# core/desktop/windows-drivers/ — Windows 底层驱动套件（SPEC-WIN-DRIVER-001）

> 与 `engine/`（DSP 算法）彻底解耦：本目录只做传输与格式搬运，
> 不承载任何具体音效算法；仅依赖 Windows SDK（用户态）/ WDK（内核态）。

## 现状（2026-10-13）

- [x] 目录骨架 + 独立 CMake（VS18 x64，不进引擎构建）
- [x] `02_voicemeeter_client/`：三级自省检测（注册表 → Remote DLL → PE 版本）
- [x] `02` OUTPUT INSERT 回调泵（A1 主对进引擎 + 其余透传 + 静音旁路 + 中性透传验证）
- [ ] `02` 多总线逐对处理、参数下发面（后续 slice）
- [ ] `03_system_apo/`（需管理员；本机 shell 非提权，按需提权跑 Configurator）
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
