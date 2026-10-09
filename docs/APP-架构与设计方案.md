# AuraDSP APP — 架构与设计方案

> 版本：v1.0（2026-10-09）
> 定位：**AuraDSP 跨平台 APP 的完整方案** —— UI 层 / 驱动层分层、引擎形态矩阵、延迟预算、设计系统、Win11 首版落地范围。
> 上游文档：`docs/产品架构总览.md`（产品/品牌真相源）、`docs/项目架构与开发规范.md`（工程真相源）。
> 状态：有效。与本方案冲突的旧描述以本文档为准。

---

## 1. 顶层架构：两大模块 + 一条协议

```
┌────────────────────────────────────────────────────────────────┐
│                     AuraDSP APP（各平台同名）                    │
│                                                                │
│  ┌────────────────────────────┐  ┌───────────────────────────┐ │
│  │  UI 层  auradsp_app        │  │  驱动层  AuraDSP Engines   │ │
│  │  Flutter（一码多端）         │  │                           │ │
│  │  · 状态三态明示              │  │  ┌─────────────────────┐  │ │
│  │  · 参数控制 / 预设           │  │  │ engine_api（C ABI）  │  │ │
│  │  · 可视化（频谱/电平/波形）   │◄─┼─►│ 统一参数 ID + 环形缓冲│  │ │
│  │  · 多语言 / 多配色           │  │  └──────────┬──────────┘  │ │
│  │                            │  │             │              │ │
│  │  形态探测（无感知切换）       │  │  ┌──────────▼──────────┐  │ │
│  │  · Root 引擎在？→ 走控制通道  │  │  │ 引擎核心（源码整合）   │  │ │
│  │  · 否 → 内置 Rootless 引擎   │  │  │ libjamesdsp（纯 C）  │  │ │
│  │                            │  │  └──────────┬──────────┘  │ │
│  │                            │  │  ┌──────────▼──────────┐  │ │
│  │                            │  │  │ 平台适配（驱动/链路）  │  │ │
│  │                            │  │  │ AIDL HAL / WASAPI /  │  │ │
│  │                            │  │  │ APO / PipeWire / CA  │  │ │
│  │                            │  │  └─────────────────────┘  │ │
│  └────────────────────────────┘  └───────────────────────────┘ │
└────────────────────────────────────────────────────────────────┘
```

**三条铁律：**

1. **UI 与引擎只经 Control API（engine_api C ABI + 参数 ID 语义）通信**，UI 不感知引擎在哪个进程、哪种形态。
2. **引擎核心一律源码整合**（`source/` → `core/*/vendor-src/`，ORIGIN.md 逐项溯源），**禁止链接任何预编译组件/闭源 API**。参考实现（EqualizerAPO、pulseeffects、JDSP4Linux 等）只读源码学思路，不链接其产物。
3. **process 路径 RT-safe**：无 malloc / 无锁 / 无 IO / 无日志；可视化数据走 lock-free SPSC 环形缓冲单向推送。

## 2. 引擎形态矩阵（驱动层）

| 平台 | 形态 | 载体 | 注入方式 | 全局性 | 延迟档 | 状态 |
|---|---|---|---|---|---|---|
| Android | **(Root)** | KSU/Magisk 模块 `auradsp_jdsp` | AIDL effects HAL 注入 audio HAL | 系统全局 | HAL 管线 | ✅ v0.4.0 已验证 |
| Android | **(Rootless)** | APK 内置 `.so` | AudioEffect 挂 audio session / 进程内 FFI | 应用会话级 | ≤10ms | Phase 6 |
| **Windows** | **(Desktop)** v1 | `auradsp_engine.dll` + WASAPI 共享模式播放链 | 应用内播放/loopback 链路 | 进程级 | ≤10ms | **← 本次 Win11 首版** |
| Windows | (Desktop) v2 | SFX APO（挂声卡驱动） | APO 注册（需签名） | 系统全局 | in-place | Phase 7b |
| Linux | (Desktop) | PipeWire filter-chain / 脉冲模块 | 会话管理器加载 | 用户会话级 | ≤10ms | Phase 7 |
| macOS | (Desktop) | CoreAudio + AudioUnit | AU 插件/驱动 | 应用级起步 | — | 低优先级 |

**Windows 系统级的诚实结论**（写进决策，不糊弄）：纯用户态无法对"所有应用"做无驱动低延迟处理。全局路径 = SFX APO（需要代码签名，可先走测试签名验证）或虚拟声卡（需要驱动签名）。因此 Win11 首版以**进程级真实链路**交付：内置播放器 → AuraDSP 引擎 → WASAPI 输出，链路真实可听、延迟真实可测，UI 与协议与最终 APO 形态完全一致——APO 只是换掉"音频进引擎的那一截"。

### 2.1 引擎核心选型（源码移植清单）

| 能力 | 来源 | 整合方式 |
|---|---|---|
| DSP 核心（11 效果 + limiter + postGain） | `source/JamesDSPManager/Main/libjamesdsp`（纯 C，含 `_WIN32` 分支） | 提取至 `core/desktop/vendor-src/libjamesdsp/`，ORIGIN.md 登记 |
| Windows WASAPI 链路 | 自研（Win32 WASAPI API，非第三方库） | `core/desktop/windows/` |
| APO 挂载思路（Phase 7b） | `source/equalizerAPO64` **只读参考** | 不链接，只学注册/参数序列化 |
| PipeWire filter-chain 思路（Phase 7） | `source/pulseeffects`、`source/JDSP4Linux` **只读参考** | 同上 |
| 算法对照 | `source/ViPER4Android-FX`、`source/ViPERFX_RE` | 只读参考 |

## 3. Control API（UI ↔ 引擎的统一协议）

引擎侧统一 C ABI（`core/desktop/engine_api/auradsp_engine.h`，Android Rootless 与桌面共用；Android Root 经 AIDL VendorParamId 透传同语义）：

```c
// 生命周期
auradsp_handle auradsp_create(float sample_rate, int max_block);
void auradsp_destroy(auradsp_handle);
// RT 音频（进程内直调；桌面 WASAPI 线程 / Android audio session 线程）
void auradsp_process(auradsp_handle, const float* in, float* out, int frames); // stereo interleaved
// 参数（string ID + POD 值；与 AIDL VendorParamId 语义对齐）
int  auradsp_set_param(auradsp_handle, const char* id, const void* val, uint32_t bytes);
int  auradsp_get_param(auradsp_handle, const char* id, void* out, uint32_t bytes);
// 状态与延迟（UI 三态明示的数据源）
int  auradsp_get_state(auradsp_handle);            // processing | bypass | error
double auradsp_get_latency_ms(auradsp_handle);     // 当前启用组合的附加延迟
// 可视化（lock-free SPSC ring，UI 线程拉取；引擎 RT 线程只写）
uint32_t auradsp_viz_read(auradsp_handle, auradsp_viz_frame* out, uint32_t max);
```

参数 ID 首批（与 Android 已验证的 VendorParamId 对齐并扩展）：`bass.enable/bass.gain/reverb.preset/stereo.mix/eq.enable/eq.bands/post.gain/limiter.enable/crossfeed.amount/tube.enable/convolver.ir/...`

## 4. 商业级延迟预算（48 kHz 基准，1ms = 48 帧）

libjamesdsp 各模块算法延迟实测/推算（代码依据：`jdsp_header.h` FFTSIZE_DRS=8192、`TwoStageFFTConvolver`、`sf_reverb`）：

| 模块 | 算法 | 附加延迟 | 档位 |
|---|---|---|---|
| MultimodalEQ | IIR biquad 级联 | ≈0 | **T0** |
| BassBoost(DBB) | IIR | ≈0 | **T0** |
| VacuumTube | 波形整形 | ≈0 | **T0** |
| StereoEnhancement | 全通/短 FIR | <1ms | **T0** |
| Limiter + PostGain | 前瞻限幅 | 1~5ms | **T0** |
| Crossfeed | FIR 短头 | 2~5ms | **T1** |
| DDC | FIR（冲激长度定） | 数 ms~20ms | **T1** |
| Convolver | IR 卷积 | = IR 长度 | **T2** |
| Reverb | 预延迟 + 梳状 | 20~120ms | **T2** |
| Compressor(FFTCompander) | **FFT 8192 OLA** | **~85–170ms** | **T2（低延迟模式禁用）** |
| ArbMag | FFTConvolver2x2 | 分块延迟 | **T2** |

**三档模式（UI 常显延迟徽标）：**

- **实时**（游戏/直播）：总附加 ≤ 10ms → 只允许 T0，超档效果自动置灰并标注原因；
- **音乐**（默认）：≤ 30ms → T0 + T1；
- **品质**（观影/听感优先）：不设限，允许 T2（reverb/convolver/compressor）。

引擎按当前启用组合实时计算 `get_latency_ms()`；这是"商业水平"的硬验收线：**任何预设保存前引擎拒绝超过所选档位预算的组合**。

## 5. 多声道方案（stereo 引擎 × 声道矩阵）

libjamesdsp 交织路径硬编码 2 声道（`processFloatMultiplexd`），但内部已有多声道 blob 基础（`blobsCh1..4`、`hrtfblobsResampled[4]`）。分两步走：

- **Phase A（本版）：声道矩阵包络** —— 引擎外层实现 M×N 下混/上混矩阵：LFE 直通（不动低频主干），C/SL/SR 按系数并入 L/R 处理后回填。5.1/7.1 全局处理立即可用，UI 提供直通/下混/声道映射三视图。
- **Phase B（后续）**：逐声道实例化（N-1 个 JamesDSPLib 并行实例，LFE 单独直通），需评估 CPU；若需真多声道跨声道效果，再评估 vendor-src 打 `[PATCHED]` 扩展通道数（铁律 §3.3 流程）。

## 6. 可视化与流畅交互

- 引擎侧：每处理块计算 FFT/电平（复用引擎内 Hartley FFT 基础设施），写 SPSC ring——**RT 线程零阻塞**。
- 桥接层：独立读线程批量拉帧 → 降采样至 UI 需要的 60Hz 节奏 → Dart。
- UI：`CustomPaint` + `RepaintBoundary` 隔离重绘；频谱 60fps、电平表 30fps、波形按需。桌面端 Impeller 后端。

## 7. 设计系统（扁平 × 艺术氛围 × 去 AI 味）

真相源：`design/tokens/aura.tokens.json`（W3C Design Tokens 结构），Flutter 侧代码生成 `ThemeData`。

### 7.1 视觉原则

1. **扁平但有不平**：层次靠明度阶梯（底→面板→浮层三级灰阶）+ 1px hairline 描边，**禁用阴影堆叠**；卡片与背景的区分用 4% 明度差 + hairline。
2. **小圆角体系**：6/10/14px 三级，禁止全胶囊大圆角（廉价感主源）。
3. **8pt 网格**：间距 4/8/12/16/24/32/48。
4. **艺术氛围层**：实时频谱作为界面背景元素（低不透明度、单色化），叠加细噪点 grain（程序化生成，非贴图），暗色主题下频谱即"氛围光源"——这是与现代音乐应用气质对齐的核心手法。
5. **数字即设计**：所有数值读数用等宽字体 + tabular figures，延迟徽标、dB 刻度、频点标签全部对齐网格。
6. **图标自绘**：单色几何线性图标（1.5px 描边），不用 emoji、不用 Material 默认图标库的圆润风。

### 7.2 字体（全部 OFL/开源商用，避开 AI 味重灾区字体）

| 用途 | 拉丁 | 中文 |
|---|---|---|
| Display/品牌 | **Bricolage Grotesque** | **得意黑 Smiley Sans**（斜切黑体，音乐海报气质） |
| 正文/UI | **IBM Plex Sans** | **Noto Sans SC** |
| 数值/等宽 | **IBM Plex Mono** | — |

### 7.3 三套配色方案（可切换，默认 Aura Dark）

| 主题 | 底 | 面板 | 文本 | 强调 | 辅助 | 气质 |
|---|---|---|---|---|---|---|
| **Aura Dark**（默认） | `#0E0F13` | `#171A21` | `#E8EAF0` | 酸性绿 `#D4FF3F` | 暖橙 `#FF6B35` | 音乐工程感，暗室监听 |
| **Aura Light** | `#F4F1EA` 暖纸白 | `#FFFFFF` | `#1A1A1A` | 朱红 `#E63B2E` | 墨蓝 `#22335C` | 印刷海报感，日间 |
| **Aurora**（可视化沉浸） | `#070B14` | `#0D1522` | `#DCE6F5` | 青 `#64F0DC` | 品红 `#FF5EA8` | 氛围光，频谱沉浸模式 |

对比度全部按 WCAG AA（4.5:1）校验；语义色（success/warning/error）三主题各自配对。

### 7.4 三态明示（直击"静默失效"痛点）

引擎状态**常驻头部**：`● 处理中（延迟 8.3ms）` / `○ 旁路` / `✕ 失效（原因）`，配色语义化（强调色/灰/警示红）。任何效果开关改动 100ms 内反映到该徽标。

### 7.5 多语言

`flutter gen-l10n` + ARB。首批 **zh-CN（默认）/ en / ja**；效果名、预设名走独立翻译表（`effect_names_*.arb`），与 UI 文案分离，便于覆盖默认引擎命名。

## 8. 仓库目录结构（本次落定）

```
JamesDSP/
├── app/
│   └── auradsp_app/            # UI 层：Flutter 工程
│       ├── lib/
│       │   ├── core/           # 主题（令牌生成物）、路由、i18n、设计系统
│       │   ├── features/       # home / equalizer / effects / visualizer / settings / player
│       │   ├── engine/         # Control API 客户端：FFI 绑定 + 形态探测 + 状态机
│       │   └── main.dart
│       ├── windows/ android/ linux/    # 平台壳
│       └── pubspec.yaml
├── core/
│   ├── android/                # 已有（Root HAL + 未来 Rootless 共享 engine_api）
│   └── desktop/                # 驱动层（桌面）：本次新建
│       ├── engine_api/         # ★ auradsp_engine.h/.c — 统一 C ABI
│       ├── vendor-src/         # libjamesdsp 源码提取 + ORIGIN.md
│       ├── windows/            # WASAPI 链路 + DLL 构建脚本
│       └── linux/              # Phase 7 预留
├── design/
│   ├── tokens/aura.tokens.json # 设计令牌真相源（三主题）
│   └── i18n/                   # 语言清单与效果名翻译表
└── docs/adr/                   # 关键决策记录（ADR-001..）
```

## 9. Win11 首版交付范围（本迭代）

**验收标准：`flutter run -d windows` 直接可用，链路真实可听。**

1. `auradsp_engine.dll`（MSVC 编译 libjamesdsp + engine_api，smoke test：init→process→free 数值回归）；
2. Flutter Windows APP：
   - 引擎桥（dart:ffi）+ 形态探测 + 三态明示 + 延迟徽标；
   - 控制页：BassBoost / Reverb 预设 / StereoWiden / PostGain / EQ 开关（对齐 Android 已验证参数集）；
   - 内置播放器（WAV/FLAC → 引擎 → WASAPI 输出），A/B 旁路按钮；
   - 频谱可视化（SPSC ring → CustomPaint）；
   - 三主题切换 + zh/en 双语 + 延迟模式三档（实时/音乐/品质，超档置灰）。
3. 桌面引擎延迟实测报告（WASAPI 事件对 + 引擎附加延迟）。

## 10. 路线图合并（更新产品架构总览 §8）

| 阶段 | 内容 | 状态 |
|---|---|---|
| Phase 5 | AuraDSP APP Flutter 骨架 + Root 引擎控制（Android） | ← 当前（与 Win 首版并行） |
| **W1** | **Win11 首版：engine_api + DLL + Flutter Windows APP（本方案 §9）** | ← 本次 |
| Phase 6 | Rootless 引擎（APK 内置，同一 engine_api） | 待做 |
| Phase 7 | Desktop v2：Windows SFX APO（测试签名→正式签名）、Linux PipeWire | 待做 |
| Phase 8 | 多声道 Phase B / 多语言扩展 / 打包发布 | 待做 |
