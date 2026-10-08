# vendor-src 来源说明（Origin）

所有目录均为**上游源码整合**（无预编译产物），用于 registrar 构建。
每个条目记录：上游仓库 / 分支 / 提取范围 / 用途。升级时重新提取并更新此表。

| 目录 | 上游 | 分支 | 提取范围 | 用途 |
|---|---|---|---|---|
| `libfmq/` | github.com/LineageOS/android_system_libfmq | lineage-23.2 | 全仓库（源码+头文件） | FMQ 数据面（AidlMessageQueue/EventFlag），静态编入效果库 |
| `frameworks_native/binder-ndk/` | github.com/LineageOS/android_frameworks_native | lineage-23.2 | `libs/binder/ndk/`（仅头文件 include_cpp/include_ndk/include_platform） | binder NDK 头（NDK sysroot 缺 `binder_interface_utils.h` 等 C++ 头） |
| `system_media/audio/` | github.com/LineageOS/android_system_media | lineage-23.2 | `audio/include/system/audio_effects/` | effect 常量（kEventFlag*、标准 type UUID）与 legacy uuid 头 |
| `android_hardware_interfaces/` | github.com/LineageOS/android_hardware_interfaces | lineage-23.0 (Android 16) | `audio/aidl`（.aidl 源 + default/ C++ 参考实现）+ `common/aidl` + `common/fmq/aidl` | AIDL 接口定义源；`default/` 为权威参考实现（EffectFactory/EffectImpl 等） |
| `platform_system_hardware_interfaces/` | github.com/BlissOS/platform_system_hardware_interfaces | voyager-x86-qpr2 (Android 16) | `media/aidl` + `common/aidl` | media.audio.common 等 AIDL 接口定义源 |
| `libjamesdsp/` | github.com/joshua-8/JamesDSPManager（本机 source/JamesDSPManager） | main @ 提取时点 | `Main/libjamesdsp/jni/jamesdsp/` 下的 `jdsp/` 全目录 + `cpthread.c`（85 个 .c，5.3MB）。**排除** `jamesdsp.c`（legacy EffectDSPMain ABI 适配层，注册员架构不需要） | JamesDSP DSP 引擎本体（EEL2/FFT/ASRC/全部效果链），以 C 源码静态编入 libjdsp.so |

## 再生成 AIDL stub

`aidl-gen/`（include + gen-src）由以上 `.aidl` 源经
`aidl --lang=ndk --structured --stability=vintf --version {3|4|2|1|4} --min_sdk_version=34`
生成，产物可直接重建（见 registrar/build.sh）。包→版本映射：
effect=V3, audio.common=V4, hardware.common=V2, common.fmq=V1, media.audio.common=V4。
