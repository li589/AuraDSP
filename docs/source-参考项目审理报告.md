# source/ 参考项目审理报告

> 版本：**v2.0 全面复审版**（2026-10-10）
> 范围：`source/` 下全部 10 个第三方参考克隆的实测结构、源码完整性、磁盘占用、许可证与算法价值。
> 定位：只读参考区（.gitignore 排除，不入主库）；本报告为 M1 插件宿主 / Phase 5~8 / 算法对照（M5 细化）提供完整决策依据。

---

## 1. 资产总览（实测基线）

截至 2026-10-10，`source/` 下全部 10 个参考项目均已完成嵌套 `.git` 剥除，并在 `source/ORIGIN.md` 登记版本（`source/` 为不入库的只读克隆区，该文件仅本机可见；入库的来源登记见 [`core/desktop/vendor-src/ORIGIN.md`](../core/desktop/vendor-src/ORIGIN.md) 与 [`core/android/vendor-src/ORIGIN.md`](../core/android/vendor-src/ORIGIN.md)）。最新实测占用与价值评估如下：

| # | 目录 | 对应上游仓库 | 平台 / 技术栈 | 许可证 | 实测体积 / 文件数 | 对 AuraDSP 的参考价值与对齐里程碑 |
|---|---|---|---|---|---|---|
| 1 | **JamesDSPManager** | `james34602/JamesDSPManager` (master@5aed6a4) | Android / 纯 C DSP 库 | GPL-3.0 | 21.14 MB (612 文件) | ★★★ **核心引擎真相源**（已提取整合至 `core/`，含 P-001/P-002 补丁） |
| 2 | **JDSP4Linux** | `Audio4Linux/JDSP4Linux` (master@3ea7d73) | Linux / PipeWire, Pulse, Qt | GPL-3.0 | 39.21 MB (1,291 文件) | ★★★ **Phase 7 Linux 形态蓝本**（filter-chain 模块化挂载与 D-Bus 通信） |
| 3 | **RootJamesDSP** | `ShadoV90/RootJamesDSP` (master@58e6b1b) | Android (Root / KSU / Magisk) | GPL-3.0 | 14.79 MB (991 文件) | ★★ **Root 路线历史对照**（已由本项目原生 AIDL HAL + KSU 模块超越） |
| 4 | **RootlessJamesDSP** | `timschneeb/RootlessJamesDSP` (master@60d25ae) | Android / AudioEffect 前台服务 | GPL-3.0 | 15.01 MB (1,010 文件) | ★★★ **Phase 6 Rootless 形态直接蓝本**（免 Root 动态会话捕获与前台保活） |
| 5 | **ViPER4Android-FX** | `Magisk-Modules-Repo/ViPER4Android-FX` (master@507b93e) | Android / Magisk, sepolicy | 见仓库 | 3.32 MB (18 文件) | ★★ **系统集成与资产参考**（SELinux 策略范式、VDC 耳机校准格式、IRS 脉冲文件） |
| 6 | **ViPERFX_RE** | `AndroidAudioMods/ViPERFX_RE` (rewrite-continued@eb65772) | Android / C++20, NDK, CMake | GPL-3.0 | 1.12 MB (119 文件) | ★★ **现代 C++ float32 DSP 架构先例**（纯浮点管线设计、动态处理算法参考） |
| 7 | **element** | `kushview/element` (main@7a415269) | Win/Linux/macOS / JUCE, C++ | Apache-2.0 | 6.88 MB (701 文件) | ★★★ **M1 插件宿主与 M6 节点连线图的头号参考**（多格式宿主 + 连线矩阵） |
| 8 | **equalizerAPO64** | `TheFireKahuna/equalizerAPO64` (main@7156020) | Windows / C++, AVX2/512, Qt6 | GPL-2.0 / LGPL | 90.34 MB (488 文件) | ★★★ **Phase 7b Windows APO 唯一工程蓝本**（系统端点注入、注册表挂载、AVX 加速） |
| 9 | **lsp-plugins** | `lsp-plugins/lsp-plugins` (master@2df6eea0) | 多平台 / C++, SIMD, 多格式 | LGPL-3.0+ | 559.99 MB (7,642 文件) | ★★★ **M5 算法对照 + 多格式构建中枢**（66 个子模块完整展开，包含 DSP 核心库） |
| 10 | **pulseeffects** | `mikhailnov/pulseeffects` (master@b9ec88ed) | Linux / C++, GStreamer, GTK3 | GPL-3.0 | 7.45 MB (436 文件) | ★★ **效果机架与预设架构参考**（EasyEffects 前身，预设 JSON 格式与多效果编排） |

总计占用：**~760 MB**，约 **13,300** 个源文件与资源。

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

---

## 3. 算法与系统能力对照矩阵

| 功能 / 算法需求 | AuraDSP 当前状态 | `source/` 中最佳参考仓库 | 具体参考源码路径 / 说明 |
|---|---|---|---|
| **核心 DSP 引擎** | libjamesdsp (vendor + P-001/P-002) | `JamesDSPManager` | `Main/libjamesdsp`（纯 C 引擎真相源） |
| **低频搁架（Low Shelf）** | wrapper 自研 RBJ Biquad (<0.03% 误差) | `lsp-plugins` | `modules/lsp-dsp-units/include/lsp-plug.in/dsp-units/filters/biquad.h` |
| **参数化混响** | wrapper 自研 Freeverb | `pulseeffects` / `lsp-plugins` | Freeverb / Schroeder 算法拓扑及早期反射参量 |
| **响度感知 / 动态扩展** | 待开发（M5 细化） | `lsp-plugins` | `modules/lsp-plugins-loud-comp/src/main/`（工业级等响度曲线与自适应滤波） |
| **多频段分带展宽** | P-002 补丁导出 vendor stereowide | `lsp-plugins` | `modules/lsp-plugins-crossover/`（Linkwitz-Riley 4阶分频网络参考） |
| **卷积与 IR 管理** | FileGate 六道门卫 + convolver 节点 | `equalizerAPO64` / `lsp-plugins` | `lsp-plugins-impulse-responses/`（高吞吐卷积与 IR 预处理机制） |
| **插件宿主 (VST3/CLAP)** | M1 规划阶段（待 D1 协议闭环） | `element` | `src/engine/` & `src/controllers/`（跨平台插件扫描、隔离与总线调度） |
| **信号链重排序 / 节点图** | M3-a 线性展示 / M3.5 待 ADR | `element` / `pulseeffects` | `element` 的 Graph 连线拓扑；`pulseeffects` 的 pipeline 动态重编排 |
| **Windows 全局音频** | 当前为进程内 WASAPI pump | `equalizerAPO64` | `EqualizerAPO/`（APO 注册表服务、驱动挂载与端点拦截） |
| **Linux 全局音频** | Phase 7 规划中 | `JDSP4Linux` / `pulseeffects` | `JDSP4Linux/src/pipewire/`（PipeWire filter-chain 与 SPA 模块） |
| **Android 免 Root 引擎** | Phase 6 规划中 | `RootlessJamesDSP` | `app/src/main/java/.../AudioCaptureService.kt`（无 Root 前台服务捕获） |

---

## 4. 磁盘与工程合规性审计

1. **嵌套 `.git` 审查**：
   - 全面递归扫描确认：`source/` 下所有目录及子目录均 **无任何 `.git` 目录残留**，彻底规避子模块递归嵌套与意外提交问题。
2. **构建缓存审计**：
   - `source/RootJamesDSP/` 与 `source/RootlessJamesDSP/` 下存在由构建/导入自动生成的 `.gradle/` 目录。该目录仅为本地临时索引，建议后续可选择性清理或保留在本地。
3. **大文件与二进制包审计**：
   - `equalizerAPO64/Setup/lib*`：存在约 70MB 的 Qt6 预编译 DLL，只读保留无需改动。
   - `lsp-plugins/release/`：存在解包与打包的 tar 归档（约 339MB），主工程源码已在 `modules/` 完整展开。

---

## 5. 问题清单最新结论（全部闭环）

| # | 状态 | 涉及项 | 结论与说明 |
|---|---|---|---|
| **P-1** | ✅ 已闭环 | 嵌套 `.git` 剥离 | 10 个项目已统一剥除 `.git`，版本与 commit 完整登记于 `source/ORIGIN.md`。 |
| **P-2** | ✅ 已闭环 | RootJamesDSP README 疑云 | 确认 ShadoV90/RootJamesDSP 为上游 fork，其 root 模式通过 `BUILD_ROOT.md` 与脚本体现，克隆源准确无误。 |
| **P-3** | ✅ 已闭环 | 大体积仓库审计 | 体积主要由 `lsp-plugins`（全量 66 模块 + release 归档）与 `equalizerAPO64`（Qt6 DLL）构成。代码结构完整，不影响主仓库性能（已 `.gitignore`）。 |
| **P-4** | ✅ 已闭环 | element 上游文件 | 上游 `CLAUDE.md` 为只读参考，已备案无害。 |
| **P-5** | ✅ 已闭环 | lsp-plugins 源码定位 | **已彻底澄清并闭环**：`modules/` 下 66 个子模块源码完整在盘，无需额外克隆单个插件仓。 |
| **P-6** | ✅ 新增闭环 | bass_enhancer 溯源 | 确认 pulseeffects 底层为 Calf 插件；算法对照锁定为 `lsp-plugins-loud-comp` 与 `lsp-dsp-units`。 |

---

## 6. 后续行动建议

1. **M1 插件宿主推进**：在 D1（GPLv3）决策明确后，直接以 `source/element` 作为 VST3/CLAP 进程内宿主的架构蓝本。
2. **M5 算法精细化**：全面挖掘 `source/lsp-plugins/modules/lsp-dsp-units` 与 `lsp-plugins-loud-comp`，用于自研等响度与高阶滤波器的对比验证。
3. **磁盘轻量化（可选）**：如需节约约 300MB 空间，可清空 `source/lsp-plugins/release/` 下的离线归档包，因 `modules/` 源码已足够自洽。

