# AuraDSP

![version](https://img.shields.io/badge/version-0.5.0-2f81f7?style=flat-square)
![platform](https://img.shields.io/badge/platform-Windows_10%2F11_%7C_Android-0078d6?style=flat-square)
![engine](https://img.shields.io/badge/engine-C%2B%2B20-00599c?style=flat-square)
![ui](https://img.shields.io/badge/UI-Flutter_3.47-02569b?style=flat-square)
![dsp](https://img.shields.io/badge/DSP-23_stages-8957e5?style=flat-square)
![plugins](https://img.shields.io/badge/plugins-VST3_%7C_CLAP-4b8bbe?style=flat-square)

**跨平台全局音频效果系统** —— 一套 Flutter 界面 + 一族自研引擎，把系统级音频链路接管下来做实时 DSP。
Windows 侧是进程内 WASAPI 泵 + `auradsp_engine.dll`；Android 侧经 AIDL effects HAL 注入系统音频链路。
UI 与引擎之间只有一层 **C ABI**（`engine/auradsp_engine.h`），UI 不感知引擎形态、也不感知引擎在哪个进程。

| 关键面 | 现状 |
|---|---|
| 主力形态 | Windows 10 / 11 桌面，全功能；四种音频后端可切 |
| 处理能力 | 23 个处理阶段 = 自研 11 个效果 TU + vendor 12 级可重排序链 + 插件 4 槽 × 5 级插入 |
| 插件宿主 | VST3 / CLAP 64 位；默认进程内，`AURA_PLUGIN_HOST_MODE=process` 切进程外硬隔离 |
| 质量门禁 | analyze 零问题 · Dart 55 个测试文件 / 580+ 用例 · 引擎冒烟 110 项 · ABI / 补丁编号 / 静默异常三道脚本门禁 |

目录：[它是什么](#1-它是什么) · [形态矩阵](#2-形态矩阵) · [音频链路](#3-音频链路) · [近期里程碑](#4-近期里程碑) · [快速开始](#5-快速开始) · [仓库结构](#6-仓库结构) · [质量门禁](#7-质量门禁) · [文档入口](#8-文档入口) · [许可证与致谢](#9-许可证与致谢)

---

## 1. 它是什么

三层结构，每层只认下一层的契约：

```text
┌─ UI 层  app/auradsp_app（Flutter）────────────────────────
│  21 张效果卡 · 处理链排序 · 插件页（4 槽）· 脚本 IDE · 预设/会话记忆 · 六页体系
└──────────────┬───────────────────────────────────────────
               │ C ABI = 唯一进程边界（engine/auradsp_engine.h）
┌─ 引擎层  auradsp_engine.dll（C++20 / MSVC）───────────────
│  chain/   信号链与 IO（含 viz、convolver、audiofile）
│  dsp/     11 个自研效果 TU
│  legacy/  12 级经典链（JamesDSP 算法核 + EEL2）+ PATCHES.md
│  plugins/ 插件宿主：api / driver / formats / platform / integration
└──────────────┬───────────────────────────────────────────
               │
┌─ 后端层  core/desktop/windows-drivers（独立 CMake）──────
│  AuraVAIO 虚拟声卡 · ASIO 双线 · Voicemeeter 回调 · 系统 APO · 三桥
└──────────────────────────────────────────────────────────
```

三条贯穿全仓的约束（细节见 [`AGENT.md`](AGENT.md)）：

1. **C ABI 是唯一边界**——UI 只能经 `engine/auradsp_engine.h` 下发；符号三处对齐由 `tools/bin/abi_consistency.py` 强制。
2. **RT 线程绝对禁区**——音频回调内不分配、不加锁、不做 IO；控制侧改动走影子快照 + 块边界原子换指针。
3. **数据驱动，禁止硬置入**——参数、预设、效果注册表以 `ParamRegistry` / `graph.effects` / JSON 资产为真源，不按插件名/厂商名写死分支。

---

## 2. 形态矩阵

| 形态 | 平台 | 接入方式 | 状态 |
|---|---|---|---|
| **Desktop** | Windows 10 / 11 | 进程内 WASAPI 泵 + `auradsp_engine.dll`（DLL 进程内 FFI） | ● 主力，全功能 |
| **Root** | Android（KSU / Magisk） | AIDL effects HAL 注入，系统级全局 | ● 端到端打通 + 重启持久化 |
| **Rootless** | Android APK | 会话级 AudioEffect 前台服务 | ○ 蓝本 `source/RootlessJamesDSP` |
| **Linux** | PipeWire / PulseAudio | filter-chain 模块化挂载 | ○ 蓝本 `source/JDSP4Linux` |

**Windows 四种音频后端**（`app/auradsp_app/lib/core/audio_modes.dart`）：

| 模式 | 含义 | 备注 |
|---|---|---|
| `sysapo` | System APO | 默认；回归纯配置面 |
| `vaio` | AuraVAIO 虚拟声卡 | 驱动已点亮，选择持久化 |
| `vbcallback` | Voicemeeter 回调 | 支持活切；按总线（路）独立引擎 |
| `asio` | 专业 ASIO | 支持活切；2/4/6/8 声道多线 |

Android 侧为 `root` / `rootless`。驱动套件在 `core/desktop/windows-drivers/`：`01_vaio` / `02_voicemeeter_client` / `03_apo` / `04_asio` + `bridge/`（asio / vaio / vm 三桥）。

---

## 3. 音频链路

粗粒度分组如下；**精确顺序与门控以 `engine/chain/engine_chain.cpp` 的 `process_stereo_chain` 为准**。

```text
输入
 │
 ├→ 前级（Category A，8 声道独立掩码）
 │     gate · deesser · filter · bassmono · bass（心理声学）· shelf · dyneq · comp
 ├→ 插件 Pre-DSP（4 槽 × 5 级拓扑之一）
 ├→ vendor 12 级链（legacy，内部可重排序）
 ├→ 后级舞台：haas · spatial · exciter · loudness · Freeverb
 └→ 输出级：Lookahead Limiter → 安全钳位 → 插件 Post-Limiter
 │
输出
```

**自研 11 个效果 TU**（`engine/dsp/`）

| 效果 | 说明 |
|---|---|
| `gate` + `deesser` | 噪声门 + 齿音消除（同一 TU） |
| `filter` | 独立 HP / LP / BP biquad |
| `bassmono` | 低频单声道化 |
| `bass` | 心理声学低音（MaxxBass 式谐波） |
| `shelf` | 低频搁架 biquad |
| `dyneq` | 三段全参数动态 EQ（见下） |
| `haas` | Haas 差分环绕 |
| `spatial` | 参数化 HRTF + 镜像源早期反射 + FDN 晚期 |
| `exciter` | 谐波激励器 |
| `loudness` | 等响度补偿（简化 ISO 226） |
| `freeverb` | 参数化混响（Schroeder-Moorer） |

`dyneq` 细节：Low shelf 20–500Hz / Mid bell 200–8kHz / High shelf 2k–20kHz，每段含
`enable / freq / q / gain / range / threshold`，全局 `attack / release`；静态 RBJ + 动态谱减
（与 deesser 同构），位于 shelf 之后、vendor 链之前。

**vendor 12 级链**（`engine/legacy/`，内部可重排序）
`tube`（Triode / Pentode / Tape）· `bass` · `eq`（卷积 EQ）· `comp`（DrDynamic FFT Compander）· `arbmag` · `convolver`（IR 卷积，FileGate 六道门卫）· `ddc`（ViPER DDC）· `liveprog`（EEL2 可编程，专业 IDE + 编译/应用互锁 + EqualizerAPO 转写）· `crossfeed`（bs2b，Chu Moy / Jan Meier）· `stereo`（分带展宽）· `reverb`（SF 预设）· `post` + `limiter`

**插件宿主**（`engine/plugins/`）
VST3 / CLAP 64 位，4 插槽 × 5 级插入拓扑（Pre-DSP / Pre-Vendor / Post-Vendor / Post-Reverb / Post-Limiter）。挂载即旁路，解旁路才进链；32 位插件由 PE 头判定后双端拦截。进程外宿主为 opt-in。

> 完整参数语义以 `engine/auradsp_engine.h` 参数表 + `graph.effects` 注册表为准 —— **以代码为准，不全信文档**。

Voicemeeter 桥（`bridge/vm_bridge` + `02_voicemeeter_client`）按路处理：回调内每 8 声道一组建独立引擎，插件可按总线勾选/旁路；超预算自动保护会持续超限时把插件收窄到监听总线（EMA < 50% × 6s 自动恢复，手动改掩码立即让位 + 60s 冷却），插件页如实显示「部分旁路」。组间并行（Z17）把各组 DSP 发布给常驻 worker 池，单回调墙钟从 Σ(8 组) 压到 ≈ max(单组)，`AURA_VM_PARALLEL=0` 可退回串行对账。

---

## 4. 近期里程碑

| 日期 | 内容 | 提交 |
|---|---|---|
| 2026-10-28 | 预设系统 v7：路由/设备端点移出预设（不再被载入预设清空）、`defaults.json` 与出厂预设键集常驻门禁、导入版本闸门与同名改名 | `8486e11` `cbf5990` |
| 2026-10-28 | 插件扫描目录改版（平台预置、可勾选、异步深扫）+ 深扫挂死防护（进程内 2.5s / 进程外 IPC 超时杀宿主） | `60df848` |
| 2026-10-28 | 挂载即旁路（治理「UI 显示旁路但实际不旁路」）+ 插件界面在旁路槽不再假装有音频流 | `56c145f` |
| 2026-10-27 | VB 桥加载期卡顿根治：fan-in 预算感知截止 + 加载期旁路 + 泵线程提优先级 | `902afd4` |
| 2026-10-24 | 全仓审查与硬置入排查：运行时真特判 **0 处**，5 个 P0 / 9 个 P1 全闭环 | 见 `docs/30-审查/` |

---

## 5. 快速开始

**环境要求**

| 依赖 | 版本 / 说明 |
|---|---|
| Windows | 10 / 11（驱动套件仅 Windows） |
| Visual Studio | 2026 + MSVC x64，C++20（`build_engine.sh` 用 `-G "Visual Studio 18 2026"`） |
| CMake | 随 VS 附带即可 |
| Flutter | 3.47.7+，需启用 Windows desktop；`flutter doctor` 全绿 |
| Python | 3.10+（冒烟测试与 `tools/bin` 门禁脚本） |

**桌面引擎**（产物 `core/desktop/windows/out/Release/auradsp_engine.dll`，脚本会自动同步多副本）

```bash
cd core/desktop/windows && bash build_engine.sh
# 等价：cmake -S . -B out && cmake --build out --config Release
```

**UI 应用**（`--no-tree-shake-icons` 必须带，否则图标被裁）

```powershell
cd app/auradsp_app
flutter build windows --release --no-tree-shake-icons
flutter analyze
flutter test --concurrency=1          # 并发跑会因 isolate 超时抖动，必须串行
```

**测试与工具**

```powershell
python test/runner.py --smoke                 # 引擎冒烟（统一入口，110 项登记）
python test/runner.py --ui                    # UI 自动化（置顶前置，默认 7 个脚本）
python tools/bin/abi_consistency.py           # .def / 头文件 / ffi.dart 三处符号一致
python tools/bin/verify_dll_copies.py --sync  # DLL 多副本哈希同步（禁手拷）
python tools/bin/patch_id_scan.py             # P-NNN 唯一且已登记
python tools/bin/dart_swallow_scan.py         # 空 catch 必须留痕
```

发布产物：`app/auradsp_app/build/windows/x64/runner/Release/` 增量覆盖到 `dist/AuraDSP-Windows-x64/`（`dist/` 不进 git）。引擎与桥的 DLL 若被运行中的 App 占用会同步失败，先退出应用。

---

## 6. 仓库结构

<details>
<summary>展开目录树（含各目录规模）</summary>

> 目录演进：P3a/P3b 把引擎、第三方、资源三块提到顶层（`core/desktop/engine_api` → `engine/`、
> `core/desktop/vendor-src` → `vendor/`、`resource/` → `assets/`）；P4b 把链/IO 与插件宿主收进
> `chain/`、`host/`；P1（2026-10-20）再把插件宿主从 `host/` 迁到 `plugins/` 分层目录。

```text
AuraDSP/
├── engine/                  ★ 桌面引擎（C++20 / MSVC）
│   ├── auradsp_engine.{h,cpp,def}    C ABI 契约（UI↔驱动唯一边界）
│   ├── engine_internal.h             私有状态 + 跨文件符号
│   ├── chain/                        链与 IO：engine_{chain,convolver,viz,probe,audiofile}.cpp
│   ├── dsp/                          11 个自研效果 TU（每效果一文件）
│   ├── plugins/                      插件宿主：api/ driver/ formats/ platform/win32/ integration/ tests/
│   └── legacy/                       JamesDSP 算法核（12 级链 + EEL2）+ PATCHES.md
├── vendor/                  ★ 第三方接口头只读（clap / steinberg-vst3），原样未改
├── assets/                  ★ 运行资源 251MB（convolver/ ddc/ liveprog/ + manifest.json）
├── core/
│   ├── desktop/windows/             CMakeLists + build_engine.sh → out/Release/*.dll
│   ├── desktop/windows-drivers/     独立 CMake：01 VAIO / 02 VM 泵 / 03 自研 APO / 04 ASIO 双线 / bridge 三桥
│   └── android/                     registrar / spike-global-effect / stubs / aidl-gen / vendor-src
├── app/auradsp_app/         Flutter 3.47.7 · 121 个 dart（不含 l10n 生成）· 21 张效果卡
├── test/
│   ├── smoke/                       112 个 smoke_*.py；runner 登记 110
│   │                                未登记 2 个：three_key_plugins（人工值守）、g7_2_bridge_abi（需三桥产物）
│   └── ui/                          14 个 UI 脚本；runner 默认跑 7 个
├── tools/                   bin 14 · probe 22 · resource_pipeline 2 · calibration 1（archive/ 不入库）
├── source/                  第三方参考仓库只读快照（17 项）
├── docs/                    00-总览 10-架构 20-执行 30-审查 40-回顾 90-归档 + adr / forensics / ui-redesign / 参考技术手册
├── .ai/                     AI 自治沉淀区：memory（长期范式 + 每日过程）/ rules
├── AGENT.md · CLAUDE.md     智能体协作总纲 / 命令速查
└── dist/                    发布产物（不进 git）
```

</details>

---

## 7. 质量门禁

| 门禁 | 命令 | 覆盖范围 |
|---|---|---|
| Dart 静态分析 | `flutter analyze` | 全量 lib + test，要求零问题 |
| Dart 单测 | `flutter test --concurrency=1` | 55 个测试文件；串行执行避免 isolate 抖动 |
| 引擎冒烟 | `python test/runner.py --smoke` | 110 项：DSP 正确性、插件生命周期、桥 ABI、竞态 |
| ABI 一致性 | `python tools/bin/abi_consistency.py` | `.def` ↔ 头文件 ↔ `ffi.dart` 三处符号与签名 |
| DLL 副本同步 | `python tools/bin/verify_dll_copies.py --sync` | 三处副本哈希一致（禁手拷） |
| 补丁编号 | `python tools/bin/patch_id_scan.py` | `P-NNN` 唯一、单调、已登记、别名不歧义 |
| 静默异常 | `python tools/bin/dart_swallow_scan.py` | 空 `catch` 必须留痕或标注理由 |
| 硬编码中文 | `test/l10n_cjk_guard_test.dart` | 棘轮：`lib/features` + `lib/ui` 基线只降不升 |

最近一轮（2026-10-28）：analyze 零问题、Dart 580+ 用例通过、冒烟 100%。

---

## 8. 文档入口

| 文档 | 定位 |
|---|---|
| [`AGENT.md`](AGENT.md) | **智能体协作总纲**：铁律 / 目录规范 / 命令速查 |
| [`CLAUDE.md`](CLAUDE.md) | 精简版构建与测试命令 |
| [`docs/README.md`](docs/README.md) | **`docs/` 导航入口**（完整索引） |
| [`docs/00-总览/项目架构与开发规范.md`](docs/00-总览/项目架构与开发规范.md) | **工程唯一真相源**：目录约定 / 分层 / 构建规范 / 已验证决策表 |
| [`docs/00-总览/产品架构总览.md`](docs/00-总览/产品架构总览.md) | **产品与品牌真相源**：命名体系 / 形态矩阵 |
| [`docs/30-审查/预设系统与硬置入复检-2026-10-28.md`](docs/30-审查/预设系统与硬置入复检-2026-10-28.md) | 最近一轮专项复检：预设边界 / 基线门禁 / 硬置入排查结论 |
| [`.ai/memory/MEMORY.md`](.ai/memory/MEMORY.md) | **项目长期备忘**：既定范式 / 避坑 / 测试 SOP（入库的唯一记忆真相源） |
| [`docs/源码重组与目录规范方案-2026-10-13.md`](docs/源码重组与目录规范方案-2026-10-13.md) | 目录重组的诊断 / 目标树 / 政策 / 分期 |
| [`docs/40-回顾/阶段性回顾-2026-10-13.md`](docs/40-回顾/阶段性回顾-2026-10-13.md) | 重构 P0→P3b 与功能交付回顾 |

架构决策记录见 `docs/adr/`：ADR-001 / 003 / 004 / 006 / 007 / 008 / 009 已接受，ADR-002 已被 ADR-006 取代（原文留档）。

---

## 9. 许可证与致谢

- 引擎核心衍生自 [JamesDSP](https://github.com/james34602/JamesDSPManager)（libjamesdsp，2026-10-16 起收编于 `engine/legacy/`），遵循其上游 GPL 系许可证；所有补丁登记在 `engine/legacy/PATCHES.md`。
- 第三方插件 API（`vendor/plugin-api/`：CLAP / Steinberg VST3）遵循各自许可证。
- 第三方参照项目以只读快照置于 `source/`（不入库），提取与版本溯源见 `source/ORIGIN.md` 与 `vendor/ORIGIN.md`。
- 运行资源（IR / VDC / Liveprog 脚本）来自上游社区，清单见 `assets/manifest.json`。
