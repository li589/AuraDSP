# UI 设计系统与目录约定（AuraDSP 桌面端）

> 定位：**UI 层的工程约定说明书**。数值真相源是 `app/auradsp_app/design/tokens/aura.tokens.json`；
> 目录与依赖方向的权威是 `docs/00-总览/项目架构与开发规范.md`。本文补充两者之间的
> 「怎么做」——令牌流水线、重建粒度、i18n 棘轮与待办清单。
>
> 最近更新：2026-10-23（P0 效率组 + P2 令牌生成/i18n 棘轮落地后）

---

## 1. 设计令牌流水线（P2-1）

```
app/auradsp_app/design/tokens/aura.tokens.json  ← 手改（唯一真相源，W3C Design Tokens）
        │  python tools/gen_theme.py     ← 改完 JSON 必须重跑
        ▼
app/auradsp_app/lib/core/tokens.g.dart  ← 生成物，禁止手改
        ▼
lib/core/design.dart  (AuraSpace / AuraSize / AuraRadius / AuraDur / AuraCurve)
lib/core/theme.dart   (auraDark / auraLight / aurora 三套 AuraPalette)
        ▼
features/ 一律经 Aura* 常量取数值，禁止散落魔法数
```

**漂移防线**：`test/tokens_parity_test.dart` 把 JSON 与运行时常量逐项比对
（3×14 色 + 间距/语义留白 + 尺寸/圆角 + 动效时长/曲线，共 85 项）。
改了 JSON 忘记重跑生成器 → 该测试必红。

**只校验不写盘**：`python tools/gen_theme.py --check`（CI/提交前用）。

### 数值规范速查

| 类别 | 令牌 | 值 |
|---|---|---|
| 间距 | `AuraSpace.xxs…hero` | 2 / 4 / 8 / 12 / 16 / 24 / 32 / 48（8pt 网格） |
| 语义留白 | `pageX` `pageTop` `cardPad` `cardGap` `rowGap` `contentMaxW` | 32 / 26 / 20 / 16 / 12 / 1080 |
| 圆角 | `AuraRadius.xs/sm/md/lg` | 4 / 6 / 10 / 14（禁止全胶囊；禁阴影堆叠，层次靠明度 + 1px hairline） |
| 动效 | `AuraDur.instant/fast/base/slow/page` | 90 / 140 / 220 / 380 / 260 ms |
| 曲线 | `AuraCurve.standard/emphasized/entrance` | easeOutCubic / cubic-bezier(0.2,0,0,1) / (0.16,1,0.3,1) |
| 字号 | `TokType.hero…micro` | 40 / 26 / 18 / 14 / 12 / 11 |

> 新增令牌：改 JSON → 跑生成器 → 在 `Aura*` 类里加一行转发（或直接用 `Tok*`）。
> 禁止只改 `design.dart` 不改 JSON（parity 测试会红）。

---

## 2. 状态与重建粒度约定（P0 成果）

| 数据类型 | 通道 | 规则 |
|---|---|---|
| 结构性状态（模式切换、挂载、配置） | 粗 `ChangeNotifier`（AppModel） | `_notifyUi()` 已做 microtask 合并（同帧多次变更只发一次）；测试模式保持同步 |
| 1s 级心跳（VB/VAIO/ASIO status） | `model.hbTick`（ValueNotifier） | **禁止**走粗 notify；消费方包 `HbBuilder(tick: model.hbTick, ...)` |
| 30fps 可视化（spectrum/level/GR） | 独立 `ValueNotifier`（state.dart 中 23 个） | 只给 `ValueListenableBuilder`/paint 消费 |
| 每秒硬件读数（电平表、保护行） | 心跳 + `RepaintBoundary` | 重绘不外溢父级 |

**页面容器**：`IndexedStack` 保活（切页零重建、滚动/展开态保留），配套：

- 每页 `TickerMode(enabled: i == _index)` —— 离屏停动画；
- 页面定时器（如插件页 1s status 轮询）必须按 `model.visiblePage` 门控，
  否则保活后会每秒白跑 IPC；
- 新增页面记得在 `core/nav.dart` 的 `AppPage` 枚举 + `shell._destinations`
  同步顺序（索引即导航位）。

**禁止**：在 `ListenableBuilder` 的 builder 闭包里引用外层 `build()` 的局部变量
（捕获旧绑定；2026-10-22 插件页 Hero 卡教训）。可变读取一律写进 builder 作用域。

---

## 3. 目录与依赖方向

```
lib/
├── engine/      传输层（FFI / isolate / 桥）——不依赖 UI
├── core/        state / config / theme / design / l10n / tokens.g
├── features/    页面与业务组件——只经 core/ 访问基础设施
└── ui/          设计系统（P1-2 已落地）：chrome.dart（骨架/基础控件）、widgets.dart（卡片/仪表）
```

**P1-2 已落地（2026-10-23）**：`chrome.dart` / `widgets.dart` 已迁入 `lib/ui/`，
旧路径 `features/chrome.dart`、`features/widgets.dart` 改为纯 `export` 薄壳
（调用点零改动；`test/layering_guard_test.dart` 断言薄壳不得再长实现）。

**特殊件**：`features/effects/cards_common.dart` 是 `part of '../effects_page.dart'`
的 part 文件，与 effects 库同一编译单元，**不能**单独迁入 `ui/`；若迁移需先把
effects_page 改为库 + part 结构（P1 后续，非必需）。

**P1-3 守卫**：`test/layering_guard_test.dart` 四项断言——`ui/` 不得 import
`features/`；`engine/` 不得依赖 UI；`core/` 不得依赖 `features/`；两个薄壳只允许
`export`。

**P1-1 拆分（2026-10-23）**：`features/settings_page.dart` 2509 行 → 父文件 371 行
（SettingsPage + State）+ `features/settings/panels/` 五个 part：
`sections`(456) / `hardware_drivers`(531) / `hardware_io`(784) / `vb_theme`(398)。用 part 而非独立库，是为了保留私有符号可见性、
做到零逻辑改动的机械拆分。

命名：`AuraXxx` 用于设计系统控件（AuraChip/AuraSwitch/AuraSegmented）；
`SectionCard`/`ParamSlider` 等语义件保持现名；页面私有件 `_Xxx`。

---

## 4. i18n 约定与棘轮（P2-2）

- 新文案一律进 `lib/l10n/app_{zh,en,ja}.arb`，跑 `flutter gen-l10n`，
  界面用 `l10nOf(context).key`。
- **棘轮**：`test/l10n_cjk_baseline.txt` 记录现存硬编码中文（当前 218 条 / 24 文件，
  重灾区 `settings_page.dart` 68 条）。`test/l10n_cjk_guard_test.dart` 断言
  「任何文件不得超过基线」——新增硬编码直接红。
- 还债流程：改代码 → `python tools/l10n_cjk_scan.py` 看剩余量 →
  `python tools/l10n_cjk_scan.py --baseline` 降基线 → 与代码一起提交。
- 扫描规则（三方一致）：去块注释、跳过 `//` 行、统计字符串字面量内的 CJK。

---

## 5. 当前状态与后续（2026-10-23）

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 页面保活、心跳级联、重绘隔离 | ✅ `9616870` |
| P2-1 | 令牌生成器 + 85 项 parity 测试 | ✅ 本轮 |
| P2-2 | i18n 棘轮基线 + 守卫测试 | ✅ 本轮（债务 218 条待逐步清） |
| P2-3 | 本文档 | ✅ 本轮 |
| P1-1 | settings_page 2509 行 → 370 行 + 3 个 part（sections/hardware/vb_theme） | ✅ 本轮 |
| P1-2 | chrome/widgets → `lib/ui/`，旧路径 export 薄壳 | ✅ 本轮 |
| P1-3 | 依赖方向守卫（ui/engine/core 互不越级 + 薄壳约束） | ✅ 本轮 |
| P1-4 | 裸 `Slider` 收敛 —— **审计结论：已达成**。全库真实裸 `Slider(` 仅 3 处：`effects_page.dart` 内部（ValueSlider 基座实现，正确）、`input_card` 条形滑块（自定义 track/thumb，非参数行）、`liveprog_page` 动态参数行（自带 label/读数列）。抽象早已到位：47 处 `ParamSlider` + 23 处 `ValueSlider` + 3 处 `ParamOutputGainSlider`。原「78 处」是 grep 把 `ParamSlider(` 调用计入的度量错误。 | ✅ 已核销 |
| P1-1b | `hardware.dart` 1309 → `hardware_drivers.dart`(531) + `hardware_io.dart`(784) | ✅ 本轮 |
| P2 续 | i18n 还债：① `chrome.dart` 空设备占位（1 条）；② `channel_routing_selector` 手写 zh/en 双语整体转 arb（20 条，**同时补齐 ja**）。基线 218 → **197**（25 文件）。`l10nOf` 上移 `core/ui_helpers.dart`（ui/ 与 features/ 共用，widgets 保留 re-export 兼容） | 🔄 进行中 |
| P2 续 | 218 条硬编码中文按页转 arb（建议顺序：settings 68 → channel_routing 20 → gate/comp 27） | ⏳ 逐步 |
