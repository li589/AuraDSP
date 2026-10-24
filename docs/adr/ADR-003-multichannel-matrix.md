# ADR-003 — 多声道 Phase A 采用声道矩阵包络，不改动 vendor-src

- 状态：**已接受并落地**（2026-10-09 决策，2026-10-10 实现）
- 背景：需求要求兼容多声道（5.1/7.1）。libjamesdsp 交织处理路径硬编码 2 声道（`processFloatMultiplexd`，见 JamesDspEngine.cpp:73 注释），直接扩展需改 vendor-src 并打 [PATCHED]（铁律 §3.3），升级成本高。
- 决策：
  - **Phase A**：引擎外层做 M×N 下混/上混矩阵。LFE 直通（不经 DSP，保护低频主干与超低音相位），C/SL/SR 以可配系数并入 L/R 处理后回填。5.1/7.1 全局处理立即可用。
  - **Phase B**：逐声道实例化（N-1 个引擎实例 + LFE 直通），CPU 达标后再评估；跨声道效果需求出现时才考虑 vendor-src 打补丁。
- 后果：Phase A 下"立体声增强/Crossfeed"对 C/SL/SR 的作用是间接的（经并入矩阵），在 UI 效果说明中如实标注。

## 实施记录（2026-10-10）

- **ABI**：新增参数 `channels.count`（i32，2=立体声 / 4=Quad / 6=5.1 / 8=7.1）。只接受这四个值，其它一律拒绝而非静默截断——驱动层缓冲尺寸与引擎解释不一致会直接越界。（2026-10-24 细审更正：实现自始就接受 4，原文只写 2/6/8 与实现不符。）`auradsp_process` 的 `in`/`out` 在 `channels.count > 2` 时按 `frames × channels` 交织解释。
- **实现**：抽�� `process_stereo_chain(src, dst)` 使多声道与立体声**共用同一条处理链**，保证"多声道 = 立体声 + 矩阵"这一不变式，不会出现两套效果逻辑各自漂移。`ch <= 2` 时整段矩阵逻辑跳过，立体声路径与改造前逐字节一致。
- **系数**：下混/上混统一用 `kMxSqrtHalf`（0.70710678，即 -3.01dB），C 与环绕等权回填，4 声道（Quad）按 FL FR BL BR 布局。声道序遵循 WAVEFORMATEX 标准：FL FR C LFE SL SR [BL BR]。（2026-10-24 细审更正：原文写的 `kMx51`/`kMx71`/`kMxUpmixSurround` 三个可配系数在实现里并不存在，矩阵系数目前是硬编码常量、不可调。）
- **工作区**：`mx_scratch`（max_block × 8，留存各声道供上混取用）与 `mx_stereo`（max_block × 2，链输出），create 时预分配，RT 线程零分配。
- **可视化**：多声道下频谱/电平取自下混后的立体声工作区（信号走向的近似），已在代码注释与本 ADR 中标注。
- **验证**：`test/smoke/smoke_config_and_matrix.py` 断言 LFE **逐样本直通**（与处理链完全无关，max dev = 0）、环绕并入 L/R、上混回填量级合理、`channels.count` 边界、立体声路径无回归。
- **遗留**：Phase A 无法对 C/SL/SR 做独立处理，这正是 Phase B 的动机；`writeToDevice` 侧的多声道写入在 Dart 侧已就位（按 devCh 写入），此前对 ch≥2 填 0 的限制由本 ADR 的引擎矩阵解除。

## 演进记录（2026-10-24）：多声道电平 Phase B

- 引擎 MC 链（`process_multichannel_chain`，Category A/B 路线）落地后，Phase B 原描述「逐声道实例化 N-1 个引擎实例」已由该独立 MC 链路线取代，不再按原计划实施；vendor-src 打补丁仍维持「跨声道效果需求出现时才考虑」。
- **多声道电平**（未决清单 #94）设计已定稿：`auradsp_viz_frame` 追加式扩展（`channel_count` + `channel_levels[8]` + `stage_ch_levels[32][8]`，536B→1600B，`AURADSP_ABI` 1→2），MC 链各效果器后 per-channel 峰值采样，UI 电平柱 2→N。完整设计（ABI/引擎/Dart/UI/验证矩阵）见 `docs/20-执行/多声道电平PhaseB设计-2026-10-24.md`。
- 诚实性约束：vendor 段与 Category B 效果（bassmono/haas/spatial）只作用于 FL/FR 对，其 per-channel 电平对 [2..7] 声道恒显 -120，不复制假装全声道；GR 槽保持单值语义。（2026-10-24 细审补注：**comp/eq 是例外**——离散 MC 下二者按声道对 (2,3)/(4,5)/(6,7) 继续处理（`engine_chain.cpp:919`），但其 per-channel 电平未按对回填，[2..7] 仍恒 -120；即「只作用 FL/FR」这句对 comp/eq 不成立，且 C 与 LFE 被配成一对，与本文「LFE 直通」原则冲突。列为未决项，见细审报告。）
