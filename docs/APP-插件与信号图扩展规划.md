# AuraDSP APP 扩展规划 v0.2 —— 插件 / Liveprog / 信号图 / 卷积 / 效果细化

> 版本：**v0.2**（2026-10-10 回写实施状态；原 v0.1 草案于 2026-10-09）
> 定位：回应五项能力诉求的**计划报告 + 跨平台方案**，并**跟踪实施状态**。
> 上游文档：[`docs/README.md`](README.md)（导航）、`docs/APP-架构与设计方案.md`（APP 总方案）、`docs/产品架构总览.md`（产品真相源）、`docs/项目架构与开发规范.md`（工程真相源）。
> 决策记录：[`docs/adr/`](adr/)（ADR-001 ~ ADR-004）。
> **实施结果（2026-10-10）**：M1/M2/M3.5(a~d)/M3-b/M4/M5 全部落地，`python test/runner.py --smoke` 10 项 100% PASS。里程碑状态见 §9.1，拍板结果见 §10。

---

## 0. 摘要

| # | 诉求 | 一句话方案 | 基础现状 | 首个里程碑 | 状态 |
|---|---|---|---|---|---|
| 1 | VST/VST3 插件（32/64 位） | **v1 进程内双插槽**（每槽可选五级插入锚点）；桥进程沙箱为 Phase 7 预案。VST3=GPLv3 SDK、VST2=逆向头、CLAP=MIT 一等公民 | 已落地：`auradsp_plugin_host` + 76 个插件实扫 | M1 ✅ | ✅ |
| 2 | 实时可编程 DSP（代码） | 直接暴露 vendor 自带的 **Liveprog（EEL2/NSEEL）**：编辑器（语法高亮/格式化/lint）+ 保存/加载/编译反馈 + 自适应参数滑块 | 已落地并增强 | M2 ✅ | ✅ |
| 3 | 效果顺序/开关 + 模块接线 UI | **一个信号图数据模型，两种视图**：有序链视图（12 级重排）+ 全局阶段拓扑（Stage 0~4 含插件） | 已落地：P-004 表驱动链 + `graph.order` | M3 ✅ | ✅ |
| 4 | IR 原生支持 + 文件安全 | 卷积/IR 升一等公民 + **统一外部文件门卫 FileGate** 作用于一切文件入口 | 已落地：六道门卫 + IR 多通道频谱 | M4 ✅ | ✅ |
| 5 | 效果细化（高级选项默认折叠） | 每效果"基本/高级"两级参数卡；高级区随效果开关自动折叠 | 已落地 | M5 ✅ | ✅ |

**全局原则**（沿用并扩展 APP-架构与设计方案 §1 铁律）：

- RT 路径永远 source-of-truth 是 C/C++；Flutter UI 只经 Control API 说话。
- 一切外部输入（音频文件 / IR / VST DLL / liveprog 脚本 / 预设 JSON）过**同一套文件门卫**（§5.4）。
- 崩溃隔离原则：**任何第三方代码（插件/脚本）不得与引擎主进程同生共死**。
  > **现状偏差**：v1 进程内宿主尚未满足此条（ADR-004 明示接受的取舍），桥进程化推迟至 Phase 7。

---

## 1. 现状盘点（代码事实，非愿望）

### 1.1 引擎已具备（vendor-src/libjamesdsp，纯 C，源码整合）

| 能力 | 代码位置 | 现状 |
|---|---|---|
| 11 个 DSP 效果 | `jdsp/Effects/`（bs2b/crossfeed/dbb/dynamic/multimodalEQ/reverb/stereoEnhancement/vacuumTube/vdc/arbEqConv/convolver1D + FFTCompander） | engine_api v1 **只暴露 5 个**（bass/reverb/stereo/eq/post），其余 6+1 个已编译进 DLL 但无参数通道 |
| **EEL2 实时可编程 DSP** | `Effects/liveprogWrapper.c`：`LiveProgStringParser(jdsp, eelCode)` 解析 `@init`/`@sample` 两段，`NSEEL_code_compile` 编译进 VM；寄存器 `spl0/spl1/srate` | 完整可用，**未暴露到 ABI**；无参数滑块（可加 `slider1..N` regvar 扩展） |
| 卷积器 + IR | `Effects/convolver1D.c`、`jdspController.c:267`；IR 解码用 dr_flac/dr_wav/dr_mp3（eel2/ 下），`JamesDSPOfflineResampling` 按 `ratio = targetFs/IR.sampleRate` 离线重采样 | **IR 采样率不匹配已内置处理**；HRTF blobs 同机制。缺：ABI 暴露、IR 元数据回读、APP 层安全防线 |
| ASRC（设备采样率适配） | `JamesDSPInit`：设备率 ∉[44.1k,48k] 时自动启用，内部锚定 44.1/48k | 已生效，意味着"44.1k IR 在 48k 设备"与"48k 设备 44.1k 输出"都有兜底 |
| 可视化基础设施 | SPSC ring（我们 2026-10-09 修好的 4096-FFT 实现） | 已有，插件桥进程需复制该模式 |

### 1.2 缺口清单（对照五项诉求）

- engine_api v1 是**固定链 + 扁平参数**模型：没有"效果槽位/顺序/插拔"语义，也没有 `plugin.*`/`liveprog.*`/`convolver.*` 参数族。
- 无任何进程模型：engine 是进程内 DLL，VST 宿主必须引入**多进程 + IPC**——这是本轮最大的架构增量。
- 无文件安全层：当前 WAV 文件入口直接 `openFile()` 后塞给引擎，无嗅探/限额/隔离。
- UI 是静态四页（主页/效果/可视化/设置），无"链"概念页面。

### 1.3 许可证事实（2026-10-09 核查）

| 组件 | 许可证 | 对本项目的含义 |
|---|---|---|
| VST3 SDK（Steinberg） | **双许可：GPLv3 或 Steinberg 专有** | 本项目因 libjamesdsp 为 GPL-3.0，APP 生态走 **GPLv3 路线零签署成本**；未来若闭源需签 Steinberg 协议（ADR 需记录此约束） |
| VST2 | Steinberg 已停发许可；社区逆向头（Debian `fst` GPL-3、vestige 等） | VST2 宿主用 GPL 逆向头可行；VST2 是"兼容遗产"而非战略方向 |
| **CLAP**（u-he/Bitwig） | **MIT，纯 C ABI**，官方平台列表含 Windows/Linux/Mac/**Android/iOS** | 无任何法律摩擦 → 定为**跨平台一等公民格式**与 Android 创新路径 |
| JUCE | AGPLv3 / 商业双许可 | 本轮**不引入**（重量级 + 许可纠缠）；仅在需要插件 GUI 桥时按 ADR 重评 |
| EEL2/NSEEL（Cockos WDL） | WDL 自由许可（类 zlib + 声明条款） | 已随 libjamesdsp 引入，无新增义务 |

【决策点 D1】确认 GPLv3 路线（即 AuraDSP APP 保持 GPL-3.0 分发）。这决定 VST3 集成方式与未来商业化弹性。

---

## 2. 方向一：VST/VST3 插件宿主（PC 优先）

> **⚠ 决策更新（2026-10-10）**：本节 §2.2 描述的"插件沙箱桥"**不再是 v1 首选形态**。实际落地为**进程内双插槽 + 五级阶段插入**（[ADR-004](adr/ADR-004-plugin-multi-slot-and-stage-topology.md)）。桥进程化推迟到 Phase 7，前置条件是先建立插件崩溃采集口径与隔离收益的量化依据。本节内容保留为**桥进程化阶段的设计预案**，§2.4~2.8 的扫描器 / 预设 / 崩溃防线设计仍然有效并已部分落地。

### 2.1 目标与非目标

**目标**：在 Windows 桌面端，把任意 VST2/VST3（64/32 位）与 CLAP 效果插件插入 AuraDSP 信号图任意槽位；插件崩溃/泄漏**不拖垮** APP 与音频引擎；扫描可预期、可缓存、可重检。

> **现状偏差（诚实记录）**：v1 进程内宿主**接受**了"插件崩溃会带崩进程"这一代价，未达成"崩溃不拖垮 APP"的目标。这是 ADR-004 明示的取舍，不是遗漏。

**非目标（本轮明确不做）**：
- **Android 上加载 PC 插件（dll/vst3/au）**——架构上不可行也不该做（x86/PE 二进制 vs ARM/ELF）。Android 的插件创新路线是 **CLAP-on-Android**（MIT、纯 C、官方平台表含 Android）或自研 `aura-effect` 打包格式，见 §2.8。
- iOS/inter-app audio、MIDI 乐器宿主（先做效果器）。

### 2.2 桥进程设计预案：插件沙箱桥（Plugin Bridge Process）— *Phase 7 再启用*

这是本方向的地基，也是对 jBridge 类外挂的**内置替代**：

```
┌────────────────────────── AuraDSP 主进程 ──────────────────────────┐
│  Flutter UI ── Control API ── 引擎核心（libjamesdsp + 信号图）        │
│                                   │                                 │
│                          插件槽位 Slot[k]                           │
│                                   │ 桩（in-process shim，RT-safe）    │
│  SPSC 音频环（零拷贝共享内存）◄──────┘                                 │
└───────────────┬──────────────────────────────┬─────────────────────┘
        共享内存 fmq/环形缓冲（音频）      控制通道（参数/状态/UI 事件）
                ▼                              ▼
   ┌────── 桥进程 A（64 位） ──────┐   ┌────── 桥进程 B（32 位） ──────┐
   │  VST3 宿主壳 auradsp_bridge   │   │  auradsp_bridge32.exe         │
   │  └─ 插件 X.dll/.vst3          │   │  └─ 老插件 Y.dll              │
   └──────────────────────────────┘   └──────────────────────────────┘
```

设计要点（每条对应你提出的痛点）：

| 痛点（你的原话） | 架构对策 |
|---|---|
| "jBridge 桥接麻烦还容易崩" | 桥**内置**：APP 自带 64/32 两个桥壳进程，用户无感；扫描即探测出位数并自动路由 |
| "VST 内部故障/内存泄漏把外部一起挂掉" | **每插件一进程**（默认；可配置"轻量组"合并同厂商插件省内存——FL Studio 也是这个思路）。桥进程崩溃 → 引擎侧槽位自动旁路（bypass + 事件条报错 + 一键重载），主进程与音频流**零中断** |
| "插件内存泄漏" | 桥进程内存水位监控（私有字节数），超阈值警告；音频路径用共享内存固定环形缓冲，桥进程泄漏的是它自己的地址空间，杀掉重载即可恢复，泄漏不累积到主进程 |
| "华丽界面容易崩" | GUI 彻底隔离：插件原生窗口句柄挂到 Flutter `HWND` 容器（Windows specific），GUI 卡死/崩溃不影响音频桥（GUI 与音频是同一桥进程内的两个线程，音频线程看门狗在 GUI 冻结时自动旁路） |
| 32 位插件 | 32 位桥壳进程（Wow64 下正常），与 64 位插件桥的 IPC 协议**完全一致**——位数只是桥的属性，不是信号图的属性 |

**IPC 协议**（桥 ↔ 主进程，二选一【决策点 D2】）：
- A（推荐）：**共享内存音频环 + 命名管道控制流**——参考项目仓库里现成的 libfmq 思路（Android 侧已趟过 memfd/文件映射的坑，Windows 用 CreateFileMapping + 事件对）；延迟最低（≈0 附加拷贝一次）。
- B：gRPC/Socket——开发快但音频流抖动风险高，不推荐。

桥进程崩溃语义（硬验收）：杀掉桥进程，主 APP 不倒、声音在 200ms 内自动旁路恢复、UI 事件条给出"插件 X 已崩溃，已旁路，点此重载"。

### 2.3 格式矩阵与选型

| 格式 | 宿主实现 | 许可证载体 | 优先级 |
|---|---|---|---|
| **VST3** | VST3 SDK（`public.sdk` host 侧） | GPLv3 路线（与本项目一致） | **P0**（生态最大） |
| **CLAP** | clap SDK（纯 C，clap-host） | MIT | **P0**（跨平台战略 + Android 路径） |
| VST2 | 逆向头（fst/vestige，GPL） | GPL-3 | P1（遗产兼容，吃存量插件） |
| AU/AAX/LV2 | 不做 | — | AU 仅 macOS 阶段再议 |

### 2.4 扫描器（快扫/深扫/缓存/进度/重检）

分两级，扫描**永远在桥进程里**（插件崩溃只死扫描进程）：

1. **快扫（<1s）**：文件系统遍历（标准目录 + 用户自选目录）→ magic bytes/PNG 检查 → VST3 `.vst3` bundle 结构解析、CLAP `.clap` 识别 → **不加载代码**，产出候选清单（路径/大小/位数/格式猜测）。
2. **深扫（可中断、可后台）**：在桥进程中真实 `load + initialize + query`，产出：厂家/名称/版本/类别/参数数/延迟报告/支持声道/状态徽标（OK/加载失败/初始化崩溃）。结果写 `plugin_cache.json`（按 (路径, mtime, size, APP 版本) 失效）。
3. **进度与记忆**：扫描进度条可关（后台继续）；"上次扫描时间/插件数"常显；支持单插件右键"重新检查"（只重扫该条目）。
4. **禁用名单**：崩溃过的插件自动进灰名单（启动时跳过深扫，手动可解除）。

### 2.5 身份合并：32/64 位合并 + VST2/VST3 合并（FL Studio 灵感）

插件身份键（dedup key）：
```
identity = normalize(vendor + pluginName)     # 忽略版本/位数/格式
entries = [{format: vst3, bits: 64, path}, {format: vst2, bits: 64, path}, {format: vst3, bits: 32, path}...]
```
- 信号图里用户选的是**逻辑插件**；实际加载条目按"同位优先 → VST3 优先 → 版本新优先"自动择优，UI 上可手动锁定某条目。
- 32 位条目在 64 位条目存在时默认隐藏（设置里可显示），避免列表双份污染——这正是 jBridge 时代列表混乱的反面。
- 扫描器按 identity 聚合展示，合并信息（"3 个二进制 · 64 位 VST3 已选用"）。

### 2.6 预设、弹窗、授权、存储本地化

- **预设**：插件原生预设（VST3 program list / VST2 programs / CLAP preset discover）+ 用户预设 = 引擎状态快照（序列化到 `%APPDATA%/AuraDSP/presets/`，JSON + 插件状态 blob base64）；预设里插件状态用插件自己的 chunk 存取，UI 不解析。
- **弹窗（GUI）**：默认收进"槽位详情"页内嵌容器；提供"弹出为独立窗口"与"无 GUI（只用参数面板）"三态。桥进程崩溃时容器显示降级参数面板（通用自动 GUI：参数名+滑块，VST3 参数天然可枚举）。
- **授权/解锁**：插件侧授权逻辑在桥进程内自然工作（多数插件按机器码/账号激活，与宿主无关）；APP 只提供"打开插件 GUI"入口。绝不在主进程碰授权。
- **存储本地化**：所有插件相关缓存/预设/白名单集中 `%APPDATA%/AuraDSP/`，提供"打开数据目录"入口；便携模式（exe 同目录 portable.flag）支持。

### 2.7 崩溃与资源防线（验收即红线）

1. 杀桥进程 → 主进程不倒、自动旁路 ≤200ms、UI 有事件（前述硬验收）。
2. 深扫对每个插件设 10s 超时（扫描进程自杀协议）。
3. 桥进程内存水位 > 1.5GB 警告、> 3GB 建议重载。
4. 音频环 underrun 时槽位自动旁路优先于卡顿（可配置）。

### 2.8 Android 的诚实评估与创新路径

- 事实：VST/VST3/AU 是桌面二进制格式，Android（ARM64/ELF/binder 生命周期）无法直接加载——这不是"没做到"，是格式与平台不匹配。任何宣称 Android 支持 VST 的方案本质都是 PC 侧渲染。
- **创新路径（按投入排序）**：
  1. **CLAP-on-Android 宿主**：CLAP 官方平台表含 Android；纯 C ABI 可被 NDK 编译。若生态出现 CLAP ARM 插件，AuraDSP 将是第一批 Android CLAP 宿主——"Android 全局/会话级可插插件"目前无人做过，具备叙事价值。
  2. **自研 `aura-effect` 打包格式**：本质是"声明式参数 + liveprog/EEL2 脚本 + 可选 WASM 算子"，天然跨平台，PC/Android 同一份文件。
  3. 保持架构口子：信号图槽位是抽象的（Slot::Native / Slot::Plugin(Bridge) / Slot::Liveprog / Slot::Convolver），Android Rootless 形态将来只需提供 Plugin 槽的本地实现。
- 优先级：**先把 Windows 打磨好**（你的原话），Android 插件放 Phase 后段。

---

## 3. 方向二：Liveprog——实时可编程 DSP

### 3.1 为什么这是"低垂的高级果实"

引擎里已经躺着一台完整的 EEL2 虚拟机（`liveprogWrapper.c` + `eel2/` 全套 NSEEL）：`LiveProgStringParser(jdsp, eelCode)` 解析 `@init`/`@sample` 两段并编译，`spl0/spl1` 是样本进出、`srate` 是采样率。**只差 ABI 暴露和编辑器**，无需任何新算法工作。

### 3.2 能力设计

| 能力 | 设计 |
|---|---|
| 代码编辑页 | Flutter 内置代码编辑器（等宽 + 行号 + 语法高亮，可用 `code_text_field` 起步）；PC 支持外接编辑器（编辑命令模板，文件变更热重载） |
| 脚本格式 | 沿用 EEL 文本 + `@init` / `@sample` 段；扩展 `@options` 段声明 UI 参数（`slider:name=default,min,max,step`）→ 引擎 `NSEEL_VM_regvar("sliderN")` 注册，UI 自动生成滑块（vendor 补丁走铁律 §3.3，改动 <50 行） |
| 保存/载入 | 脚本库 `%APPDATA%/AuraDSP/liveprog/`；每个脚本 = 单文件 `.eel`（含元数据头：名称/作者/声道/说明）；内建库预置 3~5 个示例（软限幅、立体声展宽实验、磁带饱和） |
| 编译反馈 | `LiveProgStringParser` 返回码已带语法错误定位（"@init section not found" 等）→ ABI 映射为 `liveprog.compile` 事件，编辑器内联标错 |
| 安全 | EEL2 VM 天然无 IO/无系统调用（沙箱脚本语言）；编译在控制线程完成（不阻塞 RT）；`@sample` 段禁止循环无界（NSEEL 自带指令上限）——泄露 CPU 的脚本最坏情况是音频超时，引擎看门狗旁路 |
| 信号图集成 | Liveprog 是信号图的一种槽位类型（§4），可多次实例化、可排序、可旁路 |

### 3.3 里程碑 M2 验收

1. ABI 新增 `liveprog.code`（字符串参数）/ `liveprog.enable` / `liveprog.param<N>`；
2. 编辑页：写一个 5 行的立体声增益脚本 → 点"应用" → 1s 内生效且 A/B 旁路可听；
3. 语法错误在编辑器中标红并显示引擎返回的定位信息；
4. 脚本保存/重命名/删除/双击加载全链路走通。

---

## 4. 方向三：信号图（Signal Graph）——"顺序/开关"与"模块接线"的统一解

### 4.1 问题重述（你指出的重叠与冲突）

- EasyEffects 心智：**有序效果链**，每项开关/旁路/移除/拖动排序——线性、简单、移动端友好。
- qjackctl/Element 心智：**patchbay 图形接线**，任意模块/设备连线——表达力强，但复杂、小屏反人类。
- 若做两套：同一拓扑两个编辑入口 → 状态同步、认知负担、维护双份 UI，都是反模式。

### 4.2 取舍决策（本方案核心结论）

**一个模型，两种投影，一条编辑心智：**

```
SignalGraph（唯一数据模型，存于引擎，UI 只投影）
  = Node[ ]（有序主链） + Edge[ ]（仅并行/旁链时存在）
  Node = { slotId, kind: native|plugin|liveprog|convolver|io,
           enabled, bypassed, params, label }
  Edge = { from, to, port }          # 默认无 Edge = 纯线性主链
```

| 视图 | 何时用 | 形态 |
|---|---|---|
| **链视图**（默认，也是唯一必做） | 90% 场景：纯线性链 | 垂直卡片流：每卡 = 图标 + 名称 + 启用/旁路开关 + 内嵌迷你可视化（该节点自己的频谱/电平）+ 折叠参数区；拖拽排序、左滑/按钮移除、"+"插入新效果 |
| **图视图**（桌面进阶，可后置） | 需要并行总线、旁链、侧路由时才打开 | 桌面画布（自研 CustomPainter 节点图，暂不引第三方大库）；**同一模型**，只是把 Edge 画出来；提供"回到链视图"一键归位 |

**关键设计裁决：**
1. **链视图不画线**——线性链的"接线"隐含在顺序里，UI 上用流式箭头表达数据流向，零学习成本；只有用户显式创建并行/旁链时才出现 Edge，此时 UI 自动提示"已进入图模式"。
2. **每节点内嵌实时可视化**（你提的 EasyEffects 式"处理时音频视觉反馈"）：每个节点卡片里一个 8~16px 高的迷你频谱/电平条，数据来自该节点的 viz 分接头（引擎侧每槽位一个 viz 环，复用既有 SPSC 机制）。这比独立可视化页更能体现"每一环在做什么"。
3. **移动端适配**：链视图本身就是竖向卡片流，天然适配小屏；图视图在 Android 上**功能降级为只读预览**（能看不能拖线，编辑退回链视图）——明确取舍，不做移动端画布。
4. **不重复建模**：两个视图读写同一个 `SignalGraph`，切换视图 = 换渲染器，无任何同步代码。

### 4.3 引擎侧配套（engine_api v2 核心增量）

```c
/* 信号图语义（v2 新增参数族，全部走既有 set_param 通道） */
graph.set        /* JSON 或紧凑二进制：整个图（节点+边），应用时原子重构建 */
graph.node.enable / graph.node.bypass / graph.node.remove
graph.node.move  /* 槽位重排 */
graph.node.vizTap /* 该节点的 viz 环句柄 */
/* 节点类型注册 */
effect.list      /* 枚举内建效果（把 vendor 里 11 个效果全部登记） */
```

- 引擎内部从"固定链"改为 **EffectSlot[ ] 动态链**：每槽位 = `{kind, params, bypassFlag}`，process 循环按序调各槽的 process 指针（libjamesdsp 各效果本就是 `Enable/Disable/SetParam/Process` 四件套，包装成槽位是机械工作）。
- **延迟预算联动**：`get_latency_ms()` 改为 Σ(启用槽位延迟)，ADR-002 三档守卫自动适配（图超预算 → 拒绝该节点启用并指名原因）。
- 兼容策略：v1 的扁平参数保留为"主链上固定 5 效果"的糖（UI 旧页面照常工作），v2 起新页面走 graph.*。

### 4.4 UI 信息架构落地

- 新增导航页 **"信号链"**（替代/合并现有"效果"页）：默认即链视图；
- 现有四页保留，效果页的参数编辑迁移为链视图点开节点后的详情面板（同一组件复用）；
- 图视图入口放在链视图右上（"编辑连线"），纯线性链时该按钮半透明 + tooltip"添加并行/旁链后解锁"——用产品语言化解两套心智的打架。

【决策点 D3】① 图视图进 M3 还是后置到 M6（建议：后置，先让链视图+节点级可视化交付价值）；② Android 图视图只读降级是否接受。

---

## 5. 方向四：卷积/IR 一等公民 + 统一文件安全

### 5.1 卷积能力设计

- ABI 暴露：`convolver.enable` / `convolver.ir.path`（或 `ir.data` 流式）/ `convolver.predelay` / `convolver.gain`；
- **IR 元数据回读**：采样率/时长/声道/峰值，加载前 UI 即显示（"48kHz · 2.3s · stereo · 峰值 -3.2dB"）；
- 采样率不匹配：引擎 `JamesDSPOfflineResampling` 已处理（44.1↔48 离线重采样），APP 层只需把"已自动重采样 44.1k→48k"作为事件提示用户（诚实明示，不静默）；
- 大 IR：TwoStageFFTConvolver 天然支持长 IR；APP 侧对 >60s IR 弹确认（CPU 预算）。

### 5.2 统一外部文件门卫（FileGate）——作用于一切文件入口

你点名的四类风险（格式不对/恶意代码/超大/损坏）落成统一规范，所有文件入口（WAV、IR、liveprog 脚本、VST、预设 JSON）共用：

| 防线 | 内容 |
|---|---|
| L1 嗅探 | 不信任扩展名，读 magic bytes 判真实格式（RIFF/WAVE、fLaC、FORM/AIFF、EEL 文本、PE/ELF） |
| L2 限额 | 尺寸上限按类型：IR ≤ 256MB、音频 ≤ 1GB、脚本 ≤ 1MB、预设 ≤ 8MB；解析前先查 `stat` 拒超大 |
| L3 隔离解码 | 解码在**非主 isolate**（Dart isolate）或独立进程（VST 类必然是桥进程）；解码失败/超时只降级不连坐 |
| L4 健全性 | 解码后校验：NaN/Inf 扫描、全零/全直流检测、极端 clipping 提示、声道数/位深白名单 |
| L5 代码类文件特供 | VST/CLAP = 只在桥进程加载（§2.2）；liveprog = VM 沙箱无 IO（§3.2）；预设 JSON = schema 校验 + 拒绝未知字段执行 |
| L6 失败语义 | 统一错误码 + UI 事件条文案（"文件损坏/格式不符/超过大小上限"），永不静默吞 |

验收红线：构造损坏 WAV / 假扩展名 / 4GB 空洞文件 / 含 NaN 的 IR，四类输入全部被拒且有明确文案，主进程无崩溃。

---

## 6. 方向五：效果细化（高级选项默认折叠）

### 6.1 UI 模式：两级参数卡

每个效果节点卡 = **基本区**（1~3 个最常用参数，始终可见）+ **高级区**（默认折叠，点击展开；展开状态记忆）。沿用既有 `SectionCard` 加折叠体，动效走设计系统 AuraDur。

### 6.2 各效果细化清单（含算法缺口标注）

| 效果 | 基本区（默认可见） | 高级区（折叠） | 引擎缺口与算法来源 |
|---|---|---|---|
| **低音增强** | 总量（dB） | **拆两轴**：低频增强（low-shelf gain, 60~250Hz 可调频点）+ 低音管理（low-pass 截止 + sub 加法，参考 EasyEffects/LSP `bass_enhancer` 与 `bass_loudness`） | vendor dbb.c 现为单参数低架滤波；细化需 vendor 补丁（biquad 频点/类型参数化，§3.3 流程）或新增 biquad 级联小模块 |
| **混响** | 预设选择（保留现有 8 预设） | 手动参数：预延迟 / 衰减时间 / 高频阻尼 / 扩散 / 干湿比 | vendor reverb.c = sf_presetreverb（预设库算法，无逐参数接口）→ 两条路：A) 换 Freeverb/Schroeder 可参化实现（源码对照 `source/` 里的开源实现）；B) 卷积混响（IR 库 + §5.1，T2 同档）。【决策点 D4】建议双轨：参数化混响为 P0，IR 混响由卷积槽位天然覆盖 |
| **声场展宽** | 总宽度（沿用 0–75% 安全上限） | 频带宽度（低/中/高各自宽度）、中置保持量（把"中心剥离"做成可见可调的 0–100% 而非黑盒）、单声道声场合成（mono→stereo，iZotope Imager 思路） | vendor stereoEnhancement.c 是子带 M/S；参数化"per-band mix + centre keep"为中等补丁（子带循环已存在，暴露数组即可） |
| **EQ** | 现有开关 | 图形频点编辑（multimodalEQ 已强，暴露 freq/gain/q 三元组数组即可） | 仅 ABI 暴露工作 |
| **动态低音/真空管/串扰消除/VDC** | 未暴露，全部进链视图节点库 | 各自 2~5 参数 | 全部是"vendor 已有、ABI 未暴露"，机械工作 |
| **Liveprog / 插件 / 卷积** | §3 / §2 / §5 | — | — |

### 6.3 交付节奏

参数扩展跟随 engine_api v2 分批：先暴露零算法缺口的（EQ/dynamic/tube/bs2b/vdc/convolver），再做需要 vendor 补丁的（bass 细化、stereo per-band、参数化混响）。

---

## 7. 跨平台能力矩阵（规划态）

| 能力 | Win Desktop v1/v2 | Android Root | Android Rootless | Linux | macOS |
|---|---|---|---|---|---|
| 内建效果全量（11）+ 高级参数 | ✅ M5 | ✅（AIDL 透传） | ✅ | ✅ | ✅ |
| 信号图（链视图） | ✅ M3 | ✅ | ✅ | ✅ | ✅ |
| 信号图（图视图） | ✅ M6 | 只读降级 | 只读降级 | ✅ | ✅ |
| Liveprog 编辑器 | ✅ M2 | 查看+参数（编辑器 PC 先行） | 同左 | ✅ | ✅ |
| VST2/VST3/CLAP 宿主（桥进程） | ✅ M1/M6 | ❌（格式不匹配，诚实不做） | ❌ PC 格式 / ✅ CLAP-ARM 创新路径 | ✅（PipeWire 阶段） | 后议 |
| 卷积 IR + 门卫 | ✅ M4 | ✅ | ✅ | ✅ | ✅ |
| 多声道 Phase B | 并行评估 | ✅ | ❌（会话级限制） | ✅ | ✅ |

跨平台红线：**Control API 语义在所有形态一致**——Android Root 形态新增参数族时走 AIDL VendorParamId 扩展，UI 零改动。

---

## 8. 数据与协议演进：engine_api v2

```
v1（现状）：扁平参数 + 固定链 + 单 viz 环
v2 增量：
  effect.list / graph.*            → 信号图（§4.3）
  plugin.scan / plugin.slot.*      → 插件桥控制（§2，桥进程专属协议另行 RFC）
  liveprog.code/.enable/.paramN    → 可编程 DSP（§3.2）
  convolver.* / ir.meta            → 卷积（§5.1）
  file.gate 事件                   → 文件门卫统一错误语义（§5.2）
版本策略：v1 参数全部保留为糖；ABI 序号 +1，运行时能力查询位图（capability bitmap），
  UI 按能力渲染（旧 Android Root 引擎自动隐藏新功能而不是报错）。
```

---

## 9. 里程碑与风险

### 9.1 里程碑排期与实际状态

> 状态列于 2026-10-10 回写。引擎 smoke 门禁：`python test/runner.py --smoke`（10 项，100% PASS）。

| 里程碑 | 内容 | 依赖 | 状态 |
|---|---|---|---|
| **M2 Liveprog** | ABI 暴露 + 编辑页 + 脚本库 + slider 扩展 | 无新依赖 | ✅ 2026-10-09（+ 2026-10-10 补语法高亮/格式化/自适应滑块/外部文件夹） |
| **M4 卷积 + 文件门卫** | convolver.* 进 ABI + FileGate 层 + 损坏样本测试集 | 无新依赖 | ✅ 2026-10-09 |
| **M3 信号图·链视图** | 引擎 EffectSlot 动态链 + graph.* + 链视图 UI + 节点级 viz 分接 | M4 | ✅ 2026-10-09~10（M3.5-a 链表化 / -b 链视图 / -c per-stage 电平 / -d 插件入链） |
| **M5 效果细化第一批** | 零算法缺口的 6 效果参数暴露 + 两级参数卡 | M3 | ✅ 2026-10-09~10 |
| **M3-b 预设系统** | 全参数 JSON 快照 保存/载入/删除 | M3 | ✅ 2026-10-10（演进为预设 schema v2 `*.aurapreset.json`） |
| **M1 插件宿主最小版** | VST3/CLAP 64 位进程内宿主（双插槽）+ 扫描器 v1 | D1 决策 | ✅ 2026-10-10（[ADR-004](adr/ADR-004-plugin-multi-slot-and-stage-topology.md)，宿主形态由"桥进程首选"改为"进程内"） |
| **M6 插件宿主完整版** | 桥进程沙箱 + 崩溃隔离 + 身份合并 + 授权 | M1 + M3 | ⏸ 推迟至 Phase 7；前置条件为建立插件崩溃采集口径 |
| **M7 Android 插件创新** | CLAP-on-Android 评估原型 | M6 + Rootless（Phase 6） | ⏸ 待做 |

排序逻辑：先用**零依赖高价值**的 M2/M4/M3 建立信号图地基，插件宿主（风险最集中）放地基稳了之后，且首版先进程内最小化验证 VST3 宿主代码正确性，再引入多进程复杂度。

> **D1（GPLv3）已拍板为"是"**（§10）；实际落地顺序与 §9.1 原表一致，但宿主形态按 ADR-004 调整为进程内优先。

### 9.2 风险登记

| 风险 | 等级 | 对策 |
|---|---|---|
| 插件桥 IPC 音频抖动（缓存失配、GC 式毛刺） | 高 | 共享内存环 + 事件对 + RT 线程优先级；先进程内最小版验证算法正确性再上桥 |
| GPL 边界模糊（桥进程里跑第三方专有插件是否"聚合作品"） | 高（法律） | D1 决策 + 行业惯例研究（DAW 普遍多进程桥接：隔离事实显著）；必要时桥进程声明独立作品边界并在 ADR 留痕；正式分发前过一次法律评审 |
| 引擎动态链重构回归（现有固定链 5 效果全部要重接） | 中 | graph.set 原子重建 + 全量数值回归基线（smoke 对照 v1 输出） |
| VST2 逆向头合规细节 | 中 | 只用 GPL 逆向头（fst），弃 vestige（许可含糊）；VST2 定位遗产兼容 |
| 插件生态长尾（扫描慢/兼容性矩阵大） | 中 | 两级扫描 + 缓存 + 灰名单 + "已知问题插件"社区表 |
| 范围膨胀（五方向并行） | 高 | 严格按里程碑串行；每个 M 独立可交付可回退 |

### 9.3 source/ 参考克隆清单（Phase 0 准备，只读参考不链接，遵循 source/ 整合铁律）

| 仓库 | 用途 | 许可证 |
|---|---|---|
| `free-audio/clap` + `free-audio/clap-host-example` | CLAP 宿主协议与最小宿主样例 | MIT |
| `steinbergmedia/vst3sdk` | VST3 host 侧（GPLv3 分支使用） | GPLv3/专有 |
| `free-audio/clap-validator` | 插件扫描健壮性参考 | MIT |
| `wwmm/easyeffects` | 链式 UI 交互与效果管理心智参考 | GPL-3 |
| `LSP (lsp-plugins)`（已在库，66模块就绪） | 等响度补偿（loud-comp）/ 分频 / 滤波算法对照 | LGPL-3.0+ |
| `iZotope Ozone Imager` 思路（不开源，仅行为对照） | 声场细化参数面设计 | — |
| `vst-node / yabridge`（Linux VST 桥实现） | 桥进程 IPC 模式参考 | GPL-3 |
| `element`（已在库） / `jack-keyboard`（patchbay 交互） | 插件宿主与图视图交互参考 | Apache-2.0 / GPL-3 |

（注：`element` 与 `lsp-plugins` 已克隆并在 `source/ORIGIN.md` 登记；新克隆一律浅克隆 + 剥 .git，遵循铁律。）

---

## 10. 决策点汇总

| # | 决策 | 状态 | 结论 |
|---|---|---|---|
| D1 | APP 生态走 GPLv3（连带 VST3 免签署） | ✅ **已拍板：是** | libjamesdsp 已是 GPL-3，顺势而为；记录约束：未来闭源需重谈 |
| D2 | 桥 IPC 技术栈 | ⏸ 延后（Phase 7） | 共享内存环 + 命名管道（复用 Android 侧 fmq 经验），随 ADR-005 一并评估 |
| D3 | 图视图时机 / Android 只读降级 | ✅ 部分落地 | 图视图已落地（M3.5-b 处理链页 + M3.5-d 全局阶段拓扑）；Android 只读降级随 Rootless 评估 |
| D4 | 参数化混响 vs IR 混响 | ✅ 双轨 | 参数化（Freeverb，P0）+ IR 混响（卷积槽位覆盖） |
| D5 | M2/M4/M3 先行的排期 | ✅ 认可并执行 | 实际按此顺序落地，2026-10-10 全部完成 |
| D6 | 插件宿主形态：桥进程 vs 进程内 | ✅ **已拍板：进程内** | [ADR-004](adr/ADR-004-plugin-multi-slot-and-stage-topology.md)；双插槽 + 五级阶段插入，桥进程化推迟至 Phase 7 |
