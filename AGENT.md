# AGENT.md — AuraDSP 智能体协作总纲与工程指南

> 本文档专为 AI 编码智能体（Antigravity、Codex、Cursor、Claude、AutoDev 等）编写，旨在帮助智能体秒级熟悉项目全貌、架构铁律、目录规范与工作流。
> **最近对齐**：**2026-11-04**（**插件扫描归属重构 + 崩溃隔离**：扫描不再整轮委托宿主——快扫本地、深扫按候选位数借「能加载它的那个宿主」做：64 位→懒启动 `plugin_host_x64`（可仅扫描用途）、32 位→`plugin_host_x86` 位桥，`AURA_PLUGIN_DEEP_SCAN=inproc` 回退引擎内深扫；协议 v4→v5，`Op::QueryMetadata` 一次返回 count + N × RemotePluginInfo（VST3 一包多插件完整返回），宿主改 `driver->queryMetadata` 直出；32 位条目 `isCompatible`/文案按位桥可用性判定，不再写死「请装 64 位版本」；宿主深扫加 SEH 兜底，AV 只废单候选不丢整轮；进程内/外扫描结果一致，VST2 冒烟 81 断言双模式全绿 → docs/20-执行/插件扫描归属重构与崩溃隔离-2026-11-04.md）；**2026-11-03**（**Windows VST2 64/32 位适配落地**：收编 Xaymar 净室 `vst.h`（BSD-3-Clause）到 `vendor/plugin-api/vst2/`，退役仓库内非净室 LSP 三头；新增 `VST2` 格式驱动/实例/元数据；64 位走进程内、32 位走 `plugin_host_x86` 位桥；32 位深扫新增 IPC `Op::QueryMetadata` 由桥宿主代查真实元数据；VST2 编辑器 `effEditIdle` 30ms 心跳、`AUR2`/`.fxp` 预设；自建探针 + `smoke_plugin_vst2.py` 77 项断言 × 进程内/外双路径全绿（142 项冒烟）。**安全策略**：64 位 VST2 进程内扫描只做 PE 快扫，绝不在引擎进程 `LoadLibrary` 未知厂商 VST2（实测 Blue Cat/FabFilter 深扫 AV 崩溃），真实元数据由加载路补齐 → [ADR-013](docs/adr/ADR-013-vst2-support-and-clean-room-header.md)、[实施计划](docs/20-执行/VST2插件适配实施计划-2026-11-03.md)）；**2026-11-02**（**Windows 32位位桥与双宿主实装全链跑通**：已完成 `plugin_host_x64.exe` 与 32 位位桥 `plugin_host_x86.exe` 编译分发与门禁落地；跨架构统一 VizFrame 守护 `1600 || 1596` 杜绝 ABI 静默漂移；攻克 32 位 VST3 `InitDll()`/`ExitDll()` 规范生命周期与模块初始化机制，真实 32 位 VST3 与 CLAP 插件加载、元数据解析与跨位数无锁环实时音频处理全链跑通；`smoke_win32_plugin_host.py` 19 项全绿通过；UI 插件搜索框已展长填满；**插件双宿主架构定案**：原 uradsp_plugin_host 明确重命名为 plugin_host_x64 并规划 32 位位桥宿主 plugin_host_x86，扩展名随平台自适应；Win 平台支持 VST3/CLAP/VST2，明确排除 AU 并在 UI 隐藏，LV2 暂缓；UI 插件列表搜索条自动展长占满、分类按钮紧凑靠右无空位 → docs/10-架构/插件双宿主架构与跨格式扩展方案-2026-11-02.md；**高危并发遗留对账**：L-01/02/03 早已于 10-31 晚由 ADR-011+P-047/P-048 彻底闭环，当前仅在册遗留为 L-04 混响参数平滑）；**2026-11-01**（**Linux 适配方案已出稿**：三轴全面取证（引擎 C++ / APP / 构建测试门禁）→ `docs/10-架构/Linux适配方案-2026-11-01.md`；**同日 owner 裁定 Linux 三项产品语义**（D-5 追求功能对等 / D-6 PulseAudio simple API 优先 / D-7 首期只做插件消费者并隐藏 Linux 插件目录 UI）→ [ADR-012](docs/adr/ADR-012-linux-platform-rulings-and-branch-policy.md)；**分支策略：`feature/linux → dev → main`**（单向；Linux 代码全在 `feature/linux`，验证通过后合 dev，**dev 决定是否合 main**）；台账：销账 13 项 / 仍在册 4 项 / 待裁定 1 项（仅 D-4））；2026-10-31（D-1 裁定：限幅器是内置信号链最后一道门，ADR-010 + 门禁 `smoke_limiter_final_gate.py`；D-2 `assets` 大二进制已闭环——`filter-repo` 重写全部历史并 force-push，本地 `.git` 203.6MB → 50.6MB，分支/标签历史中 `.irs`/`.vdc` 条目为 0，回归门禁 `tools/bin/assets_untracked_scan.py`；D-3 dev→main 已合并（PR #15））；2026-10-28（复核 Freeverb 退役、链页 20 级、VizFrame 1600B（ABI v2）；2026-10-19 已同步引擎尖端 Phase 1~3、多声道 Phase 1~3、空间音效 L1 + Phase A/B1/B2a/B2b/B2c/B3a/B3b/B3c（头跟踪/仰角/mix/OpenTrack、6/8ch 双耳虚拟环绕、VM 8ch、本地多声道入引擎、ASIO 双线 2/4/6/8 档多声道传输、FDN、全通散射、镜像源早期反射）、VizFrame 536B/21 节点电平、`graph.effects` 21 项、VAIO 4.0/5.1/7.1 与四模式驱动实况、`.irs`/`.vdc` 跟踪实况）。

---

## 1. 项目定位与架构总览

**AuraDSP** 是一款面向跨平台（Windows 11 / Android）的下一代高品质音频 DSP 引擎与现代控制台套件。

### 技术栈与分层

| 层次 | 路径 | 核心技术 | 职责与契约 |
|---|---|---|---|
| **核心引擎** | `engine/` | C++20, MSVC/CMake | **P3a 后由 `core/desktop/engine_api` 上移至顶层**：`auradsp_engine.{h,cpp,def}`（ABI 契约）+ `engine_internal.h`（私有符号单一入口）+ `chain/`（`engine_{chain,convolver,viz,probe,audiofile}.cpp` 链与 IO）+ `dsp/` 11 个自研效果 TU（含 `dsp_dyneq.cpp`、`dsp_spatial.cpp`）+ `plugins/` 插件宿主（**2026-10-20 P1 迁移**：`api/` + `driver/` + `formats/` + `platform/win32/` + `integration/` + `tests/`）+ `legacy/`（**2026-10-16 由 `vendor/libjamesdsp/` 收编**的 JamesDSP C 算法核：12 级经典音效 + EEL2 + libsamplerate，补丁登记见 `engine/legacy/PATCHES.md`）。严格遵循 **RT-Safe（音频线程零锁、零内存分配、零系统调用）** |
| **平台适配器** | `core/desktop/windows/` | CMake + MSVC + WASAPI | 桌面 DLL 构建脚本与 Windows 音频适配；产物 `out/Release/auradsp_engine.dll` 为 DLL 真相源 |
| **Windows 驱动套件** | `core/desktop/windows-drivers/` | Windows SDK（用户态）+ WDK（内核态，待） | 与 `engine/` 彻底解耦的传输/格式层：`02_voicemeeter_client/`（VM 回调泵）、`03_system_apo/`（自研 APO `AuraApo.dll` + Configurator/selftest/tone_play/诊断探针）、`bridge/`（无编号 FFI 桥：`common/PluginBridge.h` + `vm_bridge/` VB 桥 + `asio_bridge/` ASIO 桥 + `vaio_bridge/` VAIO 桥）。规则与现状见该目录 README |
| **第三方源码** | `vendor/` | C / C++ | **只读**：仅剩 `plugin-api/{clap,steinberg}`（行业接口标准）。原 `libjamesdsp/` 已于 2026-10-16 收编至 `engine/legacy/`（见下「核心引擎」行与 `engine/legacy/PATCHES.md`）；补丁仍须 `[PATCHED-AuraDSP P-xxx]` 标注并登记 `engine/legacy/PATCHES.md` |
| **运行资源** | `assets/` | IR / VDC / EEL | **P3b 后由 `resource/` 改名**：`convolver/`、`ddc/`、`liveprog/` + `manifest.json`。本地约 242.9MB（2501 文件）；`.irs`/`.vdc` **已彻底不在 git 中**（D-2，2026-10-31 夜：`filter-repo` 重写全部历史 + force-push，本地 `.git` 203.6MB → 50.6MB；重写前为 2443 个 / 241.6MB），走 release 附件（资源包现由 Release v0.5.0 挂 5 个资源包承载；独立版本线 `resources-v*` 首版 0.0.1 就绪后迁移，见 `installer/docs/01` §2.4，`dist/AuraDSP-Windows-x64.zip` 内嵌 `resources/`）；`manifest.json` + `README.md` 仍在版本控制内作台账；门禁 `tools/bin/assets_untracked_scan.py` 常驻守卫，**不得 `git add -f`** |
| **应用前端** | `app/auradsp_app/` | Flutter 3.47.7+, Dart FFI | 现代暗黑精致音频工作站 UI；6 页导航体系（主页/效果/脚本/插件/处理链/可视化）；高频可视化与状态隔离 |
| **无锁桥接** | `engine/auradsp_engine.h/.cpp` | SPSC 无锁环形缓冲区 | 引擎以 30fps 向 UI 单向推送 1600 字节定长 `VizFrame`（ABI v2；前 536B 与 v1 兼容；含 32 带输出频谱 + 32 带 EQ 输入频谱、总峰值及 21 节点 per-stage 电平/GR 槽位及 per-channel 电平；`sizeof == 1600` 断言守护 ABI，改动须同步全部 ctypes 镜像） |
| **参考源码** | `source/` | C/C++/Java/Kotlin | 第三方参考代码库（只读，严禁嵌套 `.git`，严禁在此写代码） |

> ⚠️ **路径易错点（P3a/P3b 后务必核对）**：本仓已走向"顶层扁平化"，旧路径一律失效——引擎在 `engine/`（**不是** `core/desktop/engine_api`），第三方在 `vendor/`（**不是** `core/desktop/vendor-src`），资源在 `assets/`（**不是** `resource/`）。写任何文档或脚本前先按此核对，避免制造新的漂移。

---

## 2. 目录规范与职责划分

| 目录 | 职责范围 | 规则与约束 |
|---|---|---|
| `engine/` | **桌面引擎源码**：ABI 契约 (`auradsp_engine.*`)、`engine_internal.h`（私有符号单一入口）、`chain/`（`engine_{chain,convolver,viz,probe,audiofile}.cpp`）、`dsp/`（每效果一文件）、`plugins/`（`api/` 公共头、`driver/` 扫描与槽位、`formats/` VST3/CLAP/VST2 实例、`platform/win32/` GUI/工具、`integration/` 引擎胶水、`tests/` 宿主直调测试）、`legacy/`（2026-10-16 收编的 JamesDSP C 算法核 + `PATCHES.md`） | 修改任何音频路径必须保证 RT-Safe；新增自研效果请落 `engine/dsp/` 并登记 `CMakeLists.txt`；**P1 后插件宿主文件在 `engine/plugins/` 下，勿再按 `engine/host/` 旧路径引用**；`legacy/` 视同 vendor 只读，补丁须登记 `engine/legacy/PATCHES.md`，engine 侧引用其头必须写 `legacy/jdsp/...` |
| `core/` | **平台壳**：`core/desktop/windows/`（CMake + WASAPI，DLL 真相源在 `out/Release/`）、`core/desktop/windows-drivers/`（Windows 底层驱动套件：VM 泵 / 自研 APO / VB 桥，独立 CMake 不进引擎构建）、`core/android/`（registrar / spike / stubs / 独立 vendor-src） | 构建脚本集中于此；纯算法改动应在 `engine/` 内进行，不要动这里的文件清单 |
| `vendor/` | **行业接口标准只读源码**：`plugin-api/`（CLAP / Steinberg VST3 官方头 / **VST2 Xaymar 净室 `vst.h`**）。原 `libjamesdsp/` 已于 2026-10-16 迁至 `engine/legacy/`（`a81dc04`） | 补丁必须 `[PATCHED-AuraDSP P-xxx]` + `engine/legacy/PATCHES.md` 登记；升级即重新提取覆盖。**VST2 编译只认 `vst2/vst.h`（BSD-3-Clause）；Steinberg 官方 2.4 归档仅 `source/` 只读，严禁入 vendor/Release** |
| `assets/` | **运行资源**：`convolver/`、`ddc/`、`liveprog/` + `manifest.json`（本地 242.9MB，原 `resource/`，P3b 改名） | 打包与盘点走 `tools/resource_pipeline/`；勿把 python 脚本或日志混进资源树；`.irs`/`.vdc` **已不在 git 中**（D-2，2026-10-31 夜 `filter-repo` 重写全部历史 + force-push；重写前为 2443 个 / 241.6MB），门禁 `tools/bin/assets_untracked_scan.py` 守卫，**勿 `git add -f`** |
| `app/` | Flutter 前端工程、L10n、各功能页、FFI 绑定 | 构建命令必须带 `--no-tree-shake-icons` |
| `test/` | **全量测试套件**：`test/smoke/`（C++ 引擎单测）、`test/ui/`（UI 自动化置顶测试）、`test/data/`（测试数据）、`test/date/`（**日期任务归档区**） | 测试统一入口 `python test/runner.py` |
| `test/date/` | **日期任务归档区**：`test/date/2026-XX-XX/<task>/`（如 `perf-baseline`、`perf-final`）；每个任务固定 `work/`（原始采样、临时构建、对照截图）+ `outputs/`（结论文档、机器可读总表） | **根目录不再新建日期目录**：所有按日期组织的任务产物一律落 `test/date/2026-XX-XX/<task>/`；`work/` 由 `.gitignore`（`test/date/**/work/`）忽略、不入库，`outputs/` 正常跟踪；跨目录引用必须写全 `test/date/...` 路径 |
| `tools/` | **开发辅助工具与小组件**：`bin/push_via_api.py`、`probe/gen_test_irs.py`、`probe/diag_rail_icons.py`、`probe/bench_effects.py` 等；另有 `resource_pipeline/`（资源打包）与 `calibration/`（校准转换） | 纯工具性质，不包含测试用例；`probe/` 为一次性探针、`archive/` 为过程产物，均不进门禁 |
| `docs/` | 架构方案、UI 设计规范、决策记录 (ADR)、阶段报告；含 `参考技术手册/`（第三方 PDF 手册本地只读区，约 220MB，仅 README 清单入库） | 方案先行，设计更新后必须同步文档；参考手册区只读，禁改禁搬，规则见 `docs/参考技术手册/README.md` |
| `.ai/` | **AI 自治沉淀区**：`.ai/memory/`（**项目记忆唯一入库真相源**：`MEMORY.md` 长期范式 + `YYYY-MM-DD.md` 当日过程）、`.ai/rules/`（硬规则与 UI 设计规范） | 各类智能体共享知识，无需人工介入。**注意**：`.workbuddy/memory/` 被 `.gitignore` 忽略、跨智能体不可见，只能当热副本，阶段结束必须搬迁合并到 `.ai/memory/`（规则见 `.ai/README.md` 记忆分工） |

---

## 3. 智能体工程开发铁律

### 3.1 引擎与音频契约（RT-Safe）
1. **音频主线程绝对禁区**：禁止 `malloc/free/new/delete`，禁止 `std::mutex/jdsp_lock` 竞态，禁止 IO/打印/系统调用。
2. **控制/RT 互斥层级（Z13/Z14 后铁律）**：`auradsp_set_param/get_param` 全程持 `h->ctrl_mutex` → 控制-控制竞争结构上被排除；控制侧真正需防的是 vs RT——RT 入口（`JamesDSPProcessMultiplexedStageSet` 两分支 / `JamesDSPProcess`）honoring `kAuraStages[i].lock`（comp/convolver/ddc/liveprog=1）持 `jdsp_lock`，**故控制侧任何结构变更路径必须同持 `jdsp_lock`**（例：`apply_comp`、`set_ddc_enable`/`set_ddc_load`）。`jdsp_lock` **非递归**：已内部自锁的函数（`DDCStringParser`）不可再包。修法模板：RT lock=1 + 控制侧同锁 + 同型竞争门禁（`smoke_comp_race.py`/`smoke_ddc_race.py`）。
2. **表驱动处理链（P-004）**：12 效果节点顺序经由 `graph.order` 完整重排序，非法集合必须白名单全拒；每个 stage 的峰值采样必须是 $O(1)$ 常数时间。
3. **文件门卫（FileGate）**：加载 IR 脉冲文件或 VDC 文件必须经由六道门卫校验（magic、尺寸、NaN/Inf 检测、重采样），防崩溃与内存溢出。
4. **"12 级"只指 vendor 链，不等于效果总数**（易错点）：
   - `AURADSP_VENDOR_STAGES = 12` **专指** `libjamesdsp` 内部那一条链（`JamesDSPRebuildChain` 校验 12 个恰好一次），`graph.order` 也只接受这 12 个 id；
   - 但**链路实际不止 12 个节点**：`graph.effects` 注册表共 **21** 条 = vendor 12 级（注册表中 `post`/`limiter` 分列故占 13 条）+ 自研 8 个（gate、filter、bassmono、haas、exciter、loudness、dyneq、spatial，见 `chain/engine_chain.cpp` 的 `process_stereo_chain`）。
     ✅ **dyneq 已登记**（`e1375b0`，2026-10-13）：三段全参数动态 EQ（`1631b52` 新增）现已进注册表（`tier:1, exposed:true`）并接入链路，早期"未登记"警告已作废。新增效果请按下面第 5 条一并登记注册表并同步计数注释（`91ea9d2` 教训：e1375b0 补条目时漏改说明段计数）。
   - 改 vendor 链长度同步 3 处：`AURADSP_VENDOR_STAGES`、`kAuraStages`、`Dart kEngineStageCount`；**改自研模块则另说**，不要把两者混为一谈。
5. **新增自研效果落地清单（6 步，缺一不可）**：`engine/dsp/dsp_xxx.cpp` 实现 → `engine_internal.h` 声明 + `Params` 字段 → `process_stereo_chain` 插入 → `CMakeLists.txt` 源文件表登记（漏登记会**静默不参与编译**）→ `graph.effects` 注册表登记（漏登记则**处理链页不显示该节点**，见上条 dyneq 教训）→ `test/smoke/smoke_xxx.py` 并挂入 `runner.py`。

### 3.2 UI 与交互规范
1. **高频渲染与状态隔离**：30fps 的电平与频谱可视化通过独立 `ValueNotifier` 驱动局部重绘，严禁触发根级 `notifyListeners`。
2. **双击出厂归位**：所有参数滑块均支持整行双击恢复 `ParamDefaults` 出厂默认值；声场展宽双击归位时联动清空 5 个子带。
3. **构建必带参数**：`flutter build windows --release --no-tree-shake-icons`，严禁遗漏 `--no-tree-shake-icons`（避免 Material 图标子集化静默丢失）。

### 3.3 自动化测试铁律（血泪教训）
1. **测试与开发工具严格分流**：测试脚本一律放在 `test/smoke/` 或 `test/ui/`，开发小工具放在 `tools/`。
2. **新测试必须挂载 `test/runner.py`**：新增 `test/smoke/*.py` 须登记进 `smoke_files` 列表，新增 `test/ui/*.py` 须登记进 UI 默认列表——未挂载的测试不会被 `--smoke`/`--ui` 执行，等同废测。
3. **UI 自动化测试三要素**：
   - **强制前置置顶**：必须调用 `HWND_TOPMOST` + `SetForegroundWindow`，并在 `WinSta0\Default` 物理活动桌面上交互。
   - **状态先行保障**：在拖动任何滑块前，**必须先检测并确保卡片主开关处于打开激活状态**；开关关闭时滑块处于 disabled 状态，任何点击拖拽均为无效操作！
   - **像素级几何命中**：通过窗口矩形归一化与实际组件像素推导 Thumb 圆心位置，严禁盲目写死假坐标。
   - **视觉差分闭环断言**：每步操作前后必须比对截图区域像素差异（`assert_images_differ`），确保动作真正生效，杜绝假测试。

### 3.5 UI 设计系统与跨端交互铁律（详见 `.ai/rules/ui_design_spec.md`）
1. **统一问号徽标（`InfoBadge` 强制铁律）**：
   - 严禁手写 `Tooltip(child: Icon(Icons.help_outline_rounded))`。凡提示气泡一律统一调用 `InfoBadge(message: ...)`。
   - **电脑端**：持续常驻显示，hover 300ms 弹出，点击可切换锁定/关闭。
   - **移动端**：不滑动时持续隐藏保持极简；滑动页面时唤醒显示，停止滑动后延迟 2.6s 平滑淡出；支持触屏直接点击气泡展开/收起（3.5s 自动淡出防遮挡）。
   - 页面根骨架 `PageScaffold` 已内置 `HelpVisibilityScope`，自动监听滚动。
2. **效果器卡片布局与输出增益外框（`OutputGainFrame`）**：
   - 卡片严禁无意义术语与冗余后缀（去重去杂词，如禁用“链头处理”、“DBB”、“Shelf”等）。
   - 常用参数主卡展示，深度进阶参数统一收纳于 `AdvancedSection` 折叠框。
   - 凡带有输出增益/补偿门/声像的效果器，**必须使用 `OutputGainFrame` 包裹并固定置于卡片最末尾**，形成清晰视觉区隔；且必须配置 `defaultValue: 0.0` 及 `onResetToDefault` 出厂复位能力。
3. **视觉一致性与字体排版**：
   - 参数标签统一使用 `labelOf(p)` 字体风格，严禁私自缩小字体或改为细体破坏视觉层级。
   - 滑块已有 `unit` 属性时，`format` 格式化严禁追加单位，杜绝出现 `1000ms s`、`0.0dB dB` 重复单位。
4. **处理链与效果器名称严格对齐**：
   - `chain_page.dart` 的 `stageLabelOf(l, id)` 与 `effects_page.dart` 卡片标题和 Arb 词条必须 100% 对应，严禁同名异义或同义异词。

---

## 3.6 分支策略（2026-11-01 owner 裁定，ADR-012）

```
feature/linux  ──(实现代码，验证通过)──▶  dev  ──(dev 验证合并后，dev 决定)──▶  main
```

- **Linux 代码全部在 `feature/linux`**（从 `dev` 切出）；验证通过后合入 `dev`；`main` 的合并**由 `dev` 决定**，非自动。
- **单向合并**：`feature/linux → dev → main`；`feature/linux` **不得直连 `main`**。
- **决策记录（ADR / 方案文档 / 台账）走 `dev → main` 常规 PR 路径**，不属于代码；它们不应阻塞 Linux 开发。
- 分支命名：`feature/<主题>`。

## 4. 常用命令速查

```powershell
# 1. 运行底层 C++ 引擎全量单测 (100% PASS 门禁)
python test/runner.py --smoke

# 2. 运行 UI 自动化前置置顶测试
python test/runner.py --ui

# 3. 前端静态代码分析
cd app/auradsp_app; flutter analyze

# 4. 构建 Release 版本应用
cd app/auradsp_app; flutter build windows --release --no-tree-shake-icons

# 4b. 构建 C++ 引擎并自动同步产物到 test/app-runner/dist
#     入口 = 根 preset（windows-x64 → windows-x64-release，构建树 build/windows/x64，
#     产物 core/desktop/windows/out/Release）；成功后自动分发三处消费端
bash core/desktop/windows/build_engine.sh

# 4c. 仅同步已构建产物（不重新编译）：把真相源覆盖分发到 test/app-runner/dist
#     任意端点缺失或单文件失败仅告警跳过；-WhatIf 预演，-PackZip 重打包发行 zip
powershell -ExecutionPolicy Bypass -File tools/sync_artifacts.ps1

# 4d. 发行包清单：dist/<产品>-<平台>/build-info.txt（版本/提交/DLL SHA256）
python tools/bin/dist_manifest.py --check

# 4d. 设计令牌：改 app/auradsp_app/design/tokens/aura.tokens.json 后重生成（tokens.g.dart 勿手改）
python tools/gen_theme.py            # --check 只校验不写盘
python tools/l10n_cjk_scan.py        # 硬编码中文扫描；--baseline 降基线（棘轮）

# 5. 受限网络或 API 推送代码到远端
python tools/bin/push_via_api.py main
```
