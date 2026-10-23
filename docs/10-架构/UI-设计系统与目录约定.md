# UI 设计系统与目录约定（AuraDSP 桌面端）

> 定位：**UI 层的工程约定说明书**。数值真相源是 `design/tokens/aura.tokens.json`；
> 目录与依赖方向的权威是 `docs/00-总览/项目架构与开发规范.md`。本文补充两者之间的
> 「怎么做」——令牌流水线、重建粒度、i18n 棘轮与待办清单。
>
> 最近更新：2026-10-23（P0 效率组 + P2 令牌生成/i18n 棘轮落地后）

---

## 1. 设计令牌流水线（P2-1）

```
design/tokens/aura.tokens.json          ← 手改（唯一真相源，W3C Design Tokens）
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
└── ui/          （P1 规划）设计系统：chrome / controls / cards / meters
```

**当前**：`features/chrome.dart`（骨架/基础控件）、`features/widgets.dart`
（内容卡片/仪表）、`features/effects/cards_common.dart`（参数控件）三处共享层，
边界靠约定。**P1 目标**：迁入 `lib/ui/`，旧文件留 `export` 薄壳保持调用点零改动，
并加静态断言测试（`ui/` 不得 import `features/` 或 `core/state`）。

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
| P1 | settings_page 拆分 → `features/settings/panels/`；chrome/widgets → `lib/ui/` 薄壳迁移；依赖方向断言；裸 `Slider` 收敛到 `ParamSlider` | ⏳ 待排期 |
| P2 续 | 218 条硬编码中文按页转 arb（建议顺序：settings 68 → channel_routing 20 → gate/comp 27） | ⏳ 逐步 |
