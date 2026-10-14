# 04_asio_engine/ — ASIO 专业模式（宿主侧）

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

## 规划布局（Spec §2.1，Phase 1 批准后落码）

```text
AsioHost.{h,cpp}   # IASIO RAII 封装（枚举→init→能力→createBuffers→start/stop）
asio_probe.cpp     # 枚举 + 能力查询 JSON（无音频，零风险）
asio_tone.cpp      # 选定驱动正弦播放 N 秒（对标 03 tone_play）
AsioBridge.h       # P2 常驻桥 C ABI（镜像 05 VmBridge.h 契约）
```

## 构建前提

父目录 `core/desktop/windows-drivers/CMakeLists.txt` 将以 `ASIO_SDK_ROOT`
（默认指向上述本机路径）引入 `auraasio_host` 静态库与 `asio_probe`/`asio_tone`
可执行目标；SDK 缺失即 FATAL 并提示本文件。详见 Spec §3 Phase 1 的 CMake 片段。

## RT 铁律（与 02/05 同款）

`bufferSwitch` 即 RT 线程：零分配、零锁、零 syscall、零日志；仅做缓冲搬运 +
`auradsp_process` + viz 帧入 SPSC 环。MMCSS 无法覆盖驱动回调线程（SDK pdf p.46），
RT 保障靠回调工作量有界（Spec §2.3 / 风险 R-2）。
