# AuraDSP UI 设计规范与交互标准手册 (Human & AI Collaboration Guide)

> **版本**：v1.0 (2026-10-13)  
> **适用范围**：AuraDSP 移动端（Android / iOS）与桌面端（Windows / macOS / Linux）全部界面、组件与新功能拓展。  
> **受众**：人类工程师、设计人员、以及所有参与工程协作的 AI 智能体（Antigravity、Cursor、Claude、GPT 等）。

---

## 1. 核心设计哲学

AuraDSP 定位为**专业、克制、极简、高阶**的现代暗黑声学控制台。
- **视觉去躁**：界面不应充斥视觉杂质；在移动端有限的屏幕空间中，任何非必要长驻元素（如密集的说明图标）必须被隐藏或按需唤醒；
- **跨端自适应**：同一套 Dart/Flutter 代码库同时服务大屏桌面与触屏手机。桌面端善用鼠标悬停与广阔视口；移动端强化触控热区、滑动唤醒与防误触；
- **一处规范，处处一致**：卡片排版、字体层级、增益保护门、复位手势与帮助问号必须具有完全一致的交互心智模型。

---

## 2. 帮助提示体系规范 (`InfoBadge`)

### 2.1 历史教训与现状统一
过去工程中曾零散出现两类问号：一类是手写的小 `Tooltip(child: Icon(Icons.help_outline_rounded, size: 14))`，另一类是组件化的 `InfoBadge`。
- **痛点**：手写的 `Tooltip` 仅依赖鼠标 hover，触屏移动端几乎无法激活，且无法点击展开/收起，视觉大小割裂；
- **铁律**：**全应用一律废止手写 Tooltip 图标，统一强制使用 `InfoBadge(message: ...)`**。

### 2.2 跨端可见性与交互状态机

```
                      +-------------------+
                      |   环境断点判断     |
                      +---------+---------+
                                |
               +----------------+----------------+
               |                                 |
        [!context.isMobile]                [context.isMobile]
           (电脑/桌面端)                       (触屏移动端)
               |                                 |
        +---------------+                +---------------+
        |  持续常驻可见   |                |  默认持续隐藏   |
        |  opacity: 1.0 |                |  opacity: 0.0 |
        +-------+-------+                +-------+-------+
                |                                |
       (鼠标悬停 300ms 弹出)              (用户滑动界面唤醒)
       (移出即关闭/点击锁定)                     |
                                         +-------v-------+
                                         |   平滑淡入显示  |
                                         |  opacity: 1.0 |
                                         +-------+-------+
                                                 |
                                         (用户停止滑动 2.6s)
                                                 |
                                         +-------v-------+
                                         | 延迟自动平滑隐藏|
                                         |  opacity: 0.0 |
                                         +---------------+
```

### 2.3 触屏点击与防遮挡机制
- **点击切换**：移动端触屏点击 `InfoBadge` 徽标可直接展开气泡；再次点击立即收起；
- **自动淡出**：气泡展开后，内置 **3.5 秒** 自动淡出定时器。若用户未手动收起，3.5s 后气泡安全淡出，绝不永久遮挡下方的滑块或开关；
- **点击热区扩展**：`InfoBadge` 视觉直径为 15.0px，外周带有 4px 透明安全边衬，实际触屏命中区达 23×23px 以上，保证手指触控命中率；
- **隐藏防误触**：移动端问号隐藏时，外层由 `IgnorePointer(ignoring: !isVisible)` 保护，杜绝隐形热区误触。

### 2.4 代码调用范式 (Best Practice)
```dart
// 模式选择、开关旁或标签旁
Row(
  children: [
    Text(l.someFeatureMode, style: labelOf(p, color: p.text)),
    const SizedBox(width: 4),
    InfoBadge(message: l.someFeatureHelpTooltip),
    const Spacer(),
    // 选项控件...
  ],
)
```

---

## 3. 效果器卡片布局架构规范

### 3.1 卡片结构三层模型
每个效果器卡片从上到下严格遵循三层结构：
1. **卡片头 (Header)**：序号、效果名称、延迟读数与主开关 `AuraSwitch`；
2. **核心控制区 (Body)**：只放 1~3 个日常最核心的调音参数（如强度、频率、模式选择 Chip）；
3. **高级扩展区 (Advanced)**：折叠面板 `AdvancedSection`，收纳进阶参数；
4. **输出保护区 (Output Gain Frame)**：输出增益门。

### 3.2 `OutputGainFrame` 统一外框与置底铁律
所有带有输出增益/自动补偿/声像保护控制的效果器（动态压限器、卷积混响、立体声拓宽、哈斯环绕、高频激励器、空间混响等）：
- **必须使用 `OutputGainFrame` 统一外框包裹**；
- **位置必须固定在卡片最末尾**（核心调音完成之后的末级增益保护）；
- **必须支持出厂复位**：
  ```dart
  OutputGainFrame(
    child: ValueSlider(
      label: l.outputGain,
      value: model.effectOutputGain,
      defaultValue: 0.0,
      onResetToDefault: () => model.setEffectOutputGain(0.0),
      min: -12.0,
      max: 12.0,
      unit: 'dB',
      format: (v) => v >= 0 ? '+${v.toStringAsFixed(1)}' : v.toStringAsFixed(1),
      onChanged: model.setEffectOutputGain,
      onChangedEnd: model.setEffectOutputGain,
    ),
  )
  ```

### 3.3 文案极简与去冗余
- 严禁出现让普通用户困惑的术语（如禁止使用“链头处理”等无意义生僻词）；
- 选项标签禁止加注括号缩写（如“动态增强”不要赘述“DBB”，“纯净低架”不要赘述“Shelf”）。

---

## 4. 排版与数值滑块规范 (`ValueSlider`)

### 4.1 统一标签字阶
- 所有参数滑块与单选行前导标题一律使用 `labelOf(p, color: p.text)`（13pt，w600）；
- **严禁私自降级字体**：严禁私自将某些参数标签改成 `captionOf`、变细或改小字号，避免破坏排版网格的严谨度。

### 4.2 单位防重规范
- `ValueSlider` 自带 `unit` 属性，组件会自动在右侧渲染数值与单位；
- `format` 回调函数中**严禁额外拼接单位字符**！
  - ❌ **错误**：`unit: 'ms', format: (v) => '${v}ms'` $\rightarrow$ 界面会渲染成 `1000ms ms`
  - ❌ **错误**：`unit: 's', format: (v) => '${v}s'` $\rightarrow$ 界面会渲染成 `1000ms s`
  - ✅ **正确**：`unit: 'ms', format: (v) => v.toStringAsFixed(0)` $\rightarrow$ 界面正常渲染 `1000 ms`

---

## 5. 处理链与卡片命名对齐规范

`chain_page.dart` 中处理链 16 个阶段展示名函数 `stageLabelOf(l, id)`，必须与 `effects_page.dart` 对应卡片的标题及 Arb 本地化词条严格保持一致：

| stage ID | l10n 字段 | 中文展示名 | 对应效果器卡片 |
|---|---|---|---|
| `gate` | `l.stGate` | 输入门控 | `_GateCard` |
| `bassmono` | `l.stBassmono` | 低频单声道 | `_BassMonoCard` |
| `tube` | `l.tubeTitle` | 电子管温润 | `_TubeCard` |
| `comp` | `l.compTitle` | 动态压限器 | `_CompCard` |
| `bass` | `l.bassBoost` | 低音增强 | `_BassCard` |
| `eq` | `l.eqMultiBand` | 图形均衡器 | `_EqCard` |
| `arbmag` | `l.stArbmag` | 自由幅频响应 | `_ArbMagCard` |
| `convolver` | `l.convTitle` | 卷积混响 | `_ConvolverCard` |
| `ddc` | `l.ddcTitle` | 耳机校准 | `_DdcCard` |
| `liveprog` | `l.stScript` | 实时脚本 | `_LiveprogCard` |
| `crossfeed` | `l.crossfeedTitle` | 串扰消除 | `_CrossfeedCard` |
| `stereo` | `l.stereoWiden` | 立体声拓宽 | `_StereoCard` |
| `haas` | `l.stHaas` | 哈斯环绕 | `_HaasCard` |
| `exciter` | `l.stExciter` | 高频激励器 | `_ExciterCard` |
| `reverb` | `l.spatialReverbTitle`| 空间混响 | `_ReverbCard` |
| `output` | `l.postGain` | 输出增益 | `_OutputGainCard` |

---

## 6. Do & Don't 规范速查清单

| 维度 | ✅ 推荐做法 (Do) | ❌ 严禁做法 (Don't) |
|---|---|---|
| **问号组件** | 使用 `InfoBadge(message: l.tip)` | 手写 `Tooltip(child: Icon(Icons.help_outline))` |
| **移动端问号** | 滑动时平滑唤醒，停止滑动 2.6s 自动收起 | 在移动端持续常驻问号，破坏极简暗黑观感 |
| **输出增益** | 用 `OutputGainFrame` 包裹置底，提供复位 | 散落在卡片中间，与其他声音调制混在一起 |
| **滑块单位** | `unit: 'ms', format: (v) => v.toStringAsFixed(0)` | `unit: 'ms', format: (v) => '${v}ms'` 导致重复 |
| **标签字体** | 统一使用 `labelOf(p, color: p.text)` | 私自改成小字号或细体导致排版不统一 |
| **模块命名** | 处理链、卡片标题、Arb 词条 100% 同步 | 同一效果器在不同页面使用不同同义词 |
