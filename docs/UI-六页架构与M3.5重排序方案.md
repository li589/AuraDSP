# UI 六页架构与 M3.5 重排序方案

> 版本：v0.1 设计稿（2026-10-09）。**本轮只出方案与设计，不含实现。**
> 输入：用户六页信息架构需求 + M3.5 重排序激活 + GPLv3 拍板。
> 上游：`docs/APP-插件与信号图扩展规划.md`（v0.1）、`docs/APP-架构与设计方案.md`。

---

## 1. 信息架构：四页 → 六页，去掉页眉小标题

| 页 | 内容 | 状态 |
|---|---|---|
| **主页** | 引擎状态/可视化速览（用户暂不满意，重设计后议） | 改版延后 |
| **效果** | 除脚本/插件外**所有效果**的参数卡；卡片按 UX 逻辑组织（**UI 显示顺序 ≠ 处理顺序**——处理顺序唯一由"处理链"页负责，效果页内不提供排序） | 本轮设计 §2 |
| **脚本** | Liveprog 编辑器 + 对齐/格式化 + 语法飘红 + Tab 捕获 | 本轮设计 §3 |
| **插件** | 多格式插件宿主（M1），**许可证已拍板 GPLv3.0** | 引用 M1 方案 |
| **处理链** | Element 式模块顺序调整/开关 + 多通道电平显示 | **= M3.5 本体**，§4（**M3.5-a/b/c 引擎与 UI 均已全量落地**） |
| **可视化** | Poweramp 式视觉偏好 + iZotope/FL Studio 式专业展示 | 后议占位 |

**导航变更**：删除每页 PageHeader 的 eyebrow（"控制台/效果链/实时编程…"），页面标题直接以导航名承担；导航 rail 保持 6 项（主页/效果/脚本/插件/处理链/可视化）。现有四页映射：主页✓保留、效果=现效果页扩展、脚本=现 Liveprog 页、可视化✓保留；插件/处理链为新增。

---

## 2. 效果页重设计

### 2.1 通用交互规范（一次定死，全部卡片遵守）

1. **UI 顺序 ≠ 处理顺序**（用户裁定）：效果页卡片按 UX 逻辑组织（不与处理顺序绑定，可自由调整）；**处理顺序唯一由"处理链"页负责**；信号流条（处理顺序可视化）保留在效果页顶部作为参照，不承担编辑职责。
2. **双击归位默认值**：所有滑块支持双击恢复出厂默认（实现：滑块组件加 `defaultValue` 属性 + 双击手势；引擎默认值表集中在 `ParamId` 旁）。
3. **高级区交互修复**：
   - 左侧展开标志不可见 → 展开箭头改为**常亮 accent 色**（非 textDim），尺寸 16→18，命中区扩至整行；
   - **删除高级行右侧的状态文字**（"分带模式：开/关"等）——状态由高级区自身内容表达；
   - **与主滑块解耦**：高级参数改变**不再隐式重置主滑块**（如拖分带后主总滑块显示"—"而非被回写）；主滑块双击归位时才清分带（引擎语义 `stereo.mix` 清分带保留，仅 UI 呈现解耦）。

### 2.2 各效果细化需求映射

| 效果卡 | 新增能力 | 工程落点 |
|---|---|---|
| **脉冲响应**（卷积卡更名） | ① 多声道频谱可视化（类 EasyEffects：加载 IR 后显示各声道频谱包络）；② **混合比例**（wet/dry） | 引擎：`convolver.ir.spectrum` get（IR 分帧 FFT→32 带×声道，复用 viz FFT 基础设施）；`convolver.wet/dry` f32（Freeverb 同款原位混合，前置实现）；UI：IR 频谱小图 + 混合滑块入高级区 |
| **VDC 加载**（类蝰蛇/JamesDSP） | 加载 `.vdc` corr 文件（Viper DDC 空间校正） | 引擎：vendor 已有 `ddc.c`（DDCProcess 在链内）——暴露 `ddc.load` 字符串参数 + `ddc.enable`，**复用 FileGate 六道门卫**（vdc 为专有二进制格式，门卫加 magic/尺寸/结构校验）；UI：DDC 卡（打开文件/启用/来源提示） |
| **参数化混响 3D 空间渲染** | 实时 3D 声场可视化（炫酷向） | 纯 UI：CustomPaint 伪 3D 房间（透视网格地板 + 源/听者 + 反射射线束），射线密度/颜色映射 `freeverb.decay`，雾化程度映射 `damp`，声源脉冲映射实时电平；数据全部来自既有 viz/参数，**引擎零改动** |
| **扬声器优化**（类蝰蛇） | 扬声器频响校正（e-Speaker 类 FIR 校正） | 设计为"校正 FIR"效果：加载测量文件（或选预设曲线）→ 生成校正 IR → 走卷积通道（复用 convolver 基建，第二实例）；vendor/算法来源对照 ViPERFX_RE。**依赖 M3.5 之后做多实例**，先出参数占位 |
| **听力保护**（类蝰蛇） | 响度护栏（防长时间高声压） | 设计为 limiter 扩展：`protection.enable` + 目标响度（LUFS 粗测）+ 缓入限制；引擎侧复用 vendor limiter 参数化或 wrapper 级 RMS 护栏（审计后定）；UI：听力保护卡（阈值/释放/实时响度表） |

### 2.3 分期

- **一期【已全量完成并验证通过】**：
  - **集中式默认值真相源**：在 `lib/core/state.dart` 建立 `ParamDefaults`（严格对齐 C++ 引擎初始状态）；
  - **全量滑块双击归位出厂值**：`ValueSlider` 升级为整行 `HitTestBehavior.opaque` 手势捕获；低音主滑块、低频搁架频点/增益、Freeverb（衰减/阻尼/湿声/干声）、脉冲混合比例、声场展宽（含联动清除子带）及输出增益全部支持双击恢复出厂默认值；
  - **高级区交互与解耦**：展开箭头常亮 accent 色，去除冗余状态字，声场展宽双击恢复时联动重置 5 个子带为 0.5 中性；
  - **置顶前置测试闭环**：`tools/ui_verify_slider_reset.py`（每次模拟交互前严格置顶前置激活，自动化操作与断言）全部 100% PASS，生成截图 `20-bass-dragged.png` ~ `24-postgain-doubletap-reset.png` 留档；
- **二期【已完成并验证通过】**：
  - **IR 多声道频谱可视化**（C++ 引擎层复用 viz FFT `WDL_real_fft` + 32 对数频带 `kBandEdges`，施加单侧平顶 Tukey 窗防时域首冲激截断；FFI 暴露 `convolver.ir.spectrum`；Dart 端 `_IrSpectrumGraph` 支持 1~8 声道分色绘制、渐变面积图与 20Hz~20kHz 对数频轴刻度）；
  - **Freeverb 3D 声学室空间渲染**（`_Freeverb3DStage` + `_Freeverb3DPainter`，实现透视 3D 房间线框、网格地板、虚拟发声源与听者节点、反射射线束与声波脉冲，实时联动 `decay`/`damp`/`wet`/电平）；
  - **置顶前置测试闭环**：`tools/smoke_convolver_spectrum.py`（引擎层单测）与 `tools/ui_verify_effects_3d.py`（每次交互前严格置顶前置激活，自动化操作与断言）全部 100% PASS；
- **三期**：扬声器优化（多实例卷积）+ 听力保护（响度护栏算法选型）。

---

## 3. 脚本页（Liveprog）增强

1. **Tab 捕获**：编辑框拦截 Tab 键插入 `\t` 而非焦点外传（`Focus`/`KeyboardListener` + `TextEditingController` 光标处插入；Shift+Tab 反缩进）。
2. **对齐/格式化**：EEL 简易格式化器（Dart 实现：按 `;` 断句、运算符两侧空格、`@init/@sample` 段统一缩进层级；不追求完美，先保证一致可读）。
3. **语法飘红**：现状引擎只报段级错误（"@init 语法错误"）；两级方案：
   - 一期（纯 UI）：编译失败时**整段着红 + 错误行定位**（vendor 错误码→段映射，本地重编译定位到首个非法 token 附近——用 Dart 侧词法近似，不做完整语法树）；
   - 二期（vendor 小补丁 P-003）：`NSEEL_code_compile` 错误回调带**行号/列号**（NSEEL 内部有错误位置信息，需要核实暴露面），引擎 `liveprog.compile` 事件携带行列 → 编辑器精确飘红。

**实施状态（2026-10-10 已落地）**
- **Tab 捕获** ✅：`EelSyntaxTextEditingController` 接管编辑行为。
- **格式化** ✅ `EelFormatter`——按 `;` 断句、运算符两侧空格归一（`_formatOperatorsInLine`）、连续赋值块 `=` 对齐（`_alignAssignments`）；`@init/@sample` 段缩进层级统一。
- **语法高亮** ✅ `EelSyntaxTextEditingController.buildTextSpan` 纯 Dart 词法着色——注释、字符串、段指令（`@init/@sample/@slider/@block`）、关键字、内建（`spl0/1`、`slider1-8`、`srate`、`num_ch`、`tempo`、`play_state`）、数学函数、数值。
- **自适应滑块** ✅ `EelSliderParser` + `EelSliderMeta`——解析 `sliderN:default<min,max,step>显示名` 声明行，并从代码体**反推**未声明但被引用的 `slider1..8`（`isReferenced`）；UI 提供"自适应(N) / 全部 8 槽"切换，按脚本自身的 min/max 渲染。
- **外部预设文件夹** ✅ `LiveprogItem` + `LiveprogLibrary.listAll(customDirs)`——聚合 `%APPDATA%/AuraDSP/liveprog` 与外部目录递归扫描（`.eel` / `.txt`），目录以 Chip 增删，持久化进 `config.json` 的 `paths.customScriptDirs`。
- **状态栏与 lint** ✅ `Ln/Col` + 字符数 + "语法就绪"徽标；`EelLinter` 结果以可点击告警 Chip 呈现，点击跳转。
- **仍待办**：一期错误行精确定位与二期 P-003 vendor 补丁（带行列号的编译错误回调）。

---

## 4. 处理链页 = M3.5 本体（重排序激活）

用户需求把"处理链"定为**调整效果/插件模块处理顺序 + 多通道电平显示**的页面——这是 §4.2 曾标注"A3 决策"（table-driven vendor process 补丁）的正式启动。方案：

### 4.1 数据模型（不改，沿用扩展规划 §4.2）

`SignalGraph = Node[有序主链] + Edge[并行/旁链，后置]`；本阶段只做**主链排序**。

### 4.2 引擎：vendor 链表化（P-004 vendor 补丁，ADR-004 草案）

- 现状：`JamesDSPProcess` 硬编码 12 段序列，其中 convolver/ddc/liveprog 三段包在 `jdsp_lock` 内；
- 补丁：新增 `jdsp->chain[]`（函数指针 + enabled 标志数组，容量 16），`JamesDSPProcess` 改为**遍历 chain 表**（lock 分组语义保留：表项带 `needsLock` 标志，连续 lock 段合并加解锁）；顺序由宿主通过 `graph.set` 下发重建（合法节点集 = vendor 12 效果白名单，防止任意函数指针注入）；
- 兼容：默认 chain = 现硬编码顺序（行为逐字节等价，全量烟囱回归保证）；
- 验收：①默认表回归与现状输出一致（数值 diff=0）；②交换两个效果顺序后音频特征变化可测（如 reverb 前后置的频谱差）；③RT 契约不破坏（表遍历无分配/锁竞争路径回归实测）。

### 4.3 UI（处理链页）

- 纵向节点列表（拖拽手柄排序、单节点开关/旁路、点击展开参数面板——与效果页卡片组件复用）；
- **多通道电平**：每节点右侧一个迷你双声道电平表（数据：per-node viz 分接，引擎在链表遍历时对每节点做轻量峰值采样写入 per-slot 环——工程点：峰值采样 O(1)/节点，无额外 FFT）；
- 插件槽位（M1 后）同列表呈现，桥进程健康状态徽标；
- 顶栏常显"当前顺序 = 信号流向"图（复用信号流条组件，节点可点击定位）。

### 4.4 里程碑（含实施状态）

- **M3.5-a ✅ 已落地（2026-10-09）**：P-004 链表化补丁（`JDSPChainItem chain[16]` +
  `JamesDSPRebuildChain`，`JamesDSPProcess`/`CheckBenchmarkReady` 双函数表驱动）+
  `graph.order` 参数。验证：默认序全量烟囱回归 PASS（5 件套）；非法序 6 种全拒
  （含尾部溢出/缺项/重复/未知名）；探针决定性验证（liveprog 增益×2：默认位被输出
  限幅钳 1.0 → 尾置 1.3985 → 恢复 1.0）。
- **M3.5-b ✅ v1 已落地**：处理链页（ReorderableListView 拖拽 + 应用/恢复默认 +
  12 stage 一屏全见 + 只读信号流参照）。
- **M3.5-c ✅ 已全量落地并验证通过（2026-10-10）**：
  - **引擎层零开销采样与 SPSC 环扩展**：在 `JDSPChainItem` 引入固定 `stageIdx (0..11)`，在 `JamesDSPProcess` 与 `JamesDSPProcessCheckBenchmarkReady` 表遍历中实施 $O(1)$ 常数时间峰值扫描写入 `stagePeakL/R[16]`；`auradsp_viz_frame` 扩展包含 16 声道电平数组（dBFS 转换），SPSC 无锁环高频直推，零分配、零系统调用、严格 RT-Safe；
  - **单测全绿**：`tools/smoke_chain_meter.py` 验证默认直通（12 节点精确对齐 -10.46 dBFS）与 Liveprog 2.0x 增益节点（前置 7 节点保持 -10.46 dBFS，后置 5 节点精确放大至 -4.44 dBFS），100% PASS；6 项历史单测全量无回归；
  - **Dart & UI 落地**：`auradsp_ffi.dart` 扩展 280 字节 `VizFrame` 结构体映射；`state.dart` 提供 30fps 隔离电平监听器与 `toggleStage(stageId)`；`chain_page.dart` 呈现紧凑双轨双声道电平表（色阶平滑渐变映射）与每节点独立旁路/直通指示灯胶囊（`_StageBypassPill`）；
  - **置顶前置 UI 自动化验证**：`tools/ui_verify_chain_meter.py` 在物理活动桌面置顶前置测试全部 PASS，留档截图 `30-chain-initial.png` ~ `33-chain-reset.png`。
- **M3.5-d ✅ 已落地（2026-10-10）**：插件槽位入链。宿主由单插槽扩为**固定 2 插槽**（`kMaxPluginSlots = 2`），每槽经 `insertStage`（0..4）选择插入锚点，形成**外部可插 + 内部可重排**的统一拓扑。决策见 [ADR-004](adr/ADR-004-plugin-multi-slot-and-stage-topology.md)。
  - **引擎**：`auradsp_process` 由 `process_plugin_slots_stage(h, stage, ...)` 统一承担 stage 遍历——链首 `Stage 0 Pre-DSP` → 低频搁架 → `Stage 1 Pre-Vendor` → vendor 12 级链 → `Stage 2 Post-Vendor` → Freeverb → `Stage 3 Post-Reverb`（默认，行为与旧单插槽一致）→ NaN/Inf 清洗与 ±10.0 钳位 → `Stage 4 Post-Limiter`。stage 匹配只读 `std::atomic`，音频线程零分配零锁。
  - **ABI**：新增 13 个 `auradsp_plugin_slot_*` 导出，旧单插槽符号全部保留为转发 slot 0 的薄封装，**向后兼容无破坏**。
  - **UI（处理链页）**：`_PluginStageTopologyView` 全局阶段拓扑图——Stage 0~4 与 vendor 内部节点同屏横向信号流，活跃插槽内联渲染为 `S<n>:<插件名>` 芯片；`_PluginSlotChainCard` 每槽一张卡（阶段下拉 + GUI 打开 + bypass 胶囊 + 延迟读数）。

> 顺序模型说明：`graph.order` 接受**全部 12 个 stage 各一次**的逗号分隔列表；
> 这是"完整重排"模型（非"排序权重"），非法集合一律拒绝并保持原表不变。
> 效果页的 UI 显示顺序与处理顺序无关（用户裁定），信号流条仅作参照。

---

## 5. 插件页（引用 M1，决策更新）

- **GPLv3.0 已拍板** → VST3 SDK GPLv3 路线确认、CLAP MIT 一等公民、VST2 用 fst 逆向头（扩展规划 §2.3 不变）；
- **宿主形态决策已落地** → v1 采用**进程内双插槽 + 五级阶段插入**，取代扩展规划 §2.2 的桥进程首选设想（[ADR-004](adr/ADR-004-plugin-multi-slot-and-stage-topology.md)）；桥进程化推迟到 Phase 7，且需先有崩溃采集口径；
- 插件页 UI 现状（2026-10-10 已实现）：
  - **双插槽选择器** `_SlotSelectorBar` / `_SlotTab`——Slot 1 / Slot 2 标签页，各自显示活跃/旁路徽标、插件名与阶段短标签；
  - **自定义扫描目录** `_CustomDirsSection`——增删目录 Chip + 重扫，持久化进 `config.json` 的 `paths.customPluginDirs`；
  - **活跃插件卡** `_ActivePluginHero`——打开原生 GUI 界面、预设存取、插入阶段下拉；
  - **插件列表项** `_PluginListItem`——按 `isLoadedInThisSlot` / `loadedInOtherSlot` 渲染"插槽 N 活跃中 / 已载入"徽标，按钮文案随槽位动态变化（载入至插槽 N / 从当前槽卸载）；
  - **预设** 落盘 `%APPDATA%/AuraDSP/plugin_presets/<插件名>/*.aurapreset`，由宿主经 VST3 `getState/setState` 或 CLAP `extension_data` 流式序列化。

## 6. 可视化页（占位）

Poweramp 式视觉偏好 + 专业频谱/矢量示波器类组件 + 视觉预设体系——后议；本页骨架保留，导航不缺位。

---

## 7. 实施顺序建议

1. **P-004 ADR-004 评审**（本方案 §4.2 补丁面与回归策略确认）→ M3.5-a；
2. 效果页通用交互规范（双击归位/高级区修复）——小改可先行，不依赖 M3.5；
3. M3.5-b 处理链页；
4. 效果页一期细化（脉冲响应改名/混合比例/VDC 加载）；
5. 脚本页 Tab/格式化（独立，随时可插队）；
6. 二/三期（IR 频谱、3D 渲染、扬声器优化、听力保护）随 M1/M3.5 进度排布。
