# ADR-007 — DSD 播放不支持（v1/v2 维持 PCM-only），留触发条件再议

- 状态：**接受**（2026-10-15）
- 背景：本机在装驱动含 DSD 转码器（DSDTranscoder，ASIO 显示名"DSD 转码器 (DoP/Native)"）。其 ASIO 声道在 DSD 会话下自报 `ASIOSampleType` 为 DSD 系（1-bit 分块），与引擎 PCM float32 处理链不兼容。Spec §5 R-6 已定铁律"不猜格式"——`AsioHost` 对输入/输出声道只接受 Float32LSB/Int32LSB/Int24LSB/Int16LSB 四种，DSD 声道在 `create_buffers` 阶段显式拒绝并上报（非崩溃）。
- 决策：
  1. **v1/v2 均不支持 DSD 播放**，维持 PCM-only。理由：① ASIO 的 DSD 传输（ASIO 2.1 `ASIOOutputDsd`/`kAsioSupportsDsd` 系）与 PCM 缓冲是两套通道模型，宿主需按 DSD 块率重排采样字节，工作量大且无中间件可复用；② 本产品价值在**处理链**（EQ/卷积/动态等），而任何 DSP 处理都要求 PCM 域——DSD 直通链路上插 PCM 引擎毫无意义，纯直通则不需要本产品；③ 目标用户听音链（流媒体/本地文件）几乎全为 PCM，DSD 源（SACD ISO 等）在播放器侧已有 DoP/PCM 转换。
  2. **遇 DSD 驱动时的行为**：枚举正常展示（驱动可见）；start 若选中该驱动且声道为 DSD 格式 → `buffers-failed: unsupported sample type ...`，UI note 直显原因，不静默、不猜格式。
  3. **再议触发条件**（全部满足才重开）：① 出现真实用户诉求（issue/反馈中 DSD 源直通需求 ≥ 可观比例）；② 有"DSD 直通 + PCM 处理并行声道"的清晰产品形态（而非引擎插 DSD 块流）；③ ASIO DSD 扩展在目标驱动上的兼容性实测可复现。届时另立 ADR 取代本文。
- 后果：DSDTranscoder 在本产品内为"可见但不可用"驱动（note 说明原因）；Spec §5 R-6 维持有效；`smoke_asio_bridge.py` 的驱动优先级列表不包含 DSD 驱动（其格式不支持，start 必失败）。
