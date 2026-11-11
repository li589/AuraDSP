# AuraDSP

![version](https://img.shields.io/badge/version-0.1.0-2f81f7?style=flat-square)
![platform](https://img.shields.io/badge/platform-Windows_10%2F11_%7C_Linux_%7C_Android-0078d6?style=flat-square)
![engine](https://img.shields.io/badge/engine-C%2B%2B20-00599c?style=flat-square)
![ui](https://img.shields.io/badge/UI-Flutter_3.47-02569b?style=flat-square)
![dsp](https://img.shields.io/badge/DSP-23_units-8957e5?style=flat-square)
![plugins](https://img.shields.io/badge/plugins-VST3_%7C_CLAP_%7C_VST2-4b8bbe?style=flat-square)

**跨平台全局音频效果系统** —— 一套 Flutter 界面 + 一族自研引擎，把系统级音频链路接管下来做实时 DSP。
UI 与引擎之间只有一层 **C ABI**（`engine/auradsp_engine.h`）：UI 不感知引擎形态，也不感知引擎在哪个进程。

> **项目状态**：Windows 成品级（主力形态）· Linux 功能对等已交付 · Android Root 端到端打通 · 首个正式版 **v0.1.0**（Windows + Linux，只从 `main` 构建）筹备中。

**核心亮点**

- **一套界面，三种形态**：Windows 桌面（WASAPI / AuraVAIO 虚拟声卡 / Voicemeeter / ASIO）、
  Linux 桌面（PulseAudio 三模式 + ALSA 专家模式）、Android Root（AIDL effects HAL 系统级注入）。
- **自研 DSP 链**：11 个自研效果 TU + 12 级经典算法链（可重排序）+ 卷积 / DDC / EEL2 可编程脚本；
  参数与预设全数据驱动，引擎参数表单一真源、双端对账门禁看守。
- **真插件宿主**：VST3 / CLAP / VST2 三格式、4 槽 × 5 级插入；64 位进程内加载，
  32 位自动经 `plugin_host_x86` 位桥隔离；原生编辑器窗口在 Windows 与 Linux（X11）双平台对等开放。
- **系统级集成**：自研 AuraVAIO 内核虚拟声卡（多声道 WaveRT）、虚拟 ASIO、系统 APO、Voicemeeter 回调桥。
- **工程纪律**：RT 线程零分配零锁零 IO；CI 八 job；140+ 冒烟门禁与多道脚本门禁常绿。

三条贯穿全仓的约束（细节见 [`AGENT.md`](AGENT.md)）：

1. **C ABI 是唯一边界** —— UI 只能经 `engine/auradsp_engine.h` 与引擎通信，符号多处对齐由脚本门禁强制。
2. **RT 线程绝对禁区** —— 音频回调内不分配、不加锁、不做 IO；控制侧改动走影子快照 + 块边界原子换指针。
3. **数据驱动，禁止硬置入** —— 参数、预设、效果注册表以引擎参数表 / `graph.effects` / JSON 资产为真源。

---

## 形态矩阵

| 形态 | 平台 | 接入方式 | 状态 |
|---|---|---|---|
| **Desktop** | Windows 10 / 11 | WASAPI 泵 + `auradsp_engine.dll` 进程内 FFI | ● 主力，全功能 |
| **Linux** | Ubuntu（PulseAudio / PipeWire） | 同一 C ABI 的 `libauradsp_engine.so` + PA simple API（ALSA 直连为专家模式） | ● 已交付，与 Windows 功能对等 |
| **Root** | Android（KSU / Magisk） | AIDL effects HAL 注入，系统级全局 | ● 端到端打通 + 重启持久化 |
| **Rootless** | Android APK | 会话级 AudioEffect 前台服务 | ○ 蓝本 `source/RootlessJamesDSP` |

Windows 四后端（`audio_modes.dart`）：`sysapo` 系统 APO（默认）· `vaio` AuraVAIO 虚拟声卡 ·
`vbcallback` Voicemeeter 回调（按总线独立引擎）· `asio` 专业 ASIO（2/4/6/8 声道）。
Linux 三模式：`system`（PA 输出）· `virtual`（null-sink 虚拟设备）· `driver`（snd-aloop 回环），外加 ALSA 专家直连。
双平台安装器均已落地（Windows 单文件向导 / Linux deb + AppImage + tar.gz），见 `installer/`。

## 音频链路

精确顺序与门控以 `engine/chain/engine_chain.cpp` 的 `process_stereo_chain` 为准：

```text
输入
 ├→ 前级：gate(+deesser) · filter · bassmono · bass（心理声学）· Stage 0 插件 · shelf · dyneq · Stage 1 插件
 ├→ vendor 12 级链（legacy，内部可重排序）：tube · bass · eq · comp · arbmag · convolver · ddc
 │    · liveprog（EEL2）· crossfeed · stereo · reverb · post + limiter
 ├→ 后级：Stage 2 插件 · haas · spatial · exciter ·（多声道 FDN 混响）· Stage 3 插件
 └→ 输出：loudness · Lookahead Limiter → 安全钳位 → Stage 4 插件
输出
```

处理能力共 23 个效果单元；插件 4 槽 × 5 级插入点（Pre-DSP / Pre-Vendor / Post-Vendor /
Post-Reverb / Post-Limiter），挂载即旁路、解旁路才进链。EEL2 脚本系统自带专业 IDE 与
内置手册（与 VM 函数表门禁对账）；脚本经 `spl0/spl1` 处理前两声道，宿主以 `num_ch`
告知当前链路声道数（2/4/6/8）。完整参数语义以代码为准——引擎参数表 + `graph.effects` 注册表。

## 快速开始

**Windows**（VS 2026 + MSVC x64 / CMake / Flutter 3.47.9 / Python 3.10+）

```powershell
cmake --preset windows-x64
cmake --build --preset windows-x64-release --target auradsp_engine plugin_host_x64
# 未装 Steinberg ASIO SDK 时追加 -DAURADSP_BUILD_BRIDGES=OFF
cd app/auradsp_app
flutter build windows --release --no-tree-shake-icons   # 该 flag 必须带，否则图标被裁
```

**Linux**（依赖口径与 CI 相同，见 `.github/workflows/ci.yml`）

```bash
cmake --preset linux-x64
cmake --build --preset linux-x64-release   # 产物 core/desktop/linux/out/Release/libauradsp_engine.so
cd app/auradsp_app && flutter build linux --release --no-tree-shake-icons
python tools/sync_artifacts.py              # 引擎/宿主产物同步进 bundle
```

**验证**

```bash
flutter analyze                             # 要求零问题
python test/runner.py                       # 引擎冒烟（按平台自动切换清单）
python tools/bin/run_dart_tests.py          # Dart 单测（按文件串行，勿全量并发）
python tools/bin/abi_consistency.py         # ABI 符号多处对齐
bash installer/linux/pack.sh --build        # Linux 一键打包（deb / AppImage / tar.gz）
```

## 仓库结构

```text
engine/        桌面引擎（C++20）：auradsp_engine.{h,cpp,def} C ABI · chain/ 信号链与 IO
               · dsp/ 11 个自研效果 TU · plugins/ 插件宿主 · legacy/ JamesDSP 核 + PATCHES.md
vendor/        第三方接口头只读（CLAP / VST3 / VST2 净室头）
assets/        运行资源（convolver / ddc / liveprog + manifest.json）
core/desktop/  windows CMake 与构建脚本 · windows-drivers/ VAIO/VM/APO/ASIO 与三桥 · linux CMake
app/auradsp_app/  Flutter UI（效果卡 / 处理链 / 插件页 / 脚本 IDE / 可视化）
installer/     双平台安装器：windows 单文件向导 · linux deb/AppImage 打包链
test/          smoke/ 冒烟门禁脚本 · ui/ UI 自动化
tools/         bin 门禁工具 · resource_pipeline 资源包流水线
docs/          00-总览 10-架构 20-执行 30-审查 40-回顾 90-归档 + adr/
source/        第三方参考仓库只读快照 · dist/ 发布产物（不进 git）
```

## 质量门禁

| 门禁 | 覆盖 |
|---|---|
| `flutter analyze` / Dart 单测 | 全量 lib + test 零问题；单测按文件串行跑（CI J6） |
| 引擎冒烟 `test/runner.py` | 144 项登记：DSP 正确性、插件生命周期、桥 ABI、竞态；按平台自动切换 |
| 脚本门禁 | ABI 一致性 · 补丁编号 P-NNN · 静默异常留痕 · EEL 手册↔VM 对账 · 硬编码中文棘轮 |
| CI（`ci.yml` + `windows-installer.yml`） | 八 job：静态门禁 / 双平台引擎构建 / Linux 冒烟 / ABI / Dart 测试 / 资源守卫 / Linux App 打包 / 安装器 |

## 文档入口

| 文档 | 定位 |
|---|---|
| [`AGENT.md`](AGENT.md) | 智能体协作总纲：铁律 / 目录规范 / 命令速查 |
| [`docs/README.md`](docs/README.md) | `docs/` 完整导航索引 |
| [`docs/00-总览/项目架构与开发规范.md`](docs/00-总览/项目架构与开发规范.md) | 工程唯一真相源：目录 / 分层 / 构建 / 已验证决策 |
| [`docs/00-总览/产品架构总览.md`](docs/00-总览/产品架构总览.md) | 产品与品牌真相源：命名体系 / 形态矩阵 |
| [`docs/30-审查/`](docs/30-审查/) | 历轮审查报告（全项目深审、三面审计等，均已结案） |
| [`installer/docs/01_distribution_architecture.md`](installer/docs/01_distribution_architecture.md) | 发行架构：版本规范 / 双平台产物 / 资源包独立版本线 |

架构决策记录见 `docs/adr/`。

## 许可证与致谢

- 本项目以 [GNU GPL v3.0](LICENSE) 开源（全文见仓库根 `LICENSE`）。
- 引擎核心衍生自 [JamesDSP](https://github.com/james34602/JamesDSPManager)（libjamesdsp，收编于 `engine/legacy/`），遵循其上游 GPL 系许可证；所有补丁登记在 `engine/legacy/PATCHES.md`。
- 第三方插件 API（`vendor/`：CLAP / Steinberg VST3 / VST2 Xaymar 净室头）遵循各自许可证；VST2 仅以 BSD-3-Clause 净室头编译。
- 运行资源（IR / VDC / Liveprog 脚本）来自上游社区，清单见 `assets/manifest.json`；参照项目快照溯源见 `source/ORIGIN.md` 与 `vendor/ORIGIN.md`。
