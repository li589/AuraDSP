# ADR-012：Linux 平台三项产品语义裁定与分支策略

> **状态：已接受**（2026-11-01，owner 裁定）
> **关联**：[Linux 适配方案-2026-11-01](../10-架构/Linux适配方案-2026-11-01.md) ·
> [跨平台基础框架与平台依赖剥离方案-2026-10-29](../10-架构/跨平台基础框架与平台依赖剥离方案-2026-10-29.md) ·
> [跨平台基础审查-2026-11-01](../30-审查/跨平台基础审查-2026-11-01.md)

---

## 1. 背景

《Linux 适配方案-2026-11-01》完成三轴只读取证后，就三项**产品语义**（目标用户、延迟取舍、功能范围）
提交待裁定项 D-5 / D-6 / D-7。按既定规矩，这类决定不由工程侧单方拍板，须 owner 裁定后落
**ADR + 门禁 + 文档**。

owner 于 2026-11-01 裁定三项，并同时确定 **Linux 开发的分支策略**。

---

## 2. 裁定

### D-5 —— Linux 音频后端选项集：**追求功能对等**

Linux 上保留与 Windows 同构的三种模式语义，**不裁剪、不留空壳**：

| 模式 | 语义 | 实现落点 |
|---|---|---|
| `system` | App 自己持有输出设备 | 设备栈（D-6 选定的 PulseAudio simple API） |
| `virtual` | 虚拟 sink 设备 | PulseAudio `module-null-sink`（`pactl load-module module-null-sink sink_name=…`） |
| `driver` | 内核态虚拟声卡 | Linux 主线已有的 **`snd-aloop`** 内核模块（`modprobe snd-aloop index=2 enable=1,1`），AuraDSP 绑定 `hw:Loopback,N` |

**理由（owner 认可）**：Linux 用户期望与 Windows 同等的能力矩阵，砍成单一 `system` 会让 Linux 版
在功能对等上长期落后，且后续补 `virtual` / `driver` 仍要改动 `composeMode` 与设置页的语义骨架。

> **对方案原估算的修正（实测）**：本方案 §1.3 原写「`driver` 需内核态开发，不建议塞进首期」——
> **该估算偏重**。实测核实：Linux **主线内核已自带**虚拟声卡模块 `snd-aloop`（`alsa-km`，主线 2.6 起），
> 且 PipeWire 的 ALSA 拦截层（`libpipewire-module-alsa-card` 扫描 `/proc/asound/cards`）会把它
> 自动暴露为 `pw-loopback-source/sink` 并以 PulseAudio 兼容 sink/source 呈现。
> ⇒ **`driver` 模式无需自研内核模块**，是「模块加载 + ALSA 绑定 + 持久化配置」问题；
> ⇒ **`virtual` 模式亦无需引入原生 libpipewire**，`module-null-sink` 在原生 PulseAudio 与
> `pipewire-pulse` 上都可用 ⇒ **D-5 的三条路径全部落在 D-6 选定的 PulseAudio 栈上**，不引第二套音频 API。

### D-6 —— Linux 音频栈选型：**PulseAudio simple API 优先**

- **首选**：PulseAudio **simple API**（`libpulse-simple.so`），Dart 侧 FFI 直调。
  - 理由：`AudioOut` 端口（`app/auradsp_app/lib/engine/audio_out/audio_out.dart:8-33`）是
    WASAPI 形状的**拉**模型（`write(src, frames)` + `currentPadding()`），simple API 同样是拉模型
    ⇒ **可 1:1 对接，无需模型倒置**；且全发行版可用（PipeWire 自带 PA 兼容层）。
- **后续**：ALSA 直连作为**低延迟专家模式**（第二期），首期不做。
- **不做**：原生 libpipewire API（推模型需环形缓冲倒置，且 RT 线程回调进 Dart VM 未实测）。

**实现期必须注意的运行时事实**（Ubuntu 22.04+ 等 PipeWire 主导环境）：

- 实际承担 PulseAudio 协议的是 `pipewire-pulse`；若该服务未运行，**PulseAudio API 调用会静默失败**
  （`pactl` 仍可用但发现不到新设备）⇒ 实现须把「PA 连接失败」与「无设备」区分成两种错误码。
- PipeWire 主导环境下 **`~/.config/pulse/default.pa` 不被读取**；生效的是
  `/usr/share/pipewire/pipewire.conf.d/90-enable-alsa.conf` 与 `pipewire-pulse` 的设备发现机制
  ⇒ 诊断路径须区分「原生 PulseAudio」与「PipeWire 兼容模式」两条。
- 实时优先级由 **rtkit** 托管，不自行 `sched_setscheduler`；XRUN 监控用 `pw-top` / PA underflow 计数。

### D-7 —— Linux 首期的插件能力边界：**只做插件消费者，并隐藏 Linux 插件目录 UI**

- Linux 首期**不做** VST3/CLAP **宿主**（沿用 `AURADSP_ENABLE_PLUGINS=OFF` 整体裁掉，
  引擎编入 `plugin_chain_adapter_stub.cpp` / `plugin_abi_stub.cpp`；实测该 stub 与真实实现
  **C ABI 56 符号全等**，导出集契约不破）。
- Linux 首期**不做**把 AuraDSP 自身导出为 LV2 / CLAP 插件（属全新产品形态，需独立立项）。
- **必须隐藏 Linux 的插件目录 UI**：`app/auradsp_app/lib/platform/plugins/plugin_dirs_desktop.dart:34-51`
  当前会列出 `/usr/lib/vst3`、`/usr/local/lib/clap` 等目录，而宿主是 Windows-only
  （`platform_profile.dart:25`）⇒ 现状是「能看不能用」。裁定要求：**首期在 Linux 上不展示插件目录**，
  消除预期落差。

---

## 3. 分支策略（2026-11-01 owner 裁定）

```
feature/linux  ──(Linux 代码，验证通过)──▶  dev  ──(dev 验证合并后，dev 决定)──▶  main
```

| 阶段 | 承载内容 | 合并判据 |
|---|---|---|
| `feature/linux` | **仅 Linux 开发**（引擎 Linux 目标、端口实现、App 侧 Linux 适配、Linux 门禁） | 代码**验证通过**（Linux 构建 + smoke + ABI 门禁全绿） |
| `dev` | 集成验证 | dev 侧验证合并后**再由 dev 决定**是否合并 |
| `main` | 发行主分支 | 由 `dev` 决定，非自动 |

**约束**：

1. `feature/linux` 从 `dev` 切出，**不得**直连 `main`；合并方向单向 `feature/linux → dev → main`。
2. `main` 的合并不由 `feature/linux` 触发，须经 `dev` 验证后由 `dev` 侧决定。
3. 本 ADR 与 Linux 方案文档等**决策记录**走 `dev → main` 的常规 PR 路径（不属 Linux 代码）；
   **代码**一律走 `feature/linux`。
4. 分支命名：`feature/<主题>`；本次为 `feature/linux`。

---

## 4. 后果

### 4.1 正面

- Linux 版能力矩阵与 Windows 对齐（`system` / `virtual` / `driver` 三模式齐备），不欠功能债。
- `driver` 模式复用主线内核 `snd-aloop`，**不写内核代码** ⇒ 风险与工期远低于自研虚拟声卡。
- 首期不引第二套音频 API（不碰原生 libpipewire）⇒ 音频栈只有 PulseAudio 一套，诊断路径单一。

### 4.2 需要承担的代价（owner 已知悉并接受）

| 代价 | 说明 | 缓解 |
|---|---|---|
| Linux 侧工作量增加 | 三模式齐备 ⇒ 需要 `virtual` 与 `driver` 两条新路径 + 对应的模式语义收敛 | 拆为 S5a / S5b / S5c 三期，各自独立可提交 |
| `snd-aloop` 需 root 加载 | `modprobe snd-aloop` 需特权 | ① 文档化一条命令；② 提供 udev 规则或 `modules-load.d` 持久化；③ 首期可**降级**：未加载时 `driver` 模式显示「需先加载 snd-aloop」而非报错 |
| `module-null-sink` 需用户级 `pactl` | 需调用 PA 控制接口 | 走 `libpulse` 的 `pa_context` 查/加载模块（不必 fork `pactl`） |
| `pipewire-pulse` 未运行时静默失败 | PA API 调用无显式错误 | 实现期把「连接失败」与「无设备」分成两个错误码，并写入诊断日志 |
| 插件目录 UI 隐藏 ⇒ Linux 首期插件能力为 0 | 用户在 Linux 上无法使用任何 VST3/CLAP/LV2 插件 | 属首期**已知取舍**；后续立项补 formats 层 Win32 剥离 + ELF 元数据端口（CP-24） |

### 4.3 门禁（待 `feature/linux` 落地）

本 ADR 的门禁在 `feature/linux` 分支随实现落地（**本轮不改代码**）：

| 门禁 | 断言 |
|---|---|
| `smoke_linux_source_table.py` | Linux 源表可编译闭包：不含 `jamesdsp.c`、不引 Win32 头、`-include stdint.h` 生效 |
| `abi_consistency.py`（扩展） | Linux version script 符号集 == `engine/auradsp_engine.def` 的 56 符号 |
| `smoke_audio_modes_linux.py` | Linux 三模式 id（`system`/`virtual`/`driver`）均能由 `composeMode()` 产出且语义不落到 Windows id；设置页不出现 Windows 专有选项 |
| `smoke_linux_plugin_ui.py` | Linux 上插件目录 UI 不展示（`plugin_dirs_desktop.dart` 的 Linux 分支被条件关闭） |

---

## 5. 变更影响清单

| 对象 | 影响 |
|---|---|
| `app/auradsp_app/lib/core/audio_modes.dart:67,121-136` | 三个 Linux id 需真正可由 `composeMode()` 产出（当前是语义死路） |
| `app/auradsp_app/lib/features/settings/settings_audio_tab.dart:36-37,55-60,77-82` | 改为按 OS 过滤 + 渲染 Linux 三模式 |
| `app/auradsp_app/lib/platform/plugins/plugin_dirs_desktop.dart:34-51` | Linux 分支按 D-7 关闭 |
| `app/auradsp_app/lib/engine/audio_out/` | 新增 `audio_out_linux.dart`（PulseAudio simple API）+ `createAudioOut()` 按 OS 分派 |
| `app/auradsp_app/lib/platform/platform_profile.dart:25,32` | `supportsPlugins` 在 Linux 恒 false；`supportsLocalDevice` 扩为 Windows \|\| Linux |
| `engine/platform/linux/` | 新增 4 个端口实现（`fs`/`env`/`log`/`module`） |
| `engine/auradsp_engine.map`（新） | Linux version script，由 `.def` 同源生成 |
| `core/desktop/linux/`（新） | Linux 构建目标 + `build_engine.sh`（Ninja，去 `pwd -W`） |
| `CMakeLists.txt:20-24` | 加 `if(NOT WIN32)` 分支 |
| `CMakePresets.json:18-23,32-43` | `linux-x64` 转正 + 补 `linux-x64-release` / `-debug` |
| `test/runner.py:30-46` | `PLATFORM_ANY` 改默认允许 + 显式 Windows 标记（消除假绿） |
| `tools/bin/verify_dll_copies.py:19` | 去掉硬编码本机路径 |
| `.github/workflows/`（新） | 7 个 job（静态门禁 / Linux 构建 / Linux smoke / ABI / Windows 构建 / Dart 测试 / 资源守卫） |

---

## 6. 本轮边界

**本 ADR 只记录裁定，不含任何代码实现。** 代码实施全部在 `feature/linux` 分支上进行，
按 [Linux 适配方案](../10-架构/Linux适配方案-2026-11-01.md) §4 的 S0~S5c 分期推进，
每期独立提交、验证通过后合入 `dev`；`dev` 验证合并后由 `dev` 决定是否合入 `main`。
