# AuraDSP 文档索引

> 本页是 `docs/` 的**导航入口**。工程约束的真相源是 [`项目架构与开发规范.md`](项目架构与开发规范.md)，产品/品牌真相源是 [`产品架构总览.md`](产品架构总览.md)。
> 根目录另有面向智能体的总纲：[`AGENT.md`](../AGENT.md)（协作与铁律）、[`CLAUDE.md`](../CLAUDE.md)（构建/测试命令）。

---

## 1. 真相源（修改代码前必读）

| 文档 | 定位 | 何时更新 |
|---|---|---|
| [项目架构与开发规范.md](项目架构与开发规范.md) | **工程唯一真相源**：目录约定、`source/` 整合铁律、`core/android` 分层、构建规范、已验证决策表、路线图 | 目录/依赖方向/构建方式/技术决策变化时 |
| [产品架构总览.md](产品架构总览.md) | **产品与品牌真相源**：命名体系（AuraDSP / AuraDSP Engines (Root/Rootless)）、形态矩阵、控制通道、仓库映射 | 新增用户可见名称前先对照 §1 |

## 2. 架构决策记录（ADR）

决策一旦落地即冻结；回退需新增 ADR 推翻，不得原地改写。

| ADR | 主题 | 状态 |
|---|---|---|
| [ADR-001](adr/ADR-001-windows-v1-process-level.md) | Windows v1 采用**进程内**真实处理链（内置播放器 → DLL → WASAPI 共享） | 已接受 |
| [ADR-002](adr/ADR-002-latency-tiers.md) | 三档硬延迟分级（realtime ≤10ms / music ≤30ms / quality 无限），**引擎侧强制** | 已接受 |
| [ADR-003](adr/ADR-003-multichannel-matrix.md) | 多声道 Phase A 采用声道矩阵包络，不改 vendor-src | 已接受 |
| [ADR-004](adr/ADR-004-plugin-multi-slot-and-stage-topology.md) | 插件**多插槽（2 路）+ 五级链阶段插入拓扑**；不引入桥进程 | 已接受 |

## 3. 方案与规划（按主题）

### 3.1 产品与动机
- [项目初衷.md](项目初衷.md) — 动机与愿景；对 JamesDSP / EqualizerAPO / Voicemeeter / PulseEffects / Element / ViPER 的实测痛点复盘
- [source-参考项目审理报告.md](source-参考项目审理报告.md) — `source/` 10 个参考仓库的审计与算法对照矩阵

### 3.2 Android 路线
- [M0-Android音频政策专项调研.md](M0-Android音频政策专项调研.md) — Android 音频政策调研
- [Spike2-AIDL效果库验证报告.md](Spike2-AIDL效果库验证报告.md) — AIDL 效果 HAL 端到端验证（Enforcing 下通过）

### 3.3 APP 功能规划
- [APP-架构与设计方案.md](APP-架构与设计方案.md) — APP 架构与 UI 设计规范（`theme.dart` 的 §7 主题依据）
- [APP-插件与信号图扩展规划.md](APP-插件与信号图扩展规划.md) — 五方向扩展规划（插件宿主 / Liveprog / 信号图 / 卷积 / 效果细化），含里程碑与风险登记
- [UI-六页架构与M3.5重排序方案.md](UI-六页架构与M3.5重排序方案.md) — 六页信息架构、效果页重设计、**M3.5 真重排序**方案与实施状态
- [UI与音频效果深度重构与体验优化方案.md](UI与音频效果深度重构与体验优化方案.md) — 空间混响统一、交互式 EQ、组件级微型延迟、低音重构、电子管卡片
- [外置参数持久化记忆与预设系统v2方案.md](外置参数持久化记忆与预设系统v2方案.md) — `config.json` + 会话记忆 + 预设 schema v2（`*.aurapreset.json`）

### 3.4 测试基建
- [UI自动化测试基建与经验沉淀.md](UI自动化测试基建与经验沉淀.md) — 置顶前置测试基建与血泪教训

### 3.5 阶段性回顾（时间序）
- [阶段性回顾-2026-10-09.md](阶段性回顾-2026-10-09.md) — Win11 APP 冲刺日
- [阶段性回顾-2026-10-10.md](阶段性回顾-2026-10-10.md) — 插件多插槽 / 五级拓扑 / EEL 编辑器 / 交叉系统验证

## 4. 非 Markdown 资产

| 目录 | 内容 | 说明 |
|---|---|---|
| `docs/forensics/` | Android 取证原始材料（dumpsys / audio_effects.xml / tombstone / jdsp live log） | **原始证据，勿删勿改**；结论见各自目录内的报告 |
| `docs/ui-redesign/` | UI 迭代截图（含像素差分基线） | `test/ui/ui_assert.py` 的差分基线来源 |
| `design/tokens/aura.tokens.json` | 三套主题（aura-dark / aura-light / aurora）的 W3C Design Token | 由 `lib/core/theme.dart` 消费 |

## 5. 文档维护约定

1. **方案先行**：新增能力先出方案文档，再写代码；实现状态回写进方案的里程碑小节。
2. **决策留痕**：跨模块/不可逆的取舍一律开 ADR，编号顺延，写明"背景 / 决策 / 后果 / 回退条件"。
3. **真相源同步**：目录、依赖方向、构建命令、已验证决策表变化，必须同步 `项目架构与开发规范.md` §2/§4/§5/§6。
4. **不复述代码**：文档记录**为什么**与**契约**，字段级细节以头文件注释为准（见 `core/desktop/engine_api/auradsp_engine.h` 参数语义表）。
5. **每日沉淀**：会话记忆与教训写入 `.ai/memory/`（AI 自治沉淀区，无需人工介入）。