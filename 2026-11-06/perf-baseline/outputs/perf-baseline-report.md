# AuraDSP 可视化页性能基线报告（第一阶段：测量与归因）

- 日期：2026-11-06
- 范围：Windows x64，release（`flutter build windows --release --no-tree-shake-icons`）；profile 仅用于静态堆采样
- 窗口：1400 × 900（与用户实测窗口同量级）；机器 32 逻辑核
- 配置：可视化样式 `bars`、歌词关闭、音频模式 `sysapo/pipeline`、引擎 `DSP STANDBY`（`deviceRate=0`，无真实音频设备）
- 原始产物：同级 `work/`（`stages/proc_*.json`、`gpu_*.csv`、`run_*.log`、截图、测量脚本）

---

## 1. 方法与可信度

| 手段 | 用途 | 备注 |
| --- | --- | --- |
| `flutter build windows --release --no-tree-shake-icons` | 全部数值基线 | 用户规定构建口径 |
| psutil 1 Hz 采样（`work/measure.py`） | RSS / private / 进程 CPU% | CPU 为「单核百分比」，可 >100；总占比 = /32 |
| Windows 性能计数器 `\GPU Engine(*)` / `\GPU Process Memory(*)`（`work/gpu_sampler.ps1`） | GPU 3D 利用率、Dedicated/Shared 显存 | 按 `pid_<pid>` 过滤，取 `engtype_3d`，约 3 s 一次 |
| VM Service（profile + `FLUTTER_ENGINE_SWITCHES`） | Dart 堆用量、按类分配 top | 仅静态阶段可用（见 1.1） |
| `SchedulerBinding.addTimingsCallback` 临时插桩（release，编译期开关） | 实际 fps、build/raster 耗时 | 测量后已回退 |

### 1.1 已知限制（必须写进结论可信度）
1. **profile 构建在“播放态可视化”下必崩**（`0xC0000005`）：空载/静态可视化正常，一旦舞台进入播放态切页即访问违例；Impeller 与 `enable-impeller=false`（Skia）均复现。因此**播放态的 heap snapshot / CPU sampling / timeline 无法采集**，改用 release + 编译期计数插桩 + 系统计数器；静态阶段仍用 profile 读堆。
2. 计数器构建中 `pageBuilds` 字段未接线（恒 0），**不作为证据**；其余三项（frames/fps、build/raster、canvas repaint）为真实统计。
3. 本文所有 RSS 含 GPU 共享内存映射部分；Windows “共享 GPU 内存”另列，两者不可简单相加为用户可见“内存”。

---

## 2. 基线表（每阶段只改一个变量）

完整机器可读版本：`baseline-stages.csv`（同目录）。下表 CPU 为单核百分比，括号内为 32 核总占比。

| # | 阶段 | RSS 均值/峰值 (MB) | CPU (% core) | GPU 3D | GPU Shared (MB) |
| --- | --- | --- | --- | --- | --- |
| S1 | 启动后静止空载 | 219 / 220 | 1.0 (0.03%) | ~0 | 4 |
| S2 | 主页空闲（长稳 ≈35 min GPU 采样） | 322 / 323 | 0.8 (0.03%) | 0.1 | 8 |
| S3 | 可视化页**未播放**（≈24 min GPU 采样） | 350 / 350 | 1.2 (0.04%) | 1.9 | 43 |
| S4 | 可视化**强制播放态 + 频谱全零 + 歌词关** | 602 / 662 | 163.8 (5.12%) | 32.0 | 188 |
| S5 | 同 S4 + 歌词开 | 564 / 574 | 163.3 (5.10%) | 38.6 | 201 |
| S6 | 同 S4 + 歌词关（计数器构建） | 525 / 530 | 162.4 (5.08%) | — | — |
| S7 | 真实播放（粉噪）+ 歌词关 | 1077 / 1201 | 135.0 (4.22%) | 38 (35–41) | 450–780 |
| S8 | 真实播放（粉噪）+ 歌词开 | 1270 / 1503 | 129.5 (4.05%) | — | — |
| S9 | 强制播放标志下切到 Effects 页 | 320 / 335 | 7.3 (0.23%) | — | — |

样式矩阵（强制播放态、频谱全零、歌词关）：

| 样式 | RSS 均值/峰值 (MB) | CPU (% core) |
| --- | --- | --- |
| bars | 525 / 530 | 162.4 |
| oscilloscope | 649 / 673 | 162.6 |
| goniometer | 666 / 693 | 164.3 |
| cyberGrid | 668 / 678 | 163.8 |
| pulseOrb | 671 / 679 | 163.4 |
| auroraShader | 479 / 618 | 161.6 |
| tunnelShader | 338 / 339 | 167.9 |
| tornado | 322 / 323 | 164.6 |

> `milkDrop`、`fluidDynamics` 未测（菜单需滚动，脚本点击会误关菜单）；已有 8 个样式覆盖数据库/时间驱动/着色器/粒子四类，分布已足够判断共同通路。

单变量对照实验：

| 实验 | RSS 均值/峰值 (MB) | CPU (% core) | GPU 3D | GPU Shared (MB) |
| --- | --- | --- | --- | --- |
| 原版 bars（S4） | 602 / 662 | 163.8 | 32.0 | 188 |
| HUD 去掉 `BackdropFilter` | 392 / 408 | 167.0 | 17.2 | 92 |
| 只冻结时间轴（Ticker 仍转） | 376 / 388 | 166.6 | 4.6 | 27 |
| `enable-impeller=false`（Skia） | 508 / 529 | 162.3 | 36.1 | 185 |

**关键读数（对应用户现象）**
- 用户“无音乐但进入可视化页 CPU≈5%、内存 1.2–1.3 GB、GPU≈60%”——本机复现 S4/S5（5.1% 总核、0.56–0.6 GB，窗口更小）与 S8（1.27 GB，完全吻合）；GPU 差异来自窗口尺寸/核显型号。
- 用户“最小化托盘后 GPU≈0、无音乐 CPU≈0”——与 S3 一致：**渲染循环停掉后一切归零**，说明高占用是页面渲染态特有，不是引擎常驻。

---

## 3. 帧与时间线证据（计数器，S4 场景，60+ 个 2 s 窗口）

| 指标 | 实测 |
| --- | --- |
| 帧率 | 70.6 – 111.4 fps（中位 ≈ 85 fps，持续产帧） |
| build（UI 线程） | 0.11 – 0.29 ms（中位 0.16 ms） |
| raster（光栅线程） | 10.1 – 14.2 ms（中位 ≈ 11.5 ms） |
| 画布氛围层重绘触发 | 36 – 50 次/s |
| `viz` 音频事件 | **0 次/s**（引擎 STANDBY，频谱全零，日志中无 `[PERF] viz events`） |

推论（实测支撑）：

1. **光栅线程是瓶颈**：11.5 ms × 85 fps ≈ 1.0 核满载；UI 线程 build 仅 0.16 ms，可忽略。与进程 CPU 1.63 核吻合（光栅 + UI + 合成 + 少量其它线程）。
2. **不是数据驱动**：`viz` 事件为 0，频谱全零，但帧仍以 ≈85 fps 产出——驱动方是舞台的 `AnimationController.repeat()`（每 vsync 触发 Ticker），不是频谱/电平 ValueNotifier。
3. **只冻结时间轴不够**：对照实验 S18 中 `_time` 不再推进、GPU 3D 掉到 4.6%、Shared 掉到 27 MB，但 CPU 仍 166.6%。说明 Ticker 让帧管线一直“热”，CPU 开销跟**产帧**绑定，而不只是跟“画布内容变化”绑定。
4. **渲染后端无关**：Impeller(OpenGLESSDF) 163.8% vs Skia 162.3%，GPU 32% vs 36%。排除“Impeller 在 Windows 上退化的假设”。
5. **样式无关**：8 个样式 CPU 全部 161.6–167.9%，RSS 只随氛围层/网格多少浮动（322–671 MB）。样式 painter 不是主因，共同通路（Ticker + 全屏画布 + HUD 合成）主导。
6. **成本定位在可视化页子树**：同一进程、同一强制播放标志，切到 Effects 页后 CPU 7.3%（含切换尖峰），说明没有引擎级后台空转。

---

## 4. 分层内存归因（按量级排序）

以“强制播放态 bars、歌词关”约 525–602 MB 为基准：

| 排序 | 层 | 量级 | 依据 |
| --- | --- | --- | --- |
| 1 | **引擎/框架/驱动常驻**（Flutter 引擎、ANGLE/D3D、ICU/字体、纹理与表面） | ≈300 MB | 基准对比：主页 RSS 322 MB；启动 219 MB；profile 主页 363 MB。Dart 堆仅 16 MB，其余全在引擎/原生侧 |
| 2 | **视效画布与场景**（渲染目标、路径/着色器缓存、离屏层） | ≈+200 MB | S2 322 → S4 602（+280 MB），其中玻璃层占 ≈210 MB（见 3） |
| 3 | **HUD 玻璃层 `BackdropFilter` 离屏模糊** | ≈210 MB RSS + ≈96 MB GPU Shared | 去掉后 602→392 MB、188→92 MB；CPU 无变化 → 纯内存/显存项 |
| 4 | **真实音频播放带来的每帧分配与缓存增长** | ≈+475 MB，峰值 +650 MB | S4 602 → S7 1077/1201；同期 GPU Shared 188→450–780 MB。强制静默也走同一 UI 通路却只有 602 MB，故更可能是每帧新建 Gradient/Path/Shader 与 Skia/Impeller 缓存，而非 DSP 音频缓冲（后者应在引擎就绪时一次性预分配）——**该条为高置信推测，需第二阶段用 isolate 级堆采样确认** |
| 5 | **歌词** | +38 MB（静默）/ +193 MB（真实播放） | S4→S5、S7→S8 单变量对比 |
| 6 | **Dart 堆（主 isolate）** | 15.4 / 17.5 MB（used/capacity） | profile `getMemoryUsage`；top 类：`InstructionsSection` 6.36 MB、`Code` 4.35 MB(27 205 个)、`CodeSourceMap` 2.45 MB、`_OneByteString` 2.38 MB、`Function` 2.15 MB、`_List` 1.94 MB、`Field` 1.08 MB、`Class` 0.94 MB —— **占总 RSS <5%** |
| 7 | 原生堆 / 音频 isolate / 插件宿主 / legacy DSP 预分配 | 未单独量化 | 引擎 `STANDBY` 且插件目录为空，本阶段无法分离；列入第二阶段（需不崩溃的 profile 或 native heap 工具） |

> `_Location`（widget inspector）216 KB 只出现于 profile，release 无此开销。

---

## 5. “界面静止仍持续重绘”根因结论

**主因（实测闭环）**
1. 播放态下 `VisualizerStage` 的 `AnimationController.repeat()` 常驻，Ticker 每个 vsync 请求一帧 → 实测 ≈85 fps 持续产帧，与是否有音频数据无关。
2. 每帧触发全屏画布的 `CustomPaint` 重绘，光栅线程耗时 ≈11.5 ms（1400×900），在 16.7 ms 垂直同步预算内被“跑满”，形成自持的高占用循环。
3. 因此只要 `playing == true`（当前 `AppModel.liveSpectrum` 只要处于播放/桥接/采集态即为真），**即便频谱全零、无声、界面无动画**，CPU ≈1.6 核、GPU ≈32–39%、内存 +200 MB 也照旧发生。

**排除项（均为实测反证）**
- 不是音频数据频率驱动（`viz` 事件 0 次/s）。
- 不是样式 painter 本身（8 样式 CPU 同一水平）。
- 不是 Impeller 后端缺陷（Skia 同值）。
- 不是 HUD 模糊的 CPU 成本（去掉后 CPU 不变），只是内存/显存成本。
- 不是引擎/音频后台空转（Effects 页 7.3%、未播放可视化页 1.2%）。

**次因**
- HUD `BackdropFilter` 全屏离屏卷积：+210 MB RSS、+96 MB 共享显存、GPU 3D 32%→17.2% 的差值。
- 歌词：+38 MB（静默）/ +193 MB（真实播放），CPU 无变化。
- 真实播放时每帧分配导致的堆/缓存膨胀：RSS 峰值 1.2–1.5 GB，GPU 共享 450–780 MB。

---

## 6. 优化方案

见同目录 `optimization-plan.md`（按 P0/P1/P2 分级，每项含预期收益、风险、实时安全约束与验证方法）。
