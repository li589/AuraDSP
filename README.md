# AuraDSP

![version](https://img.shields.io/badge/version-0.5.0-2f81f7?style=flat-square)
![platform](https://img.shields.io/badge/platform-Windows_10%2F11_%7C_Linux_%7C_Android-0078d6?style=flat-square)
![engine](https://img.shields.io/badge/engine-C%2B%2B20-00599c?style=flat-square)
![ui](https://img.shields.io/badge/UI-Flutter_3.47-02569b?style=flat-square)
![dsp](https://img.shields.io/badge/DSP-23_units-8957e5?style=flat-square)
![plugins](https://img.shields.io/badge/plugins-VST3_%7C_CLAP_%7C_VST2-4b8bbe?style=flat-square)

**跨平台全局音频效果系统** —— 一套 Flutter 界面 + 一族自研引擎，把系统级音频链路接管下来做实时 DSP。
Windows 侧是进程内 WASAPI 泵 + `auradsp_engine.dll`；Android 侧经 AIDL effects HAL 注入系统音频链路。
UI 与引擎之间只有一层 **C ABI**（`engine/auradsp_engine.h`），UI 不感知引擎形态、也不感知引擎在哪个进程。

> **项目状态**：Windows 成品级（主力形态）· Linux 功能对等已交付 · Android Root 端到端打通 ·
> 2026-11-05 完成全项目深度审查（驱动 / 引擎 / 插件 / App / 跨组件五面），7 条发现全部修复闭环。

**核心亮点**

- **一套界面，三种形态**：Windows 桌面（WASAPI / AuraVAIO 虚拟声卡 / Voicemeeter / ASIO 四后端）、
  Linux 桌面（PulseAudio 三模式 + ALSA 专家模式）、Android Root（AIDL effects HAL 系统级注入）。
- **自研 DSP 链**：11 个自研效果 TU + 12 级经典算法链（可重排序）+ 卷积 / DDC / EEL2 可编程脚本，
  参数与预设全数据驱动，引擎参数表单一真源、双端对账门禁看守。
- **真插件宿主**：VST3 / CLAP / VST2 三格式，64 位进程内、32 位自动位桥隔离，
  插件原生编辑器窗口在 Windows 与 Linux（X11）双平台对等开放。
- **系统级集成**：自研 AuraVAIO 内核虚拟声卡（多声道 WaveRT）、虚拟 ASIO、系统 APO、
  Voicemeeter 回调桥——2026-11-05 经深度审查硬化（内核环几何真值化、控制设备
  SDDL 收紧 + 独占映射防劫持，真机实证）。
- **工程纪律**：RT 线程零分配零锁、CI 八 job 双流水线、140+ 冒烟门禁与多道脚本门禁常绿。

| 关键面 | 现状 |
|---|---|
| 主力形态 | Windows 10 / 11 桌面，全功能；四种音频后端可切 |
| 处理能力 | 23 个效果处理单元（能力计数）= 自研 11 个效果 TU + vendor 12 级可重排序链；另有插件 4 槽 × 5 级插入（链页按 20 个可见阶段展示） |
| 插件宿主 | VST3 / CLAP / VST2；64 位加载走进程内，32 位自动经 `plugin_host_x86` 位桥；`AURA_PLUGIN_HOST_MODE=process` 切加载硬隔离；扫描=快扫本地、深扫按位数进对应宿主（`AURA_PLUGIN_DEEP_SCAN=inproc` 回退引擎内深扫） |
| 质量门禁 | analyze 零问题 · Dart 单测 70 文件通过 / 4 平台跳过（CI 口径） · 引擎冒烟 143 项 · ABI / 补丁编号 / 静默异常三道脚本门禁 · GitHub CI 八 job（Win/Linux 双流水线） · 全项目深度审查 S0–S8 已结案（2026-11-05） |

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
| **Linux** | Ubuntu（PulseAudio） | 引擎 `libauradsp_engine.so`（与 Windows 同一 C ABI / 同 56 符号）+ PulseAudio simple API 输出 | ✅ 一期已交付（`feature/linux` 已合入 `dev`，PR #21）：引擎与 App 闭环、CI 全绿，Ubuntu 24.04 真机验证通过；三模式功能对等（S5a：系统 / 虚拟 sink / snd-aloop 驱动，真机回环采集走 `.monitor` 源）；桌面体验齐备（S5b：XDG 目录拆分、托盘 PNG、XDG 自启、MPRIS 媒体会话）；治理收尾完成（S5c：插件目录 UI 按 D-7 隐藏、死依赖清理、库加载单点化）；真机轮次另修复输出泵饿死、Impeller 软件 GL 重绘损坏与频谱门三项（详见 `docs/40-回顾/Linux移植收官回顾-2026-11-02.md`，验证步骤见同目录《Linux真机验证清单》）；二期续加 **ALSA 直连专家模式**（D-6 二期：period 256 帧直连输出/采集、driver 模式直采 `hw:Loopback`，设置页可切换，默认仍 PulseAudio） 与 **插件宿主全量**（D-7 二期：VST3/CLAP 进程内托管 + 双宿主隔离 `plugin_host_x64`/`plugin_host_x86` 与 32 位桥，CI 活体实证）；其后完成细致打磨三期（驱动健壮性/状态可见性/设置完整性）与代码安全+边界审查（IPC 对端认证等 8 项修复，详见 `docs/40-回顾/Linux打磨与安全审查-2026-11-02.md`）；其后 **X11 插件编辑器 GUI**（2026-11-04：顶层容器 + 最小 XEmbed 宿主，CLAP/VST3/VST2 三格式编辑器对等开放）与 **VST2 Linux 跟进**（ELF 入口判定扫描 + 位桥深扫/加载）落地；2026-11-05 全项目深度审查收尾 Linux 侧：虚拟 sink 生命周期治理（退出/切离自动卸载、残留先卸后装）与 PA/PipeWire 重启后输出死亡自动恢复 |

**Windows 四种音频后端**（`app/auradsp_app/lib/core/audio_modes.dart`）：

| 模式 | 含义 | 备注 |
|---|---|---|
| `sysapo` | System APO | 默认；回归纯配置面 |
| `vaio` | AuraVAIO 虚拟声卡 | 驱动已点亮，选择持久化；内核侧经深度审查硬化（环几何真值派生 + 控制设备 SDDL/独占映射，见 §4 里程碑 2026-11-05） |
| `vbcallback` | Voicemeeter 回调 | 支持活切；按总线（路）独立引擎 |
| `asio` | 专业 ASIO | 支持活切；2/4/6/8 声道多线 |

Android 侧为 `root` / `rootless`。驱动套件在 `core/desktop/windows-drivers/`：`01_vaio` / `02_voicemeeter_client` / `03_apo` / `04_asio` + `bridge/`（asio / vaio / vm 三桥）。

---

## 3. 音频链路

粗粒度分组如下；**精确顺序与门控以 `engine/chain/engine_chain.cpp` 的 `process_stereo_chain` 为准**。

```text
输入
 │
 ├→ 前级：gate(+deesser) · filter · bassmono · bass（心理声学）· Stage 0 Pre-DSP 插件
 │     · shelf · dyneq · Stage 1 Pre-Vendor 插件
 ├→ vendor 12 级链（legacy，内部可重排序；立体声/矩阵/双耳混响 = Progenitor2）
 ├→ 后级：Stage 2 Post-Vendor 插件 · haas · spatial · exciter
 ├→ 混响：离散多声道在 exciter 后、Stage 3 前走 MC FDN（`dsp_mc_reverb.cpp`）
 └→ 输出：Stage 3 Post-Reverb 插件 · loudness · Lookahead Limiter → 安全钳位 → Stage 4 Post-Limiter 插件
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
| `spatial` | 参数化 HRTF + 镜像源早期反射（晚期混响由 vendor / MC FDN 承担） |
| `exciter` | 谐波激励器 |
| `loudness` | 等响度补偿（简化 ISO 226） |
| `mc_reverb` | 离散多声道 FDN 混响（`dsp_mc_reverb.cpp`；立体声/矩阵/双耳走 vendor Progenitor2） |

`dyneq` 细节：Low shelf 20–500Hz / Mid bell 200–8kHz / High shelf 2k–20kHz，每段含
`enable / freq / q / gain / range / threshold`，全局 `attack / release`；静态 RBJ + 动态谱减
（与 deesser 同构），位于 shelf 之后、vendor 链之前。

**vendor 12 级链**（`engine/legacy/`，内部可重排序）
`tube`（Triode / Pentode / Tape）· `bass` · `eq`（卷积 EQ）· `comp`（DrDynamic FFT Compander）· `arbmag` · `convolver`（IR 卷积，FileGate 六道门卫）· `ddc`（ViPER DDC）· `liveprog`（EEL2 可编程，专业 IDE + 编译/应用互锁 + EqualizerAPO 转写）· `crossfeed`（bs2b，Chu Moy / Jan Meier）· `stereo`（分带展宽）· `reverb`（SF 预设）· `post` + `limiter`

**插件宿主**（`engine/plugins/`）
VST3 / CLAP / VST2，4 插槽 × 5 级插入拓扑（Pre-DSP / Pre-Vendor / Post-Vendor / Post-Reverb / Post-Limiter）。挂载即旁路，解旁路才进链；64 位插件走进程内，32 位插件按 PE 头位数自动路由到 `plugin_host_x86` 位桥（含跨进程窗口嵌入）。进程外宿主为 opt-in。VST2 扫描只做 PE 快扫（不在引擎进程 `LoadLibrary` 未知插件），真实元数据由加载路补齐；32 位 VST2 深扫由位桥宿主代查。

> 完整参数语义以 `engine/auradsp_engine.h` 参数表 + `graph.effects` 注册表为准 —— **以代码为准，不全信文档**。

Voicemeeter 桥（`bridge/vm_bridge` + `02_voicemeeter_client`）按路处理：回调内每 8 声道一组建独立引擎，插件可按总线勾选/旁路；超预算自动保护会持续超限时把插件收窄到监听总线（EMA < 50% × 6s 自动恢复，手动改掩码立即让位 + 60s 冷却），插件页如实显示「部分旁路」。组间并行（Z17）把各组 DSP 发布给常驻 worker 池，单回调墙钟从 Σ(8 组) 压到 ≈ max(单组)，`AURA_VM_PARALLEL=0` 可退回串行对账。

---

## 4. 近期里程碑

| 日期 | 内容 | 提交 |
|---|---|---|
| 2026-11-05 | **全项目深度审查结案（S0–S8）**：驱动 / 引擎 / 插件 / App / 跨组件五面全审，7 条发现全闭环——VAIO 内核环拷贝改内核真值几何（P0）、控制设备 SDDL 收紧 + 独占映射防劫持（真机反劫持 170/5 双拒实证）、Linux 输出端点死亡自动恢复、虚拟 sink 生命周期治理、参数 SSOT 三处对齐、VST3 预置读入上限、文档原子写 + 坏档隔离；CI 八 job 全绿 | 见 `docs/30-审查/全项目深度审查方案与报告-2026-11-05.md` |
| 2026-11-04 | Linux 插件编辑器 GUI（X11）：运行时 dlopen libX11 窗口层 + 最小 XEmbed 宿主，CLAP/VST3/VST2 三格式编辑器对等开放；配套代码审查修复 X 错误处理器缺失（F1）等 5 项，CI 全绿 | 见 `docs/10-架构/Linux编辑器GUI评估-2026-11-04.md` |
| 2026-11-05 | 效果器延迟计算全域统一与 DAW 工控级监视舱重构（消除 AI 味）：① 定义 5 态延迟模型（实测/参数推算/测定中/零延迟/未测定）与全局统一色彩规范映射；② 测定路径唯一化，统一经由异步安全管道派发并反哺全链总延迟；③ 右上角彻底废弃悬浮药丸与呼吸光晕，重构为专业 DAW 一体化深灰金属切面主状态总控舱（MasterStatusConsole），配备 5.5px 纯净固态硬件 LED 与等宽 Monospace PDC 延迟仪表 | 见 `docs/40-回顾/处理链全流程复合频响测量与科幻信号流全景重构-2026-11-05.md` |
| 2026-11-05 | 处理链全流程复合频响测量与科幻信号流全景重构：① 顶部集成 EqualizerAPO 风格全流程复合曲线/折线频谱图（256 点纯内存解析传递函数，支持立体声/左/右声道及 Voicemeeter A1~Ax 总线动态切换，静音测量与延迟反哺）；② 全局信号流卡片全面升级为未来科技感交互面板（HUD 展开动效、PCB 电路板背景与流光粒子、Stage 0~4 插件芯片插槽实时嵌入、重绘科技能量流光箭头、支持自由平移缩放与 100% 复位） | 见 `docs/40-回顾/处理链全流程复合频响测量与科幻信号流全景重构-2026-11-05.md` |
| 2026-11-05 | 插件界面视觉降噪与规范收敛：移除第三方效果器库副标题说明文字，彻底移除底部 M1 插件宿主引擎规范整卡 | `2e2595e` |
| 2026-11-05 | 插件体系健壮性专项治理：① 修复高阶 Ambisonics 64 通道越界写栈崩溃与音频死循环；② 落地非有限值（NaN/Inf）全通道过滤清洗与钳位防护，根除插件异常导致引擎静音；③ VST2 支持自适应动态重设尺寸与边框自由拖动；④ 修复 Linux CLAP 定时器派发消灭黑屏；⑤ 探测无界面插件提示纯算法 Headless；⑥ 修复 Linux 32 位位桥打包路径搜索失败；⑦ 跨格式统一隔离黑名单；双平台 64/32 位门禁全绿 | 见 `docs/40-回顾/插件健壮性治理与多通道拓扑优化-2026-11-05.md` |
| 2026-11-01 | Linux 移植第一期（`feature/linux` 分支）：引擎 Linux 目标（导出集与 `.def` 恒等）、App PulseAudio 输出闭环、CI 七 job 双流水线全绿、Linux 测试套件补强（冒烟 PASS 9 / Dart 57 PASS + 4 平台跳过） | `61bca64` `017b2eb` `b80eaeb` `d94f2ff` |
| 2026-11-02 | Linux 移植一期收官：三模式功能对等（S5a）、桌面体验（S5b：XDG/托盘/自启/MPRIS）、治理收尾（S5c）与全增量代码审查；Ubuntu 24.04 真机轮次修复输出泵饿死、snd-aloop 回环源、Impeller 重绘损坏三项真机问题；冒烟 PASS 12 / Dart 59 PASS + 4 平台跳过、CI 七 job 全绿，`feature/linux` 合入 `dev` | `c9c0524` `4524e08` `8193b72` `d07650f` `0d79cd3` PR #21 |
| 2026-11-02 | Linux 二期 ALSA 专家模式（D-6 二期立项交付）：libasound FFI 直连（period 256/buffer 1024）、后端设置切换、driver 直采 hw:Loopback、设备枚举与新门禁（冒烟 PASS 13） | `6f5b5f6` `dd48c1e` `0924c36` |
| 2026-11-03 | VST2 64/32 位适配：Xaymar 净室头收编、VST2 驱动/实例/编辑器/预设、32 位 IPC 远程深扫、自建探针与 77 项断言 × 进程内/外双路径全绿 | 见 `docs/20-执行/VST2插件适配实施计划-2026-11-03.md` |
| 2026-11-02 | Linux 二期插件宿主全量（D-7 二期立项交付）：引擎插件层默认开启、VST3/CLAP 进程内托管、POSIX 双宿主隔离（shm 环 + Unix socket IPC）与 32 位桥路由；CI 八 job 全绿且 J3 日志实证 x86 桥活体全链（跨位数环形峰值 0.4） | `e76ba16` `f6a1f4a` `b369016` `e553382` `6d99392` |
| 2026-11-02 | Linux 打磨三期 + 安全/边界审查：ALSA 采集率一致性与协商校验、失败原因与采集中断状态送达 UI、ALSA 采集设备设置入口与枚举治理；安全审查修复 IPC 对端认证（SO_PEERCRED + socket 0600）、FFI 回调字符串防护、数值边界与 /tmp 日志链接防护共 8 项（冒烟 PASS 14 / SKIP 126 / FAIL 0） | `2b2c150` `c7f2213` `e1f541b` `fb10200` |
| 2026-10-28 | 预设系统 v7：路由/设备端点移出预设（不再被载入预设清空）、`defaults.json` 与出厂预设键集常驻门禁、导入版本闸门与同名改名 | `9494ecd` `edac88e` |
| 2026-10-28 | 插件扫描目录改版（平台预置、可勾选、异步深扫）+ 深扫挂死防护（进程内 2.5s / 进程外 IPC 超时杀宿主） | `c44228c` |
| 2026-10-28 | 挂载即旁路（治理「UI 显示旁路但实际不旁路」）+ 插件界面在旁路槽不再假装有音频流 | `fc2054c` |
| 2026-10-27 | VB 桥加载期卡顿根治：fan-in 预算感知截止 + 加载期旁路 + 泵线程提优先级 | `ca1b7b5` |
| 2026-10-24 | 全仓审查与硬置入排查：运行时真特判 **0 处**，5 个 P0 / 9 个 P1 全闭环 | 见 `docs/30-审查/` |

---

## 5. 快速开始

**环境要求**

| 依赖 | 版本 / 说明 |
|---|---|
| Windows | 10 / 11（驱动套件仅 Windows） |
| Visual Studio | 2026 + MSVC x64，C++20（`build_engine.sh` 用 `-G "Visual Studio 18 2026"`） |
| CMake | 随 VS 附带即可 |
| Flutter | 3.47.9（当前基线），需启用 Windows desktop；`flutter doctor` 全绿 |
| Python | 3.10+（冒烟测试与 `tools/bin` 门禁脚本） |

**桌面引擎**（产物 `core/desktop/windows/out/Release/auradsp_engine.dll`，脚本会自动同步多副本）

```powershell
# 统一入口（M3）：同一棵构建树 build/windows/x64，产物仍写回各子工程 out/<Config>/
cmake --preset windows-x64
cmake --build --preset windows-x64-release --target auradsp_engine auradsp_plugin_host
# 未装 Steinberg ASIO SDK 时：cmake --preset windows-x64 -DAURADSP_BUILD_BRIDGES=OFF
```

```bash
cd core/desktop/windows && bash build_engine.sh
# 等价（子工程单独配置）：cmake -S . -B out && cmake --build out --config Release
```

**Linux 桌面**（一期已合入 `dev`；环境与 CI 同口径，见 `.github/workflows/ci.yml`）

```bash
# 依赖：clang/cmake/ninja-build/pkg-config/libgtk-3-dev（Flutter 官方清单）
#       + gcc/g++（引擎）、pulseaudio（运行时出声与 pulse 门禁）
cmake --preset linux-x64
cmake --build --preset linux-x64-release     # 产物 core/desktop/linux/out/Release/libauradsp_engine.so
cd app/auradsp_app && flutter build linux --release --no-tree-shake-icons
python tools/sync_artifacts.py               # 产物同步（跨平台，替代原 PS1 实现）
```

**UI 应用**（`--no-tree-shake-icons` 必须带，否则图标被裁）

```powershell
cd app/auradsp_app
flutter build windows --release --no-tree-shake-icons
flutter analyze
python ../../tools/bin/run_dart_tests.py      # T-03：按文件串行 + 失败单文件重试两次（全量并发不可信）
```

**测试与工具**

```powershell
python test/runner.py --smoke                 # 引擎冒烟（统一入口，143 项登记，按平台自动切换）
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
├── app/auradsp_app/         Flutter 3.47.9 · 203 个 dart（不含 l10n 生成）· 21 张效果卡
├── test/
│   ├── smoke/                       146 个脚本（137 个 smoke_*.py + 9 个探针/专用）；runner 登记 143 项
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
| Dart 单测 | `python tools/bin/run_dart_tests.py` | 74 个测试文件（CI 口径 70 通过 + 4 平台跳过）；按文件串行 + 失败单文件重试两次（全量并发不可信）；Windows 范式专属 4 文件在非 Windows 主机显式 SKIP-PLATFORM |
| 引擎冒烟 | `python test/runner.py --smoke` | 143 项：DSP 正确性、插件生命周期、桥 ABI、竞态；平台标记（PLATFORM_WINDOWS / PLATFORM_LINUX）按开发平台自动切换 |
| ABI 一致性 | `python tools/bin/abi_consistency.py` | `.def` ↔ 头文件 ↔ `ffi.dart` ↔ `.map`（Linux version script）四处符号与签名 |
| CI | `.github/workflows/ci.yml` | 八 job：静态门禁 / Linux 引擎构建 / Linux 冒烟 / ABI / Windows 构建 / Dart 测试 / 资源守卫 / Linux App 打包与无头启动，push 与 PR 均触发 |
| DLL 副本同步 | `python tools/bin/verify_dll_copies.py --sync` | 三处副本哈希一致（禁手拷） |
| 补丁编号 | `python tools/bin/patch_id_scan.py` | `P-NNN` 唯一、单调、已登记、别名不歧义 |
| 静默异常 | `python tools/bin/dart_swallow_scan.py` | 空 `catch` 必须留痕或标注理由 |
| 硬编码中文 | `test/l10n_cjk_guard_test.dart` | 棘轮：`lib/features` + `lib/ui` 基线只降不升 |

最近基线（2026-11-05，全项目深度审查结案轮）：analyze 零问题、Dart 单测 70 文件 PASS / FAIL 0、
引擎冒烟 Linux 口径 PASS 14 / SKIP 129（Windows 专属）/ FAIL 0、GitHub CI 八 job 全绿
（run 42025227808，含 J3 的 x86 桥活体实证与 J6 全量 Dart 测试）。深度审查 7 条发现已全部
闭环（内核 P0 含真机 WDK 构建与双 VM 实测、控制设备防劫持含真机反劫持脚本实证）；
`feature/linux` 待 owner 合入 `dev`。

---

## 8. 文档入口

| 文档 | 定位 |
|---|---|
| [`AGENT.md`](AGENT.md) | **智能体协作总纲**：铁律 / 目录规范 / 命令速查 |
| [`CLAUDE.md`](CLAUDE.md) | 精简版构建与测试命令 |
| [`docs/README.md`](docs/README.md) | **`docs/` 导航入口**（完整索引） |
| [`docs/00-总览/项目架构与开发规范.md`](docs/00-总览/项目架构与开发规范.md) | **工程唯一真相源**：目录约定 / 分层 / 构建规范 / 已验证决策表 |
| [`docs/00-总览/产品架构总览.md`](docs/00-总览/产品架构总览.md) | **产品与品牌真相源**：命名体系 / 形态矩阵 |
| [`docs/30-审查/全项目深度审查方案与报告-2026-11-05.md`](docs/30-审查/全项目深度审查方案与报告-2026-11-05.md) | **最近一轮全量审查（已结案）**：驱动 / 引擎 / 插件 / App / 跨组件五面 + 7 条发现修复与复审台账 |
| [`.ai/memory/MEMORY.md`](.ai/memory/MEMORY.md) | **项目长期备忘**：既定范式 / 避坑 / 测试 SOP（入库的唯一记忆真相源） |
| [`docs/源码重组与目录规范方案-2026-10-13.md`](docs/源码重组与目录规范方案-2026-10-13.md) | 目录重组的诊断 / 目标树 / 政策 / 分期 |
| [`docs/40-回顾/处理链全流程复合频响测量与科幻信号流全景重构-2026-11-05.md`](docs/40-回顾/处理链全流程复合频响测量与科幻信号流全景重构-2026-11-05.md) | 处理链全流程复合频响测量（EqualizerAPO风格）与科幻信号流全景重构 |
| [`docs/40-回顾/阶段性回顾-2026-10-13.md`](docs/40-回顾/阶段性回顾-2026-10-13.md) | 重构 P0→P3b 与功能交付回顾 |

架构决策记录见 `docs/adr/`：ADR-001 / 003 / 004 / 006 / 007 / 008 / 009 已接受，ADR-002 已被 ADR-006 取代（原文留档）。

---

## 9. 许可证与致谢

- 引擎核心衍生自 [JamesDSP](https://github.com/james34602/JamesDSPManager)（libjamesdsp，2026-10-16 起收编于 `engine/legacy/`），遵循其上游 GPL 系许可证；所有补丁登记在 `engine/legacy/PATCHES.md`。
- 第三方插件 API（`vendor/plugin-api/`：CLAP / Steinberg VST3 / VST2 Xaymar 净室头）遵循各自许可证；VST2 仅以 BSD-3-Clause 净室头编译，Steinberg 官方 2.4 归档不入库、不分发。
- 第三方参照项目以只读快照置于 `source/`（不入库），提取与版本溯源见 `source/ORIGIN.md` 与 `vendor/ORIGIN.md`。
- 运行资源（IR / VDC / Liveprog 脚本）来自上游社区，清单见 `assets/manifest.json`。
