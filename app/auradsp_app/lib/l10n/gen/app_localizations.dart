import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_ja.dart';
import 'app_localizations_zh.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'gen/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations? of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations);
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('ja'),
    Locale('zh'),
  ];

  /// No description provided for @appName.
  ///
  /// In zh, this message translates to:
  /// **'AuraDSP'**
  String get appName;

  /// No description provided for @navHome.
  ///
  /// In zh, this message translates to:
  /// **'主页'**
  String get navHome;

  /// No description provided for @navEffects.
  ///
  /// In zh, this message translates to:
  /// **'效果'**
  String get navEffects;

  /// No description provided for @navVisualizer.
  ///
  /// In zh, this message translates to:
  /// **'可视化'**
  String get navVisualizer;

  /// No description provided for @navSettings.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get navSettings;

  /// No description provided for @stateProcessing.
  ///
  /// In zh, this message translates to:
  /// **'处理中'**
  String get stateProcessing;

  /// No description provided for @stateBypass.
  ///
  /// In zh, this message translates to:
  /// **'旁路'**
  String get stateBypass;

  /// No description provided for @stateError.
  ///
  /// In zh, this message translates to:
  /// **'失效'**
  String get stateError;

  /// No description provided for @latencyLabel.
  ///
  /// In zh, this message translates to:
  /// **'延迟'**
  String get latencyLabel;

  /// No description provided for @latencyMs.
  ///
  /// In zh, this message translates to:
  /// **'延迟 {n}ms'**
  String latencyMs(int n);

  /// No description provided for @latencyTip.
  ///
  /// In zh, this message translates to:
  /// **'算法附加延迟：仅统计引入延迟的效果（如混响 +30ms）；低延迟效果计 0ms'**
  String get latencyTip;

  /// No description provided for @latencyMode.
  ///
  /// In zh, this message translates to:
  /// **'延迟模式'**
  String get latencyMode;

  /// No description provided for @latencyRealtime.
  ///
  /// In zh, this message translates to:
  /// **'实时'**
  String get latencyRealtime;

  /// No description provided for @latencyMusic.
  ///
  /// In zh, this message translates to:
  /// **'音乐'**
  String get latencyMusic;

  /// No description provided for @latencyQuality.
  ///
  /// In zh, this message translates to:
  /// **'品质'**
  String get latencyQuality;

  /// No description provided for @latencyRealtimeDesc.
  ///
  /// In zh, this message translates to:
  /// **'≤10ms · 游戏/直播，仅低延迟效果'**
  String get latencyRealtimeDesc;

  /// No description provided for @latencyMusicDesc.
  ///
  /// In zh, this message translates to:
  /// **'≤30ms · 音乐欣赏（推荐）'**
  String get latencyMusicDesc;

  /// No description provided for @latencyQualityDesc.
  ///
  /// In zh, this message translates to:
  /// **'不限 · 观影/听感优先，允许混响等'**
  String get latencyQualityDesc;

  /// No description provided for @bassBoost.
  ///
  /// In zh, this message translates to:
  /// **'低音增强'**
  String get bassBoost;

  /// No description provided for @bassGain.
  ///
  /// In zh, this message translates to:
  /// **'增强量'**
  String get bassGain;

  /// No description provided for @reverb.
  ///
  /// In zh, this message translates to:
  /// **'混响'**
  String get reverb;

  /// No description provided for @reverbPreset.
  ///
  /// In zh, this message translates to:
  /// **'预设'**
  String get reverbPreset;

  /// No description provided for @reverbOff.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get reverbOff;

  /// No description provided for @stereoWiden.
  ///
  /// In zh, this message translates to:
  /// **'声场展宽'**
  String get stereoWiden;

  /// No description provided for @postGain.
  ///
  /// In zh, this message translates to:
  /// **'输出增益'**
  String get postGain;

  /// No description provided for @equalizer.
  ///
  /// In zh, this message translates to:
  /// **'均衡器'**
  String get equalizer;

  /// No description provided for @limiter.
  ///
  /// In zh, this message translates to:
  /// **'限制器'**
  String get limiter;

  /// No description provided for @engineInfo.
  ///
  /// In zh, this message translates to:
  /// **'引擎'**
  String get engineInfo;

  /// No description provided for @engineForm.
  ///
  /// In zh, this message translates to:
  /// **'Desktop（进程内）'**
  String get engineForm;

  /// No description provided for @engineAbi.
  ///
  /// In zh, this message translates to:
  /// **'ABI v{a} · {v}'**
  String engineAbi(int a, String v);

  /// No description provided for @theme.
  ///
  /// In zh, this message translates to:
  /// **'配色方案'**
  String get theme;

  /// No description provided for @themeAuraDark.
  ///
  /// In zh, this message translates to:
  /// **'Aura 暗色'**
  String get themeAuraDark;

  /// No description provided for @themeAuraLight.
  ///
  /// In zh, this message translates to:
  /// **'Aura 亮色'**
  String get themeAuraLight;

  /// No description provided for @themeAurora.
  ///
  /// In zh, this message translates to:
  /// **'Aurora 氛围'**
  String get themeAurora;

  /// No description provided for @language.
  ///
  /// In zh, this message translates to:
  /// **'语言'**
  String get language;

  /// No description provided for @about.
  ///
  /// In zh, this message translates to:
  /// **'关于'**
  String get about;

  /// No description provided for @aboutBody.
  ///
  /// In zh, this message translates to:
  /// **'AuraDSP Engines + AuraDSP UI。DSP 核心基于 libjamesdsp（源码整合，GPL 系许可）。'**
  String get aboutBody;

  /// No description provided for @spectrum.
  ///
  /// In zh, this message translates to:
  /// **'实时频谱'**
  String get spectrum;

  /// No description provided for @noAudio.
  ///
  /// In zh, this message translates to:
  /// **'空闲 — 无音频流经引擎'**
  String get noAudio;

  /// No description provided for @guardBlocked.
  ///
  /// In zh, this message translates to:
  /// **'已拦截：该效果超出当前延迟档预算，切换至品质模式后可用'**
  String get guardBlocked;

  /// No description provided for @reverbPreset0.
  ///
  /// In zh, this message translates to:
  /// **'音乐厅'**
  String get reverbPreset0;

  /// No description provided for @reverbPreset1.
  ///
  /// In zh, this message translates to:
  /// **'小型厅堂'**
  String get reverbPreset1;

  /// No description provided for @reverbPreset2.
  ///
  /// In zh, this message translates to:
  /// **'中厅'**
  String get reverbPreset2;

  /// No description provided for @reverbPreset3.
  ///
  /// In zh, this message translates to:
  /// **'大会堂'**
  String get reverbPreset3;

  /// No description provided for @reverbPreset4.
  ///
  /// In zh, this message translates to:
  /// **'盛大厅堂'**
  String get reverbPreset4;

  /// No description provided for @reverbPreset5.
  ///
  /// In zh, this message translates to:
  /// **'大教堂'**
  String get reverbPreset5;

  /// No description provided for @reverbPreset6.
  ///
  /// In zh, this message translates to:
  /// **'巨型厅堂'**
  String get reverbPreset6;

  /// No description provided for @reverbPreset7.
  ///
  /// In zh, this message translates to:
  /// **'山谷'**
  String get reverbPreset7;

  /// No description provided for @sourceCard.
  ///
  /// In zh, this message translates to:
  /// **'音频源'**
  String get sourceCard;

  /// No description provided for @srcTone.
  ///
  /// In zh, this message translates to:
  /// **'测试音 440Hz'**
  String get srcTone;

  /// No description provided for @srcPink.
  ///
  /// In zh, this message translates to:
  /// **'粉噪'**
  String get srcPink;

  /// No description provided for @srcFile.
  ///
  /// In zh, this message translates to:
  /// **'打开 WAV 文件'**
  String get srcFile;

  /// No description provided for @srcStop.
  ///
  /// In zh, this message translates to:
  /// **'停止'**
  String get srcStop;

  /// No description provided for @bypassOn.
  ///
  /// In zh, this message translates to:
  /// **'旁路 ON（A/B）'**
  String get bypassOn;

  /// No description provided for @bypassOff.
  ///
  /// In zh, this message translates to:
  /// **'旁路 OFF'**
  String get bypassOff;

  /// No description provided for @engineFailed.
  ///
  /// In zh, this message translates to:
  /// **'引擎初始化失败'**
  String get engineFailed;

  /// No description provided for @engineFailedBody.
  ///
  /// In zh, this message translates to:
  /// **'auradsp_engine.dll 未找到或初始化失败。若 DLL 已随包存在，请查看下方错误详情定位（常见：音频设备/COM 初始化问题）。'**
  String get engineFailedBody;

  /// No description provided for @reverbNeedsQuality.
  ///
  /// In zh, this message translates to:
  /// **'品质档限定'**
  String get reverbNeedsQuality;

  /// No description provided for @channelMode.
  ///
  /// In zh, this message translates to:
  /// **'声道模式'**
  String get channelMode;

  /// No description provided for @channelsStereo.
  ///
  /// In zh, this message translates to:
  /// **'立体声'**
  String get channelsStereo;

  /// No description provided for @channels51.
  ///
  /// In zh, this message translates to:
  /// **'5.1'**
  String get channels51;

  /// No description provided for @channels71.
  ///
  /// In zh, this message translates to:
  /// **'7.1'**
  String get channels71;

  /// No description provided for @channelPhaseA.
  ///
  /// In zh, this message translates to:
  /// **'Phase A：矩阵下混包络（ADR-003），逐声道实例化将于 Phase B 提供。'**
  String get channelPhaseA;

  /// No description provided for @pageHomeEyebrow.
  ///
  /// In zh, this message translates to:
  /// **'控制台'**
  String get pageHomeEyebrow;

  /// No description provided for @pageHomeTitle.
  ///
  /// In zh, this message translates to:
  /// **'引擎总览'**
  String get pageHomeTitle;

  /// No description provided for @pageEffectsEyebrow.
  ///
  /// In zh, this message translates to:
  /// **'效果链'**
  String get pageEffectsEyebrow;

  /// No description provided for @pageEffectsTitle.
  ///
  /// In zh, this message translates to:
  /// **'音效控制'**
  String get pageEffectsTitle;

  /// No description provided for @pageVisualizerEyebrow.
  ///
  /// In zh, this message translates to:
  /// **'分析器'**
  String get pageVisualizerEyebrow;

  /// No description provided for @pageVisualizerTitle.
  ///
  /// In zh, this message translates to:
  /// **'实时频谱'**
  String get pageVisualizerTitle;

  /// No description provided for @pageSettingsEyebrow.
  ///
  /// In zh, this message translates to:
  /// **'偏好'**
  String get pageSettingsEyebrow;

  /// No description provided for @pageSettingsTitle.
  ///
  /// In zh, this message translates to:
  /// **'设置'**
  String get pageSettingsTitle;

  /// No description provided for @statusLabel.
  ///
  /// In zh, this message translates to:
  /// **'状态'**
  String get statusLabel;

  /// No description provided for @levelsTitle.
  ///
  /// In zh, this message translates to:
  /// **'电平'**
  String get levelsTitle;

  /// No description provided for @deviceLabel.
  ///
  /// In zh, this message translates to:
  /// **'输出设备'**
  String get deviceLabel;

  /// No description provided for @peakLabel.
  ///
  /// In zh, this message translates to:
  /// **'峰值'**
  String get peakLabel;

  /// No description provided for @themeSwitchTip.
  ///
  /// In zh, this message translates to:
  /// **'切换配色方案'**
  String get themeSwitchTip;

  /// No description provided for @heroHintProcessing.
  ///
  /// In zh, this message translates to:
  /// **'音频正流经效果链，改动即时生效'**
  String get heroHintProcessing;

  /// No description provided for @heroHintIdle.
  ///
  /// In zh, this message translates to:
  /// **'从下方选择音源开始处理'**
  String get heroHintIdle;

  /// No description provided for @reverbAutoQuality.
  ///
  /// In zh, this message translates to:
  /// **'已自动切换到品质延迟档以启用混响'**
  String get reverbAutoQuality;

  /// No description provided for @reverbAutoQualityHint.
  ///
  /// In zh, this message translates to:
  /// **'点击预设会自动切换到品质延迟档（混响为 T2 效果，需要品质档）'**
  String get reverbAutoQualityHint;

  /// No description provided for @stereoWidenHint.
  ///
  /// In zh, this message translates to:
  /// **'展宽已限制在 75%：更高比例会剥离中置人声（类卡拉OK效应），导致几乎无声'**
  String get stereoWidenHint;

  /// No description provided for @railCollapseTip.
  ///
  /// In zh, this message translates to:
  /// **'收起导航栏'**
  String get railCollapseTip;

  /// No description provided for @railExpandTip.
  ///
  /// In zh, this message translates to:
  /// **'展开导航栏'**
  String get railExpandTip;

  /// No description provided for @navLiveprog.
  ///
  /// In zh, this message translates to:
  /// **'脚本'**
  String get navLiveprog;

  /// No description provided for @pageLiveprogEyebrow.
  ///
  /// In zh, this message translates to:
  /// **'实时编程'**
  String get pageLiveprogEyebrow;

  /// No description provided for @pageLiveprogTitle.
  ///
  /// In zh, this message translates to:
  /// **'可编程 DSP'**
  String get pageLiveprogTitle;

  /// No description provided for @lpEditor.
  ///
  /// In zh, this message translates to:
  /// **'EEL2 编辑器'**
  String get lpEditor;

  /// No description provided for @lpEditorHint.
  ///
  /// In zh, this message translates to:
  /// **'寄存器 spl0/spl1（左右样本）、srate、slider1..8；@init 段需至少一条语句'**
  String get lpEditorHint;

  /// No description provided for @lpApply.
  ///
  /// In zh, this message translates to:
  /// **'应用并编译'**
  String get lpApply;

  /// No description provided for @lpUnload.
  ///
  /// In zh, this message translates to:
  /// **'卸载'**
  String get lpUnload;

  /// No description provided for @lpNew.
  ///
  /// In zh, this message translates to:
  /// **'新建模板'**
  String get lpNew;

  /// No description provided for @lpCompileOk.
  ///
  /// In zh, this message translates to:
  /// **'编译成功，脚本运行中'**
  String get lpCompileOk;

  /// No description provided for @lpNoCode.
  ///
  /// In zh, this message translates to:
  /// **'尚未加载脚本（使能时直通）'**
  String get lpNoCode;

  /// No description provided for @lpSliders.
  ///
  /// In zh, this message translates to:
  /// **'脚本滑块（slider1..8）'**
  String get lpSliders;

  /// No description provided for @lpSliderHint.
  ///
  /// In zh, this message translates to:
  /// **'数值域 -1..+4，实际含义由脚本定义；改动实时生效'**
  String get lpSliderHint;

  /// No description provided for @lpLibrary.
  ///
  /// In zh, this message translates to:
  /// **'脚本库（%APPDATA%/AuraDSP/liveprog）'**
  String get lpLibrary;

  /// No description provided for @lpLibraryEmpty.
  ///
  /// In zh, this message translates to:
  /// **'库为空 — 用下方名称框保存当前代码'**
  String get lpLibraryEmpty;

  /// No description provided for @lpSave.
  ///
  /// In zh, this message translates to:
  /// **'保存到库'**
  String get lpSave;

  /// No description provided for @convTitle.
  ///
  /// In zh, this message translates to:
  /// **'脉冲响应'**
  String get convTitle;

  /// No description provided for @convOpenIr.
  ///
  /// In zh, this message translates to:
  /// **'打开 IR 文件'**
  String get convOpenIr;

  /// No description provided for @convClear.
  ///
  /// In zh, this message translates to:
  /// **'清除 IR'**
  String get convClear;

  /// No description provided for @convNoIr.
  ///
  /// In zh, this message translates to:
  /// **'未加载脉冲文件（支持 WAV / FLAC；含格式嗅探、尺寸限额与健全性校验）'**
  String get convNoIr;

  /// No description provided for @convResampled.
  ///
  /// In zh, this message translates to:
  /// **'源采样率与设备不同，已自动重采样（诚实明示，不静默）'**
  String get convResampled;

  /// No description provided for @convAutoQuality.
  ///
  /// In zh, this message translates to:
  /// **'已自动切换到品质延迟档以启用卷积'**
  String get convAutoQuality;

  /// No description provided for @signalFlow.
  ///
  /// In zh, this message translates to:
  /// **'信号流'**
  String get signalFlow;

  /// No description provided for @fvTitle.
  ///
  /// In zh, this message translates to:
  /// **'参数化混响'**
  String get fvTitle;

  /// No description provided for @fvHint.
  ///
  /// In zh, this message translates to:
  /// **'Freeverb 算法（8 组合梳 + 4 全通/声道），与预设混响可并存；品质档限定'**
  String get fvHint;

  /// No description provided for @fvDecayLabel.
  ///
  /// In zh, this message translates to:
  /// **'衰减'**
  String get fvDecayLabel;

  /// No description provided for @fvDampLabel.
  ///
  /// In zh, this message translates to:
  /// **'阻尼'**
  String get fvDampLabel;

  /// No description provided for @fvWetLabel.
  ///
  /// In zh, this message translates to:
  /// **'湿声'**
  String get fvWetLabel;

  /// No description provided for @fvDryLabel.
  ///
  /// In zh, this message translates to:
  /// **'干声'**
  String get fvDryLabel;

  /// No description provided for @presetTitle.
  ///
  /// In zh, this message translates to:
  /// **'预设'**
  String get presetTitle;

  /// No description provided for @presetHint.
  ///
  /// In zh, this message translates to:
  /// **'保存/载入引擎全量参数快照（%APPDATA%/AuraDSP/presets）；T2 效果在音乐档下会被守卫拒绝（诚实提示）'**
  String get presetHint;

  /// No description provided for @presetLoadHint.
  ///
  /// In zh, this message translates to:
  /// **'点击载入：'**
  String get presetLoadHint;

  /// No description provided for @presetEmpty.
  ///
  /// In zh, this message translates to:
  /// **'库为空 — 调好参数后用下方名称框保存'**
  String get presetEmpty;

  /// No description provided for @presetSave.
  ///
  /// In zh, this message translates to:
  /// **'保存当前'**
  String get presetSave;

  /// No description provided for @presetDelete.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get presetDelete;

  /// No description provided for @presetSaved.
  ///
  /// In zh, this message translates to:
  /// **'预设已保存'**
  String get presetSaved;

  /// No description provided for @presetSaveFail.
  ///
  /// In zh, this message translates to:
  /// **'保存失败（名称非法或磁盘不可写）'**
  String get presetSaveFail;

  /// No description provided for @presetDeleted.
  ///
  /// In zh, this message translates to:
  /// **'预设已删除'**
  String get presetDeleted;

  /// No description provided for @presetDeleteFail.
  ///
  /// In zh, this message translates to:
  /// **'删除失败'**
  String get presetDeleteFail;

  /// No description provided for @presetLoaded.
  ///
  /// In zh, this message translates to:
  /// **'预设已载入'**
  String get presetLoaded;

  /// No description provided for @presetLoadFail.
  ///
  /// In zh, this message translates to:
  /// **'预设读取失败'**
  String get presetLoadFail;

  /// No description provided for @navPlugins.
  ///
  /// In zh, this message translates to:
  /// **'插件'**
  String get navPlugins;

  /// No description provided for @navChain.
  ///
  /// In zh, this message translates to:
  /// **'处理链'**
  String get navChain;

  /// No description provided for @convMix.
  ///
  /// In zh, this message translates to:
  /// **'混合比例'**
  String get convMix;

  /// No description provided for @convMixHint.
  ///
  /// In zh, this message translates to:
  /// **'干湿比：0% = 纯原始信号，100% = 纯卷积结果（默认 100%，等同经典 IR 加载）'**
  String get convMixHint;

  /// No description provided for @ddcTitle.
  ///
  /// In zh, this message translates to:
  /// **'VDC 空间校正'**
  String get ddcTitle;

  /// No description provided for @ddcOpen.
  ///
  /// In zh, this message translates to:
  /// **'打开 VDC 文件'**
  String get ddcOpen;

  /// No description provided for @ddcNoFile.
  ///
  /// In zh, this message translates to:
  /// **'未加载校正文件（.vdc：耳机/扬声器空间校正系数，兼容蝰蛇音效 DDC）'**
  String get ddcNoFile;

  /// No description provided for @ddcLoaded.
  ///
  /// In zh, this message translates to:
  /// **'已加载'**
  String get ddcLoaded;

  /// No description provided for @ddcClear.
  ///
  /// In zh, this message translates to:
  /// **'清除'**
  String get ddcClear;

  /// No description provided for @lpFormat.
  ///
  /// In zh, this message translates to:
  /// **'格式化'**
  String get lpFormat;

  /// No description provided for @convSpectrumTitle.
  ///
  /// In zh, this message translates to:
  /// **'脉冲频响包络'**
  String get convSpectrumTitle;

  /// No description provided for @fv3DTitle.
  ///
  /// In zh, this message translates to:
  /// **'3D 声场渲染'**
  String get fv3DTitle;

  /// No description provided for @advanced.
  ///
  /// In zh, this message translates to:
  /// **'高级'**
  String get advanced;

  /// No description provided for @stageTube.
  ///
  /// In zh, this message translates to:
  /// **'电子管'**
  String get stageTube;

  /// No description provided for @tubeTitle.
  ///
  /// In zh, this message translates to:
  /// **'电子管模拟器'**
  String get tubeTitle;

  /// No description provided for @spatialReverbTitle.
  ///
  /// In zh, this message translates to:
  /// **'空间混响'**
  String get spatialReverbTitle;

  /// No description provided for @reverbCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get reverbCustom;

  /// No description provided for @reverbRoomSize.
  ///
  /// In zh, this message translates to:
  /// **'声场尺寸'**
  String get reverbRoomSize;

  /// No description provided for @reverbStereoWidth.
  ///
  /// In zh, this message translates to:
  /// **'声场宽度'**
  String get reverbStereoWidth;

  /// No description provided for @reverbMix.
  ///
  /// In zh, this message translates to:
  /// **'混响干湿比'**
  String get reverbMix;

  /// No description provided for @eqMultiBand.
  ///
  /// In zh, this message translates to:
  /// **'多段图形均衡器'**
  String get eqMultiBand;

  /// No description provided for @eqBands.
  ///
  /// In zh, this message translates to:
  /// **'频段规格'**
  String get eqBands;

  /// No description provided for @eqPresets.
  ///
  /// In zh, this message translates to:
  /// **'预设风格'**
  String get eqPresets;

  /// No description provided for @eqFlat.
  ///
  /// In zh, this message translates to:
  /// **'平直复位'**
  String get eqFlat;

  /// No description provided for @eqBypass.
  ///
  /// In zh, this message translates to:
  /// **'旁路对比'**
  String get eqBypass;

  /// No description provided for @eqQFactor.
  ///
  /// In zh, this message translates to:
  /// **'Q值锐度'**
  String get eqQFactor;

  /// No description provided for @eqFilterType.
  ///
  /// In zh, this message translates to:
  /// **'滤波器架构'**
  String get eqFilterType;

  /// No description provided for @eqInterpolation.
  ///
  /// In zh, this message translates to:
  /// **'插值算法'**
  String get eqInterpolation;

  /// No description provided for @bassIntensity.
  ///
  /// In zh, this message translates to:
  /// **'低音增强强度'**
  String get bassIntensity;

  /// No description provided for @bassMode.
  ///
  /// In zh, this message translates to:
  /// **'低音增强模式'**
  String get bassMode;

  /// No description provided for @bassModeDynamic.
  ///
  /// In zh, this message translates to:
  /// **'动态增强 (DBB)'**
  String get bassModeDynamic;

  /// No description provided for @bassModeShelf.
  ///
  /// In zh, this message translates to:
  /// **'纯净低架 (Shelf)'**
  String get bassModeShelf;

  /// No description provided for @bassModeHarmonic.
  ///
  /// In zh, this message translates to:
  /// **'心理声学谐波'**
  String get bassModeHarmonic;

  /// No description provided for @bassCutoff.
  ///
  /// In zh, this message translates to:
  /// **'截止频率'**
  String get bassCutoff;

  /// No description provided for @bassHarmonics.
  ///
  /// In zh, this message translates to:
  /// **'谐波注入量'**
  String get bassHarmonics;

  /// No description provided for @bassBlend.
  ///
  /// In zh, this message translates to:
  /// **'谐波色彩平衡'**
  String get bassBlend;

  /// No description provided for @bassSubFloor.
  ///
  /// In zh, this message translates to:
  /// **'下潜保护切除'**
  String get bassSubFloor;

  /// No description provided for @tubeDrive.
  ///
  /// In zh, this message translates to:
  /// **'饱和驱动度'**
  String get tubeDrive;

  /// No description provided for @tubeStyle.
  ///
  /// In zh, this message translates to:
  /// **'电子管音色风格'**
  String get tubeStyle;

  /// No description provided for @tubeStyleTriode.
  ///
  /// In zh, this message translates to:
  /// **'经典三极管'**
  String get tubeStyleTriode;

  /// No description provided for @tubeStylePentode.
  ///
  /// In zh, this message translates to:
  /// **'现代五极管'**
  String get tubeStylePentode;

  /// No description provided for @tubeStyleTape.
  ///
  /// In zh, this message translates to:
  /// **'模拟磁带温润'**
  String get tubeStyleTape;

  /// No description provided for @tubeOversampling.
  ///
  /// In zh, this message translates to:
  /// **'高阶抗混叠过采样'**
  String get tubeOversampling;

  /// No description provided for @tubeCompensation.
  ///
  /// In zh, this message translates to:
  /// **'输出电平补偿'**
  String get tubeCompensation;

  /// No description provided for @tubeMix.
  ///
  /// In zh, this message translates to:
  /// **'干湿混合比'**
  String get tubeMix;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'ja', 'zh'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'ja':
      return AppLocalizationsJa();
    case 'zh':
      return AppLocalizationsZh();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
