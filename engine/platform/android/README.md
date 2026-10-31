# engine/platform/android — Android 端口适配（占位）

> 状态：**占位，无实现代码**（M6，2026-10-29）。本目录只承载契约；Android 接入前
> 不构建、不交叉编译。方案：
> [跨平台基础框架与平台依赖剥离方案](../../../docs/10-架构/跨平台基础框架与平台依赖剥离方案-2026-10-29.md)。

## 1. 两条接入路径（互不替代）

| 路径 | 归属 | 说明 |
|---|---|---|
| **App 内输出**（AAudio / Oboe） | App 侧 `AudioOut` 端口 | 低延迟客户端 API，运行在 App 进程；Android 实现落地后由 `createAudioOut()` 工厂接入，不改 DSP |
| **系统效果 HAL 注入** | `core/android/` | 效果库运行在 audioserver/vendor 进程（`hal_audio_default`），由 effects HAL `dlopen`；入口见 [core/android/README.md](../../../core/android/README.md) |

两条路径共用同一份引擎与 C ABI（`engine/auradsp_engine.h`）。HAL 注入不是 App 内的
`AudioOut` 实现，也不经过 Dart 泵循环；`AudioOut` 在 Android 上仍归 App 侧。

## 2. 端口待实现项

| 端口 | Android 落点 | 约束 |
|---|---|---|
| `port/fs.h` `fopen_utf8` | 直接 `fopen`（bionic 按 UTF-8 直通）；可选 `FsOpenError*` 回传失败原因（R2） | 应用沙箱路径与 vendor 路径的权限差异由调用方保证 |
| `port/env.h` `get_env` | `getenv` + NUL/容量语义对齐 | vendor 进程受 SELinux 限制，环境变量不可作为配置真相源 |
| `port/log.h` `log_level` / `log_emit` | `__android_log_print`（标签沿用 `AURADSP`） | 格式逐字保留 `[AuraDSP][file:line] msg\n` |
| `port/module.h` | `dlopen` / `dlsym` / `dlclose` / `dlerror` | HAL 进程的 linker namespace 与 SELinux 决定可加载路径，不能沿用 Windows 的「目录优先」搜索语义 |

## 3. 插件宿主与 GUI

- **进程外插件宿主不适用**：`engine/plugins/platform/win32/host/`（共享内存 + `CreateProcess`）
  是 Windows 模型；Android 走 `AURADSP_ENABLE_PLUGINS=OFF`（2026-11-01 已落地）整体裁剪
  VST3/CLAP 子系统（链阶段直通、C ABI 导出集不变）。`AURADSP_PLUGIN_HOST_REMOTE=OFF`
  只裁远程宿主，不裁 Win32 插件驱动/格式实现。
- **VST3 / CLAP 不落地**：无桌面窗口栈与插件目录约定；编辑器 GUI 属方案 N4 独立立项。
- 若未来需要 Android 原生效果扩展，走 `core/android/registrar` 的 `registrar::IAudioEngine`
  三步接入（见 `core/android/registrar/README.md`），不复用桌面插件格式。

## 4. 构建（本轮不产出）

- preset `android-arm64`（Ninja，构建树 `build/android/arm64-v8a`）仅为占位：
  NDK 工具链未接入根 CMake，本轮不构建。
- `core/android/*/build*.sh` 继续独立使用 NDK clang（`aarch64-linux-android34`，
  NDK r30 本机路径见脚本），不并入根 CMake；Gradle 接入后续另立项。
- ABI 与页大小硬要求：`-Wl,-z,max-page-size=16384`（Android 15+ 16KB page），
  效果库以 `version_script.txt` 只导出 HAL 契约符号（`createEffect` / `queryEffect` /
  `destroyEffect`），其余 `local: *`。
- 引擎 C ABI 不变：新增平台只新增 `platform/android/*` 适配文件与导出机制说明，
  不新增 `auradsp_engine.h` / `.def` 符号。
