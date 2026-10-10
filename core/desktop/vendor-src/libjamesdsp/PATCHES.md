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

## P-006 jdsp_header.h + multimodalEQ.c — EQ 卷积器双缓冲（2026-10-10）

- **位置**：MultimodalEQ 新增 convB / ctiveConv / convProcCount / convSwapProc；
  MultimodalEqualizerConstructor 与 Destructor 增删 convB 的 Init/Free；
  MultimodalEqualizerAxisInterpolation 改为重建到非活动实例并原子换指针；
  MultimodalEqualizerProcess 改用 ctiveConv
- **症状**：操作 EQ 时爆音。eq.curve 经 uradsp_set_param 在驱动 WASAPI 的线程上
  调用 MultimodalEqualizerAxisInterpolation（makima + 最小相位 IR + FFT 卷积刷新，约 760µs），
  而同一线程的音频回调正在 FFTConvolver2x2Process(&mEQ.conv, ...)
- **根因**：重建与处理**操作同一个卷积器对象且全程无锁** ——
  刷新方覆写 _segmentsIRRe/Im、_current、_overlap，
  处理方同时在读它们。ctrl_mutex 明确不挡 process。
  这是数据竞争，不只是延迟问题，故单纯节流或挪线程无法根治
- **改动**：mEQ 内预分配 conv / convB 两个卷积器 + ctiveConv 指针。
  控制线程在非活动实例上完成 IR 构建与刷新，随后换指针；
  音频线程块首读一次指针即切到新 IR，块内不再触碰换出的实例
- **生命周期**：两实例均内嵌于 mEQ，由 MultimodalEqualizerDestructor 统一释放，
  **不存在跨线程释放**
- **在途守卫**：convProcCount 由音频线程递增，convSwapProc 记录上次换出时的快照；
  换出后需再跑满 1 块才允许把该实例重新投入重建，
  避免与换出瞬间尚未返回的那次 Process 调用竞争
- **convState 未双缓冲**：已查明 FFTConvolver2x2RefreshImpulseResponse(conv1, conv2, ...)
  中 conv1 仅用作 FFT 暂存（写 _fftBuffer、读 it/sine），IR 段不更新；
  只有 conv2 才是真正的 IR 存储。故无需为其引入第二份
- **兼容性**：外部调用方无需改动，uradsp_set_param("eq.curve") 语义不变；
  operatingMode != 0 的 IIR 分支未触及
