# source/ 参考项目审理报告

> 版本：**v2.6**（2026-10-24，新增 LiveprogIDE 参考仓，扩充 §1 / §2.9 / §3 / §4 / §5）
> 范围：`source/` 下全部 16 个第三方参考克隆的实测结构、源码完整性、磁盘占用、许可证与算法价值。
> 定位：只读参考区（.gitignore 排除，不入主库）；本报告为 M1 插件宿主 / Phase 5~8 / 算法对照（M5 细化）提供完整决策依据。

---

## 1. 资产总览（实测基线）

截至 2026-10-16，`source/` 下全部 15 个参考项目均已完成嵌套 `.git` 剥除，并在 `source/ORIGIN.md` 登记版本（`source/` 整体 gitignore，仅 `ORIGIN.md` 白名单入库；从参考仓提取进主库的第三方资产登记见 [`vendor/ORIGIN.md`](../../vendor/ORIGIN.md) 与 [`core/android/vendor-src/ORIGIN.md`](../../core/android/vendor-src/ORIGIN.md)）。最新实测占用与价值评估如下：

| # | 目录 | 对应上游仓库 | 平台 / 技术栈 | 许可证 | 实测体积 / 文件数 | 对 AuraDSP 的参考价值与对齐里程碑 |
|---|---|---|---|---|---|---|
| 1 | **JamesDSPManager** | `james34602/JamesDSPManager` (master@5aed6a4) | Android / 纯 C DSP 库 | GPL-3.0 | 21.14 MB (612 文件) | ★★★ **核心引擎真相源**（已提取整合至 `core/`，含 P-001/P-002 补丁） |
| 2 | **JDSP4Linux** | `Audio4Linux/JDSP4Linux` (master@3ea7d73) | Linux / PipeWire, Pulse, Qt | GPL-3.0 | 39.21 MB (1,291 文件) | ★★★ **Phase 7 Linux 形态蓝本**（filter-chain 模块化挂载与 D-Bus 通信） |
| 3 | **RootJamesDSP** | `ShadoV90/RootJamesDSP` (master@58e6b1b) | Android (Root / KSU / Magisk) | GPL-3.0 | 14.79 MB (991 文件) | ★★ **Root 路线历史对照**（已由本项目原生 AIDL HAL + KSU 模块超越） |
| 4 | **RootlessJamesDSP** | `timschneeb/RootlessJamesDSP` (master@60d25ae) | Android / AudioEffect 前台服务 | GPL-3.0 | 15.01 MB (1,010 文件) | ★★★ **Phase 6 Rootless 形态直接蓝本**（免 Root 动态会话捕获与前台保活） |
| 5 | **ViPER4Android-FX** | `Magisk-Modules-Repo/ViPER4Android-FX` (master@507b93e) | Android / Magisk, sepolicy | 无 OSS 许可（社区分发壳 + 官方二进制） | 3.32 MB (18 文件) | ★★ **系统集成与资产参考**（SELinux 策略范式、VDC 耳机校准格式、IRS 脉冲文件；实为官方 2.5.x 驱动 + DeWitt app 的社区分发壳，授权详见 §2.7） |
| 6 | **ViPERFX_RE** | `AndroidAudioMods/ViPERFX_RE` (rewrite-continued@eb65772) | Android / C++20, NDK, CMake | GPL-3.0 | 1.12 MB (119 文件) | ★★ **现代 C++ float32 DSP 架构先例**（纯浮点管线设计、动态处理算法参考） |
| 7 | **element** | `kushview/element` (main@7a415269) | Win/Linux/macOS / JUCE, C++ | Apache-2.0 | 6.88 MB (701 文件) | ★★★ **M1 插件宿主与 M6 节点连线图的头号参考**（多格式宿主 + 连线矩阵） |
| 8 | **equalizerAPO64** | `TheFireKahuna/equalizerAPO64` (main@7156020) | Windows / C++, AVX2/512, Qt6 | GPL-2.0 / LGPL | 90.34 MB (488 文件) | ★★★ **Phase 7b Windows APO 唯一工程蓝本**（系统端点注入、注册表挂载、AVX 加速） |
| 9 | **lsp-plugins** | `lsp-plugins/lsp-plugins` (master@2df6eea0) | 多平台 / C++, SIMD, 多格式 | LGPL-3.0+ | 559.99 MB (7,642 文件) | ★★★ **M5 算法对照 + 多格式构建中枢**（66 个子模块完整展开，包含 DSP 核心库） |
| 10 | **pulseeffects** | `mikhailnov/pulseeffects` (master@b9ec88ed) | Linux / C++, GStreamer, GTK3 | GPL-3.0 | 7.45 MB (436 文件) | ★★ **效果机架与预设架构参考**（EasyEffects 前身，预设 JSON 格式与多效果编排） |
| 11 | **clap** | `free-audio/clap` (main@a47f6ba, v1.2.10) | 跨平台 / C 头文件（ABI 标准） | MIT | 3.73 MB (101 文件) | ★★★ **M1 插件宿主 CLAP 正典上游**（引擎内置 `vendor/plugin-api/clap` 的来源，见 §2.5） |
| 12 | **ViPER4Windows** | `likelikeslike/ViPER4Windows` (main@ccc3f61, v2.0.1) | Windows / C++ APO + Flutter UI | 未见 LICENSE（Copyright ViPER520） | 3.14 MB (218 文件) | ★★★ **Windows 全局注入第二蓝本 + ViPER 效果系参数布局**（APO 挂载、共享内存参数投递、跨平台预设 v2 格式；引擎 submodule 已补齐，见 §2.6 与下行） |
| 13 | **ViPERDSP** | `likelikeslike/ViPERDSP` (main@6fc1f1b) | 跨平台 / C++17, CMake, pffft | **All Rights Reserved（仅限个人使用）** | 1.36 MB (123 文件) | ★★★ **ViPER 效果算法层**（23 个效果 + 21,278 行；VHE/DynamicSystem/FETCompressor 等蓝本；**仅供阅读参考，禁商用与代码搬运**，见 §2.6） |
| 14 | **tympan-apo** | `penta2himajin/tympan-apo` (main@e85f7a4) | Windows / Rust APO 框架 | MIT OR Apache-2.0 | 654 KB (61 文件) | ★★ **Windows APO 的 Rust 抽象与 COM 基础设施蓝本**（IUnknown/IClassFactory/IAudioProcessingObject/IAudioSystemEffects v1-v3，SFX/MFX/EFX；含 Win11 AEC APO 与 lock-free ring；含 CLAUDE.md 研发手记）。对照 sysapo/VAIO 模式研发 |
| 15 | **virtual-surround-sound** | `nnyj/virtual-surround-sound` (main@b67d037) | Windows / C++ APO 转发器 | GPL-3.0（**含 NIRSOFT SoundVolumeView.exe 专有工具，注意**） | 410 KB (31 文件) | ★★ **Windows APO RT 线程转发范式 + COM 聚合陷阱实录**（VB-Cable 7.1→HeSuVi binaural→WASAPI 物理设备，~10ms 延迟；lock-free SPSC ring + 注册表监听设备切换；docs/apo-forwarder-internals.md 记录 audiodg 聚合/端点 FX slot/LPAC ACE 等踩坑）。**GPL-3.0 但工具目录含第三方专有 exe，仅作阅读参考** |
| 16 | **LiveprogIDE** | `timschneeb/LiveprogIDE` (master@b2f3924) | 跨平台 / Qt6, C++ (QMake) | **未见 LICENSE（All Rights Reserved，默认保留所有权利）** | 12.0 MB (424 文件) | ★★ **Liveprog（EEL2）脚本 IDE / 编辑器 UX 参考**（Qt6 QCodeEditor 语法高亮 + Qt-Advanced-Docking-System 停靠布局；`src/definitions/demo.eel` 为样例脚本）。对齐引擎 `engine/legacy/` 的 liveprog(EEL2) 可编程级，可为 AuraDSP Liveprog 编辑页提供 UI 范式；**根无 LICENSE → 禁并入 GPL-3.0 主库，仅作阅读参考**。子依赖 `QCodeEditor`(MIT)、`3rdparty/docking-system`(LGPL-2.1) 已各自带许可、内容已展开并去嵌套 `.git` |

总计占用：**~780 MB**，约 **14,100** 个源文件与资源。

---

## 2. 重点项目深度审查

### 2.1 lsp-plugins（核心突破：66 个子模块全量到齐）

- **历史结论订正**：v1.0 报告曾判断其主仓为"元仓库、未见插件源码"。本次 v2.0 深度核查确认：**`modules/` 目录下 66 个子模块源码已全部展开就绪**（共计 220 MB 独立工程源码）。
- **模块拓扑与关键资产**：
  1. **DSP 核心算法库 (`modules/lsp-dsp-units/` & `lsp-dsp-lib/`)**：
     - `include/lsp-plug.in/dsp-units/filters/`：包含全套双二阶（Biquad）、状态变量滤波器（SVF）、复数均衡滤波单元。
     - `include/lsp-plug.in/dsp-units/dynamics/`：门限、压限、扩展、多频段动态处理单元。
     - `include/lsp-plug.in/dsp-units/sampling/`：高质量重采样与插值核（可直接对照我们 EQ 曲线的 Makima 轴注入与 FFT 重采样）。
  2. **专项算法插件 (`modules/lsp-plugins-*/`)**：
     - `lsp-plugins-loud-comp`：**等响度补偿（Loudness Compensator）** 工业级实现，完美对照 M5 细化中的响度感知算法。
     - `lsp-plugins-para-equalizer` 与 `graph-equalizer`：参数化 EQ 与图示 EQ，支持任意频段与精密 Q 值响应。
     - `lsp-plugins-crossover`：精确的分频器实现，对应我们 M5-a 分带展宽（Multiband stereowide）的分频基础。
     - `lsp-plugins-impulse-responses` & `impulse-reverb`：卷积混响与冲激响应处理，可作为 FileGate/卷积引擎的对照。
     - `lsp-plugins-spectrum-analyzer`：4096-FFT 频谱仪参考，直接对照 AuraDSP UI 侧的 30fps 实时频谱渲染。
  3. **插件框架与宿主胶水 (`modules/lsp-plugin-fw/`)**：
     - 抽象了一套跨 CLAP、LV2、VST2、VST3、JACK、PipeWire 的统一 C++ 骨架，是后续 M1/M6 插件宿主协议测试的极佳样例。
- **体积构成**：
  - `modules/` 源码树：220 MB。
  - `release/` 发布归档：339 MB（包含已解包的完整源码归档 `lsp-plugins-src-1.2.35.tar` 248 MB、`tar.gz` 78 MB、文档 `.7z` 28 MB）。
  - **建议**：`release/` 下的 `.tar` 和压缩包属于构建与离线备份产物，如需压缩目录空间，可随时安全删除 `release/` 下的重复 tar 包，保留 `modules/` 即可。

### 2.2 element（插件宿主与信号图架构标杆）

- **技术栈**：基于 JUCE 框架的现代模块化宿主。
- **参考价值**：
  - **M1 插件宿主**：完整实现了 VST3、CLAP、LV2、AU 的插件加载、生命周期管理、参数自动化与音频总线桥接。
  - **M6 信号图视图（Graph View / Patchbay）**：UI 包含完整的节点连接、多通道路由、引脚拖拽连线。这是 AuraDSP 后续由线性信号链演进为可自由编排有向无环图（DAG）的现成参考架构。
- **开源合规性**：Apache-2.0 许可证，代码模式与架构思路可自由借鉴吸收，对 AuraDSP 主体（GPL-3.0）完全兼容。

### 2.3 equalizerAPO64（Windows 系统全局注入底座）

- **技术栈**：C++20、Windows 驱动模型（sfx/mfx/efx）、AVX2/AVX-512 内联汇编指令优化。
- **参考价值**：
  - **Phase 7b Windows APO 落地**：详细展示了如何向 Windows 注册表注册 Audio Processing Object，如何挂接特定输出端点（GUID），以及处理高并发低时延 WASAPI/DirectSound 音频缓冲。
  - **双精度 64 位管线**：包含完整的参数配置文件解析器（`config.txt`）与高性能双精度 biquad 级联实现。
- **体积成因剖析**：
  - 实测 90.34 MB 中，约 **70 MB** 集中于 `Setup/lib32`、`lib64`、`libARM64` 目录下的 Qt6 预编译动态库（`Qt6Gui.dll`, `Qt6Widgets.dll`, `Qt6Core.dll` 等），用于其安装配置工具 `Configurator.exe`。源码本体极为精干。

### 2.4 pulseeffects vs lsp-plugins（关于 bass_enhancer 的重要澄清）

- **核实发现**：
  - `pulseeffects/src/bass_enhancer.cpp` 中通过 `gst_element_factory_make("calf-sourceforge-net-plugins-BassEnhancer", nullptr)` 实例化。因此 **pulseeffects 的低音增强算法实质为 Calf 插件**，其本身仅为 GStreamer/GSettings 胶水层。
  - 若 AuraDSP 在 M5 细化阶段需要对照底层的谐波合成（Harmonics Generation）与低音基频重建算法，应当对照 **Calf 原生源码** 或 **lsp-plugins-loud-comp / lsp-dsp-units**，而非参考 pulseeffects 的 wrapper。

### 2.5 clap（CLAP 标准正典上游）

- **背景**：AuraDSP 引擎的 CLAP 宿主（`engine/host/auradsp_plugin_host.cpp`，`#include <clap/clap.h>`，实现 `ClapPluginInstance`）此前依赖内置快照 `vendor/plugin-api/clap/`；该快照于 2026-10-10 自 `source/lsp-plugins/modules/lsp-3rd-party/include/clap/` 提取（`vendor/ORIGIN.md` 登记为 `clap-api`）。本次新克隆 `source/clap` 为其**正典上游**。
- **版本落差（重要）**：

  | | 正典上游 `source/clap` | 引擎内置 `vendor/plugin-api/clap` |
  |---|---|---|
  | 版本 | **1.2.10** | **1.2.6** |
  | 头文件数 | 68 | 60 |
  | 差异 | 多出 8 个 `ext/draft/*`：`background-activation/progress/state-context`、`flush-events`、`octave-number`、`param-hovered`、`params-origin`、`webview` | 严格子集（无独有文件） |

- **同步建议**：内置快照可从 `source/clap/include/clap/` 覆盖升级至 1.2.10。**已逐文件实测 ABI 安全性**：60 个公共头中 17 个有内容变化，均为注释/文档增补（`ext/params.h` 的 enum 位值 `IS_BYPASS=1<<4`…`IS_ENUM=1<<16` 与 `clap_param_info_t` 字段布局逐条核对**完全一致**，仅行号因注释增多而偏移；`plugin.h`/`host.h`/`factory/plugin-factory.h` 0 处非注释差异），外加 8 个新增 `ext/draft/*` 头与版本号——**无任何结构/ABI 变更**。升级后更新 `vendor/ORIGIN.md` 的 `clap-api` 提取来源（lsp-plugins → source/clap）与版本号即可。**升级属引擎构建输入变更，须重编 + 冒烟验证**（草案扩展仅经 `clap/all.h` 引入，引擎目前用 `clap/clap.h`，风险极低）。
- **许可**：MIT，与 AuraDSP 主项目 GPL-3.0 完全兼容；引擎宿主亦可对照 `source/element` 的 CLAP 实现。

### 2.6 ViPER4Windows + ViPERDSP（Windows 全局注入第二蓝本；引擎层 All Rights Reserved）

- **项目性质订正**：本仓为 `likelikeslike` 的**现代重写版 v2.0.1**（版本号 260818），与原版 ViPER4Windows 的驱动注入方案不同——改以标准 **Windows APO（MFX）** 挂载系统音频管线，配 Fluent 风格 Flutter UI。README 署名致敬 ViPER4Android（Zhuhang / ViPER520）与 ViPERDSP 逆向（Martmists / Iscle / likelikeslike）。
- **源码完整性（v2.3 已补齐）**：v2.2 时 `ViPERDSP/` 为未初始化 submodule 占位空目录（指针 `db1c11c`）；本次已克隆补齐（`likelikeslike/ViPERDSP` main@6fc1f1b，123 文件 / 1.36 MB，嵌套 `.git` 已剥除）。**版本差注意**：ViPER4Windows 钉住 `db1c11c`，本克隆为其后继 main（含 `a25d50e` "Replace TubeSimulator with QuadricTube" 等变更），与宿主 APO 层的接口兼容性以构建实测为准。APO 层通过 `#include "viper/ViPER.h"` 与 `"include/ViPERParams.h"` 消费该引擎接口。
- **引擎层实测结构（21,278 行 C/C++，C++17 + CMake + pffft）**：
  1. `include/{ViPERParams.h, log.h}`：全效果参数结构体（与 Flutter 侧 `viper_params_layout.dart` 经 `tools/viper_layout_gen.py` 代码生成配对）。
  2. `viper/ViPER.cpp`（1,564 行）：效果编排与分发入口（`DispatchParamValue` 全参数下发）。
  3. `viper/effects/` **23 个效果模块**：ViPERBass / ViPERBassMono / ViPERClarity / ColorfulMusic（清晰度系）、TubeSimulator / AnalogX、SpectrumExtend（VSE）、DiffSurround / DepthSurround / Stereo3DSurround / StereoImager / VHE（含 L0–L4 系数表）、DynamicSystem、Cure（CURe crossfeed）、Reverberation / Convolver、DynamicEQ / IIRFilter、FETCompressor / MultibandCompressor / PlaybackGain / LUFSTargeting / SoftwareLimiter、PsychoacousticBass、SpeakerCorrection、ViPERDDC。
  4. `viper/utils/` **~35 个基础组件**：pffft（FFT）、Biquad / IIR_1st / IIR_NOrder_* 滤波器族、CRevModel / CCombFilter / CAllPassFilter（混响组件）、PConvSingle（分区卷积）、Polyphase（重采样）、Harmonic / DynamicBass（低音增强）、Crossfeed、QuadricTube（新电子管模型）、TimeConstDelay、WaveBuffer 等。
- **授权红线（显式 All Rights Reserved，比 v2.2 判断更严重）**：引擎 README 明确声明——逆向代码，原 IP 归 Zhuhang / ViPER520；上游项目无许可证，按 **All Rights Reserved** 处理，**仅限个人使用、禁止任何商用**。AuraDSP 为 GPL-3.0 分发项目：**该库代码一律不得并入**，仅可作算法思路的阅读参考；若未来落地 ViPER 系效果，须自研重写或取得明确授权（全谱系授权地图见 §2.7）。
- **对 AuraDSP 的算法对照价值（纯参考，禁搬运）**：VHE / DynamicSystem（头戴虚拟化，对照 haas + crossfeed）、PsychoacousticBass + Harmonic（对照 psycho 模块）、FETCompressor / MultibandCompressor（对照 vendor comp）、SpeakerCorrection / SpectrumExtend（对照 shelf / filter）、Convolver + PConvSingle（对照 convolver 节点）。
- **快照内实测结构（218 文件 / 3.14 MB，含 ViPERDSP）**：
  1. **APO 层 `ViPER4WindowsAPO/`（C++，约 1,150 行）**：`CRegAPOProperties` 注册 MFX APO（INPLACE + 采样/帧率/位深必须匹配）；`FinalConstruct` 创建 `ViPER` 引擎实例并打开共享内存；**RT-Safe 参数投递范式**——`StartParamWatch()` 监听参数变更，`staged_params_` / `consumed_params_` 两个 `std::atomic` 指针构成双缓冲（写侧暂存、音频线程取用后交换删除），配合 avrt 多媒体类调度；`ViPERLog.h` 提供调试日志。
  2. **Flutter UI `ViPER4Windows/`**：`lib/pages/` 八页面（output / equalizer / tone / spatial / dynamics / devices / preset / driver）；`lib/services/` 含 `shared_memory_service.dart`、`control_pipe_server.dart`、`apo_registration_service.dart`（端点注册）、`profile_file_manager.dart`（按设备持久化）；`lib/models/viper_params_layout.dart` 为**效果参数布局蓝本**（可对照 AuraDSP 的 `engine_internal.h` Params 结构与链视图）。
  3. **安装与工具**：`Installer/ViPER4Windows.iss`（Inno Setup，含 APO 注册/还原与 `DisableProtectedAudioDG` 处理）；`tools/convert_preset.py`（预设转换）。
- **对 AuraDSP 的参考价值**：
  - **Phase 7b Windows 全局注入的第二实现路径**：与 `equalizerAPO64`（GPL、重配置工具链）互为对照——本仓展示轻量 APO 注册 + 共享内存投递的最小闭环。
  - **RT-Safe 参数热更新**：双缓冲 + 原子指针范式可直接对照本项目 P-004 表驱动链的参数下发路径。
  - **跨平台预设格式 v2（grouped JSON）**：与 ViPER4Android / ViPER4Mac 互通，可为 AuraDSP 预设导入导出提供格式参照。
  - **按设备 profile 自动切换**：endpoint ID 为键、form factor 判耳机/音箱，对照本项目多设备形态适配。
- **许可风险提示**：仓库**无 LICENSE 文件**（仅 Inter 字体 MIT 许可），APO 注册信息标注 `Copyright ViPER520`。作为参考阅读无碍；**任何代码搬运前必须先与上游确权**。

### 2.7 ViPER 蝰蛇音效全谱系与合规地图（v2.4 新增，2026-10-14 联网考证）

**背景**：GitHub 及其它渠道 ViPER 相关仓库众多，真伪、版本与授权状态混乱（中文站点充斥「正版/免ROOT/2026 最新版」打包 APK）。本节一次性厘清来龙去脉与合规条款；结论均有出处（XDA、百度百科、36 氪、GitHub 官方 org 实测）。

**正主与官方遗产**：
- ViPER's Audio 由 **ViPER520（王宇飞 / Euphy Wong）**创立（版权线 `Copyright (C) 2006-2016 vipercn.com / vipersaudio.com`），**zhuhang（Jasper Loo）**为联合创始人，2013 年经其登陆 XDA 走向全球；全球累计安装量约 4,000 万（36 氪，2016）。
- **官方 GitHub org `vipersaudio` 仍然在线**（2026-10-14 实测）：`viper4android_fx`（app 源码，266★/123 forks，末次活动 2016-02）、`viper4android_xhifi`、`viperfx_core_binary`（驱动二进制仓）、`gst-plugin-viperfx`；已入 GitHub Arctic Code Vault 归档。
- **官方条款**：app 源码公开但仓库**无 OSS 许可证**（GitHub 默认 All Rights Reserved）；驱动 `libv4a_*.so` 的 README 明写 **"restrict disallowed in commercial use"（严禁商用）**；百度百科记「授权：免费」——**免费 ≠ 开源，更 ≠ 可商用**。
- 官方维护止于 **V4A 2.5.0.5（2018）**；XHiFi 线 2013 年停更、功能并入 FX。

**三条谱系与授权条款**：

| 谱系 | 代表仓库 / 产品 | 代码可见性 | 授权状态 | 对 AuraDSP 的意义 |
|---|---|---|---|---|
| 官方二进制系 | `vipersaudio` org；V4A 2.5.0.5 驱动 | app 源码公开 / 驱动二进制 | 无 OSS 许可；**驱动严禁商用** | 个人使用灰色地带；**不可并入、不可商用** |
| 社区分发壳 | Magisk-Modules-Repo/ViPER4Android-FX（本报告 #5）；Team_DeWitt app（pittvandewitt/MrWhite214，包名 `com.pittvandewitt.viperfx`，Kotlin 重写、APK 闭源、AndroidAudioMods 发 release） | 壳源码 + 官方二进制 | 随官方条款 | 挂载结构参考；驱动同样禁商用 |
| 逆向重写系 | AndroidAudioMods/ViPERFX_RE（#6，GPL-3.0）→ likelikeslike/ViPERDSP（#13，ARR）→ likelikeslike/ViPER4Windows（#12，无 LICENSE） | 全源码 | FX_RE 挂 GPL-3.0 但**派生自 ARR 代码，授权有效性存疑（灰区）**；两个衍生仓显式 ARR | **只读参考**。许可证兼容 ≠ 安全：原权利人仍可主张 ARR 派生权利，勿被 GPL 字样误导 |

**唯一合规商用路径（商业授权系）**：36 氪实证——王宇飞创立的**听觉工坊**自 2014 年起向**酷狗**提供蝰蛇音效（3D丽音 / HiFi现场 / 超重低音 / 纯净人声），现运营为**酷狗蝰蛇声学实验室**（15 万款音效、5.5 亿用户、蝰蛇声学认证；硬件合作方含华为音频 / OPPO / vivo / 小米 / LHDC / 理想 / 蔚来）；听觉工坊另有 ViPER-MX USB 声卡硬件（6→2 声道下混）。**若 AuraDSP 未来要商品化 ViPER 系效果，唯一正途是向该体系取得授权，而非使用 GitHub 代码。**

**假蝰蛇鉴定法**：中文站点泛滥的「VIPER 正版 / 免ROOT版 / 2026 最新版」基本为改装 pittvandewitt APK 塞广告或假应用。三判据：① 包名是否为 `com.pittvandewitt.viperfx`；② 驱动版本是否为官方 2.5.0.x 系；③ 是否捆绑广告 / 索取无关权限。真正的官方遗产只在 `vipersaudio` org 与酷狗体系内。

**结论**：维持 v2.3 裁定——ViPERDSP / ViPERFX_RE / ViPER4Windows 三仓仅供阅读参考，代码零搬运；ViPER 系效果落地一律自研重写。

### 2.8 tympan-apo 与 virtual-surround-sound（Windows APO 参考矩阵补强，2026-10-16 新增）

**共性定位**：二者均为 Windows Audio Processing Object（APO）生态的第三方参考，与本项目 Phase 7b 的 Windows 系统级音频注入路线（sysapo / VAIO 模式）同源异构——至此 `source/` 的 Windows APO 蓝本从"两个 C++ 工程"扩展为"Rust 抽象 + C++ 转发范式 + C++ 全功能工程（equalizerAPO64）+ C++ APO+Flutter（ViPER4Windows）"的四维对照，覆盖 COM 基础设施、RT 线程转发、注册表/INF 自动化到 audiodg 实战陷阱的完整知识链。**二者均仅作阅读参考、禁代码搬运**（理由见各自许可研判）。

**tympan-apo（Rust APO 框架，`MIT OR Apache-2.0`）**
- **已实现范围**（`docs/overview.md` 全部 In scope 项已落地）：
  - COM 基础设施：`src/raw/` 实现 IUnknown、IClassFactory、注册与四个 `Dll*` 导出；
  - 接口集：`IAudioProcessingObject` 家族 + `IAudioSystemEffects` v1/v2/v3，覆盖 SFX/MFX/EFX 三类；
  - AEC APO 支持（`src/aec/`，受 `aec` feature 门控）：`AecProcessingObject` 基础、`AecApoInstanceCom` + `register_aec_apo!` COM 桥、`aec_scaffold` 示例——直接对接 Win11 麦克风采集管线的官方声学回声消除槽位；
  - 格式协商（`src/format.rs`）：`WAVEFORMATEX` 与 `WAVEFORMATEXTENSIBLE`；
  - RT-Safe 原语（`src/realtime/`）：lock-free ring buffer、atomic state、atomic refcount；
  - 注册辅助（`src/clsid.rs` / `src/raw/register.rs` / `src/inf.rs` / `src/fx_properties.rs`）：CLSID 分配、注册表写入、INF 生成器、FxProperties 端点绑定；
  - 示例 APO（`examples/`）：`passthrough` / `gain` / `aec_scaffold`。
- **结构资产**：`src/{raw,aec,realtime,format.rs,clsid.rs,inf.rs,fx_properties.rs}`、`examples/`、`docs/{architecture,handoff-protocol,overview,references,testing}.md`、`tests/`、`CLAUDE.md`（含研发手记，对 AI 协作友好）。
- **许可研判**：`MIT OR Apache-2.0` 双许可，与 AuraDSP GPL-3.0 主体不冲突——架构思路可自由借鉴；若未来要并入代码，须保留原许可声明（Apache-2.0 含专利授权条款，须一并保留 `LICENSE-APACHE`）。
- **对 AuraDSP 价值**：本项目 Windows APO 路线此前只有 equalizerAPO64（C++/AVX）与 ViPER4Windows（C++ APO）两个 C++ 蓝本；tympan-apo 提供**另一种语言范式的 COM 抽象参考**——尤其 `IAudioSystemEffects v3`、AEC 槽位、`IAudioProcessingObject` 生命周期、RT-Safe 原语与 INF/注册表自动化生成，对评估"用 Rust 重写 APO 层"或理解 APO COM 契约有较高研读价值。注意它**不提供 DSP 算法**，只提供"接入 Windows 音频引擎"的骨架。

**virtual-surround-sound（C++ APO 转发器，`GPL-3.0`，含 NIRSOFT 专有 exe）**
- **定位**：自定义 APO，把 VB-Cable 虚拟 7.1 端点变成耳机环绕栈——app 播到 cable，HeSuVi（Equalizer APO）卷积 7.1→双耳，`vss_apo.dll` 在音频引擎内把结果转发到任意物理输出；设备切换实时、无需重启音频。
- **技术要点**（README + `docs/apo-forwarder-internals.md`）：
  - Inline APO 转发，~10ms 附加延迟，运行于 Windows Audio Engine 的 RT 线程；
  - lock-free SPSC ring buffer 桥接 DSP 线程与专用 WASAPI 渲染线程；
  - 实时输出设备切换（`RegNotifyChangeKeyValue` 监听 `HKLM\SOFTWARE\VirtualSurroundSound\TargetDeviceId`），无需音频重启；
  - `IAudioClient3` 低延迟路径（可用时），20ms 共享模式回退；
  - 音量 OSD（AutoHotkey）+ 任务计划程序自动路由设备插拔。
- **架构与 audiodg 踩坑实录**（`docs/apo-forwarder-internals.md`，**极高价值**）：
  - 数据流：`apps(7.1)→CABLE Input(默认设备)→EAPO SFX(预混)→EAPO MFX(HeSuVi 7.1→双耳)→vss forwarder MFX→物理设备(WASAPI)`；
  - COM 聚合规则：`audiodg` 聚合 APO，`IClassFactory::CreateInstance` 收到非空 outer unknown；缺聚合支持会静默放弃 APO，端点 FX 图失败，`IAudioClient::Initialize` 返回 `E_NOTIMPL`；
  - 端点 FX slot 规则（Win11 24H2 / VB-Cable Pack45）：经典 slot 5=SFX/6=MFX/7=EFX，MFX 单独注册被忽略需 SFX 填充；composite slot `,13`(SFX)/`,14`(MFX) 为 MULTI_SZ 多 APO 列表；FxProperties ACL 拒绝管理员 `KEY_WRITE`；
  - LPAC 权限：`audiodg` 以 LPAC 运行，配置键需对 `S-1-15-2-1` / `S-1-15-2-2` 开放读 ACE，否则 APO 静默读失败；
  - 调试陷阱：坏 APO 导致端点流打开失败、播放器静默回退其他设备（"能出声"不证明被测端点正常）；dbg 走 `OutputDebugString`，需 DebugView 捕获。
- **结构资产**：`apo/src/{vss_apo.cpp, vss_apo.def}`（核心转发器，单文件最小 APO 实现，便于理解 APO DLL 导出契约）、`docs/{apo-forwarder-internals,sonar-apo-internals}.md`、`scripts/`、`tasks/`、`debug/`（含 `set_71_policy.ps1` / `wasapi_tone.ps1`）、`tools/`（`SoundVolumeView.exe` 专有工具）。
- **许可研判（重点）**：`LICENSE` 确认为 **GNU GPL v3**——vss 自身 C++ 源码（apo/src、docs）是真正的 OSS；**但 `tools/` 下的 `SoundVolumeView.exe` 为 NIRSOFT 专有闭源免费工具，不在 GPL 覆盖范围内**。合规操作：① vss 源码按 GPL-3.0 阅读参考；② `tools/` 第三方 exe **绝不可并入主库或重新分发**，仅作本地辅助；③ 与 ViPERDSP（ARR，禁商用）不同，vss 是合法 OSS，但本项目 Phase 7b 已有 equalizerAPO64（GPL-2.0/LGPL，同源兼容）作为工程主蓝本，vss 补强的是"APO 在 RT 线程内转发 + 设备热切换"这一窄而深的范式与其详尽的 audiodg 陷阱清单。
- **对 AuraDSP 价值**：若 Windows APO 路线需"在音频引擎 RT 线程内做轻量转发/镜像到其他端点"或"按设备热切换 sink"，vss 的 **SPSC ring + 注册表监听范式**与 `apo-forwarder-internals.md` 的 audiodg 陷阱清单是极高价值的实战参考；其单文件 APO 实现也便于快速掌握 APO DLL 的最小导出契约（`DllGetClassObject` / `DllRegisterServer` 等）。

**两仓合论**：tympan-apo（Rust 抽象，可自由借鉴架构）与 virtual-surround-sound（C++ 转发范式 + 详尽 audiodg 踩坑，GPL-3.0 但含专有 exe 须剔除）共同把 Windows APO 参考矩阵补全为"基础设施→转发范式→全功能工程→UI 宿主"的完整链条；二者维持与既有 APO 蓝本一致的**只读参考、禁搬运**定位。

---


### 2.9 LiveprogIDE（EEL2 / Liveprog 脚本 IDE，2026-10-24 新增）

- **背景**：由 `timschneeb`（RootlessJamesDSP 同主）维护的**嵌入式 Liveprog IDE**，README 自述 "Basic embeddable Liveprog IDE, currently supports EELang2 (JamesDSP for Linux)"；设计为 QMake `subdirs` 工程的插件，可通过 `COMPILE_STANDALONE` 编译独立 dummy 应用。
- **技术栈**：Qt6（QMake 构建，`EELEditor.pro` / `src/src.pro`）+ `QCodeEditor`（Qt 代码编辑器，MIT，仓库内双份：`QCodeEditor/` 根级与 `3rdparty/QCodeEditor/`，均带 `LICENSE.MIT`）+ `Qt-Advanced-Docking-System`（停靠布局，LGPL-2.1，经 `.gitmodules` 声明的子模块，内容已展开并去嵌套 `.git`）。
- **实测结构（424 文件 / 12.0 MB，不含 .git）**：`src/` 含 `eeleditor.{cpp,h,ui}`（主编辑器窗口）、`model/`（EEL 符号/文档模型）、`widgets/`、`utils/`、`definitions/demo.eel`（样例 Liveprog 脚本）、`fonts/`、`icons/`、`editorresources.qrc`；`3rdparty/docking-system/`（停靠系统，含 `src/`、`PyQtAds/`、`sip/`、`examples/`、文档）；根级 `screenshot.png`（编辑器截图）、`EELEditor.pro.user`（QtCreator 用户配置，本地产物）。
- **许可研判（重点）**：**仓库根目录无任何 LICENSE 文件** → 按 GitHub 默认 **All Rights Reserved** 处理（保留所有权利）。子依赖 `QCodeEditor`(MIT)、`Qt-Advanced-Docking-System`(LGPL-2.1) 各自带许可、可自由借鉴其架构；但 **LiveprogIDE 本体代码（EEL 编辑器 UI/逻辑）一律不得并入 GPL-3.0 分发的 AuraDSP 主库**，仅作 Liveprog 脚本编辑器 UX 与 EEL2 语法的阅读参考。
- **对 AuraDSP 价值**：本项目引擎 `engine/legacy/` 已实现 liveprog（EEL2 可编程）级；`app/` 侧 Liveprog 编辑页若需构建/升级脚本编辑器，本仓提供现成的 Qt EEL2 语法高亮 + 停靠式多文档 IDE 范式（UI 布局、符号模型、示例脚本组织方式）。**仅作阅读参考、禁代码搬运**（理由见许可研判）。

## 3. 算法与系统能力对照矩阵

| 功能 / 算法需求 | AuraDSP 当前状态 | `source/` 中最佳参考仓库 | 具体参考源码路径 / 说明 |
|---|---|---|---|
| **核心 DSP 引擎** | libjamesdsp (vendor + P-001/P-002) | `JamesDSPManager` | `Main/libjamesdsp`（纯 C 引擎真相源） |
| **低频搁架（Low Shelf）** | wrapper 自研 RBJ Biquad (<0.03% 误差) | `lsp-plugins` | `modules/lsp-dsp-units/include/lsp-plug.in/dsp-units/filters/biquad.h` |
| **参数化混响** | wrapper 自研 Freeverb | `pulseeffects` / `lsp-plugins` | Freeverb / Schroeder 算法拓扑及早期反射参量 |
| **响度感知 / 动态扩展** | 待开发（M5 细化） | `lsp-plugins` | `modules/lsp-plugins-loud-comp/src/main/`（工业级等响度曲线与自适应滤波） |
| **多频段分带展宽** | P-002 补丁导出 vendor stereowide | `lsp-plugins` | `modules/lsp-plugins-crossover/`（Linkwitz-Riley 4阶分频网络参考） |
| **卷积与 IR 管理** | FileGate 六道门卫 + convolver 节点 | `equalizerAPO64` / `lsp-plugins` | `lsp-plugins-impulse-responses/`（高吞吐卷积与 IR 预处理机制） |
| **插件宿主 (VST3/CLAP)** | M1 引擎已实现进程内宿主（`engine/host/auradsp_plugin_host.cpp`，四插槽） | `clap`（协议正典）/ `element`（架构） | `source/clap/include/clap/`（CLAP C ABI 正典头）；`element/src/engine/`（跨平台宿主扫描、隔离与总线调度） |
| **信号链重排序 / 节点图** | M3-a 线性展示 / M3.5 待 ADR | `element` / `pulseeffects` | `element` 的 Graph 连线拓扑；`pulseeffects` 的 pipeline 动态重编排 |
| **Windows 全局音频** | 当前为进程内 WASAPI pump | `equalizerAPO64` / `ViPER4Windows` | `EqualizerAPO/`（APO 注册表服务、驱动挂载与端点拦截）；`ViPER4WindowsAPO/ViPER4WindowsAPO.cpp`（MFX APO 注册 + 共享内存参数投递的最小闭环） |
| **RT-Safe 参数热更新** | P-004 表驱动链参数下发 | `ViPER4Windows` | `staged/consumed_params_` 原子双缓冲 + `StartParamWatch()`（对照音频线程零分配约束） |
| **跨平台预设格式** | 自研 JSON 预设 | `ViPER4Windows` | `lib/models/` + `tools/convert_preset.py`（v2 grouped-JSON，与 ViPER4Android/Mac 互通） |
| **ViPER 系效果算法** | 部分自研（haas / psycho / crossfeed / comp） | `ViPERDSP`（仅阅读参考） | `viper/effects/{VHE,DynamicSystem,PsychoacousticBass,FETCompressor,SpectrumExtend}.cpp`（**All Rights Reserved，禁搬运**；全谱系授权地图见 §2.7） |
| **Linux 全局音频** | Phase 7 规划中 | `JDSP4Linux` / `pulseeffects` | `JDSP4Linux/src/pipewire/`（PipeWire filter-chain 与 SPA 模块） |
| **Android 免 Root 引擎** | Phase 6 规划中 | `RootlessJamesDSP` | `app/src/main/java/.../AudioCaptureService.kt`（无 Root 前台服务捕获） |
| **Windows APO COM 抽象 / 生命周期（Rust 范式）** | Phase 7b Windows APO 路线（sysapo/VAIO） | `tympan-apo`（新增 #14） | `src/raw/`（IUnknown/IClassFactory/Dll* 导出）、`src/clsid.rs`/`src/inf.rs`/`src/fx_properties.rs`（CLSID/INF/FxProperties 注册）、`src/realtime/`（lock-free ring）；对照 equalizerAPO64/ViPER4Windows 的 C++ APO 实现，提供另一种语言范式的 COM 契约参考 |
| **Windows APO RT 线程转发 + 设备热切换** | 当前为进程内 WASAPI pump | `virtual-surround-sound`（新增 #15） | `apo/src/vss_apo.cpp`（单文件最小 APO DLL）+ `docs/apo-forwarder-internals.md`（audiodg 聚合/端点 FX slot/LPAC ACE 踩坑实录）；lock-free SPSC ring 桥接 DSP 与 WASAPI 渲染线程，注册表监听实时切换 sink |
| **Liveprog（EEL2）脚本编辑器 / IDE** | app/ Liveprog 编辑页（规划/待强化） | `LiveprogIDE`（新增 #16） | `src/eeleditor.{cpp,h,ui}`（Qt6 EEL2 语法高亮 + 停靠式多文档 IDE）+ `src/definitions/demo.eel`（样例脚本）；对齐引擎 `engine/legacy/` 的 liveprog 可编程级；**根无 LICENSE（ARR），仅阅读参考、禁搬运** |

---

## 4. 磁盘与工程合规性审计

1. **嵌套 `.git` 审查**：
   - 全面递归扫描确认：`source/` 下所有目录及子目录均 **无任何 `.git` 目录残留**，彻底规避子模块递归嵌套与意外提交问题。
   - **v2.5 更新（2026-10-16）**：本轮新增的 `tympan-apo/`、`virtual-surround-sound/` 两个克隆在登记前已剥除各自的嵌套 `.git`（原各约 340–430 KB）；剥除后递归复核 `source/` 下 `.git` 数量为 **0**，铁律持续有效。
   - **v2.6 更新（2026-10-24）**：新增 `LiveprogIDE/` 克隆（master@b2f3924）在登记前已剥除嵌套 `.git`（约 9.8 MB）；剥除后递归复核仍为 **0**，铁律持续有效。
2. **构建缓存审计**：
   - `source/RootJamesDSP/` 与 `source/RootlessJamesDSP/` 下存在由构建/导入自动生成的 `.gradle/` 目录。该目录仅为本地临时索引，建议后续可选择性清理或保留在本地。
3. **大文件与二进制包审计**：
   - `equalizerAPO64/Setup/lib*`：存在约 70MB 的 Qt6 预编译 DLL，只读保留无需改动。
   - `lsp-plugins/release/`：存在解包与打包的 tar 归档（约 339MB），主工程源码已在 `modules/` 完整展开。
   - **v2.5 新增告警**：`virtual-surround-sound/tools/SoundVolumeView.exe` 为 **NIRSOFT 专有闭源免费工具**（非 GPL 覆盖），属第三方二进制，**不得并入主库、不得随参考区重新分发**；仅作本地辅助用途，与参考区"只读快照"铁律一并遵守。

---

## 5. 问题清单最新结论（全部闭环）

| # | 状态 | 涉及项 | 结论与说明 |
|---|---|---|---|
| **P-1** | ✅ 已闭环 | 嵌套 `.git` 剥离 | 12 个项目已统一剥除 `.git`，版本与 commit 完整登记于 `source/ORIGIN.md`。 |
| **P-2** | ✅ 已闭环 | RootJamesDSP README 疑云 | 确认 ShadoV90/RootJamesDSP 为上游 fork，其 root 模式通过 `BUILD_ROOT.md` 与脚本体现，克隆源准确无误。 |
| **P-3** | ✅ 已闭环 | 大体积仓库审计 | 体积主要由 `lsp-plugins`（全量 66 模块 + release 归档）与 `equalizerAPO64`（Qt6 DLL）构成。代码结构完整，不影响主仓库性能（已 `.gitignore`）。 |
| **P-4** | ✅ 已闭环 | element 上游文件 | 上游 `CLAUDE.md` 为只读参考，已备案无害。 |
| **P-5** | ✅ 已闭环 | lsp-plugins 源码定位 | **已彻底澄清并闭环**：`modules/` 下 66 个子模块源码完整在盘，无需额外克隆单个插件仓。 |
| **P-6** | ✅ 新增闭环 | bass_enhancer 溯源 | 确认 pulseeffects 底层为 Calf 插件；算法对照锁定为 `lsp-plugins-loud-comp` 与 `lsp-dsp-units`。 |
| **P-7** | ✅ 新增闭环 | CLAP 正典上游与内置快照落差 | 新克隆 `source/clap` 为正典上游 v1.2.10；内置快照 `vendor/plugin-api/clap` 为 1.2.6（落后 8 个 draft 头），可按 §2.5 建议升级。 |
| **P-8** | ✅ 已闭环 | ViPER4Windows 引擎源码缺失 | 已克隆补齐 `likelikeslike/ViPERDSP` main@6fc1f1b（123 文件 / 1.36 MB，.git 已剥除并登记），23 个效果模块到齐；注意其为 ViPER4Windows 钉住指针 db1c11c 的后继版本。引擎为 **All Rights Reserved 仅限个人使用**，仅作阅读参考、禁并入 AuraDSP；谱系与合规全景见 §2.7。 |
| **P-9** | ✅ 已闭环 | 新增两个 Windows APO 参考仓（tympan-apo / virtual-surround-sound） | 2026-10-16 用户克隆至 `source/`；二者嵌套 `.git` 已剥除（递归复核 `source/` 下 `.git` 数量 = 0），HEAD 分别锁定 `e85f7a4` / `b67d037`，已于 `source/ORIGIN.md` 追加 #14 / #15 登记、本报告升版 v2.5（§1 扩至 15 项、新增 §2.8、§3 补充两行、§4 审计更新）。许可研判：tympan-apo 双许可（`MIT OR Apache-2.0`，可自由借鉴架构、并入须保留声明）；virtual-surround-sound 为 GPL-3.0 但 `tools/` 含 NIRSOFT 专有 `SoundVolumeView.exe`，**该 exe 禁并入/重分发**，源码仅作阅读参考。二者维持只读参考、禁搬运定位。 |
| **P-10** | ✅ 已闭环 | 新增 LiveprogIDE 参考仓（timschneeb/LiveprogIDE，master@b2f3924） | 2026-10-24 克隆至 `source/`；嵌套 `.git` 已剥除（递归复核 `source/` 下 `.git` 数量 = 0），HEAD 锁定 `b2f3924`，已于 `source/ORIGIN.md` 追加 #16 登记、本报告升版 v2.6（§1 扩至 16 项、新增 §2.9、§3 补充一行、§4 审计更新）。许可研判：根目录**无 LICENSE 文件** → 按 **All Rights Reserved** 处理（timschneeb 作者，与 RootlessJamesDSP 同主；子依赖 QCodeEditor MIT / docking-system LGPL-2.1 各自带许可）。**根无 LICENSE → 代码禁并入 GPL-3.0 主库，仅作 EEL2/Liveprog 脚本编辑器 UX 的阅读参考**（对齐引擎 `engine/legacy/` 的 liveprog 可编程级），维持只读、禁搬运定位。 |

---

## 6. 后续行动建议

1. **M1 插件宿主推进**：在 D1（GPLv3）决策明确后，直接以 `source/element` 作为 VST3/CLAP 进程内宿主的架构蓝本。
2. **M5 算法精细化**：全面挖掘 `source/lsp-plugins/modules/lsp-dsp-units` 与 `lsp-plugins-loud-comp`，用于自研等响度与高阶滤波器的对比验证。
3. **磁盘轻量化（可选）**：如需节约约 300MB 空间，可清空 `source/lsp-plugins/release/` 下的离线归档包，因 `modules/` 源码已足够自洽。
4. **CLAP 快照升级（可执行）**：将 `vendor/plugin-api/clap` 自 1.2.6 覆盖升级至 `source/clap` 的 1.2.10，同步更新 `vendor/ORIGIN.md` 的 `clap-api` 溯源（提取路径改为 `source/clap/include/clap/`）；升级后重编引擎并跑冒烟测试。
5. **ViPER4Windows / ViPERDSP 后续**：APO 层与 `viper_params_layout.dart` 可作为 Phase 7b 蓝本阅读；ViPERDSP 为 All Rights Reserved（仅限个人使用），**代码不得并入 GPL 分发**——若需落地 ViPER 系效果（VHE / 动态系统 / 心理声学低音等），按 §2.6 算法对照清单自研重写；若要走商品化，唯一正途是向听觉工坊 / 酷狗蝰蛇声学体系取得授权（§2.7）。
6. **Windows APO 路线四维对照（tympan-apo / virtual-surround-sound / equalizerAPO64 / ViPER4Windows）**：Phase 7b 立项时，以 `equalizerAPO64` 为工程主蓝本、`ViPER4Windows` 为轻量闭环对照；`tympan-apo` 用于评估"Rust 重写 APO 层"可行性与 `IAudioSystemEffects v3` / AEC 槽位契约；`virtual-surround-sound` 的 `apo-forwarder-internals.md` 与 SPSC ring 范式作为"RT 线程内转发 + 设备热切换"的实战参考。所有参考维持只读、禁搬运（§2.8）。
7. **virtual-surround-sound 专有二进制隔离**：将 `tools/SoundVolumeView.exe`（NIRSOFT 专有闭源）纳入本地不入库清单，避免随参考区误提交或分发；该工具仅用于本地端点调试，不参与 AuraDSP 任何构建或分发。

