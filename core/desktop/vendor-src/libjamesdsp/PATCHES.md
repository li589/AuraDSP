# vendor-src 补丁登记（PATCHES.md）

> 铁律 §3.3：上游源码原则上原样整合；确需扩展时打 `[PATCHED-AuraDSP <日期>]` 标记补丁，
> 逐条登记于本文件（位置 / 动机 / 影响面 / 上游同步冲突风险）。禁止无登记的隐式修改。

## P-001 liveprogWrapper.c — 宿主滑块注册（2026-10-09）

- **位置**：`jdsp/Effects/liveprogWrapper.c` `LiveProgLoadCode()`，`NSEEL_init_memRegion` 之后、编译之前。
- **动机**：为 AuraDSP engine_api 的 `liveprog.param1..8` 提供宿主变量。NSEEL 的
  `NSEEL_VM_freevars` 会在每次加载代码时清空注册表，因此滑块注册必须紧跟
  `init_memRegion` 重做——放在调用方（engine_api）无法满足"编译前"时序。
- **内容**：编译前 `NSEEL_VM_regvar("slider1".."slider8")`，初值 0。
- **行为影响**：脚本里可直接读写 `slider1..8`（EEL 变量），未引用的滑块无副作用。
- **上游同步冲突风险**：低（插入块独立，上游 `LiveProgLoadCode` 结构稳定）。

## P-002 stereoEnhancement.c + jdsp_header.h — 分带展宽（2026-10-09）

- **位置**：struct `stereoEnhancement` 加 `bandMix[5]`/`bandMixUsed`；`StereoEnhancementRefresh` 重置标志；`StereoEnhancementProcess` 分带路径；新增 `StereoEnhancementSetBandMix/UseUnifiedMix`。
- **动机**：M5 声场细化（用户诉求：iZotope Imager 式频带宽度）。上游 5 个子带共享单一 mix，无法分带调节。
- **行为影响**：`bandMixUsed=0`（默认/Refresh 后/UseUnifiedMix 后）与上游逐字节一致；宿主显式 SetBandMix 后按带取值。gain 补偿沿用统一公式（分带时不二次补偿，UI 负责提示）。
- **上游同步冲突风险**：中（改了 struct + Process 核心行；上游若重构此文件需人工合并）。

## P-005 jdsp_header.h + jdspController.c — 卷积干湿比（2026-10-10）

- **位置**：struct 加 `auraConvScratch / auraConvWet / auraConvDry / auraConvMixUsed`；
  `stage_conv` 在 `auraConvMixUsed && auraConvScratch` 时改走"留干信号 → 卷积 → 按系数混合"。
- **动机**：M5-3 脉冲响应混合比例（上游卷积只能全湿输出，无法与干信号混合）。
- **scratch 归属**：由宿主提供并在 `JamesDSPInit` **之后**绑定
  （`JamesDSPInit` 内部 `memset(jdsp,0,sizeof)` 会清掉提前写入的指针——实测踩过）。
- **行为影响**：`auraConvMixUsed=0`（默认）时 `stage_conv` 与上游逐字节一致；
  仅让能且 mix<1 时启用混合路径（每块两次 memcpy 的开销）。
- **上游同步冲突风险**：低（结构体加字段 + 单函数分支）。
