# AOCI-Code / CodeGraph 读取范围与子代理边界

适用范围：本仓库所有主代理与子代理。目标是复用认知而不反复传输全索引；本规则不覆盖 AOCI 工具合同、Guide 或安全停点。

## 1. 读取模式

每个任务必须隐式或显式使用以下一种模式：

- `NONE`：不读取 AOCI 条目；只读项目规范、任务 brief 与源码。适合单文件机械修改、测试修补和已给出完整接口的任务。
- `SCOPED`（默认）：只读取与任务有关的 AOCI Entry、CodeGraph 符号/调用关系和源码。适合定位、排障、单模块实现和任务级审查。
- `FULL`：读取完整 Whole-Index。仅限全局架构理解、跨域重构、用户明确要求、AOCI Guide 要求，或已知上下文压缩后的强制恢复。

## 2. 主代理决策顺序

1. 已有可靠完整认知时直接复用，不因新任务、新子代理或新阶段自动重读。
2. 局部任务默认 `SCOPED`；先 CodeGraph，再 AOCI 检索，最后源码确认。
3. 只有命中 `FULL` 条件时才调用普通 `aoci_overview`；需要状态事实时用 `check_only=true`。
4. 已知上下文压缩恢复仍按 AOCI 合同强制完整重载；这是 `FULL` 的例外，不可用局部检索替代。
5. 全量链一旦开始必须连续完成并只提交一次 Attestation；不得边读边让子代理重复加载。

## 3. SCOPED 的标准路径

1. 主代理确认 CodeGraph 索引状态；过期时由主代理运行 `codegraph sync`，子代理不得自行全量重建。
2. 用 `codegraph context`、`query`、`node`、`callers`、`callees` 获取任务相关符号与代码块。
3. 用 `aoci_search` 按关键词或 Tag 找候选，用 `aoci_get_entries` 只读精确路径或 `code:` 对象。
4. 对要修改或定罪的结论，回到源码通读相关段落并 grep 全部引用面；索引冲突以源码为准。
5. ABI 导出、Dart↔C FFI、共享内存块名等字符串接线必须额外按符号名 grep，不得相信 CodeGraph 空结果。

## 4. 子代理派发合同

主代理每次派发必须显式写入以下字段；缺省按 `NONE` 执行：

```text
AOCI_READ_MODE: NONE | SCOPED | FULL
AOCI_SCOPE: <精确路径、code: 对象或关键词；NONE/FULL 时写 none>
AOCI_FULL_REASON: <仅 FULL 必填；否则 none>
CODEGRAPH_SCOPE: <符号、文件或任务短语；none 表示禁用>
AOCI_MAINTENANCE_AUTHORIZED: false
```

- 子代理不得自行调用 `aoci_rules`、普通 `aoci_overview`、`aoci_maintain`、`aoci_update_entry` 或 `aoci_report`，除非主代理在同一 brief 中明确授权并给出原因。
- `SCOPED` 只允许在给定路径/关键词内调用 `aoci_search` 与 `aoci_get_entries`；需要扩大范围时先向主代理报告。
- `FULL` 默认只允许主代理执行；子代理仅在跨域架构任务且主代理明确授权时读取，并不得把全索引正文复制进报告或后续 prompt。
- 主代理负责把相关约束摘要或精确 Entry 传给子代理，不传 Whole-Index 正文。

## 5. 维护与交接

- AOCI 维护由主代理在受管理对象达到最终稳定状态后统一执行；子代理只报告变更与证据。
- 任务交接只保留 receipt 身份、未完成写入/Recovery 状态和读取模式，不保留或摘要 Whole-Index 正文。
- 禁止用 Memory、历史会话、CodeGraph 或局部 Entry 冒充当前完整认知；禁止为“保险起见”重复全量读取。
