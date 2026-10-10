# ADR-004 — 插件多插槽（2 路）与五级链阶段插入拓扑，插件宿主保持进程内

- 状态：**已接受**（2026-10-10）
- 关联：[ADR-001](ADR-001-windows-v1-process-level.md)（Windows v1 进程内链路）、[扩展规划 §2.2/§9.1](../APP-插件与信号图扩展规划.md)、[UI-六页 §4.4](../UI-六页架构与M3.5重排序方案.md)
- 取代：[扩展规划 §2.2](https://) 提出的"插件沙箱桥（Plugin Bridge Process）"作为 **v1 首选形态**的设想

## 背景

1. M1 插件宿主首版落地时是**单插槽、单插入点**（`auradsp_plugin_load` 一套 API，插件固定插在 vendor 链与 Freeverb 之后）。这带来两个硬限制：
   - 无法同时挂载两个第三方插件（如"均衡器 + 饱和器"串联），用户诉求落不了地；
   - 插件**无法选择插入位置**，只能在固定点生效——而"混响前置 / 限幅后置"在音频工程上是常规需求。
2. M3.5 的 12 级 vendor 链重排序（P-004 表驱动补丁）已在 2026-10-09 落地，**vendor 内部 12 个 stage 可任意排序**（`graph.order`），但第三方插件在 vendor 链之外，无法参与排序，形成"内部可重排、外部不可插"的割裂。
3. 扩展规划 §2.2 原设计为**独立桥进程**（共享内存环 + 命名管道）承载插件，理由是崩溃隔离与 GPLv3 边界。但首版即上桥进程会把风险集中到 IPC 抖动与跨进程音频对齐上，验证成本高。

## 决策

### 1. 进程内宿主，双插槽

插件宿主 v1 维持**进程内**（与 ADR-001 的 v1 进程内处理链一致），但从单插槽扩展为**固定 2 个插槽**（`PluginHostManager::kMaxPluginSlots = 2`）。

- 2 路是刻意上限，不是占位符：桌面 v1 面向"EQ + 饱和/压缩"这类最主流的二段式串联，2 路已覆盖绝大多数真实用例；同时把宿主侧内存、UI 信息密度与崩溃影响面控制住。
- 每个插槽独立持有实例、bypass、latency、insertStage 四个状态（`std::atomic`，与音频线程无锁）。
- 插槽数**不通过 ABI 暴露为可变**，而是常量 `auradsp_plugin_get_num_slots()` 返回——UI 依此渲染 Slot 1 / Slot 2 标签页，不做动态增删。

### 2. 五级链阶段拓扑（插入点）

插件插槽通过 `insertStage`（0..4）选择插入 `auradsp_process` 链中的固定锚点，实现"外部可插"与"内部可重排"的统一：

| Stage | 锚点位置 | 语义 |
|---|---|---|
| 0 | `Pre-DSP`，链头 | 低频搁架 EQ 之前，作用于最原始输入 |
| 1 | `Pre-Vendor`，vendor 链之前 | 低频搁架 EQ 之后、12 级 vendor 效果之前 |
| 2 | `Post-Vendor`，vendor 链之后 | 12 级 vendor 效果之后、Freeverb 混响之前 |
| 3 | `Post-Reverb`，默认 | Freeverb 混响之后 |
| 4 | `Post-Limiter`，链尾 | NaN/Inf 清洗与 ±10.0 钳位之后，最终安全输出 |

- **默认值 = Stage 3**，与 v1 单插槽时期的固定插入点行为一致，保证升级不改变既有听感。
- Stage 遍历由 `process_plugin_slots_stage(h, stage, ...)` 统一承担：对每个 stage，按插槽序遍历"已激活 ∧ 未旁路 ∧ 插入阶段匹配"的实例，平面缓冲 `plugin_buf_l/r` 就地进出。
- 音频线程上**无分配、无锁、无 IO**：stage 匹配只读 `std::atomic`，循环边界为编译期常量。

### 3. ABI 演进：新增 slot 族，旧符号保留

新增 13 个导出：

```
auradsp_plugin_get_num_slots
auradsp_plugin_slot_{load,unload,set_bypass,get_bypass,get_latency,get_status}
auradsp_plugin_slot_{show_editor,close_editor,is_editor_open}
auradsp_plugin_slot_{save_preset,load_preset}
auradsp_plugin_slot_{set_insert_stage,get_insert_stage}
```

**旧单插槽导出全部保留**，实现为转发至 slot 0 的薄封装（`auradsp_plugin_load` → `auradsp_plugin_slot_load(h, 0, ...)`），保证旧 UI / 旧测试 / 第三方调用方零改动可用。ABI 单调向后兼容，无破坏性变更。

### 4. 预设序列化

`auradsp_plugin_slot_{save,load}_preset` 走 VST3 `getState/ setState` 与 CLAP `extension_data` 的既有路径，由宿主负责流读写；Dart 侧只管文件落盘位置（`%APPDATA%/AuraDSP/plugin_presets/<插件名>/`，`.aurapreset` 扩展名，非法文件名字符清洗）。**引擎侧不做路径解析，不碰外部文件 IO**。

## 后果

**正面**
- 用户可同时挂 2 个插件并各自选择插入点，"混响前置 / 限幅后置"等工程惯例可落地。
- 处理链页（chain_page）从"只读 vendor 12 级顺序"升级为**全局阶段拓扑视图**：Stage 0~4 与 vendor 内部节点同屏呈现，活跃插槽以内联 `S<n>:<插件名>` 芯片渲染在其锚点节点内。
- ABI 向后兼容，旧消费者不受影响。

**负面 / 已知限制**
- **插件崩溃会带崩宿主进程**（进程内的固有代价）。这是 v1 明确接受的取舍；桥进程化推迟到 M6，且必须先有崩溃复现样本与隔离收益的量化依据。
- 插件自身内部状态机（如 Auto-Tune 的音高缓存）与信号链重排的交互未做深度验证；重排后可能出现需重新初始化才正确的插件。
- Stage 数量（5）是编译期常量。若未来需要用户自由拖拽插件到任意 vendor stage 之间，需要再次开 ADR 扩展锚点表（届时评估在 `JDSPChainItem` 上开动态外部节点位）。
- 两个插槽各自的延迟累加进总延迟读数，但未做补偿调度；两插件串联延迟超阈值时仅在 UI 标注，未自动降级。

**回退条件**
- 插件宿主崩溃率超出可接受范围（需先建立崩溃采集口径）；
- 或出现必须依赖桥进程隔离才能商用的插件场景（如需要独立授权校验的专有插件）。
满足任一条即启动 ADR-005 重新评估桥进程化，并同步更新本文档。

## 验证记录（2026-10-10）

- `test/smoke/smoke_multislot_and_stages.py` — 10 组断言 100% PASS：插槽数=2、双槽同时载入（同槽位互斥与跨槽独立）、Stage 0/4 分别写入并回读、预设流式序列化往返（4143 字节）、双插槽音频通路切换（激活时 / 旁路时）、卸载与销毁。
- `test/ui/ui_verify_vst_and_eel.py` — 置顶前置 UI 端到端验证：双插槽选择器、自定义扫描目录、处理链页 Stage 0~4 全局拓扑拖拽、各槽阶段下拉调节。
- 回归：`python test/runner.py --smoke` 10/10 PASS，`flutter analyze` 0 问题。