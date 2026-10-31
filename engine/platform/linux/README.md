# engine/platform/linux — Linux 端口适配（占位）

> 状态：**占位，无实现代码**（M6，2026-10-29）。本目录只承载契约；Linux 实机接入前
> 不构建、不交叉编译。方案：
> [跨平台基础框架与平台依赖剥离方案](../../../docs/10-架构/跨平台基础框架与平台依赖剥离方案-2026-10-29.md)。

## 1. 职责边界

- `engine/platform/port/*.h` 在 Linux 的**唯一实现落点**（端口-适配器，ADR-CP-1）。
- 引擎核心（`engine/` 根 / `chain/` / `dsp/` / `plugins/integration/`）不得出现 OS 头或
  平台符号，一律走端口。门禁：`python test/smoke/smoke_platform_isolation.py`（F1）。
- 端口**仅限控制线程**（加载/建链/读文件）；严禁进入 `auradsp_process` 调用图
  （RT-Safe：零分配零锁零系统调用，F5 块耗时兜底）。
- 设备输出不归引擎：`AudioOut` 端口在 App 侧
  （`app/auradsp_app/lib/engine/audio_out/`，ADR-CP-3）。PipeWire/Pulse/ALSA 选型在
  App 层落地，不改 C ABI。

## 2. 待实现端口

| 端口 | 声明 | Windows 现状 | Linux 目标 |
|---|---|---|---|
| 文件 | `port/fs.h` `fopen_utf8` | UTF-8→UTF-16 + `_wfopen` | 直接 `fopen`（glibc 按 UTF-8 字节直通，文件名无需转码） |
| 环境变量 | `port/env.h` `get_env` | `GetEnvironmentVariableA` | `getenv` + 容量/NUL 语义对齐（未设置或超容量返回 false） |
| 日志 | `port/log.h` `log_level` / `log_emit` | `OutputDebugStringA`；`AURADSP_LOG` 首次读取后粘性缓存 | `stderr`（格式逐字保留 `[AuraDSP][file:line] msg\n`）或 syslog |
| 模块 | `port/module.h` `module_open_utf8` / `module_symbol` / `module_close` / `module_last_error` / `module_last_error_text` | `plugins/platform/win32/plugin_module.cpp`：`LoadLibraryExW(LOAD_WITH_ALTERED_SEARCH_PATH)` | `dlopen(RTLD_NOW)` / `dlsym` / `dlclose` / `dlerror` |
| 时间/自旋 | `port/time.h` `now_ms` / `sleep_ms` / `cpu_relax` | header-only 标准 C++（`steady_clock` / `sleep_for` / x86 pause） | 同左，无需平台实现 |

实现时必须逐项对齐的语义：

- `fopen_utf8` 返回 `FILE*`，调用方负责 `fclose`；失败返回 `nullptr`。可选 out 参数
  `FsOpenError*` 回传失败原因（R2：`invalid_encoding` / `out_of_memory` /
  `open_failed`），调用方据此区分 `E_PARAM` 与 `E_IO`；Linux 直通 `fopen` 下
  `invalid_encoding` 不会出现（UTF-8 字节原样传给内核）。
- `get_env` 失败（未设置/写越界）返回 false，`buf` 恒以 NUL 结尾。
- `log_level` 默认 2、钳位 0–2、进程内粘性；`log_emit(min_level, ...)` 低于当前级别直接丢弃。
- `module_last_error` 返回数值错误码（Windows 为 `GetLastError`，Linux 为失败点
  `errno`/0）；`module_last_error_text` 返回同一失败的可读文本（Windows 为
  `FormatMessage` 系统文案，Linux 为 `dlerror()` 捕获串，注意后者读取即清除，
  实现需在失败点就地快照到线程局部缓冲）。

## 3. 不在本目录

| 项 | 归属 |
|---|---|
| 设备输出（PipeWire / PulseAudio / ALSA） | App 侧 `AudioOut`：`audio_out_linux.dart` 落地后由 `createAudioOut()` 工厂接入，调用方不变 |
| 桥（VM / VAIO / ASIO） | `bridge/` 只实现 `ab_*` 契约（`core/desktop/windows-drivers/bridge/common/aurabridge.h`）+ Dart `BridgeDesc`；Windows 三桥不跨平台 |
| 插件宿主 | 远程宿主（`engine/plugins/platform/win32/host/`，共享内存 + `CreateProcess`）为 Windows-only；Linux 用 `AURADSP_ENABLE_PLUGINS=OFF`（2026-11-01 已落地）整体裁掉 VST3/CLAP 宿主，引擎编入 `plugins/integration/{plugin_chain_adapter_stub,plugin_abi_stub}.cpp`，插件阶段直通且 C ABI 导出集不变。`AURADSP_PLUGIN_HOST_REMOTE=OFF` 只裁远程宿主，**不等于**可移植（仍编 Win32 插件驱动/格式实现） |
| 插件编辑器 GUI | 方案 §8 的 `port/gui.h` 属 N4「插件生态跨平台」独立立项，尚未建立 |

## 4. 构建与验证（本轮不产出）

- preset `linux-x64`（Ninja，构建树 `build/linux/x64`）仅为占位；
  根 [CMakeLists.txt](../../../CMakeLists.txt) 在非 Windows 主机上直接报错。
- 本轮 **不构建、不交叉编译**；Linux 里程碑接入时再补 `if(NOT WIN32)` 分支与源表，
  并把 `linux-x64` 转为可配置 preset。
- 可跨平台先行跑的门禁：`python test/smoke/smoke_platform_isolation.py`（纯源码扫描，
  `test/runner.py` 已标记 `PLATFORM_ANY`）。
