# ADR-011 — 控制线程与 RT 线程不得共享可变 DSP 状态

- 状态：**接受**（2026-10-31）
- 依据：`docs/30-审查/未决任务复核-2026-10-31.md` §3.1（L-01）/ §3.2（L-03）/ §3.3（L-02）；用户选定 P0 双池专项
- 背景：
  1. 2026-10-31 全量复核登记的 **L-01 / L-02 / L-03** 是本仓**唯一**的已知高危并发遗留，三者同源于「控制线程与 RT 线程共享可变 DSP 状态」。本 ADR 把这一类缺陷的**通用契约**固化下来，并登记三项的落地实现。
  2. **L-01 / L-03（池）属崩溃级**：控制线程对池内共享的 `FFTConvolver1x1` 调 `LoadImpulseResponse`，而该函数首步即 `FFTConvolver1x1Free`（free 掉 `_fftBuffer` / `_overlap` / `_inputBuffer` / `_segments*`）；RT 此刻可能正在同一实例上跑 `FFTConvolver1x1Process` ⇒ **释放后使用（UAF）**。
  3. **L-03（主卷积）属撕裂级**：vendor 的 `ArbitraryResponseEqualizerStringParser` 对 `arbMag.conv` 做**原位** `RefreshImpulseResponse`（逐段改写 IR 的频域段），RT 的 `stage_arbmag` 同时在同一对象上跑 `FFTConvolver2x2Process` ⇒ RT 读到「一半新、一半旧」的 IR，滤波器响应既不是曲线 A 也不是曲线 B。实测（见 §门禁）输出块间相对偏离可达 **1002%~50810%**（幅度失控），而修复后稳定在 **341.5% ± 0.03%**（合法瞬态）。
  4. **L-02 属数据竞争级**：控制线程 `reset_channel_state()` 直清 RT 正在使用的非原子状态（gate / filter / shelf / dyneq / tube / exciter / loudness / limiter / bassmono / psycho / haas / spatial / post_gain 平滑态）。
  5. 三项此前**都没有门禁**，也都不在任何锁的保护范围内：`ctrl_mutex` 明确不挡 `process`，`jdsp_lock` 只在 `kAuraStages[i].lock == 1` 的 stage 上被 RT 取得，而 eq / arbmag 两条 stage 的 lock 均为 0。
  6. 仓内已有**同范式的成熟先例**可照抄，不必自创：P-006 mEQ 卷积器双缓冲、comp（B1-c `CompSlot`）、liveprog（B1 `eelSlots`）、ddc（B1-b `DDCView`）、reverb 影子槽。共同点是「控制侧在非活动影子槽构建 → 成功后原子换指针 → RT 块首只读一次指针 → 换出的槽延迟回收」。

- 决策：
  1. **通用契约（唯一裁决）**：**控制线程与 RT 线程不得共享可变 DSP 状态**。任何由控制线程发起、会改变 RT 正在使用之 DSP 对象或状态的操作，必须满足下列三选一：
     1. **影子槽 + 原子发布**（首选）：控制侧在非活动影子实例上完整构建，成功后原子换指针；RT 在块首只读一次指针，块内不碰换出实例；换出的实例延迟回收，回收前须过在途守卫。
     2. **请求位 + RT 消费**：控制侧只置位一个原子请求标志，实际的状态清理/生效由 RT 在块边界执行（先例：`McReverbState::reset_req`）。
     3. **同持 `jdsp_lock`**：控制侧变更与 RT 处理互斥。要求该 stage 的 `kAuraStages[i].lock == 1`，且 RT 必须 honor 该标志（CLAUDE.md 既有铁律）。仅在「重建耗时亚毫秒级、且不做全量重算」时可用——comp/ddc/liveprog 当年就是因为持锁时长 = 全量重算时长（实测 comp 单块尖峰 342ms）才改走影子槽。
  2. **在途守卫（影子槽专用，与 comp B1-c 同式）**：复用已退役槽前必须满足双条件任一 —— (a) `in_flight == 0`（当前无 RT 块在途，覆盖音频停流时 `proc_count` 冻结的场景，否则参数改动永远不生效）；(b) `proc_count >= retired_at`（换出后至少又跑满一个音频块）。两条件皆不满足时控制侧有界等待（500ms 墙钟，自旋优先），仍不可用则**放弃本次重载（旧快照继续生效）**，绝不退化到活动槽原地重建（那会与 RT 竞争 ⇒ UAF）。
  3. **L-01 / L-03（池）落地**：eq 与 arbmag 两个逐声道池各改为 **2 个 bank（活动槽 + 影子槽）**，每 bank 持有 `kMxMaxChannels` 个 `FFTConvolver1x1`。控制线程只在影子 bank 上 `LoadImpulseResponse`，成功后原子发布 `active` 下标；RT 在 `process_multichannel_chain` 入口取一次快照（`h->eq_pool_bank` / `h->arbmag_pool_bank`），块内不再触碰换出的 bank。`loaded` 标志下沉到 bank 内（不再是跨线程裸 `int`）。
  4. **L-03（主卷积）落地**：`kAuraStages` 的 `arbmag` stage 由 `lock 0` 改为 **`lock 1`**（RT 在该 stage 取 `jdsp_lock`），控制侧刷新主卷积前同持 `jdsp_lock`（`engine/engine_param_table.h` 的 `arbmag_refresh_vendor_conv`）。此处选契约 1.3 而非影子槽：主卷积是 vendor 的 `FFTConvolver2x2`，其双缓冲改造需侵入 vendor 结构体（`ArbEqConv`/`arbitraryMagnitude`），而刷新耗时为亚毫秒级（IR 段重写，无全量重算），锁的持有时长可控。**注**：`arbMag` 的 Free+Load 崩溃级路径（`ArbitraryResponseEqualizerEnable(forceRefresh)`）在 Windows 桌面端**不可达**——`JamesDSPSetSampleRate` 仅由 Android AudioEffect 入口调用，不在 `.def` 导出表内；该路径仅 Android 侧同源存在。
  5. **L-02 落地**：`reset_channel_state()` 拆为两段 —— 控制侧（`reset_channel_state`，控制线程）只做控制线程自己的事（池重载、vendor 段 `apply_reverb`、`LiveProgSetChannels`）并置位 `h->reset_req`；RT 侧（`reset_channel_state_rt`，音频线程）在 `auradsp_process` 入口消费 `reset_req` 后执行真正的状态清理（gate / filter / shelf / dyneq / tube / exciter / loudness / limiter / bassmono / psycho / haas / spatial / post_gain 平滑态 / 混响自动增益平滑态）。`spatial_reset` 因此从控制线程迁到 RT 线程（只做 memset + 标量写，RT 安全）。
  6. **重载节流是固有代价，不是缺陷**：影子槽方案下，控制侧重载速率上限为「每音频块一次」（RT 换指针只能在块边界生效）。守卫不通过时放弃本次重载，旧 IR 继续生效，下一次参数变更会再次触发重载。这与 comp/ddc/liveprog 的既有语义一致。

- 后果：
  - 三项高危并发遗留全部销账：崩溃级（UAF）降级为零，撕裂级降级为零，L-02 的数据竞争消失。
  - **内存代价**：eq 与 arbmag 池的卷积器数量各翻倍（每池 2 bank × 8 声道）。单池 IR 长度 8192、块长 256 时每个卷积器约 142KB ⇒ 每池约 +1.1MB，两池合计 **+2.3MB**（相对 10-31 内存专项后的 0.98GB 基线可忽略）。
  - **RT 行为变更**：`arbmag` stage 现取 `jdsp_lock`。控制侧刷新主卷积期间 RT 在该 stage 阻塞一次（亚毫秒级），曲线变更时的单块尖峰实测 1.08~1.79ms，无可闻卡顿。离散多声道路径不走 vendor 链的 arbmag（改用逐声道池），该锁只影响立体声 / 矩阵 / 双耳三条路径。
  - **控制线程可能等待**：影子槽复用失败时控制侧最多等 500ms 墙钟（自旋 60000 次后回落 1ms 睡眠）。实测 UI 线程换曲线 3000+ 次 / 5s 无卡顿。
  - 若将来某条路径确实需要「重载立即生效且不可丢弃」，须另立方案（例如预备槽队列），不得回退到活动槽原地重建。

- 门禁：
  - `test/smoke/smoke_pool_race.py`（已登记 `test/runner.py`）。四个阶段：① eq 池并发重载（8ch 离散）② arbmag 池并发重载（8ch 离散）③ arbmag 主卷积撕裂检测（立体声，直流输入 + 双曲线交替刷新）④ 拓扑重置并发（`channels.mode` / `channels.count` / `spatial.*` 翻转，且开启 EQ 以覆盖「拓扑重置 → 池重载」这条 UAF 向量）。另含收尾健康检查（竞态后 eq 池仍按曲线生效，实测 +11.94dB / 目标 +12dB）。
  - 反向验证（脚本化、可复现）：`python tools/probe/prefix_toggle.py revert` → 重建 → 门禁**四阶段全部转红**；`python tools/probe/prefix_toggle.py restore` → 重建 → 全绿。实测转红项：
    - 阶段①：RT 第 12 块 `access violation writing 0x0000000000000020`
    - 阶段②：RT 第 11 块 `access violation writing 0x0000000000000020`
    - 阶段③：块间最大相对偏离 1342.7%（阈值 700%）
    - 阶段④：RT 第 225 块 `access violation writing 0x0000000000000020`
  - 撕裂量测探针：`python tools/probe/probe_arbmag_tear.py`（独立复现 pre-fix / post-fix 的偏离分布）。
  - 撕裂检测器的统计选择（重要，勿改）：只能用**极值**统计（块间最大相对偏离）。`mean` 类统计在此**不可用**——修复版因 stage 取锁而变慢，单位块内的换曲线次数上升，合法瞬态的均值反而更高（19.4% vs 11.3%），与撕裂信号混淆。pre-fix 4 次观测 2397% / 1002% / 3794% / 50810%，post-fix 4 次观测 341.52% / 341.47% / 341.66% / 341.5%，两分布**完全不重叠**，阈值取 700%。
