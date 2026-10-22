# state.dart 拆分方案（入口 + state/ 文件夹）

> 日期：2026-10-22 ｜ 状态：**方案待审**（未动代码）
> 对象：`app/auradsp_app/lib/core/state.dart`（6414 行，单文件单类 `AppModel` 6162 行）

---

## TL;DR

- **策略**：入口 `state.dart` + `state/` 目录 **9 个 part 文件**，类方法按领域迁入
  part 文件中的 **extension**（同类库可访问全部私有成员，编译+运行双验证）。
- **零行为变更、零 API 变更**：34 个导入方的 `import 'core/state.dart'` 与全部
  `model.xxx` 调用原样可用；part 文件共享入口的 import，无需一行 import 改动。
- **入口目标 ~1100 行**（字段清单 + 构造器 + dispose + 小模型类），其余
  ~5300 行按领域入 9 个 260-1300 行的 part 文件。
- **分 7 个阶段迁移**，每阶段 `flutter analyze` + `flutter test`（18 个测试文件）
  双门验证，任一步红即回退该阶段。
- 已实证排除两条歧路：**类体跨 part 文件**（Dart 不允许）、**mixin 自引用**
  （`mixin M on AppModel` 在类定义期解析不到私有成员，编译失败）。

---

## 1. 现状盘点（实测数据）

| 指标 | 值 |
|------|----|
| 文件总行数 | 6414 |
| `AppModel` 类体 | L253-6414，6162 行 |
| 成员总数 | 537（269 方法 + 268 字段，含 getter） |
| 三大巨型方法 | `_onMessage` 940 行（L1359）、`_mirror` 516 行（L2672）、`replaySessionToEngine` 263 行（L2409）——合计占类体 28% |
| 均匀 setter 块 | L3460-4660 约 1200 行、~150 个 `setXxx`（同构：置值→`_mirror`→notify） |
| 头部区（L1-252） | 6 个小类/枚举 + `ParamDefaults` 常量类（246 行） |
| 构造器 / dispose | L1196-1249 / L6363-6414（唯一 `@override`） |
| 外部导入方 | 34 个文件（lib 13 + test 18 + core 3），全部经 `core/state.dart` 单一口径 |
| 外部符号使用 | `AppModel`×351、`ParamDefaults`×125、`PluginInsertStage`×17（在 plugin_manager）、`EngineDisplay`×8、`AudioDeviceItem`×5、`EngineConn`×4、`SavedPluginSlot`×2、`EngineInfo`×1 |

**耦合密度**（类体内引用行数）：`notifyListeners` 257、`config.` 100、`send(` 72、
`scheduleAutoSave` 70、`setParam` 37、`_toIso` 29、`_markSent` 23。
`_onMessage` 调用 53 个不同目标（多为 `pluginManager.onXxx` 转发 + 私有助手）。

**结论**：不存在低耦合的"接缝"可把类拆成多个独立类——几乎所有方法都依赖
`config/send/_mirror/notifyListeners` 这套共享原语与全部效果字段。因此本方案
是**文件级组织重构**（降低单文件认知负荷、按领域归位），不是运行时架构重构。

---

## 2. 拆分机制实验结论（决策依据）

在 `/tmp/dart_test` 用 Dart 3.13 工具链实证（Flutter 3.47.7 同版 analyzer）：

| 机制 | 结果 | 用途 |
|------|------|------|
| 类体跨 part 文件（方法声明在入口、实现体在 part） | ❌ `concrete_class_with_abstract_member` | 排除 |
| `mixin M on AppModel` 自引用 | ❌ 应用时报 `Undefined name '_priv'`（约束在类定义期解析） | 排除 |
| **part 文件 extension 访问同类库私有成员** | ✅ analyze 0 issue + 运行通过（`ext sees private: 1`） | **主路径** |
| extension getter/setter 写私有字段 | ✅ | 主路径 |
| 跨 part 文件的 extension 互调（A 调 B 的助手） | ✅ | 主路径 |
| extension 泛型方法 | ✅（`pick<int>` 运行通过） | 覆盖 `getParam<T>/setParam<T>` |
| **extension 方法 tear-off** | ✅（`final VoidInt cb = m.setThing; cb(7)` 编译+运行通过） | 覆盖 UI 7 处回调直传 |
| part 文件共享入口 import（零 import 改动） | ✅ 语言特性 | 迁移成本主来源消除 |
| 外部经单 import 获得全部 extension | ✅（run.dart 只 import main.dart） | 34 个导入方零改动 |

**tear-off 普查**（UI 直传 `model.method` 作回调的 7 处，均验证可迁）：
`setExciterOversample`、`setTubeOversample`（effects 卡）、`flattenEq`、
`toggleEqBypass`（interactive_eq）、`setAutoRestoreSession`（settings）、
`isApoOperating`×2（settings，getter 条件位）。

---

## 3. 目标结构

```
lib/core/state.dart              ← 入口（目标 ~1100 行）
lib/core/state/
  state_models.dart     (~470)  小模型 + 常量（纯数据，零 AppModel 依赖）
  state_core.dart       (~700)  引擎命令原语 + isolate 生命周期
  state_events.dart     (~1000) _onMessage 事件路由 + 事件去重 + 延迟探测
  state_session.dart    (~600)  会话回放/预设脏跟踪/自动保存/主题本地化/自定义目录
  state_chain.dart      (~700)  处理链 stage/组/顺序 + 立体声链 + Liveprog + 卷积/DDC
  state_effects.dart    (~1250) 全部效果 setter（同构块，按效果分节注释）
  state_eq.dart         (~700)  EQ 网格/频点/曲线/预设/响应 + 静态助手改顶层函数
  state_audio_modes.dart(~750)  音频模式 + ADR-009 管线 + 设备/APO/VAIO/ASIO 驱动管理
  state_vb_asio.dart    (~260)  VB 总线/按路掩码/编辑器选路 + ASIO 运行参数 + VAIO 端点
```

### 入口保留内容（不可迁移部分）

- 文件头 + 全部 import（33 行）+ 9 条 `part` 指令；
- 6 个小类/枚举可迁 `state_models.dart`，但**从入口 re-export 无意义**——
  part 文件本就是同一库，外部 `import 'core/state.dart'` 自动可见；
- `AppModel` 类声明 + **全部 268 个字段**（字段不能进 extension，带 doc 集中
  入口反而是"状态全景图"，便于审查）；
- 构造器（L1196-1249，体内调用 `checkAsioDriverStatus/checkApoStatus/
  _rebuildEqGridForSampleRate/_spawn`——extension 方法在构造器体内可正常调用）；
- `dispose`（唯一 `@override`，必须留类体）。

### 各 part 文件内容明细

**state_models.dart**（L1-252 整体搬迁）
`SavedPluginSlot`、`EngineConn`、`EngineDisplay`、`EngineInfo`、`AudioDeviceItem`、
`GuardRejection`、`ParamDefaults`。纯顶层声明，机械剪切。

**state_core.dart**（引擎命令原语 + isolate 生命周期）
`send`、`setInt`、`setFloat`、`setStringParam`、`getParamById`、`setParamById`、
`getParam<T>`、`setParam<T>`、`mirrorInt`、`isSectionEnabled`、`_mirror`、
`_markSent`、`_spawn`、`_stopAudioIsolate`、`_restartIsolate`、
`_restartIsolateAsync`、`_scheduleFatalRetry`、`_onWindowVisibilityChanged`、
`handleMessageForTesting`、`retryWasapi`、`setSource`。

**state_events.dart**（~1400 行含原语）
`_onMessage`（940 行 isolate 事件路由，含 VB 上升沿回落/插件事件转发/config
事件/APO 心跳等全部 case）、`_admitEngineEvent`、`clearAudioError` 等 4 个
clear、`_onComponentLatencyResult`、`refreshComponentLatency`、
`latencyProbeResource`、`isLatencyProbeSupported`、`hasLatencyRefresh`、
`isProbingLatency`。

**state_session.dart**
`replaySessionToEngine`（263 行）、`saveAsUserPreset`、`loadPreset`、
`scheduleAutoSave`、`scheduleReadback`、`evaluatePresetDirty`、
`addCustomPluginDir/ScriptDir`、`removeCustomPluginDir/ScriptDir`、
`setTheme`、`setLocale`、`setAutoRestoreSession`、`setSampleRate`。

**state_chain.dart**
`filterVendorOrder`、`setGraphOrder`、`stageMeterIndex`、`setChainGroup`、
`isStageEnabled`、`toggleStage`、`_pushStereoChain`、`setStereoMix`、
`setStereoBand`、`resetStereoBand`、`resetStereoWiden`、
`resetStereoBandsToGlobal`、`setStereoEnabled`、Liveprog 四件
（`setLiveprogCode/Enabled/Param`、`unloadLiveprog`）、卷积/DDC 六件
（`setConvolverEnabled`、`loadConvolverIr`、`clearConvolver`、
`parseVdcMetadata`、`loadVdc`、`setDdcEnabled`）、`irWasResampled`（static→
顶层函数）、`_sendBassGain`、`_stepBassRamp`、`_kickBassRamp`、
`_disableBassRamped`（低音斜坡）。

**state_effects.dart**（同构 setter 块 + 少量多行方法）
L3460-4660 全部效果 setter：comp/ddc/bass/spatial/reverb/gate/deesser/
dyneq/loudness/arbmag/filter/shelf/tube/exciter/haas/crossfeed/bassmono/
xfeed/limiter/inputGain 各组 + 9 个 autoGain/outputGain 对 +
`setFreeverbEnabled`、`selectReverbPreset`、`setReverbCustomParam`、
`setSpatialReverbEnabled`、`setSource51Mode`、`setEffectsCategory`、
`_syncHeadTracker`、`_startHeadTracker`、`setBassShapingEnabled`。
文件内按效果分节头注释，150+ 个同构方法审查时可按节跳读。

**state_eq.dart**
`eqGridFor`、`eqOpModeForFilter`、`eqPeakingDb`、`eqTargetGains`（4 个 static
→ 改 part 文件顶层函数，`eqFreqs7/10/15/31` 4 个 static const → 顶层 const）、
`setEqBandsCount`、`setEqBandGain`、`setEqBandQ`、`setEqQ`、`setEqFilter`、
`applyEqCurve`、`applyEqQs`、`fillEqQ`、`applyEqGains`、`setEqInterp`、
`toggleEqBypass`、`flattenEq`、`applyEqPreset`、`_pushEqCurve`、`_flushEqCurve`、
`_rebuildEqGridForSampleRate`、`_scheduleEqResponse`、`composeEqOutputSpectrum`、
`eqOutputSpectrum`、`currentEqCurveSignature`（getter）。

**state_audio_modes.dart**
`setAudioMode`、`setModeCategory`、`setAttachmentMode`、`setPipelineInput`、
`setPipelineOutput`、`setPipelineInputDevice/OutputDevice/InputEnabled/
OutputEnabled`、`refreshAudioDevices`、`_findApoInspectExe`、
`_findVaioInstallScript`、`installVaioDriver`、`uninstallVaioDriver`、
`_findAsioRegisterScript`、`_findApoConfigScript`、`setApoTargetEndpoint`、
`setMonitorMirroring`、`setApoAttached`、`checkAsioDriverStatus`、
`registerAsioDriver`、`unregisterAsioDriver`、`setApoCompositeMode`、
`checkApoStatus`、`attachSystemApo`、`detachSystemApo`。

**state_vb_asio.dart**
`setVbBus`、`setVbPluginGroup`、`setVbPluginGroupAll`、`setVbPluginEditorGroup`、
`_fallbackVbPluginEditorGroup`、`setAsioDriver`、`setAsioBufSize`、
`setAsioOutPair`、`refreshAsioDrivers`、`setVaioOutputEndpoint`、
`refreshVaioDetect`、`_sendAsioRestart`。

---

## 4. 迁移规程（7 阶段，每阶段双门验证）

每阶段完成 = `flutter analyze` 0 issue **且** `flutter test` 全绿
（18 个测试文件；其中 param_contract/config_and_presets/session 相关是行为
等价的关键哨兵）。任一步红 → 只回退该阶段（git 分阶段提交，单阶段回滚
面 ≤400 行搬迁）。

| 阶段 | 内容 | 预计搬迁行数 | 验证重点 |
|------|------|------------|---------|
| P0 | 基线记录：analyze/test 全绿快照 + 行数统计入档 | 0 | 建立对照基线 |
| P1 | `state_models.dart`：6 小类 + `ParamDefaults` 整体切出 | ~470 | 纯顶层声明机械剪切；param_schema/presets 单测 |
| P2 | `state_core.dart`：命令原语 + isolate 生命周期（`_mirror`/`send`/`getParam<T>` 等） | ~700 | param_contract/ir_sample_rate 单测；tear-off 无涉及 |
| P3 | `state_events.dart`：`_onMessage` 等（最大单体） | ~1400 | ui_event_dedup/ui_engine_error_i18n 单测；VB 事件路径 |
| P4 | `state_session.dart` + `state_chain.dart` | ~1300 | config_and_presets/chain_groups/comp_and_ddc/bass_shaping 单测 |
| P5 | `state_effects.dart`（同构 setter 块） | ~1250 | effects_category/ui_stereo_restore 单测 |
| P6 | `state_eq.dart` + `state_audio_modes.dart` + `state_vb_asio.dart` | ~1700 | eq_grid_samplerate/eq_preset_curve/eq_spectrum/settings_* 单测 |
| P7 | 收尾：入口头部导航注释、行数复核、方案文档归档 | 0 | 入口 ≤1200 行、各 part ≤1400 行 |

**机械迁移步骤（每个成员）**：
1. 剪切方法体（含 doc 注释）到目标 part 文件对应 `extension XxxState on AppModel` 内；
2. 类体原位置不留空行疤痕（保持字段区间连续）；
3. 静态成员（`eqGridFor` 等）改顶层函数/常量，类内引用点去掉 `AppModel.`/类名限定
   （若有；实测引用均为裸名）；
4. analyze 红定位到命名冲突/tear-off/泛型三类已知模式，按 §5 缓解处理。

**命名约定**：extension 名 = 文件名派生（`state_eq.dart` → `extension EqState
on AppModel`）；part 文件头固定 `part of '../state.dart';` + 领域说明注释。

---

## 5. 风险登记与缓解

| # | 风险 | 等级 | 缓解 |
|---|------|------|------|
| R1 | extension 名与实例成员撞名（迁移 wholesale 后不应发生） | 低 | analyze 直接报 `ambiguous_extension_member_access`/冲突；wholesale 搬迁不留双份 |
| R2 | 7 处 UI tear-off（`onChanged: model.setExciterOversample` 等） | 低 | 机制已验证（§2）；analyze 兜底 |
| R3 | 泛型方法 `getParam<T>/setParam<T>` 迁 extension | 低 | 已验证；param_contract 单测兜底 |
| R4 | 构造器体内调用迁移后的方法（`checkAsioDriverStatus` 等 4 个） | 低 | 构造器体可调 extension；settings_asio/settings_vaio 单测兜底 |
| R5 | 字段初始化器引用（`eqFrequencies = eqGridFor(...)`） | 低 | 顶层函数在字段初始化器可用（顶层=静态上下文）；eq_grid_samplerate 单测兜底 |
| R6 | 私有助手跨 part 重名（两个 extension 各有一个 `_pushX`） | 低 | 命名带领域前缀；同库撞名 analyze 即报 |
| R7 | `dispose`/构造器误迁 | 低 | 规程明令留类体；diff review 专项检查 |
| R8 | 单阶段搬迁量大导致 review 疲劳 | 中 | 同构 setter 块按"效果"分节搬、按节 review；每阶段独立提交可 bisect |
| R9 | 行为等价性意外（如某方法依赖类内位置——无此类语义） | 低 | Dart 无成员位置语义；analyze+test 双门 |

**明确不做**（边界）：
- 不把 `AppModel` 拆成多个类（无低耦合接缝，见 §1 耦合密度）；
- 不改任何公共 API/导入路径（34 个导入方零改动）；
- 不动 isolate 协议、引擎 ABI、持久化格式；
- 不借机做逻辑重构（搬迁 diff 必须"纯剪切"，review 时可逐字节对 diff）；
- 不引入 mixin（自引用已实证不可行）。

---

## 6. 验证方案

1. **静态门**（每阶段）：`flutter analyze` → No issues found。
2. **单测门**（每阶段）：`flutter test` 18 文件全绿。重点哨兵：
   `param_contract_test`（原语）、`config_and_presets_test`（会话/预设）、
   `eq_grid_samplerate_test`/`eq_preset_curve_test`/`eq_spectrum_test`（EQ）、
   `chain_groups_test`/`comp_and_ddc_chain_test`/`bass_shaping_test`（链）、
   `settings_asio_test`/`settings_vaio_test`/`settings_paradigms_test`（模式/驱动）、
   `ui_event_dedup_test`/`ui_engine_error_i18n_test`（事件）、
   `ui_stereo_restore_test`（立体声恢复）、`effects_category_test`。
3. **构建门**（P7）：`tools/build_windows.ps1 -SkipEngine -Package` +
   `smoke_vm_bridge`（确认 Dart 侧无运行时回归后再交付）。
4. **结构门**（P7）：入口 ≤1200 行、单 part ≤1400 行、9 文件均有领域头注释。
5. **行为等价论证**：diff 审查确认每个阶段为纯剪切（git diff 仅行移动，
   无逻辑字符增删——用 `git diff --cached -M --stat` 辅助确认）。

---

## 7. 工作量与排期建议

| 阶段 | 预估 |
|------|------|
| P0-P2（models/core） | 1 个会话段 |
| P3（events，最大单体） | 1 个会话段 |
| P4-P6（session/chain/effects/eq/modes） | 2-3 个会话段 |
| P7 + 构建冒烟 + 归档 | 1 个会话段 |

建议顺序执行、逐阶段提交（`refactor(state): ...` 系列提交），全部完成后
dev 分支领先 main 的提交数增加但不改行为——可随时在主链验证窗口合并。

---

## 9. 执行日志

### P0 基线（2026-10-22 完成）

- **行数**：`lib/core/state.dart` = 6414 行；入口拆分目标 ~1100 行。
- **analyze**：`flutter analyze` 0 issue。
- **test**：`flutter test` 317 用例。全量套件在本机存在**随机单文件
  加载/超时抖动**（每轮换一个文件，特征 = `loading <file>` 或
  `did not complete`，疑已装 Avast 的 I/O 干扰；并发度 1/4 均复现），
  但**每个测试文件单独跑必全过**。
  → 基线判定规则：analyze 干净 + 18 个文件各自单跑全绿 + 全量允许
  此已知抖动特征（凡全量失败文件，单独复跑必须全过，否则为真红）。
- **P0 附带修复**：`test/plugin_manager_test.dart` 断言未随
  优雅卸载（2026-10-22 两段式派发：先 bypass、150ms 后 unload）同步
  ——全量首跑即真红。已订正并提交 `6a3b274`（独立于重构）。

### P1（state_models.dart）

- **剪切**：state.dart L35-251（SavedPluginSlot / EngineConn / EngineDisplay /
  EngineInfo / AudioDeviceItem / GuardRejection / ParamDefaults 共 217 行）
  → 新建 `lib/core/state/state_models.dart`（part of '../state.dart'）。
  git diff = 1 增 217 删，纯搬运零改行。入口 6414 → 6199 行；part 指令
  置于 import 表之后、AppModel 之前。
- **验证**：analyze 0 issue；全量串行 319/320（唯一失败 =
  settings_vaio_test 已知抖动，单独复跑 3/3 过）。另实测：代码变更后
  **冷跑**（测试内核重编译）会放大超时抖动至 6+ 文件，热跑恢复单文件
  特征——后续各阶段以「热跑」为判定运行。提交 `3f8c02d`。

### P2（state_core.dart）

- **剪切**：20 个成员（send/setInt/setFloat/setStringParam、getParam<T>/
  setParam<T>/getParamById/setParamById/mirrorInt、_mirror/_markSent/
  isSectionEnabled、_spawn/_onWindowVisibilityChanged/_restartIsolate/
  _restartIsolateAsync/_stopAudioIsolate/_scheduleFatalRetry/retryWasapi、
  handleMessageForTesting/setSource）→ `lib/core/state/state_core.dart`
  （770 行，`extension StateCore on AppModel`）。入口 6199 → 5450 行。
  两处字段（_restartToken/_fatalRetries 及其文档注释）按"字段留类体"规则
  未动。机检：14 个原块逐字等价（仅 notifyListeners→_notifyUi 改名）。
- **踩坑（机制实验盲区，已沉淀）**：`notifyListeners()` 是 ChangeNotifier
  `@protected` 成员，extension 不是子类 → 16 个
  invalid_use_of_protected_member/visible_for_testing 警告。解法 =
  类体内加转发 `void _notifyUi() => notifyListeners();`，迁出方法统一改调。
  后续各阶段同法处理（含 P3+ 可能遇到的 addListener 等同类成员）。
- **测试基础设施库感知化**：param_contract_test 的静态链解析器只读
  state.dart 单文件 → convolver.mix 的 setFloat helper 断链、误判
  「无引擎下发」真红。两文件均加 `_readStateLibrary()`（入口+全部 part
  拼源），`_parseMethods` 扩展为同时扫描 `extension … on AppModel` 体；
  config_and_presets_test 5 处源码形状断言同法预改（P3/P4 免再踩）。
- **验证**：analyze 0 issue；param_contract + config_and_presets 单文件
  106/106；全量串行 316 过 + 4 文件已知超时抖动（chain_groups×2、
  settings_asio×2，单独复跑 5/5 全过）。本机抖动率较 P1 升高（疑 Avast
  I/O 干扰加剧），判定规则不变：全量失败文件单独复跑必须全过。

---

## 8. 关联文档

- 今日插件审查报告：`docs/30-审查/插件系统全面审查报告-2026-10-22.md`
- VB 按路体系总结：`docs/20-执行/VB按路插件体系-实施总结-2026-10-22.md`
- part 拆分先例：`lib/features/plugins_page.dart` + `lib/features/plugins/`（450 行入口 + 5 part）
