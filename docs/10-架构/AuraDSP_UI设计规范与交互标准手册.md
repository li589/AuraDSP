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

`chain_page.dart` 中处理链 20 个阶段（`kStageMeta`）展示名函数 `stageLabelOf(l, id)`，必须与 `effects_page.dart` 对应卡片的标题及 Arb 本地化词条严格保持一致：

| stage ID | l10n 字段 | 中文展示名 | 对应效果器卡片 | 架构归属 |
|---|---|---|---|---|
| `gate` | `l.stGate` | 噪声门 | `_GateCard` | 自研 C++20 |
| `dyneq` | `l.dyneqTitle` | 动态均衡器 | `_DyneCard` | 自研 C++20 |
| `filter` | `l.stFilter` | 滤波器 | `_FilterCard` | 自研 C++20 |
| `bassmono` | `l.bassMonoModule` | 低频单声道化 | `BassShapingCard`（BassMono 子模块） | 自研 C++20 |
| `tube` | `l.tubeTitle` | 电子管模拟器 | `_TubeCard` | Legacy 12 级链 |
| `comp` | `l.compTitle` | 动态压限器 | `_CompressorCard` | Legacy 12 级链 |
| `bass` | `l.bassBoost` | 低音增强 | `_BassCard` | Legacy 12 级链 |
| `eq` | `l.eqMultiBand` | 多段图形均衡器 | `_EqualizerCard` | Legacy 12 级链 |
| `arbmag` | `l.stArbmag` | 任意响应 EQ | `_ArbmagCard` | Legacy 12 级链 |
| `convolver` | `l.convTitle` | 脉冲响应 | `_ConvolverCard` | Legacy 12 级链 |
| `ddc` | `l.ddcTitle` | VDC 空间校正 | `_DdcCard` | Legacy 12 级链 |
| `liveprog` | `l.stScript` | 脚本 | `LiveprogPage`（独立页） | Legacy 12 级链 |
| `crossfeed` | `l.crossfeedTitle` | 串扰消除 | `_CrossfeedCard` | Legacy 12 级链 |
| `stereo` | `l.stereoWiden` | 立体声扩展 | `_StereoCard` | Legacy 12 级链 |
| `haas` | `l.stHaas` | 差分环绕 | `_HaasCard` | 自研 C++20 |
| `spatial` | `l.spatialTitle` | 空间音效 | `_SpatialCard` | 自研 C++20 |
| `exciter` | `l.stExciter` | 激励器 | `_ExciterCard` | 自研 C++20 |
| `loudness` | `l.stLoudness` | 响度补偿 | `_LoudnessCard` | 自研 C++20 |
| `reverb` | `l.spatialReverbTitle` | 空间混响 | `_SpatialReverbCard` | Legacy 12 级链 |
| `output` | `l.postGain` | 输出增益 | `_PostCard` | Legacy 12 级链 |

---

## 6. 处理链节点输出电平监控设计规范 (`StagePeakMeter`)

### 6.1 视觉规格与硬件点阵美学
处理链各行右侧的电平表采用**专业模拟硬件合成器风格的 LED 分段点阵灯柱**（`_SynthLedLadderMeter` + `_SynthLedPainter`）：
- **分段色彩与声学阈值**：
  - 底座与安全段（-60 dBFS ~ -12 dBFS）：荧光绿（Accent 主题色）；
  - 动态预警段（-12 dBFS ~ -3 dBFS）：过渡暖黄（Warning 琥珀色）；
  - 峰值极限段（-3 dBFS ~ 0 dBFS+）：过载亮红（Error 削波提示）；
- **熄灭底座感**：未被点亮的 LED 灯珠必须保留半透明暗色微底（`alpha: 0.15`），模拟硬件 LED 关断时的玻璃微透质感；
- **行高与布局**：行高固定为 **46 ~ 48px**，右侧预留出整齐的 LED 灯柱插槽与旁路胶囊（`_StageBypassPill`），形成紧凑有致的桌面 DAW 专业质感。

### 6.2 真实输出电平契约 (Per-Stage True Output)
- **输出电平唯一定义**：处理链节点右侧显示的电平，**必须且只能是该模块自身处理后的真实输出峰值（Output Level）**，严禁使用整链总输出或输入电平充数；
- **重排序免疫（Order-Independent Mapping）**：
  - 引擎在遍历执行处理链时，于各 stage 函数调用后立即做 $O(1)$ 局部峰值扫描，并严格按该模块固有的静态 `stageIdx` 写入槽位；
  - UI 侧通过 `stageMeterIndex(id)` 绑定固定的逻辑槽位，**拖拽重排节点位置时，电平读数跟随模块自身移动**，绝不随动态位置发生错位；
- **旁路/直通行为**：当模块被旁路（Bypassed）或未启用时，其输出电平自然退化为其输入信号电平（直通），视觉上清晰反映“信号无衰减穿过”。

### 6.3 全 20 级节点输出电平表实现与槽位规范 (ABI v2)
- **全 20 级节点全量覆盖**（节点电平占槽位 0..20，共 21 槽；GR 另占 24..29）：
  - **Legacy 12 级链（槽位 0..11）**：`tube`(0), `comp`(1), `bass`(2), `eq`(3), `arbmag`(4), `convolver`(5), `ddc`(6), `liveprog`(7), `crossfeed`(8), `stereo`(9), `reverb`(10), `output`(11)；
  - **Gate 输入门控（槽位 12..13）**：槽位 12 为输入前测点（`input_lvl_in`），槽位 13 为本级真实输出峰值（`input_lvl_out` / `gate`）；
  - **自研 7 节点（槽位 14..20）**：`dyneq`(14), `filter`(15), `bassmono`(16), `haas`(17), `exciter`(18), `loudness`(19), `spatial`(20)；
  - **GR 计量（槽位 24..29）**：limiter / comp / gate / dyneq low / mid / high；
  - **扩展预留（槽位 21..23、30..31）**：供后续三方插件插槽及多通道扩展使用（恒置 -120 dBFS）；
- **ABI 容量升级（ABI v2 / 1600 字节）**：`auradsp_viz_frame` 的 `stage_levels_l/r` 物理长度保持 32；v2 在 536B 前缀后追加 `channel_count`、`channel_levels[8]`、`stage_ch_levels[32][8]`，全帧严格锁定在 1600 字节（C ABI、Dart FFI 与 Python 冒烟测试镜像保持强校验）；
- **静态映射与优雅隐退**：`core/state/state_chain.dart` 中的 `stageMeterIndex` 采用纯静态 ID 匹配，与用户在链页的实时拖拽重排 `graph.order` 彻底解耦；未知或未注册 stage 索引返回 `-1`，UI 采用 `const SizedBox.shrink()` 优雅保护。

### 6.4 多声道支持约定 (Multichannel Capability)
- **UI 动态扩展就绪**：
  `_SynthLedLadderMeter` 与 `_SynthLedPainter` 内部直接接收 `List<double> channelsDb`，支持动态计算列宽与边距。若底层提供 2/4/6/8 维电平，组件原生自适应渲染 2/4/6/8 列并排点阵；
- **Phase A 声道矩阵下混包络约定**：
  依照 [ADR-003](../adr/ADR-003-multichannel-matrix.md)，引擎多声道处理（5.1/7.1）外置了 M→2 下混与 2→M 上混矩阵，链内各节点在物理上运行于下混后的 2 声道核心。因此，**Phase A 阶段处理链电平表展示的是“并入了环绕声信号的核心立体声输出包络”**；
- **Phase B 现行口径**：
  离散多声道（`channels.mode=1`）已按 8 声道掩码逐声道/成对处理 Category A，并通过 `stage_ch_levels[32][8]` 下发 per-channel 电平；Category B（haas/spatial/stereo/crossfeed 等）仍仅作用前置 FL/FR。UI 按 `channel_count` 自适应 2/6/8 列。

---

## 7. Do & Don't 规范速查清单

| 维度 | ✅ 推荐做法 (Do) | ❌ 严禁做法 (Don't) |
|---|---|---|
| **问号组件** | 使用 `InfoBadge(message: l.tip)` | 手写 `Tooltip(child: Icon(Icons.help_outline))` |
| **移动端问号** | 滑动时平滑唤醒，停止滑动 2.6s 自动收起 | 在移动端持续常驻问号，破坏极简暗黑观感 |
| **输出增益** | 用 `OutputGainFrame` 包裹置底，提供复位 | 散落在卡片中间，与其他声音调制混在一起 |
| **滑块单位** | `unit: 'ms', format: (v) => v.toStringAsFixed(0)` | `unit: 'ms', format: (v) => '${v}ms'` 导致重复 |
| **标签字体** | 统一使用 `labelOf(p, color: p.text)` | 私自改成小字号或细体导致排版不统一 |
| **模块命名** | 处理链、卡片标题、Arb 词条 100% 同步 | 同一效果器在不同页面使用不同同义词 |
| **节点电平** | 忠实展示本级模块真实输出峰值，重排不漂移 | 偷换为全链总输出或随拖拽次序错位映射 |
| **电平保护** | 全 20 节点全量覆盖；未知 stage `meterIndex < 0` 返回 `SizedBox.shrink()` | 硬连越界 slot 导致出现恒灭或电平串位假死 |
| **多声道点阵** | `channelsDb` 动态下发，UI 自适应多列点阵 | 写死立体声 2 列硬编码，阻断多声道平滑升级 |

