# AuraDSP UI 设计系统与视觉交互铁律规范 (UI Design & Interaction Spec)

> **生效级别**：P0 级强制规范。所有参与 AuraDSP（移动端 + 桌面端）UI 开发的 AI Agent 与人类工程师必须严格遵守。任何违背本规范的代码提交均视为缺陷。

---

## 1. 统一问号与帮助气泡规范 (`InfoBadge` 强制铁律)

### 1.1 绝对禁止与强制替代
- **严禁私自手写 Tooltip 图标**：严禁在任何卡片、Row、或者标签旁边手写 `Tooltip(child: Icon(Icons.help_outline_rounded))`。
  - *原因*：原生 `Tooltip` 在移动触屏上极难长按激活、不支持点击切换展开、样式与整体设计脱节，会导致用户看到“两类问号、小的点不了”的严重交互缺陷。
- **强制统一使用 `InfoBadge`**：凡是界面中需要帮助问号、解释气泡、模式说明、参数释义的地方，**一律统一使用 `InfoBadge(message: ...)`**。

### 1.2 跨端交互与显隐状态契约
AuraDSP 采用跨平台自适应响应系统：
1. **指针环境（`!context.usesTouchInput`；桌面与窄窗口鼠标均适用）**：
   - **持续常驻显示**：指针环境视口充裕，问号徽标常驻保持可见；
   - **交互反馈**：鼠标悬停 300ms 自动弹出气泡；鼠标移开即隐藏；点击徽标可切换锁定显示/手动关闭。
2. **触屏环境（`context.usesTouchInput`；Android/触屏设备，与窗口宽度解耦）**：
   - **平时持续隐藏**：为了保持极简高阶的暗黑美学，触屏非滑动状态下问号徽标透明度为 0 并忽略指针命中 (`IgnorePointer(ignoring: true)`)；
   - **滑动唤醒机制**：用户滑动页面或列表时，触发 `recordScroll()`，问号徽标平滑淡入（`AnimatedOpacity 1.0`）；
   - **延迟自动淡出**：用户停止滑动后，延迟 **2.6 秒**，问号平滑淡出隐藏；
   - **触屏点击响应**：用户可直接点击问号弹出解释气泡。气泡弹出后若无操作，**3.5 秒后自动淡出收起**，防止遮挡关键控制项；用户再次点击徽标可立即关闭。
3. **架构支持**：
   - 全局/页面根骨架 `PageScaffold` 已内嵌 `HelpVisibilityController` 与 `HelpVisibilityScope`，自动监听 `ScrollNotification`；
   - 新增组件只需直接放置 `InfoBadge(message: l10n.someTip)`，无需手动处理滚动监听，Scope 会自动联动生效。
4. **宽度与输入能力分离（Q3 owner 裁定，2026-11-20）**：
   - `AuraBreakpoint` / `isCompactWidth` 只决定布局形态；
   - `AuraInputScope` 在 `MaterialApp.builder` 中包住 Navigator（覆盖页面与 Dialog），监听真实 `PointerDown`，以 `context.usesTouchInput` 决定交互语义；窄桌面窗口（鼠标）不得按移动端隐藏徽标。

---

## 2. 效果器卡片布局架构规范

### 2.1 极简暗黑与文案去重
- **标题极简**：卡片标题与副标题必须直观，严禁出现让普通用户费解的内部工程术语（如禁止使用“链头处理”等生僻词）；
- **去除冗余后缀**：模式名称和参数名称严禁加注无意义缩写（例如“动态增强”禁止额外赘述“DBB”，“纯净低架”禁止额外赘述“Shelf”）。

### 2.2 核心参数与高级参数分层
- **主卡体**：只放用户最常调节的 1~3 个核心控制项（如开关、模式切换 Chip、主要增益/频率滑块）；
- **高级参数收纳**：所有进阶参数（如启动时间、释放时间、侧链去齿音、时频分辨率等）必须收纳在 `AdvancedSection` 折叠面板中，保持初次展示的极简秩序。

### 2.3 输出增益门统一外框 (`OutputGainFrame` 铁律)
凡带有输出增益补偿、保护门或立体声声像等保护性输出参数的效果器卡片（动态压限器、卷积混响、立体声拓宽、哈斯环绕、高频激励器、空间混响等）：
1. **必须使用 `OutputGainFrame` 包裹**；
2. **位置必须固定放置在卡片最末尾**（位于所有核心调音滑块之后）；
3. **出厂复位能力**：输出增益滑块必须支持右键/双击复位为 `0.0 dB`：
   ```dart
   OutputGainFrame(
     child: ValueSlider(
       label: l.outputGain,
       value: model.someOutputGain,
       defaultValue: 0.0,
       onResetToDefault: () => model.setSomeOutputGain(0.0),
       min: -12.0,
       max: 12.0,
       unit: 'dB',
       format: (v) => v >= 0 ? '+${v.toStringAsFixed(1)}' : v.toStringAsFixed(1),
       onChanged: model.setSomeOutputGain,
       onChangedEnd: model.setSomeOutputGain,
     ),
   )
   ```

---

## 3. 字体风格与视觉层级铁律

- **统一前导标签样式**：参数滑块、模式选择、单选组的前导标签一律使用 `labelOf(p, color: p.text)`（13pt, w600）；
- **严禁私自矮化或变细**：严禁私自将某些参数标签改成 `captionOf`、薄字体或改小字号（如严禁把“分析颗粒度”做成薄小字体）。全界面所有参数前导标签的排版骨架与视觉比重必须严格一致。

---

## 4. 数值滑块与单位规范 (`ValueSlider`)

- **防单位重复**：`ValueSlider` 已有独立 `unit` 属性（如 `ms`, `dB`, `Hz`, `%`）。
  - **错误范式**：`unit: 's', format: (v) => '${v}s'` $\rightarrow$ 界面会显示成 `1000ms s` 或 `0.5s s`。
  - **正确范式**：`unit: 'ms', format: (v) => v.toStringAsFixed(0)` $\rightarrow$ 界面由组件自动规范拼接为 `1000 ms`。
- **出厂默认值复位**：所有滑块均需提供 `defaultValue` 与 `onResetToDefault` 回调，支持鼠标右键、触屏双击瞬间重置出厂值。

---

## 5. 处理链与卡片命名对齐规范

- `chain_page.dart` 中处理链节点（`kStageMeta` 共 20 个阶段）的展示名映射函数 `stageLabelOf(l, id)`，必须与 `effects_page.dart` 对应卡片的标题以及 Arb 国际化文件严格一一对应：
  - `gate` $\rightarrow$ `l.stGate`（噪声门）
  - `dyneq` $\rightarrow$ `l.dyneqTitle`（动态均衡器）
  - `filter` $\rightarrow$ `l.stFilter`（滤波器）
  - `bassmono` $\rightarrow$ `l.bassMonoModule`（低频单声道化）
  - `tube` $\rightarrow$ `l.tubeTitle`（电子管模拟器）
  - `comp` $\rightarrow$ `l.compTitle`（动态压限器）
  - `bass` $\rightarrow$ `l.bassBoost`（低音增强）
  - `eq` $\rightarrow$ `l.eqMultiBand`（多段图形均衡器）
  - `arbmag` $\rightarrow$ `l.stArbmag`（任意响应 EQ）
  - `convolver` $\rightarrow$ `l.convTitle`（脉冲响应）
  - `ddc` $\rightarrow$ `l.ddcTitle`（VDC 空间校正）
  - `liveprog` $\rightarrow$ `l.stScript`（脚本）
  - `crossfeed` $\rightarrow$ `l.crossfeedTitle`（串扰消除）
  - `stereo` $\rightarrow$ `l.stereoWiden`（立体声扩展）
  - `haas` $\rightarrow$ `l.stHaas`（差分环绕）
  - `spatial` $\rightarrow$ `l.spatialTitle`（空间音效）
  - `exciter` $\rightarrow$ `l.stExciter`（激励器）
  - `loudness` $\rightarrow$ `l.stLoudness`（响度补偿）
  - `reverb` $\rightarrow$ `l.spatialReverbTitle`（空间混响）
  - `output` $\rightarrow$ `l.postGain`（输出增益）
- 严禁同一效果器在处理链页和效果页使用不同的同义词。

---

## 6. 浮层（Dialog）窄屏规范（P2，2026-11-20）

- 所有 `Dialog` / `AlertDialog` 必须设置 `insetPadding: auraDialogInset(context)`（`ui/aura_dialog.dart`）；窄屏 12px，桌面沿用 40/24。
- 内容尺寸禁止裸写固定宽高：用 `AuraDialogConstraints(maxWidth:, maxHeight:)` 包住，内部保留显式设计尺寸；`AlertDialog` 内容含 `ListView` 等惰性视口时**不要**用 `width/height: double.infinity`（会触发 intrinsic 尺寸断言）。
- 360px 下浮层实际矩形不得超出视口；主操作按钮命中区 ≥48×48。
- 新增浮层必须在 `test/dialog_layout_test.dart` 或对应页面测试中补 360 回归。

---

## 7. 页内窄屏降级规范（P3，2026-11-20）

- **判定基准是内容宽度，不是视口断点**：`PageScaffold` 在 mobile/tablet 档留白不同，480 档内容区可能比 360 更窄。凡"左右两簇争宽"的布局，用 `LayoutBuilder` 取 `maxWidth` 判定（首页 hero、视效 HUD 均已按此修正）。
- **`Row(mainAxisSize.min)` 的子项拿到的是无界主轴约束**，内层 `Flexible`/`Expanded` 不生效。要让文本/胶囊可压缩，必须让它们处在有界父约束下（外层 `Expanded`/`Flexible`，或 `LayoutBuilder` 给出的 maxWidth）。
- **`SectionCard.trailing` 在 <480 自动换行**（`SectionTitle` 已内建）；新增卡片不要再自己写"标题 + 动作"同排 Row。
- **必须全部可见的等价控件**（页签、分段控件）窄屏用 `FittedBox(fit: BoxFit.scaleDown)` 等比缩小，不要藏进横向滚动。
- **可折行的控件组**（视效 HUD、量程胶囊）窄屏用 `Wrap` 折行；禁止用 `SingleChildScrollView` 把主操作藏到视口外。
- 降级允许压缩/截断次级文本，**不允许为了过测试隐藏主操作**。新增页面必须在 `test/narrow_pages_test.dart` 的 `_pageNames` 对应档位补 360 回归。

---

## 8. 触控目标（R7，2026-11-20）

- **尺寸按输入能力判定，不按视口宽度**：`context.usesTouchInput` 为真时，交互控件命中区 ≥48×48；指针环境保持紧凑视觉尺寸。
- 命中区变大**必须让布局盒真的到 48**：`RenderBox` 只在自己尺寸内命中，`OverflowBox`/负偏移画出去的部分收不到点击。做法是 `SizedBox(48) + Center(视觉件)`。
- 已达标：`InfoBadge`（23↔48）、顶栏 `_IconAction`（32↔48）、底栏六项（60）。
- 未达标（R7-b，需单独一轮）：`AuraChip`、`AuraDropdown` 触发器、效果卡开关等 28–32 高控件。
- 回归在 `test/touch_target_test.dart`；新增可点控件请同步加断言（widget 测试默认平台是 android，断言顺序固定「先鼠标 → 再触屏」）。
