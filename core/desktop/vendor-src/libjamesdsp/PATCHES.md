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
- **根因**：重建与处理**操作同一个卷积器对象** ——
  刷新方覆写 _segmentsIRRe/Im、_current、_overlap，处理方读的是同一个对象。
  ctrl_mutex 明确不挡 process。
  **注意措辞更正（2026-10-10 复盘）**：这**不是跨线程数据竞争**——
  `setParamStr` 与 WASAPI 音频泵同属 `audio_isolate.dart` 的同一个 isolate
  （`case 'setParamStr'` :739 与 `pump()` :1154 同函数，:1250 由
  `unawaited(pump())` 启动），Dart isolate 单线程 ⇒ 两者同 OS 线程。
  真实成因是 ① 每次重建**阻塞音频泵**约 760µs，导致回调赶不上；
  ② 重建对象与处理对象**重叠**（同一块内存先被刷新再被处理）。
  该补丁消除了②并把①移出关键路径，价值成立；「数据竞争」的原始措辞是错的。
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

## P-007 multimodalEQ.c — EQ 频率轴按实际 Nyquist 收尾（2026-10-10）

- **位置**：两处 jdsp->mEQ.freq[NUMPTS + 1] = 24000.0
  （MultimodalEqualizerConstructor 与 MultimodalEqualizerAxisInterpolation）
- **症状**：采样率低于 48kHz 时，EQ 曲线最末端锚点超过 Nyquist。
  44.1kHz 下 Nyquist 为 22050Hz，硬编码的 24000 越界。
- **改动**：改为 (double)jdsp->fs * 0.5，按实际采样率取 Nyquist。
- **配套**：P-006 已把 uradsp_engine.cpp 侧 eq.curve 的频点也按
  sample_rate * 0.5 钳位，两端一致。
- **兼容性**：req[NUMPTS]（用户最末点）已由引擎侧钳到 
yquist * 0.999，
  故 req[NUMPTS] < fs * 0.5 恒成立，单调性不被破坏。

## P-008 jdspController.c — 块长抖动抑制：不再无谓重建卷积器（电平抖动 / 卡顿修复，2026-10-12）

- **位置**：`jdspController.c` 的 `pfloat32Multiplexed()` 内 `if (jdsp->blockSize != n)` 分支
- **病因**：只要块长变化，就无条件调 `JamesDSPRefreshConvolutions()` →
  `Convolver1DLoadImpulseResponse(updateOld=0)` → 析构并重建全部卷积器
  （重做全 IR 的 FFT + 分段选择）。而 AuraDSP 的 WASAPI 泵传入
  `n = min(avail, max_block)`，`avail` 随 padding 逐轮抖动，于是**几乎每轮都重建**。
  实测（`tools/probe_ir_stability.py`，0.5s / 48kHz IR）：

  | 块长 | 中位耗时 | 输出 RMS |
  |---|---|---|
  | 恒定 1024 | 0.160ms | 0.5607 |
  | 1024/900/700 抖动 | **4.050ms（25×）** | **0.4360（低 22%）** |
  | 1024/1023（差 1 样本） | **3.958ms（25×）** | **0.4577（低 18%）** |

  即用户反馈的「启动后播放长时间声音，会周期性声音断续或者变小或者卡顿」：
  重建既吃满 CPU 预算（卡顿），又重置卷积状态把湿信号尾巴截断（变小 / 断续）。

- **上游原意图**：组件说明里写着 "update convolution object to **maximize performance**"
  —— 所以这里的块长变化是**性能优化触发器**，不是正确性要求：
  `FFTConvolver2x2Process` 以输入 FIFO 逐块消化（`while (processed < len)`），
  任意 `len` 都输出正确 —— 所以**不重建也不会牺牲正确性**，只需消除抖动。

- **修改**：把重建条件改为**量级滞回** —— 仅当块长跨越 2 倍（`n >= old*2 || old >= n*2`，
  含 `old == 0` 首次）时才重建。`blockSize` 仍照常更新（被 `selectConvPartitions` 等读取），
  只是不再因此触发重建。

- **验收**：`test/smoke/smoke_ir_block_jitter.py`（已挂 runner）—— 抖动块长时中位耗时放大 < 3×
  且输出 RMS 偏差 < 2%；移除 P-008 后该用例报「中位耗时放大 26.7x —— 卷积器仍在重建」。

## P-009 jdspController.c — 取消容量内块长变化的卷积器重建（P-008 的残留修复，2026-10-12）

- **位置**：`jdspController.c` 的 `pfloat32Multiplexed()` 内 `if (jdsp->blockSize != n)` 分支
- **病因**：P-008 的 2 倍量级滞回仍允许大幅可用帧变化触发重建。WASAPI 可用帧数可以从
  接近满块跌到不足一半，例如 `1024 → 512`，于是仍会周期性析构并重建全部卷积器。
  实测（0.5s / 48kHz IR，`test/smoke/smoke_ir_block_jitter.py`）：
  `1024/512` 中位耗时放大约 20 倍，输出 RMS 只剩约 0.43。
- **修改**：只在真正扩大卷积器容量（`oldBlockSizeMax < n`）或首次初始化时才重建。
  `jdsp->blockSize` 仍照常更新，但它不再是触发重建的充分条件。
- **验收**：回归用例新增 `1024/500` 与 `1024/300` 两种大幅块长变化，中位耗时放大 < 3×；
  用临时屏蔽重建触发条件的版本验证该用例仍会变红。