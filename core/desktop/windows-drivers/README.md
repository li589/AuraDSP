# core/desktop/windows-drivers/ — Windows 底层驱动套件（SPEC-WIN-DRIVER-001）

> 与 `engine/`（DSP 算法）彻底解耦：本目录只做传输与格式搬运，
> 不承载任何具体音效算法；仅依赖 Windows SDK（用户态）/ WDK（内核态）。

## 现状（2026-10-13）

- [x] 目录骨架 + 独立 CMake（VS18 x64，不进引擎构建）
- [x] `02_voicemeeter_client/`：三级自省检测（注册表 → Remote DLL → PE 版本）
- [x] `02` OUTPUT INSERT 回调泵（A1 主对进引擎 + 其余透传 + 静音旁路 + 中性透传验证）
- [x] 回调语义对标 `source/equalizerAPO64/VoicemeeterClient`（bus 组迭代/精确零+10s+输出静默
      三条件 idle/CHANGE 计数；初版 1e-5+2s 已按此推翻，见 `VmAudioCallback.cpp` 头注）

## 托盘图标语义（VM 原生 tooltip 实证）

- **R-BOX**：Remote API 客户端占用，一格一 login，上限 8。漏 Logout 即攒 R
  （曾 6 次运行复现 R 全亮；现已 Login/Logout 单次配对，EAPO `endSoftware` 同式）。
- **A-BOX**：内部音频回调被占用。EAPO 常驻回调故常亮 A；本泵只在运行秒级内持有，
  平时无 A。点 A 可看占用者（与 EAPO 共存时互相看到对方名）。

## 占用 / 崩溃 / 重试策略（EAPO 对标）

- OUT 槽同时只能一家：`rc==1` 直接让路记 note；其它非零按 EAPO 式有界重试
  10×100ms（EAPO 是 30×，泵短命故减半），超时仍优雅退出码 0。
- Double-Logout / Double-FreeLibrary 会 AV（已抓现行各一次）：leave 幂等，
  logout+unreg 全路径单次配对。
- 进程崩溃会滞留 OUT 槽（VM 侧无超时回收）→ 重启 VM；R 会话同理靠重启清。
- VM 被杀：回调断流→精确零→bypass 透传→ stop/unreg/logout 照常返回（已实测杀进程，
  exit 0 无崩溃）；引擎住在 audiodg，杀 GUI 未必停泵。
- 死锁：结构不可能（RT 零锁 + 主线程无等待回调的原语，见源码头注）。
- 爆音预算：`maxCbUs` 打点上报，中性 8 组约 3.2ms（缓冲 42.7ms），smoke 阈值半周期。
- [x] `02` 多总线逐对处理（版型预建 handle，组独立 idle）
- [x] `02` 参数下发面（`--seti/--setf`，回报 applied/failed；声学有条件断言）
- [ ] `03_system_apo/`（需管理员；本机 shell 非提权，按需提权跑 Configurator）
- [x] `03` 只读检测（端点枚举/FxProperties 五槽/签名开关；本机 48 端点全可读，
      在用微软 inbox SFX/MFX，无第三方 APO；`smoke_apo_inspect.py`）
- [ ] `03` Configurator（安装/备份/卸载/服务重启握手，需提权，EAPO 简报已备）
- [ ] `04_asio_engine/`（需 Steinberg ASIO SDK，仓内暂无）
- [ ] `01_vaio_driver/`（需 WDK；**本机无 WDK**，`Include/wdf` 不存在，不可构建）

## 环境结论（本机实测）

- Voicemeeter 全家桶已安装（Standard/Banana/Potato exe + Remote32/64 DLL 1.1.1.9）→
  模式 2 可即刻联调；三级自省在本机应三级全通。
- Windows Kits 10（仅 SDK）→ 用户态全可构建；内核态等 WDK。
- 当前 shell 非管理员 → APO 注册/回滚操作需另行提权。

## 构建

```powershell
cmake -S core/desktop/windows-drivers -B core/desktop/windows-drivers/out -G "Visual Studio 18 2026" -A x64
cmake --build core/desktop/windows-drivers/out --config Release
```

产物进 `out/`（`**/out/` 已 gitignore），不污染源码树。
