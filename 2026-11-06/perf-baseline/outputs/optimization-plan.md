# AuraDSP 可视化页优化方案（第一阶段产出，按优先级分级）

> 基线数据与归因见同目录 `perf-baseline-report.md`；全部数字来自本机 release 实测（1400×900、32 核）。
> **实时安全总则**：本文件所有条目均为 UI/控制侧改动，不改变音频回调路径；**不得**把节流逻辑下沉到音频 isolate（`viz` 事件的产出频率保持不变，只在 UI 侧消费时降频）。任何涉及共享控制结构（参数表、插件表）的改动必须持 `jdsp_lock`；本方案 P0/P1/P2 均**不需要**修改共享结构，故不触碰 `jdsp_lock`。

## 分级总览

| 编号 | 优化项 | 预期收益（本机实测反证） | 风险 | 触碰实时安全 | 优先级 |
| --- | --- | --- | --- | --- | --- |
| P0-1 | 静默/无音频时停止舞台 Ticker | CPU 163.8% → ≈1–3%；GPU 32% → ≈2%；Shared 188 → 43 MB | 低 | 否 | P0 |
| P0-2 | 产帧节流：由每 vsync 改为 20–30 Hz | fps 85 → 25–30；CPU ≈163% → ≈55%±；GPU ≈32% → ≈10% | 中（观感） | 否 | P0 |
| P0-3 | HUD 玻璃层去掉 `BackdropFilter` | RSS −210 MB（−35%）；GPU Shared −96 MB；GPU −15 pp；CPU 0 | 低（视觉） | 否 | P0 |
| P0-4 | 最小化/不可见时彻底停渲染循环 | GPU ≈0、CPU ≈1%（当前 S3 已验证下限） | 低 | 否 | P0 |
| P1-1 | painter 每帧对象复用审计 | 播放态峰值 1.2–1.5 GB → 目标 −300~500 MB | 中 | 否 | P1 |
| P1-2 | 氛围层烘焙 + 低频更新 | 每帧 raster −2~4 ms（11.5 → 8~10 ms） | 低 | 否 | P1 |
| P1-3 | 歌词/媒体同步链路降耗 | −38 MB（静默）/−193 MB（播放）；CPU 无变化 | 低 | 否 | P1 |
| P1-4 | 修复 profile 播放态访问违例 | 无直接收益；解锁 timeline/heap 归因 | 中 | 否 | P1 |
| P1-5 | 图像缓存与离屏层审计 | 未知，预计 −50~150 MB | 低 | 否 | P1 |
| P2-1 | 舞台分层（HUD 独立边界 + 静态层缓存） | 每帧 raster 与合成进一步下降 | 中 | 否 | P2 |
| P2-2 | 省电模式（无音频/无操作降帧） | 静默长期占用 → ≈0 | 低 | 否 | P2 |
| P2-3 | 引擎/原生堆审计（第二阶段） | 定位 ≈300 MB 常驻的构成 | 低 | 否 | P2 |

---

## P0（本轮立刻做，收益最大、风险最低）

### P0-1 静默/无音频时停止舞台 Ticker
- **问题**：`VisualizerStage` 在 `playing == true` 时常驻 `AnimationController.repeat()`，每 vsync 产帧；实测频谱全零、`viz` 事件 0 次/s 时仍 85 fps、CPU 163.8%、GPU 32%。
- **做法**：把“是否渲染”从 `AppModel.liveSpectrum`（播放/桥接/采集态的 UI 语义）解耦为“真实信号活动”：用频谱能量 + L/R 电平判定，连续 **N 帧（建议 2 s）无活动**时 `_animController.stop()`（不是只冻结 `_time`，S18 已证明冻结无效），信号恢复时 `repeat()`。保留一次性首帧绘制，避免黑屏。
- **预期收益**：静默态回落到 S3 水平（CPU 1.2%、GPU 1.9%、Shared 43 MB）；按用户场景（“不播放音乐进入可视化页”）即为 5% → <0.2% 总占用。
- **风险/边界**：曲间静音、极安静的段落会暂停动效（2 s 迟滞可调）；用 `TickerMode` 或直接 `stop()` 语义都可行，但必须确认 HUD 计时器/歌词不依赖该 Ticker。
- **实时安全**：否。不动音频线程、不动 `viz` 事件产出。
- **验证**：复测 S4 场景（强制播放 + 零频谱）应得 CPU <5%（单核）且 GPU <5%；真实粉噪播放时与现状同值（功能不回退）。

### P0-2 产帧节流：每 vsync → 20–30 Hz
- **问题**：时间轴本就按 30 Hz 推进（`_tickParity`），但 Ticker 仍以 85 fps 产帧，一半以上帧没有内容变化。
- **做法**：以 `Timer.periodic(33 ms)` 或 `TickerMode(enabled: …)` + 单帧驱动替代 `repeat()`；`_time` 每次推进 0.032 s（仍 30 Hz 视觉），氛围层维持 20 Hz。**不要**降低音频 isolate 的 `viz` 产率。
- **预期收益**：产帧 ≈85 → 25–30 fps；光栅占用按比例下降（11.5 ms × 25 ≈ 0.29 核），预计 CPU 163% → ≈50–60%，GPU 32% → ≈10%；与 P0-1 叠加后静默态近零。
- **风险/边界**：慢速旋转/流动观感需要验收（现有代码注释已说明 30 fps 对观感无差别；本次把“产帧”也降到同一档）；需要处理首帧与恢复播放时的对齐，避免跳变。
- **实时安全**：否。
- **验证**：计数器复测 fps 应落在 25–30；`raster` 仍 ≈11.5 ms/帧但帧数下降；主观对比动效流畅度。

### P0-3 HUD 玻璃层去掉 `BackdropFilter`
- **问题**：Windows 上 `_GlassSurface` 用 `ui.ImageFilter.blur(sigma 12)` 全屏离屏卷积，是最大的单一内存项。
- **做法**：Windows 复用 Linux 的无模糊路径（`ClipRRect` + 半透明底），或**预烘焙**：把背景一次性模糊成 `ui.Image` 缓存，仅在看板内容/尺寸变化时重算。两者视觉差异需设计确认。
- **预期收益**：RSS 602 → 392 MB（−210 MB，−35%）；GPU Shared 188 → 92 MB；GPU 3D 32 → 17.2%；CPU 无变化（实测）。
- **风险/边界**：视觉上玻璃质感减弱；若选预烘焙方案需处理窗口 resize / 样式切换的缓存失效。
- **实时安全**：否。纯 UI 层。
- **验证**：复测同一场景的 RSS/GPU Shared；截图对比。

### P0-4 不可见/最小化时彻底停渲染
- **现状**：用户实测最小化后 GPU≈0、CPU≈0；本机 S3（未播放）也是 1.2%/1.9%，说明机制大致有效。
- **做法**：确认“窗口不可见”时既停 `viz` 订阅也**停 Ticker**（当前 `setVizSuspended` 只影响 isolate 侧推送；需核对 `VisualizerStage` 是否仍被 Ticker 驱动）。
- **预期收益**：最小化/托盘期间 CPU、GPU 归零，避免后台空转。
- **风险**：低；恢复可见时需立即重建首帧。
- **实时安全**：否。

---

## P1（紧随其后，收益中等、需要逐项验证）

### P1-1 painter 每帧对象复用审计
- **证据**：强制静默 602 MB vs 真实粉噪 1077/1201 MB（+475/+650 MB），同期 GPU Shared 188 → 450–780 MB；强制静默也走同一 UI 通路，说明增量来自“内容每帧变化”引发的分配/缓存，而非音频缓冲（后者应在引擎就绪时预分配）。
- **做法**：逐样式检查 `Paint` / `LinearGradient` / `Path` / `ImageFilter` 是否在 `paint()` 内新建；改为成员缓存 + 参数变更时重建（项目已有 2026-10-31 的单画笔复用改造，需确认全部样式覆盖，尤其 bars 的柱体渐变与阴影 `MaskFilter`）。
- **预期收益**：播放态峰值 1.2–1.5 GB 目标 −300~500 MB；降低 GC 抖动与 GPU 表面排队。
- **风险**：中——缓存画笔状态污染易引发“样式切换后颜色错乱”，必须逐样式 A/B + 截图回归。
- **实时安全**：否（纯 UI 线程）。
- **验证**：粉噪 5 min 峰值 RSS 与 GPU Shared 对比。

### P1-2 氛围层烘焙 + 低频更新
- **证据**：画布氛围层重绘触发 36–50 次/s；每帧 raster 11.5 ms。
- **做法**：`StyleAtmospherePainter`（全屏径向渐变 + 星点）烘焙为 `ui.Picture`/`ui.Image`，仅 2–5 Hz 更新或仅在参数变化时重算；星点漂移用位移而非重绘。
- **预期收益**：每帧 raster −2~4 ms（按 25 fps 计 ≈ −0.05~0.1 核）。
- **风险**：低；需处理尺寸变化与主题切换的缓存失效。
- **实时安全**：否。

### P1-3 歌词 / 媒体同步链路
- **证据**：歌词 +38 MB（静默）、+193 MB（真实播放，1270 vs 1077），CPU 无变化；`MediaSyncService` 在开启歌词时以 50 ms 轮询（SMTC 子进程）。
- **做法**：仅在“页面可见 + 有活动媒体会话”时轮询；无会话时退化为事件驱动/更稀疏轮询；歌词文本布局结果缓存，避免每帧重建。
- **预期收益**：记忆 1.27 GB 阶段下降 ≈200 MB；后台无会话时不再拉起子进程。
- **风险**：低；歌词切换延迟需验收。
- **实时安全**：否。

### P1-4 修复 profile 播放态访问违例（已定位：引擎采样器；已规避）

- **结论**：不是本应用代码问题。cdb 符号化显示崩点在
  `flutter_windows.dll!dart::ProfilerNativeStackWalker::CallerFP` →
  `Profiler::SampleThread` → `ThreadInterrupterWin::Interrupt`，错误偏移恒为
  `+0x8b3dd0`，访问地址落在主线程栈底未提交页（如 `0x1000c0`）。官方空模板
  工程（仅 `AnimationController` + `CustomPaint`）在同一 Flutter 3.47.9 /
  Dart 3.13.7 下复现同一偏移。因此“氛围层 / 时间驱动样式 / HUD 玻璃层”的
  二分假设不成立：在主页（不含任何可视化）同样复现。
- **触发条件**：`flutter run --profile` 注入 `enable-dart-profiling=true` 后，
  引擎以 1 kHz（`--profile_period=1000`）采样；采样线程沿 frame pointer
  回溯被中断线程的 native 栈时越过已提交区。release 无该路径
  （`SchedulerBinding` 的 `TimelineTask` 仅在 `!kReleaseMode` 存在，且 release
  启动器不注入采样开关）。
- **规避**：把采样周期放宽到 10 ms（100 Hz）。`flutter run` 原生支持
  `--dart-flags` 透传（flutter_tools 的 `desktop_device.dart` 会把 `dart-flags=…`
  作为引擎开关写入 `FLUTTER_ENGINE_SWITCH_*`）：

  ```
  flutter run -d windows --profile --dart-flags=--profile_period=10000
  ```

  直启 `Profile\auradsp_app.exe` 时等价注入：
  `FLUTTER_ENGINE_SWITCHES=2`、`FLUTTER_ENGINE_SWITCH_1=enable-dart-profiling=true`、
  `FLUTTER_ENGINE_SWITCH_2=dart-flags=--profile_period=10000`。
- **验证**：粉噪播放 + 可视化页连续采样 300 s 无崩溃；`getFlagList` 显示
  `profile_period=10000`、`profiler=true`、`profile_vm=true`；累计 1980 个 CPU
  采样（对应 27500+ 函数符号），`getAllocationProfile(gc=true)`（两个 isolate
  堆约 15.96 MB）与 `getMemoryUsage` 均正常返回。
- **残留风险**：1 kHz 仍未完全稳定（对照实验出现启动 2 s 内崩溃）；100 Hz 为
  实测可用档。根本修复需引擎/SDK 升级，随 P2-3 一起排期。
- **实时安全**：否。

### P1-5 图像缓存与离屏层审计
- **做法**：核对 `PaintingBinding.imageCache` 上限、`saveLayer` 调用点、`RepaintBoundary` 数量；对每次样式切换产生的旧层确认释放。
- **预期收益**：预计 −50~150 MB（待测）。
- **风险**：低。
- **实时安全**：否。

---

## P2（结构性/后续阶段）

### P2-1 舞台分层重构
- HUD 与画布各自独立 `RepaintBoundary`；静态装饰层（网格、坐标轴、玻璃底）用缓存层；用 `TickerMode` 统一包裹动态层，使“暂停/降帧”成为结构能力而不是逐处判断。

### P2-2 省电模式
- 无音频、无操作 10 s 后自动降帧到 5 Hz 或展示静态首帧；设置面板提供“高画质/均衡/省电”三档（帧率上限 60/30/5）。

### P2-3 第二阶段：引擎/原生堆审计
- 目标：给 ≈300 MB 的引擎常驻、audio isolate 堆、legacy DSP 预分配（IR/插件宿主）建立分层表。依赖 P1-4 修复 profile。
- 实时安全：只读采样，不修改音频线程。

---

## 建议实施顺序与验收口径

1. **P0-1 + P0-2 合并实现**（同一处渲染驱动逻辑，避免两次改动同一段代码）：验收指标——强制播放 + 零频谱：CPU ≤5%（单核）、GPU 3D ≤5%、RSS ≤400 MB；真实播放：观感无回退。
2. **P0-3**：验收——同一场景 RSS ≤420 MB、GPU Shared ≤100 MB，截图评审通过。
3. **P0-4**：验收——最小化 5 min 内 CPU ≤2%、GPU ≈0。
4. **P1-1/P1-2**：验收——粉噪 5 min 峰值 RSS ≤800 MB、GPU Shared ≤400 MB、raster ≤9 ms。
5. 每项单独提交，附 `work/` 下同口径复测数据（沿用 `measure.py` + `gpu_sampler.ps1`，保持阶段标签一致）。

---

## 施工后遗留清单（2026-11-06 P0 落地后）

1. **profile 播放态访问违例 0xC0000005（已定位 + 已规避）**：根因是 Flutter
   3.47.9（Dart 3.13.7）Windows profile 引擎的 CPU 采样器：默认 1 kHz 采样时
   `ProfilerNativeStackWalker::CallerFP` 沿 frame pointer 回溯到主线程栈底
   未提交页（偏移恒为 `flutter_windows.dll+0x8b3dd0`），官方空模板工程同样复现。
   release 无采样路径，故不复现。规避：profile 采集一律用 100 Hz
   （`flutter run -d windows --profile --dart-flags=--profile_period=10000`，
   或直启 Profile exe 时注入同名引擎开关）。详见 P1-4。
   影响已解除：profile 下堆/分配快照与 CPU 采样均可正常采集。
2. **P0-3 收益量级修正**：方案预估 −210 MB / −96 MB 基于旧 85 fps 全屏卷积节奏；在 P0-2 之后
   （30 Hz、HUD 仅覆盖岛区）实测 −78 MB / −65 MB。后续若恢复逐帧全屏特效，需重新评估。
3. **GPU Process Memory 计数器口径**：`gpu_sampler.ps1` 的 shared 为进程级常驻值，跨次运行会随
   驱动缓存/实例重建漂移（同场景 37–188 MB 都出现过）；跨版本对比只看 GPU 3D 引擎占用与帧率，
   shared 仅作同一次运行内的相对参考。
4. **未播放页启动瞬时 RSS**：启动后约 10 s 内测得的可视化页 RSS 会比稳定态高 25–65 MB
   （Dart 堆/驱动缓存尚未回落），验收需等待 ≥45 s 稳定后再采样。

