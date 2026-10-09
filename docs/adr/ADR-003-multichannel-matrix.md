# ADR-003 — 多声道 Phase A 采用声道矩阵包络，不改动 vendor-src

- 状态：已接受（2026-10-09）
- 背景：需求要求兼容多声道（5.1/7.1）。libjamesdsp 交织处理路径硬编码 2 声道（`processFloatMultiplexd`，见 JamesDspEngine.cpp:73 注释），直接扩展需改 vendor-src 并打 [PATCHED]（铁律 §3.3），升级成本高。
- 决策：
  - **Phase A**：引擎外层做 M×N 下混/上混矩阵。LFE 直通（不经 DSP，保护低频主干与超低音相位），C/SL/SR 以可配系数并入 L/R 处理后回填。5.1/7.1 全局处理立即可用。
  - **Phase B**：逐声道实例化（N-1 个引擎实例 + LFE 直通），CPU 达标后再评估；跨声道效果需求出现时才考虑 vendor-src 打补丁。
- 后果：Phase A 下"立体声增强/Crossfeed"对 C/SL/SR 的作用是间接的（经并入矩阵），在 UI 效果说明中如实标注。
