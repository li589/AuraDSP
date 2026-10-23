# AuraDSP

> 跨平台全局音频效果系统 · Cross-platform Global Audio Effects
> Flutter 统一界面 + AuraDSP Engines 引擎族（自研 DSP + vendor 算法 + 平台音频适配）

**AuraDSP** 是一套自下而上的跨平台音频效果栈：桌面为 Windows 进程内 WASAPI 泵 + 本地 DLL 引擎；Android 以 AIDL effects HAL 注入系统音频链路（Enforcing 下端到端已跑通，KSU 模块持久化）。UI 用 Flutter 一套代码，驱动层与 DSP 算法通过 **C ABI（`engine/auradsp_engine.h`）** 解耦——UI 不感知引擎形态与所在进程。

---

## 1. 当前形态矩阵

| 形态 | 平台 | 方式 | 状态 |
|---|---|---|---|
| **Desktop** | Windows 11 | 进程内 WASAPI 泵 + `auradsp_engine.dll`（DLL 进程内 FFI） | ✅ 主力（全功能） |
| **Root** | Android (KSU/Magisk) | AIDL effects HAL 注入，系统级全局 | ✅ 端到端打通 + 重启持久化 |
| **Rootless** | Android APK | 会话级 AudioEffect 前台服务（Phase 6） | ⬜ 蓝本见 `source/RootlessJamesDSP` |
| **Linux** | PipeWire/Pulse | filter-chain 模块化挂载（Phase 7） | ⬜ 蓝本见 `source/JDSP4Linux` |

> **音频后端模式**（`app/auradsp_app/lib/core/audio_modes.dart`）：Windows 侧四模式 `vaio`（AuraVAIO 虚拟声卡）/ `vbcallback`（Voicemeeter 回调）/ `sysapo`（System APO，默认）/ `asio`（专业 ASIO）；Android `root`/`rootless`。`vbcallback`/`asio` 已支持活切；`vaio`/`sysapo` 选择持久化，VAIO 驱动已点亮、sysapo 回归纯配置面。驱动侧对应实现见 `core/desktop/windows-drivers/`（01 VAIO / 02 VM 泵 / 03 自研 APO / 04 ASIO 双线 / bridge 三桥）。

---

## 2. 仓库结构（2026-10-20；P3a/P3b 顶层化 + P4b 引擎子目录化 + P1 插件目录迁移后）

> P3a/P3b 已把引擎、第三方、资源三块提到顶层：
> `core/desktop/engine_api` → **`engine/`**、`core/desktop/vendor-src` → **`vendor/`**、`resource/` → **`assets/`**。
> P4b（`cec8064`）把引擎的链/IO 与插件宿主文件收进 `chain/` 与 `host/` 子目录（纯移动）；
> P1（2026-10-20）再把插件宿主从 `host/` 迁到 `plugins/` 分层目录（纯移动）。

```text
AuraDSP/
├── engine/              # ★ 桌面引擎（C++20，MSVC）
│   ├── auradsp_engine.{h,cpp,def}   # C ABI 契约（UI↔驱动唯一边界）
│   ├── engine_internal.h            # 私有状态 + 跨文件符号（内部单一入口）
│   ├── chain/                       # 链与 IO：engine_{chain,convolver,viz,probe,audiofile}.cpp
│   ├── dsp/                         # 11 个自研效果 TU（每效果一文件，含 dyneq/spatial）
│   ├── plugins/                     # 插件宿主：api/plugin_host.h + driver/ + formats/ + platform/win32/ + integration/ + tests/（四插槽 kMaxPluginSlots=4）
│   └── legacy/                      # JamesDSP C 算法核（12 级经典音效 + EEL2）+ PATCHES.md
├── vendor/              # ★ 第三方行业标准只读（CLAP / VST3 官方接口头，原样未改）
│   └── plugin-api/      #   clap / steinberg(vst3)
├── assets/              # ★ 运行资源（原 resource/，P3b 迁来的 251MB）
│   ├── convolver/ ddc/ liveprog/  + manifest.json
├── core/
│   ├── desktop/windows/ # CMakeLists + build_engine.sh → out/Release/*.dll（DLL 真相源）
│   ├── desktop/windows-drivers/  # Windows 底层驱动套件（独立 CMake）：01 VAIO / 02 VM 泵 / 03 自研 APO / 04 ASIO 双线 / bridge 三桥
│   └── android/         # registrar / spike-global-effect / stubs / vendor-src
├── app/auradsp_app/     # Flutter 3.47.7（92 个 dart，21 张效果卡；音频后端四模式已接通/持久化）
├── test/
│   ├── smoke/           # 79 个 smoke_*.py；runner.py --smoke 登记 84 项（78 smoke + 6 辅助/基准）
│   │                    #   smoke_three_key_plugins.py 需人工值守，刻意不挂载
│   └── ui/              # 14 个 UI 脚本；runner.py --ui 默认跑 7 个
├── tools/               # bin/ 10 · probe/ 17 · resource_pipeline/ 2 · calibration/ 1 · archive/
├── source/              # 第三方参考仓库只读快照（15 项 ORIGIN 登记 / 14 个顶层克隆）
├── docs/                # 00-总览 10-架构 20-执行 30-审查 40-回顾 90-归档
│   └── 参考技术手册/     #   第三方 PDF 手册本地只读区（约 220MB，仅 README 清单入库）
└── .ai/                 # AI 自治沉淀区（memory/rules）
```

---

## 3. 内置音效器

处理链（`engine/chain/engine_chain.cpp` 的 `process_stereo_chain`）大致顺序：
**输入增益 → gate/deesser → filter → bassmono → 心理声学低音 → 插件 Pre-DSP → low-shelf → 动态EQ → vendor 链 → Haas → Spatial → Exciter → Freeverb → Loudness → Lookahead Limiter → 安全钳位 → 插件 Post-Limiter**

### 自研（`engine/dsp/`）
| ID | 效果 | ID | 效果 |
|---|---|---|---|
| `gate`+`deesser` | 噪声门 + 齿音消除 | `freeverb` | 参数化混响（Schroeder-Moorer） |
| `filter` | 独立 HP/LP/BP biquad | `loudness` | 等响度补偿（简化 ISO226） |
| `bassmono` | 低频单声道化 | `psycho` | 心理声学低音（MaxxBass 式谐波） |
| `haas` | Haas 差分环绕 | `shelf` | 低频搁架 biquad |
| `exciter` | 谐波激励器 | `dyneq` | 全参数动态 EQ（3 段，见下） |
| `spatial` | 参数化 HRTF + 镜像源早期反射 + FDN 晚期 | | |

`dyneq` 为三段全参数动态 EQ：Low shelf（20–500Hz）/ Mid bell（200–8kHz）/ High shelf（2k–20kHz），
每段含 `enable/freq/q/gain/range/threshold`，全局 `attack/release`；静态 RBJ + 动态谱减（与 Deesser 同构），
位于 low-shelf 之后、vendor 链之前。

### legacy 链（原 `libjamesdsp`，2026-10-16 收编至 `engine/legacy/`，内部 12 级可重排序）
`tube`（Triode/Pentode/Tape 三音色 + 干湿 + 补偿）· `bass` · `eq`（卷积 EQ）· `comp`（DrDynamic FFTCompander）· `arbmag`（任意幅度 EQ）· `convolver`（IR 卷积，带 FileGate 六道门卫）· `ddc`（ViPER DDC）· `liveprog`（EEL2 可编程）· `crossfeed`（bs2b，含 Chu Moy / Jan Meier 模式）· `stereo`（分带展宽）· `reverb`（SF 预设）· `post`+`limiter`（输出级）

### 插件宿主
VST3 / CLAP 64 位进程内宿主，4 插槽 × 5 级插入拓扑（Pre-DSP / Pre-Vendor / Post-Vendor / Post-Reverb / Post-Limiter）。

> 完整效果清单与宣传口径以 `engine/auradsp_engine.h` 参数语义表 + `graph.effects` 注册表为准（**以代码为准，不全信文档**）。

**Voicemeeter 桥按路处理**（`bridge/vm_bridge` + `02_voicemeeter_client`）：VM 回调内每 8 声道一组建独立引擎，插件可按总线（路）勾选/旁路；Z12 超预算自动保护在回调持续超预算时把插件收窄到监听总线（EMA<50%×6s 恢复，手动改掩码立即让位 + 60s 冷却），插件页「生效中」按钮诚实显示「部分旁路」态。进程外插件宿主 opt-in：`AURA_PLUGIN_HOST_MODE=process`。

---

## 4. 快速开始

### 桌面引擎（Windows）
```bash
# MSVC Release 构建，产物 core/desktop/windows/out/Release/auradsp_engine.dll
cd core/desktop/windows && bash build_engine.sh
# 或：cmake -S . -B out && cmake --build out --config Release
```

### UI 应用
```powershell
cd app/auradsp_app
flutter build windows --release --no-tree-shake-icons   # 必须带该参数
flutter analyze
flutter test --concurrency=1
```

### 测试与工具
```powershell
python test/runner.py --smoke                 # 引擎 ctypes 冒烟（统一入口）
python test/runner.py --ui                    # UI 自动化（强制置顶前置）
python tools/bin/verify_dll_copies.py --sync  # DLL 多副本哈希同步（禁手拷）
python tools/bin/abi_consistency.py           # .def / engine.h / ffi.dart 三处符号一致
python tools/bin/run_tests.py --smoke         # 转发 runner.py
```

> `tools/probe/*` 为一次性探针（用完归档，不进门禁）；`tools/archive/` 为过程产物（gitignored）。

---

## 5. 文档入口

| 文档 | 定位 |
|---|---|
| [`AGENT.md`](AGENT.md) | **智能体协作总纲**：铁律 / 目录规范 / 命令速查 |
| [`CLAUDE.md`](CLAUDE.md) | 精简版构建与测试命令 |
| [`docs/README.md`](docs/README.md) | **`docs/` 导航入口**（完整索引） |
| [`docs/00-总览/项目架构与开发规范.md`](docs/00-总览/项目架构与开发规范.md) | **工程唯一真相源**：目录约定 / 分层 / 构建规范 |
| [`docs/00-总览/产品架构总览.md`](docs/00-总览/产品架构总览.md) | **产品与品牌真相源**：命名体系 / 形态矩阵 |
| [`docs/源码重组与目录规范方案-2026-10-13.md`](docs/源码重组与目录规范方案-2026-10-13.md) | 本次重组的诊断 / 目标树 / 政策 / 分期 |
| [`docs/40-回顾/阶段性回顾-2026-10-13.md`](docs/40-回顾/阶段性回顾-2026-10-13.md) | 重构 P0→P3b 与本期功能交付回顾 |

决策记录见 `docs/adr/`（ADR-001/003/004/006/007/008/009 已接受，ADR-002 已被 006 取代）。

---

## 6. 许可证与致谢

- 引擎核心衍生自 [JamesDSP](https://github.com/james34602/JamesDSPManager)（libjamesdsp，2026-10-16 起收编于 `engine/legacy/`），遵循其上游 GPL 系许可证；补丁统一登记在 `engine/legacy/PATCHES.md`。
- 第三方插件 API（`vendor/plugin-api/`：CLAP / Steinberg VST3）遵循各自许可证。
- 第三方参照项目以只读快照置于 `source/`（不入库），提取与版本溯源见 `source/ORIGIN.md` 与 `vendor/ORIGIN.md`。
- 运行资源（IR / VDC / Liveprog 脚本）来自上游社区，见 `assets/manifest.json`。
