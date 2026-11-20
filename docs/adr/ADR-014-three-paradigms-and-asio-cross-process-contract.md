# ADR-014 — 三范式划分与 ASIO 跨进程三线契约

> **状态**：已接受（owner 裁定 2026-11-20；S1–S5 实施完成 2026-11-21）
> **关联**：[ASIO 模式重构方案-2026-11-20](../20-执行/ASIO模式重构方案-2026-11-20.md) ·
> [ADR-009 两大交互范式](ADR-009-audio-processing-paradigms-and-settings-restructure.md)（本 ADR 修订其范式划分） ·
> [ADR-008 ASIO 驱动身份与架构](ADR-008-asio-driver-identity-and-architecture.md)

---

## 背景

1. ADR-009 把 ASIO 拆进管线模式的两端：虚拟驱动作输入源、
   ASIO Client 作输出端。该划分在 REAPER 实测中被证伪为
   「语义同构、实现三分」——2026-11-20 定罪：REAPER 播放、
   电平表满格却无声无可视化，根因是 Driver 线的三根跨进程
   线从未接通：
   - **汇端点**：驱动 WASAPI 汇写死系统默认端点，App 的物理
     输出选择无人消费，处理完的声音进了无人转送的虚拟设备；
   - **参数**：DAW 进程内的引擎实例与 App 互不可见，恒跑
     默认参数，App 侧调参从未到达声音；
   - **遥测**：App 为显示状态自开一份自家驱动空会话（假会
     话），测的是空实例的回环，DAW 侧真实例无回传通道。
2. 三缺陷同源：ASIO 在 UI 上被拆成输入/输出两半后，没有任
   何一层负责「App ↔ DAW 进程内驱动实例」的跨进程契约。

## 决策

### D-1 三范式并列

顶级处理范式为三：**附加模式 / 普通管线模式 / ASIO 模式**。
ASIO 模式内以子形态切换分 **虚拟 ASIO**（Driver 线）与
**ASIO Client**（Client 线），不再出现输入/输出端选择；
管线模式的输入/输出选择器摘除 ASIO 两项。每个范式自记子
状态；存量配置由纯函数 `migrateParadigm` 在配置构造与会话
恢复两处同口径提升（管线 + ASIO 对 → ASIO 范式）。

### D-2 虚拟 ASIO = 控制台语义

虚拟形态下 App 本地音频链全停、**不自开驱动会话**（假会话
删除）；App 退居控制台：写参数、读遥测、管注册与端点选择。
ASIO Client 形态维持桥会话形态不变（App 宿主第三方驱动）。

### D-3 跨进程三线契约（单一真相 `AsioDriverShared.h`）

1. **汇端点**：注册表 `HKCU\SOFTWARE\AuraDSP\AsioDriver\
   RenderEndpoint`（端点 ID，App 写、汇读；失效回落系统
   默认）；汇补齐 24/32 位整数格式真转换。
2. **参数**：共享块 `Global\AuraDSP_AsioDriverParams`——
   App 唯一写者（与 APO 参数发布者共用同一参数镜像），载荷
   为引擎 `ApplyParamsString` 同格式参数串，写序「载荷 →
   字节数 → bypass → seq」，驱动泵以 seq 变化触发应用并
   复核稳定；bypass 为块内独立字段。驱动对块缺席（App 后
   启）低频重试打开。
3. **遥测**：共享块 `Global\AuraDSP_AsioDriverTelemetry`——
   驱动泵单写，桥（asiostatus 中转）与 App（viz 合成）双
   读；载荷含 DAW 在场心跳、已处理帧、峰值、汇实际生效端
   点/格式，v2 起含输出/EQ 入口频谱（各 32 段）。

### D-4 契约版本口径

遥测块版本 2（v1 字段布局不动、尾部追加频谱）；读者接受
1–2，写者恒写当前版。参数块版本 1。布局变更必须同步：
契约头、驱动、桥、Dart 读者四处 + 判别 smoke
（`smoke_asio_driver_params` / `smoke_asio_telemetry_contract`）。

## 后果

- 正面：REAPER 无声/无可视化/参数不生效三缺陷同灭；UI 语
  义与实现同构（选 ASIO 模式即进入 ASIO 的配置面）；跨进
  程契约有单一真相与冒烟钉守。
- 约束（已知并接受）：参数串格式承载不了任意文本——字符
  串参数 v1 只带 `graph.order`，LiveProg 代码与 IR/DDC 路
  径不经参数块（DAW 侧引擎相应槽位跑默认），待有真实需求
  时再扩块格式；遥测未含逐声道峰值（viz 左右暂用立体声
  折单值峰值）。
- ADR-009 的附加范式、硬件生命周期与异常防御规范继续有
  效；其「两范式」划分与 ASIO 归属由本 ADR 取代。
- 宾机验收（方案 §六）待含本重构的发行包（r61）后走完，
  不阻塞本 ADR 生效。
