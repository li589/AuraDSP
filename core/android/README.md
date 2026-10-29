# core/android — Android 效果 HAL 脚手架

> 定位：Android 侧**进程外**效果注入（audioserver/vendor 进程 dlopen 效果库），与 Windows
> 桌面构建完全独立；根 CMake 不包含本目录。平台契约见
> [engine/platform/android/README.md](../../engine/platform/android/README.md)，方案见
> [跨平台基础框架与平台依赖剥离方案](../../docs/10-架构/跨平台基础框架与平台依赖剥离方案-2026-10-29.md)。
> M6（2026-10-29）只补本 README，未新增构建。

## 1. 目录

| 目录 | 角色 | 入口 |
|---|---|---|
| `aidl-gen/` | AIDL NDK 生成桩（`include/` + `gen-src/`）；**构建时生成物，`.gitignore` 排除** | 见 §2 再生成命令 |
| `vendor-src/` | 上游源码整合：libfmq、binder NDK 头、system_media、AIDL 接口、libjamesdsp | `vendor-src/ORIGIN.md`（来源表 / 分支 / 提取范围 / 版本） |
| `stubs/` | vendor 进程缺失的 libcutils/libbase/libutils 最小替代（隐藏可见性） | [stubs/README.md](stubs/README.md) |
| `registrar/` | 正式核心（Spike2 收敛）：`registrar::IAudioEngine` + FMQ 数据面 + 三导出 | [registrar/README.md](registrar/README.md)；`bash registrar/build.sh` |
| `spike-global-effect/` | M0 可行性 Spike（legacy `audio_effect_library_t` 2.0 + 临时挂载部署） | [spike-global-effect/README.md](spike-global-effect/README.md)；`build_aidl.sh` / `deploy/` |
| `registrar/examples/` | 接入示例：`spike_eq`（最小 EQ）、`jamesdsp_engine`（libjdsp.so） | [examples/jamesdsp_engine/README.md](registrar/examples/jamesdsp_engine/README.md) |

## 2. 生成物与符号契约

- `aidl-gen/` 由 `vendor-src/` 的 `.aidl` 源生成：
  `aidl --lang=ndk --structured --stability=vintf --version {3|4|2|1|4} --min_sdk_version=34`。
  包→版本：effect=V3、audio.common=V4、hardware.common=V2、common.fmq=V1、
  media.audio.common=V4。不入库（`.gitignore` 排除），tag `aidl-gen-backup-20261013`
  留档；新机按 [vendor-src/ORIGIN.md](vendor-src/ORIGIN.md) 重建。
- `registrar/version_script.txt` 与 `spike-global-effect/version_script.txt`：只导出
  `createEffect` / `queryEffect` / `destroyEffect`，其余 `local: *` —— 与 vendor 进程内
  真库零符号冲突，dlsym 契约与 legacy HAL 加载器一致。
- 两条实现形态并存：
  - `spike-global-effect/`（Spike）：legacy `audio_effect_library_t`（API 2.0），AIDL 时代
    仍兼容（本机 OplusAudioX apiVersion=0x20000 实测），无需实现 AIDL 接口。
  - `registrar/`：AIDL `IEffect`（`BnEffect` + FMQ status/in/out），仍导出同名三符号的
    AIDL dlsym 契约（`binder_exception_t createEffect(const AudioUuid*, std::shared_ptr<IEffect>*)` 等）。

## 3. 构建与部署入口

以下命令在**仓库根**执行（各脚本用 `dirname "$0"` 自解析路径）。

| 目的 | 命令 |
|---|---|
| 构建 registrar 正式库 | `cd core/android/registrar && bash build.sh`（NDK r30 clang / `aarch64-linux-android34` → `out/libspikeeq.so`） |
| 构建 Spike 验证库 | `cd core/android/spike-global-effect && bash build_aidl.sh`（→ `out/libspikeeq.so`） |
| 构建 libjdsp 效果库 | `cd core/android/registrar/examples/jamesdsp_engine && bash build_jdsp.sh`（→ `out/libjdsp.so`） |
| 临时部署 / 撤销（Spike） | `bash core/android/spike-global-effect/deploy/deploy.sh` / `rollback.sh`（KSU 授权弹窗需手机确认；reboot 自动失效） |
| 显式挂链验证 | `core/android/spike-global-effect/attach-test/classes.dex`、`core/android/registrar/examples/jamesdsp_engine/deploy/attach-test/` |

部署流程（Spike 定案）：tmpfs 覆盖 `/vendor/lib64/soundfx`（原库全量拷贝 + 新 so，
保持 `vendor_soundfx` 标签）→ bind-mount 补丁版 `audio_effects_config.xml`
（`odm_etc` 标签）→ `killall audioserver`（init 自动拉起）→ logcat/dumpsys 验证。
`-Wl,-z,max-page-size=16384` 为 Android 15+ 16KB page 硬要求。

## 4. 验证结论入口

- Spike（legacy 接口可行性）：[spike-global-effect/README.md](spike-global-effect/README.md)；
  端到端报告 [Spike2-AIDL效果库验证报告.md](../../docs/30-审查/Spike2-AIDL效果库验证报告.md)。
- Registrar（AIDL/FMQ 正式骨架）：[registrar/README.md](registrar/README.md) —— HAL 枚举、
  create/setParameter/open/command、release 全链通过（Android 16 / Ace 6T / Enforcing）。
- 引擎接入：[examples/jamesdsp_engine/README.md](registrar/examples/jamesdsp_engine/README.md)
  （完整 libjamesdsp 静态编入，默认 BassBoost +6dB 可听验证；binder 参数通道待接）。

## 5. 已知限制

- QTI HAL `queryProcessing` 原生失败 → `audio_effects_config.xml` 的 `<postprocess>`
  自动挂链不可用，须由宿主/App 显式 attach。
- FMQ 共享内存三级回退：memfd → `/dev/ashmem` → `/data/vendor/audio` 文件
  （Oplus 收紧 SELinux 后 file-backed 为实际生效路径）。
- 正式部署（KSU 模块）需固化 sepolicy 规则或依赖 file-backed 分配器；临时挂载仅用于验证。
- 本目录不进入根 CMake / Windows 构建；改 `stubs/` 必须重跑 `registrar/build.sh` + 真机验证。
