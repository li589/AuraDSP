# engine/legacy/ 补丁登记（PATCHES.md）

> 铁律 §3.3：上游源码原则上原样整合；确需扩展时打 `[PATCHED-AuraDSP <日期> P-xxx]` 标记补丁，
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
## B1 liveprogWrapper.c + jdspController.c + jdsp_header.h — liveprog 影子 VM 编译，RT 零锁等待（2026-10-24）

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

## B1-b Effects/vdc.c + jdspController.c + jdsp_header.h — ddc 影子视图 + countChars 栈溢出修复（2026-10-24）

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

## B1-c Effects/dynamic.c + jdspController.c + jdsp_header.h + engine/chain/engine_chain.cpp — comp 影子槽双缓冲，Z13 锁收口（2026-10-24）

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
