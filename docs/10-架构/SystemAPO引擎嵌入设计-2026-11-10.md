# System APO 引擎嵌入设计（2026-11-10 立项）

> 状态：**已立项（用户裁定 2026-11-10）**，P0 设计定稿。取代对象：AuraApo v1 透传实现；同时 supersede `docs/00-总览/项目架构与开发规范.md` 的方向锁定「sysapo 回归纯配置面」（2026-10-15）——该行已就地更正并注明本裁定。
> 取证基础：第四轮项 1 取证（APO 透传定性）+ 本立项 P0 取证（APO 结构 / 引擎 ABI / 参数全集 / audiodg 环境，证据见同日旁聊记录与仓库代码，下文关键处给文件锚点）。

## 1. 目标与非目标

**目标**：System APO 附加到物理端点后，系统音频经 AuraDSP 引擎真实处理；App 内的参数调节实时生效；App 的电平/频谱可视化在 sysapo 模式下由 APO 回传驱动；任何引擎侧故障不得波及 audiodg（自动退回透传）。

**非目标（v1 明确不做）**：
- 多端点同时处理（见 D3 单引擎座位）；
- 插件托管进 APO（VST3/CLAP 等不进 audiodg）；
- `convolver.ir.path`、`ddc.load` 在 APO 侧生效（audiodg 的 LPAC 身份读不到用户目录文件，这两项在 APO 模式下保持惰性，见 D4）；
- 采样率转换（APO 协商率即引擎率，与桥同口径）。

## 2. 现状锚点（取证事实）

- AuraApo 为自写 COM（`03_system_apo/AuraApo.cpp`，282 行）：只认 float32、任意声道透传；`Initialize` 丢弃一切入参；引擎句柄的唯一自然挂点是 `LockForProcess`/`UnlockForProcess`（格式在此定型、非 RT 点）。
- 引擎 ABI：`auradsp_create(rate, max_block)`（8000–192000，max_block ≤ 16384，create 非 RT 安全）；`auradsp_process` 块帧数可变、超 max_block 钳断；声道由 `channels.count` ∈ {2,4,6,8} 决定；`auradsp_set_param` 按字符串 id 寻址、持 `ctrl_mutex`、钩子可阻塞——**控制线程专用，严禁 APOProcess 线程调用**（桥的既有线程模型同此：控制线程 set_param、泵线程 process、数值靠原子字段同步）。
- viz：`auradsp_viz_read` 拉 1600B 帧（spectrum[32] + 电平 + 分级电平，~30 Hz），SPSC 单消费者。
- 多 handle 同进程共存是引擎常态（App 内本地 + VAIO 桥 + ASIO 桥 + VB 最多 8 个）；进程全局仅 NSEEL 全局初始化引用计数（永不释放，有意为之）。
- audiodg：LocalService + LPAC 沙箱；本产品装机时已置 `DisableProtectedAudioDG=1`（apo_config install 既有行为）；跨进程共享对象必须用心跳同款穿透 DACL（`D:(A;;GA;;;LS)(A;;GA;;;WD)(A;;GA;;;S-1-15-2-1)(A;;GA;;;S-1-15-2-2)`，AuraApo.cpp:250-253 已验证可穿透）。
- 参数全集：引擎表 235 条描述符，其中数值 184 条（f32/i32/bool 定长），字符串值 7 个 id（`eq.curve`、`arbmag.string`、`liveprog.code`、`liveprogmc.code`、`graph.order`、`convolver.ir.path`、`ddc.load`）；布局可由 `engine_param_table.h` 机械生成（`tools/gen_param_contract.py` 先例）。App 会话典型量级 162 数值 + 3~4 字符串（isolate 的 `paramMirror`/`paramStrMirror` 已全量留底）。

## 3. 总体架构

```
App 进程                                  audiodg 进程
┌────────────────────────────┐           ┌──────────────────────────────┐
│ audio isolate              │  参数块    │ AuraApo 实例（per 连接）      │
│  paramMirror（既有）        │ ────────▶ │  ├ 非座位实例：透传（同 v1）   │
│  └ ApoParamPublisher       │  Global\  │  └ 座位实例：                 │
│     （新增：镜像→共享块）    │  AuraDSP_ │     ├ worker 线程（新增）     │
│ telemetry 轮询（新增 FFI）  │  ApoParams│     │   轮询参数块→set_param  │
│  └ 合成 viz 事件→UI（既有   │ ◀──────── │     │   viz_read→写 telemetry │
│     事件形状不变）          │  telemetry │     └ APOProcess（RT）        │
└────────────────────────────┘  Global\   │         SEH 包裹→引擎 process │
                               AuraDSP_   │         故障→闩锁透传         │
                               ApoTelemetry└──────────────────────────────┘
```

引擎 DLL 由座位实例在 LockForProcess 时以绝对路径 LoadLibrary（D1），create 于同点，destroy 于 UnlockForProcess（worker 先停后拆）。

## 4. 决策表

| # | 决策 | 理由 / 代价 |
|---|---|---|
| D1 | **引擎定位**：APO 以自身模块目录为锚，依次试「同目录 `auradsp_engine.dll`」→「上一级 `..\auradsp_engine.dll`」，绝对路径 LoadLibraryW，加载后 `auradsp_abi()==2` 强校验 | 三种布局（安装/便携：引擎在 exe 根 = driver/ 上一级；开发：sync_artifacts 把引擎抄到 drivers out 同级）全覆盖，零新增包体副本、零注册表依赖。桥的 TryLoadEngine 不可搬（其 ExeDir 在 audiodg 里是 System32） |
| D2 | **引擎构建纪律（P2 前置）**：Windows 引擎目标加 `/MT`（静态 CRT）+ `/guard:cf`，CI 以 dumpbin 校验产物导入表（不得出现动态 VCRUNTIME/MSVCP 依赖）与 CFG load-config | audiodg 是全 CFG 进程且有「System32 CRT 首次拉入致 loader 崩」「无 CFG 位图在虚调用点 fail-fast」两次定罪记录（CMakeLists.txt:192-203）。/MT+/guard:cf 对 App/桥消费者无副作用 |
| D3 | **单引擎座位**：全部 APO 实例共享一个「引擎座位」（telemetry 块内 CAS 抢占，LockForProcess 抢、UnlockForProcess 放）；同端点的 SFX/MFX/EFX 三实例只有一个跑引擎、其余透传；第二个端点的实例同样透传（telemetry 记 seat-taken） | 三槽同 CLSID 串联是现安装形态，v1 透传无感、DSP 下会三倍处理——座位制从根上避免。多端点真处理需端点身份管线（Initialize 的端点属性存储），列 v2 |
| D4 | **参数块**：单一 Global 映射 `AuraDSP_ApoParams`，穿透 DACL；头部（magic/version/写序号/bypass 旗）+ 数值区（184 项定长数组，索引由引擎表机械生成、C 头与 Dart 表同源同门）+ 字符串区（`eq.curve` 4K / `arbmag.string` 4K / `liveprog.code` 16K / `graph.order` 1K 定长槽）；`convolver.ir.path`、`ddc.load`、`liveprogmc.code` **不入块**（v1 排除，见 §1 非目标）；App 侧写者 = audio isolate 的 publisher（镜像变更即写 + 序号自增，进 sysapo/附加时全量重写一遍） | seqlock 式读（序号前后校验、撕裂重试）使 worker 读无锁；定长布局使块大小可静态断言；排除项是环境不可达而非搬运问题 |
| D5 | **应用线程模型**：座位实例在 LockForProcess 起一条 worker 线程：50 ms 轮询参数块序号，变化时整块快照→与上次应用值 diff→逐项 `auradsp_set_param`（字符串 id）；同一线程兼任 viz 泵（`auradsp_viz_read` → telemetry）。APOProcess 线程只做 process 本身 | 与桥的控制/泵分工同构；set_param 的锁与文件钩子被关在非 RT 线程；50 ms 轮询的滑杆延迟 ≤ ~100 ms 可接受，v1 不引入命名事件 |
| D6 | **APOProcess**：座位且引擎就绪且未旁路时：输入按声道适配（D8）→ 分块（≤ max_block）调 `auradsp_process` → 写回；全程 `__try/__except` 包裹，异常即闩锁故障态、本会话余下块全透传并在 telemetry 置 fault。bypass 旗置位时跳过引擎（等价透传） | audiodg 崩溃 = 全系统音频死，SEH 闩锁是硬要求；旁路在 APO 层跳过与引擎内旁路听感等价且更省 |
| D7 | **telemetry**：单一 Global 映射 `AuraDSP_ApoTelemetry`（APO 建、App 开读，方向与心跳同）：座位状态（owner pid/率/声道/已应用参数数/fault 旗/seat-taken 计数）+ 最新电平（peakIn/Out L/R、level dB）+ spectrum[32] + 更新序号。App 侧由 audio isolate 新增 FFI 读（kernel32 OpenFileMappingW 直读，不经 apo_config 进程），sysapo 生效期间 100 ms 轮询并合成与本地引擎同形状的 viz 事件发 UI | UI 消费管线零改动；面板的心跳显示沿用既有 apo_config 通道不变（心跳块保留原样，兼容） |
| D8 | **声道适配**：引擎声道 = APO 声道 ∈ {2,4,6,8} 时直通交织；=1 时复制成双声道处理后取 L 写回；其余（3/5/7/>8）只取前 2 声道以步长适配处理、其余声道原样透传。scratch 在 LockForProcess 按 max_block 预分配 | 引擎只认 {2,4,6,8}；APO 协商接受任意声道 float32（既有口径不收紧，避免格式协商回归） |
| D9 | **延迟报告**：引擎就绪后 `GetLatency` 返回引擎报告的延迟帧数（引擎延迟导出），否则 0 | APO 契约应如实报告，系统侧会做补偿 |
| D10 | **构建与门**：AuraApo 目标新增引擎头包含与运行期加载（不静态链接引擎）；新增 Windows 冒烟 `smoke_apo_engine.py`：独立宿主 exe COM 直驱 CAuraApo（造连接描述符喂已知正弦 + 参数块置 post.gain=0.5 → 断言输出幅度减半、telemetry 座位与电平 sane、in-place 变体同断言），注册进 runner（Windows-only，其余平台 SKIP） | APO 是纯 COM 对象、无需 audiodg 即可在宿主内全链验证——这是本项目唯一可进 CI 的真机替代面；VM/CI 外的 audiodg 实装验收仍属用户真机清单 |

## 5. 分阶实施

| 阶 | 内容 | 验收面 |
|---|---|---|
| P1 | 参数/telemetry 共享块定义（生成器扩展：引擎表 → 索引头 + Dart 索引表 + 漂移门）；isolate 侧 ApoParamPublisher（镜像→块）+ telemetry FFI 读与 viz 事件合成（sysapo 未接引擎前先以「块在流转、telemetry 无座位」状态自检） | 生成门 + Dart 单测（块布局/序号/合成事件）；analyze |
| P2 | 引擎构建纪律（D2）+ AuraApo 引擎宿主：定位/加载/座位/worker/参数应用/APOProcess 真处理/SEH 闩锁/声道适配/延迟报告 | CI J5 编译 + dumpbin 校验步；代码自审 |
| P3 | App 集成：sysapo 生效时 viz/状态面接 telemetry（引擎率/声道/已应用数/fault 显示）；撤下第四轮透传标注行，换真实状态文案；附加/模式进入时触发 publisher 全量重写 | analyze + J6；面板口径走查 |
| P4 | Windows 冒烟宿主 + smoke 注册 + 本文档与活文档收口 + 真机验收清单交接 | CI windows 相关作业 + 本地 runner 登记核对 |

## 6. 风险登记

- **R1 CFG/CRT 纪律若与引擎现状冲突**（引擎现产物导入表未复核）：P2 先复核再定旗标落点；若引擎 DLL 无法满足纪律，退路是 APO 专用引擎副本单独构建（同源不同旗），不得放宽纪律。
- **R2 audiodg 内引擎 create 的重量**：JamesDSP 全局初始化 + FFT 建表在 LockForProcess（音频流重建点）执行，可能给端点切换加可感延迟；worker 化 create（LockForProcess 只登记、worker 建引擎、就绪前透传）为预备方案，P2 实测后定。
- **R3 参数钩子副作用**：custom_set 含 EEL 编译等重活，全在 worker 线程；`liveprog.code` 在 audiodg 内编译 EEL 的稳定性以冒烟 + 真机为据，异常由引擎自身错误口 + SEH 闩锁兜底。
- **R4 座位与多实例竞态**：抢/放座位用 Interlocked CAS + 实例析构兜底释放（Unlock 未达成的异常路径靠 pid 存活校验回收——telemetry 座位记录 owner pid，App 侧发现 pid 已死可提示，APO 侧新实例抢占时校验旧 owner 进程句柄存活）。
- **R5 格式协商回归**：APO 现「只认 float32」口径不动；引擎处理失败（create 失败/ABI 不符）一律落回 v1 透传行为，保证任何情况下不比现状差。
