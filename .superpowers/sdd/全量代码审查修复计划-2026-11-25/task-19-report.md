# Task 19：龙卷风渲染器与频谱突发完成报告

- 基线：`f482a35fc1749c47404be8ecb62a26949bd947c6`
- 分支：`feature/linux`
- 范围：VM-12、VM-13；完成中断的既有实现、测试登记、分析器清理、差异收敛、验证与提交。
- 边界：未重启设计，未执行真实/远端设备或驱动操作，未新增依赖，未修改 DSP、AGC、频带表或 `tools/Emergency_Fix_Audio.cmd`。

## 1. 接手状态与主线对账

接手时工作树已有龙卷风 shader 状态/失败诊断、dispatcher 注入、受控频谱测试、两个 golden 和原生受控信号 smoke，但没有提交或报告。本次保留这条实现路线，没有把 GPU 体积龙卷风重写为另一套 painter。

交接提供的既有结果，与本次实际重跑分开记录：

- `flutter test test/tornado_style_regression_test.dart test/visualizer_refactor_test.dart test/spectrum_rendering_test.dart`：41/41 PASS。
- `python test/smoke/smoke_viz_controlled_signals.py`：PASS；原生静音全零，10kHz 能量局部落在 27/28 带，白噪声/粉红噪声没有满足判据的无来源孤立 raw 尖峰。
- `flutter analyze`：11 项，分别为 `style_gpu_shader.dart` 的未使用 `TextOverflow` show-import、`gpu_shader_service.dart` 的 `prefer_initializing_formals`，以及 `spectrum_rendering_test.dart` 的 `avoid_print`。
- `git diff --check`：PASS。
- `smoke_viz_controlled_signals.py` 尚未登记到 `test/runner.py`，不符合仓库 smoke 注册规则。
- `visualizer_refactor_test.dart` 有 464 行差异，其中大部分是宽范围格式化，不是 Task 19 行为断言。

基线与 HEAD 对账确认二者均为 `f482a35fc1749c47404be8ecb62a26949bd947c6`，没有额外主线提交需要合并。

## 2. 实际实现与根因闭合

### 2.1 每个 shader 独立记录编译状态，不再共享模糊失败态

`app/auradsp_app/lib/features/visualizer/shaders/gpu_shader_service.dart`：

- 新增 `GpuShaderCompileStatus.idle/compiling/compiled/failed`，按 `GpuShaderType` 保存状态与错误文本。
- `initialize()` 逐个资产加载；一个资产失败会留下该资产的真实错误，不再中断其余 shader 的初始化，也不抹掉已成功资产。
- `isReady` 现在要求初始化完成且全部资产均为 compiled；部分成功不会被误报为全就绪。
- `fragmentShader()` 创建失败也会记录为对应 shader 的 failed/error，而不是把异常扩散到绘制路径。
- 保留既有 `FragmentProgram`/`FragmentShader` 缓存与每帧复用设计。
- 增加仅用于确定性测试的 loader 注入入口；生产仍使用 `FragmentProgram.fromAsset`。收尾时用私有 initializing-formal 构造函数承接 factory，消除 lint，不改变公共测试入口或加载语义。

### 2.2 龙卷风失败时明确显示原因，不再画通用圆环冒充所选样式

`app/auradsp_app/lib/features/visualizer/styles/style_gpu_shader.dart` 与 `visualizer_painter_dispatcher.dart`：

- dispatcher 可将测试 service 注入所有 GPU painter；未注入时仍使用生产 singleton。
- `GpuShaderPainter` 暴露 `VisualizerRendererKind.cpuPainter/gpuShader`、当前编译状态与包含资产路径/错误的 `statusDescription`。
- tornado 没有可用 shader 时，绘制深色背景及 `PARTICLE TORNADO LOADING` 或 `PARTICLE TORNADO UNAVAILABLE` 诊断；失败文本包含实际资产路径和加载/编译错误。
- 既有通用渐变/圆环 fallback 仍只服务其他 GPU 样式，不再用于 tornado。未修改 `particle_tornado.frag`、uniform 布局、漏斗/旋转算法或任何频谱生产代码。

这闭合的是“失败被静默伪装成另一个视觉样式”和“无法观察实际 renderer/编译状态”，不是声称本地测试已经证明 Win10 真机 GPU 编译。

## 3. 回归与受控信号设计

### 3.1 龙卷风 renderer 与像素回归

新增 `app/auradsp_app/test/tornado_style_regression_test.dart`：

1. dispatcher 必须选择 `GpuShaderType.tornado` / `shaders/particle_tornado.frag`，而非通用 painter。
2. 注入确定性加载失败后，painter 必须公开 failed 状态、CPU 路径和真实错误。
3. 在旧通用圆环应出现的固定像素区域检查亮度，防止失败后继续伪装成圆环。
4. 固定 480×320 画布保存失败诊断 golden `goldens/tornado_shader_failure.png`。
5. 通过真实 Flutter runtime-effect 资产加载，比较 time=0.75 与 time=2.0 两帧，要求超过 500 个明显变化像素，防止旋转退化为静态图。
6. 固定时间真实 shader 帧匹配 `goldens/tornado_fixed_time.png`。

两个 PNG 均为 480×320；失败 golden 的条块是 Flutter 测试字体的正常 golden 表现。`visualizer_refactor_test.dart` 保留原有所有用例，只在既有 Canvas 风格循环中补充 tornado 的实际 painter/shader 类型和 renderer/status 一致性断言。

### 3.2 原生 raw 频谱受控验证

新增 `test/smoke/smoke_viz_controlled_signals.py`，不访问音频设备、驱动或服务：

- 通过 `engine_artifact.find_engine_lib()` 解析现有引擎产物，经 `viz_frame.VizFrame` 使用同一 ABI 镜像。
- 以 48kHz、240 帧 stereo block、400 block 分别输入静音、10kHz 正弦、固定种子白噪声和确定性粉红噪声。
- 读取真实原生 viz FFT/频带结果，打印每类信号最后帧与最后 30 帧均值的 32 带 raw 序列。
- 静音所有帧/带必须严格为零；10kHz 峰值必须在 27/28，显著能量只允许落在局部 26..29；噪声末 30 帧不得出现中心值 >0.90 且相邻局部支撑 <0.20 的孤立尖峰。
- 引擎产物缺失时维持仓库既有 smoke 的显式 SKIP 口径。

本次实测 10kHz 最后帧/均值在 band 27/28 分别为 0.8340/0.8065；白噪声与粉红噪声均值序列与 Dart 侧固定夹具一致。

### 3.3 Dart raw → AGC → post 链路验证

`app/auradsp_app/test/spectrum_rendering_test.dart` 新增三段快照 helper：同一固定 raw 输入连续经过 12 帧 `CavaFeatureEngine(barCount: 32, autosens: true)` 和 `PeakPhysicsEngine`，复制 raw/AGC/post，避免生产复用缓冲覆盖证据。

- 静音三级全部严格为零，并打印三份 32 带序列。
- 以 `VizBands.edges` 查找 10kHz 所属带，而不是硬编码错带；当前为 band 28。raw=0.65 经 autosens 后该带 AGC/post=0.99，其余每带在 AGC/post 都保持零。
- 白噪声/粉红噪声使用原生 smoke 独立生成的 mean30 raw 固定夹具；raw、AGC、post 都不得新增满足“中心 >0.75 且比相邻较高者至少高 0.35”的孤立尖峰，AGC/post 值必须有限且处于 0..1。
- 测试日志改用 `debugPrint`，保留原始诊断输出并消除 `avoid_print`。

这些受控结果没有证明 AGC、attack、频带表或 DSP 存在缺陷，因此没有以 UI 裁剪、频带重排或参数调整制造“修复”。

### 3.4 注册与差异收尾

- `test/runner.py` 将 `smoke_viz_controlled_signals.py` 加入 `PLATFORM_ANY` 和实际 `smoke_files` 执行列表；它与现有引擎 smoke 一样通过 `engine_artifact` 解析产物，且不需要 Windows 专属设备接口。
- 删除未使用的 `TextOverflow` 导入；所有分析器发现均已处理。
- `visualizer_refactor_test.dart` 的广泛格式化已撤回，最终从 464 行差异收敛为 18 行，仅保留两个 import 与 tornado 断言。`spectrum_rendering_test.dart` 的既有用例格式也已恢复，保留新增受控链路覆盖。
- 未重写实现或测试来掩盖行为，未删除既有断言，保留测试所需两个 golden。

## 4. RED 证据的可恢复程度

工作树和任务目录没有保留上一实现者首次运行 Step 2 的 RED 控制台输出，本报告不虚构当时失败数量、文本或退出码。

测试明确锁住的真实旧行为是：tornado shader 不可用时会进入通用圆环 fallback，且 service 只有整体 failed 标志、没有逐资产错误。确定性失败注入和旧圆环区域像素断言会在该旧实现上失败；最终修复改为可观察的逐资产 failed/error 与诊断画面。真实资产编译、帧差和 golden 是当前有效 GREEN 证据，不被倒写成先前 RED 输出。

本次收尾实际观察到一次组合运行的 `visualizer_refactor_test.dart` 加载阶段 `Connection closed before test suite loaded`；当时没有该文件的断言失败。随后单文件运行 18/18 PASS，同一三文件组合命令重跑 41/41 PASS。没有为这一未复现的测试进程连接问题修改生产代码，也没有把它计为最终通过。

## 5. 最终验证

以下均为本次收尾在最终代码上的实际结果；Flutter 命令工作目录为 `app/auradsp_app`，其余为仓库根：

| 命令 | 结果 |
| --- | --- |
| `flutter test test/tornado_style_regression_test.dart test/visualizer_refactor_test.dart test/spectrum_rendering_test.dart` | PASS，41/41 |
| `python test/smoke/smoke_viz_controlled_signals.py` | PASS；silence=0，10kHz 局部到 27/28，white/pink 无判据内孤立 raw 尖峰 |
| `flutter analyze` | PASS；No issues found |
| `python test/smoke/smoke_runner_registry.py` | PASS；磁盘、平台集与执行清单对齐，无重复/幽灵条目 |
| `git diff --check` | PASS；无 whitespace error，仅有 Git 的既有 LF→CRLF 工作副本提示 |

除上述隔离 `visualizer_refactor_test.dart` 排查外，没有生产变更要求运行额外既有套件，因此未扩大测试范围。

## 6. 限制与待真机验收

- 本地 `FragmentProgram.fromAsset`、runtime-effect 帧差和软件 golden 只证明当前 Flutter 测试运行时可加载并绘制资产；它们不是 Win10 实际 GPU/驱动编译、30 秒连续播放或产品视觉验收。
- golden 能防固定环境像素回归，不能证明所有 GPU、分辨率、主题、DPI 下的漏斗形态、稳定视角、光晕和粒子观感均被产品接受。
- 原生 smoke 是进程内受控 PCM 验证，不是声卡、APO、ASIO、VAIO 或真实播放链路验收；Dart AGC/post 用固定 raw 序列验证 UI 特征链，不重新执行原生 FFT。
- 当前测试只排除所定义阈值和输入下的无来源尖峰，不排除所有音乐内容、突发包络或长时间播放中的视觉偏高；受控测试没有证明 DSP 缺陷，故本任务未改 DSP/AGC/attack/频带表。
- `tools/Emergency_Fix_Audio.cmd` 是接手前已存在的 untracked 文件，本次未修改、未纳入提交。未执行 AOCI、subagent、远端/真实设备、驱动、push/merge 或 Git config 操作。
