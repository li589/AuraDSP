# engine/legacy/ 补丁登记（PATCHES.md）

> 铁律 §3.3：上游源码原则上原样整合；确需扩展时打 `[PATCHED-AuraDSP P-xxx]` 标记补丁，
> 逐条登记于本文件（位置 / 动机 / 影响面 / 上游同步冲突风险）。禁止无登记的隐式修改。
>
> **编号是唯一真相源**（D6，2026-10-24）：`P-NNN` 单调递增、永不复用，每条在下方有
> `## P-NNN` 章节。工程专项代号（`B1-c` / `D7` / `Z13` / `M3.5-c` …）一律**降级为别名**，
> 写在编号之后（如 `P-018 B1-c`），只用于和审查报告章节对照，**不再单独充当编号**。
> 门禁 `tools/bin/patch_id_scan.py`（随 `smoke_d6_patch_ids.py` 运行）强制三件事：
> 每个代码标记必须紧跟 `P-\d{3}`；该编号必须在本文件有登记；同一别名不得映射到两个编号。

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

## P-003 — 保留编号：LiveProg 编译错误行列号 vendor 补丁尚未落地

- **状态**：该编号已在 `docs/UI-六页架构与M3.5重排序方案.md:66、75`
  中规划为二期工作，源码中暂无对应补丁。
- **登记目的**：避免把编号空缺误读为登记遗漏。

## P-004 jdsp_header.h + jdspController.c — 表驱动处理链（2026-10-09）

- **位置**：
  `JDSPChainItem`、`chain[16]`、`chainLen`、`JamesDSPRebuildChain`；
  12 个 stage 封装和默认处理顺序。
- **内容**：
  每个 stage 的 enabled 判断收进对应 stage 函数；
  `graph.order` 必须恰好包含全部 12 个 stage 各一次，否则拒绝并且保持原表；
  convolver/ddc/liveprog 逐段加解锁。
- **行为影响**：
  输出级和处理顺序可重建，非法顺序不会部分生效。
- **上游同步冲突风险**：中（处理主循环结构已改，合并上游改动时需要人工核对）。

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

- **位置**：MultimodalEQ 新增 convB / activeConv / convProcCount / convSwapProc；
  MultimodalEqualizerConstructor 与 Destructor 增删 convB 的 Init/Free；
  MultimodalEqualizerAxisInterpolation 改为重建到非活动实例并原子换指针；
  MultimodalEqualizerProcess 改用 activeConv
- **症状**：操作 EQ 时爆音。eq.curve 经 auradsp_set_param 在驱动 WASAPI 的线程上
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
- **改动**：mEQ 内预分配 conv / convB 两个卷积器 + activeConv 指针。
  控制线程在非活动实例上完成 IR 构建与刷新，随后换指针；
  音频线程块首读一次指针即切到新 IR，块内不再触碰换出的实例
- **生命周期**：两实例均内嵌于 mEQ，由 MultimodalEqualizerDestructor 统一释放，
  **不存在跨线程释放**
- **在途守卫**：convProcCount 由音频线程递增，convSwapProc 记录上次换出时的快照；
  换出后需再跑满 1 块才允许把该实例重新投入重建，
  避免与换出瞬间尚未返回的那次 Process 调用竞争
- **convState 未双缓冲**：已查明 FFTConvolver2x2RefreshImpulseResponse(conv1, conv2, ...)
  中 conv1 仅用作 FFT 暂存（写 _fftBuffer、读 bit/sine），IR 段不更新；
  只有 conv2 才是真正的 IR 存储。故无需为其引入第二份
- **兼容性**：外部调用方无需改动，auradsp_set_param("eq.curve") 语义不变；
  operatingMode != 0 的 IIR 分支未触及

## P-007 multimodalEQ.c — EQ 频率轴按实际 Nyquist 收尾（2026-10-10）

- **位置**：两处 jdsp->mEQ.freq[NUMPTS + 1] = 24000.0
  （MultimodalEqualizerConstructor 与 MultimodalEqualizerAxisInterpolation）
- **症状**：采样率低于 48kHz 时，EQ 曲线最末端锚点超过 Nyquist。
  44.1kHz 下 Nyquist 为 22050Hz，硬编码的 24000 越界。
- **改动**：改为 (double)jdsp->fs * 0.5，按实际采样率取 Nyquist。
- **配套**：P-006 已把 auradsp_engine.cpp 侧 eq.curve 的频点也按
  sample_rate * 0.5 钳位，两端一致。
- **兼容性**：freq[NUMPTS]（用户最末点）已由引擎侧钳到 
yquist * 0.999，
  故 freq[NUMPTS] < fs * 0.5 恒成立，单调性不被破坏。

## P-008 jdspController.c — 块长抖动抑制：不再无谓重建卷积器（电平抖动 / 卡顿修复，2026-10-12）

- **位置**：`jdspController.c` 的 `pfloat32Multiplexed()` 内 `if (jdsp->blockSize != n)` 分支
- **病因**：只要块长变化，就无条件调 `JamesDSPRefreshConvolutions()` →
  `Convolver1DLoadImpulseResponse(updateOld=0)` → 析构并重建全部卷积器
  （重做全 IR 的 FFT + 分段选择）。而 AuraDSP 的 WASAPI 泵传入
  `n = min(avail, max_block)`，`avail` 随 padding 逐轮抖动，于是**几乎每轮都重建**。
  实测（`tools/probe/probe_ir_stability.py`，0.5s / 48kHz IR）：

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
## P-010 jdsp_header.h + jdspController.c — 每效果输出增益门 + 自动增益补偿（2026-10-13）

- **位置**：jdsp_header.h 的 JamesDSPLib 结构体（P-004 的 chain/stagePeak 段后）、
  jdspController.c 的 stage 封装与 setter 区。
- **功能**：为 vendor 链内的 tube/comp/bass/eq 四个效果提供
  (a) 输出增益门（fxOutGain，线性，控制线程写/RT 读，x86 对齐 float 原子），
  (b) 自动增益补偿 leveler（fxAutoGain 开关 + 平滑 RMS 比：输入/输出各 5% 每块平滑，
  补偿增益 10% 每块，±12dB 限幅），全部在对应 stage 包装器内效果处理后原位应用。
- **RT 安全**：stage_rms/stage_apply_fx_gain 纯乘加，无分配无锁；fxAG* 状态 RT 独占；
  开关切换时控制线程重置平滑状态（JamesDSPSetFxAutoGain）。
- **新增接口**：JamesDSPSetFxOutGain / JamesDSPSetFxAutoGain / JamesDSPInitFxGains
  （后者在引擎 create 的 JamesDSPInit 后调用，默认输出增益 1.0、自动补偿关）。
- **配合方**：auradsp_engine.cpp 的 bass/eq/tube/comp.outgain|autogain 参数；
  reverb 的增益/补偿在引擎侧 Freeverb（M5-c，非 vendor）实现，不占 vendor 槽。
- **验收**：test/smoke/smoke_fx_gain.py（输出增益 dB→线性倍率精确命中；自动补偿收敛到输入响度）。
## P-011 jdsp_header.h + Effects/vacuumTube.c — 电子管音色/干湿混合/输出补偿（2026-10-13）

- **位置**：jdsp_header.h 的 VacuumTube 结构体（+character/drywet/outcomp/tapeLp[2]）、
  setter 声明区；vacuumTube.c 的 VTInit/VTProcess/新 setter。
- **功能**：(a) character 0 Triode（旧行为逐位一致）/1 Pentode（谐波x1.8+trim 0.8）/
  2 Tape（谐波x0.5+湿信号一阶 HF 阻尼 coef 0.5+trim 1.05）；
  (b) drywet 干湿混合（0=干声直通，1=全湿=旧行为；in-place 别名安全，dry 取当期输入样点）；
  (c) outcomp 输出补偿 dB（±12，只作用于湿信号，块首一次 pow）。
- **RT 安全**：查表分支+乘加+自有状态，无分配无锁无 syscall；控制线程写对齐 int/float
  （与既有 pregain 同模式）；VTInit 只清 tapeLp 不碰用户值（开关不丢档）。
- **新增接口**：VacuumTubeSetCharacter / VacuumTubeSetDryWet / VacuumTubeSetOutComp。
- **配合方**：engine 的 tube.style|mix|compensation 参数（apply_tube 每次推送，create 即默认全湿 0dB）；
  默认 drywet 由引擎推送 1.0（vendor 零初始化为 0=干声直通，fail-open 安全）。
- **验收**：test/smoke/smoke_tube.py（谐波谱随 style 可测变化；mix=0约等于直通；compensation 电平精确命中；
  三档 RMS 正负1dB 内响度中性）。

## P-012 jdsp_header.h + jdspController.c — 输出限幅器总开关（2026-10-15）

- **位置**：`JamesDSPLib` 加 `int limiterEnabled`（`[PATCHED-AuraDSP P-012]`）；
  `JamesDSPInit` 内（memset 之后、JLimiterInit 之旁）置 1；
  `stage_output` 包络增益分支 gated（关时 `gR=1.0`，只做 postGain）。
- **动机**：`limiter.enable` 此前只存引擎侧标志、无任何落地——UI 开关是摆设，
  且延迟上报（engine_chain 按此 bit 加 2ms）与实际行为脱节。
- **行为影响**：默认 1，与上游逐位一致（初始化顺序：memset→置1，无 P-005 式踩踏）；
  关时跳过包络跟踪与增益衰减，postGain 照常。
- **配合方**：`auradsp_engine.cpp` 的 `limiter.enable` 分支同步写 vendor 标志。
- **上游同步冲突风险**：低（加字段 + 单函数分支；上游若重构 stage_output 需人工合并）。
- **验收**：热信号过载干湿对比（见 smoke_limiter.py，下述）。

## P-013 jdspController.c + jdsp_header.h — 上层效果器 id 列表过滤层（2026-10-16）

- **位置**：`jdspController.c` 新增 `JamesDSPFilterVendorOrder()`（`JamesDSPRebuildChain` 之后）；
  `jdsp_header.h` 对应 `extern` 声明（`[PATCHED-AuraDSP P-013]`）。
- **动机**：App 的「处理顺序」页下发的是**全量**效果器 id（19 个，含 gate/filter/dyneq/
  bassmono/haas/exciter/loudness 七个自研 stage，它们在引擎自己的 `process_stereo_chain` 上，
  不归 vendor 链管）。原调用方把这份原样喂给 `JamesDSPRebuildChain`，而后者只认
  `kAuraStages` 的 12 个 id 且要求「恰好各一次」→ 任何来自 App 的载荷都必然
  `found<0` 返回 -1：用户拖拽的顺序被**静默丢弃**，引擎永远跑默认序，
  而 UI 显示的顺序与实际执行不一致。
- **内容**：保序抽取已知 id、去重、丢弃未知 id、容忍首尾空白；`output` 位置由本函数
  钉死在末尾（输入里出现也一律跳过后再追加，否则会被吞掉、过滤结果只剩 11 个 id）。
  集合仍不完整时交由 `JamesDSPRebuildChain` 按原语义拒绝。
- **行为影响**：`ids=NULL`（默认序）路径完全不变；纯 12-id 合法列表过滤后逐字节相同；
  新增的是「含未知/重复 id 的列表也能被正确消化」这一能力。
- **配合方**：`engine/auradsp_engine.cpp` 的 `graph.order` 分支先过本函数再重建链。
- **上游同步冲突风险**：低（纯新增函数 + 一条 extern，不改任何既有逻辑）。
- **验收**：`test/smoke/smoke_graph_order.py` —— App 19-id 载荷 rc=-1→0；
  eq 移到 liveprog 之后峰值 1.0→3.198（证明重排真实生效，非纸面接受）。

## P-014 liveprogWrapper.c — 迁移后路径注释纠偏与标记补编号（2026-10-16）

- **位置**：`jdsp/Effects/liveprogWrapper.c` `LiveProgLoadCode()` 内 P-001 注释块
  （原 L46-L49）。
- **动机**：Phase 1 收编（`vendor/libjamesdsp` → `engine/legacy/`）后，注释内指引路径
  `core/desktop/vendor-src/libjamesdsp/PATCHES.md` 失效；且 P-001 原标记只有日期、
  缺 `P-xxx` 编号，不符合登记簿铁律的双要素格式。
- **内容**：注释路径改为 `engine/legacy/PATCHES.md` 并追加
  `[PATCHED-AuraDSP 2026-10-16 P-014]`；P-001 标记补编号为
  `[PATCHED-AuraDSP 2026-10-09 P-001]`。纯注释，无生成代码差异。
- **行为影响**：无（comment-only）。
- **上游同步冲突风险**：低（单注释块；上游若重写 `LiveProgLoadCode` 需人工合并）。
- **验收**：`git diff` 仅注释行；引擎重建 + `python test/runner.py --smoke` 全绿。
- **同日登记簿自维护**（随本条一并落地，不另占编号）：
  ① 铁律模板统一为双要素 `[PATCHED-AuraDSP <日期> P-xxx]`
  （消除与 `engine/AGENT.md` §4 的格式矛盾——2026-10-16 全局审查 m1 根因）；
  ② 清理 P-006/P-007/P-010 条目内历史反斜杠转义事故遗留的控制字符
  （BEL/BS/FF/TAB 共 15 字节）及 P-013 段混合行尾（20 处裸 LF），
  按源码语义复原为 `activeConv`/`auradsp_*`/`fxOutGain`/`fxAutoGain`/`fxAG*`/
  `bit/sine`/`freq[NUMPTS]`/`test/smoke/...`；
  ③ 文件标题由 `vendor/` 更正为 `engine/legacy/`。

## P-015 stereoEnhancement.c — 平滑等功率增益补偿（2026-10-17）

- **位置**：`jdsp/Effects/stereoEnhancement.c` `StereoEnhancementSetParam`。
- **动机**：原算法在 `mix=0.5` 处硬性将输出增益放大至 2.0 倍 (+6 dB)，导致用户拖动立体声展宽滑块时音量剧烈暴冲暴跌，体验失真（被误解为音量调节器）。
- **内容**：采用平滑抛物线等功率增益补偿 `1.0f + 0.75f * (x * (1.0f - x))`，在 0.5 处温和补偿约 +1.4 dB 以弥补中央直达声能量分散，两端平滑归一到 1.0。
- **行为影响**：消除 +6dB 音量突跳，立体声展宽调节过程总声能主观保持恒定。
- **上游同步冲突风险**：低（单函数 4 行修改）。
## P-016 B1 liveprogWrapper.c + jdspController.c + jdsp_header.h — liveprog 影子 VM 编译，RT 零锁等待（2026-10-24）

- **位置**：`jdsp/Effects/liveprogWrapper.c` 全文件重写（影子槽编译 + 原子换指针）；
  `jdspController.c` `stage_liveprog` enabled 判断内移 + `kAuraStages` liveprog lock 1→0；
  `jdsp_header.h` `LiveProg` 加 `retiredAt`、`JamesDSPLib` 的 `eel` 值改指针 +
  新增 `eelSlots[3]`/`eelProcCount`/`eelSwapProc`/`eelInFlight`、新增 `LiveProgUnload` 声明；
  `engine/chain/engine_chain.cpp` `lp_refresh_sliders` 适配指针；`engine/engine_param_table.h`
  `set_liveprog_unload` 改走 API（不再越层写字段）。
- **动机**（全量审查 B1/P0）：原 `LiveProgStringParser` 持 `jdsp_lock` 做
  `NSEEL_code_compile ×2`（大脚本实测 ~26ms，用户自述可达 ≥2s），而 RT 的
  `stage_liveprog` 每块取同一把锁——编译期间 RT 在 `EnterCriticalSection` 上
  无限期等待（无超时/无优先级继承）⇒ 整段音频卡死，即「加载脚本时卡顿」根因。
  Z13 修过同一把锁的数据竞争，但没修**等待时长**。
- **设计**（P-006 mEQ 双缓冲同范式）：3 个预分配 LiveProg 槽（各含独立 NSEEL VM），
  `jdsp->eel` 指向活动快照；控制线程编译进非活动影子槽后原子换指针
  （x86-64 对齐指针存即原子；RT 块首只读一次）。在途守卫双条件任一满足即可复用
  换下的槽：① `eelInFlight == 0`（RT 入口/出口原子增减，证明无在途调用持有旧
  快照——覆盖音频停流时 `eelProcCount` 冻结导致连续加载全部「引擎忙」的可用性洞）；
  ② `eelProcCount >= retiredAt`（换下后跑满 1 块）。两条件皆不满足时有界等待
  500ms 墙钟（`Sleep(1)` 实际粒度 ~5-15ms，按时间收敛而非迭代计数），仍无槽返回
  -4；绝不退化到活动槽原地编译（UAF）。
- **行为影响**：① 加载/重载脚本期间 RT 零阻塞（压测：216 个编译窗口内 RT 产出
  68k+ 块、最大块 0.3-1.5ms vs pre-B1 总产出 400 块、最大块 ~50ms）；
  ② 编译失败时**旧脚本继续运行**（原实现先清旧 code 再编译，失败即静默停效）；
  ③ `liveprog.enable=0` 期间块边界仍推进守卫计数（`stage_liveprog` 恒调用
  `LiveProgProcess`，enabled 判断内移）；④ `liveprog.unload` 语义不变
  （经 `LiveProgUnload` 置活动快照 `compileSucessfully=0`，单次 int 写 x86 原子）。
- **RT 安全论证**：RT 只读 `jdsp->eel`（块首一次）+ 快照内指针字段（换指针后不变），
  唯一可变共享量为 `*vmFs`（srate，单次对齐 float 写）与 `*input1/2`（per-sample
  输入/输出寄存器，本就无锁）——均保持原有 x86 原子级访问语义，未引入新的竞争面。
- **上游同步冲突风险**：中（`liveprogWrapper.c` 为整文件重写，上游若更新需以本版
  为基线人工合并；`LiveProg` 结构体与 `JamesDSPLib` 布局变更需同步）。
- **验收**：`test/smoke/smoke_liveprog_race.py`（新增，runner 已注册）——
  RT×UI 双线程 + 逐块计时 + 编译窗口内产出比 + 旧快照存活语义 + 停流连发加载 +
  有界等待 + 收尾健康，共 17 项断言；反向验证（临时还原 pre-B1 持锁编译）3 项核心
  断言失败（417 块 / 1.6 块每窗口 / 40.8ms 尖峰），证明测试非空转。
  `smoke_liveprog.py` 7 场景全过；全量 python 冒烟 100%；Dart 436/436（串行）；
  flutter analyze 零问题。
- **后续（B1 同法未竟项）**：comp（`CompressorSetParam(forceRefresh=1)` 全量重置，
  Z13 锁保持）与 ddc（`DDCRefresh` free+换 `sosPointer`/`usedSOSCount` 两字段非原子，
  Z14 锁保持）仍持 `jdsp_lock`——两者持锁时长亚毫秒~毫秒级（非秒级），且与
  `JamesDSPSetSampleRate` 的全效果重建共用该锁，列为 B1-b/B1-c 后续专项。

## P-017 B1-b Effects/vdc.c + jdspController.c + jdsp_header.h — ddc 影子视图 + countChars 栈溢出修复（2026-10-24）

- **位置**：`jdsp/Effects/vdc.c` 尾部重写（`countChars` 递归改迭代 +
  `PeakingFilterResampler` 双 malloc 泄漏修复 + 影子视图化）；
  `jdspController.c` `stage_ddc` 恒调 `DDCProcess`（enabled 内移）+
  `kAuraStages` ddc lock 1→0；`jdsp_header.h` `DDC` 结构体缩为仅 `oldFile`、
  新增 `DDCView{sosPointer,usedSOSCount,retiredAt}`/`AURA_DDC_SLOTS(3)`/
  `ddcActive`/`ddcProcCount`/`ddcInFlight`；`engine/engine_param_table.h`
  `set_ddc_load`/`set_ddc_enable` 去 `jdsp_lock` + -4 独立文案；
  `engine/legacy/jamesdsp.c` cmd 1212 路径去锁（Z14 锁不再需要）。
- **动机**（B1 条目预告的 ddc 专项 + 本次新发现的 P0）：① 原
  `DDCStringParser` 持 `jdsp_lock` 解析（大文件 ~7-9ms），`stage_ddc`
  每块取同一把锁——解析期间 RT 排队卡顿（同 B1-a 根因）；② 真正的杀手：
  `countChars` 按字符**递归**计数（深度=剩余串长），VDC 文件 >~107KB 即
  栈溢出崩溃——DDC 工具导出的巨型文件加载必崩；③ `PeakingFilterResampler`
  双 malloc 泄漏（第一次分配被第二次覆盖后永不释放）。
- **设计**（B1-a 同范式）：3 个预分配视图槽，`jdsp->ddcActive` 指向活动视图；
  控制线程解析→装填非活动槽→原子换指针（x86-64 对齐指针存即原子；RT 块首
  只读一次）。在途守卫双条件任一满足即可复用换下的槽：① `ddcInFlight == 0`
  （RT 入口/出口原子增减——覆盖音频停流时 `ddcProcCount` 冻结导致连续加载
  全部「引擎忙」的可用性洞）；② `ddcProcCount >= retiredAt`（换下后跑满
  1 块）。槽内旧数组仅在复用本槽时释放（彼时守卫已保证无 RT 引用）；
  有界等待 500ms 墙钟，仍无槽返回 -4；解析失败保留旧视图（加载失败不静音
  正在生效的校正，同 B1-a）。
- **countChars 修复**：递归→迭代。1.3MB/20000 段 VDC 实测 32.6ms 解析
  不崩；`smoke_ddc_race.py` 回归线 ~260KB（>原崩溃阈值 107KB）。
- **行为影响**：① 大 VDC 解析期间 RT 零阻塞（4s 压测：~500 个解析窗口内
  RT 产出 49k+ 块、99 块/窗、最大块 0.37ms vs pre-B1-b 12.6 块/窗、最大块
  9.41ms=解析持锁时长）；② 解析窗口内旧视图持续生效、换指针后新视图恰好在
  块边界切入（during@old=3/3、after@new=32/32）；③ 音频停流时连续加载
  5 次全部成功（≤8ms/次，`ddcInFlight==0` 守卫；pre-B1 设计下第 3 次起
  计数冻结全「引擎忙」）。
- **测试时间戳归属教训**：采样时间戳若取在 `process` 返回后，「swap 前开始
  （读旧视图指针）、t1 后返回」的跨界块会被误记入 after 窗口带旧增益——
  B1-b 首跑即踩（after=[0.1..0.2] 假失败）。改为**块首时间戳**（=视图指针
  读取时刻）+ during 窗口 1ms 前向裕量（swap 贴近 t1、尾部仅 µs 级），
  两侧断言与 swap 时刻完全解耦，确定性 100%。
- **验收**：`smoke_ddc_race.py` 扩展四段全绿（大文件防崩 / RT 不阻塞 /
  旧视图存活 / 停流连发）；反向验证（临时还原 pre-B1-b 持锁解析 +
  stage lock=1）**3 项核心断言失败**：12.6 块/窗（<30）、最大块 9.41ms
  （≥6ms）、解析期块被锁挡过 swap 点（during@old=0/1）——证明测试非空转。
  阈值标定：≥30/窗（修复后 3.3× 余量；RT 迭代 ~82µs 解释器主导，跨机稳定）、
  <6ms（修复后 16× 余量，且 > CPython GIL 切换间隔 5ms，单次解释器交接
  最多污染 ~5ms 不误报）。`smoke_ddc.py` 2970 加载 0 失败；全量 python
  冒烟 100%；Dart 436/436（串行，干净重跑）；flutter analyze 零问题。
- **契约门禁**：-4 文案按 Part H reason-token 契约三方登记——新 token
  `engine busy`（`kEngineReasonTokens` + `errEngineBusy` 三语 arb +
  引擎侧字面量改为 `<subject>: <token>[ (detail)]` 合规形）；
  `gen_param_contract.py` 再生 fixture（仅哨兵行 param_table 1179→1172）。
  注意：Part H 扫描器只匹配 `set_error(h, "..."` 直接字面量，三元形式
  `set_error(h, cond ? "..." : "...")` 天然绕过扫描——本次主动合规，
  该盲区留待后续专项收口。
- **上游同步冲突风险**：中高（vdc.c 尾部重写 + `DDC` 结构体缩容，上游若
  更新需以本版为基线人工合并）。
- **后续（B1 同法未竟项）**：仅剩 comp（`CompressorSetParam(forceRefresh=1)`
  全量重置，Z13 锁保持）——B1-c。

## P-018 B1-c Effects/dynamic.c + jdspController.c + jdsp_header.h + engine/chain/engine_chain.cpp — comp 影子槽双缓冲，Z13 锁收口（2026-10-24）

- **位置**：`jdsp/Effects/dynamic.c` Compressor 段重写（`CompSlot` 选槽/
  状态携带集/`CompressorCommit` 影子提交）；`jdspController.c` `stage_comp`
  恒调 `CompressorProcess`（enabled 内移）+ `kAuraStages` comp lock 1→0；
  `jdsp_header.h` `FFTCompander comp` 单体 → `CompSlot compSlots[2]` +
  `compActive`/`compProcCount`/`compSwapProc`/`compInFlight`；
  `engine/chain/engine_chain.cpp` `apply_comp` 去 `jdsp_lock` 改单次
  `CompressorCommit`（参数+曲线一次构建一次换指针）。
- **动机**（B1 条目预告的 comp 专项）：`CompressorSetParam(forceRefresh=1)`
  持 `jdsp_lock` 做 `FFTCompanderInit` 全量重算（默认 tfres=1 CWT 为重档），
  `stage_comp` 每块取同一把锁——Z13（2026-10-23）用互斥关闭了「拖滑块即崩」
  的数据竞争，但持锁时长即重建时长：参数频调时 RT 反复阻塞在
  `EnterCriticalSection`（反向验证实测单块尖峰 **342ms**），即用户抱怨的
  「调参卡顿」。只修竞争没修等待时长，B1-c 收口。
- **设计**（B1-a/B1-b 同范式）：2 个预分配 `CompSlot`（1 活动 + 1 影子——
  控制侧构建由 ctrl_mutex 串行，单 RT 线程至多一个 comp 调用在途即至多
  持有一个槽，一个影子槽足够；3 槽只增内存不增可用性）。控制线程
  `CompressorCommit`：选槽（在途守卫双条件：`compInFlight==0` 或
  `compProcCount>=retiredAt`）→ 装载 → 构建（Init/参数/曲线）→ 原子换
  `compActive`。RT 块首只读一次指针，块内不碰换出实例。有界等待 500ms
  墙钟，仍无槽返回 -4（旧快照继续生效），绝不退化活动槽原地重建（UAF）。
- **状态携带集 + 验证重试**（B1-c 独有，B1-a/b 无需携带状态）：compander
  是**有状态滤波器**，影子必须延续 RT 演化状态（否则每次调参都可闻重启）。
  携带集 = RT 演化且构建不重写的字段：tfres>=3 平滑/斜坡/合成滤波器状态
  （`diffGain`/`interpolatedGain`/`updateIdx`/`*step`/`z1_*`/`z2_*`）、
  STFT 在途簿记 + 环形缓冲 + `oldBuf` 谱包络、`freq2`/`gains2` 曲线定义。
  拷贝正确性由验证重试保证：RT 只写活动槽，若携带期间有 comp 调用进入/
  离开（`compInFlight` 非零或 `compProcCount` 变化）则作废重拷——影子槽
  写入与 RT 零交集，重拷无副作用。Init 构建跳过 1.19MB 全量拷贝（Init 重算
  全部表/簿记，只带 ~130KB 携带集）；非 Init 构建（legacy SetGain 路径）
  才全量带入——表为 RT 只读故源稳定，scratch 撕裂无害（每帧写前必读，
  与现实现 Init 后残留上帧数据同类不变量）。
- **等待策略教训**：首版纯 `Sleep(1)` 重试（B1-a/b 同款）在 comp 上翻车——
  comp 是重档效果（默认 CWT，单块 C 段占比高），RT 块间隙窄，`Sleep(1)`
  实际粒度 5-15ms 把控制线程拖到 ~285ms/次提交。改**自旋优先**
  （`YieldProcessor` 6 万轮 ≈3ms 预算，超预算回落 Sleep），提交回到
  ~1.4ms/次。教训：有界等待的自旋/睡眠配比须按持锁方（此处为 RT 块间隙）
  的时长分布标定，不能照搬轻档效果的参数。
- **自洽性修正**：`CompressorSetParam` 包装改为 applyCurve=1——携带集不含
  `DREmult`/`headRoomdB`，若 Init 改了 `procUpTo` 而曲线不重算，换入后 RT
  将按陈旧曲线运行；原实现靠 SetParam+SetGain 同一把锁内连续执行掩盖了
  该窗口，影子方案下必须让每次提交自洽。
- **行为影响**：① RT 永不因 comp 取锁（压测：3297-3570 块/s、最大块
  1.2-1.4ms vs Z13 反向 613 块/s、最大块 342ms）；② 调参吞吐恢复
  （uiA 633 sweeps vs 首版影子 3 sweeps）；③ 参数/曲线一次构建一次换指针，
  无中间态窗口；④ comp 停用期间在途计数恒走（块边界放行影子槽复用）。
- **验收**：`smoke_comp_race.py` 扩展 RT 不阻塞两项 + 原有 Z13 竞争断言
  全绿；反向验证（临时还原 comp lock=1 + apply_comp 持锁）**两项新断言
  失败**：613 块/s（<800）、最大块 342ms（≥10ms）——证明非空转。阈值：
  ≥800 块/s（修复后 4× 余量）、<10ms（修复后 7× 余量，且远大于 CPython
  GIL 切换间隔 5ms 不误报）。`smoke_comp.py` 12 项全过；全量 python
  冒烟 100%。
- **契约门禁**：`CompressorCommit` 的 -4 复用 B1-b 已登记的 `engine busy`
  reason-token 口径（`apply_comp` void 契约不上抛，p-struct 已存新值，
  下一次任意 comp.* 变更补上——-4 需 RT 卡在 comp 内 >500ms，实测不可达）。
  `gen_param_contract.py` 指纹不覆盖 dynamic.c/jdspController.c/
  engine_chain.cpp，fixture 无需再生。
- **上游同步冲突风险**：高（`FFTCompander comp` 单体字段被替换为槽数组 +
  `Compressor*` 全段重写，上游若更新需以本版为基线人工合并）。
- **后续（B1 同法未竟项）**：无——B1 系列（liveprog/ddc/comp）全部收口。
  `JamesDSPSetSampleRate` 全效果重建仍持 `jdsp_lock`（RT 的 convolver
  stage 亦持锁），属同一把锁的剩余暴露面，列后续评估。

## P-019 B1-d Effects/dynamic.c + jdsp_header.h + engine/chain/engine_chain.cpp — comp 启动缺额，不再原声直通（2026-10-24）

- **位置**：`Effects/dynamic.c`（新增 `CompressorStartupDeficit` / `comp_process_chunk`，
  重写 `FFTCompanderProcessSamples`，`FFTCompanderInit` 增 `mOutputDeficit = -1` 与输入/
  重叠缓冲清零）；`jdsp_header.h`（`FFTCompander` 增 `mOutputDeficit`，
  `MAX_OUTPUT_BUFFERS_DRS` 2→4）；`engine/chain/engine_chain.cpp`（`compute_latency` 计入缺额）；
  `engine/engine_internal.h`（`kCompLatProfile` 注释重写）。
- **动机**（全量审查后新增专项）：原实现把「本块没产出」当「本块无需改动」——抽干循环在
  `mOutputBufferCount == 0` 时一次都不执行，而 `in == out` 原地处理意味着输出缓冲里仍是
  **未处理原声**。于是管线上电前 `ovpLen` 个样本是无压缩直通。块长与 hop 不整除时
  （441 帧块 7 次、500 帧块 2 次）还会**周期性复发**——旧实现靠上述"泄漏"意外维持
  收支平衡，任何一侧改动都会让洞露出来。
- **内容**：启动先以静音吐出 `D = ovpLen − gcd(ovpLen, 完整工作块长)` 个样本（OLA 爬升段
  本就是静音），此后 `可用输出 = D − (I mod ovpLen) ≥ 0` 恒成立；抽干不足时补静音。
  `CompressorProcess` 取消预切块，整块交给 `FFTCompanderProcessSamples`（单次至多一个 hop，
  防 FIFO 越界）。
- **行为影响**：延迟 `= (fftLen − ovpLen) + D`，块长整除 hop 时 D=0。实测 48k/tf=1：
  blk512→3584、blk256→3840、blk441→4095 帧。D 必须计入上报，否则报的比听的小。
- **验收**：`test/smoke/smoke_b1d_comp_startup.py`（82 断言五层：源码不变式 / 启动段精确静音 /
  稳态无饥饿洞 / 脉冲位移 == frames+D / 上报==实测）。反向验证（还原旧抽干逻辑重建 DLL）：
  核心断言判红 23 项。
- **上游同步冲突风险**：中高（`FFTCompanderProcessSamples` 整段重写，上游若更新需以本版为
  基线人工合并；`CompressorProcess` 的预切块已删除）。

## P-020 B4 jdsp_header.h + jdspController.c + Effects/dynamic.c + engine/chain/engine_chain.cpp — 调用级 stage 门控（RT 不再改写 vendor 开关）（2026-10-24）

- **位置**：`jdsp_header.h`（`AuraStageGates` 结构 + `JDSPStageFn` 签名 +
  `CompressorProcess` / `JamesDSPProcessMultiplexedStageSet` 声明）；
  `jdspController.c`（12 个 stage fn 增 gates 形参，tube/comp/bass/eq/arbmag/
  output 读调用级门控，其余忽略；两处链循环传 NULL）；
  `Effects/dynamic.c`（`CompressorProcess` 增 `enabled` 形参，不再读全局
  `compEnabled`）；`engine/chain/engine_chain.cpp`（MC Category B 段删 5 组
  save/写0/restore，改填 gates）。
- **动机**（审查 B4）：MC Category B 段在**音频线程**内 save→写 0→restore
  `tubeEnabled`/`limiterEnabled`/`compEnabled`/`equalizerEnabled`/
  `arbitraryMagEnabled`。这些字段由控制线程（`VacuumTubeEnable/Disable`、
  `CompressorEnable/Disable`、`MultimodalEQEnable`、`ArbitraryResponse…`）
  随时改写——用户操作落在 save 与 restore 之间就被 restore **静默回滚**
  （界面显示开着、实际关了）；且字段本身非原子。
- **为什么不只是「改传 ids」**：`ids` 只表达「跑哪些 stage」，表达不了本段
  真正需要的两件事——① tube 必须**仍参与峰值采样**（viz stage 0 电平靠它
  采样）但不执行；② comp/limiter 必须「被调用但不生效」（comp 每块必过以
  推进 B1-c 在途计数；`output` 段的 postGain 必须照跑、只跳 limiter）。
- **设计**：`AuraStageGates` 六字段 `signed char`，`-1` = 沿用全局开关。
  NULL = 全链全局开关（stereo 路径与 `JamesDSPProcess` 全部传 NULL，行为
  零变化）。RT 只读全局开关，绝不写。
- **行为等价性**：MC ch=6 全效果参与、两种 comp/eq mask 配置（覆盖 FL/FR /
  只覆盖 ch2-3）下 24 块输出的 sumsq/sumabs/maxabs/末 4 样本重构前后
  **逐位相同**。
- **验收**：新增 `test/smoke/smoke_rt_vendor_flags.py`（三层：engine/chain
  源码不变式「无 RT 侧 vendor 开关写入 / 无 save-restore 五连」+ comp FL/FR
  mask 门控接线 + 60 轮竞态）。反向验证（还原 save/写0/restore 重建）：源码
  不变式直接判红，竞态门禁 60 轮中 16 轮判红（26.7%/轮），修复版 0/60。
- **契约门禁**：`gen_param_contract.py` 指纹不覆盖本组文件，fixture 无需再生；
  `JamesDSPProcessMultiplexedStageSet` / `CompressorProcess` 均不在
  `auradsp_engine.def` 导出表（内部符号），签名变更不触 ABI。
- **上游同步冲突风险**：中高（12 个 stage fn 签名 + 两个函数声明全改，上游若
  更新需以本版为基线人工合并；改动机械、逐处可对照）。

## P-021 B5 jdspController.c + jdsp_header.h — 多声道声道对选择

- **位置**：`jdspController.c` 新增 `stage_selected(const char *ids, const char *id)` 及其在多声道
  处理路径的复用点；`jdsp_header.h` 对应声明区注释。
- **动机**：多声道链里双声道效果器（comp / eq / arbmag）需要按掩码只对**选中的声道对**独立
  处理，而不是把 8 声道整体塞进一套双声道参数。
- **内容**：以逗号分隔的 stage id 表驱动筛选；块长 / ASRC / 交织处理镜像
  `processFloatMultiplexd`，保证同一帧数据在两条路径上相位一致。
- **行为影响**：空表 = 全选（默认路径行为不变）；非空表只跑指定子集。
- **上游同步冲突风险**：低（新增静态函数 + 条件筛选，未改既有 stage 本体）。

## P-022 D7 jdspController.c — ASRC 多相 FIR 抽头数单点定义（2026-10-24）

- **位置**：`jdspController.c` 文件头 `AURADSP_ASRC_TAPS`（64），init 与热切两处调用点引用。
- **动机**（全量审查 D7）：原 init 路径 `asrc_taps = 64`、热切路径 `= 32`，两处都是函数内
  局部 `const`，谁也看不出对方。同一设备"冷启动即 96k"与"48k 起来再热切"会走**不同阶数**的
  抗镜像滤波器——过渡带与群延迟差一倍。
- **内容**：宏单点定义，取 64（init 是默认/质量优先路径；热切的 32 无任何注释，按历史遗留处理）。
- **诚实标注**：Windows 桌面引擎里热切路径不可达——`JamesDSPSetSampleRate` 只被
  `EffectDSPMainCommand`（Android AudioEffect 入口）调用，而后者不在 `.def` 导出表内。
  故本项只有源码级门禁可守。不可达 ≠ 可以不修：Android 侧同源，将来接线立刻生效。
- **验收**：`test/smoke/smoke_d7_asrc_consistency.py`。反向验证判红 46 项。
- **上游同步冲突风险**：低（一处宏 + 两处引用）。

## P-023 M3.5-c jdspController.c + jdsp_header.h — stage 输出峰值采样

- **位置**：`jdspController.c` `JamesDSPProcess` 每个 stage 处理后的采样段（两处）；
  `jdsp_header.h` `stageIdx` 字段注释（0..11 固定 stage ID）。
- **动机**：可视化需要 per-stage 电平，而 vendor 原实现只产出整链峰值。
- **内容**：每 stage 跑完后在 `tmpBuffer` 上取 `max|L|` / `max|R|`，按 `stageIdx` 归位到
  `audioPeaks[]`；`stageIdx` 是固定表，不随链序变化。
- **行为影响**：只读采样，不改音频路径；采样开销为每 stage 一次线性扫描。
- **上游同步冲突风险**：低（插入式采样，与 stage 本体无关）。

## P-024 Z13 jdspController.c — 多声道 RT 入口 honoring per-stage lock

- **位置**：`jdspController.c` 多声道 RT 路径两处（ASRC 分支与直通分支）。
- **动机**：该路径是引擎唯一的 RT 入口，却**完全忽略** `kAuraStages[i].lock`——comp /
  convolver / ddc / liveprog 的控制侧重置与 RT 处理之间零互斥，属数据竞争。
- **内容**：按 stage 的 `lock` 标志成对 `jdsp_lock` / `jdsp_unlock`，与 `JamesDSPProcess`
  的链表锁语义对齐。
- **后续**：B1 / B1-b / B1-c（P-016/017/018）把相关 stage 的 lock 置 0——不是"绕过锁"，
  而是用影子快照 + 原子换指针从根上消除了共享写。
- **上游同步冲突风险**：低（两处成对调用）。

## P-025 P2.4 jdsp_header.h + Effects/dynamic.c — comp 实时增益衰减计量

- **位置**：`jdsp_header.h` `JamesDSPLib.comp_gr` 字段；`Effects/dynamic.c` comp 处理时的
  写入点。
- **动机**：UI 需要显示压缩器当前增益衰减量（GR 表），vendor 原实现没有对外暴露。
- **内容**：`comp_gr`（dB ≥ 0），comp 每次处理时更新，经 viz 帧上报。
- **行为影响**：仅新增只读输出字段，不参与音频计算。
- **上游同步冲突风险**：低（新增字段 + 一处赋值）。

## P-026 E4 engine/chain/engine_chain.cpp — Stage 16 采样点跨模式对齐（2026-10-24）

- **位置**：`engine_chain.cpp` `process_multichannel_chain` 的 Category B 段（stereo 路径 `process_stereo_chain` 无改动）。
- **动机**（审查 E4）：同一 "BassMono" 槽（viz stage 16）两种模式量的不是
  同一链位置——MC 在 `basspsycho` **之后**采样、stereo 在**之前**。切模式时
  该柱跳变，违反「同槽同语义」；且 `auradsp_engine.h` 文档写的是「16: bassmono
  低频单声道输出电平」，采在 basspsycho 之后会把心理声学低音的增益算进
  BassMono 柱，槽名失真。
- **内容**：`sample_stage_peak_mc(h, 16, …)` 挪到 `bassmono_process` 与
  `basspsycho_process` **之间**（`[PATCHED-AuraDSP P-026 E4]` 标记处）。
  选「MC 侧对齐到 bassmono 之后」而不是「stereo 挪到 basspsycho 之后」，
  因为后者会连带改变 stereo 的既有读数语义（该柱一直是 BassMono 输出，
  `smoke_chain_meter.py` 的 20 级表也按此标定），前者只让 MC 向文档语义收敛。
- **行为影响**：MC 模式下 stage 16 读数不再含 basspsycho 增益（bass 开且
  amount>0 时读数变低——那是修掉了虚高）。音频零改动。
- **验收**：`test/smoke/smoke_e4_stage16_crossmode.py`——MC 模式下
  stage 16 读数在 basspsycho 开/关两态下必须相等（采样点在其之前），
  反向验证（还原 pre-fix）该断言判红。
- **上游同步冲突风险**：低（单行移动 + 注释）。

## P-027 E5 engine/plugins/platform/win32/win32_util.cpp — 厂商/版本提取异常路径留痕（2026-10-24）

- **位置**：`win32_util.cpp` 的 `extractVendorFromPath` /
  `extractCompanyFromVersionInfo` / `extractProductVersionFromVersionInfo` /
  `extractVendorFromLegalCopyright` 四处 `catch (...)`。
- **动机**（审查 E5）：四处把"读失败"与"字段不存在"静默合并为空串，
  "没有"与"读失败"不可分——PE 解析抛异常（缓冲分配失败等）与正常缺失
  完全不可观测。
- **内容**：异常路径加 `AURADSP_WARN_S` 留痕（Debug 构建落盘）。**兜底链
  语义刻意不变**：异常仍按缺失继续降级（CompanyName → LegalCopyright →
  上级目录 → "Unknown"）——把异常区分为独立返回态需要给 4 函数 ×3 调用点
  加状态管道，而下游没有任何消费者，P2 不值得。WARN 在 Release 按设计剥离
  （B-1 门禁：Release DLL 零调试串），面向用户的"区分"由兜底链终点
  "Unknown" 呈现。
- **行为影响**：音频与元数据零改动；Debug 构建多 4 条异常路径日志。
- **上游同步冲突风险**：低（纯 catch 体新增）。

## P-028 §7-2 三桥 ABI 协商 — 加载引擎后强校验 auradsp_abi() + *_abi() 导出（2026-10-24）

- **位置**：`core/desktop/windows-drivers/02_voicemeeter_client/VmPumpCore.h`
  （`FnEngAbi` + `kEngineAbiExpected`）、`bridge/asio_bridge/AsioBridge.cpp`、
  `bridge/vaio_bridge/VaioBridge.cpp`、`bridge/vm_bridge/VmBridge.cpp`
  （加载点校验 + `asio_abi`/`vaio_abi`/`vb_abi` 导出）、三桥 `.def`/`.h`、
  `tools/bin/abi_consistency.py`（B4/B5）、`bridge_plugin_ffi.dart`
  （`${prefix}_abi` 可选绑定 + assertBridgeAbi）、三桥 Dart load()。
- **动机**（审查 §7-2）：桥按编译期 viz 帧布局（1600B）做内存透传，引擎 DLL
  若是另一 ABI 版本，同偏移读帧全体字段静默错位；三桥原样照单全收任何
  auradsp_engine.dll，且全目录无一处 auradsp_abi 调用。Dart↔桥之间同样
  没有代际协商——旧桥 DLL 配新 App 时 viz 解析静默出错。
- **内容**：(1) 三桥 TryLoadEngine 成功后解析 auradsp_abi 并与
  kEngineAbiExpected(=2) 强比对——ASIO/VAIO 硬失败（rc -5/-3，note=
  engine-abi-mismatch: bridge=N engine=M；发生在驱动 open 之前），VM 桥
  引擎不可用降级透传（无引擎本就合法）；(2) 三桥新增 `*_abi()` 导出；
  (3) 门禁 B4（kEngineAbiExpected ↔ engine_internal.h AURADSP_ABI 联动）、
  B5（三桥 cpp 必须引用 auradsp_abi，防"清单齐了、校验没了"）；
  (4) Dart 侧 `assertBridgeAbi`：老桥无导出→跳过（协商回落），不符→抛错。
- **行为影响**：音频零改动；仅同代际引擎可过桥引擎门。viz_read 形参名
  out408/out536 更名 out1600（注释纠偏，审查顺手项）。
- **验收**：`test/smoke/smoke_g7_2_bridge_abi.py`——[C] 用 g++ 合成假引擎
  （桩 create/process/destroy，仅 auradsp_abi 可控）：ABI=999 拒绝
  （note=engine-abi-mismatch: bridge=2 engine=999）、ABI=2 放行（证明拒绝
  确由 ABI 门触发）；反向验证（还原 pre-fix 重建）C1 note 断言判红
  （假引擎穿过引擎门进到驱动 open）。
- **上游同步冲突风险**：低（三桥加载点各一小段 + 新增导出，逻辑自包含）。

## P-029 自研 DSP 链的采样率域对齐 —— 系数改用设备率（2026-10-24）

- **位置**：`engine/dsp/dsp_bassmono.cpp`、`dsp_dyneq.cpp`、`dsp_exciter.cpp`、
  `dsp_filter.cpp`、`dsp_gate.cpp`、`dsp_haas.cpp`、`dsp_loudness.cpp`、
  `dsp_psycho.cpp`、`dsp_shelf.cpp`、`dsp_spatial.cpp`（共 23 处 `h->jdsp.fs`
  → `h->sample_rate`）、`engine/chain/engine_chain.cpp`（`arbmag_pool` 的
  IR 设计率同改）。
- **动机**（多声道/采样率细审）：引擎内存在两个采样率域——设备率
  `h->sample_rate`（驱动缓冲实际速率）与工作率 `h->jdsp.fs`（ASRC 之后
  vendor 链的速率，非常见设备率时恒为 48k/44.1k）。vendor 链整体被 ASRC
  包裹（`jdspController.c:1283-1313` DoASRC_fwd → stage 循环 → DoASRC_bwd），
  因此 vendor stage 用 `jdsp->fs` 是自洽的；但**自研链在 ASRC 之外**，
  处理的是设备率样本，却用工作率算系数 → 96k 设备上 EQ 截止频率、门限
  attack/release、Haas 延迟、FDN 尾音整体错位一个采样率倍率。
- **实测**（修复前，`test/smoke/smoke_sr_rate_alignment.py`）：
  自研 filter（LP f0=1000Hz）的 -3dB 频率在 48k/96k/192k 分别为
  1000Hz / **2000Hz（2.00x）** / **3986Hz（3.99x）**；同期 vendor EQ
  对照组在三种设备率下均为 -6.0dB（ASRC 内自洽，证明架构本身没错，
  错的只是跨域的那一侧）。
- **内容**：自研链全部系数改用 `h->sample_rate`（设备率）；保留原有
  fallback（<=0 时取 48000）。`freeverb` 与 `limiter_process_mc` 原本就用
  `h->sample_rate`，本次统一。vendor 侧（`apply_crossfeed`、
  `compute_latency` 的工作率项）**不动**——它们在 ASRC 内，用工作率正确。
- **行为影响**：44.1k/48k 设备率下 `jdsp.fs == sample_rate`，**逐字节
  无变化**；仅非常见设备率（<44.1k 或 >48k，如 32k/96k/192k）改变。
- **验收**：`test/smoke/smoke_sr_rate_alignment.py` 三段全绿（自研 filter
  -3dB 频率三档均为 1000Hz；vendor EQ 对照组不回退；eq.enable 关闭语义）。
  反向验证：还原 pre-fix 行为重建 DLL 后，该脚本的 [A] 96k/192k 与 [C]
  三条**判红**（96k 回到 2000Hz、192k 回到 3986Hz、eq.enable 关闭后仍
  -6.01dB），证明断言非空转。
- **上游同步冲突风险**：低（自研扩展链，不涉及 vendor 源码）。

## P-030 两个静默失效修复 —— eq.enable 关闭语义 + 卷积 IR 声道门卫（2026-10-24）

- **位置**：`engine/chain/engine_chain.cpp`（`apply_eq`）、
  `engine/chain/engine_convolver.cpp`（WAV/FLAC 两处 IR 声道门卫）。
- **动机**（多声道/采样率细审）：
  (1) **eq.enable 开关失效**——上游 `MultimodalEqualizerEnable` 只有
      `if (enable) equalizerEnabled = 1;`，**没有 else 分支**，标志位一旦
      置 1 就永不归零；上游另有 `MultimodalEqualizerDisable` 才做归零，
      但宿主从不调用它。结果用户关闭 EQ 后 EQ 仍在处理音频（实测 96k：
      enable=1 → -6.01dB，enable=0 → -6.01dB，完全不变）。
  (2) **多声道 IR 静默失效**——宿主门卫接受 1..8 声道 IR，但 vendor
      卷积器是立体声对实现，`Convolver1DLoadImpulseResponse` 只有
      1/2/4 声道分支（`convolver1D.c:97/115/133` 与 `:156/174/192`）。
      3/5/6/7/8 声道时分配了 IR 缓冲却无分支命中 → `conv.process` 保持
      NULL，函数仍返回 1（成功）→ 宿主置 `ir_ready=true`、UI 显示"就绪"，
      实际输出**完全没有卷积**。
- **内容**：(1) `apply_eq` 改为分支调用——开态 `MultimodalEqualizerEnable`、
  关态显式 `MultimodalEqualizerDisable`（改宿主而非上游，降低同步冲突）；
  `equalizerForceRefresh` 的消费留在 Enable 分支，关态不消费，下次打开
  时重建一次 IR。(2) IR 声道门卫收紧为 {1,2,4}，其余显式报错
  `convolver.ir: unsupported (channel count must be 1/2/4: stereo-pair
  convolver)`——`unsupported` 已是登记 token（Part H 契约），无需新增登记。
- **行为影响**：eq.enable 关闭现在真正生效（此前是确定的开关失效）；
  3/5/6/7/8 声道 IR 由"静默无效"改为"显式报错"（原本用户会看到
  "就绪"却听不到任何卷积）。
- **验收**：`test/smoke/smoke_sr_rate_alignment.py` 的 [C] 段
  （enable=0 → -0.01dB）；反向验证见 P-029 条目（还原后 [C] 判红）。
- **上游同步冲突风险**：低（仅宿主侧两处调用点与门卫条件）。

## P-031 多声道/采样率细审的 UI 一致性与诚实性修复（2026-10-24）

- **位置**：`features/effects/channel_routing_selector.dart`（pairSemantics +
  成对翻转 + 掩码规范化）、`comp_card.dart` / `eq_card.dart`（传 pairSemantics）、
  `core/state/state_events.dart`（channelsMode 回读消费）、
  `core/state/state_session.dart`（channels.mode 会话回放下发）、
  `loudness_card` 之外的 `bass_card.dart` / `haas_card.dart` /
  `spatial_card.dart` / `reverb_card.dart`（FL/FR-only 标注）、
  `features/settings_page.dart`（采样率设备实际值）、`lib/l10n/*`（三语）。
- **动机**（多声道/采样率细审的 UI 侧发现）：
  (1) comp/eq 的 `*.channels` 掩码在引擎侧是**声道对**语义
      （`(mask & (3<<p0)) == (3<<p0)`，p0=0/2/4/6 → (0,1)(2,3)(4,5)(6,7)），
      而 UI 用逐位勾选的选择器 → 用户勾单个 C 被引擎静默忽略，
      界面却显示"N/8 声道已选"（假开关）。
  (2) `channels.mode` 的镜像与引擎真值永久失联：引擎已回读
      `channelsMode`（audio_isolate.dart:931），但 `state_events.dart`
      从不消费它；且会话恢复不回放下发 → 重启后 UI 显示"离散逐声道"
      而引擎停在默认矩阵模式（多声道策略静默降级）。
  (3) bassmono/haas/spatial/freeverb 永远只作用 FL/FR，卡片无任何标注。
  (4) `spatial.binaural` 开启会完全跳过 `channels.mode`，两处开关互不告知。
  (5) 采样率下拉是**设备请求值**，设备可拒绝并回退，UI 却只高亮所选值；
      桥模式文案称"仅对进程内生效"，实际进程内也不生效。
- **内容**：comp/eq 掩码改「成对翻转 + 掩码规范化」（UI 显示集合 == 引擎
  实际生效集合，穷举 256 掩码验证）；补 `channelsMode` 回读消费与
  `channels.mode` 会话回放下发；四个 FL/FR-only 卡片加标注；binaural 与
  声道模式的互相接管写入 l10n；采样率卡片显示设备实际值；桥模式文案纠偏；
  l10n 三语同步（新增 routingPairHint / flfrOnlyHint / sampleRateDeviceActual）。
- **行为影响**：纯 UI 与文案，音频零改动。
- **验收**：flutter analyze 零；flutter test 全绿；掩码规范化逻辑穷举验证
  （256 种输入：无半选状态、规范化不会让引擎多生效任何通道对）。
- **上游同步冲突风险**：极低（Dart 侧 UI 与 l10n）。

## P-032 四项 UI 缺陷修复 —— 低音模式弹回 / 混响预设跳两次 / IR 清除关开关 / 响度说明重复（2026-10-25）

- **位置**：`app/auradsp_app/lib/core/state/state_effects.dart`
  （setBassMode / selectReverbPreset）、`state_events.dart`（params 回读）、
  `state_core.dart`（_mirror + send 测试钩子）、`state_session.dart`（会话回放）、
  `state_chain.dart`（clearConvolver）、`state.dart`（sentParamsForTesting 字段）、
  `features/effects/loudness_card.dart`、`convolver_card.dart`、
  `channel_routing_selector.dart` 之外的 `cards_common.dart`（_ResourceSlot +
  _Freeverb3DPainter.shouldRepaint）、`lib/l10n/*` 无改动；
  引擎侧：`engine/engine_internal.h`（bass_mode 字段）、
  `engine/engine_param_table.h`（bass.mode 参数 + set_convolver_clear）。
- **动机**（用户实测报告四项）：
  (1) 效果-响度补偿：卡片顶部的说明行与「补偿强度」滑块气泡内容重复。
  (2) 效果-低音增强：模式选不中——选任何项滑块会动，但模式总被弹回
      「自然低音」。根因：`bass.mode` 只是 UI 侧谐波配方宏，**从未下发引擎**
      （引擎参数表里没有它）→ 回读 getIntNullable 恒 null → isolate 兜底 0
      → params 全量回读把 UI 无条件覆盖成 0。
  (3) 效果-空间混响：点预设后参数与 3D 图跳变两次。根因：
      `selectReverbPreset` 漏发 `freeverb.roomsize` 与 `freeverb.width`
      → 引擎侧保持旧值（默认 1.2）→ 500ms 后的全量回读把 UI 改回旧值；
      roomSize 直接决定 3D 房间几何（`sizeFactor`/消失点/后墙/天花板），
      视觉上是"整个房间缩回旧尺寸"。另有两个放大因素：回读无条件覆盖把
      自定义态(-2) 也吞掉；float32 往返尾数差让 `shouldRepaint` 恒为真。
  (4) 效果-脉冲响应：点「清除 IR」会连带关掉效果器开关（卡片收起），
      而用户期望是回到"未加载"界面、效果内部直通；并希望加载后显示
      文件名（无扩展名）。
- **内容**：
  (1) 删除 loudness_card 顶部的重复说明行（文案仍由滑块气泡承载）。
  (2) 引擎新增 `bass.mode`（int 0..2，**纯状态载体**，不参与 DSP 计算），
      `setBassMode` 补 `setInt('bass.mode', mode)`；会话回放补下发
      `bass.mode`；`_mirror` 补登记；`param_contract_test` 的
      kUiOnlySpecIds 移除 'bass.mode'（它不再是 UI 专属）。
  (3) `selectReverbPreset` 补下发 `freeverb.roomsize` / `freeverb.width`；
      `_mirror` 补这两个 id 的登记；回读对本地自定义态(-2) 保持不动；
      `_Freeverb3DPainter.shouldRepaint` 改 epsilon 比较（1e-6）消除
      float32 尾数差导致的幽灵重绘。
  (4) `clearConvolver` 不再置 `convEnabled=false`；引擎 `set_convolver_clear`
      不再 `conv_enable.store(0)`——引擎侧 `apply_convolver` 在
      conv_enable=1 且 ir_ready=false 时已走 Convolver1DDisable（直通），
      语义本就正确；`_ResourceSlot` 标题改显 IR 文件名（去扩展名），
      并给标题加 Flexible+ellipsis 防长名撑破布局。
  (5) 新增 testing-only 钩子 `AppModel.sentParamsForTesting`：testing 模式
      下记录已下发的 setParam 载荷。此前 testing 模式 `_toIso` 为 null、
      send 静默丢弃，任何"漏发参数"类缺陷在单测里都测不出来。
- **行为影响**：混响预设的 roomSize/width 现在真正到达引擎（听感与 3D 图
  一致）；低音模式选择不再被回读弹回；清除 IR 不再关开关（无文件时效果
  内部直通）；引擎参数表新增 1 个 id（215 个，param_contract 哨兵已再生）。
- **验收**：`app/auradsp_app/test/ui_p032_fixes_test.dart` 7 项全绿
  （bass.mode 下发 + 回读保持 / 预设下发 roomsize+width / 回读同值不跳变 /
  自定义态不被吞 / 清除 IR 保持开关 / 响度卡片无重复行）。
  反向验证：还原 pre-fix 行为后 4 条核心断言**全部判红**。
- **上游同步冲突风险**：极低（Dart 侧为主；引擎侧仅新增一个状态参数与
  一处门卫语义放宽）。

## P-033 reverb.c + jdsp_header.h — vendor 原生参数与影子槽（已实施，WP1/WP2，2026-10-26）

- **状态**：已实施（WP1 于 2026-10-25 落地 `reverb.outgain/autogain` 至 vendor `stage_reverb`；WP2 于 2026-10-26 落地双槽影子构建、`Reverb_SetNative` 与参数映射）。
- **位置**：`jdsp/Effects/reverb.c`（新增 `Reverb_SetNative`、`ReverbConstructor`、`ReverbDestructor`、影子换槽与在途计数）、
  `jdsp/jdsp_header.h`（`AuraReverbNativeParams`、`ReverbSlot reverbSlots[AURA_REVERB_SLOTS]` +
  `sf_reverb_state_st *reverbActive`、`reverbProcCount` / `reverbSwapProc` /
  `reverbInFlight`）、
  `jdsp/jdspController.c`（`stage_reverb` 推进在途守卫计数与输出增益，`JamesDSPInit/Free` 构造/析构）。
- **动机**：立体声/矩阵/双耳路径必须使用 vendor Progenitor2；现有
  `Reverb_SetParam` 只能整预设重建，无法承接 `freeverb.*` 自定义参数，
  且重建 1MB 状态会在拖动时卡顿。`reverb.outgain/autogain` 目前只落在
  自研 Freeverb，退役后会丢功能。
- **内容**：新增 `AuraReverbNativeParams` 与 `Reverb_SetNative()`；单槽改
  双槽影子构建 + 原子换指针（与 P-018 comp 同范式）；`freeverb.*` 参数
  映射到 vendor 原生参数；`stage_reverb` 增加 reverb 输出增益/自动增益。
- **行为影响**：立体声路径自定义混响从 Freeverb 切到 vendor 原生参数；
  预设切换不再重建活动槽。默认参数下音色不变。
- **验收**：`smoke_reverb_boundary.py`、`smoke_reverb_native_params.py`。
- **上游同步冲突风险**：中（`sf_reverb_state_st` 布局与 `stage_reverb`
  调用点改动；上游 reverb.c 结构稳定，冲突集中在头文件字段）。

## P-034 compSlots / CompressorProcessChannel — comp 逐声道（已实施，WP3）

- **状态**：已实施（2026-10-25 WP3）。
- **位置**：`jdsp/jdsp_header.h`（`CompSlot compSlots[AURA_COMP_SLOTS]` (9 槽)、
  `FFTCompander *compActive[AURA_COMP_CHANNELS]` (8 槽)、`isMono` 字段、
  `CompressorProcessBlockStart` / `CompressorProcessBlockEnd` / `CompressorProcessChannel` 声明）、
  `jdsp/Effects/dynamic.c`（mono-aware CWT/STFT/Gammatone 路径、`comp_process_chunk_mono`、
  `FFTCompanderProcessSamplesMono`、`CompressorConstructor` 9 槽初始化、
  `CompressorCommit` 逐声道影子重建原子换指针）、
  `engine/chain/engine_chain.cpp`（`comp_process_mc` Mode 0 逐声道独立处理与
  Mode 1 逐对回退处理；Section 3b 双声道对复用完全清除）。
- **动机**：`comp.channels` 原为成对语义，C/LFE 被强制联动；工程要求
  8 声道各自独立检测器/包络/OLA 状态，且超预算时可降级为逐对（`comp.mode=1`）。
- **内容**：8 活动槽 + 1 影子槽；`CompressorProcessChannel()` 单声道
  FFT 优化；参数全局共享，控制线程逐声道重建；`comp.mode=1` 时按对处理，
  半选对完全不压缩（直通保证）。
- **行为影响**：MC 离散路径 comp 从 3 对双声道复用升级为 8 单声道独立实例（或 4 对降级）；
  各通道独立检测包络，零跨声道状态串扰；C/LFE 与 FL/FR 完全解绑；立体声路径零变化。
- **验收**：`smoke_mc_comp_persch.py`、`smoke_vb_8x8_budget.py`、`smoke_effects_allparams.py`。
- **上游同步冲突风险**：中（FFTCompander 内部增加 isMono，函数解耦与新增，未侵入原始算法内核）。

## P-035 EqPool — MC 路径逐声道 EQ（已实施，WP3）

- **状态**：已实施（2026-10-25 WP3）。
- **位置**：`engine/engine_internal.h`（`EqPool` 结构体：8×`FFTConvolver1x1* conv`、
  `loaded_block`、`loaded`、`ir_rate`）、
  `engine/auradsp_engine.cpp`（`auradsp_create` / `auradsp_destroy` 生命周期管理）、
  `engine/engine_param_table.h`（`set_eq_curve` 触发 `eq_pool_reload`）、
  `engine/chain/engine_chain.cpp`（`eq_pool_alloc` / `eq_pool_free` / `eq_pool_reload` /
  `eq_pool_process_strided` / `eq_process_mc` 实现；`process_multichannel_chain` Step 12 统一调用；
  旧 Section 3b 双声道循环完全删除）。
- **动机**：`eq.channels` 原为成对语义且 MC 路径复用 vendor 立体声 EQ；
  工程要求每声道独立卷积状态，IR 按设备率生成以彻底消除 96k/192k 设备率下的八度偏移（S-6）。
- **内容**：8×`FFTConvolver1x1` 专用池；`eq_pool_reload()` 采用设备率
  `(float)h->sample_rate` 生成脉冲响应并做 Nyquist 钳位与补零扩展；
  `eq_pool_process_strided()` 按 mask 提取 mono 跨步卷积；Section 3b 删除，
  立体声路径保持 vendor 原生实现不变。
- **行为影响**：MC 离散路径 EQ 8 声道完全独立；单声道掩码生效；96k 下 IR 频点对齐无漂移；
  立体声路径零变化。
- **验收**：`smoke_mc_eq_persch.py`、`smoke_eq_freq_clamp.py`、`smoke_effects_allparams.py`。
- **上游同步冲突风险**：低（全新池化实现，完全位于外围 engine 模块，无改动 legacy equalizer.c）。

## P-036 vendor 状态显式 reset（预留，WP6）

- **状态**：预留；WP6 若需要 `JamesDSPResetVendorState` 之类的显式
  vendor 状态清理入口才启用，否则本号保留不用。
- **位置**：`jdsp/jdspController.c` / `jdsp/jdsp_header.h`（待定）。
- **动机**：`reset_channel_state()` 需要保证拓扑切换时 vendor 段（comp/
  reverb/EQ 影子槽、延迟线）不残留旧布局状态。
- **内容**：待 WP6 评估；优先复用现有 `Refresh` / `Disable` 路径，避免
  新增 vendor 入口。
- **上游同步冲突风险**：低（若启用，预计为单个显式 reset 函数）。

## P-037 postGainCh — stereo/matrix/binaural 逐声道输出补偿（已实施，WP5）

- **状态**：已实施（2026-10-26 WP5）。
- **位置**：`jdsp/jdsp_header.h`（`float postGainCh[2]`）、
  `jdsp/jdspController.c`（`stage_output`）。
- **动机**：`post.gain.c0..c7` 需要逐声道补偿；MC 路径由引擎侧
  `post_gain_process_mc` 承担，立体声/矩阵/双耳路径必须在 vendor
  `stage_output` 内与主增益同级，limiter 才能看到最终电平。
- **内容**：`postGainCh[2]` 默认 1.0；新增
  `JamesDSPSetPostGainCh(jdsp, ch, dB)`（控制线程，与
  `JamesDSPSetPostGain` 同范式）；`stage_output` 改为
  `tmpBuffer[c][i] * postGain * postGainCh[c]`。MC vendor 段移除 `output`。
- **行为影响**：trim 全 0 时逐位等于旧行为。
- **验收**：`smoke_postgain_persch.py`。
- **上游同步冲突风险**：低（两个字段 + 一行乘法；上游 `stage_output`
  结构稳定）。

## P-038 LiveProg 运行环境感知与代码冗余清理（已实施，2026-10-26）

- **状态**：已实施（2026-10-26，对应细审 REM-1/REM-2/REM-3）。
- **位置**：`jdsp/jdsp_header.h`、`jdsp/Effects/liveprogWrapper.c`、
  `jdsp/jdspController.c`、`engine/engine_internal.h`、`engine/chain/engine_chain.cpp`。
- **动机**：
  1. LiveProg 脚本在 EEL 中原本仅注册 `srate`（工作率 `jdsp->fs`），脚本无法得知真实的驱动层设备采样率及当前声道数，在多声道下缺少物理环境感知（REM-1）；
  2. `ArbmagPool` 与 `EqPool` 中 `loaded_block` 写而未读，属冗余死代码（X-9 / REM-2）；
  3. `AURADSP_ASRC_TAPS` 注释中关于桌面端热切的不准确描述纠偏为桌面流重启架构说明（S-9 / REM-3）。
- **内容**：
  1. 在 `LiveProg` 虚拟机中注册 `dev_srate`、`num_ch`、`nch`，并记录环境快照 `snapFs`/`snapDevFs`/`snapNumCh`；新增 `LiveProgSetChannels` 供拓扑变更时同步；
  2. 移除 `engine_internal.h` 与 `engine_chain.cpp` 中未被读取的 `loaded_block`；
  3. `jdspController.c` 修正抽头数注释。
- **验收**：`test/smoke/smoke_liveprog.py` 新增环境感知用例，全套 smoke runner 通过。
- **上游同步冲突风险**：低。

## P-039 LiveProg 多段分段解析器支持 (@init, @slider, @block, @sample) 与 @slider 块执行（已实施，2026-10-27）

- **状态**：已实施（2026-10-27）。
- **位置**：`jdsp/jdsp_header.h`（`codehandleSlider`）、
  `jdsp/Effects/liveprogWrapper.c`（`LiveProgStringParser`、`LiveProgCompileInto`、
  `LiveProgProcess`、`LiveProgDestructor`、`LiveProgSlotInitVM`、`checkErrorCode`）。
- **动机**：
  1. 上游 `LiveProgStringParser` 仅硬编码匹配 `@init` 与 `@sample`，且直接截取两段之间的所有文本作为 `@init` 内容（附带硬编码 `-(8 + 1)` 截断）；如果脚本中包含 `@slider`（如 JSFX 常用或新建模板），NSEEL 会在编译 `@init` 时因识别到非法的 `@` 指令抛出 "Syntax error at @init section"；
  2. JSFX 规范下的 `@slider` 参数变动与初始化代码需要正确编译并在块首及初始化时触发执行，以使滑块参数计算生效；
  3. 彻底消除 Windows `\r\n` 换行符与多余空白带来的分段截断风险。
- **内容**：
  1. 重写 `LiveProgStringParser`：稳健扫描行首段标记 `@init`、`@slider`、`@block`、`@sample`；
  2. 精确切分段区间，分别送入对应编译器；
  3. `LiveProg` 增加 `codehandleSlider`；在编译成功后执行一次 `@init` 和 `@slider`，在 `LiveProgProcess` 的块开头执行一次 `@slider`；
  4. 释放与错误返回码完善（`-5`: Syntax error at @slider section）。
- **行为影响**：
  纯超集支持！带 `@slider` 的 JSFX 脚本和模板完全正常编译并执行滑块逻辑；无 `@slider` 的传统脚本完全无性能损耗。
- **验收**：`smoke_liveprog.py` 与示例模板编译测试。
- **上游同步冲突风险**：低。
## P-040 混响 3D 声学画师 shouldRepaint 浮点 epsilon（实施：2026-10-27）

- **状态**：已实施（2026-10-27）
- **位置**：`app/auradsp_app/lib/features/effects/cards_common.dart`（`_Freeverb3DPainter.shouldRepaint`）。
- **动机**：画师参数（decay/damp/roomSize/stereoWidth）由动画/旋钮连续驱动，受单精度 IEEE754 舍入影响可能产生 1e-7 级尾数抖动；直接 `!=` 比较会把「等值不同位」误判为变化，触发无谓的逐帧重绘，多个编辑器同开时放大 UI 卡顿。
- **内容**：引入 `static const double _eps = 1e-6;`，`shouldRepaint` 中四路参数比较全部带 `_eps` 容差，只有真实变化才触发重绘。
- **行为影响**：无（纯绘制刷新判定收紧，绘制结果逐位不变）。
- **验收**：D6 门禁全绿（本条目即登记）。
- **上游同步冲突风险**：无（纯 Flutter 侧逻辑，无 vendor 代码）。
## P-041 插件挂载即旁路——假旁路根治 + 编辑器无可视化闭环（实施：2026-10-28）

- **状态**：已实施（2026-10-28）
- **位置**：`engine/plugins/driver/plugin_host_manager.cpp`（`commitInstanceLocked`）
  + `app/auradsp_app/lib/core/plugin_manager.dart`（`onPluginSlotLoaded`）
  + `app/auradsp_app/lib/core/state/state_session.dart`（回放恒发 bypass）
  + `app/auradsp_app/lib/engine/audio_isolate.dart`（在途加载 bypass 暂存）
  + 9 个冒烟测试补显式解旁路。
- **动机**（用户实测两症状，同根因）：
  ① **假旁路**：UI 显示旁路但音频实际流经插件。UI 侧 2026-10-22 已有
  「挂载即旁路」策略（挂载成功后下发 bypass:true），但引擎
  `commitInstanceLocked` 出厂激活（`bypassed.store(false)`）在三处把它
  打掉：VB 后台补挂组 `LoadGroupForSlot` 的 `SlotLoad` 会用刚 commit 的
  引擎态（bypass=0）**回写镜像**，覆盖 UI 已下发的 1 → 组 1..N-1 全部
  激活；异步加载窗口内先到的 bypass 请求被 commit 的 false 抹掉；
  会话回放保存为激活的槽被 `onPluginSlotLoaded` 的无条件 mount-bypass
  下发覆盖成旁路（且旧回放只发 true 不发 false，激活槽无人解旁路）。
  ② **编辑器无可视化**：编辑器固定开在组 0（`PluginEngine()`），而组 0
  是唯一真旁路的实例（组 1..N-1 被 ① 误激活）→ 无 processBlock → 无
  表针，可听效果全部来自被误激活的组。**定性为 bug 而非策略**，无需
  「显示/不显示实时流」开关。
- **内容**：引擎挂载恒旁路（commit 存 true，单源真值，三路时序全部
  免疫）；UI 删除冗余 mount-bypass 下发（它是会话回放覆盖的根源）；
  会话回放恒发保存的 bypass 值；isolate 对在途加载窗口内的 bypass
  请求暂存、load 完成后补发（非桥异步路径竞态）；VB 桥路径 load 同步
  无竞态、镜像回写在挂载旁路语义下自洽（无需改桥）。
- **与 Z12 超预算保护的适配**：槽级 bypass 与链级 enable 正交——旁路槽
  不进音频路径（`processInterleavedN` 早退），挂载窗口内链零负载，天然
  不触发保护；用户解旁路后若重插件超预算，Z12 链级收窄照常生效（链
  掩码决定哪些组进路径，槽 bypass 决定槽是否进路径），保护退出后掩码
  重放不碰槽 bypass。加载期旁路（g_loadSuspending）同理不受影响。
- **行为影响**：① 所有模式（本地/VAIO/ASIO/APO/VB）挂载后槽一律旁路
  （UI 橙色「旁路」），用户显式打开才生效——与 UI 既有显示语义首次
  真正对齐；② 挂载瞬间重插件零音频冲击（此前出厂激活会立即吃 CPU）；
  ③ 旁路期间 F-2 真旁路把插件 deactivate（VST3 setActive(false)），
  编辑器无表针属预期；④ 优雅卸载的 bypass:true 前置（unload 流程）
  与挂载旁路衔接一致，无残留。
- **验收**：`smoke_plugin_bypass_lifecycle` 挂载断言翻转（==1）+ 5 轮
  切换稳态逐位不回归；`smoke_vm_plugin_load_fast` 新增「挂载即旁路」+
  「解旁路后 processCalls 恢复」断言；9 个旧契约冒烟补显式解旁路后
  全量 100%；flutter analyze 零问题；plugin/会话相关 Dart 测试全过。
  9 个测试文件：plugin_host / plugin_host_process（4 处 load）/ pdc /
  bus / chain_stages / channels / chain_enable / cross_mode_consistency /
  bypass_lifecycle。
- **上游同步冲突风险**：低（engine 单行语义翻转 + Dart 三处小改；
  vendor 代码零触碰）。

## P-042 插件扫描目录改版——显式目录列表 / 平台预置 / 内置目录 / 厂商分组（实施：2026-10-28）

- **状态**：已实施（2026-10-28）
- **位置**：新增 `app/auradsp_app/lib/core/plugin_scan_dirs.dart`（模型 +
  平台目录发现）与 `lib/features/plugins/plugin_scan_dirs.dart`（独立 UI 文件，
  原 `plugins_dirs.dart` 的 part 文件删除）；`lib/core/config.dart`
  （`customPluginDirs` → `pluginScanDirs` 条目 + `pluginScanDirsSeeded` 迁移）、
  `lib/core/text_collation.dart`（新增）、`lib/core/state/state_session.dart`
  （目录操作 API + 内置目录归一 + 首次播种）、`lib/core/plugin_manager.dart`
  （`setScanDirs` / `pluginGroups` / 预留格式计数）、
  `lib/features/plugins/plugins_list.dart`（厂商分组 + 扫描占位 + 格式药丸）、
  `lib/features/plugins_page.dart`（挂载新 section、移除右上角打开文件夹）、
  三语 arb + gen-l10n。
- **动机**（用户定案）：① 「自定义插件检索目录」名不副实——实际依赖引擎隐式
  默认目录，用户移除/取消勾选在引擎侧不生效；② 目录管理展示形态差（Chip 墙，
  无勾选、无逐条打开）；③ 插件列表无分组，百级条目难找。
- **内容**：
  · 目录即真值：`pluginScanDirs` 条目含 path/enabled/builtin；UI 多选列表
    （左复选框、右「打开文件夹」「移除该条」），列表左上全选（三态）+ 清除；
    「添加目录」保留在卡片头；插件库卡片右上角打开文件夹按钮删除。
  · 平台预置：仅首次播种（`pluginScanDirsSeeded`），且目录必须真实存在——
    Windows：CommonProgramFiles/LOCALAPPDATA 的 VST3/CLAP 与 VST2 常见目录 +
    HKLM/HKCU\SOFTWARE\VST 的 VSTPluginsPath（reg.exe best-effort）；
    macOS：/Library 与 ~/Library/Audio/Plug-Ins 下 VST3/CLAP/VST/Components；
    Linux：/usr/lib、/usr/local/lib 与 ~/.{vst3,clap,lv2,vst}。
  · 内置目录：`<配置根>/plugins` 自动创建、恒启用、不可移除（UI 禁用移除按钮
    并标注「内置」），为未来自带插件预留。
  · 引擎只扫传入目录：`collectSearchPathsLocked` 有显式目录时不再叠加默认目录
    （空输入保留默认兜底，兼容脚本/冒烟）。
  · 列表按厂商分组：厂商字典序（大小写/变音符号折叠 + 数字自然序；非拉丁按
    码位稳定排序，明确不做拼音序），组内插件同名序，未知厂商沉底。
  · 预留格式：FilterPills 增加 VST2 / AU / LV2（灰显不可点 + 悬停「后续版本
    支持」）；`PluginFormat` 已能解析三种格式，驱动实现后即刻可用。
- **附带修复**（本轮门禁暴露的历史欠款）：① `liveprog_page.dart` 字号恢复
  提示硬编码中文 → `liveprogFontReset` 三语词条（CJK 棘轮归零）；②
  `setLiveprogParam` 未同步 `lpSliderValues` → 同签名重应用会复活声明默认值，
  用户旋钮值被覆盖（10-27 滑块重构遗留，`config_and_presets` Liveprog v2 用例
  抓到）；③ `eel_editor_test` 断言串与 10-27 改版后的 `eelEmptyInit` 文案漂移
  → 改为匹配 @init 语义（保持定位/blocking/行号意图）。
- **验收**：新增 `test/plugin_scan_dirs_test.dart` 11 项（排序/迁移/目录过滤/
  分组）全过；`flutter analyze` 零问题；`config_and_presets` 86 项全过；
  全量 Dart 串行 559 项中仅剩环境型 loading/did-not-complete（被点名文件单跑
  全过）；`runner.py --smoke` 100%。
- **上游同步冲突风险**：低（全部为 Dart 侧与 UI；引擎仅一处目录收集策略）。

## P-043 深扫挂死防护——单项超时 / 宿主 IPC 超时 / 前端中断保列表（实施：2026-10-28）

- **状态**：已实施（2026-10-28）
- **位置**：`engine/plugins/driver/plugin_scanner.cpp`（单项元数据查询超时守卫）、
  `engine/plugins/api/plugin_host.h`（ScanJob 诊断计数）、
  `engine/plugins/host/plugin_host_client.{h,cpp}`（带超时的 IPC 读 + 超时杀宿主）、
  `app/auradsp_app/lib/engine/audio_slots.dart`（中断判定）、
  `lib/core/plugin_manager.dart` + `lib/core/state/state_events.dart`（aborted
  语义：保留上次结果 + 提示）。
- **动机**（用户实测）：深扫需 LoadLibrary/实例化插件，个别插件在现场卡死
  （甚至弹出自己的 UI），整条扫描链路永久阻塞，UI 停在「正在扫描」，只能重启
  应用；且一次失败会把整份插件列表清空。
- **内容**：
  · 进程内深扫：每个候选的元数据查询放 detached worker，主扫描线程最多等
    2500ms；超时 → 放弃该候选并回退「快速信息」条目（标注「深度扫描超时」，
    仍可正常尝试挂载——挂载路径有独立的异步超时保护），扫描继续推进。放弃
    线程无法安全回收，设上限 4（`kScanAbandonLimit`），超过即停止深扫（后续
    候选降级快扫）。硬隔离仍建议 `AURA_PLUGIN_HOST_MODE=process`（进程外宿主）。
  · 进程外宿主：`readAllTimeout`（PeekNamedPipe 轮询 2ms + 进程存活检查），
    扫描类操作 8s、其余 60s；超时 = 杀宿主进程 + 标记管道失效，下次操作自动
    重启干净宿主。
  · 前端：`_scanChunked` 区分「正常扫完」与「中途中断」（stepped==0 且
    processed<total）→ `pluginScanned.aborted`；管理器收到 aborted 时**保留
    上次成功列表**并提示「扫描中断…」，绝不用残缺/空表覆盖。
- **验收**：`runner.py --smoke` 100%（含 plugin_host_process / plugin_bus 等
  深扫相关）；引擎构建零警告；Dart 侧 aborted 语义由既有用例回归。
- **上游同步冲突风险**：低-中（scanner 的扫描循环改写为守卫形态；宿主客户端
  请求签名增可选参数，调用点默认值兼容）。
