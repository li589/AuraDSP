# ADR-001 — Windows 首版采用进程级真实链路，系统级 APO 延后 Phase 7b

- 状态：已接受（2026-10-09）
- 背景：需求要求"可以直接使用的 Win11 APP"且"DSP 延迟达到商业水平"。Windows 上对**所有应用**做无驱动全局处理的唯一正路是 SFX APO（挂声卡驱动，in-place），但它需要代码签名（测试签名→EV 证书），纯用户态方案（loopback 重注入）延迟不可接受。
- 决策：Win11 首版 = **进程级真实链路**：内置播放器（WAV/FLAC）→ `auradsp_engine.dll`（libjamesdsp）→ WASAPI 共享模式输出。链路真实可听、引擎附加延迟真实可测。UI 与 Control API 与最终 APO 形态完全一致，APO 只替换"音频进引擎的那一截"。
- 后果：首版全局性 = 进程级（诚实标注，不做虚假宣传）；Phase 7b 再补 APO + 签名流水线。
- 依据：EqualizerAPO 源码（`source/equalizerAPO64`）确认其本质为 APO 注册 + 驱动端 sfx 声明；PowerToys/Razer 等商业产品同样走 APO。
