# app/auradsp_app — Flutter 应用约定（Dart，人 + AI 必读）

> 顶层总纲见仓库根 `AGENT.md`。本文件只收 **lib/ + test/ 内才成立** 的硬约定。

## 1. 新参数全链路（按序，缺一不可；dyneq 21 参数范例）

`ParamId` 常量 → `ParamDefaults` → state 字段 → setter（存值+钳位+`setInt/setFloat`）
→ 推送块（push-all）→ `_mirror` 回写 → isolate `idp` + 回读 map + state 读回
→ preset 快照/恢复 → UI 控件 → l10n。
setter 只存本地不下发 = 死控件（Issue #1），一经发现要么接线要么删控件。

## 2. 新效果 stage 五件套（chain_page）

`kStageMeta` + `kDefaultCoreOrder` + `isStageEnabled` + `toggleStage` +
`stageLabelOf`（配 `stXxx` l10n）。`graph.order` 发送前用
`filterVendorOrder` 只留 12 个 vendor id（Issue #4）。

## 3. preset 兼容铁律

- 恢复用 `if (... != null)` 容忍缺字段（老预设不碰新开关，要有回归测试）。
- 顺序：参数先行，enable 最后；加字段不 bump 版本（删除/改义才 bump）。
- 快照/恢复对称测试是新效果的标配（exciter/dyneq 范例）。

## 4. l10n

- 只改 `lib/l10n/app_{zh,en,ja}.arb`，跑 `flutter gen-l10n` 生成；
  `lib/l10n/gen/` **永远手不动**。三语一次齐，缺语种 = CI 红线。

## 5. 测试

- 一律 `AppModel(testing: true)`（不拉真 isolate、不落 session，Issue #2）。
- float32 回读断言用 `1e-6`（`closeTo(x, 1e-9)` 必挂，Issue #2）。
- 构建永远带 `--no-tree-shake-icons`，否则 MaterialIcons 空白。
- isolate 发送全用 `?.` 空安全；testing 下无 port 是常态不是异常。
