// ignore: unused_import
import 'package:intl/intl.dart' as intl;

import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for Chinese (`zh`).
class AppLocalizationsZh extends AppLocalizations {
  AppLocalizationsZh([String locale = 'zh']) : super(locale);

  @override
  String get appName => 'AuraDSP';

  @override
  String get navHome => '主页';

  @override
  String get navEffects => '效果';

  @override
  String get navVisualizer => '可视化';

  @override
  String get navSettings => '设置';

  @override
  String get stateProcessing => '处理中';

  @override
  String get stateBypass => '旁路';

  @override
  String get stateError => '失效';

  @override
  String get stateIdle => '空闲';

  @override
  String get vbBuses => 'VB 总线（关=直通）';

  @override
  String get shelfTitle => '低频搁架';

  @override
  String get shelfHint => '分频点以下整体托起/压低，补录音偏瘦的低频或收油腻的轰头';

  @override
  String get shelfFreq => '分频点';

  @override
  String get shelfGain => '增益';

  @override
  String get shelfFreqInfo => '低于该频率整体增减，40~400Hz，一般放 80~120Hz。';

  @override
  String get shelfGainInfo => '托起为正、压低为负；和低音增强是两条路，可叠加但别 double。';

  @override
  String get retryNow => '重试';

  @override
  String get sampleRateFollowBridge => '桥模式跟随 VB/ASIO 设备，此处仅对进程内生效';

  @override
  String get latencyLabel => '延迟';

  @override
  String latencyMs(int n) {
    return '延迟 ${n}ms';
  }

  @override
  String get latencyTip => '算法附加延迟：仅统计引入延迟的效果（如混响 +30ms）；低延迟效果计 0ms';

  @override
  String get bassBoost => '低音增强';

  @override
  String get bassGain => '增强量';

  @override
  String get reverb => '混响';

  @override
  String get reverbPreset => '预设';

  @override
  String get reverbOff => '关闭';

  @override
  String get stereoWiden => '立体声扩展';

  @override
  String get postGain => '输出增益';

  @override
  String get equalizer => '均衡器';

  @override
  String get limiter => '限制器';

  @override
  String get engineInfo => '引擎';

  @override
  String get engineForm => 'Desktop（进程内）';

  @override
  String engineAbi(int a, String v) {
    return 'ABI v$a · $v';
  }

  @override
  String get theme => '配色方案';

  @override
  String get themeAuraDark => 'Aura 暗色';

  @override
  String get themeAuraLight => 'Aura 亮色';

  @override
  String get themeAurora => 'Aurora 氛围';

  @override
  String get language => '语言';

  @override
  String get about => '关于';

  @override
  String get aboutBody =>
      'AuraDSP Engines + AuraDSP UI。DSP 核心基于 libjamesdsp（源码整合，GPL 系许可）。';

  @override
  String get spectrum => '实时频谱';

  @override
  String get noAudio => '空闲 — 无音频流经引擎';

  @override
  String get reverbPreset0 => '音乐厅';

  @override
  String get reverbPreset1 => '小型厅堂';

  @override
  String get reverbPreset2 => '中厅';

  @override
  String get reverbPreset3 => '大会堂';

  @override
  String get reverbPreset4 => '盛大厅堂';

  @override
  String get reverbPreset5 => '大教堂';

  @override
  String get reverbPreset6 => '巨型厅堂';

  @override
  String get reverbPreset7 => '山谷';

  @override
  String get sourceCard => '音频源';

  @override
  String get srcTone => '测试音 440Hz';

  @override
  String get srcPink => '粉噪';

  @override
  String get srcFile => '打开 WAV 文件';

  @override
  String get srcStop => '停止';

  @override
  String get testSrcTitle => '测试音频源';

  @override
  String get testSrcHint => '测量用信号；停止后回到正式源';

  @override
  String get srcMp3 => '打开 MP3 文件';

  @override
  String get bypassOn => '旁路 ON（A/B）';

  @override
  String get bypassOff => '旁路 OFF';

  @override
  String get engineFailed => '引擎初始化失败';

  @override
  String get engineFailedBody =>
      'auradsp_engine.dll 未找到或初始化失败。若 DLL 已随包存在，请查看下方错误详情定位（常见：音频设备/COM 初始化问题）。';

  @override
  String get channelMode => '声道模式';

  @override
  String get channelsStereo => '立体声';

  @override
  String get channels51 => '5.1';

  @override
  String get channels71 => '7.1';

  @override
  String get channelPhaseA => 'Phase A：矩阵下混包络（ADR-003），逐声道实例化将于 Phase B 提供。';

  @override
  String get audioMode => '音频模式';

  @override
  String get audioModeHint => '模式切换即时生效；WASAPI 最终只收敛于 AuraVAIO 模式';

  @override
  String get audioParadigm => '处理范式';

  @override
  String get audioParadigmHint => '选择音频接入形态：附加模式原地挂载处理，普通管线模式端到端流转（ADR-009）';

  @override
  String get paradigmAttachment => '附加模式';

  @override
  String get paradigmPipeline => '普通管线模式';

  @override
  String get modeVoicemeeterApi => 'Voicemeeter API';

  @override
  String get pipelineIn => '输入端';

  @override
  String get pipelineInHint => '选择音频如何进入 AuraDSP 核心处理管线';

  @override
  String get pipelineOut => '输出端';

  @override
  String get pipelineOutHint => '选择经由 AuraDSP 处理后的最终音频送往的目标端点';

  @override
  String get inputWasapi => 'WASAPI 标准模式';

  @override
  String get inputVaio => 'AuraVAIO 虚拟输入';

  @override
  String get inputAsioDriver => 'AuraDSP Virtual ASIO';

  @override
  String get outputWasapi => 'WASAPI 标准输出';

  @override
  String get outputVaio => 'AuraVAIO 虚拟输出';

  @override
  String get outputAsioClient => 'AuraDSP ASIO Client';

  @override
  String get tooltipInputWasapi =>
      'WASAPI 标准模式：支持从系统物理麦克风录制，或对播放设备进行内录/环回 (Loopback) 采集';

  @override
  String get tooltipInputVaio =>
      'AuraVAIO 虚拟输入：接收系统音频或第三方播放器输出至 AuraVAIO 虚拟声卡的立体声/7.1 声道流';

  @override
  String get tooltipInputAsioDriver =>
      'AuraDSP Virtual ASIO：作为虚拟 ASIO 驱动供 FL Studio、Cubase、Ableton 等专业 DAW 宿主调用注入音频';

  @override
  String get tooltipOutputWasapi => 'WASAPI 标准输出：将处理完成的声音输出至物理扬声器、耳机或第三方虚拟输出设备';

  @override
  String get tooltipOutputVaio =>
      'AuraVAIO 虚拟输出：将声音输出至虚拟端点作为数字汇聚，可搭配物理耳机监听镜像使用';

  @override
  String get tooltipOutputAsioClient =>
      'AuraDSP ASIO Client：作为客户端对接外置物理专业 ASIO 声卡，享受超低延迟硬件监听';

  @override
  String get driverLayerTitle => '驱动信息与控制';

  @override
  String get inputLayerTitle => '输入端信息与开关';

  @override
  String get outputLayerTitle => '输出端信息与开关';

  @override
  String get inputDisabledNotice => '输入端已停用（音频采集暂停，处于静音/无输入状态）';

  @override
  String get outputDisabledNotice => '输出端已停用（声音输出静音）';

  @override
  String get inputDeviceLabel => '输入设备';

  @override
  String get outputDeviceLabel => '输出设备';

  @override
  String get defaultInputDevice => '系统默认设备 [内录/环回]';

  @override
  String get defaultOutputDevice => '系统默认输出 (Default Render)';

  @override
  String get tagLoopback => '[内录/环回]';

  @override
  String get tagRecording => '[录制]';

  @override
  String get apoTargetEndpoint => '附加目标端点';

  @override
  String get apoTargetEndpointHint => '选择要挂载 AuraDSP 系统级 APO 处理的音频端点';

  @override
  String get apoStatus => 'APO 挂载状态';

  @override
  String get apoAttached => '已附加';

  @override
  String get apoNotAttached => '未附加';

  @override
  String get apoActionAttach => '一键附加';

  @override
  String get apoActionDetach => '一键卸载';

  @override
  String get asioDriverCardTitle => 'AuraDSP 虚拟 ASIO 驱动';

  @override
  String get asioDriverStatus => '驱动状态';

  @override
  String get asioDriverRegistered => '已在系统注册';

  @override
  String get asioDriverNotRegistered => '未注册';

  @override
  String get asioDriverActionRegister => '一键注册驱动';

  @override
  String get asioDriverActionUnregister => '一键注销驱动';

  @override
  String get asioDawStatus => 'DAW 状态';

  @override
  String get asioDawConnected => '活跃连接中';

  @override
  String get asioDawIdle => '空闲（等待 DAW 接入）';

  @override
  String get asioStatusCheck => '检查状态';

  @override
  String get virtualSinkNotice =>
      '提示：AuraVAIO 为虚拟声卡输出，需在 OBS 或录音软件中选择 AuraVAIO 才能听到声音。';

  @override
  String get monitorMirroring => '本地耳机监听镜像';

  @override
  String get monitorMirroringHint => '在向虚拟声卡推流的同时，分路一份音频到当前物理扬声器/耳机以供本地监听';

  @override
  String get audioDevice => '设备';

  @override
  String get modeAuto => '自动';

  @override
  String get sampleRate => '采样率';

  @override
  String get buffer => '缓冲区';

  @override
  String get modeVaio => 'AuraVAIO';

  @override
  String get modeVb => 'Voicemeeter';

  @override
  String get modeSysApo => 'System APO';

  @override
  String get modeAsio => 'ASIO';

  @override
  String get asioDriver => 'ASIO 驱动';

  @override
  String get asioBufSize => '缓冲档';

  @override
  String get asioBufAuto => '自动（驱动首选）';

  @override
  String get asioOutPair => '输出声道对';

  @override
  String get asioRefresh => '刷新驱动';

  @override
  String get asioSwitches => '回调帧';

  @override
  String asioSrMismatch(String sr, String cfg) {
    return '驱动运行于 $sr Hz，与全局设置 $cfg Hz 不符（ASIO 跟随驱动）';
  }

  @override
  String wasapiSrFallback(String sr, String cfg) {
    return '设备实际 $sr Hz（请求 $cfg Hz 被拒，已回退）';
  }

  @override
  String get asioLatChanged => '驱动已上报延迟变更（重开会话后刷新）';

  @override
  String get asioDropouts => '欠载';

  @override
  String get modeRoot => 'Root';

  @override
  String get modeRootless => 'Rootless';

  @override
  String get modeSystem => '系统';

  @override
  String get modeVirtual => '虚拟';

  @override
  String get modeDriver => '驱动';

  @override
  String get catAppearance => '外观';

  @override
  String get catAudio => '音频';

  @override
  String get catSystem => '系统';

  @override
  String get catTest => '测试';

  @override
  String get pageHomeEyebrow => '控制台';

  @override
  String get pageHomeTitle => '引擎总览';

  @override
  String get pageEffectsEyebrow => '效果链';

  @override
  String get pageEffectsTitle => '音效控制';

  @override
  String get pageVisualizerEyebrow => '分析器';

  @override
  String get pageVisualizerTitle => '实时频谱';

  @override
  String get pageSettingsEyebrow => '偏好';

  @override
  String get pageSettingsTitle => '设置';

  @override
  String get statusLabel => '状态';

  @override
  String get levelsTitle => '电平';

  @override
  String get deviceLabel => '输出设备';

  @override
  String get peakLabel => '峰值';

  @override
  String get themeSwitchTip => '切换配色方案';

  @override
  String get heroHintProcessing => '音频正流经效果链，改动即时生效';

  @override
  String get heroHintIdle => '从下方选择音源开始处理';

  @override
  String get stereoWidenHint => '扩展度已做安全上限保护：过高比例会剥离中置人声（类卡拉OK效应），导致声像空洞';

  @override
  String get railCollapseTip => '收起导航栏';

  @override
  String get railExpandTip => '展开导航栏';

  @override
  String get navLiveprog => '脚本';

  @override
  String get pageLiveprogEyebrow => '实时编程';

  @override
  String get pageLiveprogTitle => '可编程 DSP';

  @override
  String get lpEditor => 'EEL2 编辑器';

  @override
  String get lpEditorHint =>
      '寄存器 spl0/spl1（左右样本）、srate、slider1..8；@init 段需至少一条语句';

  @override
  String get lpApply => '应用并编译';

  @override
  String get lpUnload => '卸载';

  @override
  String get lpNew => '新建模板';

  @override
  String get lpCompileOk => '编译成功，脚本运行中';

  @override
  String get lpNoCode => '尚未加载脚本（使能时直通）';

  @override
  String get lpStatusOk => '运行中';

  @override
  String get lpStatusIdle => '未加载';

  @override
  String get lpStatusError => '编译失败';

  @override
  String get lpErrInitMissing => '缺少 @init 段';

  @override
  String get lpErrInitSyntax => '@init 段语法错误';

  @override
  String get lpErrSampleMissing => '缺少 @sample 段';

  @override
  String get lpErrSampleSyntax => '@sample 段语法错误';

  @override
  String get lpBlockedByLint => '先修复标红的结构问题再应用';

  @override
  String get lpCodeMismatch => '预设存档时的脚本与当前代码不一致，滑块值可能对不上号';

  @override
  String get lpCompiling => '编译中…';

  @override
  String lpCompileTook(String t) {
    return '上次编译耗时 $t';
  }

  @override
  String get lpCompileSlow => '偏慢，连击应用可能卡音频';

  @override
  String lpSkipped(int n) {
    return '$n 个超限或损坏的文件已跳过';
  }

  @override
  String get lpOverwriteTitle => '覆盖确认';

  @override
  String get lpOverwriteBody => '已存在同名脚本，覆盖吗？';

  @override
  String get lpOverwriteAction => '覆盖';

  @override
  String get lpDeleteTitle => '删除脚本';

  @override
  String get lpDeleteBody => '确定删除该脚本文件吗？不可撤销。';

  @override
  String get lpDeleteAction => '删除';

  @override
  String get lpRenameTitle => '重命名脚本';

  @override
  String get lpOpFailed => '操作失败，请重试';

  @override
  String get lpCompiledIdle => '已编译，打开右上角开关才生效';

  @override
  String get lpSliders => '脚本滑块（slider1..8）';

  @override
  String get lpSliderHint => '有声明按声明，无声明默认 0..1；改动实时生效';

  @override
  String get lpLibrary => '脚本库（%APPDATA%/AuraDSP/liveprog）';

  @override
  String get lpLibraryEmpty => '库为空 — 用下方名称框保存当前代码';

  @override
  String get lpSave => '保存到库';

  @override
  String get convTitle => '脉冲响应';

  @override
  String get convOpenIr => '打开 IR 文件';

  @override
  String get convClear => '清除 IR';

  @override
  String get convNoIr => '未加载脉冲文件（支持 WAV / FLAC；含格式嗅探、尺寸限额与健全性校验）';

  @override
  String get convResampled => '源采样率与设备不同，已自动重采样';

  @override
  String get fvTitle => '参数化混响';

  @override
  String get fvDecayLabel => '衰减';

  @override
  String get fvDampLabel => '阻尼';

  @override
  String get fvWetLabel => '湿声';

  @override
  String get fvDryLabel => '干声';

  @override
  String get presetTitle => '预设';

  @override
  String get presetHint =>
      '保存/载入引擎全量参数快照（%APPDATA%/AuraDSP/presets）；T2 效果在音乐档下会被守卫拒绝（诚实提示）';

  @override
  String get presetLoadHint => '点击载入：';

  @override
  String get presetEmpty => '库为空 — 调好参数后用下方名称框保存';

  @override
  String get presetSave => '保存当前';

  @override
  String get presetDelete => '删除';

  @override
  String get presetSaved => '预设已保存';

  @override
  String get presetSaveFail => '保存失败（名称非法或磁盘不可写）';

  @override
  String get presetDirtyBadge => '自定义（未保存）';

  @override
  String get presetDeleted => '预设已删除';

  @override
  String get presetDeleteFail => '删除失败';

  @override
  String get presetLoaded => '预设已载入';

  @override
  String get presetLoadFail => '预设读取失败';

  @override
  String get navPlugins => '插件';

  @override
  String get navChain => '处理链';

  @override
  String get convMix => '混合比例';

  @override
  String get convMixHint => '干湿比：0% = 纯原始信号，100% = 纯卷积结果（默认 100%，等同经典 IR 加载）';

  @override
  String get ddcTitle => 'VDC 空间校正';

  @override
  String get ddcOpen => '打开 VDC 文件';

  @override
  String get ddcNoFile => '未加载校正文件（.vdc：耳机/扬声器空间校正系数，兼容蝰蛇音效 DDC）';

  @override
  String get ddcLoaded => '已加载';

  @override
  String get ddcClear => '清除';

  @override
  String get lpFormat => '格式化';

  @override
  String get convSpectrumTitle => '脉冲频响包络';

  @override
  String get fv3DTitle => '3D 声场渲染';

  @override
  String get advanced => '高级';

  @override
  String get stageTube => '电子管';

  @override
  String get tubeTitle => '电子管模拟器';

  @override
  String get spatialReverbTitle => '空间混响';

  @override
  String get reverbCustom => '自定义';

  @override
  String get reverbRoomSize => '声场尺寸';

  @override
  String get reverbStereoWidth => '声场宽度';

  @override
  String get reverbMix => '混响干湿比';

  @override
  String get eqMultiBand => '多段图形均衡器';

  @override
  String eqBands(int n) {
    return '$n段';
  }

  @override
  String get eqPresets => '预设风格';

  @override
  String get eqFlat => '平直复位';

  @override
  String get eqBypass => '旁路对比';

  @override
  String get eqQFactor => 'Q值锐度';

  @override
  String get eqFilterType => '滤波器架构';

  @override
  String get eqInterpolation => '插值算法';

  @override
  String get bassIntensity => '低音增强强度';

  @override
  String get bassMode => '低音增强模式';

  @override
  String get bassModeDynamic => '自然低音';

  @override
  String get bassModeShelf => '纯净低音';

  @override
  String get bassModeHarmonic => '超重低音';

  @override
  String get bassModeTooltip =>
      '低音增强模式：\n• 自然低音：vendor 直给提升，不加谐波\n• 纯净低音：轻量谐波（0.35），干净有形体\n• 超重低音：重谐波（0.7），小单元也出下潜';

  @override
  String get bassCutoff => '截止频率';

  @override
  String get bassHarmonics => '谐波注入量';

  @override
  String get bassBlend => '谐波色彩平衡';

  @override
  String get bassSubFloor => '下潜保护切除';

  @override
  String get tubeDrive => '饱和驱动度';

  @override
  String get tubeStyle => '电子管音色风格';

  @override
  String get tubeStyleTriode => '经典三极管';

  @override
  String get tubeStylePentode => '现代五极管';

  @override
  String get tubeStyleTape => '模拟磁带温润';

  @override
  String get tubeCompensation => '输出电平补偿';

  @override
  String get tubeMix => '干湿混合比';

  @override
  String get dlgCancel => '取消';

  @override
  String get dlgAdd => '添加';

  @override
  String get dlgSave => '保存';

  @override
  String get dlgLoad => '载入';

  @override
  String get dlgClose => '关闭';

  @override
  String get dlgUnload => '卸载';

  @override
  String get dlgPreset => '预设';

  @override
  String get memTitle => '持久化记忆与配置外置';

  @override
  String get memHint => '自动记录当前所有效果调音状态，并在应用下次启动时无缝恢复。';

  @override
  String get memAutoRestore => '退出时自动保存并恢复会话记忆';

  @override
  String memDir(String path) {
    return '配置存储目录: $path';
  }

  @override
  String get memClear => '清除会话记忆';

  @override
  String get memCleared => '已清除持久化会话记忆，下次启动将使用纯净默认值';

  @override
  String get memReset => '重置外置配置为默认';

  @override
  String get memResetDone => '已重置 config.json 为标准配置模板';

  @override
  String get sysTitle => '系统';

  @override
  String get sysHint => '托盘常驻与开机启动（Windows）';

  @override
  String get sysTray => '最小化到托盘';

  @override
  String get sysTrayHint => '关闭窗口时隐藏到系统托盘，音频继续播放；退出请用托盘菜单';

  @override
  String get sysAutostart => '开机自启';

  @override
  String get sysAutostartHint => '登录 Windows 时自动启动 AuraDSP';

  @override
  String get latUnmeasured => '未测量';

  @override
  String latTipMeasured(String text) {
    return '组件处理延迟（脉冲响应实测）: $text\n点击 ↻ 重新测量（约数十毫秒，不影响正在播放的音频）';
  }

  @override
  String get latTipProbing => '正在测量组件延迟…';

  @override
  String get latTipUnmeasured => '尚未测量该组件的延迟\n点击 ↻ 执行一次脉冲响应实测（约数十毫秒）';

  @override
  String latTipEstimated(String text) {
    return '估算值（非实测）: $text\n来自标称表或解析推算，未经脉冲响应测量';
  }

  @override
  String get eqCanvasHint => '上下拖动调增益 · 双击节点归零 0dB · 双击背景平直复位';

  @override
  String get eqBypassOn => '旁路生效中 (Bypass)';

  @override
  String get eqFilterMinphase => '最小相位 FIR';

  @override
  String get eqFilterIir6 => '6阶 IIR';

  @override
  String get eqFilterIir12 => '12阶 IIR';

  @override
  String get eqInterpMakima => 'Makima (平滑防冲)';

  @override
  String get eqInterpPchip => 'PCHIP (单调保形)';

  @override
  String get eqPresetFlat => '平直 (Flat)';

  @override
  String get eqPresetPop => '流行 (Pop)';

  @override
  String get eqPresetRock => '摇滚 (Rock)';

  @override
  String get eqPresetJazz => '爵士 (Jazz)';

  @override
  String get eqPresetClassical => '古典 (Classical)';

  @override
  String get eqPresetVocal => '人声增强 (Vocal)';

  @override
  String get eqPresetSmile => '微笑增强 (V-Shape)';

  @override
  String get eqPresetBass => '低音强化 (Bass+)';

  @override
  String get eqPresetTreble => '高音清晰 (Treble+)';

  @override
  String get eqPresetCustom => '自定义 (Custom)';

  @override
  String get eqPresetPick => '选择 EQ 风格预设';

  @override
  String get eqQTip => 'Q-Factor 滤波器锐度 (0.3 ~ 10.0)\n垂直拖动调节 · 双击复位 1.41';

  @override
  String get stTube => '电子管';

  @override
  String get stComp => '压限器';

  @override
  String get stBassmono => '低频单声道';

  @override
  String get stGate => '噪声门';

  @override
  String get stFilter => '滤波器';

  @override
  String get filterHint => 'gate 之后的第一道整形：HP 去隆隆声，LP/BP 按需';

  @override
  String get filterType => '类型';

  @override
  String get filterHP => '高通';

  @override
  String get filterLP => '低通';

  @override
  String get filterBP => '带通';

  @override
  String get filterFreq => '频率';

  @override
  String get filterQ => 'Q 值';

  @override
  String get gateHint => '链头第一道：低于阈值的背景噪声被压掉，attack/release 控制开关速度';

  @override
  String get gateThreshold => '阈值';

  @override
  String get gateAttack => '开启时间';

  @override
  String get gateRelease => '释放时间';

  @override
  String get gateAutoGain => '自动增益补偿';

  @override
  String get deesserTitle => '齿音消除';

  @override
  String get deesserFreq => '齿音频段';

  @override
  String get deesserAmount => '压制强度';

  @override
  String get stHaas => '差分环绕';

  @override
  String get stExciter => '激励器';

  @override
  String get stLoudness => '响度补偿';

  @override
  String get stDyneq => '动态EQ';

  @override
  String get dyneqTitle => '动态均衡器';

  @override
  String get dyneqHint => '三段全参数动态均衡：频段能量超阈后自动衰减，阈下只做静态整形';

  @override
  String get dyneqBandLow => '低频段';

  @override
  String get dyneqBandMid => '中频段';

  @override
  String get dyneqBandHigh => '高频段';

  @override
  String get dyneqFreq => '频率';

  @override
  String get dyneqQ => 'Q 值';

  @override
  String get dyneqGain => '静态增益';

  @override
  String get dyneqRange => '动态量';

  @override
  String get dyneqThreshold => '阈值';

  @override
  String get dyneqAttack => '启动时间';

  @override
  String get dyneqRelease => '释放时间';

  @override
  String get loudnessHint => '小音量自动补低频和高频，大音量直通';

  @override
  String get loudnessAmount => '补偿强度';

  @override
  String get exciterHint => '给高频加谐波，压缩音频的空气感来源';

  @override
  String get exciterAmount => '谐波量';

  @override
  String get exciterHifreq => '取频点';

  @override
  String get exciterHifreqInfo => '只取该频率以上成分做谐波。MP3 缺高频时往低调，齿音重时往高调。';

  @override
  String get chainPinnedFirst => '首位钉死';

  @override
  String get chainPinnedLast => '末位钉死';

  @override
  String get haasHint => '延迟侧制造声场宽度，另一侧恒直通保兼容';

  @override
  String get haasDelay => '延迟量';

  @override
  String get haasMix => '差分混合比';

  @override
  String get haasSide => '延迟侧';

  @override
  String get haasSideRight => '右声道';

  @override
  String get haasSideLeft => '左声道';

  @override
  String get fxCatSpatial => '空间';

  @override
  String get fxCatLate => '激励与输出';

  @override
  String get spatialTitle => '空间音效';

  @override
  String get spatialHint => '虚拟 5.0 摆位加早期反射，耳机上重建音箱房。混响 / 脉冲 / 声场卡片已并入本卡';

  @override
  String get spatialStyle => '风格';

  @override
  String get spatialStyleInfo => '风格即整组预设：切换会覆盖房间 / 张角 / 中置（引擎与界面同步）';

  @override
  String get spatialStyleDolby => 'Dolby 房';

  @override
  String get spatialStyleDts => 'DTS 定位';

  @override
  String get spatialStyleNeutral => '中性';

  @override
  String get spatialRoom => '房间';

  @override
  String get spatialRoomInfo => '早期反射电平加反射时间缩放。0 为干摆位，1 为大房';

  @override
  String get spatialWidth => '张角';

  @override
  String get spatialWidthInfo => '扬声器摆位张角缩放。只改变对侧耳声像，同侧直达不变';

  @override
  String get spatialCenter => '中置';

  @override
  String get spatialCenterInfo => '中置声像聚焦：人声对白能量';

  @override
  String get spatialOutGain => '输出';

  @override
  String get spatialOutGainInfo => '空间级输出电平补偿';

  @override
  String get spatialAutoGain => '自动增益';

  @override
  String get spatialAutoGainInfo => '向输入响度收敛（与混响同式），防摆位后忽大忽小';

  @override
  String get src51Fold => '混缩';

  @override
  String get src51Pass => '直通';

  @override
  String get src51Hint => '多声道文件：混缩进引擎处理，直通绕开引擎；设备声道不足时自动回落混缩';

  @override
  String get bassmonoHint => '链头处理：分频点以下单声道化，防小音箱低频破音';

  @override
  String get bassmonoFreq => '分频点';

  @override
  String get stEq => '均衡器';

  @override
  String get stArbmag => '任意响应 EQ';

  @override
  String get stScript => '脚本';

  @override
  String get chainTitle => '处理链';

  @override
  String get chainOrderTitle => '处理顺序与状态';

  @override
  String get chainOrderHint =>
      '拖拽调整信号处理先后（自上而下）；改动后点\"应用\"。支持独立旁路/启用单节点；右侧显示每节点实时双声道电平。';

  @override
  String get chainApply => '应用顺序';

  @override
  String get chainReset => '恢复默认';

  @override
  String get chainReserved => '预留';

  @override
  String get chainGrpInput => '输入整形';

  @override
  String get chainGrpTone => '音色与动态';

  @override
  String get chainGrpEqScript => '均衡与脚本';

  @override
  String get chainGrpSound => '声场';

  @override
  String get chainGrpSpatial => '空间';

  @override
  String get chainGrpOut => '输出段';

  @override
  String get chainFlowTitle => '信号流（当前顺序）';

  @override
  String get chainFlowCaption => '全局信号流顺序示意：';

  @override
  String get chainNodeInput => '输入门控';

  @override
  String get chainNodeLimiter => '主限幅 Limiter';

  @override
  String get chainNodeOutputGate => '输出门控';

  @override
  String get chainNodeOutput => '音频输出';

  @override
  String get lpManual => '参考手册';

  @override
  String get lpManualTitle => 'EEL2 快速参考手册';

  @override
  String get lpManualContent =>
      '【核心音频流寄存器】\n• spl0: 左声道样本值（浮点数，标称 ±1.0）\n• spl1: 右声道样本值（浮点数，标称 ±1.0）\n• srate: 当前设备实际采样率 (Hz)\n\n【交互滑块变量】\n• slider1 ~ slider8: 界面动态滑块参数（默认 0.0 ~ 1.0）\n\n【代码段规范】\n• @init: 脚本加载或重置时执行一次（必须至少包含一条语句）\n• @slider: 用户滑动滑块或参数变动时触发\n• @sample: 每个音频样本点流过时执行';

  @override
  String get lpEditorTooltip =>
      '基于 Cockos EEL2 脚本引擎的实时音频 DSP 编程环境，可在音频流中动态注入自定义算法。';

  @override
  String get exciterMode => '模式';

  @override
  String get exciterModeTooltip => '通过非线性传递函数产生高频泛音与丰富谐波，补偿高频衰减，重塑空气感与通透细节。';

  @override
  String get exciterAmountInfo =>
      '控制注入的高频谐波与原信号的混合比例。适度提升可显著增加声音光泽度，过高可能产生毛刺感。';

  @override
  String get eqModeLabel => '模式';

  @override
  String get eqModeTooltip =>
      '频段模式切换。在频谱画布中上下拖动节点调整增益，双击复位为 0dB，右侧调节选定频点的 Q 值锐度。';

  @override
  String get haasSideTooltip =>
      'Haas 效应差分环绕：将单侧声道延迟 0~25ms，利用双耳到达时间差在耳机中营造自然脱箱的环绕包围感。';

  @override
  String get bassmonoCombinedTooltip =>
      '将设定分频点以下的超低频合并为单声道，消除低频相位抵消与浑浊感，增强低音凝聚力与下潜力度。';

  @override
  String get inputGate => '输入门控';

  @override
  String get inputGain => '总输入增益';

  @override
  String get channelBalance => '声道平衡';

  @override
  String get channelBalanceHint => '每个声道单独控制，默认100%。最终每个声道音量 = 总输入增益 × 单通道控制。';

  @override
  String get channelLeft => '左声道 (L)';

  @override
  String get channelRight => '右声道 (R)';

  @override
  String get inputStageIn => '本级输入';

  @override
  String get inputStageOut => '本级输出';

  @override
  String get chainStagePreDsp => 'DSP 前置';

  @override
  String get chainStagePreVendor => '厂商链前置';

  @override
  String get chainStagePostVendor => '厂商链后置';

  @override
  String get chainStagePostReverb => '混响后置';

  @override
  String get chainStagePostLimiter => '限幅后置';

  @override
  String chainSlotActive(int n, String name, String fmt) {
    return '插槽 $n：$name ($fmt)';
  }

  @override
  String chainSlotEmpty(int n) {
    return '插槽 $n：未挂载插件';
  }

  @override
  String get chainSlotBypassed => '已旁路 (直通)';

  @override
  String get chainSlotProcessing => '正在处理';

  @override
  String chainSlotStatusLine(String a, int b) {
    return '状态：$a • 延迟：$b 采样';
  }

  @override
  String get chainSlotHint => '可在“插件”页面选择效果器加载至本插槽';

  @override
  String get chainOpenGui => '打开原生界面 (GUI)';

  @override
  String get chainBypassed => '已旁路';

  @override
  String get chainEnable => '启用';

  @override
  String lpSaved(String name) {
    return '已保存：$name.eel';
  }

  @override
  String get lpAddDirTitle => '添加外部脚本预设目录';

  @override
  String get lpAddDirPrompt => '请输入包含 .eel / .txt 脚本预设的完整文件夹路径：';

  @override
  String get lpAddDirExample => '例：D:\\AudioScripts\\EelPresets';

  @override
  String lpChars(int n) {
    return '$n 字符';
  }

  @override
  String get lpReady => '语法就绪';

  @override
  String lpIssues(int n) {
    return '$n 处潜在问题';
  }

  @override
  String lpIssueAt(int line, String msg) {
    return '第 $line 行：$msg';
  }

  @override
  String get lpShowAll => '全部 8 槽';

  @override
  String lpAdaptive(int n) {
    return '自适应 ($n)';
  }

  @override
  String get lpNoSliders => '当前代码未声明或引用 slider1..8 参数（纯算法处理）';

  @override
  String get lpExpandSliders => '展开全部 8 槽滑块';

  @override
  String get lpAddDir => '添加外部目录';

  @override
  String get lpSlidersHint => '滑块条已自适应当前脚本声明与引用的 slider 参数；支持点击右上角切换模式。';

  @override
  String get lpLibraryHint => '支持本地 %APPDATA% 库与外部多预设文件夹自动索引。';

  @override
  String get convIrTitle => '脉冲响应 (IR)';

  @override
  String convFramesLine(int frames, String dur, int ch, String peak, int rate) {
    return '$frames 帧 · $dur · ${ch}ch · 峰值 $peak dBFS · 源 ${rate}Hz';
  }

  @override
  String get ddcFilterTitle => 'VDC 滤波器';

  @override
  String get stereoBandActive => '分带生效中';

  @override
  String get stBand0 => '低频段';

  @override
  String get stBand1 => '中低频';

  @override
  String get stBand2 => '中频';

  @override
  String get stBand3 => '中高频';

  @override
  String get stBand4 => '高频';

  @override
  String get stBandHint => '分带微调：各频带基础扩展量将与上方总主控滑块进行动态乘数联动';

  @override
  String get presetFactoryTitle => '出厂经典调音预设';

  @override
  String get presetUserTitle => '我的自定义预设';

  @override
  String get presetUserEmpty => '暂无用户自定义预设 — 调好参数后在下方保存';

  @override
  String presetLoadedFactory(String name) {
    return '已载入出厂预设: $name';
  }

  @override
  String presetLoadedUser(String name) {
    return '已载入自定义预设: $name';
  }

  @override
  String get presetSaveHint => '输入预设名称保存当前状态为用户预设';

  @override
  String get convSpectrumCaption => '32 频带 · 0..1 归一化能量';

  @override
  String get sliderResetTip => '点击重置默认值';

  @override
  String get plugAddDirTitle => '添加插件检索目录';

  @override
  String get plugAddDirPrompt => '请输入或粘贴包含 64 位 VST3 / CLAP 效果器的完整文件夹路径：';

  @override
  String get plugAddDirExample => '例：D:\\AudioPlugins\\VST3';

  @override
  String get plugAddScan => '添加并扫描';

  @override
  String plugPresetTitle(String name) {
    return '插件预设管理 — $name';
  }

  @override
  String get plugPresetSaveLabel => '保存当前参数状态';

  @override
  String get plugPresetNameHint => '输入新预设名称...';

  @override
  String plugPresetList(int n) {
    return '已有预设列表 ($n)';
  }

  @override
  String get plugPresetEmpty => '暂无已保存预设，可通过上方输入框保存。';

  @override
  String get plugTitle => '插件中心';

  @override
  String get plugLibTitle => '第三方效果器库';

  @override
  String get plugLibHint =>
      '系统标准 VST3 / CLAP 64 位插件目录与自定义目录扫描与管理。支持零延迟与前瞻延迟补偿，双声道平面 RT-Safe 运行。';

  @override
  String get plugDeepScan => '深度遍历';

  @override
  String get plugScan => '扫描';

  @override
  String get plugScanning => '正在扫描...';

  @override
  String get plugScanPreparing => '正在枚举插件目录…';

  @override
  String plugScanProgressCount(int done, int total, int found) {
    return '已扫描 $done/$total · 发现 $found 个插件';
  }

  @override
  String get plugScanNoVerify => '快扫不加载插件：仅读取文件元数据，插件在挂载时才验证';

  @override
  String get plugOpenFolder => '打开 VST3 标准目录';

  @override
  String get plugSearchHint => '搜索插件名称、厂商或路径...';

  @override
  String get plugM1Title => 'M1 插件宿主引擎规范';

  @override
  String get plugM1Hint => '多格式进程内宿主已支持 64 位 VST3 与 CLAP 架构。';

  @override
  String get plugFeatSlots => '四槽位对称机架 (Slot 1 ~ Slot 4) 独立管理与并发';

  @override
  String get plugFeatStages => '全音效链阶段插入 (Pre-DSP ~ Post-Limiter)';

  @override
  String get plugFeatGui => '原生 Win32 GUI 弹窗独立消息循环';

  @override
  String get plugFeatPreset => '二进制流预设保存与即时载入恢复';

  @override
  String get plugFeatDirs => '可自定义插件目录检索与本地状态快照';

  @override
  String get plugFeatRt => '平面双声道 RT-Safe 预分配零锁保障';

  @override
  String plugSlot(int n) {
    return '插槽 $n (Slot $n)';
  }

  @override
  String get plugBypassed => '旁路';

  @override
  String get plugCustomTitle => '自定义插件检索目录';

  @override
  String get plugCustomHint => '添加其他硬盘分区或 DAW 的 VST3/CLAP 路径，扫描时将自动合并遍历。';

  @override
  String get plugCustomAdd => '添加目录';

  @override
  String get plugCustomEmpty =>
      '暂未添加自定义目录。除系统默认路径（C:\\Program Files\\Common Files\\VST3 等）外，可点击右上角添加。';

  @override
  String plugMountTitle(int n) {
    return '挂载状态 (插槽 $n)';
  }

  @override
  String plugMountEmpty(int n) {
    return '插槽 $n 暂未挂载第三方插件';
  }

  @override
  String get plugMountEmptyHint => '请在下方效果器库列表中选择已安装的 VST3 / CLAP 插件进行加载';

  @override
  String get plugScanNow => '立即扫描本机已安装插件';

  @override
  String plugMountedTitle(int n) {
    return '当前挂载插件 (插槽 $n)';
  }

  @override
  String plugMountedTitleNamed(int n, String name) {
    return '当前挂载插件 (插槽 $n)：$name';
  }

  @override
  String plugEditorTitleNamed(int n, String name) {
    return '$name（插槽 $n）';
  }

  @override
  String get plugOpenGuiBtn => '打开界面 (GUI)';

  @override
  String get plugUnloadFromSlot => '从当前槽卸载';

  @override
  String plugLoadToSlot(int n) {
    return '载入至插槽 $n';
  }

  @override
  String get plugLatencyLabel => '实测音频延迟';

  @override
  String get plugStageLabel => '信号处理链插入阶段：';

  @override
  String get plugRtNote => '实时动态串联 • 保持 RT-Safe 契约';

  @override
  String get plugFilterAll => '全部';

  @override
  String get plugNoPlugins => '未检测到已安装的第三方插件';

  @override
  String get plugNoPluginsHint =>
      '请确认插件已放置在系统 VST3 / CLAP 路径，或在上方添加自定义插件目录后重新扫描';

  @override
  String get plugNoMatch => '未找到符合当前搜索和过滤条件的插件';

  @override
  String get plugIncompatibleBadge => '32 位不兼容';

  @override
  String get plugIncompatibleHint =>
      '该插件为 32 位版本，AuraDSP 是 64 位宿主，无法加载；请安装对应的 64 位版本。';

  @override
  String plugSlotActive(int n) {
    return '插槽 $n 活跃中';
  }

  @override
  String plugSlotLoaded(int n) {
    return '插槽 $n 已载入';
  }

  @override
  String get plugUnknownVendor => '未知厂商';

  @override
  String get plugThirdParty => '第三方插件';

  @override
  String plugSlotPluginLine(String name, String stage) {
    return '$name • [$stage]';
  }

  @override
  String get plugSlotNoFx => '未挂载效果器';

  @override
  String get chainActive => '生效中';

  @override
  String get chainBypass => '旁路';

  @override
  String get plugActive => '生效';

  @override
  String get lpSaveFailed => '保存失败（名称非法或磁盘不可写）';

  @override
  String get chainVstTitle => '第三方 VST / CLAP 插件挂载槽与阶段处理顺序';

  @override
  String get chainVstHint => '支持多插槽并行挂载；可在下方为每个插件单独设定在全局音频链上的插入阶段与处理先后。';

  @override
  String get compTitle => '动态压限器';

  @override
  String get compTimeconstant => '响应时常数';

  @override
  String get compGranularity => '分析颗粒度';

  @override
  String get compGranularityCoarse => '粗略 (低负荷)';

  @override
  String get compGranularityNormal => '标准 (平衡)';

  @override
  String get compGranularityFine => '精细 (多频带)';

  @override
  String get compTfresolution => '时频分辨率';

  @override
  String get compTfresTransient => '瞬态响应';

  @override
  String get compTfresBalanced => '平衡';

  @override
  String get compTfresFine => '高频解析';

  @override
  String get autoGainCompensation => '自动增益补偿';

  @override
  String get autoGainCompensationTooltip => '随音效提升动态平抑输出电平，防止多级叠加导致削波失真';

  @override
  String get outputGainGate => '输出增益门';

  @override
  String get outputGainGateTooltip => '微调该效果器出口电平 (-12.0 ~ +6.0 dB)';

  @override
  String get arbmagSubtitle => '8192点因果最小相位 FIR 卷积 · 自由频响与 AutoEq 曲线';

  @override
  String get arbmagPresetFlat => '平直 (Flat)';

  @override
  String get arbmagPresetHarman => 'Harman 目标曲线';

  @override
  String get arbmagPresetDiffuse => '扩散场 (Diffuse-Field)';

  @override
  String get arbmagImport => '导入文件';

  @override
  String get arbmagPaste => '剪贴板粘贴';

  @override
  String get arbmagClear => '清空曲线';

  @override
  String get arbmagEmptyHint => '尚未加载曲线。可点击上方预设、导入 AutoEq GraphicEQ 文件或粘贴代码。';

  @override
  String get arbmagEditor => 'GraphicEQ 代码编辑器';

  @override
  String arbmagNodes(int count) {
    return '已载入 $count 个频点';
  }

  @override
  String get arbmagApply => '应用代码';

  @override
  String get arbmagInvalidFormat => 'GraphicEQ 格式错误或未包含有效节点';

  @override
  String get crossfeedTitle => '串扰消除';

  @override
  String get crossfeedMode => '模式';

  @override
  String get crossfeedDesc => '专为耳机设计，通过低通互馈消除头中效应与听觉疲劳';

  @override
  String get crossfeedModeDefault => '默认标准';

  @override
  String get crossfeedModeChuMoy => '经典耳放 (Chu Moy)';

  @override
  String get crossfeedModeJanMeier => '增强互馈 (Jan Meier)';

  @override
  String get crossfeedModeCustom => '自定义';

  @override
  String get crossfeedCutoff => '截止频率';

  @override
  String get crossfeedFeed => '互馈电平';

  @override
  String crossfeedActiveDesc(String mode, String fcut, String feed) {
    return '当前生效：$mode ($fcut Hz, $feed dB)';
  }

  @override
  String get fxCatFront => '前置整形';

  @override
  String get fxCatCore => '核心处理';
}
