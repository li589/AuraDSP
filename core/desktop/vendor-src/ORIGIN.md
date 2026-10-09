# ORIGIN.md — core/desktop/vendor-src 溯源登记

> 铁律：本目录每个子集必须登记上游仓库、分支、提取路径、用途、日期。
> 升级路径：从 `source/` 重新提取覆盖，更新版本号即可。
> 禁止在本目录内改上游逻辑；如必须打补丁，标注 `[PATCHED]` 并给出 diff 说明。

| 条目 | 上游 | 提取路径 | 版本/日期 | 用途 | 状态 |
|---|---|---|---|---|---|
| libjamesdsp | https://github.com/james34602/JamesDSPManager（本地克隆 `source/JamesDSPManager`） | `Main/libjamesdsp/jni/jamesdsp/`（剔除 `Android.mk`） | 2026-10-09 提取 | AuraDSP Engines 引擎核心（DSP 全部算法：EQ/BassBoost/Reverb/Convolver/Crossfeed/StereoEnh/VacuumTube/DDC/Compressor/ArbMag/LiveProg-EEL2 + limiter/postGain） | 原样未改 |
