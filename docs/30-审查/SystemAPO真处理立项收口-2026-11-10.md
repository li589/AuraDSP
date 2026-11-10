# System APO 真处理立项收口（2026-11-10）

> 立项：用户裁定 2026-11-10（第四轮项 1 取证后点选 + 确认）。设计：`docs/10-架构/SystemAPO引擎嵌入设计-2026-11-10.md`（P0 定稿 `527bc66a`，方向锁定更正同提交落地）。
> 结论：**P1–P4 全部落地**。AuraApo 由 v1 透传升级为真处理：座位实例在 audiodg 内加载纪律版引擎 DLL、经共享参数块接收 App 参数、电平/频谱经 telemetry 回传驱动 App 可视化；全部失败路径（抢不到座位、引擎缺失/版本不符、引擎异常）都退回 v1 透传语义，最坏不劣于现状。

## 1. 分阶落地

| 阶 | 提交 | 内容与证据 |
|---|---|---|
| P0 | `527bc66a` | 设计文档（十项决策 D1–D10、风险 R1–R5）+ 活文档方向锁定就地更正（supersede 2026-10-15「sysapo 回归纯配置面」） |
| P1a | `323331ed` | 参数块布局生成器（引擎表 → 325 数值槽 + 4 字符串槽，C/Dart 双产物同源摘要互钉）+ ApoShared.h 契约头 + smoke_apo_param_layout 漂移门（本地 11 项 PASS） |
| P1b | `a9d8f8b6` | isolate 侧 ApoParamPublisher（seqlock 发布）+ ApoTelemetryReader（100ms 轮询合成同形状 viz 事件）；setParam/setParamStr/bypass 三处镜像钩子；setAudioMode 按 sysapo 启停 |
| P2a | `e4c00f41` | APO 专用引擎变体 auradsp_engine_apo.dll（同源另建：/MT + /guard:cf + 无插件；主引擎 /MD 实锤不合纪律，按 R1 退路执行，主引擎零改动）+ smoke_apo_engine_binary PE 纪律门（纯 Python 解析，合成 PE 自验）+ J5 实跑步 |
| P2b | `5ef648a1` | ApoEngineHost（座位 CAS + 旧 owner 死亡回收、D1 三候选加载、worker 50ms 应用参数 + viz 泵、SEH 闩锁、声道适配、延迟报告）+ AuraApo 四处接线 + 驱动 CMake 的 AURADSP_DRIVERS_APO_ONLY + ci.yml 新作业 J5b（APO 家族首次进 CI 编译） |
| P2c | `f71b4a48` | pack.py 随包 auradsp_engine_apo.dll（ApoAssets 四件，缺失 die；与 AuraApo.dll 同级 = D1 首选位）；fixture 同步，本地 ALL PASS |
| P2d | `ea3fb824` | 冒烟准备阶段复核出的两个真洞，见 §2 |
| P3 | `26a9de21` | App 集成：apotelemetry 状态事件 → 五个 AppModel 字段；ready 恢复补 sysapo 分支；面板撤透传标注、换真实状态行（处理中/等待就绪/故障退回直通） |
| P4 | `908c1bd1` | apo_engine_test 进程内端到端冒烟（见 §3）+ J5→J5b artifact 链 + smoke_apo_engine 包装登记 |

## 2. P2d 两洞（未出 VM 即定罪，设计阶段未预见）

1. **首帧清零**：worker 首帧原本全量应用 325 槽，块内未被 App 写过的槽值为 0——会把引擎未触碰参数的非零默认值（comp 阈值等）清零。修：布局插入 64B **有效位图**（mask@64、values@128，生成器统一改版），发布者置位与镜像严格对应，worker 只应用置位槽；字符串槽以 bit 325+s 把门（可表达「显式清空 EEL 代码」）。
2. **创建权**：`Global\` 对象只有服务/管理员令牌能创建，标准用户的 App 进程建参数块必败——原发布者自建路径在生产环境不成立。修：参数块改由 APO（LocalService）在 TryStart 创建并持句柄保活；发布者改「先 Open 既有、不在再试 Create」，皆无时随后续参数变更重试。telemetry 本就 APO 创建，口径自此统一。

另两个实施级偏差（已在提交说明登记）：D2 的校验由 dumpbin 改为纯 Python PE 解析（零工具链依赖、断言面更宽，含导出面）；telemetry 的 peakIn 无独立来源（viz 帧只有输出侧电平），以 peakOut 同值填报并在代码注明暂不具判别力。

## 3. 验证面

- **J5**：纪律版引擎编译 + PE 纪律门（导入表无动态 CRT、CFG 函数表在位、导出面完整）。
- **J5b**：APO 家族 MSVC 编译（此前只有用户本机覆盖）+ apo_engine_test 实跑：锁定后座位归属宿主进程；基线近单位增益；经参数块发布 input.gain=0.25 后输出 RMS 相对基线落入 [0.19, 0.31]（决定性断言）；telemetry 应用计数/更新序号/频谱在动；INPLACE 变体一致；解锁后座位释放。
- **J6 / analyze**：P1/P3 的 Dart 侧（惰性静默路径、状态事件、面板状态行）。
- **本地门**：smoke_apo_param_layout、D4-b、pack fixture 均 PASS。

<!-- CI-FINAL -->

## 4. 已知边界（v1 口径，设计 §1/§6）

- 单引擎座位：同一时刻只有一个端点真处理；同端点 SFX/MFX/EFX 三实例只有一个跑引擎（其余透传），第二端点同理。
- 插件链在 APO 模式下不生效（引擎变体无插件子系统，面板文案已明示）。
- convolver IR / DDC 文件不进 APO（audiodg 的 LPAC 身份读不到用户目录）。**处置口径（用户裁定 2026-11-10 午后）**：不再静默惰性——进 sysapo（含重启直进的 ready 恢复）时若这两节开着则自动关闭并通知；sysapo 期间尝试开启被 setParam 拦截并通知（`AppModel.kApoFileEffectEnables` + `applyApoFileEffectPolicy`）；离开 sysapo 不自动恢复。同日补：telemetry 升 v2，追加 eqIn/stage 分级回传，sysapo 下处理流的分级电平表可动（读者按 version 分级取用）。
- 多声道：{2,4,6,8} 直通；mono 复制处理；3/5/7 与 >8 只处理前两声道、其余直通。
- 参数应用延迟 ≤ ~100ms（worker 50ms 轮询 + App 侧写入）。

## 5. 真机验收清单（用户侧，vm-win10）

1. 全量构建（build_windows.ps1）后安装新包，附加 APO 到物理声卡，进 sysapo 模式播放：应有实际音效（对比第四轮项 1 的无变化）。
2. 拖动任意参数滑杆（如输入增益/EQ），变化应在 ~0.1s 内可闻；App 电平表与频谱应由 APO 回传驱动（面板状态行显示「APO 引擎处理中」）。
3. 面板状态行三态核对：刚进 sysapo 为「等待引擎就绪」，随后转「处理中」；如出现「故障退回直通」请回传双份日志（auradsp_debug.log + _iso.log）。
4. 旁路开关：开启时声音应变直通；关闭恢复处理。
5. 多端点/复合插槽不回归：附加/卸载往返（按端点 ID）与第四轮清单合并验收。
6. 长时播放稳定性：audiodg 不崩（事件查看器无 audiodg/AuraApo 相关错误）；若崩，回传事件查看器的故障模块与偏移。

## 6. Win7/8 适配（2026-11-10 午后，微软官方文档调研后处置）

调研范围：Microsoft Learn 现行文档（驱动/Win32），逐条带出处；以下「未载」即官方现行文档查无此项，不作推断填充。

- **注册模型分版本**：Win7 时代为 LFX（流）/GFX（设备）两槽；Win8.1 起改称 SFX/MFX 并新增 EFX 槽，现行 PKEY_FX_* 槽位口径明文标注「Windows 8.1 and later」。本产品的 apo_config 既有 `win7-sapo` 模式即旧槽位分支——注册层已分版本，无需新增工作。
- **隔离与密钥**：audiodg 受保护进程自 Vista 起；`DisableProtectedAudioDG` 在现行 Learn 中**未载**定义与分版本行为（仅一处称其为 test key，定义页已下线）。本产品各版本统一依赖该值 + 测试签名，文档层无更多可核。audiodg 的 LPAC 引入时点同样未载（AppContainer 本身为 Win8 概念）。
- **API 可用性**：本项目用到的 Global\ 映射创建（服务令牌默认含 SeCreateGlobalPrivilege）、GetModuleHandleEx、IAudioProcessingObject/LockForProcess/APOProcess 均为 Vista/Win7 可用；APO 只实现 IAudioSystemEffects v1，不要求 8.1 的 v2 / Win11 的 v3，版本形状正确。
- **唯一实坑 + 已处理**：含 AppContainer SID（S-1-15-2-*）的 SDDL——该机构 Win7 不存在，其在 Win7 上的解析成败文档未载。已给全部三处共享映射（v1 心跳、参数块、telemetry 块）加退路：主 SDDL 转换失败即退回不含 LPAC ACE 的 `LS+WD` 口径（Win7 语义完整）。Win8+ 主口径一次成功，退路不触发。
- **签名**：Win7 64 位即要求签名（标准 CI 根、嵌入或目录签名）；Win10 1607+ 收紧为微软根；证明签名仅 Win10+。与既有「驱动正式签名是最大外部风险」口径一致，无新增动作。
- **形态底线**：App 本体（Flutter）官方支持面为 Win10+，Win7/8 上只有驱动/APO 组件包可独立安装运行；组件侧按 Win7 基线（_WIN32_WINNT 0x0601）构建。Win7/8 的验收只能是组件级（apo_config 附加 + APO 加载出声），App 级验收不适用于该两版本。
