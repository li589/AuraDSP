# ORIGIN.md — core/desktop/vendor-src 溯源登记

> 铁律：本目录每个子集必须登记上游仓库、分支、提取路径、用途、日期。
> 升级路径：从 `source/` 重新提取覆盖，更新版本号即可。
> 禁止在本目录内改上游逻辑；如必须打补丁，标注 `[PATCHED]` 并给出 diff 说明。

| 条目 | 上游 | 提取路径 | 版本/日期 | 用途 | 状态 |
|---|---|---|---|---|---|
| libjamesdsp | https://github.com/james34602/JamesDSPManager（本地克隆 `source/JamesDSPManager`） | `Main/libjamesdsp/jni/jamesdsp/`（剔除 `Android.mk`） | 2026-10-09 提取 | AuraDSP Engines 引擎核心（DSP 全部算法：EQ/BassBoost/Reverb/Convolver/Crossfeed/StereoEnh/VacuumTube/DDC/Compressor/ArbMag/LiveProg-EEL2 + limiter/postGain） | 原样未改 |
| clap-api | https://github.com/free-audio/clap（源自 `source/lsp-plugins/modules/lsp-3rd-party/include/clap/`） | `clap/` | 2026-10-10 提取 | CLAP 纯 C ABI 宿主接口头文件（MIT 许可，跨平台一等公民） | 原样未改 |
| steinberg-vst3 | https://github.com/steinbergmedia/vst3sdk（源自 `source/lsp-plugins/modules/lsp-3rd-party/include/steinberg/`） | `steinberg/` | 2026-10-10 提取 | Steinberg VST3 C++ 宿主接口头文件（GPLv3 路线） | 原样未改 |

