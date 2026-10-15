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

  /// No description provided for @stateIdle.
  ///
  /// In zh, this message translates to:
  /// **'空闲'**
  String get stateIdle;

  /// No description provided for @vbBuses.
  ///
  /// In zh, this message translates to:
  /// **'VB 总线（关=直通）'**
  String get vbBuses;

  /// No description provided for @shelfTitle.
  ///
  /// In zh, this message translates to:
  /// **'低频搁架'**
  String get shelfTitle;

  /// No description provided for @shelfHint.
  ///
  /// In zh, this message translates to:
  /// **'分频点以下整体托起/压低，补录音偏瘦的低频或收油腻的轰头'**
  String get shelfHint;

  /// No description provided for @shelfFreq.
  ///
  /// In zh, this message translates to:
  /// **'分频点'**
  String get shelfFreq;

  /// No description provided for @shelfGain.
  ///
  /// In zh, this message translates to:
  /// **'增益'**
  String get shelfGain;

  /// No description provided for @shelfFreqInfo.
  ///
  /// In zh, this message translates to:
  /// **'低于该频率整体增减，40~400Hz，一般放 80~120Hz。'**
  String get shelfFreqInfo;

  /// No description provided for @shelfGainInfo.
  ///
  /// In zh, this message translates to:
  /// **'托起为正、压低为负；和低音增强是两条路，可叠加但别 double。'**
  String get shelfGainInfo;

  /// No description provided for @retryNow.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retryNow;

  /// No description provided for @sampleRateFollowBridge.
  ///
  /// In zh, this message translates to:
  /// **'桥模式跟随 VB/ASIO 设备，此处仅对进程内生效'**
  String get sampleRateFollowBridge;

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
  /// **'立体声扩展'**
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

  /// No description provided for @testSrcTitle.
  ///
  /// In zh, this message translates to:
  /// **'测试音频源'**
  String get testSrcTitle;

  /// No description provided for @testSrcHint.
  ///
  /// In zh, this message translates to:
  /// **'测量用信号；停止后回到正式源'**
  String get testSrcHint;

  /// No description provided for @srcMp3.
  ///
  /// In zh, this message translates to:
  /// **'打开 MP3 文件'**
  String get srcMp3;

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

  /// No description provided for @audioMode.
  ///
  /// In zh, this message translates to:
  /// **'音频模式'**
  String get audioMode;

  /// No description provided for @audioModeHint.
  ///
  /// In zh, this message translates to:
  /// **'模式切换即时生效；WASAPI 最终只收敛于 AuraVAIO 模式'**
  String get audioModeHint;

  /// No description provided for @audioDevice.
  ///
  /// In zh, this message translates to:
  /// **'设备'**
  String get audioDevice;

  /// No description provided for @modeAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get modeAuto;

  /// No description provided for @sampleRate.
  ///
  /// In zh, this message translates to:
  /// **'采样率'**
  String get sampleRate;

  /// No description provided for @buffer.
  ///
  /// In zh, this message translates to:
  /// **'缓冲区'**
  String get buffer;

  /// No description provided for @modeVaio.
  ///
  /// In zh, this message translates to:
  /// **'AuraVAIO'**
  String get modeVaio;

  /// No description provided for @modeVb.
  ///
  /// In zh, this message translates to:
  /// **'Voicemeeter'**
  String get modeVb;

  /// No description provided for @modeSysApo.
  ///
  /// In zh, this message translates to:
  /// **'System APO'**
  String get modeSysApo;

  /// No description provided for @modeAsio.
  ///
  /// In zh, this message translates to:
  /// **'ASIO'**
  String get modeAsio;

  /// No description provided for @asioDriver.
  ///
  /// In zh, this message translates to:
  /// **'ASIO 驱动'**
  String get asioDriver;

  /// No description provided for @asioBufSize.
  ///
  /// In zh, this message translates to:
  /// **'缓冲档'**
  String get asioBufSize;

  /// No description provided for @asioBufAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动（驱动首选）'**
  String get asioBufAuto;

  /// No description provided for @asioOutPair.
  ///
  /// In zh, this message translates to:
  /// **'输出声道对'**
  String get asioOutPair;

  /// No description provided for @asioRefresh.
  ///
  /// In zh, this message translates to:
  /// **'刷新驱动'**
  String get asioRefresh;

  /// No description provided for @asioSwitches.
  ///
  /// In zh, this message translates to:
  /// **'回调帧'**
  String get asioSwitches;

  /// No description provided for @asioSrMismatch.
  ///
  /// In zh, this message translates to:
  /// **'驱动运行于 {sr} Hz，与全局设置 {cfg} Hz 不符（ASIO 跟随驱动）'**
  String asioSrMismatch(String sr, String cfg);

  /// No description provided for @wasapiSrFallback.
  ///
  /// In zh, this message translates to:
  /// **'设备实际 {sr} Hz（请求 {cfg} Hz 被拒，已回退）'**
  String wasapiSrFallback(String sr, String cfg);

  /// No description provided for @asioLatChanged.
  ///
  /// In zh, this message translates to:
  /// **'驱动已上报延迟变更（重开会话后刷新）'**
  String get asioLatChanged;

  /// No description provided for @asioDropouts.
  ///
  /// In zh, this message translates to:
  /// **'欠载'**
  String get asioDropouts;

  /// No description provided for @modeRoot.
  ///
  /// In zh, this message translates to:
  /// **'Root'**
  String get modeRoot;

  /// No description provided for @modeRootless.
  ///
  /// In zh, this message translates to:
  /// **'Rootless'**
  String get modeRootless;

  /// No description provided for @modeSystem.
  ///
  /// In zh, this message translates to:
  /// **'系统'**
  String get modeSystem;

  /// No description provided for @modeVirtual.
  ///
  /// In zh, this message translates to:
  /// **'虚拟'**
  String get modeVirtual;

  /// No description provided for @modeDriver.
  ///
  /// In zh, this message translates to:
  /// **'驱动'**
  String get modeDriver;

  /// No description provided for @catAppearance.
  ///
  /// In zh, this message translates to:
  /// **'外观'**
  String get catAppearance;

  /// No description provided for @catAudio.
  ///
  /// In zh, this message translates to:
  /// **'音频'**
  String get catAudio;

  /// No description provided for @catSystem.
  ///
  /// In zh, this message translates to:
  /// **'系统'**
  String get catSystem;

  /// No description provided for @catTest.
  ///
  /// In zh, this message translates to:
  /// **'测试'**
  String get catTest;

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

  /// No description provided for @stereoWidenHint.
  ///
  /// In zh, this message translates to:
  /// **'扩展度已做安全上限保护：过高比例会剥离中置人声（类卡拉OK效应），导致声像空洞'**
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

  /// No description provided for @lpStatusOk.
  ///
  /// In zh, this message translates to:
  /// **'运行中'**
  String get lpStatusOk;

  /// No description provided for @lpStatusIdle.
  ///
  /// In zh, this message translates to:
  /// **'未加载'**
  String get lpStatusIdle;

  /// No description provided for @lpStatusError.
  ///
  /// In zh, this message translates to:
  /// **'编译失败'**
  String get lpStatusError;

  /// No description provided for @lpErrInitMissing.
  ///
  /// In zh, this message translates to:
  /// **'缺少 @init 段'**
  String get lpErrInitMissing;

  /// No description provided for @lpErrInitSyntax.
  ///
  /// In zh, this message translates to:
  /// **'@init 段语法错误'**
  String get lpErrInitSyntax;

  /// No description provided for @lpErrSampleMissing.
  ///
  /// In zh, this message translates to:
  /// **'缺少 @sample 段'**
  String get lpErrSampleMissing;

  /// No description provided for @lpErrSampleSyntax.
  ///
  /// In zh, this message translates to:
  /// **'@sample 段语法错误'**
  String get lpErrSampleSyntax;

  /// No description provided for @lpBlockedByLint.
  ///
  /// In zh, this message translates to:
  /// **'先修复标红的结构问题再应用'**
  String get lpBlockedByLint;

  /// No description provided for @lpCodeMismatch.
  ///
  /// In zh, this message translates to:
  /// **'预设存档时的脚本与当前代码不一致，滑块值可能对不上号'**
  String get lpCodeMismatch;

  /// No description provided for @lpCompiling.
  ///
  /// In zh, this message translates to:
  /// **'编译中…'**
  String get lpCompiling;

  /// No description provided for @lpCompileTook.
  ///
  /// In zh, this message translates to:
  /// **'上次编译耗时 {t}'**
  String lpCompileTook(String t);

  /// No description provided for @lpCompileSlow.
  ///
  /// In zh, this message translates to:
  /// **'偏慢，连击应用可能卡音频'**
  String get lpCompileSlow;

  /// No description provided for @lpSkipped.
  ///
  /// In zh, this message translates to:
  /// **'{n} 个超限或损坏的文件已跳过'**
  String lpSkipped(int n);

  /// No description provided for @lpOverwriteTitle.
  ///
  /// In zh, this message translates to:
  /// **'覆盖确认'**
  String get lpOverwriteTitle;

  /// No description provided for @lpOverwriteBody.
  ///
  /// In zh, this message translates to:
  /// **'已存在同名脚本，覆盖吗？'**
  String get lpOverwriteBody;

  /// No description provided for @lpOverwriteAction.
  ///
  /// In zh, this message translates to:
  /// **'覆盖'**
  String get lpOverwriteAction;

  /// No description provided for @lpDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除脚本'**
  String get lpDeleteTitle;

  /// No description provided for @lpDeleteBody.
  ///
  /// In zh, this message translates to:
  /// **'确定删除该脚本文件吗？不可撤销。'**
  String get lpDeleteBody;

  /// No description provided for @lpDeleteAction.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get lpDeleteAction;

  /// No description provided for @lpRenameTitle.
  ///
  /// In zh, this message translates to:
  /// **'重命名脚本'**
  String get lpRenameTitle;

  /// No description provided for @lpOpFailed.
  ///
  /// In zh, this message translates to:
  /// **'操作失败，请重试'**
  String get lpOpFailed;

  /// No description provided for @lpCompiledIdle.
  ///
  /// In zh, this message translates to:
  /// **'已编译，打开右上角开关才生效'**
  String get lpCompiledIdle;

  /// No description provided for @lpSliders.
  ///
  /// In zh, this message translates to:
  /// **'脚本滑块（slider1..8）'**
  String get lpSliders;

  /// No description provided for @lpSliderHint.
  ///
  /// In zh, this message translates to:
  /// **'有声明按声明，无声明默认 0..1；改动实时生效'**
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
  /// **'源采样率与设备不同，已自动重采样'**
  String get convResampled;

  /// No description provided for @fvTitle.
  ///
  /// In zh, this message translates to:
  /// **'参数化混响'**
  String get fvTitle;

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
  /// **'{n}段'**
  String eqBands(int n);

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
  /// **'自然低音'**
  String get bassModeDynamic;

  /// No description provided for @bassModeShelf.
  ///
  /// In zh, this message translates to:
  /// **'纯净低音'**
  String get bassModeShelf;

  /// No description provided for @bassModeHarmonic.
  ///
  /// In zh, this message translates to:
  /// **'超重低音'**
  String get bassModeHarmonic;

  /// No description provided for @bassModeTooltip.
  ///
  /// In zh, this message translates to:
  /// **'低音增强模式：\n• 自然低音：vendor 直给提升，不加谐波\n• 纯净低音：轻量谐波（0.35），干净有形体\n• 超重低音：重谐波（0.7），小单元也出下潜'**
  String get bassModeTooltip;

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

  /// No description provided for @dlgCancel.
  ///
  /// In zh, this message translates to:
  /// **'取消'**
  String get dlgCancel;

  /// No description provided for @dlgAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加'**
  String get dlgAdd;

  /// No description provided for @dlgSave.
  ///
  /// In zh, this message translates to:
  /// **'保存'**
  String get dlgSave;

  /// No description provided for @dlgLoad.
  ///
  /// In zh, this message translates to:
  /// **'载入'**
  String get dlgLoad;

  /// No description provided for @dlgClose.
  ///
  /// In zh, this message translates to:
  /// **'关闭'**
  String get dlgClose;

  /// No description provided for @dlgUnload.
  ///
  /// In zh, this message translates to:
  /// **'卸载'**
  String get dlgUnload;

  /// No description provided for @dlgPreset.
  ///
  /// In zh, this message translates to:
  /// **'预设'**
  String get dlgPreset;

  /// No description provided for @memTitle.
  ///
  /// In zh, this message translates to:
  /// **'持久化记忆与配置外置'**
  String get memTitle;

  /// No description provided for @memHint.
  ///
  /// In zh, this message translates to:
  /// **'自动记录当前所有效果调音状态，并在应用下次启动时无缝恢复。'**
  String get memHint;

  /// No description provided for @memAutoRestore.
  ///
  /// In zh, this message translates to:
  /// **'退出时自动保存并恢复会话记忆'**
  String get memAutoRestore;

  /// No description provided for @memDir.
  ///
  /// In zh, this message translates to:
  /// **'配置存储目录: {path}'**
  String memDir(String path);

  /// No description provided for @memClear.
  ///
  /// In zh, this message translates to:
  /// **'清除会话记忆'**
  String get memClear;

  /// No description provided for @memCleared.
  ///
  /// In zh, this message translates to:
  /// **'已清除持久化会话记忆，下次启动将使用纯净默认值'**
  String get memCleared;

  /// No description provided for @memReset.
  ///
  /// In zh, this message translates to:
  /// **'重置外置配置为默认'**
  String get memReset;

  /// No description provided for @memResetDone.
  ///
  /// In zh, this message translates to:
  /// **'已重置 config.json 为标准配置模板'**
  String get memResetDone;

  /// No description provided for @latUnmeasured.
  ///
  /// In zh, this message translates to:
  /// **'未测量'**
  String get latUnmeasured;

  /// No description provided for @latTipMeasured.
  ///
  /// In zh, this message translates to:
  /// **'组件处理延迟（脉冲响应实测）: {text}\n点击 ↻ 重新测量（约数十毫秒，不影响正在播放的音频）'**
  String latTipMeasured(String text);

  /// No description provided for @latTipProbing.
  ///
  /// In zh, this message translates to:
  /// **'正在测量组件延迟…'**
  String get latTipProbing;

  /// No description provided for @latTipUnmeasured.
  ///
  /// In zh, this message translates to:
  /// **'尚未测量该组件的延迟\n点击 ↻ 执行一次脉冲响应实测（约数十毫秒）'**
  String get latTipUnmeasured;

  /// No description provided for @eqCanvasHint.
  ///
  /// In zh, this message translates to:
  /// **'上下拖动调增益 · 双击节点归零 0dB · 双击背景平直复位'**
  String get eqCanvasHint;

  /// No description provided for @eqBypassOn.
  ///
  /// In zh, this message translates to:
  /// **'旁路生效中 (Bypass)'**
  String get eqBypassOn;

  /// No description provided for @eqFilterMinphase.
  ///
  /// In zh, this message translates to:
  /// **'最小相位 FIR'**
  String get eqFilterMinphase;

  /// No description provided for @eqFilterIir6.
  ///
  /// In zh, this message translates to:
  /// **'6阶 IIR'**
  String get eqFilterIir6;

  /// No description provided for @eqFilterIir12.
  ///
  /// In zh, this message translates to:
  /// **'12阶 IIR'**
  String get eqFilterIir12;

  /// No description provided for @eqInterpMakima.
  ///
  /// In zh, this message translates to:
  /// **'Makima (平滑防冲)'**
  String get eqInterpMakima;

  /// No description provided for @eqInterpPchip.
  ///
  /// In zh, this message translates to:
  /// **'PCHIP (单调保形)'**
  String get eqInterpPchip;

  /// No description provided for @eqPresetFlat.
  ///
  /// In zh, this message translates to:
  /// **'平直 (Flat)'**
  String get eqPresetFlat;

  /// No description provided for @eqPresetPop.
  ///
  /// In zh, this message translates to:
  /// **'流行 (Pop)'**
  String get eqPresetPop;

  /// No description provided for @eqPresetRock.
  ///
  /// In zh, this message translates to:
  /// **'摇滚 (Rock)'**
  String get eqPresetRock;

  /// No description provided for @eqPresetJazz.
  ///
  /// In zh, this message translates to:
  /// **'爵士 (Jazz)'**
  String get eqPresetJazz;

  /// No description provided for @eqPresetClassical.
  ///
  /// In zh, this message translates to:
  /// **'古典 (Classical)'**
  String get eqPresetClassical;

  /// No description provided for @eqPresetVocal.
  ///
  /// In zh, this message translates to:
  /// **'人声增强 (Vocal)'**
  String get eqPresetVocal;

  /// No description provided for @eqPresetSmile.
  ///
  /// In zh, this message translates to:
  /// **'微笑增强 (V-Shape)'**
  String get eqPresetSmile;

  /// No description provided for @eqPresetBass.
  ///
  /// In zh, this message translates to:
  /// **'低音强化 (Bass+)'**
  String get eqPresetBass;

  /// No description provided for @eqPresetTreble.
  ///
  /// In zh, this message translates to:
  /// **'高音清晰 (Treble+)'**
  String get eqPresetTreble;

  /// No description provided for @eqPresetCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义 (Custom)'**
  String get eqPresetCustom;

  /// No description provided for @eqPresetPick.
  ///
  /// In zh, this message translates to:
  /// **'选择 EQ 风格预设'**
  String get eqPresetPick;

  /// No description provided for @eqQTip.
  ///
  /// In zh, this message translates to:
  /// **'Q-Factor 滤波器锐度 (0.3 ~ 10.0)\n垂直拖动调节 · 双击复位 1.41'**
  String get eqQTip;

  /// No description provided for @stTube.
  ///
  /// In zh, this message translates to:
  /// **'电子管'**
  String get stTube;

  /// No description provided for @stComp.
  ///
  /// In zh, this message translates to:
  /// **'压限器'**
  String get stComp;

  /// No description provided for @stBassmono.
  ///
  /// In zh, this message translates to:
  /// **'低频单声道'**
  String get stBassmono;

  /// No description provided for @stGate.
  ///
  /// In zh, this message translates to:
  /// **'噪声门'**
  String get stGate;

  /// No description provided for @stFilter.
  ///
  /// In zh, this message translates to:
  /// **'滤波器'**
  String get stFilter;

  /// No description provided for @filterHint.
  ///
  /// In zh, this message translates to:
  /// **'gate 之后的第一道整形：HP 去隆隆声，LP/BP 按需'**
  String get filterHint;

  /// No description provided for @filterType.
  ///
  /// In zh, this message translates to:
  /// **'类型'**
  String get filterType;

  /// No description provided for @filterHP.
  ///
  /// In zh, this message translates to:
  /// **'高通'**
  String get filterHP;

  /// No description provided for @filterLP.
  ///
  /// In zh, this message translates to:
  /// **'低通'**
  String get filterLP;

  /// No description provided for @filterBP.
  ///
  /// In zh, this message translates to:
  /// **'带通'**
  String get filterBP;

  /// No description provided for @filterFreq.
  ///
  /// In zh, this message translates to:
  /// **'频率'**
  String get filterFreq;

  /// No description provided for @filterQ.
  ///
  /// In zh, this message translates to:
  /// **'Q 值'**
  String get filterQ;

  /// No description provided for @gateHint.
  ///
  /// In zh, this message translates to:
  /// **'链头第一道：低于阈值的背景噪声被压掉，attack/release 控制开关速度'**
  String get gateHint;

  /// No description provided for @gateThreshold.
  ///
  /// In zh, this message translates to:
  /// **'阈值'**
  String get gateThreshold;

  /// No description provided for @gateAttack.
  ///
  /// In zh, this message translates to:
  /// **'开启时间'**
  String get gateAttack;

  /// No description provided for @gateRelease.
  ///
  /// In zh, this message translates to:
  /// **'释放时间'**
  String get gateRelease;

  /// No description provided for @gateAutoGain.
  ///
  /// In zh, this message translates to:
  /// **'自动增益补偿'**
  String get gateAutoGain;

  /// No description provided for @deesserTitle.
  ///
  /// In zh, this message translates to:
  /// **'齿音消除'**
  String get deesserTitle;

  /// No description provided for @deesserFreq.
  ///
  /// In zh, this message translates to:
  /// **'齿音频段'**
  String get deesserFreq;

  /// No description provided for @deesserAmount.
  ///
  /// In zh, this message translates to:
  /// **'压制强度'**
  String get deesserAmount;

  /// No description provided for @stHaas.
  ///
  /// In zh, this message translates to:
  /// **'差分环绕'**
  String get stHaas;

  /// No description provided for @stExciter.
  ///
  /// In zh, this message translates to:
  /// **'激励器'**
  String get stExciter;

  /// No description provided for @stLoudness.
  ///
  /// In zh, this message translates to:
  /// **'响度补偿'**
  String get stLoudness;

  /// No description provided for @stDyneq.
  ///
  /// In zh, this message translates to:
  /// **'动态EQ'**
  String get stDyneq;

  /// No description provided for @dyneqTitle.
  ///
  /// In zh, this message translates to:
  /// **'动态均衡器'**
  String get dyneqTitle;

  /// No description provided for @dyneqHint.
  ///
  /// In zh, this message translates to:
  /// **'三段全参数动态均衡：频段能量超阈后自动衰减，阈下只做静态整形'**
  String get dyneqHint;

  /// No description provided for @dyneqBandLow.
  ///
  /// In zh, this message translates to:
  /// **'低频段'**
  String get dyneqBandLow;

  /// No description provided for @dyneqBandMid.
  ///
  /// In zh, this message translates to:
  /// **'中频段'**
  String get dyneqBandMid;

  /// No description provided for @dyneqBandHigh.
  ///
  /// In zh, this message translates to:
  /// **'高频段'**
  String get dyneqBandHigh;

  /// No description provided for @dyneqFreq.
  ///
  /// In zh, this message translates to:
  /// **'频率'**
  String get dyneqFreq;

  /// No description provided for @dyneqQ.
  ///
  /// In zh, this message translates to:
  /// **'Q 值'**
  String get dyneqQ;

  /// No description provided for @dyneqGain.
  ///
  /// In zh, this message translates to:
  /// **'静态增益'**
  String get dyneqGain;

  /// No description provided for @dyneqRange.
  ///
  /// In zh, this message translates to:
  /// **'动态量'**
  String get dyneqRange;

  /// No description provided for @dyneqThreshold.
  ///
  /// In zh, this message translates to:
  /// **'阈值'**
  String get dyneqThreshold;

  /// No description provided for @dyneqAttack.
  ///
  /// In zh, this message translates to:
  /// **'启动时间'**
  String get dyneqAttack;

  /// No description provided for @dyneqRelease.
  ///
  /// In zh, this message translates to:
  /// **'释放时间'**
  String get dyneqRelease;

  /// No description provided for @loudnessHint.
  ///
  /// In zh, this message translates to:
  /// **'小音量自动补低频和高频，大音量直通'**
  String get loudnessHint;

  /// No description provided for @loudnessAmount.
  ///
  /// In zh, this message translates to:
  /// **'补偿强度'**
  String get loudnessAmount;

  /// No description provided for @exciterHint.
  ///
  /// In zh, this message translates to:
  /// **'给高频加谐波，压缩音频的空气感来源'**
  String get exciterHint;

  /// No description provided for @exciterAmount.
  ///
  /// In zh, this message translates to:
  /// **'谐波量'**
  String get exciterAmount;

  /// No description provided for @exciterHifreq.
  ///
  /// In zh, this message translates to:
  /// **'取频点'**
  String get exciterHifreq;

  /// No description provided for @exciterHifreqInfo.
  ///
  /// In zh, this message translates to:
  /// **'只取该频率以上成分做谐波。MP3 缺高频时往低调，齿音重时往高调。'**
  String get exciterHifreqInfo;

  /// No description provided for @chainPinnedFirst.
  ///
  /// In zh, this message translates to:
  /// **'首位钉死'**
  String get chainPinnedFirst;

  /// No description provided for @chainPinnedLast.
  ///
  /// In zh, this message translates to:
  /// **'末位钉死'**
  String get chainPinnedLast;

  /// No description provided for @haasHint.
  ///
  /// In zh, this message translates to:
  /// **'延迟侧制造声场宽度，另一侧恒直通保兼容'**
  String get haasHint;

  /// No description provided for @haasDelay.
  ///
  /// In zh, this message translates to:
  /// **'延迟量'**
  String get haasDelay;

  /// No description provided for @haasMix.
  ///
  /// In zh, this message translates to:
  /// **'差分混合比'**
  String get haasMix;

  /// No description provided for @haasSide.
  ///
  /// In zh, this message translates to:
  /// **'延迟侧'**
  String get haasSide;

  /// No description provided for @haasSideRight.
  ///
  /// In zh, this message translates to:
  /// **'右声道'**
  String get haasSideRight;

  /// No description provided for @haasSideLeft.
  ///
  /// In zh, this message translates to:
  /// **'左声道'**
  String get haasSideLeft;

  /// No description provided for @bassmonoHint.
  ///
  /// In zh, this message translates to:
  /// **'链头处理：分频点以下单声道化，防小音箱低频破音'**
  String get bassmonoHint;

  /// No description provided for @bassmonoFreq.
  ///
  /// In zh, this message translates to:
  /// **'分频点'**
  String get bassmonoFreq;

  /// No description provided for @stEq.
  ///
  /// In zh, this message translates to:
  /// **'均衡器'**
  String get stEq;

  /// No description provided for @stArbmag.
  ///
  /// In zh, this message translates to:
  /// **'任意响应 EQ'**
  String get stArbmag;

  /// No description provided for @stScript.
  ///
  /// In zh, this message translates to:
  /// **'脚本'**
  String get stScript;

  /// No description provided for @chainTitle.
  ///
  /// In zh, this message translates to:
  /// **'处理链'**
  String get chainTitle;

  /// No description provided for @chainOrderTitle.
  ///
  /// In zh, this message translates to:
  /// **'处理顺序与状态'**
  String get chainOrderTitle;

  /// No description provided for @chainOrderHint.
  ///
  /// In zh, this message translates to:
  /// **'拖拽调整信号处理先后（自上而下）；改动后点\"应用\"。支持独立旁路/启用单节点；右侧显示每节点实时双声道电平。'**
  String get chainOrderHint;

  /// No description provided for @chainApply.
  ///
  /// In zh, this message translates to:
  /// **'应用顺序'**
  String get chainApply;

  /// No description provided for @chainReset.
  ///
  /// In zh, this message translates to:
  /// **'恢复默认'**
  String get chainReset;

  /// No description provided for @chainReserved.
  ///
  /// In zh, this message translates to:
  /// **'预留'**
  String get chainReserved;

  /// No description provided for @chainFlowTitle.
  ///
  /// In zh, this message translates to:
  /// **'信号流（当前顺序）'**
  String get chainFlowTitle;

  /// No description provided for @chainFlowCaption.
  ///
  /// In zh, this message translates to:
  /// **'全局信号流顺序示意：'**
  String get chainFlowCaption;

  /// No description provided for @chainNodeInput.
  ///
  /// In zh, this message translates to:
  /// **'输入门控'**
  String get chainNodeInput;

  /// No description provided for @chainNodeLimiter.
  ///
  /// In zh, this message translates to:
  /// **'主限幅 Limiter'**
  String get chainNodeLimiter;

  /// No description provided for @chainNodeOutputGate.
  ///
  /// In zh, this message translates to:
  /// **'输出门控'**
  String get chainNodeOutputGate;

  /// No description provided for @chainNodeOutput.
  ///
  /// In zh, this message translates to:
  /// **'音频输出'**
  String get chainNodeOutput;

  /// No description provided for @lpManual.
  ///
  /// In zh, this message translates to:
  /// **'参考手册'**
  String get lpManual;

  /// No description provided for @lpManualTitle.
  ///
  /// In zh, this message translates to:
  /// **'EEL2 快速参考手册'**
  String get lpManualTitle;

  /// No description provided for @lpManualContent.
  ///
  /// In zh, this message translates to:
  /// **'【核心音频流寄存器】\n• spl0: 左声道样本值（浮点数，标称 ±1.0）\n• spl1: 右声道样本值（浮点数，标称 ±1.0）\n• srate: 当前设备实际采样率 (Hz)\n\n【交互滑块变量】\n• slider1 ~ slider8: 界面动态滑块参数（默认 0.0 ~ 1.0）\n\n【代码段规范】\n• @init: 脚本加载或重置时执行一次（必须至少包含一条语句）\n• @slider: 用户滑动滑块或参数变动时触发\n• @sample: 每个音频样本点流过时执行'**
  String get lpManualContent;

  /// No description provided for @lpEditorTooltip.
  ///
  /// In zh, this message translates to:
  /// **'基于 Cockos EEL2 脚本引擎的实时音频 DSP 编程环境，可在音频流中动态注入自定义算法。'**
  String get lpEditorTooltip;

  /// No description provided for @exciterMode.
  ///
  /// In zh, this message translates to:
  /// **'模式'**
  String get exciterMode;

  /// No description provided for @exciterModeTooltip.
  ///
  /// In zh, this message translates to:
  /// **'通过非线性传递函数产生高频泛音与丰富谐波，补偿高频衰减，重塑空气感与通透细节。'**
  String get exciterModeTooltip;

  /// No description provided for @exciterAmountInfo.
  ///
  /// In zh, this message translates to:
  /// **'控制注入的高频谐波与原信号的混合比例。适度提升可显著增加声音光泽度，过高可能产生毛刺感。'**
  String get exciterAmountInfo;

  /// No description provided for @eqModeLabel.
  ///
  /// In zh, this message translates to:
  /// **'模式'**
  String get eqModeLabel;

  /// No description provided for @eqModeTooltip.
  ///
  /// In zh, this message translates to:
  /// **'频段模式切换。在频谱画布中上下拖动节点调整增益，双击复位为 0dB，右侧调节选定频点的 Q 值锐度。'**
  String get eqModeTooltip;

  /// No description provided for @haasSideTooltip.
  ///
  /// In zh, this message translates to:
  /// **'Haas 效应差分环绕：将单侧声道延迟 0~25ms，利用双耳到达时间差在耳机中营造自然脱箱的环绕包围感。'**
  String get haasSideTooltip;

  /// No description provided for @bassmonoCombinedTooltip.
  ///
  /// In zh, this message translates to:
  /// **'将设定分频点以下的超低频合并为单声道，消除低频相位抵消与浑浊感，增强低音凝聚力与下潜力度。'**
  String get bassmonoCombinedTooltip;

  /// No description provided for @inputGate.
  ///
  /// In zh, this message translates to:
  /// **'输入门控'**
  String get inputGate;

  /// No description provided for @inputGain.
  ///
  /// In zh, this message translates to:
  /// **'总输入增益'**
  String get inputGain;

  /// No description provided for @channelBalance.
  ///
  /// In zh, this message translates to:
  /// **'声道平衡'**
  String get channelBalance;

  /// No description provided for @channelBalanceHint.
  ///
  /// In zh, this message translates to:
  /// **'每个声道单独控制，默认100%。最终每个声道音量 = 总输入增益 × 单通道控制。'**
  String get channelBalanceHint;

  /// No description provided for @channelLeft.
  ///
  /// In zh, this message translates to:
  /// **'左声道 (L)'**
  String get channelLeft;

  /// No description provided for @channelRight.
  ///
  /// In zh, this message translates to:
  /// **'右声道 (R)'**
  String get channelRight;

  /// No description provided for @inputStageIn.
  ///
  /// In zh, this message translates to:
  /// **'本级输入'**
  String get inputStageIn;

  /// No description provided for @inputStageOut.
  ///
  /// In zh, this message translates to:
  /// **'本级输出'**
  String get inputStageOut;

  /// No description provided for @chainStagePreDsp.
  ///
  /// In zh, this message translates to:
  /// **'DSP 前置'**
  String get chainStagePreDsp;

  /// No description provided for @chainStagePreVendor.
  ///
  /// In zh, this message translates to:
  /// **'厂商链前置'**
  String get chainStagePreVendor;

  /// No description provided for @chainStagePostVendor.
  ///
  /// In zh, this message translates to:
  /// **'厂商链后置'**
  String get chainStagePostVendor;

  /// No description provided for @chainStagePostReverb.
  ///
  /// In zh, this message translates to:
  /// **'混响后置'**
  String get chainStagePostReverb;

  /// No description provided for @chainStagePostLimiter.
  ///
  /// In zh, this message translates to:
  /// **'限幅后置'**
  String get chainStagePostLimiter;

  /// No description provided for @chainSlotActive.
  ///
  /// In zh, this message translates to:
  /// **'插槽 {n}：{name} ({fmt})'**
  String chainSlotActive(int n, String name, String fmt);

  /// No description provided for @chainSlotEmpty.
  ///
  /// In zh, this message translates to:
  /// **'插槽 {n}：未挂载插件'**
  String chainSlotEmpty(int n);

  /// No description provided for @chainSlotBypassed.
  ///
  /// In zh, this message translates to:
  /// **'已旁路 (直通)'**
  String get chainSlotBypassed;

  /// No description provided for @chainSlotProcessing.
  ///
  /// In zh, this message translates to:
  /// **'正在处理'**
  String get chainSlotProcessing;

  /// No description provided for @chainSlotStatusLine.
  ///
  /// In zh, this message translates to:
  /// **'状态：{a} • 延迟：{b} 采样'**
  String chainSlotStatusLine(String a, int b);

  /// No description provided for @chainSlotHint.
  ///
  /// In zh, this message translates to:
  /// **'可在“插件”页面选择效果器加载至本插槽'**
  String get chainSlotHint;

  /// No description provided for @chainOpenGui.
  ///
  /// In zh, this message translates to:
  /// **'打开原生界面 (GUI)'**
  String get chainOpenGui;

  /// No description provided for @chainBypassed.
  ///
  /// In zh, this message translates to:
  /// **'已旁路'**
  String get chainBypassed;

  /// No description provided for @chainEnable.
  ///
  /// In zh, this message translates to:
  /// **'启用'**
  String get chainEnable;

  /// No description provided for @lpSaved.
  ///
  /// In zh, this message translates to:
  /// **'已保存：{name}.eel'**
  String lpSaved(String name);

  /// No description provided for @lpAddDirTitle.
  ///
  /// In zh, this message translates to:
  /// **'添加外部脚本预设目录'**
  String get lpAddDirTitle;

  /// No description provided for @lpAddDirPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入包含 .eel / .txt 脚本预设的完整文件夹路径：'**
  String get lpAddDirPrompt;

  /// No description provided for @lpAddDirExample.
  ///
  /// In zh, this message translates to:
  /// **'例：D:\\AudioScripts\\EelPresets'**
  String get lpAddDirExample;

  /// No description provided for @lpChars.
  ///
  /// In zh, this message translates to:
  /// **'{n} 字符'**
  String lpChars(int n);

  /// No description provided for @lpReady.
  ///
  /// In zh, this message translates to:
  /// **'语法就绪'**
  String get lpReady;

  /// No description provided for @lpIssues.
  ///
  /// In zh, this message translates to:
  /// **'{n} 处潜在问题'**
  String lpIssues(int n);

  /// No description provided for @lpIssueAt.
  ///
  /// In zh, this message translates to:
  /// **'第 {line} 行：{msg}'**
  String lpIssueAt(int line, String msg);

  /// No description provided for @lpShowAll.
  ///
  /// In zh, this message translates to:
  /// **'全部 8 槽'**
  String get lpShowAll;

  /// No description provided for @lpAdaptive.
  ///
  /// In zh, this message translates to:
  /// **'自适应 ({n})'**
  String lpAdaptive(int n);

  /// No description provided for @lpNoSliders.
  ///
  /// In zh, this message translates to:
  /// **'当前代码未声明或引用 slider1..8 参数（纯算法处理）'**
  String get lpNoSliders;

  /// No description provided for @lpExpandSliders.
  ///
  /// In zh, this message translates to:
  /// **'展开全部 8 槽滑块'**
  String get lpExpandSliders;

  /// No description provided for @lpAddDir.
  ///
  /// In zh, this message translates to:
  /// **'添加外部目录'**
  String get lpAddDir;

  /// No description provided for @lpSlidersHint.
  ///
  /// In zh, this message translates to:
  /// **'滑块条已自适应当前脚本声明与引用的 slider 参数；支持点击右上角切换模式。'**
  String get lpSlidersHint;

  /// No description provided for @lpLibraryHint.
  ///
  /// In zh, this message translates to:
  /// **'支持本地 %APPDATA% 库与外部多预设文件夹自动索引。'**
  String get lpLibraryHint;

  /// No description provided for @convIrTitle.
  ///
  /// In zh, this message translates to:
  /// **'脉冲响应 (IR)'**
  String get convIrTitle;

  /// No description provided for @convFramesLine.
  ///
  /// In zh, this message translates to:
  /// **'{frames} 帧 · {dur} · {ch}ch · 峰值 {peak} dBFS · 源 {rate}Hz'**
  String convFramesLine(int frames, String dur, int ch, String peak, int rate);

  /// No description provided for @ddcFilterTitle.
  ///
  /// In zh, this message translates to:
  /// **'VDC 滤波器'**
  String get ddcFilterTitle;

  /// No description provided for @stereoBandActive.
  ///
  /// In zh, this message translates to:
  /// **'分带生效中'**
  String get stereoBandActive;

  /// No description provided for @stBand0.
  ///
  /// In zh, this message translates to:
  /// **'低频段'**
  String get stBand0;

  /// No description provided for @stBand1.
  ///
  /// In zh, this message translates to:
  /// **'中低频'**
  String get stBand1;

  /// No description provided for @stBand2.
  ///
  /// In zh, this message translates to:
  /// **'中频'**
  String get stBand2;

  /// No description provided for @stBand3.
  ///
  /// In zh, this message translates to:
  /// **'中高频'**
  String get stBand3;

  /// No description provided for @stBand4.
  ///
  /// In zh, this message translates to:
  /// **'高频'**
  String get stBand4;

  /// No description provided for @stBandHint.
  ///
  /// In zh, this message translates to:
  /// **'分带微调：各频带基础扩展量将与上方总主控滑块进行动态乘数联动'**
  String get stBandHint;

  /// No description provided for @presetFactoryTitle.
  ///
  /// In zh, this message translates to:
  /// **'出厂经典调音预设'**
  String get presetFactoryTitle;

  /// No description provided for @presetUserTitle.
  ///
  /// In zh, this message translates to:
  /// **'我的自定义预设'**
  String get presetUserTitle;

  /// No description provided for @presetUserEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无用户自定义预设 — 调好参数后在下方保存'**
  String get presetUserEmpty;

  /// No description provided for @presetLoadedFactory.
  ///
  /// In zh, this message translates to:
  /// **'已载入出厂预设: {name}'**
  String presetLoadedFactory(String name);

  /// No description provided for @presetLoadedUser.
  ///
  /// In zh, this message translates to:
  /// **'已载入自定义预设: {name}'**
  String presetLoadedUser(String name);

  /// No description provided for @presetSaveHint.
  ///
  /// In zh, this message translates to:
  /// **'输入预设名称保存当前状态为用户预设'**
  String get presetSaveHint;

  /// No description provided for @convSpectrumCaption.
  ///
  /// In zh, this message translates to:
  /// **'32 频带 · 0..1 归一化能量'**
  String get convSpectrumCaption;

  /// No description provided for @sliderResetTip.
  ///
  /// In zh, this message translates to:
  /// **'点击重置默认值'**
  String get sliderResetTip;

  /// No description provided for @plugAddDirTitle.
  ///
  /// In zh, this message translates to:
  /// **'添加插件检索目录'**
  String get plugAddDirTitle;

  /// No description provided for @plugAddDirPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入或粘贴包含 64 位 VST3 / CLAP 效果器的完整文件夹路径：'**
  String get plugAddDirPrompt;

  /// No description provided for @plugAddDirExample.
  ///
  /// In zh, this message translates to:
  /// **'例：D:\\AudioPlugins\\VST3'**
  String get plugAddDirExample;

  /// No description provided for @plugAddScan.
  ///
  /// In zh, this message translates to:
  /// **'添加并扫描'**
  String get plugAddScan;

  /// No description provided for @plugPresetTitle.
  ///
  /// In zh, this message translates to:
  /// **'插件预设管理 — {name}'**
  String plugPresetTitle(String name);

  /// No description provided for @plugPresetSaveLabel.
  ///
  /// In zh, this message translates to:
  /// **'保存当前参数状态'**
  String get plugPresetSaveLabel;

  /// No description provided for @plugPresetNameHint.
  ///
  /// In zh, this message translates to:
  /// **'输入新预设名称...'**
  String get plugPresetNameHint;

  /// No description provided for @plugPresetList.
  ///
  /// In zh, this message translates to:
  /// **'已有预设列表 ({n})'**
  String plugPresetList(int n);

  /// No description provided for @plugPresetEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂无已保存预设，可通过上方输入框保存。'**
  String get plugPresetEmpty;

  /// No description provided for @plugTitle.
  ///
  /// In zh, this message translates to:
  /// **'插件中心'**
  String get plugTitle;

  /// No description provided for @plugLibTitle.
  ///
  /// In zh, this message translates to:
  /// **'第三方效果器库'**
  String get plugLibTitle;

  /// No description provided for @plugLibHint.
  ///
  /// In zh, this message translates to:
  /// **'系统标准 VST3 / CLAP 64 位插件目录与自定义目录扫描与管理。支持零延迟与前瞻延迟补偿，双声道平面 RT-Safe 运行。'**
  String get plugLibHint;

  /// 深扫勾选：会加载每个插件 DLL 以读取精确元数据，明显更慢
  ///
  /// In zh, this message translates to:
  /// **'深度遍历'**
  String get plugDeepScan;

  /// No description provided for @plugScan.
  ///
  /// In zh, this message translates to:
  /// **'扫描'**
  String get plugScan;

  /// No description provided for @plugScanning.
  ///
  /// In zh, this message translates to:
  /// **'正在扫描...'**
  String get plugScanning;

  /// No description provided for @plugScanPreparing.
  ///
  /// In zh, this message translates to:
  /// **'正在枚举插件目录…'**
  String get plugScanPreparing;

  /// No description provided for @plugScanProgressCount.
  ///
  /// In zh, this message translates to:
  /// **'已扫描 {done}/{total} · 发现 {found} 个插件'**
  String plugScanProgressCount(int done, int total, int found);

  /// No description provided for @plugScanNoVerify.
  ///
  /// In zh, this message translates to:
  /// **'快扫不加载插件：仅读取文件元数据，插件在挂载时才验证'**
  String get plugScanNoVerify;

  /// No description provided for @plugOpenFolder.
  ///
  /// In zh, this message translates to:
  /// **'打开 VST3 标准目录'**
  String get plugOpenFolder;

  /// No description provided for @plugSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索插件名称、厂商或路径...'**
  String get plugSearchHint;

  /// No description provided for @plugM1Title.
  ///
  /// In zh, this message translates to:
  /// **'M1 插件宿主引擎规范'**
  String get plugM1Title;

  /// No description provided for @plugM1Hint.
  ///
  /// In zh, this message translates to:
  /// **'多格式进程内宿主已支持 64 位 VST3 与 CLAP 架构。'**
  String get plugM1Hint;

  /// No description provided for @plugFeatSlots.
  ///
  /// In zh, this message translates to:
  /// **'四槽位对称机架 (Slot 1 ~ Slot 4) 独立管理与并发'**
  String get plugFeatSlots;

  /// No description provided for @plugFeatStages.
  ///
  /// In zh, this message translates to:
  /// **'全音效链阶段插入 (Pre-DSP ~ Post-Limiter)'**
  String get plugFeatStages;

  /// No description provided for @plugFeatGui.
  ///
  /// In zh, this message translates to:
  /// **'原生 Win32 GUI 弹窗独立消息循环'**
  String get plugFeatGui;

  /// No description provided for @plugFeatPreset.
  ///
  /// In zh, this message translates to:
  /// **'二进制流预设保存与即时载入恢复'**
  String get plugFeatPreset;

  /// No description provided for @plugFeatDirs.
  ///
  /// In zh, this message translates to:
  /// **'可自定义插件目录检索与本地状态快照'**
  String get plugFeatDirs;

  /// No description provided for @plugFeatRt.
  ///
  /// In zh, this message translates to:
  /// **'平面双声道 RT-Safe 预分配零锁保障'**
  String get plugFeatRt;

  /// No description provided for @plugSlot.
  ///
  /// In zh, this message translates to:
  /// **'插槽 {n} (Slot {n})'**
  String plugSlot(int n);

  /// No description provided for @plugBypassed.
  ///
  /// In zh, this message translates to:
  /// **'旁路'**
  String get plugBypassed;

  /// No description provided for @plugCustomTitle.
  ///
  /// In zh, this message translates to:
  /// **'自定义插件检索目录'**
  String get plugCustomTitle;

  /// No description provided for @plugCustomHint.
  ///
  /// In zh, this message translates to:
  /// **'添加其他硬盘分区或 DAW 的 VST3/CLAP 路径，扫描时将自动合并遍历。'**
  String get plugCustomHint;

  /// No description provided for @plugCustomAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加目录'**
  String get plugCustomAdd;

  /// No description provided for @plugCustomEmpty.
  ///
  /// In zh, this message translates to:
  /// **'暂未添加自定义目录。除系统默认路径（C:\\Program Files\\Common Files\\VST3 等）外，可点击右上角添加。'**
  String get plugCustomEmpty;

  /// No description provided for @plugMountTitle.
  ///
  /// In zh, this message translates to:
  /// **'挂载状态 (插槽 {n})'**
  String plugMountTitle(int n);

  /// No description provided for @plugMountEmpty.
  ///
  /// In zh, this message translates to:
  /// **'插槽 {n} 暂未挂载第三方插件'**
  String plugMountEmpty(int n);

  /// No description provided for @plugMountEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'请在下方效果器库列表中选择已安装的 VST3 / CLAP 插件进行加载'**
  String get plugMountEmptyHint;

  /// No description provided for @plugScanNow.
  ///
  /// In zh, this message translates to:
  /// **'立即扫描本机已安装插件'**
  String get plugScanNow;

  /// No description provided for @plugMountedTitle.
  ///
  /// In zh, this message translates to:
  /// **'当前挂载插件 (插槽 {n})'**
  String plugMountedTitle(int n);

  /// No description provided for @plugMountedTitleNamed.
  ///
  /// In zh, this message translates to:
  /// **'当前挂载插件 (插槽 {n})：{name}'**
  String plugMountedTitleNamed(int n, String name);

  /// No description provided for @plugEditorTitleNamed.
  ///
  /// In zh, this message translates to:
  /// **'{name}（插槽 {n}）'**
  String plugEditorTitleNamed(int n, String name);

  /// No description provided for @plugOpenGuiBtn.
  ///
  /// In zh, this message translates to:
  /// **'打开界面 (GUI)'**
  String get plugOpenGuiBtn;

  /// No description provided for @plugUnloadFromSlot.
  ///
  /// In zh, this message translates to:
  /// **'从当前槽卸载'**
  String get plugUnloadFromSlot;

  /// No description provided for @plugLoadToSlot.
  ///
  /// In zh, this message translates to:
  /// **'载入至插槽 {n}'**
  String plugLoadToSlot(int n);

  /// No description provided for @plugLatencyLabel.
  ///
  /// In zh, this message translates to:
  /// **'实测音频延迟'**
  String get plugLatencyLabel;

  /// No description provided for @plugStageLabel.
  ///
  /// In zh, this message translates to:
  /// **'信号处理链插入阶段：'**
  String get plugStageLabel;

  /// No description provided for @plugRtNote.
  ///
  /// In zh, this message translates to:
  /// **'实时动态串联 • 保持 RT-Safe 契约'**
  String get plugRtNote;

  /// No description provided for @plugFilterAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get plugFilterAll;

  /// No description provided for @plugNoPlugins.
  ///
  /// In zh, this message translates to:
  /// **'未检测到已安装的第三方插件'**
  String get plugNoPlugins;

  /// No description provided for @plugNoPluginsHint.
  ///
  /// In zh, this message translates to:
  /// **'请确认插件已放置在系统 VST3 / CLAP 路径，或在上方添加自定义插件目录后重新扫描'**
  String get plugNoPluginsHint;

  /// No description provided for @plugNoMatch.
  ///
  /// In zh, this message translates to:
  /// **'未找到符合当前搜索和过滤条件的插件'**
  String get plugNoMatch;

  /// No description provided for @plugIncompatibleBadge.
  ///
  /// In zh, this message translates to:
  /// **'32 位不兼容'**
  String get plugIncompatibleBadge;

  /// No description provided for @plugIncompatibleHint.
  ///
  /// In zh, this message translates to:
  /// **'该插件为 32 位版本，AuraDSP 是 64 位宿主，无法加载；请安装对应的 64 位版本。'**
  String get plugIncompatibleHint;

  /// No description provided for @plugSlotActive.
  ///
  /// In zh, this message translates to:
  /// **'插槽 {n} 活跃中'**
  String plugSlotActive(int n);

  /// No description provided for @plugSlotLoaded.
  ///
  /// In zh, this message translates to:
  /// **'插槽 {n} 已载入'**
  String plugSlotLoaded(int n);

  /// No description provided for @plugUnknownVendor.
  ///
  /// In zh, this message translates to:
  /// **'未知厂商'**
  String get plugUnknownVendor;

  /// No description provided for @plugThirdParty.
  ///
  /// In zh, this message translates to:
  /// **'第三方插件'**
  String get plugThirdParty;

  /// No description provided for @plugSlotPluginLine.
  ///
  /// In zh, this message translates to:
  /// **'{name} • [{stage}]'**
  String plugSlotPluginLine(String name, String stage);

  /// No description provided for @plugSlotNoFx.
  ///
  /// In zh, this message translates to:
  /// **'未挂载效果器'**
  String get plugSlotNoFx;

  /// No description provided for @chainActive.
  ///
  /// In zh, this message translates to:
  /// **'生效中'**
  String get chainActive;

  /// No description provided for @chainBypass.
  ///
  /// In zh, this message translates to:
  /// **'旁路'**
  String get chainBypass;

  /// No description provided for @plugActive.
  ///
  /// In zh, this message translates to:
  /// **'生效'**
  String get plugActive;

  /// No description provided for @lpSaveFailed.
  ///
  /// In zh, this message translates to:
  /// **'保存失败（名称非法或磁盘不可写）'**
  String get lpSaveFailed;

  /// No description provided for @chainVstTitle.
  ///
  /// In zh, this message translates to:
  /// **'第三方 VST / CLAP 插件挂载槽与阶段处理顺序'**
  String get chainVstTitle;

  /// No description provided for @chainVstHint.
  ///
  /// In zh, this message translates to:
  /// **'支持多插槽并行挂载；可在下方为每个插件单独设定在全局音频链上的插入阶段与处理先后。'**
  String get chainVstHint;

  /// No description provided for @compTitle.
  ///
  /// In zh, this message translates to:
  /// **'动态压限器'**
  String get compTitle;

  /// No description provided for @compTimeconstant.
  ///
  /// In zh, this message translates to:
  /// **'响应时常数'**
  String get compTimeconstant;

  /// No description provided for @compGranularity.
  ///
  /// In zh, this message translates to:
  /// **'分析颗粒度'**
  String get compGranularity;

  /// No description provided for @compGranularityCoarse.
  ///
  /// In zh, this message translates to:
  /// **'粗略 (低负荷)'**
  String get compGranularityCoarse;

  /// No description provided for @compGranularityNormal.
  ///
  /// In zh, this message translates to:
  /// **'标准 (平衡)'**
  String get compGranularityNormal;

  /// No description provided for @compGranularityFine.
  ///
  /// In zh, this message translates to:
  /// **'精细 (多频带)'**
  String get compGranularityFine;

  /// No description provided for @compTfresolution.
  ///
  /// In zh, this message translates to:
  /// **'时频分辨率'**
  String get compTfresolution;

  /// No description provided for @compTfresTransient.
  ///
  /// In zh, this message translates to:
  /// **'瞬态响应'**
  String get compTfresTransient;

  /// No description provided for @compTfresBalanced.
  ///
  /// In zh, this message translates to:
  /// **'平衡'**
  String get compTfresBalanced;

  /// No description provided for @compTfresFine.
  ///
  /// In zh, this message translates to:
  /// **'高频解析'**
  String get compTfresFine;

  /// No description provided for @autoGainCompensation.
  ///
  /// In zh, this message translates to:
  /// **'自动增益补偿'**
  String get autoGainCompensation;

  /// No description provided for @autoGainCompensationTooltip.
  ///
  /// In zh, this message translates to:
  /// **'随音效提升动态平抑输出电平，防止多级叠加导致削波失真'**
  String get autoGainCompensationTooltip;

  /// No description provided for @outputGainGate.
  ///
  /// In zh, this message translates to:
  /// **'输出增益门'**
  String get outputGainGate;

  /// No description provided for @outputGainGateTooltip.
  ///
  /// In zh, this message translates to:
  /// **'微调该效果器出口电平 (-12.0 ~ +6.0 dB)'**
  String get outputGainGateTooltip;

  /// No description provided for @arbmagSubtitle.
  ///
  /// In zh, this message translates to:
  /// **'8192点因果最小相位 FIR 卷积 · 自由频响与 AutoEq 曲线'**
  String get arbmagSubtitle;

  /// No description provided for @arbmagPresetFlat.
  ///
  /// In zh, this message translates to:
  /// **'平直 (Flat)'**
  String get arbmagPresetFlat;

  /// No description provided for @arbmagPresetHarman.
  ///
  /// In zh, this message translates to:
  /// **'Harman 目标曲线'**
  String get arbmagPresetHarman;

  /// No description provided for @arbmagPresetDiffuse.
  ///
  /// In zh, this message translates to:
  /// **'扩散场 (Diffuse-Field)'**
  String get arbmagPresetDiffuse;

  /// No description provided for @arbmagImport.
  ///
  /// In zh, this message translates to:
  /// **'导入文件'**
  String get arbmagImport;

  /// No description provided for @arbmagPaste.
  ///
  /// In zh, this message translates to:
  /// **'剪贴板粘贴'**
  String get arbmagPaste;

  /// No description provided for @arbmagClear.
  ///
  /// In zh, this message translates to:
  /// **'清空曲线'**
  String get arbmagClear;

  /// No description provided for @arbmagEmptyHint.
  ///
  /// In zh, this message translates to:
  /// **'尚未加载曲线。可点击上方预设、导入 AutoEq GraphicEQ 文件或粘贴代码。'**
  String get arbmagEmptyHint;

  /// No description provided for @arbmagEditor.
  ///
  /// In zh, this message translates to:
  /// **'GraphicEQ 代码编辑器'**
  String get arbmagEditor;

  /// No description provided for @arbmagNodes.
  ///
  /// In zh, this message translates to:
  /// **'已载入 {count} 个频点'**
  String arbmagNodes(int count);

  /// No description provided for @arbmagApply.
  ///
  /// In zh, this message translates to:
  /// **'应用代码'**
  String get arbmagApply;

  /// No description provided for @arbmagInvalidFormat.
  ///
  /// In zh, this message translates to:
  /// **'GraphicEQ 格式错误或未包含有效节点'**
  String get arbmagInvalidFormat;

  /// No description provided for @crossfeedTitle.
  ///
  /// In zh, this message translates to:
  /// **'串扰消除'**
  String get crossfeedTitle;

  /// No description provided for @crossfeedMode.
  ///
  /// In zh, this message translates to:
  /// **'模式'**
  String get crossfeedMode;

  /// No description provided for @crossfeedDesc.
  ///
  /// In zh, this message translates to:
  /// **'专为耳机设计，通过低通互馈消除头中效应与听觉疲劳'**
  String get crossfeedDesc;

  /// No description provided for @crossfeedModeDefault.
  ///
  /// In zh, this message translates to:
  /// **'默认标准'**
  String get crossfeedModeDefault;

  /// No description provided for @crossfeedModeChuMoy.
  ///
  /// In zh, this message translates to:
  /// **'经典耳放 (Chu Moy)'**
  String get crossfeedModeChuMoy;

  /// No description provided for @crossfeedModeJanMeier.
  ///
  /// In zh, this message translates to:
  /// **'增强互馈 (Jan Meier)'**
  String get crossfeedModeJanMeier;

  /// No description provided for @crossfeedModeCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get crossfeedModeCustom;

  /// No description provided for @crossfeedCutoff.
  ///
  /// In zh, this message translates to:
  /// **'截止频率'**
  String get crossfeedCutoff;

  /// No description provided for @crossfeedFeed.
  ///
  /// In zh, this message translates to:
  /// **'互馈电平'**
  String get crossfeedFeed;

  /// No description provided for @crossfeedActiveDesc.
  ///
  /// In zh, this message translates to:
  /// **'当前生效：{mode} ({fcut} Hz, {feed} dB)'**
  String crossfeedActiveDesc(String mode, String fcut, String feed);
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
