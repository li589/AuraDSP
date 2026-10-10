# ADR-003 — 多声道 Phase A 采用声道矩阵包络，不改动 vendor-src

- 状态：**已接受并落地**（2026-10-09 决策，2026-10-10 实现）
- 背景：需求要求兼容多声道（5.1/7.1）。libjamesdsp 交织处理路径硬编码 2 声道（`processFloatMultiplexd`，见 JamesDspEngine.cpp:73 注释），直接扩展需改 vendor-src 并打 [PATCHED]（铁律 §3.3），升级成本高。
- 决策：
  - **Phase A**：引擎外层做 M×N 下混/上混矩阵。LFE 直通（不经 DSP，保护低频主干与超低音相位），C/SL/SR 以可配系数并入 L/R 处理后回填。5.1/7.1 全局处理立即可用。
  - **Phase B**：逐声道实例化（N-1 个引擎实例 + LFE 直通），CPU 达标后再评估；跨声道效果需求出现时才考虑 vendor-src 打补丁。
- 后果：Phase A 下"立体声增强/Crossfeed"对 C/SL/SR 的作用是间接的（经并入矩阵），在 UI 效果说明中如实标注。

## 实施记录（2026-10-10）

- **ABI**：新增参数 `channels.count`（i32，2=立体声 / 6=5.1 / 8=7.1）。只接受这三个值，其它一律拒绝而非静默截断——驱动层缓冲尺寸与引擎解释不一致会直接越界。`auradsp_process` 的 `in`/`out` 在 `channels.count > 2` 时按 `frames × channels` 交织解释。
- **实现**：抽�� `process_stereo_chain(src, dst)` 使多声道与立体声**共用同一条处理链**，保证"多声道 = 立体声 + 矩阵"这一不变式，不会出现两套效果逻辑各自漂移。`ch <= 2` 时整段矩阵逻辑跳过，立体声路径与改造前逐字节一致。
- **系数**：下混 `kMx51/kMx71`，C 与环绕取 0.7；上混回填增益 `kMxUpmixSurround = 0.7`。声道序遵循 WAVEFORMATEX 标准：FL FR C LFE SL SR [BL BR]。
- **工作区**：`mx_scratch`（max_block × 8，留存各声道供上混取用）与 `mx_stereo`（max_block × 2，链输出），create 时预分配，RT 线程零分配。
- **可视化**：多声道下频谱/电平取自下混后的立体声工作区（信号走向的近似），已在代码注释与本 ADR 中标注。
- **验证**：`test/smoke/smoke_config_and_matrix.py` 断言 LFE **逐样本直通**（与处理链完全无关，max dev = 0）、环绕并入 L/R、上混回填量级合理、`channels.count` 边界、立体声路径无回归。
- **遗留**：Phase A 无法对 C/SL/SR 做独立处理，这正是 Phase B 的动机；`writeToDevice` 侧的多声道写入在 Dart 侧已就位（按 devCh 写入），此前对 ch≥2 填 0 的限制由本 ADR 的引擎矩阵解除。
