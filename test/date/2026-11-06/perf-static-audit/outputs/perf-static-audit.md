# AuraDSP 静默期 CPU/GPU/内存占用：静态代码审计清单

- 审计对象：`d:\temp_desktop\Proj\JamesDSP`（AuraDSP，Flutter Windows/Linux 重建版）
- 审计方式：**只读静态代码审计**。未修改任何源文件，未运行构建、测试或应用。
- 审计时间：2026-11-06
- 交叉依据：代码内保留的历史补丁注释（含 2026-10-31 / 2026-11-06 的实测记录）、`engine/legacy/PATCHES.md` 中的实测数据。
- 待解释现象：启动静置 ~660MB；无音频操作 700–800MB；进入可视化页（频谱+歌词）后 CPU ~5%、内存 1.2–1.3GB、GPU ~60%，界面几乎无动画；最小化到托盘 GPU 归零。

---

## 0. 结论摘要（先看这三条）

1. **GPU 60% 的根因不是“动画多”，而是“画面完全静止也每帧重新光栅化整屏”。**
   viz 帧流没有任何基于电平/静默的门控（唯一门控是窗口不可见），20Hz 持续产出 → 视口每帧新建 painter → 无条件 `shouldRepaint` → 全屏 `RepaintBoundary` 每帧重绘。参见 P0-1。
2. **另有一条与刷新率耦合的独立帧源**：`AnimationController.repeat()` 按 vsync 回调，时间轴每 2 个 tick 推进一次，因此在 144Hz 屏幕上实际重绘频率是 72fps，而不是注释里假设的 30fps。参见 P0-2。
3. **可视化页 1.2–1.3GB 内存与 GPU 60% 是同一机理的两面**：光栅线程持续生产整屏 surface，队列堆积。代码自身注释已记录“60fps 全屏重绘实测可涨到 2GB+”（`visualizer_stage.dart:91-93`）。减少“帧生产量”会同时降低 GPU 与常驻内存。参见 P0-1 / M-1。

启动期 660MB 不能由 Dart 业务代码解释：它由 Flutter Windows 引擎基线 + 多引擎预建（VB 模式最多 8 个引擎）构成，量级与 `PATCHES.md:1012`、`PATCHES.md:1021` 给出的实测吻合。参见 M-2。

---

## 1. 帧驱动链路（把现象映射到代码）

```
音频 isolate 泵线程（5ms/轮）
  audio_isolate.dart:2258   if (!vizSuspended && now-lastViz >= vizIntervalMs)
  audio_isolate.dart:2265-2292  7 次 *ToList + send(Map 16 键)      ← 无电平/静默判定
       vizIntervalMs = 1000/vizFps（默认 20fps）：audio_isolate.dart:95、config.dart:25
       vizSuspended 仅由窗口可见性驱动：audio_isolate.dart:1877
              ↓ SendPort
UI isolate
  state_events.dart:756    if (!window.isVisible) break;             ← 最小化→viz 全丢弃（对应 GPU 归零）
  state_events.dart:757/771/812/830  spectrum / gr* / vizChannelLevels / vizStageChLevels 全部更新
              ↓
visualizer_page.dart:363-382    ValueListenableBuilder<bool>(_playing) → VisualizerStage
visualizer_stage.dart:375-385   if (playing) VisualizerCanvasViewport(...)   ← 未传 active
  visualizer_viewport.dart:184  ValueListenableBuilder<List<double>>(spectrum)
  visualizer_viewport.dart:187  peakEngine.update(...)
  visualizer_viewport.dart:212-222  每帧 new _CompositeVisualizerPainter + 全屏 RepaintBoundary
  visualizer_viewport.dart:56-61    shouldRepaint → mainTime == null 时恒 true

并行帧源（与 viz 无关）：visualizer_stage.dart:77-84 AnimationController.repeat()
  visualizer_stage.dart:97-103    每 2 tick   _time.value += 0.032   → 刷新率/2 的重绘源
```

---

## 2. 问题清单（按严重度）

> 每条包含：位置、机制、证据、修复方向、预期收益量级。收益为量级估算，需以运行时测量复核。

### P0-1 静默期每帧全屏重绘：viz 流无静默门控 + painter 无条件重绘

- **严重度**：P0（GPU/内存双主因）
- **位置**
  - 帧生产：[audio_isolate.dart:2258-2297](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/engine/audio_isolate.dart#L2258-L2297)
  - 帧消费/重绘：[visualizer_viewport.dart:184-222](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_viewport.dart#L184-L222)
  - 重绘判定：[visualizer_viewport.dart:56-61](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_viewport.dart#L56-L61)
  - UI 事件入口：[state_events.dart:756-845](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/core/state/state_events.dart#L756-L845)
- **现象机理**
  1. 泵线程只要在回调（WASAPI 回环 / VB-VAIO 桥接在静音期同样持续回调），就按 `vizIntervalMs`（默认 50ms）无条件 `send({evt:'viz'...})`；`spectrum` 全为 0 时也照发。全链路上**唯一的抑制条件是 `vizSuspended`（窗口最小化）**，没有“静默/低能量”门控。
  2. `spectrum` 是 `ValueNotifier<List<double>>`，每次赋值都是新 List 对象（`cast<double>()`），必触发监听。
  3. 视口 `ValueListenableBuilder` 每次事件都**新建** `_CompositeVisualizerPainter` 并重建 `RepaintBoundary`/`CustomPaint` 等 widget；`shouldRepaint` 对非时间型风格（默认 `bars`）恒为 `true`，于是整屏 RepaintBoundary 每次事件都重新栅格化。
  4. 画面元素在静默期几乎不动（bars 全 0、氛围层已休眠），所以“界面几乎没有动画”与“每帧重绘整屏”同时成立——这正是实测描述。
- **证据**
  - `audio_isolate.dart:2258` 的条件里没有任何频谱/电平量；`:2265-2292` 每帧无条件生成 7 个新列表。
  - `visualizer_viewport.dart:214-219` 每帧构造新 painter；`:60` `return mainTime == null;`。
  - 代码内既有实测：`visualizer_stage.dart:91-93` 记录 60fps 全屏重绘 → 可视化页可涨到 2GB+；当前 20fps 仍有 1.2–1.3GB。
- **修复方向**（不破坏约束）
  - 在 UI 侧（不是音频线程）维护“视觉静默”状态：当 `spectrum` 最大值低于阈值且 `levelL/R` 低于阈值持续 N 帧（如 500ms），把视口切到“低频刷新/冻结”模式：停掉每帧 painter 重建，`shouldRepaint` 返回 false，只在数据显著变化时重绘。
  - 或在 isolate 侧加“静默降频”：只用**已读回的非零判据**（`vizRead` 返回的帧里已有 levelDbfs/spectrum，纯 Dart 比较，不引入 RT 侧分配/锁/系统调用）把发送频率降到 2–4Hz；viz 作为控制面数据，不影响音频线程零分配约束。
  - 不建议在音频线程加任何判断或阻塞；`jdsp_lock` 无需改动。
- **预期收益量级**：静默期 GPU 60% → 个位数；CPU 5% → 1% 以内；可视化页常驻内存 1.2–1.3GB → 0.7GB 量级（取决于队列/表面堆积是否随之消退）。

---

### P0-2 Ticker 与显示器刷新率耦合：高刷屏重绘频率翻倍

- **严重度**：P0（GPU 次主因，且会掩盖对 P0-1 的修复效果）
- **位置**：[visualizer_stage.dart:77-84](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_stage.dart#L77-L84)、[visualizer_stage.dart:96-103](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_stage.dart#L96-L103)
- **现象机理**
  - `AnimationController.repeat()` 的 Ticker 以 vsync 频率回调，`_onTick` 每 **2 次** 回调才推进一次 `_time.value`。
  - 该逻辑是按“60Hz 显示器 → 30fps”写的（注释 :91-93），但在 120/144Hz 屏上实际是 60/72fps；时间轴风格（`VisualizerTimeAware`）的 `repaint: mainTime` 会直接把整屏重绘拉到 72fps。
  - 即使是非时间型风格（bars），Ticker 仍以刷新率申请帧，GPU/CPU 无法进入空闲。
- **证据**：`:79` `duration: 10s` 与 `:83` `repeat()`；`:99-101` 奇偶翻转推进；`:35`（viewport）`super(repaint: mainTime ?? ambienceTime)`。
- **修复方向**：用**时间累积**代替“奇偶计数”（例如记录 `Stopwatch`/`elapsed`，仅当累计 ≥33ms 时推进并通知），使语义恒为 30fps；或在 `playing` 且 `active` 时才 `repeat`，静止时改用 33ms `Timer.periodic`（注意 Timer 在 `TickerMode=false` 时不会自动停，需自行按 active 取消）。
- **预期收益量级**：144Hz 机器上时间型风格重绘 72→30fps，GPU 约 -55%；Ticker 回调 144→30/s，UI 线程 CPU 降一档。

---

### P1-3 离开可视化页后，视口仍以 20–30Hz 重建（缺 `active` 门控）

- **严重度**：P1（跨页常驻 CPU 浪费）
- **位置**：[visualizer_stage.dart:375-385](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_stage.dart#L375-L385)、[visualizer_viewport.dart:184-201](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_viewport.dart#L184-L201)
- **现象机理**：页面在 `IndexedStack` 中保活；`active=false` 只让 `_animController` 停下（:108-112），但 `playing` 不变 → `VisualizerCanvasViewport` 仍挂载，其 `ValueListenableBuilder(spectrum)` 仍每 20Hz 执行：`peakEngine.update`、`waveformSynth.update`、新 painter、widget 重建。`TickerMode` 只影响动画，不影响 `ValueNotifier` 监听。
- **证据**：`visualizer_stage.dart:375` 直接按 `widget.playing` 渲染视口，没有 `&& widget.active`；对比正确示范 `AmbientSpectrum` 用 `TickerMode` 门控并整体休眠（`chrome.dart:296-356`），以及链/效果页用 `visiblePage` 包裹监听（`chain_order_card.dart:380-400`）。
- **修复方向**：给视口传 `active`，在 `active=false` 时不订阅 `spectrum`（或订阅但 `builder` 直接返回缓存 widget）；页面重新可见时再恢复。也可统一在 `VisualizerStage` 内用 `TickerMode`/可见性判断来抑制“帧消费”。
- **预期收益量级**：在其它页面停留时，可视化页相关重建/物理计算从 20–30Hz 降到 0；整体 CPU 约 -15%～-35%（取决于 current 页面）。

---

### P1-4 歌词 20Hz ticker 在离开页面后不停止（计时器泄漏）

- **严重度**：P1（常驻 Timer + 离屏重建 + 定位逻辑持续运行）
- **位置**：[media_sync_service.dart:159-164](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/lyrics/services/media_sync_service.dart#L159-L164)、[media_sync_service.dart:166-179](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/lyrics/services/media_sync_service.dart#L166-L179)、[media_sync_service.dart:196-207](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/lyrics/services/media_sync_service.dart#L196-L207)、调用方 [visualizer_page.dart:146-148](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer_page.dart#L146-L148)
- **现象机理**：`stopAutoSync()` 只取消 `_sessionSub` 并 `_provider.stop()`，**没有取消 `_ticker`，也没有把 `_isPlaying` 置 false**。而 `_ticker` 的停止只在 `_syncTicker()` 里，`_syncTicker()` 又只在会话更新时调用；`_sessionSub` 已被取消 → 之后再无更新 → 50ms `Timer.periodic` 永久保留。
  - 后果：每 50ms 计算 `_estimatedPosition()`（`DateTime.now()`）、`findLineIndex()`，并在越过行边界时改 `activeLineIndex` → 触发 `visualizer_stage.dart:177-184` 的 `AnimatedBuilder` 重建整个离屏歌词层。
- **证据**：`:160-164` 函数体仅两行取消 + provider 停止；`:167-173` 才是唯一 ticker 释放路径；`:178` 20Hz 周期。
- **修复方向**：`stopAutoSync()` 内增加 `_ticker?.cancel(); _ticker = null; _isPlaying = false;`（并保持 `_lastSyncTime` 清理）；`dispose()` 已有清理，但页面在 `IndexedStack` 中不会 dispose（`visualizer_page.dart:96-109` 实际不会执行）。
- **预期收益量级**：彻底消除离页后的 20Hz 空转与歌词层重建；常驻 Timer 从 1 个降为 0。

---

### P1-5 HUD 非播放态常驻 + `BackdropFilter` 逐帧重算模糊

- **严重度**：P1（GPU，条件性；悬停/暂停时明显）
- **位置**：[visualizer_stage.dart:148-155](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_stage.dart#L148-L155)、[visualizer_hud.dart:255-271](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_hud.dart#L255-L271)
- **现象机理**
  - `_syncHudWithPlayback()` 在 `!playing` 时直接返回并保持 `_hudVisible=true`，即“暂停/无播放”时 HUD **永久可见**。
  - HUD 玻璃面板在 Windows 上使用 `BackdropFilter(ui.ImageFilter.blur(sigma 12)`；其 backdrop 是下方持续重绘的视口。视口每帧变化 → 该区域每帧重新做高斯模糊。
  - 播放中 HUD 3s 自动隐藏（`:141-143`）后 `AnimatedOpacity` 透明，`RenderOpacity` 在 alpha=0 时不再绘制 → 模糊才真正停。
- **证据**：`:150-152` 非播放直接 return；`hud:270-271` `sigma 12`；`hud:253-268` 仅 Linux 分支绕开模糊。
- **修复方向**：非播放态也执行 3s 自动隐藏（仅在指针交互时显示）；或把 HUD 背景改为不依赖 backdrop 的静态半透明面板/预烘焙模糊位图；同时把 HUD 放进独立 `RepaintBoundary`（当前处于 stage Stack 内）。
- **预期收益量级**：HUD 可见期间 GPU -5%～-15%（视 HUD 面积与分辨率）；停止态下 HUD 不在场时此项为 0。

---

### P1-6 每帧分配（可视化路径）

- **严重度**：P1（GC 抖动 + CPU）
- **位置**
  - UI 事件：[state_events.dart:757-830](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/core/state/state_events.dart#L757-L830)
  - isolate 侧：[audio_isolate.dart:2265-2295](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/engine/audio_isolate.dart#L2265-L2295)
  - 画笔：[style_spectrum_bars.dart:60-140](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/styles/style_spectrum_bars.dart#L60-L140)、[style_atmosphere.dart:88-119](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/styles/style_atmosphere.dart#L88-L119)
- **现象机理 / 证据**
  - 每个 viz 帧：`cast<double>()`（3 次）+ `map().toList()`（3 次）+ `List.filled`（2 次）+ 16 键 Map（1 个）。默认 20Hz ≈ 每秒 ~180 个短命对象/若干千 double。
  - 每帧新建 `_CompositeVisualizerPainter`，以及 `RepaintBoundary/CustomPaint/Padding/Row/Expanded/AnimatedSwitcher/KeyedSubtree` 等 widget（20–30 套/秒）。
  - bars 画笔每个非零柱 `Rect.fromLTWH` + `RRect.fromRectAndRadius` ×2 + `Offset`；氛围层每帧 64 个 `Offset` + `Color.withValues`。
  - 注意：painter 本身已做缓存（`_delegateFor` key 含 `renderedBands/peaks` 的稳定视图），所以**没有**每帧重建 Path/shader；这点无需改动。
- **修复方向**：静默降频（P0-1）可直接消除大部分；进一步可复用 `List<double>` 缓冲、只在数值变化时赋值；把视口从 `ValueListenableBuilder` 改为“painter + repaint listenable”，避免每帧重建 widget 树（painter 内读可变 bands 即可）。
- **预期收益量级**：静默期可分配率 -90%；滚动/播放期 GC 次数约 -50%。

---

### P2-7 歌词层无独立图层：每次行切换整层重建

- **严重度**：P2
- **位置**：[visualizer_stage.dart:177-184](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_stage.dart#L177-L184)、[visualizer_stage.dart:389-391](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_stage.dart#L389-L391)
- **机理**：`AnimatedBuilder` 监听 `activeLineIndex/currentTrack/currentLyrics/lyricsState`；每次行切换重建整层（含页头、整屏渐变 `DecoratedBox`、`LyricView`）。`Listenable.merge([...])` 也在每次 stage 重建时新建并重挂监听。
- **修复方向**：渐变遮罩拆成静态 `RepaintBoundary` 兄弟层；只把歌词列表放入 `AnimatedBuilder`；`Listenable.merge` 缓存到 State 字段。
- **预期收益量级**：行切换帧的整屏栅格化 -1 次/行；滚动动画期 GPU 轻微下降。

---

### P2-8 歌词在线服务无界缓存 + 静态 HttpClient 不关闭

- **严重度**：P2（长会话内存缓增）
- **位置**：[online_lyrics_service.dart:30](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/lyrics/services/online_lyrics_service.dart#L30)、[:36](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/lyrics/services/online_lyrics_service.dart#L36)、[:52](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/lyrics/services/online_lyrics_service.dart#L52)、[:70](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/lyrics/services/online_lyrics_service.dart#L70)、[:111](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/lyrics/services/online_lyrics_service.dart#L111)
- **机理**：`Map<String, LyricDocument> _cache` 只增不减（只有显式 `clear()`），每个文档持有全部行文本；`static final HttpClient _client` 全局常驻且从不 `close()`。长会话切换大量曲目时内存单调上升。
- **修复方向**：LRU（如 32 首）+ 失败缓存 TTL 清理；退出页面时 `_cache` 降级或裁剪。
- **预期收益量级**：长会话内存不再随切歌增长（单首歌词通常数百 KB 量级，几十首即可见）。

---

### P2-9 `dbgLog` 无开关、同步写盘（与“调试系统由命令行开关启用”的约定不一致）

- **严重度**：P2（IO + 抖动；音频 isolate 线程）
- **位置**：[debug_log.dart:23-56](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/engine/debug_log.dart#L23-L56)；调用点 [audio_isolate.dart:2270-2274](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/engine/audio_isolate.dart#L2270-L2274)、[:2303](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/engine/audio_isolate.dart#L2303)、[state_events.dart:713](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/core/state/state_events.dart#L713)
- **机理**：`dbgLog()` 无任何 enabled 判断；每次调用 `writeStringSync`（同步系统调用），并每 200ms `flushSync`。被音频 isolate 泵线程与 UI 线程调用。viz 计数每 100 帧（5s）写一条，且带 `sp.reduce` 与字符串插值。
- **修复方向**：加进程级/编译期开关（命令行 flag 或环境变量），关闭时函数体直接返回；高频点继续用 `dbgLogThrottled`。
- **预期收益量级**：静默期消除周期性同步 IO 与字符串分配；拖动参数时 UI 线程写盘抖动消除。

---

### P2-10 进入可视化页即无条件编译全部 GPU shader

- **严重度**：P2（首次进入的内存/CPU 峰值）
- **位置**：[visualizer_stage.dart:86-88](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_stage.dart#L86-L88)
- **机理**：`initState` 直接 `GpuShaderService.instance.initialize()`，无论当前风格是否为 shader 风格；`FragmentProgram` 编译后常驻。
- **修复方向**：按需初始化（只有切换到 `auroraShader` 类风格时加载）；或在首次进入页面时异步、低优先级预热但可取消。
- **预期收益量级**：首帧/首次进入时 CPU 峰值下降；不使用 shader 风格时节省其程序与运行时缓存常驻内存（数 MB 量级）。

---

### P2-11 视口每帧重建 widget 树（P0-1 的结构侧成因）

- **严重度**：P2（单独看中等，但与 P0-1 叠加）
- **位置**：[visualizer_viewport.dart:184-280](file:///d:/temp_desktop/Proj/JamesDSP/app/auradsp_app/lib/features/visualizer/views/visualizer_viewport.dart#L184-L280)
- **机理**：`spectrum` 的 `ValueListenableBuilder` 把整个 body（Padding/Row/Column/AnimatedSwitcher/KeyedSubtree/RepaintBoundary/CustomPaint）都放在 builder 里；每帧重建（含 `AnimatedSwitcher` 的过渡 Stack 与 `previousChildren` 列表展开）。
- **修复方向**：builder 只负责“取值 + 更新 painter 内的可变缓冲”，结构保持不变；`AnimatedSwitcher` 用 `ValueKey(style)` 只在风格变化时重建。
- **预期收益量级**：每帧 widget 分配与元素更新归零 → 静默/播放期 UI 线程 CPU 明显下降（与 P1-6 合并计量）。

---

## 3. 内存专项（M）

### M-1 可视化页 1.2–1.3GB：帧生产过剩导致光栅队列/表面堆积（P0，与 P0-1 同源）
- 证据：`visualizer_stage.dart:91-93` 明确记录“60fps 全屏重绘 → 光栅线程落后、GPU 表面排队（实测可视化页 2GB+）”。当前默认 20fps 仍有 400–500MB 增量，属于同一机理的残留。
- 涉及的全屏图层：视口 `RepaintBoundary`（`visualizer_viewport.dart:212`）、氛围层（独立边界，11fps `chrome.dart:303`）、歌词整屏渐变（无边界，`visualizer_stage.dart:391`）、页面背景 `AmbientSpectrum`、`GrainOverlay`（`visualizer_page.dart:299-300`）。
- 修复方向：先做 P0-1/P0-2（降低帧生产量），再评估是否需要把全屏图层数从 4–5 降到 2–3（例如歌词渐变与视口合并为一个边界层）。
- 预期收益：可视化页常驻内存回到 ~700–800MB 量级；GPU 同步下降。

### M-2 启动 660MB：多引擎预建 + 引擎基线（P2，代码可控部分）
- 证据：Voicemeeter 回调模式在主线程预建最多 8 个引擎（`VmAudioCallback.cpp:71-72`、`:336-343` `create(sr, 2048)`，注释“RT 内禁分配，故全在 Start 前建好”）；`PATCHES.md:1012` 记录“9 VM = 576MB 常驻，每 handle 再加 ~25MB vendor 结构”；`:1021` 的目标是“8 并发引擎总增长 < 320MB”。
- 结论：在 VB/多总线模式下，**静置基线随实例数线性放大**，这是代码可解释的主要部分（~200MB 量级），其余为 Flutter Windows 引擎 + Dart 堆基线。
- 修复方向：按需建引擎（只建当前有信号的组）/ 退出桥接模式时销毁未用引擎；保持 EEL 全局内存按需提交（已有优化，勿回退）。
- 预期收益：VB 模式下静置内存 -100～-200MB 量级（需以运行时验证组数）。

### M-3 页面保活带来的常驻引用（P2）
- 证据：`IndexedStack` 保活（`shell.dart:187` `i == _index || _pages[i] != null`）；可视化页 `dispose` 实际不会执行（`visualizer_page.dart:96-109` 仅应用退出时跑）。
- 后果：`_mediaSync`、`OnlineLyricsService` 缓存、`GpuShaderService` 程序、视口图层纹理在离开页面后全部保留。
- 修复方向：与 P1-3/P1-4 一并处理；歌词服务可在离页时释放文档与图片/缓存引用。

---

## 4. 已确认实现正确、不要误改的点

| 位置 | 现有做法 | 为什么不能动 |
|---|---|---|
| `visualizer_viewport.dart:23-35,212-222` | 单层合批：氛围+主画笔画进同一个 `CustomPaint`，只保留一个全屏 `RepaintBoundary` | 这正是为了避免双份全屏离屏 surface；拆层会更慢 |
| `visualizer_viewport.dart:145-170` | painter 按 key 缓存（`bands/peaks` 为稳定视图对象） | 没有每帧重建 Path/Paint/shader，别改成“每帧 new painter”的更重实现 |
| `chrome.dart:296-356` | `AmbientSpectrum` 用 `TickerMode` + 窗口可见性 + 90ms 节流 + 静默休眠 | 这是正确的“离屏/静默零开销”范式，可作为 P1-3 的参照实现 |
| `chrome.dart:859-863` | `PulseDot` 独立 `RepaintBoundary` | 呼吸动画 60fps 只重绘 16px，不污染顶栏 |
| `chrome.dart:750-830` | `GrainOverlay` 静态画笔 + 独立边界 + `shouldRepaint=false` | 每帧 2200 rect 只在尺寸变化时画一次 |
| `visualizer_meters.dart:38-60` | `active=false` 时不订阅 level notifier | 与 P1-3 同思路，视口应照此补齐 |
| `chain_order_card.dart:380-400` / `input_card.dart` | 监听被 `visiblePage` 包裹 | 离屏页不参与 20–30Hz 重建 |
| `state_events.dart:756` | 窗口不可见时丢弃 viz | 与“最小化 GPU 归零”一致，是正确门控 |
| `audio_isolate.dart:2258` | viz 拉取在泵循环外层、限频 20Hz | 声音路径本身零分配/零锁未被破坏，勿在 RT 线程加逻辑 |
| `visualizer_page.dart:70-73,83,113` | `_kPerfForcePlaying` 编译期插桩 | 属另一任务的测量开关，默认 false；测量结束后应移除，本轮不处理 |

---

## 5. 修复顺序建议（收益/风险比）

1. **P0-1 静默门控**（UI 侧降频 + `shouldRepaint` 变化检测）——同时解决 GPU 60%、CPU 5%、可视化页内存增量。
2. **P0-2 时间轴改为时间累积**（去掉刷新率耦合）——高刷屏收益最大，且是 P0-1 的乘数。
3. **P1-4 歌词 ticker 泄漏**（3 行改动，风险最低）。
4. **P1-3 视口 `active` 门控**（与 P1-4 同批，离页彻底静默）。
5. **P1-5 HUD 非播放态自动隐藏**（GPU 条件性收益）。
6. **P1-6 / P2-11 结构侧收敛**（把 `ValueListenableBuilder` 降级为 repaint listenable）。
7. **P2-8/9/10/11 与 M-2**（缓存上限、日志开关、按需 shader、按需引擎）。

## 6. 约束确认（本清单中的建议均满足）

- 不在音频线程加任何分配、锁或系统调用；viz 降频/静默判定放在控制面（isolate 的发送节流或 UI 侧）。
- 不触碰 `jdsp_lock` / `ctrl_mutex` 的持锁结构修改路径。
- 平台差异建议仍落在 `lib/platform/`（HUD 模糊分支已在 `visualizer_hud.dart:253-268` 按平台处理，修复时保持该分支结构）。
- 不改动 legacy C 算法，不需要新增 `[PATCHED-AuraDSP]` 条目。

---

## 7. 附：与实测现象一一对应

| 实测现象 | 代码解释 | 条目 |
|---|---|---|
| 静置 GPU 60%、几乎无动画 | viz 20Hz 无条件产帧 → 视口每帧整屏重绘（画面内容几乎不变） | P0-1 |
| 高刷屏更明显 | `repeat()` + 每 2 tick 推进 → 刷新率/2 的重绘 | P0-2 |
| 最小化后 GPU=0 | `state_events.dart:756` 丢弃 viz | 已验证正确 |
| 可视化页 1.2–1.3GB | 全屏重绘导致光栅排队/表面堆积（历史实测 60fps→2GB+） | P0-1 / M-1 |
| 启动 660MB | 引擎基线 + 多引擎预建（VB 最多 8 个） | M-2 |
| 切页后仍耗 CPU | 视口 VLB + 歌词 20Hz ticker 未随页面停止 | P1-3 / P1-4 |
| 悬停/暂停时 GPU 更高 | HUD 常驻 + `BackdropFilter` sigma12 随视口逐帧重算 | P1-5 |
