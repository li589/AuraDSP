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
  String get latencyLabel => '延迟';

  @override
  String latencyMs(int n) {
    return '延迟 ${n}ms';
  }

  @override
  String get latencyTip => '算法附加延迟：仅统计引入延迟的效果（如混响 +30ms）；低延迟效果计 0ms';

  @override
  String get latencyMode => '延迟模式';

  @override
  String get latencyRealtime => '实时';

  @override
  String get latencyMusic => '音乐';

  @override
  String get latencyQuality => '品质';

  @override
  String get latencyRealtimeDesc => '≤10ms · 游戏/直播，仅低延迟效果';

  @override
  String get latencyMusicDesc => '≤30ms · 音乐欣赏（推荐）';

  @override
  String get latencyQualityDesc => '不限 · 观影/听感优先，允许混响等';

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
  String get stereoWiden => '声场展宽';

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
  String get guardBlocked => '已拦截：该效果超出当前延迟档预算，切换至品质模式后可用';

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
  String get bypassOn => '旁路 ON（A/B）';

  @override
  String get bypassOff => '旁路 OFF';

  @override
  String get engineFailed => '引擎初始化失败';

  @override
  String get engineFailedBody =>
      'auradsp_engine.dll 未找到或初始化失败。若 DLL 已随包存在，请查看下方错误详情定位（常见：音频设备/COM 初始化问题）。';

  @override
  String get reverbNeedsQuality => '品质档限定';

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
  String get reverbAutoQuality => '已自动切换到品质延迟档以启用混响';

  @override
  String get reverbAutoQualityHint => '点击预设会自动切换到品质延迟档（混响为 T2 效果，需要品质档）';

  @override
  String get stereoWidenHint => '展宽已限制在 75%：更高比例会剥离中置人声（类卡拉OK效应），导致几乎无声';

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
  String get lpSliders => '脚本滑块（slider1..8）';

  @override
  String get lpSliderHint => '数值域 -1..+4，实际含义由脚本定义；改动实时生效';

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
  String get convResampled => '源采样率与设备不同，已自动重采样（诚实明示，不静默）';

  @override
  String get convAutoQuality => '已自动切换到品质延迟档以启用卷积';

  @override
  String get signalFlow => '信号流';

  @override
  String get fvTitle => '参数化混响';

  @override
  String get fvHint => 'Freeverb 算法（8 组合梳 + 4 全通/声道），与预设混响可并存；品质档限定';

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
  String get eqBands => '频段规格';

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
  String get bassModeDynamic => '动态增强 (DBB)';

  @override
  String get bassModeShelf => '纯净低架 (Shelf)';

  @override
  String get bassModeHarmonic => '心理声学谐波';

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
  String get tubeOversampling => '高阶抗混叠过采样';

  @override
  String get tubeCompensation => '输出电平补偿';

  @override
  String get tubeMix => '干湿混合比';
}
