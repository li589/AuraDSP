# engine/platform/linux — Linux 端口适配

> 状态：**S2 已落地**（2026-11-01，`feature/linux`）：4 个端口实现 + Linux 构建
> 目标已就绪并实测通过（见 §4）。方案：
> [Linux 适配方案](../../../docs/10-架构/Linux适配方案-2026-11-01.md)；
> 产品语义裁定：[ADR-012](../../../docs/adr/ADR-012-linux-platform-rulings-and-branch-policy.md)。

## 1. 职责边界

- `engine/platform/port/*.h` 在 Linux 的**唯一实现落点**（端口-适配器，ADR-CP-1）。
- 引擎核心（`engine/` 根 / `chain/` / `dsp/` / `plugins/integration/`）不得出现 OS 头或
  平台符号，一律走端口。门禁：`python test/smoke/smoke_platform_isolation.py`（F1）。
- 端口**仅限控制线程**（加载/建链/读文件）；严禁进入 `auradsp_process` 调用图
  （RT-Safe：零分配零锁零系统调用，F5 块耗时兜底）。
- 设备输出不归引擎：`AudioOut` 端口在 App 侧
  （`app/auradsp_app/lib/engine/audio_out/`，ADR-CP-3）。PipeWire/Pulse/ALSA 选型在
  App 层落地，不改 C ABI（D-6 已裁定 PulseAudio simple API 优先，S3 落地）。

## 2. 端口实现现状

| 端口 | 声明 | Windows 现状 | Linux 实现（本目录） |
|---|---|---|---|
| 文件 | `port/fs.h` `fopen_utf8` | UTF-8→UTF-16 + `_wfopen` | `fs_linux.cpp`：直接 `fopen`（glibc 按 UTF-8 字节直通，文件名无需转码） |
| 环境变量 | `port/env.h` `get_env` | `GetEnvironmentVariableA` | `env_linux.cpp`：`getenv` + 容量/NUL 语义对齐（未设置、空值或超容量返回 false） |
| 日志 | `port/log.h` `log_level` / `log_emit` | `OutputDebugStringA`；`AURADSP_LOG` 首次读取后粘性缓存 | `log_linux.cpp`：`stderr`，格式逐字保留 `[AuraDSP][file:line] msg\n`，级别/粘性/钳位与 Windows 版同构 |
| 模块 | `port/module.h` `module_open_utf8` / `module_symbol` / `module_close` / `module_last_error` / `module_last_error_text` | `plugins/platform/win32/plugin_module.cpp`：`LoadLibraryExW(LOAD_WITH_ALTERED_SEARCH_PATH)` | `module_linux.cpp`：`dlopen(RTLD_NOW \| RTLD_LOCAL)` / `dlsym` / `dlclose` / `dlerror` 失败点就地快照 |
| 时间/自旋 | `port/time.h` `now_ms` / `sleep_ms` / `cpu_relax` | header-only 标准 C++（`steady_clock` / `sleep_for` / x86 pause） | 同左，无需平台实现 |

逐项对齐的语义：

- `fopen_utf8` 返回 `FILE*`，调用方负责 `fclose`；失败返回 `nullptr`。可选 out 参数
  `FsOpenError*` 回传失败原因：Linux 直通 `fopen` 下 `invalid_encoding` /
  `out_of_memory` 不会出现（无转码、无内部缓冲），失败只有 `invalid_path` /
  `open_failed` 两类。
- `get_env` 失败（未设置/空值/写越界）返回 false，`buf` 恒以 NUL 结尾。
- `log_level` 默认 2、钳位 0–2、进程内粘性；`log_emit(min_level, ...)` 低于当前级别直接丢弃。
- `module_last_error` 返回数值错误码（Windows 为 `GetLastError`，Linux 为失败点
  `errno`，dlopen 失败时不可靠、可能为 0）；`module_last_error_text` 返回同一失败的
  可读文本（Linux 为 `dlerror()` 捕获串，读取即清除，实现已在失败点就地快照到
  线程局部缓冲）。**诊断以文本为准，数值仅作参考。**
- 已知语义差：`dlopen` 给定绝对路径时依赖走 DT_NEEDED + rpath/系统路径，
  **不含模块所在目录**；Windows 的 `LOAD_WITH_ALTERED_SEARCH_PATH` 会从插件
  所在目录解析依赖。Linux 插件宿主立项时须重新裁定此点（D-7：首期不做宿主）。

构建侧的 GCC 适配（不在本目录，登记备查）：

- `engine/auradsp_gcc_shim.h` 经 CMake `-include` 前置注入全部 C++ 源（与 MSVC 的
  `/FI auradsp_msvc_shim.h` 对称）：预包含标准头以化解 legacy `min`/`max` 宏与
  `extern "C"` 块内包含模板头两处 GCC 严格性，并由 `<math.h>` 提供全局
  `isnan`/`isinf`。C 源另以 `-include stdint.h` 解 `essential.h` 的 stdint 缺口（E3）。
- Linux 源表在 `core_sources.cmake` 基础上排除 `legacy/jamesdsp.c`（E4：其 GCC
  `__attribute__((constructor))` 会与 `global_init()` 双跑初始化）。

## 3. 不在本目录

| 项 | 归属 |
|---|---|
| 设备输出（PipeWire / PulseAudio / ALSA） | App 侧 `AudioOut`：`audio_out_linux.dart`（D-6：PulseAudio simple API）落地后由 `createAudioOut()` 工厂接入，调用方不变（S3） |
| 桥（VM / VAIO / ASIO） | `bridge/` 只实现 `ab_*` 契约（`core/desktop/windows-drivers/bridge/common/aurabridge.h`）+ Dart `BridgeDesc`；Windows 三桥不跨平台 |
| 插件宿主 | 远程宿主（`engine/plugins/platform/win32/host/`，共享内存 + `CreateProcess`）为 Windows-only；Linux 用 `AURADSP_ENABLE_PLUGINS=OFF`（D-7）整体裁掉 VST3/CLAP 宿主，引擎编入 `plugins/integration/{plugin_chain_adapter_stub,plugin_abi_stub}.cpp`，插件阶段直通且 C ABI 导出集不变。`AURADSP_PLUGIN_HOST_REMOTE=OFF` 只裁远程宿主，**不等于**可移植（仍编 Win32 插件驱动/格式实现） |
| 插件编辑器 GUI | 方案 §8 的 `port/gui.h` 属 N4「插件生态跨平台」独立立项，尚未建立 |

## 4. 构建与验证（S2 实测）

```bash
# 统一入口（根 preset）或子工程脚本，二选一：
cmake --preset linux-x64 && cmake --build --preset linux-x64-release
bash core/desktop/linux/build_engine.sh
# 产物：core/desktop/linux/out/Release/libauradsp_engine.so
```

- 导出控制：`engine/auradsp_engine.map`（version script，由
  `tools/bin/gen_engine_map.py` 从 `auradsp_engine.def` 同源生成，`--check`
  校验）。只用 version script 收口，不叠加 `-fvisibility=hidden`：本仓 ABI
  头无 visibility 宏，hidden 会把 56 个 ABI 符号一并隐藏（S2 实测导出归零）。
- 门禁：`python test/smoke/smoke_linux_source_table.py`（PLATFORM_ANY）断言
  Linux 编译闭包：不含 `jamesdsp.c`、不引无守卫 Win32 头、gcc shim / stdint
  前置注入在场、`.map` 与 `.def` 同源。
- 2026-11-01 首台 Linux VM 实测（gcc 13.3 / CMake 3.28 / Ninja）：legacy C
  85 文件与 C++ 核心 19 TU 全量编译通过；`.so` 动态导出集恰为 `.def` 的
  56 符号；ctypes 加载后 `auradsp_version` = 1.1.0、`auradsp_abi` = 2，
  create(48k,512) → process → destroy 冒烟通过。
