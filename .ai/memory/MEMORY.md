
# AuraDSP 项目长期备忘
- 项目定名 **AuraDSP**（2026-10-08，用户选定；原方案 PrismDSP/Resona 落选）。仓库主分支 main，初始提交 d1e35fa。
- **里程碑 2026-10-09：Enforcing 端到端打通**（sepolicy 9 条 + bool-read 修复后，听感确认混响/低音可闻）。设备验证默认 bass 15dB + LARGEHALL1（有意极端值，参数接线后回调）。
- source/ 为第三方只读克隆区不入库；vendor-src 子目录禁止携带嵌套 .git（已清除 8 个，含 spike/aidl-src 5 个）。
- .gitattributes 已统一 LF。构建产物 out/、venv/、.codegraph/ 均在 .gitignore。
- 写代码时优先用 codegraph 检索代码结构（项目根 .codegraph/ 索引）。
- 架构唯一真相源：docs/项目架构与开发规范.md（命名/Git 规范/铁律都在里面）。
- **vendored libfmq 坑**：`read(T*,size_t)`/`write(const T*,size_t)` 返回 **bool** 不是元素数（MessageQueueBase.h:153/208）。永远 `if (!mq->read(...))`，禁止 `size_t n = mq->read(...)`（bool→1 静默错误，曾造成两天"read status failed"假根因，2026-10-09 才定位）。
- **build_jdsp.sh 增量缓存**：已改为 `[ ! -f out ] || [ src -nt out ]`；旧版只查存在性导致改源码不出现在产物里。鉴别手法：改过的行为在设备上没生效时，先用可观测的编译期常量（如新 MQ 容量 7680 vs 旧 3840）判定设备跑的是不是新二进制。
- **ksud sepolicy 语法**：magiskpolicy 式 `allow s t class perm`（无冒号）。9 条规则集 = Enforcing 下 FMQ memfd 跨域共享最小集（详见 .workbuddy/memory/2026-10-09.md）。
- **ksud 模块脚本变量作用域**：安装期 customize.sh 用 `MODPATH`（无 MODDIR）；运行期 post-fs-data.sh/service.sh 需自设 `MODDIR=${0%/*}`。混用会得到空变量 → 路径缺前缀 → "Read-only file system"。首装失败 ksud 自动清 modules_update，重装幂等。
- **Phase 4 已完成**：auradsp_jdsp_v0.4.0 KSU 模块已安装（soundfx 快照 22 库 + 启动挂载链），持久化验证待重启。
- 运行中手动替换 .so 后必须 `killall audiohalservice.qti` 确保 dlopen 新库（模块化部署路径 post-fs-data 启动则天然生效）。
- **品牌体系（2026-10-09 用户拍板）**：应用统一名 **AuraDSP**；引擎族 **AuraDSP Engines**，Android 拆 **(Root)** KSU 模块（HAL 全局）+ **(Rootless)** APK 内置（会话级）；UI=Flutter（多语言/多声道/可视化）；APP = Engines + UI。产品真相源：docs/产品架构总览.md。
- **GitHub**：仓库 github.com/li589/AuraDSP（公开）；gh CLI 已登录 li589 可直接用；本地目录 JamesDSP 即该仓库。
- **git 提交纪律**：提交前 `git status --short` 全量核对；勿按子树 add 而提交信息声明树外文件（曾漏 registrar/include|src/ 靠补提交修复）。

## AuraDSP Win11 APP（2026-10-09 全链路打通）
- Flutter SDK：**C:\FreeRulesPrograms\BasicToolkits\flutter**（3.47.7 stable；2026-10-09 自 C:\dev\flutter 迁移，已入用户 PATH，规范文档 §5.1 有环境表）；APP 工程 app/auradsp_app；引擎 DLL 产物 core/desktop/windows/out/Release/auradsp_engine.dll。
- 构建：`flutter build windows --release`（约 40s，analyze 0 error）；产物 build/windows/x64/runner/Release/（exe+DLL 随包，install 链在 windows/CMakeLists.txt，DLL 路径三级向上 `../../../core/...`）。
- 引擎 handle 独占音频 isolate（lib/engine/audio_isolate.dart，WASAPI shared 轮询推）；UI 不触 RT 路径；viz 经 ValueNotifier 30fps。
- **viz 频谱三连坑（2026-10-09 定位）**：① emit_viz 只在发射时写环形历史 → 每两块丢一块产生梳状混叠假峰（已拆 viz_write 每块写 + emit 只做 FFT）；② FFT 1024@48k 分辨率 46.9Hz，20-50Hz 对数带分不到 bin → 提到 4096；③ 直流/块不连续经汉宁窗泄漏进最低带 → FFT 前去均值。烟囱测试必须用相位连续信号（复用 240 帧块缓冲会产生 0.2 级直流假象）。
- **声场展宽上限**：libjamesdsp mix=1.0 执行 band-centre（中置全剥离，单声道→静音）。UI 0-100% 映射引擎 0-0.75（AppModel.stereoWidenMax）。
- 混响= T2 效果仅品质档：UI 点击预设自动升档（setReverbPreset）+ 守卫徽标可点。延迟读数 = 算法附加延迟（T0 效果恒 0，语义 tooltip 已加）。
- **_IconAction 教训**：透明底色的 GestureDetector 必须 `behavior: HitTestBehavior.opaque`，否则 deferToChild 下点击穿不进（曾致侧栏收起钮失灵）。
- FFI 三教训见 memory/2026-10-09.md（同文件 Edit 禁并行 / asFunction 必须显式 Dart 签名 / WASAPI vtable 按时序交错绑定）。
- **沙箱清杀子进程**：PowerShell 工具会话结束时其子进程（如启动的 GUI app）被一并杀掉，不是崩溃；验证 GUI 要在同一条 bash 命令里启动+测试。
- **扩展规划 v0.1（2026-10-09）**：docs/APP-插件与信号图扩展规划.md。五方向：插件沙箱桥（每插件一进程，VST3 GPLv3 路线 + CLAP MIT 一等公民 + VST2 用 fst 头）/ Liveprog EEL2（vendor 已有 liveprogWrapper，加 slider regvar 即可）/ 信号图一模型两视图（graph.* 进 engine_api v2，Android 图视图只读）/ 卷积 IR（ASRC+dr_flac 已在 vendor，缺 ABI+FileGate）/ 效果两级参数卡。决策点 D1~D5 待拍板，排期 M2→M4→M3→M5→M1→M6→M7。
- **M2 Liveprog 已交付（f86a86a 已推送）**：engine_api v1.1 + vendor 补丁 P-001 + 编辑页。坑：EEL @init 空段=语法错误；NSEEL regvar 必须编译前（freevars 清注册）。下轮 M4 卷积+FileGate → M3 链视图。
- **M4 卷积+FileGate 已交付（98f037e 已推送）**：convolver.* 全暴露 + 六道门卫 + T2 守卫 + UI 卷积卡。坑：dr_* 实现 vendor 已有勿重复 define（LNK2005）。下轮 M3 链视图。
- **审查修复 R-1/R-2 + M3-a 已交付（2d687da 已推送）**：_wfopen 中文路径/IR 64M 样本上限；tube+xfeed 开关 + graph.effects 注册表 + 信号流条。坑：heredoc 写 C 转义三层损耗（用 chr(34)）；push 假 up-to-date 须 gh api 核实。真·重排序需 process 链补丁（M3.5 决策）。
- **M5-a 分带展宽已交付（34afe03 已推送）**：P-002（5 子带独立 mix）+ StereoCard 高级折叠区。坑：engine 清 band 标志必须同时调 vendor UseUnifiedMix（烟囱 mono 定量法：全带 0→0.60/全带 1→0）；build 退出码被管道 grep 吞——验证构建要单独数 BUILD OK。bass 频点细化需换算法（dbb 网格固定）；参数化混响待 D4。
- **M5-b 低频搁架已交付（fe37e7b 已推送）**：wrapper 层 RBJ low-shelf（零 vendor 改动）+ BassCard 高级折叠区。教训：①shelf f0=半增益点（RBJ 语义）②低频烟囱须跨块取全局峰（单块采不到峰）③vendor 输出限幅恒开会钳强正增益。剩：M5-c 参数化混响（D4）/ M3-b。
- **M5-c 参数化混响已交付（5a23722 已推送）**：wrapper Freeverb（8comb+4ap，链后 wet/dry）+ 03 卡四滑块。坑：damp=1=damp2(0) 反馈全灭退化态（湿尾归零合法）；heredoc>2KB 会被 bash 截断——改 Write 脚本执行，ARB 批量键丢失会在 gen-l10n+analyze 才暴露。
- **M3-b 预设系统已交付（da3e9f8 已推送）**：全参数 JSON 快照 %APPDATA%/AuraDSP/presets；行尾欠账清偿（仓库级 autocrlf=false）。规划剩 M1 插件（待 D1-D5）+ M3.5 重排序（需 ADR）。
- **M5 第二批 eq.curve 已交付（33402a7 已推送）**：multimodalEQ 轴注入（NUMPTS=15、makima/om0）；补齐必须 log 域重采样（线性采样挤掉轴点）。**source/ 审理报告已出**（docs/）：P-1 全员嵌套 .git 待剥除；P-2 RootJamesDSP README=Rootless（疑克隆错仓）待核实；lsp-plugins 源码组织待核验（src/ 无预期插件子目录）。
- **阶段收尾（70de148 已推送）**：source/ 已剥 .git+ORIGIN.md 登记（RootJamesDSP=Rootless fork 结案；lsp=元仓库，各插件独立仓；bass_enhancer 算法在 LSP 插件仓，pulseeffects 只 wrapper）；tools/ 沉淀烟囱+UI 断言 8 件套；阶段性回顾见 docs/。待拍板：D1 GPLv3→M1、M3.5 ADR。
- **算法审计+M3.5/UI 方案已出（f651607 已推送）**：全效果 1.03% CPU 无热点；docs/UI-六页架构与M3.5重排序方案.md（六页/双击归位/VDC/3D 混响/处理链页=P-004 链表化 ADR-004 草案）。API 推送 422 时改 JSON body 三步手工（blob/tree/commit sha 逐级校验）。D1 GPLv3 已由用户拍板。
- **M3.5 重排序已交付（726d4f9 已推送）**：P-004 表驱动链（chain[16]+RebuildChain 白名单校验，双 process 函数改表遍历）+ graph.order（完整重排模型）+ 六页导航 + 处理链页 v1。**验证方法论：顺序类改动的数值验证会被 limiter 渐近底噪淹没（同序两次差 0.0043）——必须用跨非线性级饱和的强效应探针（liveprog 增益×2：钳 1.0 vs 尾置 1.3985）**。改 vendor 关键补丁优先用 Edit 工具（python replace 曾静默未落盘）。UI 点击 rail 要取带中心，先像素探测几何。
- **UI chrome 修复（fbc78d7 已推送）**：①**Flutter 图标 tree-shake 大坑**——增量构建不重新子集化 MaterialIcons，新增图标静默空白且换名无效；诊断看 `flutter_assets/fonts/MaterialIcons-Regular.otf` 大小（几 KB=子集，正常 1.65MB）；根治=构建加 `--no-tree-shake-icons`（已写入 docs §5.1 与构建命令）。②设置入口移顶栏右上角齿轮。③收起态点 logo 展开（去独立按钮）。④AnimatedDefaultTextStyle 是替换语义，漏 fontFamily 会让中文回落系统字体。⑤ValueSlider 双击归位 + 高级区箭头常亮。⑥UI 验证脚本必须阶段化：点击会污染后续坐标。
- **M5-3 已交付（cf1b402 已推送）**：P-005 卷积干湿比 + ddc.load/enable（VDC）；卷积卡改名「脉冲响应」+ 混合比例滑块 + VDC 卡。**两个 memset/返回值坑**：①P-005 scratch 必须在 JamesDSPInit **之后**绑定（内部 memset 清指针）；②DDCStringParser 返回 1=成功/0=跳过/-1=失败，按 rc!=0 判失败会误报。设置框背景=Dialog barrierColor+面板底色（原 transparent 导致无背景）。
- **脚本页三件套 + 卡死修复（6f1b462 已推送）**：Tab 捕获（Shortcuts/Actions 覆盖焦点遍历）/EEL 格式化（printDepth 与 nextDepth 分离）/语法检查（问题列表+点击跳行）。**重大教训：同一 FocusNode 同时挂外层 Focus 与 TextField = release-only 死循环**（无 assert，双核满转 8s/4s；外层拦截层必须用自建节点）。验证：GetProcessTimes 双采样 CPU（沙箱吞 keybd_event，键盘 UI 行为不可自动化，纯 Dart 逻辑走 flutter test）。
- **M3.5-c 处理链电平与旁路已交付（fe8e31e 已推送）**：P-004 链表注入 stageIdx，Process 循环常数时间 $O(1)$ 峰值采样无额外 FFT；280 字节定长 VizFrame 包含 16 声道 dBFS 电平并推 SPSC 无锁环；Dart 30fps 隔离订阅 + 节点独立旁路胶囊。验证：smoke_chain_meter PASS（直通 -10.46dBFS，Liveprog 放大 -4.44dBFS）。
- **测试基建彻底根治与目录分流（2026-10-10）**：①**血泪教训**：卡片主开关（AuraSwitch）未开启时，Flutter Slider 处于 `enabled: false`，任何拖拽和双击被框架无视！必须先 `ensure_switch_on` 激活卡片；②**像素级 Thumb 定位**：严禁盲写假坐标，通过实测 1400x900 窗口下 Thumb 圆心 `(583, 529)`、低频搁架 Thumb `(866, 715)` 真实拖拽；③**全流程差分断言**：前后截图区域像素比对，差异 < 限额坚决报错；④**目录职责明确**：全量测试入 `test/`（smoke/ui/data），开发小组件入 `tools/`；记忆入 `.ai/`，根目录建立 `AGENT.md`/`CLAUDE.md`。
- **文档导航入口 docs/README.md（2026-10-10 建）**：全文档索引。真相源仍是 `docs/项目架构与开发规范.md`（已升 v1.2）+ `docs/产品架构总览.md`；决策在 `docs/adr/`（ADR-001~004 已冻结，回退须新增编号不得原地改写）。
- **ADR-004 插件宿主形态（2026-10-10 定案）**：v1 **进程内双插槽 + 五级阶段插入**，取代扩展规划 v0.1 的"桥进程首选"。`kMaxPluginSlots=2` 编译期常量；`insertStage` 0=Pre-DSP/1=Pre-Vendor/2=Post-Vendor/3=Post-Reverb(默认)/4=Post-Limiter；ABI 新增 13 个 `auradsp_plugin_slot_*`，**旧单插槽符号全部保留**转发 slot 0（向后兼容无破坏）。**接受的代价：插件崩溃带崩宿主**——桥进程化是 ADR-005，前置条件是"先有插件崩溃采集口径"，无数据无法论证隔离收益。
- **新测试必须挂 test/runner.py（2026-10-10 教训）**：`smoke_multislot_and_stages.py` 与 `ui_verify_vst_and_eel.py` 写完后忘了登记，`--smoke/--ui` 跑不到——**未挂载的测试等于废测**。已补登，现为 10 项 smoke 全绿。
- **插件预设落盘分工**：引擎只做 VST3 `getState/setState` 或 CLAP `extension_data` 流序列化；路径与命名全归 Dart（`%APPDATA%/AuraDSP/plugin_presets/<插件名>/*.aurapreset`）。引擎侧不解析路径、不碰外部文件 IO。
- **用户裁定（2026-10-10）**：`docs/forensics/` 下 34MB 原始日志/tombstone **保留入库**（审计证据，勿删勿改），不清理。

## 记忆目录统一（2026-10-11 用户裁定）
- **唯一 AI 记忆目录 = `.ai/memory/`**。曾出现第二套 `.workbuddy/memory/`（WorkBuddy 侧），已于 2026-10-11 合并后移除；`.gitignore` 中 `.workbuddy/` 由注释改为**生效忽略**，防止 IDE 侧再次生成时污染工作区。
- 其他 IDE/工具 harness 目录（`.v2c/` `.video_agent/` `.codegraph/` `.tmp/`）一律忽略，不入库。

## 高频坑速查（跨会话最先看这几条）
- `--no-tree-shake-icons`：Flutter 构建漏了它，新增 MaterialIcons 会**静默空白**。诊断看 `flutter_assets/fonts/MaterialIcons-Regular.otf` 大小（几 KB=被子集化，正常 1.65MB）。
- 新测试写完后**必须登记 `test/runner.py`**（smoke→`smoke_files`、ui→UI 默认列表），未挂载=废测。
- UI 自动化：拖滑块前先 `ensure_switch_on`（`AuraSwitch` 关闭 → Slider `enabled:false` → 拖拽被框架丢弃）；必须 `HWND_TOPMOST`+`SetForegroundWindow`；必须 `assert_images_differ` 像素差分闭环。
- `flutter test` 不沙箱化：任何会写 `%APPDATA%` 的测试必须在 `setUp` 注入 `ConfigManager.baseDirOverride` 临时目录。
- libfmq `read/write` 返回 **bool** 不是元素数；`DDCStringParser` 返回 1=成功 / 0=跳过 / -1=失败；P-005 卷积 scratch 必须在 `JamesDSPInit` **之后**绑定。
- 顺序类改动的数值验证要用**跨非线性级饱和的强探针**（limiter 会淹没差异，同序两次差 0.0043 属噪声）。
- **`GetWindowThreadProcessId(hwnd, &pid)`：返回值才是线程 ID，out 参数是进程 ID。** 搞反会得出"同线程"的假结论（2026-10-12 实际踩过，导致 CLAP 白框根因误判一轮）。
- **VST3 `kResultTrue == kResultOk == 0`**（`vendor-src/plugin-api/steinberg/vst3/base/TUID.h`）。日志里 `isPlatformTypeSupported(HWND)` 返回 `0` 表示**支持**，不是拒绝。
- **`std::thread::detach()` ≠ "安全放弃等待"**：它放弃 join 但线程仍持有 `this` 与插件对象引用。超时收尾若 detach，随后 `unload` 释放同一批对象 → `0xC0000374` 堆损坏。正确做法是**隔离（放弃释放）而不是 detach**。
- **插件 GUI 的线程契约**：宿主父窗口、插件子窗口、消息泵必须在**同一个**线程。只建父窗口在本线程、`set_parent` 在别的线程 → 子窗口收不到 `WM_PAINT`（白框）+ 拖动无响应。可用"子窗口线程 ID == 父窗口线程 ID"直接断言。
- **`plugin_cache.json` 曾无 schema 版本戳**，`loadCache()` 无条件加载 → 列表永远显示陈旧数据（曾 76/76 `vendor="Unknown"`）。2026-10-12 B1 已修：信封 `{schema:2,...}`、不符即整份丢弃、落盘前自检拒绝全 Unknown 快照。**再改缓存结构必须同步 schema 版本 + Dart 测试 + rebuild_plugin_cache.py 三处。**
- Windows 进程退出码要看**真实值**：`0xC0000374`=堆损坏、`0xC0000005`=访问越界。Git Bash 报的 127 等低位截断值会掩盖崩溃；用 `subprocess` 包装取 `returncode`。

- **C1 起泵线程按模块共享**（2026-10-12）：`ModulePumpThread`（weak_ptr registry，key=canonical+小写二进制路径）。同 DLL 多槽挂载**绝不能**每实例各建泵线程——LoadLibrary 同模块 → 两条线程互斥 JUCE MessageManager 归属 → 死锁。泵对象 stop 失败必须故意泄漏（PumpDeleter），SEH 任务守卫毒化队列实现单插件崩溃隔离。共享 `once_flag` 不能放进带参的注册函数（只有首个参数生效——2026-10-12 实际踩过，CLAP/VST3 窗口类只注册了一个）。
- **僵尸进程锁 exe 的绕法**：内核态挂死进程 taskkill/Stop-Process 均无效时，`mv` 改名被锁文件（锁随 inode/文件走），链接器即可产出新文件。LNK1104 排查先 `Get-CimInstance Win32_Process`（Get-Process 可能看不见僵尸）。
- **并行会话工作区交缠拆分提交**：`git diff` 逐 hunk 过滤（含自家标记的 hunk）→ `git apply --cached` 精确暂存 → `git checkout-index -f` 同步工作区 → 重新 gen-l10n → 提交 → 备份恢复合并态 → 再 gen-l10n → 第二笔提交。gen 产物必须与所提交的 arb 同状态，否则编译期不一致。

## 延迟档已撤销（2026-10-12，ADR-006 取代 ADR-002）
- **不存在 `mode.latency`**，也不存在 `AURADSP_E_LATENCY_GUARD` 触发的拒绝路径（枚举值 -3 仅为不破 ABI 保留）。混响/卷积/Freeverb **一律自由使能**，设置页已无「延迟模式」三档选择器。
- **撤销理由**（用户实测）：切档静默回滚 → 选项「按了没反应」；守卫方向是「先开关、后切档」→ 改了档位再开效果必然撞拒绝，选项与可用性互相锁死。
- **半成品中间态是根因**：架构侧先「废除拦截、改自动升 quality」，引擎守卫却仍在 → 用户看不出档位却在被档位支配。**教训：跨层撤销决策必须同批落地 UI+FFI+引擎+ARB+文档，停在中间态比不做更糟。**
- 延迟现在是**测量量**：`compute_latency()` 只累加上报（`get_latency_ms()`），UI 用底栏总延迟 + 组件级脉冲实测徽标呈现。`graph.effects` 的 `tier` 字段仅作文档标注，不参与判定。
- 冻结 ADR 不得原地改写：ADR-002 原文保留 + 顶部加「已被 ADR-006 取代」横幅。ADR-005 是「插件桥进程化」预留号（已被 8 处引用），故本次用 ADR-006。

## 频谱渲染两处修复（2026-10-12）
- **高频柱塌成发丝**：`bw = max(1.0, span - gap)`，而 19k~20k 带的真实对数跨度只有中频带的 ~1/4，窄画布上减完 gap 即被钳到 1px。改为 `bw = max(3.0, span - gap)` 并**带内居中**（`x = x0 + (span-bw)/2`），圆角按 `min(2, bw/2)` 自适应。
- **氛围频谱残留最后一帧**：`AmbientSpectrum` 的 repaint 只挂在 `spectrum` 上，音频一停引擎不再产帧 → 画面永久定格；而 `paint()` 若继续重采样陈旧数据，又会把最后一帧的高值**反复抬回**导致永不归零。解法：State 持有 `Ticker` 看门狗，>200ms 无新帧即置 stale，`AmbientEnvelope.decay()` 用 0.70 快速衰减且**不吃陈旧数据**；衰减干净自动停表（空闲零开销）。
- **教训**：预计算尺寸/几何时不要手工复刻布局规则——`TextPainter` 与真实渲染会在字体度量、边框、内边距任一环节不一致（实测同为 110px 约束，估 1 行 18px、实渲 2 行 36px）。tooltip 气泡改为插入后用 `GlobalKey` 读回真实尺寸回正。
- **测试红/绿纪律**：「两分支改成同一公式」后对称性变成结构性保证，此时任何参数值都对称，断言对称的测试抓不住回归——必须断言**绝对下限**（如间距 ≥14px）才能钉住「没有偏移」这个真实症状。

## C2 扫描加速 / 异步不阻塞（2026-10-12）
- **枚举与元数据必须解耦**：`enumerate()` 只做目录遍历（零 PE 读取、零 LoadLibrary），
  元数据在 `scanStep` 里小批量取。一次性 API 直接复用同一条管线
  （begin → 排空 step → end），否则会出现"一次性绕过缓存"的伪性能差异（实测 46ms vs 4ms）。
- **缓存的键粒度陷阱（真实踩坑）**：一个二进制（.vst3 / CLAP bundle）可含**多个**插件类，
  深扫会产出 N 条同 path 的元数据。缓存若按 `path → 单条` 存储，重扫命中缓存时 N 被折叠成 1，
  表现为"深扫冷 79 / 热 76，凭空少 3 个插件"。**键到值是一对多时必须存列表**，
  重建用 `push_back` 而非覆盖。已固化为断言：`deep_cold == deep_warm`。
- **缓存深度要显式建模**：`m_scanCacheDeep` 记录条目是否深扫产出，复用条件为
  "指纹一致 **且** 深度足够"——深扫结果可服务快扫，反之不可（否则快扫后深扫永远拿不到真实类别）。
- **Dart 同步消息循环 case 内不能 `await`**（`await_in_wrong_context`）：把长任务抽成独立
  async 函数 fire-and-forget，结果以事件回报。让出事件循环用
  `await Future<void>.delayed(Duration.zero)`——这是"不阻塞 UI"的实质保障，比任何动画都关键。
- **分块粒度按最坏单步定**：深扫单步 p50 8.7ms 但 max 1041.8ms（长尾在大厂 DLL），
  故深扫 batch=1；快扫 batch=8。别用平均值定粒度。
- 扫描结果**渐进 append** 到 `m_scannedPlugins`，扫描过程中 `get_all` 即返回已扫部分 → UI 边扫边长。

### C3 挂载/卸载异步化（2026-10-12）
- **"锁范围窄"不等于"可以异步"**：`processSlot` 不持 `m_hostMutex`（靠 `inFlight`/`hasActive`
  无锁握手），所以 RT 路径不被 load 阻塞；但 `loadPluginSlot` 把整个加载都放在锁下，
  意味着想异步化就必须整段搬线程——全有全无。**正确做法是先把 load/unload 拆成两段**：
  `prepareInstance`（重活，锁外：解析 bundle → LoadLibrary → createInstance → activate）
  / `commitInstanceLocked`（微秒级，锁内：把指针挂进槽位）；
  `detachInstanceLocked`（锁内短：摘出槽位 + 等 RT 退出临界区）/
  `destroyInstance`（锁外：deactivate / destroy / FreeLibrary）。拆完之后"只让重活上
  控制线程、提交留在调用方线程"才成立。
- **瓶颈是调用方线程，不是锁**：Dart isolate 内音频泵（5ms/轮推 WASAPI）与命令处理
  在**同一事件循环**，所以挂载 p50 77.6ms / max 1144.1ms 会跳过 220 轮泵 → underrun。
  修法是把重活挪到引擎控制线程（std::thread + deque + cv），提交端只做微秒级入队
  （实测 0.010–0.056ms vs 同步 61.6/91.0ms）。
- **异步任务的状态字段用原子**（`std::atomic<int> taskState`），调用方无锁轮询；
  终态码 0 无/1 进行中/2 成功/3 失败。终态**粘性保留**直到下次提交——调用方不必
  担心"读得太早"。
- **被拒的任务不发终态事件**：该槽已有任务在跑时 `submit` 返回 0，此时若还发一个
  "失败"事件，会让上层把在跑的合法任务判成失败。静默返回即可。
- **UI 侧忙态要双向兜底**：引擎回执 `pluginSlotBusy`（真值）+ `loadPlugin` 乐观置忙
  并拦截重复下发。`_slotBusy` 字段**原本就声明了但从未写入**——接线时发现的是死代码。
- **门禁坑**：`flutter test` 与 `python test/runner.py --smoke` **不要并发跑**——
  资源争用会让 Dart 测试超时（`responsive_layout_test` 报 "did not complete"），单独跑则全过。

### C4 编辑器尺寸（2026-10-12）
- **"拉大框多出空白"的根因是宿主 WndProc 里没有 `WM_SIZE` 分支**，不是布局没铺满。
  插件子窗口（VST3 由 `view->attached` 建、CLAP 由 `gui->set_parent` 建）创建后尺寸就
  固定；容器放大 → 客户区变大 → 子窗口不动 → 多出来的是容器自己的空白背景。
- **两种格式的 resize 契约相反，不能统一处理**：VST3 规范要求宿主在 `WM_SIZE` 时调
  `view->onSize(newSize)`，由**插件自己**改子窗口（子窗口句柄归插件、有自己的布局
  逻辑，宿主强行 `MoveWindow` 会打架）；CLAP 规范反过来要求宿主**直接** resize 子窗口
  到客户区。所以要在 `IPluginInstance` 上开两个虚方法（默认空实现，不破坏既有实现）
  按格式分派：`onEditorResize`（WM_SIZE 回调）、`pollEditorSize`（定时器回调）。
- **插件的布局是异步的**（iZotope RX 系列典型）：`attached`/`set_parent` 之后真实尺寸
  要几十到几百毫秒才稳定，一次性同步会拿到中间态。用短命定时器 100ms × 6 = 600ms
  反复校正，tick 计数存 `GWLP_USERDATA2`，满次数自停；`WM_CLOSE` 也要 `KillTimer`
  （关窗走这条路径，不经过定时器自停）。
- 两个 Win32 细节：`GWLP_USERDATA2`（值 -5，Vista+）在部分 SDK 配置下不随
  `<windows.h>` 暴露（需 `WINVER >= 0x0600`），**手工 `#define` 补齐**而不是抬高全局
  `WINVER`——后者会改变整个翻译单元的 API 可见性，影响面大得多；
  VST3 侧 `onSize → 插件 resize → 容器 WM_SIZE → onSize` 会**回环**，用
  `m_lastViewW/H` 记住上次尺寸，没变就不重复下发。
- **自报尺寸要有合理性下限**（100×80）：低于此值视为"尚未布局完成"，不采信，
  否则会把容器缩成一个不可见的小方块。
- **反向验证手法（通用，值得复用）**：让探针支持 `AURADSP_DLL` 环境变量指定被测 DLL，
  用**未含本次修复的旧产物**跑同一套断言。C4 用它 3/3 FAIL 精确复现了用户报障
  （RX De-hum 容器 1136x897 而子窗口仍 560x540），新产物 3/3 PASS——
  这才能证明探针不是空跑，下次谁删掉 `WM_SIZE` 分支门禁会红。
- **尺寸类测试的目标值必须相对被测对象的当前值**（当前外框 ×2，上限取
  `SystemParametersInfoW(SPI_GETWORKAREA)` − 24px 防被系统 clamp）。用绝对常量
  （如固定 900×600）会踩坑：KV-Element-FX 自报 1230×730，初始就比目标大，
  "拉大"退化成"缩小"，断言误报 FAIL。
- **遗留 → C5**：`show_editor` 仍是同步调用，RX 169~568ms / KV 258~276ms /
  PatchWork 115ms，全耗在音频 isolate 事件循环上（568ms ≈ 跳过 100 多轮 5ms 泵）。
  C3 只异步化了 load/unload；"打开插件卡一下"很可能一半在 load、一半在这里，
  两者都要按 C3 同构模式异步化才算彻底。


- **P3a (2026-10-13)**: core/desktop/engine_api -> engine/, core/desktop/vendor-src -> vendor/ (git mv, R状态). 并行改动插件/host/crossfeed/arbmag请用新路径, 内容零改行可自动跟随.

## 10-19 → 10-24 精炼状态（2026-10-24 自 .workbuddy/memory 合并；详见各日期日志）

- **当前状态**：分支 `dev` 与 origin/dev 同步（Z13 三修 + Z14 于 419ce89 全部推送）。未决清单 A~R 全组关闭、实质清零；仅存 #94 多声道电平 = ADR-003 Phase B 工作量（2026-10-24 夜动工）。
- **Z13（079dbc7）**：compander 控制线程 `CompressorSetParam(forceRefresh=1)` 全量重置与 RT 消耗循环无互斥 → count 减成 -1 → `mOutputBuffer[-1]` 空写崩溃（minidump 实证）。修法 = kAuraStages comp lock=1 + `JamesDSPProcessMultiplexedStageSet` 两分支 honoring lock（此前 RT 唯一入口完全忽略该标志）+ `apply_comp` 控制侧同锁。门禁 `smoke_comp_race.py`。
- **Z14（419ce89）**：DDC 控制路径同型收口（set_ddc_enable/set_ddc_load + jamesdsp.c cmd 1212 的 DDCEnable/DDCDisable 补 jdsp_lock）。定界事实：ctrl_mutex 排除控制-控制竞争；ddcForceRefresh 无人置位（唯一调用方传 0）→ 危险刷新路径不可达；残余为形式数据竞争，修法结构性关闭。门禁 `smoke_ddc_race.py`（重锁竞争下零死锁 + 样本级生效）。
- **UI 三阶段重构收官**：P0（IndexedStack 保活 + hbTick 心跳 + RepaintBoundary + _notifyUi 合并）/ P1（settings 拆分 2509→父+6 part、设计系统迁 lib/ui、layering_guard）/ P2（aura.tokens.json→gen_theme.py→tokens.g.dart，parity 85 项；l10n 棘轮 218→0，三语 835+ key）。报告 `docs/30-审查/全天改动全面审查报告-2026-10-23.md`。
- **VB 桥按路插件 + Z12 超预算保护**：每 8 声道一组建独立引擎，插件按路勾选/旁路；保护激活时收窄到监听总线（vizStick），EMA<50%×6s 恢复，手动改掩码让位 + 60s 冷却。Dart 侧 vbAutoProtect 配置 + 设置页读数行。
- **E15 确定性流水深 v2**：深度 = ceil(回调帧/128)（1..16 自适应），传输延迟恒为 1 回调 = N×128；getLatencySlot 进程外槽改实时值。F-7 +2 块口径作废。
- **channelsMode 真值对齐（430849f）**：引擎仅 0=矩阵下混/1=离散逐声道；UI 原三档「立体声/5.1/7.1」选 7.1 恒被拒且镜像不回滚——已改两档真值 + 三语 hint + clamp。
- **部署核对铁律**：① DLL 导出用 ASCII `strings`（`-el` UTF-16 恒得 0）；② 一致性判源 mtime vs 构建时间，非 commit time；③ 本机 `flutter test` 全量并发 isolate 超时抖动（"did not complete" 逐轮漂移、单跑全过）= 环境性。
- **记忆目录裁定（2026-10-11，10-24 重申）**：唯一 AI 记忆目录 = `.ai/memory/`；`.workbuddy/memory/` 已再次合并并入本目录并移除。
