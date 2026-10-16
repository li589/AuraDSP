# ORIGIN.md — vendor/ 溯源登记

> 铁律：本目录每个子集必须登记上游仓库、分支、提取路径、用途、日期。
> 升级路径：从 `source/` 重新提取覆盖，更新版本号即可。
> 禁止在本目录内改上游逻辑；如必须打补丁，标注 `[PATCHED]` 并给出 diff 说明。

| 条目 | 上游 | 提取路径 | 版本/日期 | 用途 | 状态 |
|---|---|---|---|---|---|
| ~~libjamesdsp~~ | https://github.com/james34602/JamesDSPManager（本地克隆 `source/JamesDSPManager`） | `Main/libjamesdsp/jni/jamesdsp/`（剔除 `Android.mk`） | 2026-10-09 提取 | AuraDSP Engines 引擎核心（DSP 全部算法：EQ/BassBoost/Reverb/Convolver/Crossfeed/StereoEnh/VacuumTube/DDC/Compressor/ArbMag/LiveProg-EEL2 + limiter/postGain） | **已迁出**：2026-10-16 正式收编至 `engine/legacy/`（提交 `a81dc04`，139 文件 R100 纯平移）。补丁登记簿随迁为 `engine/legacy/PATCHES.md`（登记与标记计数以该文件为准）；升级路径改为「提取后覆盖 `engine/legacy/` 并重提补丁」。本行保留作考古记录，**不代表当前物理位置** |
| clap-api | https://github.com/free-audio/clap（源自 `source/lsp-plugins/modules/lsp-3rd-party/include/clap/`） | `clap/` | 2026-10-10 提取 | CLAP 纯 C ABI 宿主接口头文件（MIT 许可，跨平台一等公民） | 原样未改 |
| steinberg-vst3 | https://github.com/steinbergmedia/vst3sdk（源自 `source/lsp-plugins/modules/lsp-3rd-party/include/steinberg/`） | `steinberg/` | 2026-10-10 提取 | Steinberg VST3 C++ 宿主接口头文件（GPLv3 路线） | 原样未改 |

> **注**：`vendor/` 现已纯化为「行业接口标准只读区」，仅剩 `plugin-api/{clap,steinberg}`。
> libjamesdsp 虽已迁至 `engine/legacy/`，但其「第三方来源 + 深度打补丁」的双重属性不变——
> `engine/legacy/` 继续视同 vendor 只读，补丁纪律见 `engine/AGENT.md` §4。

