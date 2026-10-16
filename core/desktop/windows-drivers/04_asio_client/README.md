# 04_asio_client/ — ASIO 专业模式（宿主侧，Client 线）

> 本目录 = Client 线：打开第三方 ASIO 驱动做传输。与 Driver 线
> （自身作为 ASIO 驱动被 DAW 打开，见 `04_asio_driver/`）是两条线，规划见
> `docs/20-执行/ASIO双线开发规划-2026-10-15.md`。
>

> 与 `engine/`（DSP 算法）彻底解耦：本目录只做 ASIO 传输搬运（枚举/加载驱动、
> 缓冲区切换回调内调 `auradsp_process`），不承载任何音效算法。
> 开工依据：[`docs/20-执行/ASIO驱动开工Spec-2026-10-14.md`](../../../../docs/20-执行/ASIO驱动开工Spec-2026-10-14.md)。

## SDK 登记（第三方工具链，不入库）

| 项 | 内容 |
|---|---|
| 组件 | Steinberg ASIO SDK **2.3.4**（`changes.txt` 顶部；README 称 2.3，接口同源） |
| 本机路径 | `C:\FreeRulesPrograms\BasicToolkits\SteinbergDev\ASIOSDK`（CMake 变量 `ASIO_SDK_ROOT`） |
| 许可 | **双许可**（SDK `LICENSE.txt`）：(a) 专有——禁再分发、发布需签约；(b) **GPLv3**——允许完整开源集成。**本项目选定 GPLv3 路线**（libjamesdsp 衍生 GPL 系发布仓，见 `docs/00-总览/产品架构总览.md` §127） |
| 再分发 | **SDK 文件一律不进仓库、不进 release 附件**（同 NDK/Flutter SDK 外部工具链铁律）；按路径引用 |
| 商标 | v1 **不使用** ASIO 商标/Logo（要标需另立 ADR 并遵守 Usage Guidelines） |
| 文档 | `Steinberg ASIO SDK 2.3.pdf` / `Steinberg ASIO Usage Guidelines.pdf` 已登记于 `docs/参考技术手册/README.md`（本地只读） |

**升级路径**：Steinberg 发新版 → 更新 `BasicToolkits` 下 SDK → 改本表版本号与
Spec §1.1 → 回归 smoke。禁止手工改 SDK 内文件（与 `vendor/` 同款只读铁律）。

## 本机在装 ASIO 驱动（2026-10-14 实测，`HKLM\SOFTWARE\ASIO` 64/32 视图各 7 个）

`FL Studio ASIO` · `Voicemeeter Virtual ASIO` · `Voicemeeter AUX Virtual ASIO` ·
`Voicemeeter Insert Virtual ASIO` · `Voicemeeter Potato Insert Virtual ASIO` ·
`Voicemeeter VAIO3 Virtual ASIO` · `DSDTranscoder`

→ 无硬件即可端到端实测；枚举结果须与注册表逐一对账（`smoke_asio_probe.py`）。

**命名语义**（`fcd0f3f` 实测发现）：SDK 驱动名取子键 `Description` 值
（`asiolist.cpp` `newDrvStruct`），缺失才回退子键名。故 `DSDTranscoder`
子键的 SDK 显示名是 **`DSD 转码器 (DoP/Native)`**（GBK 字节，显示/JSON 需转
UTF-8，load 匹配键保留原始 ANSI）；smoke 对账基准必须同为 Description，
误用子键名会 mismatch。

## 规划布局（Spec §2.1，Phase 1/2 均已落地）

```text
AsioHost.{h,cpp}   # IASIO RAII 封装（枚举→init→能力→createBuffers→start/stop）
asio_probe.cpp     # 枚举 + 能力查询 JSON（无音频，零风险）
asio_tone.cpp      # 选定驱动正弦播放 N 秒（对标 03 tone_play）
# 常驻桥已搬入 ../bridge/asio_bridge/（AsioBridge.{h,cpp,def}，镜像
# ../bridge/vm_bridge/VmBridge.h 契约）：桥统一收敛，宿主留守本目录。
```

Phase 1（`fcd0f3f`）落码前三项；Phase 2（2026-10-15）落地桥四件，
`smoke_asio_bridge.py` 已挂 `test/runner.py`（Spec §7 出口核销）。

## 驱动兼容性实录（2026-10-15，FL Studio ASIO 深调）

调试 `auraasio_bridge` 宿主下 FL Studio ASIO（ilwasapi2asio）必崩问题，
逐项实验定罪三条铁律（详见 Spec §Phase 2 落地偏差记录）：

1. **引擎 DLL 必须在 `host.open` 之前加载**。驱动在
   `ASIOInit`~`ASIOCreateBuffers` 窗口内启动自有 RT 线程，此窗口内的
   `LoadLibrary` 与其争抢 loader lock——轻则回调静默，重则驱动看门狗
   `ExitProcess(0)` 干净杀宿主（无转储无段错误，易误判"玄学崩"）。
2. **`ASIOInit` 的 sysRef 不能传 nullptr**（FL Studio ASIO 会给宿主派发
   终止）；控制台宿主用 `GetConsoleWindow()`，GUI 宿主由调用方传主窗口。
3. **`ASIOCallbacks` 必须进程级生存期（`AsioHost::s_cb` 类级静态）**。
   驱动按 ASIO 契约长期持有该指针（FL Studio ASIO 存引擎对象 `+0xd0`，
   RT 线程每帧经它尾调用 `bufferSwitch`）。栈局部地址在 `create_*`
   返回后即失效，被后续调用覆写后驱动首次回调跳垃圾指针（NX 崩溃）——
   "tone 侥幸存活、桥宿主必崩"对偶现象的根因（tone 调用链浅、栈槽
   未被覆写纯属运气）。排查手法：跳板式 hook 驱动 `createBuffers`/
   RT 助手函数记录实参与调用栈。

## 构建前提

父目录 `core/desktop/windows-drivers/CMakeLists.txt` 以 `ASIO_SDK_ROOT`
（默认指向上述本机路径）引入 `auraasio_host` 静态库与 `asio_probe`/`asio_tone`
可执行目标；SDK 缺失即 FATAL 并提示本文件。详见 Spec §3 Phase 1 的 CMake 片段
（宿主最小源集为 SDK 3 源：`common/asio.cpp` + `host/asiodrivers.cpp` +
`host/pc/asiolist.cpp`，驱动侧 `asiodrvr/combase/register/dllentry` 不需要）。

## RT 铁律（与 02/05 同款）

`bufferSwitch` 即 RT 线程：零分配、零锁、零 syscall、零日志；仅做缓冲搬运 +
`auradsp_process` + viz 帧入 SPSC 环。MMCSS 无法覆盖驱动回调线程（SDK pdf p.46），
RT 保障靠回调工作量有界（Spec §2.3 / 风险 R-2）。
