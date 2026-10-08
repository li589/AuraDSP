# jamesdsp_engine — libjdsp.so

完整 JamesDSP 引擎（`vendor-src/libjamesdsp`，83 个 C 源文件）挂载到 EffectRegistrar 框架，
产出与 libspikeeq.so 相同 dlsym 契约（`createEffect`/`queryEffect`/`destroyEffect` 三导出）的 AIDL 效果库。

## 构建与产物

```bash
bash build_jdsp.sh     # → out/libjdsp.so (≈5.6MB, NDK 30, aarch64, android34)
```

| 项 | 值 |
|---|---|
| impl UUID | `6d5d0f7a-3c1e-4a9b-8b2d-9f0a1c2d3e4f`（新，勿与 spike 混用） |
| type UUID | `0bed4300-ddd6-11db-8f34-0002a5d5c51b`（标准 EQ type，同 spike） |
| 采样格式 | float 交错立体声（`processFloatMultiplexd` 直连，>2ch 走透传） |
| 引擎默认态 | **BassBoost 开启 +6dB**（供设备端可听性验证），其余效果关闭 |

## 厂商参数（setVendorParam/getVendorParam，binder 侧）

| id | 参数 | 载荷 |
|---|---|---|
| 1 | BassBoost 开关 | int32 0/1 |
| 2 | BassBoost 增益 | float dB |
| 3 | Reverb 预设 | int32（-1=关） |
| 4 | 立体声增强 | float 0..1 |
| 5 | FIR EQ 开关 | int32 0/1 |

> 注：参数目前只在引擎层暴露，binder 传输通道（Parameter::Specific vendorExtension）留待后续接入；
> 设备端首轮验证依赖默认 BassBoost +6dB 的可听差异。

## 与 spike_eq 的关键差异（排错记录）

1. **不定义 `JAMESDSP_REFERENCE_IMPL`**：避免 HAL 进程内起 benchmark 线程；
   卷积分区选择使用引擎内置默认基准系数（convbench_c0/c1 已预置）。
2. **C 编译开关**（NDK 30 clang 更严格，全部开关级处理、零源码补丁）：
   `-Wno-incompatible-function-pointer-types -Wno-incompatible-pointer-types
   -Wno-visibility -Wno-enum-conversion -Wno-implicit-int -Wno-implicit-function-declaration`
3. **include 路径只有两级**（`libjamesdsp/` 与 `libjamesdsp/jdsp/`），绝不能加
   `libjamesdsp/jdsp/Effects/eel2/`——那里的 `dirent.h` 是 Windows 版，会遮蔽 bionic 的。
4. `cpthread.c` 整体是 `_WIN32` shim，Android 上跳过；`cpthread.h` 必须在位
   （`jdsp_header.h` 的 `#include "../cpthread.h"` 依赖它，Android 分支回落系统 pthread）。

## 部署（待做）

设备端需在 `audio_effects_config.xml` 注册新 impl UUID 后推送
`out/libjdsp.so` 到 `/system/lib64/soundfx/`（或 KSU 模块 overlay 路径），
可复用 `spike-global-effect/deploy/` 的打包流程，替换库名与 UUID。
