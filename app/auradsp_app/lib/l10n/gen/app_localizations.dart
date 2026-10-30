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

  /// No description provided for @routingChFl.
  ///
  /// In zh, this message translates to:
  /// **'左前'**
  String get routingChFl;

  /// No description provided for @routingChFr.
  ///
  /// In zh, this message translates to:
  /// **'右前'**
  String get routingChFr;

  /// No description provided for @routingChC.
  ///
  /// In zh, this message translates to:
  /// **'中置'**
  String get routingChC;

  /// No description provided for @routingChLfe.
  ///
  /// In zh, this message translates to:
  /// **'超低'**
  String get routingChLfe;

  /// No description provided for @routingChSl.
  ///
  /// In zh, this message translates to:
  /// **'左环'**
  String get routingChSl;

  /// No description provided for @routingChSr.
  ///
  /// In zh, this message translates to:
  /// **'右环'**
  String get routingChSr;

  /// No description provided for @routingChBl.
  ///
  /// In zh, this message translates to:
  /// **'左后'**
  String get routingChBl;

  /// No description provided for @routingChBr.
  ///
  /// In zh, this message translates to:
  /// **'右后'**
  String get routingChBr;

  /// No description provided for @routingAllChannels.
  ///
  /// In zh, this message translates to:
  /// **'全声道 (8/8)'**
  String get routingAllChannels;

  /// No description provided for @routingStereo.
  ///
  /// In zh, this message translates to:
  /// **'立体声 (FL/FR)'**
  String get routingStereo;

  /// No description provided for @routingNoSub.
  ///
  /// In zh, this message translates to:
  /// **'无超低 (7/8)'**
  String get routingNoSub;

  /// No description provided for @routingAllBypassed.
  ///
  /// In zh, this message translates to:
  /// **'全旁路 (0/8)'**
  String get routingAllBypassed;

  /// No description provided for @routingSurroundOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅环绕 (4/8)'**
  String get routingSurroundOnly;

  /// No description provided for @routingPairHint.
  ///
  /// In zh, this message translates to:
  /// **'按立体声对生效：FL/FR、C/LFE、SL/SR、BL/BR 成对勾选，单选无效'**
  String get routingPairHint;

  /// No description provided for @routingSelectedCount.
  ///
  /// In zh, this message translates to:
  /// **'{count}/{total} 声道已选'**
  String routingSelectedCount(int count, int total);

  /// No description provided for @routingStereoPathSummary.
  ///
  /// In zh, this message translates to:
  /// **'直通 (立体声/矩阵路径)'**
  String get routingStereoPathSummary;

  /// No description provided for @routingStereoPathHint.
  ///
  /// In zh, this message translates to:
  /// **'当前处于立体声或矩阵下混路径，所有声道统一处理，独立声道掩码不生效。'**
  String get routingStereoPathHint;

  /// No description provided for @flfrOnlyHint.
  ///
  /// In zh, this message translates to:
  /// **'仅作用于前置 FL/FR 对（多声道离散时环绕与 LFE 直通）'**
  String get flfrOnlyHint;

  /// No description provided for @channelRouting.
  ///
  /// In zh, this message translates to:
  /// **'高级声道路由'**
  String get channelRouting;

  /// No description provided for @routingPresets.
  ///
  /// In zh, this message translates to:
  /// **'快速选择:'**
  String get routingPresets;

  /// No description provided for @routingPresetAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get routingPresetAll;

  /// No description provided for @routingPresetFront.
  ///
  /// In zh, this message translates to:
  /// **'仅前置'**
  String get routingPresetFront;

  /// No description provided for @routingPresetBack.
  ///
  /// In zh, this message translates to:
  /// **'仅后置'**
  String get routingPresetBack;

  /// No description provided for @routingPresetStereo.
  ///
  /// In zh, this message translates to:
  /// **'立体声'**
  String get routingPresetStereo;

  /// No description provided for @routingPresetNoLfe.
  ///
  /// In zh, this message translates to:
  /// **'无超低'**
  String get routingPresetNoLfe;

  /// No description provided for @routingPresetSurround.
  ///
  /// In zh, this message translates to:
  /// **'仅环绕'**
  String get routingPresetSurround;

  /// No description provided for @channelCount.
  ///
  /// In zh, this message translates to:
  /// **'声道数量'**
  String get channelCount;

  /// No description provided for @channelCountHint.
  ///
  /// In zh, this message translates to:
  /// **'工作声道拓扑。自动模式跟随输入源与输出端点协商；亦可手动锁定 2.0 / 4.0 / 5.1 / 7.1。'**
  String get channelCountHint;

  /// No description provided for @channelCountAuto.
  ///
  /// In zh, this message translates to:
  /// **'自动'**
  String get channelCountAuto;

  /// No description provided for @channelCountAutoDesc.
  ///
  /// In zh, this message translates to:
  /// **'自动协商生效中 · 当前工作拓扑：{count} 声道'**
  String channelCountAutoDesc(int count);

  /// No description provided for @setConnStatus.
  ///
  /// In zh, this message translates to:
  /// **'连接状态'**
  String get setConnStatus;

  /// No description provided for @setConnActive.
  ///
  /// In zh, this message translates to:
  /// **'已连接 (活跃回调)'**
  String get setConnActive;

  /// No description provided for @setConnIdle.
  ///
  /// In zh, this message translates to:
  /// **'未连接 (等待 Voicemeeter 启动)'**
  String get setConnIdle;

  /// No description provided for @setDeviceDisconnected.
  ///
  /// In zh, this message translates to:
  /// **'未连接设备'**
  String get setDeviceDisconnected;

  /// No description provided for @setEndpointShort.
  ///
  /// In zh, this message translates to:
  /// **'端点'**
  String get setEndpointShort;

  /// No description provided for @setEndpointWithId.
  ///
  /// In zh, this message translates to:
  /// **'音频端点 ({shortId})'**
  String setEndpointWithId(String shortId);

  /// No description provided for @setOfflineSuffix.
  ///
  /// In zh, this message translates to:
  /// **'{name} [离线/未连接]'**
  String setOfflineSuffix(String name);

  /// No description provided for @setDefaultEndpoint.
  ///
  /// In zh, this message translates to:
  /// **'默认音频端点 (Default Render)'**
  String get setDefaultEndpoint;

  /// No description provided for @setNoEndpoint.
  ///
  /// In zh, this message translates to:
  /// **'无可用音频端点'**
  String get setNoEndpoint;

  /// No description provided for @setApoActive.
  ///
  /// In zh, this message translates to:
  /// **'活跃处理中 ({sr}Hz · {frames} 帧)'**
  String setApoActive(int sr, int frames);

  /// No description provided for @setApoAttached.
  ///
  /// In zh, this message translates to:
  /// **'已挂接 (等待播放流触发)'**
  String get setApoAttached;

  /// No description provided for @setProcessing.
  ///
  /// In zh, this message translates to:
  /// **'处理中...'**
  String get setProcessing;

  /// No description provided for @setApoRegistered.
  ///
  /// In zh, this message translates to:
  /// **'已向目标设备注册 System APO 钩子并完成服务同步'**
  String get setApoRegistered;

  /// No description provided for @setApoAttachFailed.
  ///
  /// In zh, this message translates to:
  /// **'APO 附加未完成'**
  String get setApoAttachFailed;

  /// No description provided for @setApoUnregistered.
  ///
  /// In zh, this message translates to:
  /// **'已安全卸载 APO 钩子并精确还原原始系统/厂商驱动'**
  String get setApoUnregistered;

  /// No description provided for @setApoUnregisterFailed.
  ///
  /// In zh, this message translates to:
  /// **'APO 卸载未完成'**
  String get setApoUnregisterFailed;

  /// No description provided for @setCompositeSlot.
  ///
  /// In zh, this message translates to:
  /// **'复合插槽'**
  String get setCompositeSlot;

  /// No description provided for @setRefreshStatus.
  ///
  /// In zh, this message translates to:
  /// **'刷新状态'**
  String get setRefreshStatus;

  /// No description provided for @setApoSafetyNote.
  ///
  /// In zh, this message translates to:
  /// **'注册表安全保护：所有变更均经 HKLM\\SOFTWARE\\AuraDSP\\Child APOs 及磁盘双层快照原子保护，卸载时 100% 还原原始驱动配置。'**
  String get setApoSafetyNote;

  /// No description provided for @setDriverOffline.
  ///
  /// In zh, this message translates to:
  /// **'{name} [未检测到/离线]'**
  String setDriverOffline(String name);

  /// No description provided for @setVaioReady.
  ///
  /// In zh, this message translates to:
  /// **'AuraVAIO KMDF 驱动已就绪 (Sysvad 虚拟声卡)'**
  String get setVaioReady;

  /// No description provided for @setVaioMissing.
  ///
  /// In zh, this message translates to:
  /// **'未检测到 AuraVAIO 虚拟声卡驱动'**
  String get setVaioMissing;

  /// No description provided for @setVaioDesc.
  ///
  /// In zh, this message translates to:
  /// **'KMDF 内核模式虚拟音频驱动，提供全双工虚拟音频线缆通道'**
  String get setVaioDesc;

  /// No description provided for @setInstallDriverUac.
  ///
  /// In zh, this message translates to:
  /// **'UAC提权安装驱动'**
  String get setInstallDriverUac;

  /// No description provided for @setInstallDriverUacPrompt.
  ///
  /// In zh, this message translates to:
  /// **'正在唤起系统管理员授权，请在系统提示中点击允许安装驱动组件...'**
  String get setInstallDriverUacPrompt;

  /// No description provided for @setVaioInstallOk.
  ///
  /// In zh, this message translates to:
  /// **'AuraVAIO 驱动已成功安装并通过系统验收！'**
  String get setVaioInstallOk;

  /// No description provided for @setDriverInstallFailed.
  ///
  /// In zh, this message translates to:
  /// **'驱动安装未完成'**
  String get setDriverInstallFailed;

  /// No description provided for @setUninstallDriver.
  ///
  /// In zh, this message translates to:
  /// **'卸载驱动'**
  String get setUninstallDriver;

  /// No description provided for @setVaioUninstallOk.
  ///
  /// In zh, this message translates to:
  /// **'AuraVAIO 驱动已成功卸载'**
  String get setVaioUninstallOk;

  /// No description provided for @setDriverUninstallFailed.
  ///
  /// In zh, this message translates to:
  /// **'卸载未完成'**
  String get setDriverUninstallFailed;

  /// No description provided for @setRedetect.
  ///
  /// In zh, this message translates to:
  /// **'重新检测'**
  String get setRedetect;

  /// No description provided for @setWasapiDesc.
  ///
  /// In zh, this message translates to:
  /// **'系统底层 WASAPI 共享/独占音频引擎，无额外驱动依赖'**
  String get setWasapiDesc;

  /// No description provided for @setRefreshDevice.
  ///
  /// In zh, this message translates to:
  /// **'刷新设备'**
  String get setRefreshDevice;

  /// No description provided for @setAsioRegisterUac.
  ///
  /// In zh, this message translates to:
  /// **'UAC提权注册驱动'**
  String get setAsioRegisterUac;

  /// No description provided for @setAsioRegisterPrompt.
  ///
  /// In zh, this message translates to:
  /// **'正在唤起系统管理员授权以注册虚拟音频驱动组件...'**
  String get setAsioRegisterPrompt;

  /// No description provided for @setAsioRegisterOk.
  ///
  /// In zh, this message translates to:
  /// **'虚拟 ASIO 驱动注册成功！DAW 中现已可选'**
  String get setAsioRegisterOk;

  /// No description provided for @setAsioRegisterFailed.
  ///
  /// In zh, this message translates to:
  /// **'注册失败，请使用管理员权限重试'**
  String get setAsioRegisterFailed;

  /// No description provided for @setAsioUnregisterOk.
  ///
  /// In zh, this message translates to:
  /// **'虚拟 ASIO 驱动已从系统注销'**
  String get setAsioUnregisterOk;

  /// No description provided for @setAsioUnregisterFailed.
  ///
  /// In zh, this message translates to:
  /// **'注销失败，请使用管理员权限重试'**
  String get setAsioUnregisterFailed;

  /// No description provided for @gateHintThreshold.
  ///
  /// In zh, this message translates to:
  /// **'低于该电平的背景底噪将被衰减。太高会吃掉弱音尾音，太低门几乎不动作。'**
  String get gateHintThreshold;

  /// No description provided for @gateHysteresis.
  ///
  /// In zh, this message translates to:
  /// **'迟滞防抖 (Hysteresis)'**
  String get gateHysteresis;

  /// No description provided for @gateHintHysteresis.
  ///
  /// In zh, this message translates to:
  /// **'开门与关门之间的电平缓冲差。防止信号在阈值临界点反复振荡抽吸，确保人声起伏时门状态平稳自然。'**
  String get gateHintHysteresis;

  /// No description provided for @gateRange.
  ///
  /// In zh, this message translates to:
  /// **'衰减底线 (Range)'**
  String get gateRange;

  /// No description provided for @gateHintRange.
  ///
  /// In zh, this message translates to:
  /// **'门完全关闭时的最大衰减深度。设为 -60dB 为静音，设为 -12~-24dB 可保留自然背景底噪，避免数码窒息感。'**
  String get gateHintRange;

  /// No description provided for @gateHold.
  ///
  /// In zh, this message translates to:
  /// **'保持时间 (Hold)'**
  String get gateHold;

  /// No description provided for @gateHintHold.
  ///
  /// In zh, this message translates to:
  /// **'信号跌破关门阈值后，保持完全导通的毫秒数。防止语间停顿或鼓点泛音被过早斩断。'**
  String get gateHintHold;

  /// No description provided for @gateHintAttack.
  ///
  /// In zh, this message translates to:
  /// **'信号越过开启阈值后门打开的速度。太慢会吃掉起音，太快可能引入瞬态爆音。'**
  String get gateHintAttack;

  /// No description provided for @gateHintRelease.
  ///
  /// In zh, this message translates to:
  /// **'保持时间结束后门平滑关闭到衰减底线所需时间。较长的时间让淡出更自然。'**
  String get gateHintRelease;

  /// No description provided for @gateHintSidechain.
  ///
  /// In zh, this message translates to:
  /// **'侧链动态去齿音与噪声门输出响度自动补偿。'**
  String get gateHintSidechain;

  /// No description provided for @gateHintDeess.
  ///
  /// In zh, this message translates to:
  /// **'针对高频咝咝声、齿音（s/sh/ch）进行动态衰减，保留低频自然丰满度。'**
  String get gateHintDeess;

  /// No description provided for @gateHintDeessFreq.
  ///
  /// In zh, this message translates to:
  /// **'检测齿音（s/sh 音）的侧链频段。齿音重往低调，太闷往高调。'**
  String get gateHintDeessFreq;

  /// No description provided for @gateHintDeessAmount.
  ///
  /// In zh, this message translates to:
  /// **'齿音压制强度。只衰减高频成分，低频人声不动。'**
  String get gateHintDeessAmount;

  /// No description provided for @gateHintAutoGain.
  ///
  /// In zh, this message translates to:
  /// **'实时补偿噪声门造成的整体电平下降，保持响度不塌。'**
  String get gateHintAutoGain;

  /// No description provided for @compThreshold.
  ///
  /// In zh, this message translates to:
  /// **'压缩阈值'**
  String get compThreshold;

  /// No description provided for @compHintThreshold.
  ///
  /// In zh, this message translates to:
  /// **'信号触发动态压限的音量临界门槛。低于此门槛的声音保持原样，高于此门槛的声音将被按比例压制，从而压制过激瞬态。'**
  String get compHintThreshold;

  /// No description provided for @compRatio.
  ///
  /// In zh, this message translates to:
  /// **'压缩比率'**
  String get compRatio;

  /// No description provided for @compHintRatio.
  ///
  /// In zh, this message translates to:
  /// **'超过阈值部分的衰减陡峭程度。数值越高压制越强（如 10:1 几乎成为限幅），数值越低声音动态越温和通透。'**
  String get compHintRatio;

  /// No description provided for @compHintRelease.
  ///
  /// In zh, this message translates to:
  /// **'控制动态压缩与包络跟踪的释放响应时间。较小时瞬态冲击更明显，较大时动态压缩更平顺通透。'**
  String get compHintRelease;

  /// No description provided for @compHintBandwidth.
  ///
  /// In zh, this message translates to:
  /// **'频域分析带宽精细度。粗糙模式响应极快、适合电子流行；精细模式分频更精准、适合人声器乐。'**
  String get compHintBandwidth;

  /// No description provided for @compHintTiming.
  ///
  /// In zh, this message translates to:
  /// **'算法滤波器时间常数策略。瞬态模式保留微动态；平衡模式通用；零延迟模式无缓冲延迟。'**
  String get compHintTiming;

  /// No description provided for @compBandsTitle.
  ///
  /// In zh, this message translates to:
  /// **'分频段动态压限微调 (7 Bands)'**
  String get compBandsTitle;

  /// No description provided for @compHintBands.
  ///
  /// In zh, this message translates to:
  /// **'可对 7 个频带分别自定义分频中心频率与压限/扩展数值（负值为动态压制，正值为动态扩展）。'**
  String get compHintBands;

  /// No description provided for @bandSub.
  ///
  /// In zh, this message translates to:
  /// **'极低频'**
  String get bandSub;

  /// No description provided for @bandLow.
  ///
  /// In zh, this message translates to:
  /// **'低频'**
  String get bandLow;

  /// No description provided for @bandLowMid.
  ///
  /// In zh, this message translates to:
  /// **'中低频'**
  String get bandLowMid;

  /// No description provided for @bandMid.
  ///
  /// In zh, this message translates to:
  /// **'中频'**
  String get bandMid;

  /// No description provided for @bandHighMid.
  ///
  /// In zh, this message translates to:
  /// **'中高频'**
  String get bandHighMid;

  /// No description provided for @bandHigh.
  ///
  /// In zh, this message translates to:
  /// **'高频'**
  String get bandHigh;

  /// No description provided for @bandUltra.
  ///
  /// In zh, this message translates to:
  /// **'超高频'**
  String get bandUltra;

  /// No description provided for @compBandFreq.
  ///
  /// In zh, this message translates to:
  /// **'分频中心频率'**
  String get compBandFreq;

  /// No description provided for @compBandAmount.
  ///
  /// In zh, this message translates to:
  /// **'压限 / 扩展数值'**
  String get compBandAmount;

  /// No description provided for @compHintBandAmount.
  ///
  /// In zh, this message translates to:
  /// **'负值为动态压缩压制，正值为动态扩展。默认 -0.35。'**
  String get compHintBandAmount;

  /// No description provided for @eelUnclosedString.
  ///
  /// In zh, this message translates to:
  /// **'字符串未闭合（跨行）'**
  String get eelUnclosedString;

  /// No description provided for @eelUnmatchedClose.
  ///
  /// In zh, this message translates to:
  /// **'多余的 \"{ch}\"（无匹配的开括号）'**
  String eelUnmatchedClose(String ch);

  /// No description provided for @eelBlockCommentUnclosed.
  ///
  /// In zh, this message translates to:
  /// **'块注释未闭合（/* 缺少对应的 */）'**
  String get eelBlockCommentUnclosed;

  /// No description provided for @eelUnclosedQuote.
  ///
  /// In zh, this message translates to:
  /// **'\"{ch}\" 未闭合（始于第 {line} 行第 {col} 列）'**
  String eelUnclosedQuote(String ch, int line, int col);

  /// No description provided for @eelMissingInit.
  ///
  /// In zh, this message translates to:
  /// **'缺少 @init 段（引擎会拒绝编译）'**
  String get eelMissingInit;

  /// No description provided for @eelMissingSample.
  ///
  /// In zh, this message translates to:
  /// **'缺少 @sample 段（引擎会拒绝编译）'**
  String get eelMissingSample;

  /// No description provided for @eelEmptyInit.
  ///
  /// In zh, this message translates to:
  /// **'初始化段为空（@init 段要求包含至少一条执行语句或变量初始化）'**
  String get eelEmptyInit;

  /// No description provided for @eelEmptySample.
  ///
  /// In zh, this message translates to:
  /// **'@sample 段为空（将输出静音），确认不是漏写？'**
  String get eelEmptySample;

  /// No description provided for @eelSliderRange.
  ///
  /// In zh, this message translates to:
  /// **'slider{n} 越界（仅 slider1..8 会联动滑块）'**
  String eelSliderRange(int n);

  /// No description provided for @eelReadonlyAssign.
  ///
  /// In zh, this message translates to:
  /// **'{name} 是只读变量，赋值不会生效'**
  String eelReadonlyAssign(String name);

  /// No description provided for @lpDocIntro.
  ///
  /// In zh, this message translates to:
  /// **'EEL2 是针对实时音频处理的高性能表达式语言。在 AuraDSP 中，所有脚本在音频泵线程中即时执行。'**
  String get lpDocIntro;

  /// No description provided for @lpDocSectionsTitle.
  ///
  /// In zh, this message translates to:
  /// **'核心代码段（Sections）'**
  String get lpDocSectionsTitle;

  /// No description provided for @lpDocSampleCode.
  ///
  /// In zh, this message translates to:
  /// **'@init\n// 采样率变化或初次加载时执行，用于初始化变量与系数\n\n@sample\n// 每个采样点执行。输入输出变量为 spl0 (左声道) 和 spl1 (右声道)\nspl0 = spl0 * 0.5;\nspl1 = spl1 * 0.5;'**
  String get lpDocSampleCode;

  /// No description provided for @lpDocSlidersTitle.
  ///
  /// In zh, this message translates to:
  /// **'滑块控制语法（Sliders）'**
  String get lpDocSlidersTitle;

  /// No description provided for @lpDocSampleSlider.
  ///
  /// In zh, this message translates to:
  /// **'slider1: 0< -12, 12, 0.5 > 增益 (dB)\n// sliderN: 初始值< 最小值, 最大值, 步进 > 描述标签\n// 宿主将自动生成对应的实时调节滑块！'**
  String get lpDocSampleSlider;

  /// No description provided for @lpDocBuiltinsTitle.
  ///
  /// In zh, this message translates to:
  /// **'常用内置常量与函数'**
  String get lpDocBuiltinsTitle;

  /// No description provided for @lpDocBuiltinConsts.
  ///
  /// In zh, this message translates to:
  /// **'• 常量：srate (当前采样率), \$pi (圆周率)\n'**
  String get lpDocBuiltinConsts;

  /// No description provided for @lpDocBuiltinFns.
  ///
  /// In zh, this message translates to:
  /// **'• 函数：sin, cos, tan, sqrt, exp, log, abs, min, max, rand, floor, ceil\n'**
  String get lpDocBuiltinFns;

  /// No description provided for @lpDocBuiltinChannels.
  ///
  /// In zh, this message translates to:
  /// **'• 声道：spl0 (左输入/输出), spl1 (右输入/输出)'**
  String get lpDocBuiltinChannels;

  /// No description provided for @ioNoInputDevices.
  ///
  /// In zh, this message translates to:
  /// **'无可用输入设备'**
  String get ioNoInputDevices;

  /// No description provided for @ioRefreshDevice.
  ///
  /// In zh, this message translates to:
  /// **'刷新设备'**
  String get ioRefreshDevice;

  /// No description provided for @ioLoopbackDesc.
  ///
  /// In zh, this message translates to:
  /// **'默认内录/环回模式：实时采集系统主回放端点音频'**
  String get ioLoopbackDesc;

  /// No description provided for @ioExclusiveDesc.
  ///
  /// In zh, this message translates to:
  /// **'针对指定硬件/虚拟端口进行低延迟 WASAPI 独占/共享采集'**
  String get ioExclusiveDesc;

  /// No description provided for @ioInputLabel.
  ///
  /// In zh, this message translates to:
  /// **'输入端点'**
  String get ioInputLabel;

  /// No description provided for @ioVaioEndpointDesc.
  ///
  /// In zh, this message translates to:
  /// **'AuraVAIO 虚拟输入端点 (Stereo / 7.1 ch)'**
  String get ioVaioEndpointDesc;

  /// No description provided for @ioChannelStatus.
  ///
  /// In zh, this message translates to:
  /// **'通道状态'**
  String get ioChannelStatus;

  /// No description provided for @ioVaioActive.
  ///
  /// In zh, this message translates to:
  /// **'活跃传输中 (全双工 DMA 环形缓冲)'**
  String get ioVaioActive;

  /// No description provided for @ioVaioReady.
  ///
  /// In zh, this message translates to:
  /// **'就绪 (等待系统/应用推流)'**
  String get ioVaioReady;

  /// No description provided for @ioVaioGuide.
  ///
  /// In zh, this message translates to:
  /// **'请在系统声音设置或播放器中将默认输出设备选择为 \"AuraVAIO\"，声音将通过此虚拟输入端点送入 AuraDSP 声学处理管线。'**
  String get ioVaioGuide;

  /// No description provided for @ioAsioChannelLabel.
  ///
  /// In zh, this message translates to:
  /// **'输入通道'**
  String get ioAsioChannelLabel;

  /// No description provided for @ioAsioActive.
  ///
  /// In zh, this message translates to:
  /// **'DAW 实时注入 (活跃)'**
  String get ioAsioActive;

  /// No description provided for @ioAsioWait.
  ///
  /// In zh, this message translates to:
  /// **'等待 DAW 连接 (宿主未开启)'**
  String get ioAsioWait;

  /// No description provided for @ioAsioGuide.
  ///
  /// In zh, this message translates to:
  /// **'在 DAW (FL Studio / Cubase / Reaper / Ableton) 的 Audio Device 中选择 \"AuraDSP Virtual ASIO\" 即可将工程音频路由至此。'**
  String get ioAsioGuide;

  /// No description provided for @ioWasapiRenderDesc.
  ///
  /// In zh, this message translates to:
  /// **'WASAPI 物理渲染 (扬声器/耳机)'**
  String get ioWasapiRenderDesc;

  /// No description provided for @ioNoOutputDevices.
  ///
  /// In zh, this message translates to:
  /// **'无可用输出设备'**
  String get ioNoOutputDevices;

  /// No description provided for @ioPhysicalOutput.
  ///
  /// In zh, this message translates to:
  /// **'物理输出'**
  String get ioPhysicalOutput;

  /// No description provided for @ioAutoSelect.
  ///
  /// In zh, this message translates to:
  /// **'自动选择（非VAIO扬声器）'**
  String get ioAutoSelect;

  /// No description provided for @ioNoPhysicalOutputs.
  ///
  /// In zh, this message translates to:
  /// **'无可用物理输出设备'**
  String get ioNoPhysicalOutputs;

  /// No description provided for @ioProcessedFrames.
  ///
  /// In zh, this message translates to:
  /// **'已处理帧'**
  String get ioProcessedFrames;

  /// No description provided for @ioOutputLabel.
  ///
  /// In zh, this message translates to:
  /// **'输出端点'**
  String get ioOutputLabel;

  /// No description provided for @ioAsioHwOutput.
  ///
  /// In zh, this message translates to:
  /// **'AuraDSP ASIO Client 硬件输出'**
  String get ioAsioHwOutput;

  /// No description provided for @ioChannelMap.
  ///
  /// In zh, this message translates to:
  /// **'声道映射'**
  String get ioChannelMap;

  /// No description provided for @ioChannelPair.
  ///
  /// In zh, this message translates to:
  /// **'通道 {p1} / {p2}'**
  String ioChannelPair(int p1, int p2);

  /// No description provided for @ioOutputStatus.
  ///
  /// In zh, this message translates to:
  /// **'输出状态'**
  String get ioOutputStatus;

  /// No description provided for @ioAsioPassthrough.
  ///
  /// In zh, this message translates to:
  /// **'正在直通硬件监听 (超低延迟)'**
  String get ioAsioPassthrough;

  /// No description provided for @ioAsioReadyStatus.
  ///
  /// In zh, this message translates to:
  /// **'就绪 (等待驱动会话)'**
  String get ioAsioReadyStatus;

  /// No description provided for @catInput.
  ///
  /// In zh, this message translates to:
  /// **'输入'**
  String get catInput;

  /// No description provided for @catTone.
  ///
  /// In zh, this message translates to:
  /// **'音色'**
  String get catTone;

  /// No description provided for @catEq.
  ///
  /// In zh, this message translates to:
  /// **'均衡'**
  String get catEq;

  /// No description provided for @catStage.
  ///
  /// In zh, this message translates to:
  /// **'声场'**
  String get catStage;

  /// No description provided for @catSpace.
  ///
  /// In zh, this message translates to:
  /// **'空间效果'**
  String get catSpace;

  /// No description provided for @catStereo.
  ///
  /// In zh, this message translates to:
  /// **'立体声'**
  String get catStereo;

  /// No description provided for @catOutput.
  ///
  /// In zh, this message translates to:
  /// **'输出'**
  String get catOutput;

  /// No description provided for @catEffect.
  ///
  /// In zh, this message translates to:
  /// **'效果'**
  String get catEffect;

  /// No description provided for @arbmagMinPoints.
  ///
  /// In zh, this message translates to:
  /// **'至少需要 2 个有效频点（频率 增益dB; …）'**
  String get arbmagMinPoints;

  /// No description provided for @arbmagGraphicEqInvalid.
  ///
  /// In zh, this message translates to:
  /// **'GraphicEQ 无效：{err}'**
  String arbmagGraphicEqInvalid(String err);

  /// No description provided for @arbmagReadFailed.
  ///
  /// In zh, this message translates to:
  /// **'读取文件失败: {err}'**
  String arbmagReadFailed(String err);

  /// No description provided for @arbmagPoints.
  ///
  /// In zh, this message translates to:
  /// **'{n} 频点'**
  String arbmagPoints(int n);

  /// No description provided for @arbmagNodes.
  ///
  /// In zh, this message translates to:
  /// **'已载入 {count} 个频点'**
  String arbmagNodes(int count);

  /// No description provided for @bassHintIntensity.
  ///
  /// In zh, this message translates to:
  /// **'增强低音量感与冲击力。越高低频下潜越震撼，建议适度提升防轰头。'**
  String get bassHintIntensity;

  /// No description provided for @bassHintFrequency.
  ///
  /// In zh, this message translates to:
  /// **'低音增强作用的最高频率。低于该频率的声音将被加厚，一般建议 60~120Hz。'**
  String get bassHintFrequency;

  /// No description provided for @bassShelfRouting.
  ///
  /// In zh, this message translates to:
  /// **'低频搁架声道路由'**
  String get bassShelfRouting;

  /// No description provided for @irEnvelope.
  ///
  /// In zh, this message translates to:
  /// **'脉冲响应包络'**
  String get irEnvelope;

  /// No description provided for @irMirrorR.
  ///
  /// In zh, this message translates to:
  /// **'R (镜像)'**
  String get irMirrorR;

  /// No description provided for @convHintMix.
  ///
  /// In zh, this message translates to:
  /// **'卷积混响混合比。0% 为原始干声，100% 完全沉浸在采样的空间声学混响中。'**
  String get convHintMix;

  /// No description provided for @xfHintPreset.
  ///
  /// In zh, this message translates to:
  /// **'切换经典硬件耳机串扰模拟算法预设或自定义微调。消除耳机“头中效应”，还原自然音箱声场。'**
  String get xfHintPreset;

  /// No description provided for @xfHintCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义串扰低通截止频率与互馈衰减深度微调。'**
  String get xfHintCustom;

  /// No description provided for @xfHintCutoff.
  ///
  /// In zh, this message translates to:
  /// **'串扰低通滤波器的截止频率 (300 ~ 2000 Hz)。频率越高，被互馈到对侧声道的频带范围越宽。'**
  String get xfHintCutoff;

  /// No description provided for @xfHintFeed.
  ///
  /// In zh, this message translates to:
  /// **'低频串扰互馈衰减量 (1.0 ~ 15.0 dB)。数值越小互馈越多、声场越宽；数值越大串扰越轻微。'**
  String get xfHintFeed;

  /// No description provided for @dqHintAttack.
  ///
  /// In zh, this message translates to:
  /// **'频段能量越过阈值后压下来的速度。太慢吃掉瞬态，太快可能有咔哒感。'**
  String get dqHintAttack;

  /// No description provided for @dqHintRelease.
  ///
  /// In zh, this message translates to:
  /// **'能量跌回阈值以下后松开的速度。太短会有抽吸感，太长压住不放。'**
  String get dqHintRelease;

  /// No description provided for @dqShapeNote.
  ///
  /// In zh, this message translates to:
  /// **'Mid 为钟形带宽；Low/High 为搁架斜率共振。'**
  String get dqShapeNote;

  /// No description provided for @dqHintStaticGain.
  ///
  /// In zh, this message translates to:
  /// **'静态基础增益，常时有效；动态部分只做衰减。'**
  String get dqHintStaticGain;

  /// No description provided for @dqHintRange.
  ///
  /// In zh, this message translates to:
  /// **'频段能量超阈后最大再衰减多少。0 = 纯静态整形。'**
  String get dqHintRange;

  /// No description provided for @dqHintThreshold.
  ///
  /// In zh, this message translates to:
  /// **'该频段包络超过此电平才开始动态衰减。太低误杀，太高不动作。'**
  String get dqHintThreshold;

  /// No description provided for @dqIndepTiming.
  ///
  /// In zh, this message translates to:
  /// **'独立动态响应时常数'**
  String get dqIndepTiming;

  /// No description provided for @dqHintBandAttack.
  ///
  /// In zh, this message translates to:
  /// **'该频段专用的起音时间。'**
  String get dqHintBandAttack;

  /// No description provided for @dqHintBandRelease.
  ///
  /// In zh, this message translates to:
  /// **'该频段专用的释放时间。'**
  String get dqHintBandRelease;

  /// No description provided for @filterHintModes.
  ///
  /// In zh, this message translates to:
  /// **'HP 低于该频率衰减，LP 高于该频率衰减，BP 以该频率为中心通过。'**
  String get filterHintModes;

  /// No description provided for @filterHintResonance.
  ///
  /// In zh, this message translates to:
  /// **'谐振强度。BP 的带宽全靠它；HP/LP 只在转折处有峰。'**
  String get filterHintResonance;

  /// No description provided for @haasHintDelay.
  ///
  /// In zh, this message translates to:
  /// **'延迟侧 0~25ms（Haas 定位差）。12ms 附近声场出头中，太大则成回声。'**
  String get haasHintDelay;

  /// No description provided for @haasHintWet.
  ///
  /// In zh, this message translates to:
  /// **'湿声（延迟差分）比例。拉低保中央人声聚焦，单声道设备自动兼容。'**
  String get haasHintWet;

  /// No description provided for @inputGainTip.
  ///
  /// In zh, this message translates to:
  /// **'{label}: {gain} dB\n上下拖拽微调 · 双击归零'**
  String inputGainTip(String label, String gain);

  /// No description provided for @inputReset100.
  ///
  /// In zh, this message translates to:
  /// **'重置 100%'**
  String get inputReset100;

  /// No description provided for @inputFinal.
  ///
  /// In zh, this message translates to:
  /// **'最终: {desc}'**
  String inputFinal(String desc);

  /// No description provided for @inputResetHint.
  ///
  /// In zh, this message translates to:
  /// **'双击或点击恢复 100%'**
  String get inputResetHint;

  /// No description provided for @loudnessHint.
  ///
  /// In zh, this message translates to:
  /// **'小音量自动补低频和高频，大音量直通'**
  String get loudnessHint;

  /// No description provided for @postHintGain.
  ///
  /// In zh, this message translates to:
  /// **'全局总输出音量补偿。多重 DSP 处理后若音量偏小可适当微调。'**
  String get postHintGain;

  /// No description provided for @postCeiling.
  ///
  /// In zh, this message translates to:
  /// **'限幅阈值'**
  String get postCeiling;

  /// No description provided for @postHintCeiling.
  ///
  /// In zh, this message translates to:
  /// **'母带级前瞻限幅门限。超过此门限的瞬态将被透明压制，彻底防止任何削波失真与真峰值 (ISP) 溢出。'**
  String get postHintCeiling;

  /// No description provided for @postRelease.
  ///
  /// In zh, this message translates to:
  /// **'释放时间'**
  String get postRelease;

  /// No description provided for @postHintRelease.
  ///
  /// In zh, this message translates to:
  /// **'限幅器包络释放衰减时间。时间较短瞬态紧实有力，时间较长音质顺滑无抽吸感。'**
  String get postHintRelease;

  /// No description provided for @postLookahead.
  ///
  /// In zh, this message translates to:
  /// **'1.5ms 前瞻'**
  String get postLookahead;

  /// No description provided for @postHintLookahead.
  ///
  /// In zh, this message translates to:
  /// **'1.5ms 自适应平滑前瞻。开启后提供广播母带级零失真削峰，关闭则进入零延迟电竞/监听模式。'**
  String get postHintLookahead;

  /// No description provided for @postStereoLink.
  ///
  /// In zh, this message translates to:
  /// **'立体声联动'**
  String get postStereoLink;

  /// No description provided for @postHintStereoLink.
  ///
  /// In zh, this message translates to:
  /// **'开启后左右声道按能量最大侧联合限幅，防止大动态瞬态导致声像意外偏移。'**
  String get postHintStereoLink;

  /// No description provided for @reverbHintMix.
  ///
  /// In zh, this message translates to:
  /// **'混响声的音量占比。数值越高，空间空灵回荡感越强，如同置身音乐厅或教堂。'**
  String get reverbHintMix;

  /// No description provided for @reverbHintSize.
  ///
  /// In zh, this message translates to:
  /// **'模拟虚拟房间尺寸。尺寸越大，声场越开阔、反射间隔越长。'**
  String get reverbHintSize;

  /// No description provided for @reverbHintDecay.
  ///
  /// In zh, this message translates to:
  /// **'反射残响消散时间。数值越大，声音余韵回荡持续越久。'**
  String get reverbHintDecay;

  /// No description provided for @reverbHintWidth.
  ///
  /// In zh, this message translates to:
  /// **'混响声的双耳立体声扩展度。让回声包围整个头部。'**
  String get reverbHintWidth;

  /// No description provided for @reverbHintDamp.
  ///
  /// In zh, this message translates to:
  /// **'高频阻尼吸收。越大音色越温暖柔和，越小越明亮通透。'**
  String get reverbHintDamp;

  /// No description provided for @reverbHintDry.
  ///
  /// In zh, this message translates to:
  /// **'原始直达声保留量。确保人声吐字清晰结实。'**
  String get reverbHintDry;

  /// No description provided for @reverbHintWidthMc.
  ///
  /// In zh, this message translates to:
  /// **'多声道 FDN 的宽度：只扩展 FL/FR、SL/SR、BL/BR 三对；中置与 LFE 不参与。'**
  String get reverbHintWidthMc;

  /// No description provided for @reverbEngineLabel.
  ///
  /// In zh, this message translates to:
  /// **'当前引擎'**
  String get reverbEngineLabel;

  /// No description provided for @reverbEngineStereo.
  ///
  /// In zh, this message translates to:
  /// **'立体声'**
  String get reverbEngineStereo;

  /// No description provided for @reverbEngineMc.
  ///
  /// In zh, this message translates to:
  /// **'多声道 FDN'**
  String get reverbEngineMc;

  /// No description provided for @reverbEngineOff.
  ///
  /// In zh, this message translates to:
  /// **'已关闭'**
  String get reverbEngineOff;

  /// No description provided for @reverbEngineInfo.
  ///
  /// In zh, this message translates to:
  /// **'混响根据当前声道拓扑自动选择：双声道立体声/双耳监听采用经典双通道扩散混响；离散多声道环境采用 8 阶反馈延迟网络 (FDN) 空间算法。'**
  String get reverbEngineInfo;

  /// No description provided for @reverbLfe.
  ///
  /// In zh, this message translates to:
  /// **'LFE 入混响'**
  String get reverbLfe;

  /// No description provided for @reverbLfeInfo.
  ///
  /// In zh, this message translates to:
  /// **'开启后 LFE 经 120Hz 低通与 -6dB 送入多声道混响；湿声回加前再经同一低通。立体声路径忽略。'**
  String get reverbLfeInfo;

  /// No description provided for @reverbPredelay.
  ///
  /// In zh, this message translates to:
  /// **'预延迟'**
  String get reverbPredelay;

  /// No description provided for @reverbPredelayInfo.
  ///
  /// In zh, this message translates to:
  /// **'混响前的延迟量（0–100ms）。与预设自带的基础预延迟相加；自定义模式从 0 起算。'**
  String get reverbPredelayInfo;

  /// No description provided for @reverbLegacyPreset.
  ///
  /// In zh, this message translates to:
  /// **'旧版预设 {id}'**
  String reverbLegacyPreset(int id);

  /// No description provided for @spatialHintRoom.
  ///
  /// In zh, this message translates to:
  /// **'模拟虚拟声学室的物理反射体量。数值越大空间感越深邃宏大，反射余韵越丰满。'**
  String get spatialHintRoom;

  /// No description provided for @spatialHintWidth.
  ///
  /// In zh, this message translates to:
  /// **'扩展双耳立体声张角与虚拟环绕音箱间距。拉大可获得脱箱广阔声场，适度调控以保声音饱满。'**
  String get spatialHintWidth;

  /// No description provided for @spatialHintFocus.
  ///
  /// In zh, this message translates to:
  /// **'控制中央人声与对白结像实体聚焦感。适度提升可令人声居中清晰且不被环绕声掩盖。'**
  String get spatialHintFocus;

  /// No description provided for @spatialHintGain.
  ///
  /// In zh, this message translates to:
  /// **'在全自动等能量物理归一化基础上的输出增益微调 (-12 ~ +6 dB)。'**
  String get spatialHintGain;

  /// No description provided for @spatialHintLoudness.
  ///
  /// In zh, this message translates to:
  /// **'全站等响度自动平衡算法。自动平抑多扬声器上混带来的能量增益，彻底杜绝滑块变音量调节器的问题。'**
  String get spatialHintLoudness;

  /// No description provided for @stereoHintWidth.
  ///
  /// In zh, this message translates to:
  /// **'拉伸左右耳声像边界。适度拉伸让耳机如大音箱脱箱，拉太大可能削弱中央人声聚焦。'**
  String get stereoHintWidth;

  /// No description provided for @tubeHintColor.
  ///
  /// In zh, this message translates to:
  /// **'模拟经典电子管偶次谐波失真。带来醇厚耐听的模拟胶片暖色调，消除数码干冷感。'**
  String get tubeHintColor;

  /// No description provided for @tubeHintTrim.
  ///
  /// In zh, this message translates to:
  /// **'电子管染色后的手动电平微调，只作用于湿信号（干声不动）。切换音色风格导致响度变化时用它找平。'**
  String get tubeHintTrim;

  /// No description provided for @tubeTriode.
  ///
  /// In zh, this message translates to:
  /// **'TRIODE (偶次谐波)'**
  String get tubeTriode;

  /// No description provided for @tubePentode.
  ///
  /// In zh, this message translates to:
  /// **'PENTODE (奇次谐波)'**
  String get tubePentode;

  /// No description provided for @tubeTape.
  ///
  /// In zh, this message translates to:
  /// **'TAPE (磁带温润)'**
  String get tubeTape;

  /// No description provided for @noAvailableDevice.
  ///
  /// In zh, this message translates to:
  /// **'无可用设备'**
  String get noAvailableDevice;

  /// No description provided for @vbBuses.
  ///
  /// In zh, this message translates to:
  /// **'VB 总线（关=直通）'**
  String get vbBuses;

  /// No description provided for @vbPluginTooltip.
  ///
  /// In zh, this message translates to:
  /// **'勾选 = 挂载的插件处理该路音频（厂商音效不受影响）'**
  String get vbPluginTooltip;

  /// No description provided for @vbPluginLockedHint.
  ///
  /// In zh, this message translates to:
  /// **'通道处理关闭时插件不运行（状态保留，开启后立即恢复）'**
  String get vbPluginLockedHint;

  /// No description provided for @vbAutoProtect.
  ///
  /// In zh, this message translates to:
  /// **'超预算自动保护'**
  String get vbAutoProtect;

  /// No description provided for @vbProtectHint.
  ///
  /// In zh, this message translates to:
  /// **'音频处理时限由驱动缓冲区决定（如 128 帧 @ 48kHz = 2.7ms 截止预算）。当效果器/插件的处理耗时（EMA）持续超过预算的 85% 时，系统自动将重负载插件收窄至当前监听总线，其余总线直通，以杜绝爆音与掉字卡顿；负载回落安全阈值后将自动恢复。'**
  String get vbProtectHint;

  /// No description provided for @vbProtectActive.
  ///
  /// In zh, this message translates to:
  /// **'已激活：插件仅作用于监听总线，其余直通（回调超预算）'**
  String get vbProtectActive;

  /// No description provided for @vbProtectActiveTag.
  ///
  /// In zh, this message translates to:
  /// **'保护已激活'**
  String get vbProtectActiveTag;

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
  /// **'增益分频'**
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

  /// No description provided for @bassShapingTitle.
  ///
  /// In zh, this message translates to:
  /// **'低音塑形'**
  String get bassShapingTitle;

  /// No description provided for @bassShapingHint.
  ///
  /// In zh, this message translates to:
  /// **'融合低频搁架滤波与低音单声道化，塑造紧致干净的低频响应'**
  String get bassShapingHint;

  /// No description provided for @shelfFreqTooltip.
  ///
  /// In zh, this message translates to:
  /// **'设定低频搁架滤波器的分频截止频率点（40~400Hz），该频率以下的低音整体增减'**
  String get shelfFreqTooltip;

  /// No description provided for @shelfGainTooltip.
  ///
  /// In zh, this message translates to:
  /// **'分频点以下整体增益提升或衰减（-15~+15dB）。正值增强低频厚度，负值收紧轰鸣'**
  String get shelfGainTooltip;

  /// No description provided for @bassmonoFreqTooltip.
  ///
  /// In zh, this message translates to:
  /// **'低于此分频点的低频信号混合为单声道（20~300Hz），集中低音能量，消除低频相位抵消与混浊感'**
  String get bassmonoFreqTooltip;

  /// No description provided for @bassShapingMasterHint.
  ///
  /// In zh, this message translates to:
  /// **'总开关：任一模块开启即生效'**
  String get bassShapingMasterHint;

  /// No description provided for @bassShelfModule.
  ///
  /// In zh, this message translates to:
  /// **'低频搁架'**
  String get bassShelfModule;

  /// No description provided for @bassMonoModule.
  ///
  /// In zh, this message translates to:
  /// **'低频单声道化'**
  String get bassMonoModule;

  /// No description provided for @bassMonoDesc.
  ///
  /// In zh, this message translates to:
  /// **'把分频点以下的低频合并为单声道，消除相位抵消与浑浊。'**
  String get bassMonoDesc;

  /// No description provided for @channelSelection.
  ///
  /// In zh, this message translates to:
  /// **'声道选择'**
  String get channelSelection;

  /// No description provided for @bassShelfRoutingHint.
  ///
  /// In zh, this message translates to:
  /// **'选择应用低频搁架滤波的目标声道，未选择的声道直接直通。'**
  String get bassShelfRoutingHint;

  /// No description provided for @bassMonoPairsTooltip.
  ///
  /// In zh, this message translates to:
  /// **'选择低频单声道化作用的声道对。未勾选的声道对保持原样直通；立体声/双耳路径仅作用于 L/R。'**
  String get bassMonoPairsTooltip;

  /// No description provided for @bassMonoPairs.
  ///
  /// In zh, this message translates to:
  /// **'声道选择'**
  String get bassMonoPairs;

  /// No description provided for @bassMonoPairCount.
  ///
  /// In zh, this message translates to:
  /// **'已选 {count} 对'**
  String bassMonoPairCount(int count);

  /// No description provided for @bassMonoPairFront.
  ///
  /// In zh, this message translates to:
  /// **'前置'**
  String get bassMonoPairFront;

  /// No description provided for @bassMonoPairCenterLfe.
  ///
  /// In zh, this message translates to:
  /// **'中置+超低'**
  String get bassMonoPairCenterLfe;

  /// No description provided for @bassMonoPairSide.
  ///
  /// In zh, this message translates to:
  /// **'侧环绕'**
  String get bassMonoPairSide;

  /// No description provided for @bassMonoPairBack.
  ///
  /// In zh, this message translates to:
  /// **'后环绕'**
  String get bassMonoPairBack;

  /// No description provided for @bassMonoPairAll.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get bassMonoPairAll;

  /// No description provided for @bassMonoPairFrontOnly.
  ///
  /// In zh, this message translates to:
  /// **'仅前置'**
  String get bassMonoPairFrontOnly;

  /// No description provided for @bassMonoPairUnavailable.
  ///
  /// In zh, this message translates to:
  /// **'当前输出无此声道对'**
  String get bassMonoPairUnavailable;

  /// No description provided for @bassMonoMerge.
  ///
  /// In zh, this message translates to:
  /// **'合并方式'**
  String get bassMonoMerge;

  /// No description provided for @bassMonoMergePerPair.
  ///
  /// In zh, this message translates to:
  /// **'每对独立'**
  String get bassMonoMergePerPair;

  /// No description provided for @bassMonoMergeGlobal.
  ///
  /// In zh, this message translates to:
  /// **'全部合并'**
  String get bassMonoMergeGlobal;

  /// No description provided for @bassMonoMergeSinglePairHint.
  ///
  /// In zh, this message translates to:
  /// **'仅选中一对时两种方式等价'**
  String get bassMonoMergeSinglePairHint;

  /// No description provided for @bassMonoNoneSelected.
  ///
  /// In zh, this message translates to:
  /// **'未选择声道对 · 当前不处理'**
  String get bassMonoNoneSelected;

  /// No description provided for @bassMonoIgnoredPairs.
  ///
  /// In zh, this message translates to:
  /// **'已忽略 {count} 对当前不存在的声道'**
  String bassMonoIgnoredPairs(int count);

  /// No description provided for @bassMonoLfeWarning.
  ///
  /// In zh, this message translates to:
  /// **'C/LFE 取平均会削弱中置与超低音的分离，通常不建议'**
  String get bassMonoLfeWarning;

  /// No description provided for @bassMonoStereoPathHint.
  ///
  /// In zh, this message translates to:
  /// **'立体声/矩阵/双耳路径：仅作用 L/R'**
  String get bassMonoStereoPathHint;

  /// No description provided for @retryNow.
  ///
  /// In zh, this message translates to:
  /// **'重试'**
  String get retryNow;

  /// No description provided for @sampleRateDeviceActual.
  ///
  /// In zh, this message translates to:
  /// **'设备实际：{rate} Hz'**
  String sampleRateDeviceActual(int rate);

  /// No description provided for @sampleRateFollowBridge.
  ///
  /// In zh, this message translates to:
  /// **'桥模式跟随 VB/ASIO 设备，此处选择仅保存偏好（切回进程内模式或下次启动才生效）'**
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

  /// No description provided for @postPerChannelTrim.
  ///
  /// In zh, this message translates to:
  /// **'逐声道输出补偿'**
  String get postPerChannelTrim;

  /// No description provided for @postPerChannelTrimHint.
  ///
  /// In zh, this message translates to:
  /// **'对各个输出声道进行独立的电平微调（-15 ~ +15 dB）'**
  String get postPerChannelTrimHint;

  /// No description provided for @postResetAllTrim.
  ///
  /// In zh, this message translates to:
  /// **'全部归零'**
  String get postResetAllTrim;

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
  /// **'大音乐厅'**
  String get reverbPreset0;

  /// No description provided for @reverbPreset1.
  ///
  /// In zh, this message translates to:
  /// **'音乐厅'**
  String get reverbPreset1;

  /// No description provided for @reverbPreset2.
  ///
  /// In zh, this message translates to:
  /// **'中音乐厅'**
  String get reverbPreset2;

  /// No description provided for @reverbPreset3.
  ///
  /// In zh, this message translates to:
  /// **'小音乐厅'**
  String get reverbPreset3;

  /// No description provided for @reverbPreset4.
  ///
  /// In zh, this message translates to:
  /// **'录音棚'**
  String get reverbPreset4;

  /// No description provided for @reverbPreset5.
  ///
  /// In zh, this message translates to:
  /// **'房间'**
  String get reverbPreset5;

  /// No description provided for @reverbPreset6.
  ///
  /// In zh, this message translates to:
  /// **'大礼堂'**
  String get reverbPreset6;

  /// No description provided for @reverbPreset7.
  ///
  /// In zh, this message translates to:
  /// **'板式混响'**
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

  /// No description provided for @channelsMatrix.
  ///
  /// In zh, this message translates to:
  /// **'矩阵下混'**
  String get channelsMatrix;

  /// No description provided for @channelsDiscrete.
  ///
  /// In zh, this message translates to:
  /// **'离散逐声道'**
  String get channelsDiscrete;

  /// No description provided for @channelPhaseA.
  ///
  /// In zh, this message translates to:
  /// **'当输入音频或输出设备为多声道（4.0 / 5.1 / 7.1）时的 DSP 策略：离散多声道＝全声道独立流经 DSP，各效果器可独立指定作用声道，支持多声道插件与上混；矩阵下混＝折叠为立体声流经 DSP 效果器后再上混回填环绕声道（超低音直接直通）。「双耳虚拟环绕」开启时优先级最高，将自动以 HRIR 渲染为耳机立体声。'**
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

  /// No description provided for @audioParadigm.
  ///
  /// In zh, this message translates to:
  /// **'处理范式'**
  String get audioParadigm;

  /// No description provided for @audioParadigmHint.
  ///
  /// In zh, this message translates to:
  /// **'选择音频接入形态：附加模式原地挂载处理，普通管线模式端到端流转（ADR-009）'**
  String get audioParadigmHint;

  /// No description provided for @paradigmAttachment.
  ///
  /// In zh, this message translates to:
  /// **'附加模式'**
  String get paradigmAttachment;

  /// No description provided for @paradigmPipeline.
  ///
  /// In zh, this message translates to:
  /// **'普通管线模式'**
  String get paradigmPipeline;

  /// No description provided for @modeVoicemeeterApi.
  ///
  /// In zh, this message translates to:
  /// **'Voicemeeter API'**
  String get modeVoicemeeterApi;

  /// No description provided for @pipelineIn.
  ///
  /// In zh, this message translates to:
  /// **'输入端'**
  String get pipelineIn;

  /// No description provided for @pipelineInHint.
  ///
  /// In zh, this message translates to:
  /// **'选择音频如何进入 AuraDSP 核心处理管线'**
  String get pipelineInHint;

  /// No description provided for @pipelineOut.
  ///
  /// In zh, this message translates to:
  /// **'输出端'**
  String get pipelineOut;

  /// No description provided for @pipelineOutHint.
  ///
  /// In zh, this message translates to:
  /// **'选择经由 AuraDSP 处理后的最终音频送往的目标端点'**
  String get pipelineOutHint;

  /// No description provided for @inputWasapi.
  ///
  /// In zh, this message translates to:
  /// **'WASAPI 标准模式'**
  String get inputWasapi;

  /// No description provided for @inputVaio.
  ///
  /// In zh, this message translates to:
  /// **'AuraVAIO 虚拟输入'**
  String get inputVaio;

  /// No description provided for @inputAsioDriver.
  ///
  /// In zh, this message translates to:
  /// **'AuraDSP Virtual ASIO'**
  String get inputAsioDriver;

  /// No description provided for @outputWasapi.
  ///
  /// In zh, this message translates to:
  /// **'WASAPI 标准输出'**
  String get outputWasapi;

  /// No description provided for @outputVaio.
  ///
  /// In zh, this message translates to:
  /// **'AuraVAIO 虚拟输出'**
  String get outputVaio;

  /// No description provided for @outputAsioClient.
  ///
  /// In zh, this message translates to:
  /// **'AuraDSP ASIO Client'**
  String get outputAsioClient;

  /// No description provided for @tooltipInputWasapi.
  ///
  /// In zh, this message translates to:
  /// **'WASAPI 标准模式：支持从系统物理麦克风录制，或对播放设备进行内录/环回 (Loopback) 采集'**
  String get tooltipInputWasapi;

  /// No description provided for @tooltipInputVaio.
  ///
  /// In zh, this message translates to:
  /// **'AuraVAIO 虚拟输入：接收系统音频或第三方播放器输出至 AuraVAIO 虚拟声卡的立体声/7.1 声道流'**
  String get tooltipInputVaio;

  /// No description provided for @tooltipInputAsioDriver.
  ///
  /// In zh, this message translates to:
  /// **'AuraDSP Virtual ASIO：作为虚拟 ASIO 驱动供 FL Studio、Cubase、Ableton 等专业 DAW 宿主调用注入音频'**
  String get tooltipInputAsioDriver;

  /// No description provided for @tooltipOutputWasapi.
  ///
  /// In zh, this message translates to:
  /// **'WASAPI 标准输出：将处理完成的声音输出至物理扬声器、耳机或第三方虚拟输出设备'**
  String get tooltipOutputWasapi;

  /// No description provided for @tooltipOutputVaio.
  ///
  /// In zh, this message translates to:
  /// **'AuraVAIO 虚拟输出：将声音输出至虚拟端点作为数字汇聚，可搭配物理耳机监听镜像使用'**
  String get tooltipOutputVaio;

  /// No description provided for @tooltipOutputAsioClient.
  ///
  /// In zh, this message translates to:
  /// **'AuraDSP ASIO Client：作为客户端对接外置物理专业 ASIO 声卡，享受超低延迟硬件监听'**
  String get tooltipOutputAsioClient;

  /// No description provided for @driverLayerTitle.
  ///
  /// In zh, this message translates to:
  /// **'驱动信息与控制'**
  String get driverLayerTitle;

  /// No description provided for @inputLayerTitle.
  ///
  /// In zh, this message translates to:
  /// **'音频输入'**
  String get inputLayerTitle;

  /// No description provided for @outputLayerTitle.
  ///
  /// In zh, this message translates to:
  /// **'音频输出'**
  String get outputLayerTitle;

  /// No description provided for @inputDisabledNotice.
  ///
  /// In zh, this message translates to:
  /// **'输入端已停用（音频采集暂停，处于静音/无输入状态）'**
  String get inputDisabledNotice;

  /// No description provided for @outputDisabledNotice.
  ///
  /// In zh, this message translates to:
  /// **'输出端已停用（声音输出静音）'**
  String get outputDisabledNotice;

  /// No description provided for @inputDeviceLabel.
  ///
  /// In zh, this message translates to:
  /// **'输入设备'**
  String get inputDeviceLabel;

  /// No description provided for @outputDeviceLabel.
  ///
  /// In zh, this message translates to:
  /// **'输出设备'**
  String get outputDeviceLabel;

  /// No description provided for @defaultInputDevice.
  ///
  /// In zh, this message translates to:
  /// **'系统默认设备 [内录/环回]'**
  String get defaultInputDevice;

  /// No description provided for @defaultOutputDevice.
  ///
  /// In zh, this message translates to:
  /// **'系统默认输出 (Default Render)'**
  String get defaultOutputDevice;

  /// No description provided for @tagLoopback.
  ///
  /// In zh, this message translates to:
  /// **'[内录/环回]'**
  String get tagLoopback;

  /// No description provided for @tagRecording.
  ///
  /// In zh, this message translates to:
  /// **'[录制]'**
  String get tagRecording;

  /// No description provided for @apoTargetEndpoint.
  ///
  /// In zh, this message translates to:
  /// **'附加目标端点'**
  String get apoTargetEndpoint;

  /// No description provided for @apoTargetEndpointHint.
  ///
  /// In zh, this message translates to:
  /// **'选择要挂载 AuraDSP 系统级 APO 处理的音频端点'**
  String get apoTargetEndpointHint;

  /// No description provided for @apoStatus.
  ///
  /// In zh, this message translates to:
  /// **'APO 挂载状态'**
  String get apoStatus;

  /// No description provided for @apoAttached.
  ///
  /// In zh, this message translates to:
  /// **'已附加'**
  String get apoAttached;

  /// No description provided for @apoNotAttached.
  ///
  /// In zh, this message translates to:
  /// **'未附加'**
  String get apoNotAttached;

  /// No description provided for @apoActionAttach.
  ///
  /// In zh, this message translates to:
  /// **'一键附加'**
  String get apoActionAttach;

  /// No description provided for @apoActionDetach.
  ///
  /// In zh, this message translates to:
  /// **'一键卸载'**
  String get apoActionDetach;

  /// No description provided for @asioDriverCardTitle.
  ///
  /// In zh, this message translates to:
  /// **'AuraDSP 虚拟 ASIO 驱动'**
  String get asioDriverCardTitle;

  /// No description provided for @asioDriverStatus.
  ///
  /// In zh, this message translates to:
  /// **'驱动状态'**
  String get asioDriverStatus;

  /// No description provided for @asioDriverRegistered.
  ///
  /// In zh, this message translates to:
  /// **'已在系统注册'**
  String get asioDriverRegistered;

  /// No description provided for @asioDriverNotRegistered.
  ///
  /// In zh, this message translates to:
  /// **'未注册'**
  String get asioDriverNotRegistered;

  /// No description provided for @asioDriverActionRegister.
  ///
  /// In zh, this message translates to:
  /// **'一键注册驱动'**
  String get asioDriverActionRegister;

  /// No description provided for @asioDriverActionUnregister.
  ///
  /// In zh, this message translates to:
  /// **'一键注销驱动'**
  String get asioDriverActionUnregister;

  /// No description provided for @asioDawStatus.
  ///
  /// In zh, this message translates to:
  /// **'DAW 状态'**
  String get asioDawStatus;

  /// No description provided for @asioDawConnected.
  ///
  /// In zh, this message translates to:
  /// **'活跃连接中'**
  String get asioDawConnected;

  /// No description provided for @asioDawIdle.
  ///
  /// In zh, this message translates to:
  /// **'空闲（等待 DAW 接入）'**
  String get asioDawIdle;

  /// No description provided for @asioStatusCheck.
  ///
  /// In zh, this message translates to:
  /// **'检查状态'**
  String get asioStatusCheck;

  /// No description provided for @virtualSinkNotice.
  ///
  /// In zh, this message translates to:
  /// **'提示：AuraVAIO 为虚拟声卡输出，需在 OBS 或录音软件中选择 AuraVAIO 才能听到声音。'**
  String get virtualSinkNotice;

  /// No description provided for @monitorMirroring.
  ///
  /// In zh, this message translates to:
  /// **'本地耳机监听镜像'**
  String get monitorMirroring;

  /// No description provided for @monitorMirroringHint.
  ///
  /// In zh, this message translates to:
  /// **'在向虚拟声卡推流的同时，分路一份音频到当前物理扬声器/耳机以供本地监听'**
  String get monitorMirroringHint;

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
  /// **'输出起始声道对'**
  String get asioOutPair;

  /// No description provided for @asioDeviceChannels.
  ///
  /// In zh, this message translates to:
  /// **'设备通道'**
  String get asioDeviceChannels;

  /// No description provided for @asioTransportChannels.
  ///
  /// In zh, this message translates to:
  /// **'传输声道'**
  String get asioTransportChannels;

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

  /// No description provided for @visualizerSettingsTip.
  ///
  /// In zh, this message translates to:
  /// **'可视化设置'**
  String get visualizerSettingsTip;

  /// No description provided for @visualizerShowLyricsTip.
  ///
  /// In zh, this message translates to:
  /// **'显示歌词'**
  String get visualizerShowLyricsTip;

  /// No description provided for @visualizerHideLyricsTip.
  ///
  /// In zh, this message translates to:
  /// **'隐藏歌词'**
  String get visualizerHideLyricsTip;

  /// No description provided for @visualizerLyricsNoMedia.
  ///
  /// In zh, this message translates to:
  /// **'未检测到正在播放的媒体'**
  String get visualizerLyricsNoMedia;

  /// No description provided for @visualizerLyricsNoMediaHint.
  ///
  /// In zh, this message translates to:
  /// **'在系统中播放音乐后，歌词会自动匹配并滚动显示'**
  String get visualizerLyricsNoMediaHint;

  /// No description provided for @visualizerLyricsSearching.
  ///
  /// In zh, this message translates to:
  /// **'正在检索歌词…'**
  String get visualizerLyricsSearching;

  /// No description provided for @visualizerLyricsSearchingHint.
  ///
  /// In zh, this message translates to:
  /// **'正在为当前曲目匹配在线歌词'**
  String get visualizerLyricsSearchingHint;

  /// No description provided for @visualizerLyricsNotFound.
  ///
  /// In zh, this message translates to:
  /// **'未找到匹配的歌词'**
  String get visualizerLyricsNotFound;

  /// No description provided for @visualizerLyricsNotFoundHint.
  ///
  /// In zh, this message translates to:
  /// **'可重新获取，或选择本地 LRC 文件手动加载'**
  String get visualizerLyricsNotFoundHint;

  /// No description provided for @visualizerLyricsReady.
  ///
  /// In zh, this message translates to:
  /// **'歌词已加载'**
  String get visualizerLyricsReady;

  /// No description provided for @visualizerLyricsRetry.
  ///
  /// In zh, this message translates to:
  /// **'重新获取'**
  String get visualizerLyricsRetry;

  /// No description provided for @visualizerLyricsPickLocal.
  ///
  /// In zh, this message translates to:
  /// **'本地 LRC'**
  String get visualizerLyricsPickLocal;

  /// No description provided for @visualizerLyricsCalibrate.
  ///
  /// In zh, this message translates to:
  /// **'校准到这一行'**
  String get visualizerLyricsCalibrate;

  /// No description provided for @visualizerResetPeakTip.
  ///
  /// In zh, this message translates to:
  /// **'重置峰值保持'**
  String get visualizerResetPeakTip;

  /// No description provided for @visualizerDisplayRestoreTip.
  ///
  /// In zh, this message translates to:
  /// **'还原：标准页面布局'**
  String get visualizerDisplayRestoreTip;

  /// No description provided for @visualizerDisplayStageTip.
  ///
  /// In zh, this message translates to:
  /// **'软件全屏：视效铺满应用窗口'**
  String get visualizerDisplayStageTip;

  /// No description provided for @visualizerDisplayImmersiveTip.
  ///
  /// In zh, this message translates to:
  /// **'仅视效全屏：隐藏导航与电平，只留视觉内容（Esc 逐级退出）'**
  String get visualizerDisplayImmersiveTip;

  /// No description provided for @visualizerDrawerTitle.
  ///
  /// In zh, this message translates to:
  /// **'可视化设置'**
  String get visualizerDrawerTitle;

  /// No description provided for @visualizerDrawerCloseTip.
  ///
  /// In zh, this message translates to:
  /// **'关闭设置'**
  String get visualizerDrawerCloseTip;

  /// No description provided for @visualizerSectionPalette.
  ///
  /// In zh, this message translates to:
  /// **'色彩主题'**
  String get visualizerSectionPalette;

  /// No description provided for @visualizerSectionPaletteInfo.
  ///
  /// In zh, this message translates to:
  /// **'选择频谱与波形配色方案'**
  String get visualizerSectionPaletteInfo;

  /// No description provided for @visualizerSectionDynamics.
  ///
  /// In zh, this message translates to:
  /// **'动态与阻尼'**
  String get visualizerSectionDynamics;

  /// No description provided for @visualizerSectionDynamicsInfo.
  ///
  /// In zh, this message translates to:
  /// **'调节音频能量响应灵敏度与衰减物理'**
  String get visualizerSectionDynamicsInfo;

  /// No description provided for @visualizerSectionVisuals.
  ///
  /// In zh, this message translates to:
  /// **'画面与参考线'**
  String get visualizerSectionVisuals;

  /// No description provided for @visualizerSectionVisualsInfo.
  ///
  /// In zh, this message translates to:
  /// **'微调辉光、网格与刻度'**
  String get visualizerSectionVisualsInfo;

  /// No description provided for @visualizerSectionLyrics.
  ///
  /// In zh, this message translates to:
  /// **'歌词与字幕'**
  String get visualizerSectionLyrics;

  /// No description provided for @visualizerSectionLyricsInfo.
  ///
  /// In zh, this message translates to:
  /// **'配置同步滚动歌词显示'**
  String get visualizerSectionLyricsInfo;

  /// No description provided for @visualizerSensitivity.
  ///
  /// In zh, this message translates to:
  /// **'灵敏度'**
  String get visualizerSensitivity;

  /// No description provided for @visualizerSensitivityInfo.
  ///
  /// In zh, this message translates to:
  /// **'音频能量放大倍率，决定视觉跳动幅度'**
  String get visualizerSensitivityInfo;

  /// No description provided for @visualizerDecay.
  ///
  /// In zh, this message translates to:
  /// **'衰减阻尼'**
  String get visualizerDecay;

  /// No description provided for @visualizerDecayInfo.
  ///
  /// In zh, this message translates to:
  /// **'峰值与频谱下落时的空气阻尼阻力'**
  String get visualizerDecayInfo;

  /// No description provided for @visualizerGravity.
  ///
  /// In zh, this message translates to:
  /// **'重力'**
  String get visualizerGravity;

  /// No description provided for @visualizerGravityInfo.
  ///
  /// In zh, this message translates to:
  /// **'把峰值持续拉向底部的重力加速度'**
  String get visualizerGravityInfo;

  /// No description provided for @visualizerBloom.
  ///
  /// In zh, this message translates to:
  /// **'磷光辉光'**
  String get visualizerBloom;

  /// No description provided for @visualizerBloomInfo.
  ///
  /// In zh, this message translates to:
  /// **'阴极射线余辉与 LED 光晕强度'**
  String get visualizerBloomInfo;

  /// No description provided for @visualizerLineWidth.
  ///
  /// In zh, this message translates to:
  /// **'线条粗细'**
  String get visualizerLineWidth;

  /// No description provided for @visualizerLineWidthInfo.
  ///
  /// In zh, this message translates to:
  /// **'示波光束、相位曲线与向量线的描边宽度'**
  String get visualizerLineWidthInfo;

  /// No description provided for @visualizerBandsDensity.
  ///
  /// In zh, this message translates to:
  /// **'频段密度'**
  String get visualizerBandsDensity;

  /// No description provided for @visualizerBandsDensityInfo.
  ///
  /// In zh, this message translates to:
  /// **'选择 32 或 64 频段分辨率'**
  String get visualizerBandsDensityInfo;

  /// No description provided for @visualizerToggleGrid.
  ///
  /// In zh, this message translates to:
  /// **'参考网格'**
  String get visualizerToggleGrid;

  /// No description provided for @visualizerToggleGridInfo.
  ///
  /// In zh, this message translates to:
  /// **'显示 100Hz / 1kHz / 10kHz 倍频程与水平 dB 参考线'**
  String get visualizerToggleGridInfo;

  /// No description provided for @visualizerTogglePeaks.
  ///
  /// In zh, this message translates to:
  /// **'峰值保持线'**
  String get visualizerTogglePeaks;

  /// No description provided for @visualizerTogglePeaksInfo.
  ///
  /// In zh, this message translates to:
  /// **'在频谱柱顶部保留重力回落的峰值线'**
  String get visualizerTogglePeaksInfo;

  /// No description provided for @visualizerToggleDbScale.
  ///
  /// In zh, this message translates to:
  /// **'dBFS 刻度'**
  String get visualizerToggleDbScale;

  /// No description provided for @visualizerToggleDbScaleInfo.
  ///
  /// In zh, this message translates to:
  /// **'在右侧边框显示 0 至 -60 dBFS 声压刻度'**
  String get visualizerToggleDbScaleInfo;

  /// No description provided for @visualizerToggleLyrics.
  ///
  /// In zh, this message translates to:
  /// **'歌词叠加'**
  String get visualizerToggleLyrics;

  /// No description provided for @visualizerToggleLyricsInfo.
  ///
  /// In zh, this message translates to:
  /// **'在视效舞台上叠加同步歌词'**
  String get visualizerToggleLyricsInfo;

  /// No description provided for @visualizerToggleTranslation.
  ///
  /// In zh, this message translates to:
  /// **'双语翻译'**
  String get visualizerToggleTranslation;

  /// No description provided for @visualizerToggleTranslationInfo.
  ///
  /// In zh, this message translates to:
  /// **'在歌词主行下方显示可用译文（需先开启歌词）'**
  String get visualizerToggleTranslationInfo;

  /// No description provided for @visualizerResetDefaults.
  ///
  /// In zh, this message translates to:
  /// **'恢复出厂设置'**
  String get visualizerResetDefaults;

  /// No description provided for @visualizerResetDefaultsTip.
  ///
  /// In zh, this message translates to:
  /// **'将所有可视化参数恢复为默认值'**
  String get visualizerResetDefaultsTip;

  /// No description provided for @visualizerStyleBars.
  ///
  /// In zh, this message translates to:
  /// **'频谱柱'**
  String get visualizerStyleBars;

  /// No description provided for @visualizerStyleOscilloscope.
  ///
  /// In zh, this message translates to:
  /// **'示波器'**
  String get visualizerStyleOscilloscope;

  /// No description provided for @visualizerStyleGoniometer.
  ///
  /// In zh, this message translates to:
  /// **'相位仪'**
  String get visualizerStyleGoniometer;

  /// No description provided for @visualizerStyleCyberGrid.
  ///
  /// In zh, this message translates to:
  /// **'赛博网格'**
  String get visualizerStyleCyberGrid;

  /// No description provided for @visualizerStylePulseOrb.
  ///
  /// In zh, this message translates to:
  /// **'脉冲星云'**
  String get visualizerStylePulseOrb;

  /// No description provided for @visualizerStyleAurora.
  ///
  /// In zh, this message translates to:
  /// **'极光飘带'**
  String get visualizerStyleAurora;

  /// No description provided for @visualizerStyleTunnel.
  ///
  /// In zh, this message translates to:
  /// **'霓虹隧道'**
  String get visualizerStyleTunnel;

  /// No description provided for @visualizerStyleMilkdrop.
  ///
  /// In zh, this message translates to:
  /// **'MilkDrop'**
  String get visualizerStyleMilkdrop;

  /// No description provided for @visualizerStyleFluid.
  ///
  /// In zh, this message translates to:
  /// **'流体丝绸'**
  String get visualizerStyleFluid;

  /// No description provided for @visualizerStyleTornado.
  ///
  /// In zh, this message translates to:
  /// **'粒子龙卷风'**
  String get visualizerStyleTornado;

  /// No description provided for @visualizerThemeSystem.
  ///
  /// In zh, this message translates to:
  /// **'跟随系统'**
  String get visualizerThemeSystem;

  /// No description provided for @visualizerThemeNeonCyber.
  ///
  /// In zh, this message translates to:
  /// **'赛博霓虹'**
  String get visualizerThemeNeonCyber;

  /// No description provided for @visualizerThemeAmberTube.
  ///
  /// In zh, this message translates to:
  /// **'琥珀电子管'**
  String get visualizerThemeAmberTube;

  /// No description provided for @visualizerThemeMatrixGreen.
  ///
  /// In zh, this message translates to:
  /// **'矩阵磷光'**
  String get visualizerThemeMatrixGreen;

  /// No description provided for @visualizerThemeAuroraGlow.
  ///
  /// In zh, this message translates to:
  /// **'极光'**
  String get visualizerThemeAuroraGlow;

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
  /// **'已编译 · 点击顶栏应用生效'**
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
  /// **'脚本库'**
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

  /// No description provided for @lpApoDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入 EqualizerAPO 预设 (.txt)'**
  String get lpApoDialogTitle;

  /// No description provided for @lpApoDialogDesc.
  ///
  /// In zh, this message translates to:
  /// **'将 EqualizerAPO / Peace 参量均衡文本转换为高性能 EEL2 脚本'**
  String get lpApoDialogDesc;

  /// No description provided for @lpApoOpenFile.
  ///
  /// In zh, this message translates to:
  /// **'打开 .txt 文件'**
  String get lpApoOpenFile;

  /// No description provided for @lpApoPasteHint.
  ///
  /// In zh, this message translates to:
  /// **'在此粘贴 EqualizerAPO 配置文本（例如 Filter: ON PK Fc 1000 Hz Gain -3.0 dB Q 1.41）...'**
  String get lpApoPasteHint;

  /// No description provided for @lpApoSwapChannels.
  ///
  /// In zh, this message translates to:
  /// **'声道互换 (L ↔ R)'**
  String get lpApoSwapChannels;

  /// No description provided for @lpApoInvertPolarity.
  ///
  /// In zh, this message translates to:
  /// **'极性反转 (相位 180°)'**
  String get lpApoInvertPolarity;

  /// No description provided for @lpApoFiltersDetected.
  ///
  /// In zh, this message translates to:
  /// **'已解析出 {n} 个滤波器'**
  String lpApoFiltersDetected(int n);

  /// No description provided for @lpApoPreampDetected.
  ///
  /// In zh, this message translates to:
  /// **'前级增益: {gain} dB'**
  String lpApoPreampDetected(String gain);

  /// No description provided for @lpApoApply.
  ///
  /// In zh, this message translates to:
  /// **'填入编辑器'**
  String get lpApoApply;

  /// No description provided for @lpApoPreview.
  ///
  /// In zh, this message translates to:
  /// **'生成的 EEL2 代码预览'**
  String get lpApoPreview;

  /// No description provided for @lpFind.
  ///
  /// In zh, this message translates to:
  /// **'查找'**
  String get lpFind;

  /// No description provided for @lpReplace.
  ///
  /// In zh, this message translates to:
  /// **'替换'**
  String get lpReplace;

  /// No description provided for @lpReplaceAll.
  ///
  /// In zh, this message translates to:
  /// **'全部替换'**
  String get lpReplaceAll;

  /// No description provided for @lpFindNext.
  ///
  /// In zh, this message translates to:
  /// **'下一个'**
  String get lpFindNext;

  /// No description provided for @lpFindPrev.
  ///
  /// In zh, this message translates to:
  /// **'上一个'**
  String get lpFindPrev;

  /// No description provided for @lpMatchCase.
  ///
  /// In zh, this message translates to:
  /// **'区分大小写'**
  String get lpMatchCase;

  /// No description provided for @lpMatchCount.
  ///
  /// In zh, this message translates to:
  /// **'第 {current} 项，共 {total} 项'**
  String lpMatchCount(int current, int total);

  /// No description provided for @lpNoMatches.
  ///
  /// In zh, this message translates to:
  /// **'无匹配项'**
  String get lpNoMatches;

  /// No description provided for @lpOutline.
  ///
  /// In zh, this message translates to:
  /// **'代码大纲'**
  String get lpOutline;

  /// No description provided for @lpOutlineEmpty.
  ///
  /// In zh, this message translates to:
  /// **'未找到段指令或函数声明'**
  String get lpOutlineEmpty;

  /// No description provided for @lpTemplates.
  ///
  /// In zh, this message translates to:
  /// **'代码模板向导'**
  String get lpTemplates;

  /// No description provided for @lpTemplatesDesc.
  ///
  /// In zh, this message translates to:
  /// **'选择标准音频 DSP 起步模板，加速算法开发'**
  String get lpTemplatesDesc;

  /// No description provided for @lpTemplateUse.
  ///
  /// In zh, this message translates to:
  /// **'应用此模板'**
  String get lpTemplateUse;

  /// No description provided for @lpManualSearchHint.
  ///
  /// In zh, this message translates to:
  /// **'搜索 80+ EEL2 内置函数、关键字、寄存器...'**
  String get lpManualSearchHint;

  /// No description provided for @lpManualInsert.
  ///
  /// In zh, this message translates to:
  /// **'插入到光标处'**
  String get lpManualInsert;

  /// No description provided for @lpManualParamTitle.
  ///
  /// In zh, this message translates to:
  /// **'参数列表'**
  String get lpManualParamTitle;

  /// No description provided for @lpManualReturnTitle.
  ///
  /// In zh, this message translates to:
  /// **'返回值'**
  String get lpManualReturnTitle;

  /// No description provided for @lpManualExampleTitle.
  ///
  /// In zh, this message translates to:
  /// **'应用示例'**
  String get lpManualExampleTitle;

  /// No description provided for @lpAllCategories.
  ///
  /// In zh, this message translates to:
  /// **'全部'**
  String get lpAllCategories;

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

  /// No description provided for @presetDirtyBadge.
  ///
  /// In zh, this message translates to:
  /// **'自定义（未保存）'**
  String get presetDirtyBadge;

  /// No description provided for @presetDeleted.
  ///
  /// In zh, this message translates to:
  /// **'预设已删除'**
  String get presetDeleted;

  /// No description provided for @presetDeleteFail.
  ///
  /// In zh, this message translates to:
  /// **'删除失败（文件可能被占用或已不存在）'**
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

  /// No description provided for @tubeHint.
  ///
  /// In zh, this message translates to:
  /// **'模拟经典电子管放大器与开盘磁带机的非线性饱和特性。通过注入富有音乐感的偶次与奇次泛音，消除数字音频生硬冷涩感，赋予声音温润、饱满的模拟胶片暖色调。'**
  String get tubeHint;

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
  /// **'低音增强声学模式：\n• 自然低音：纯线性动态低频增益，无谐波渲染，保留原生打击瞬态\n• 纯净低音：注入适量偶次谐波，增强中低频饱满度与结像轮廓\n• 超重低音：深度次谐波合成与能量共振，使紧凑型耳机/音箱重现深潜体感'**
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

  /// No description provided for @sysTitle.
  ///
  /// In zh, this message translates to:
  /// **'系统'**
  String get sysTitle;

  /// No description provided for @sysHint.
  ///
  /// In zh, this message translates to:
  /// **'系统托盘常驻与开机自启动'**
  String get sysHint;

  /// No description provided for @sysTray.
  ///
  /// In zh, this message translates to:
  /// **'最小化到托盘'**
  String get sysTray;

  /// No description provided for @sysTrayHint.
  ///
  /// In zh, this message translates to:
  /// **'关闭窗口时隐藏到系统托盘，音频继续播放；退出请用托盘菜单'**
  String get sysTrayHint;

  /// No description provided for @sysAutostart.
  ///
  /// In zh, this message translates to:
  /// **'开机自启'**
  String get sysAutostart;

  /// No description provided for @trayShow.
  ///
  /// In zh, this message translates to:
  /// **'显示主窗口'**
  String get trayShow;

  /// No description provided for @trayQuit.
  ///
  /// In zh, this message translates to:
  /// **'退出'**
  String get trayQuit;

  /// No description provided for @sysAutostartHint.
  ///
  /// In zh, this message translates to:
  /// **'登录系统时自动启动并后台运行 AuraDSP'**
  String get sysAutostartHint;

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

  /// Tooltip for a latency value derived from the nominal table or analytic estimate rather than a real impulse-response measurement.
  ///
  /// In zh, this message translates to:
  /// **'估算值（非实测）: {text}\n来自标称表或解析推算，未经脉冲响应测量'**
  String latTipEstimated(String text);

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

  /// No description provided for @fxCatSpatial.
  ///
  /// In zh, this message translates to:
  /// **'空间效果'**
  String get fxCatSpatial;

  /// No description provided for @fxCatStereoOnly.
  ///
  /// In zh, this message translates to:
  /// **'立体声专用'**
  String get fxCatStereoOnly;

  /// No description provided for @fxCatLate.
  ///
  /// In zh, this message translates to:
  /// **'激励与输出'**
  String get fxCatLate;

  /// No description provided for @spatialTitle.
  ///
  /// In zh, this message translates to:
  /// **'空间音效'**
  String get spatialTitle;

  /// No description provided for @spatialHint.
  ///
  /// In zh, this message translates to:
  /// **'基于 HRTF 空间声学模型与早期反射算法，在立体声耳机上重现多扬声器真实监听声学室的开阔声场与实体脱箱感。'**
  String get spatialHint;

  /// No description provided for @spatialStyle.
  ///
  /// In zh, this message translates to:
  /// **'风格'**
  String get spatialStyle;

  /// No description provided for @spatialStyleInfo.
  ///
  /// In zh, this message translates to:
  /// **'精选空间声学预设：一键应用预置的房间反射、扬声器张角与人声对白聚焦参数。'**
  String get spatialStyleInfo;

  /// No description provided for @spatialStyleCinema.
  ///
  /// In zh, this message translates to:
  /// **'影院'**
  String get spatialStyleCinema;

  /// No description provided for @spatialStyleImaging.
  ///
  /// In zh, this message translates to:
  /// **'定位'**
  String get spatialStyleImaging;

  /// No description provided for @spatialStyleNeutral.
  ///
  /// In zh, this message translates to:
  /// **'中性'**
  String get spatialStyleNeutral;

  /// No description provided for @spatialStyleCustom.
  ///
  /// In zh, this message translates to:
  /// **'自定义'**
  String get spatialStyleCustom;

  /// No description provided for @spatialRoom.
  ///
  /// In zh, this message translates to:
  /// **'房间'**
  String get spatialRoom;

  /// No description provided for @spatialRoomInfo.
  ///
  /// In zh, this message translates to:
  /// **'声学室体量与早期反射强度：0 为无反射自由声场，数值增大可扩展房间空间体量与壁面反射余韵。'**
  String get spatialRoomInfo;

  /// No description provided for @spatialWidth.
  ///
  /// In zh, this message translates to:
  /// **'张角'**
  String get spatialWidth;

  /// No description provided for @spatialWidthInfo.
  ///
  /// In zh, this message translates to:
  /// **'声场展宽与虚拟扬声器开角：拓展左右声场宽度，营造沉浸式脱箱感。'**
  String get spatialWidthInfo;

  /// No description provided for @spatialCenter.
  ///
  /// In zh, this message translates to:
  /// **'中置'**
  String get spatialCenter;

  /// No description provided for @spatialCenterInfo.
  ///
  /// In zh, this message translates to:
  /// **'中置声像与对白聚焦：适度提升可增强居中人声主体的凝聚力与清晰度。'**
  String get spatialCenterInfo;

  /// No description provided for @spatialOutGain.
  ///
  /// In zh, this message translates to:
  /// **'输出'**
  String get spatialOutGain;

  /// No description provided for @spatialOutGainInfo.
  ///
  /// In zh, this message translates to:
  /// **'空间音效模块后级输出增益补偿 (-12 ~ +6 dB)。'**
  String get spatialOutGainInfo;

  /// No description provided for @spatialAutoGain.
  ///
  /// In zh, this message translates to:
  /// **'自动增益'**
  String get spatialAutoGain;

  /// No description provided for @spatialAutoGainInfo.
  ///
  /// In zh, this message translates to:
  /// **'等响度自适应控制：自动匹配输入信号有效能量，避免声场处理引起整体音量跳变。'**
  String get spatialAutoGainInfo;

  /// No description provided for @spatialMix.
  ///
  /// In zh, this message translates to:
  /// **'空间化比例'**
  String get spatialMix;

  /// No description provided for @spatialMixInfo.
  ///
  /// In zh, this message translates to:
  /// **'干声与空间声的混合比例。0% 等同旁路，100% 为完整虚拟声场'**
  String get spatialMixInfo;

  /// No description provided for @spatialElevation.
  ///
  /// In zh, this message translates to:
  /// **'高度'**
  String get spatialElevation;

  /// No description provided for @spatialElevationInfo.
  ///
  /// In zh, this message translates to:
  /// **'虚拟舞台的仰角。正值抬升声像，负值下沉；用于强化上方/下方定位'**
  String get spatialElevationInfo;

  /// No description provided for @spatialBinaural.
  ///
  /// In zh, this message translates to:
  /// **'多声道虚拟环绕'**
  String get spatialBinaural;

  /// No description provided for @spatialBinauralInfo.
  ///
  /// In zh, this message translates to:
  /// **'输入 4/5.1/7.1 时把全部声道渲染为双耳立体声（耳机）。开启后输出仅 FL/FR，其余声道静音，并接管设置页的「声道模式」（该项此时不生效）'**
  String get spatialBinauralInfo;

  /// No description provided for @spatialHeadTrack.
  ///
  /// In zh, this message translates to:
  /// **'头部跟随'**
  String get spatialHeadTrack;

  /// No description provided for @spatialHeadTrackInfo.
  ///
  /// In zh, this message translates to:
  /// **'开启后接收 OpenTrack UDP（端口 4242）的头部朝向；关闭时使用手动角度'**
  String get spatialHeadTrackInfo;

  /// No description provided for @spatialHeadAzim.
  ///
  /// In zh, this message translates to:
  /// **'头部朝向'**
  String get spatialHeadAzim;

  /// No description provided for @spatialHeadAzimInfo.
  ///
  /// In zh, this message translates to:
  /// **'手动偏航角度；头部跟随时由外部数据覆盖'**
  String get spatialHeadAzimInfo;

  /// No description provided for @src51Fold.
  ///
  /// In zh, this message translates to:
  /// **'混缩'**
  String get src51Fold;

  /// No description provided for @src51Pass.
  ///
  /// In zh, this message translates to:
  /// **'直通'**
  String get src51Pass;

  /// No description provided for @src51Hint.
  ///
  /// In zh, this message translates to:
  /// **'多声道文件：混缩进引擎处理，直通绕开引擎；设备声道不足时自动回落混缩'**
  String get src51Hint;

  /// No description provided for @bassmonoHint.
  ///
  /// In zh, this message translates to:
  /// **'链头处理：分频点以下单声道化，防小音箱低频破音'**
  String get bassmonoHint;

  /// No description provided for @bassmonoFreq.
  ///
  /// In zh, this message translates to:
  /// **'低音单声道分频'**
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

  /// No description provided for @chainGrpInput.
  ///
  /// In zh, this message translates to:
  /// **'输入整形'**
  String get chainGrpInput;

  /// No description provided for @chainGrpTone.
  ///
  /// In zh, this message translates to:
  /// **'音色与动态'**
  String get chainGrpTone;

  /// No description provided for @chainGrpEqScript.
  ///
  /// In zh, this message translates to:
  /// **'均衡与脚本'**
  String get chainGrpEqScript;

  /// No description provided for @chainGrpSound.
  ///
  /// In zh, this message translates to:
  /// **'声场'**
  String get chainGrpSound;

  /// No description provided for @chainGrpSpatial.
  ///
  /// In zh, this message translates to:
  /// **'空间'**
  String get chainGrpSpatial;

  /// No description provided for @chainGrpOut.
  ///
  /// In zh, this message translates to:
  /// **'输出段'**
  String get chainGrpOut;

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
  /// **'DSP 主音效链前置'**
  String get chainStagePreVendor;

  /// No description provided for @chainStagePostVendor.
  ///
  /// In zh, this message translates to:
  /// **'DSP 主音效链后置'**
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

  /// No description provided for @chainSlotRemoteFailed.
  ///
  /// In zh, this message translates to:
  /// **'插件宿主已断开（已旁路）'**
  String get chainSlotRemoteFailed;

  /// No description provided for @chainPdcLabel.
  ///
  /// In zh, this message translates to:
  /// **'延迟补偿 (PDC)'**
  String get chainPdcLabel;

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
  /// **'系统标准 VST3 / CLAP 64 位专业插件扫描与管理，支持无缝延迟补偿与高保真超低延迟运行。'**
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

  /// No description provided for @plugFeatDirs.
  ///
  /// In zh, this message translates to:
  /// **'可自定义插件目录检索与本地状态快照'**
  String get plugFeatDirs;

  /// No description provided for @plugFeatRt.
  ///
  /// In zh, this message translates to:
  /// **'实时极速监听：专为专业制作定制的零卡顿音频通道'**
  String get plugFeatRt;

  /// No description provided for @plugFeatRoute.
  ///
  /// In zh, this message translates to:
  /// **'VB 按路插件逐路独立配置'**
  String get plugFeatRoute;

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
  /// **'插件扫描目录'**
  String get plugCustomTitle;

  /// No description provided for @plugCustomHint.
  ///
  /// In zh, this message translates to:
  /// **'勾选需要扫描的目录（平台标准目录已自动预置；内置目录不可移除）。扫描只遍历勾选项及其子目录。'**
  String get plugCustomHint;

  /// No description provided for @plugCustomAdd.
  ///
  /// In zh, this message translates to:
  /// **'添加目录'**
  String get plugCustomAdd;

  /// No description provided for @plugCustomEmpty.
  ///
  /// In zh, this message translates to:
  /// **'扫描目录列表为空。点击「添加目录」选择插件所在文件夹。'**
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

  /// No description provided for @plugRouteBypassed.
  ///
  /// In zh, this message translates to:
  /// **'旁路'**
  String get plugRouteBypassed;

  /// No description provided for @abSlotA.
  ///
  /// In zh, this message translates to:
  /// **'A 预设'**
  String get abSlotA;

  /// No description provided for @abSlotB.
  ///
  /// In zh, this message translates to:
  /// **'B 预设'**
  String get abSlotB;

  /// No description provided for @abAutoSave.
  ///
  /// In zh, this message translates to:
  /// **'自动保存'**
  String get abAutoSave;

  /// No description provided for @abInheritFrom.
  ///
  /// In zh, this message translates to:
  /// **'继承自 {src}'**
  String abInheritFrom(String src);

  /// No description provided for @abReset.
  ///
  /// In zh, this message translates to:
  /// **'复原（清除当前预设，不影响来源）'**
  String get abReset;

  /// No description provided for @abResetDone.
  ///
  /// In zh, this message translates to:
  /// **'已复原当前预设'**
  String get abResetDone;

  /// No description provided for @plugRouteLocked.
  ///
  /// In zh, this message translates to:
  /// **'已锁定'**
  String get plugRouteLocked;

  /// No description provided for @plugChStereoOnly.
  ///
  /// In zh, this message translates to:
  /// **'VB 模式每通道仅立体声（L/R）进入插件链'**
  String get plugChStereoOnly;

  /// No description provided for @plugLoading.
  ///
  /// In zh, this message translates to:
  /// **'加载中…'**
  String get plugLoading;

  /// No description provided for @plugUnloading.
  ///
  /// In zh, this message translates to:
  /// **'卸载中…'**
  String get plugUnloading;

  /// No description provided for @plugStateActive.
  ///
  /// In zh, this message translates to:
  /// **'生效'**
  String get plugStateActive;

  /// No description provided for @plugStateBypassed.
  ///
  /// In zh, this message translates to:
  /// **'旁路'**
  String get plugStateBypassed;

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

  /// No description provided for @plugSlotBypassed.
  ///
  /// In zh, this message translates to:
  /// **'插槽 {n} 旁路'**
  String plugSlotBypassed(int n);

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

  /// No description provided for @plugPartialBypass.
  ///
  /// In zh, this message translates to:
  /// **'部分旁路'**
  String get plugPartialBypass;

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

  /// No description provided for @compHint.
  ///
  /// In zh, this message translates to:
  /// **'平抑突发大音量，提亮微弱细节，让听感饱满统一。右侧仪表实时显示压限削减量 (GR)。'**
  String get compHint;

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

  /// No description provided for @compModePairBadge.
  ///
  /// In zh, this message translates to:
  /// **'性能模式：逐对'**
  String get compModePairBadge;

  /// No description provided for @compModePairHint.
  ///
  /// In zh, this message translates to:
  /// **'性能模式成对分配压缩槽位以节省计算资源与内存。需成对选择声道，半选对将不被压缩。'**
  String get compModePairHint;

  /// No description provided for @compModeSemiSelectedWarning.
  ///
  /// In zh, this message translates to:
  /// **'性能模式需成对选择，半选对未生效'**
  String get compModeSemiSelectedWarning;

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
  /// **'基于 8192 点因果最小相位 FIR 卷积引擎，支持导入 AutoEq GraphicEQ 曲线或自定义任意频响响应，高精度校正耳机与扬声器频响缺陷。'**
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

  /// No description provided for @fxCatFront.
  ///
  /// In zh, this message translates to:
  /// **'前置整形'**
  String get fxCatFront;

  /// No description provided for @fxCatCore.
  ///
  /// In zh, this message translates to:
  /// **'核心处理'**
  String get fxCatCore;

  /// No description provided for @channelCenter.
  ///
  /// In zh, this message translates to:
  /// **'中央声道 (C)'**
  String get channelCenter;

  /// No description provided for @channelLfe.
  ///
  /// In zh, this message translates to:
  /// **'低频效果 (LFE)'**
  String get channelLfe;

  /// No description provided for @channelSurroundLeft.
  ///
  /// In zh, this message translates to:
  /// **'左环绕 (SL)'**
  String get channelSurroundLeft;

  /// No description provided for @channelSurroundRight.
  ///
  /// In zh, this message translates to:
  /// **'右环绕 (SR)'**
  String get channelSurroundRight;

  /// No description provided for @channelBackLeft.
  ///
  /// In zh, this message translates to:
  /// **'左后环绕 (BL)'**
  String get channelBackLeft;

  /// No description provided for @channelBackRight.
  ///
  /// In zh, this message translates to:
  /// **'右后环绕 (BR)'**
  String get channelBackRight;

  /// No description provided for @inputChannelsCount.
  ///
  /// In zh, this message translates to:
  /// **'{n} 声道'**
  String inputChannelsCount(int n);

  /// No description provided for @inputBalanceTuned.
  ///
  /// In zh, this message translates to:
  /// **'已微调 {n} 声道'**
  String inputBalanceTuned(int n);

  /// No description provided for @inputBalanceDefault.
  ///
  /// In zh, this message translates to:
  /// **'100% 默认平衡'**
  String get inputBalanceDefault;

  /// No description provided for @eqPresetElectronic.
  ///
  /// In zh, this message translates to:
  /// **'电子舞曲 (EDM)'**
  String get eqPresetElectronic;

  /// No description provided for @eqPresetHiphop.
  ///
  /// In zh, this message translates to:
  /// **'嘻哈说唱 (Hip-Hop)'**
  String get eqPresetHiphop;

  /// No description provided for @eqPresetAcoustic.
  ///
  /// In zh, this message translates to:
  /// **'原声不插电 (Acoustic)'**
  String get eqPresetAcoustic;

  /// No description provided for @eqPresetMetal.
  ///
  /// In zh, this message translates to:
  /// **'重金属 (Metal)'**
  String get eqPresetMetal;

  /// No description provided for @eqPresetPodcast.
  ///
  /// In zh, this message translates to:
  /// **'播客语音 (Podcast)'**
  String get eqPresetPodcast;

  /// No description provided for @convIrPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入或选择脉冲响应 (IR) 文件路径：'**
  String get convIrPrompt;

  /// No description provided for @convLoadIr.
  ///
  /// In zh, this message translates to:
  /// **'加载 IR'**
  String get convLoadIr;

  /// No description provided for @ddcVdcPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入或选择 VDC 空间校正文件路径：'**
  String get ddcVdcPrompt;

  /// No description provided for @ddcLoadVdc.
  ///
  /// In zh, this message translates to:
  /// **'加载 VDC'**
  String get ddcLoadVdc;

  /// No description provided for @arbmagPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入或选择 AutoEq / GraphicEQ 曲线文件路径：'**
  String get arbmagPrompt;

  /// No description provided for @testAudioWavPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入或选择测试音频 (WAV) 文件路径：'**
  String get testAudioWavPrompt;

  /// No description provided for @testAudioMp3Prompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入或选择 MP3 音频文件路径：'**
  String get testAudioMp3Prompt;

  /// No description provided for @testAudioLoad.
  ///
  /// In zh, this message translates to:
  /// **'加载音频'**
  String get testAudioLoad;

  /// No description provided for @pathPickerTitle.
  ///
  /// In zh, this message translates to:
  /// **'选择路径'**
  String get pathPickerTitle;

  /// No description provided for @pathPickerConfirm.
  ///
  /// In zh, this message translates to:
  /// **'确认'**
  String get pathPickerConfirm;

  /// No description provided for @pathPickerBrowse.
  ///
  /// In zh, this message translates to:
  /// **'浏览...'**
  String get pathPickerBrowse;

  /// No description provided for @pathPickerClear.
  ///
  /// In zh, this message translates to:
  /// **'清空'**
  String get pathPickerClear;

  /// No description provided for @pathPickerSelectDir.
  ///
  /// In zh, this message translates to:
  /// **'选择此目录'**
  String get pathPickerSelectDir;

  /// No description provided for @pathPickerErrEmpty.
  ///
  /// In zh, this message translates to:
  /// **'路径不能为空'**
  String get pathPickerErrEmpty;

  /// No description provided for @pathPickerErrDirNotExist.
  ///
  /// In zh, this message translates to:
  /// **'指定的目录不存在或无访问权限'**
  String get pathPickerErrDirNotExist;

  /// No description provided for @pathPickerErrFileNotExist.
  ///
  /// In zh, this message translates to:
  /// **'指定的文件不存在或无访问权限'**
  String get pathPickerErrFileNotExist;

  /// No description provided for @pathPickerErrFormat.
  ///
  /// In zh, this message translates to:
  /// **'不支持的文件格式 (仅支持: {exts})'**
  String pathPickerErrFormat(String exts);

  /// No description provided for @pathPickerSupported.
  ///
  /// In zh, this message translates to:
  /// **'支持格式: {exts}'**
  String pathPickerSupported(String exts);

  /// No description provided for @errEngineClosed.
  ///
  /// In zh, this message translates to:
  /// **'引擎未运行'**
  String get errEngineClosed;

  /// No description provided for @errEngineBusy.
  ///
  /// In zh, this message translates to:
  /// **'引擎忙，请稍后重试'**
  String get errEngineBusy;

  /// No description provided for @errInvalidLength.
  ///
  /// In zh, this message translates to:
  /// **'长度无效'**
  String get errInvalidLength;

  /// No description provided for @errInvalidEncoding.
  ///
  /// In zh, this message translates to:
  /// **'编码无效'**
  String get errInvalidEncoding;

  /// No description provided for @errInvalidPath.
  ///
  /// In zh, this message translates to:
  /// **'路径无效'**
  String get errInvalidPath;

  /// No description provided for @errBufferTooSmall.
  ///
  /// In zh, this message translates to:
  /// **'缓冲区空间不足'**
  String get errBufferTooSmall;

  /// No description provided for @errFileTooSmall.
  ///
  /// In zh, this message translates to:
  /// **'文件过小'**
  String get errFileTooSmall;

  /// No description provided for @errFileTooLarge.
  ///
  /// In zh, this message translates to:
  /// **'文件大小超出限制'**
  String get errFileTooLarge;

  /// No description provided for @errOutOfRange.
  ///
  /// In zh, this message translates to:
  /// **'数值超出允许范围'**
  String get errOutOfRange;

  /// No description provided for @errOutOfMemory.
  ///
  /// In zh, this message translates to:
  /// **'内存不足'**
  String get errOutOfMemory;

  /// No description provided for @errParseFailed.
  ///
  /// In zh, this message translates to:
  /// **'内容解析失败'**
  String get errParseFailed;

  /// No description provided for @errIoFailed.
  ///
  /// In zh, this message translates to:
  /// **'文件读写失败'**
  String get errIoFailed;

  /// No description provided for @errRejected.
  ///
  /// In zh, this message translates to:
  /// **'该值被引擎拒绝'**
  String get errRejected;

  /// No description provided for @errUnsupported.
  ///
  /// In zh, this message translates to:
  /// **'不支持的操作'**
  String get errUnsupported;

  /// No description provided for @errReadOnly.
  ///
  /// In zh, this message translates to:
  /// **'该参数为只读'**
  String get errReadOnly;

  /// No description provided for @errInternal.
  ///
  /// In zh, this message translates to:
  /// **'引擎内部错误'**
  String get errInternal;

  /// No description provided for @lpFindReplace.
  ///
  /// In zh, this message translates to:
  /// **'查找与替换'**
  String get lpFindReplace;

  /// No description provided for @lpSidebarLeft.
  ///
  /// In zh, this message translates to:
  /// **'切换左侧面板 (大纲与脚本库)'**
  String get lpSidebarLeft;

  /// No description provided for @lpSidebarRight.
  ///
  /// In zh, this message translates to:
  /// **'切换右侧面板 (滑块与控制台)'**
  String get lpSidebarRight;

  /// No description provided for @lpConsole.
  ///
  /// In zh, this message translates to:
  /// **'控制台'**
  String get lpConsole;

  /// No description provided for @lpNewScriptWizard.
  ///
  /// In zh, this message translates to:
  /// **'新建脚本向导'**
  String get lpNewScriptWizard;

  /// No description provided for @lpApoImportTitle.
  ///
  /// In zh, this message translates to:
  /// **'导入 APO 预设'**
  String get lpApoImportTitle;

  /// No description provided for @lpConfirmDiscardTitle.
  ///
  /// In zh, this message translates to:
  /// **'放弃未保存修改？'**
  String get lpConfirmDiscardTitle;

  /// No description provided for @lpConfirmDiscardBody.
  ///
  /// In zh, this message translates to:
  /// **'当前脚本包含未保存的修改。加载新内容将覆盖现有修改。是否继续？'**
  String get lpConfirmDiscardBody;

  /// No description provided for @lpConfirmDiscardAction.
  ///
  /// In zh, this message translates to:
  /// **'放弃并覆盖'**
  String get lpConfirmDiscardAction;

  /// No description provided for @lpConsoleClear.
  ///
  /// In zh, this message translates to:
  /// **'清空控制台'**
  String get lpConsoleClear;

  /// No description provided for @lpExpandEditor.
  ///
  /// In zh, this message translates to:
  /// **'展开'**
  String get lpExpandEditor;

  /// No description provided for @lpCollapseEditor.
  ///
  /// In zh, this message translates to:
  /// **'收起'**
  String get lpCollapseEditor;

  /// No description provided for @lpUncompiled.
  ///
  /// In zh, this message translates to:
  /// **'未编译修改'**
  String get lpUncompiled;

  /// No description provided for @lpRunningOldCode.
  ///
  /// In zh, this message translates to:
  /// **'当前应用旧代码'**
  String get lpRunningOldCode;

  /// No description provided for @lpCompileSuccess.
  ///
  /// In zh, this message translates to:
  /// **'编译成功'**
  String get lpCompileSuccess;

  /// No description provided for @lpCompilingScript.
  ///
  /// In zh, this message translates to:
  /// **'正在编译脚本…'**
  String get lpCompilingScript;

  /// No description provided for @lpEyebrowDsp.
  ///
  /// In zh, this message translates to:
  /// **'可编程 DSP'**
  String get lpEyebrowDsp;

  /// No description provided for @lpTitleEditor.
  ///
  /// In zh, this message translates to:
  /// **'EEL2 编辑器'**
  String get lpTitleEditor;

  /// No description provided for @lpBtnApplied.
  ///
  /// In zh, this message translates to:
  /// **'已应用'**
  String get lpBtnApplied;

  /// No description provided for @lpBtnUnapplied.
  ///
  /// In zh, this message translates to:
  /// **'未应用'**
  String get lpBtnUnapplied;

  /// No description provided for @lpBtnCompile.
  ///
  /// In zh, this message translates to:
  /// **'编译'**
  String get lpBtnCompile;

  /// No description provided for @lpTooltipCompileFirst.
  ///
  /// In zh, this message translates to:
  /// **'代码已修改，需先编译后方可应用'**
  String get lpTooltipCompileFirst;

  /// No description provided for @lpMenuFile.
  ///
  /// In zh, this message translates to:
  /// **'文件'**
  String get lpMenuFile;

  /// No description provided for @lpFileNewBlank.
  ///
  /// In zh, this message translates to:
  /// **'新建空白脚本'**
  String get lpFileNewBlank;

  /// No description provided for @lpFileNewFromTemplate.
  ///
  /// In zh, this message translates to:
  /// **'从模板新建...'**
  String get lpFileNewFromTemplate;

  /// No description provided for @lpFileImportApo.
  ///
  /// In zh, this message translates to:
  /// **'导入 APO 预设...'**
  String get lpFileImportApo;

  /// No description provided for @lpFileImportEel.
  ///
  /// In zh, this message translates to:
  /// **'导入 EEL 脚本...'**
  String get lpFileImportEel;

  /// No description provided for @lpFileSaveAs.
  ///
  /// In zh, this message translates to:
  /// **'另存为...'**
  String get lpFileSaveAs;

  /// No description provided for @lpFileSaveAsPrompt.
  ///
  /// In zh, this message translates to:
  /// **'请输入保存路径与文件名：'**
  String get lpFileSaveAsPrompt;

  /// No description provided for @lpFileOverwriteConfirmTitle.
  ///
  /// In zh, this message translates to:
  /// **'文件已存在'**
  String get lpFileOverwriteConfirmTitle;

  /// No description provided for @lpFileOverwriteConfirmBody.
  ///
  /// In zh, this message translates to:
  /// **'目标文件「{name}」已存在，是否确认覆盖？'**
  String lpFileOverwriteConfirmBody(String name);

  /// No description provided for @lpFileOverwriteConfirmAction.
  ///
  /// In zh, this message translates to:
  /// **'覆盖'**
  String get lpFileOverwriteConfirmAction;

  /// No description provided for @lpMenuEdit.
  ///
  /// In zh, this message translates to:
  /// **'编辑'**
  String get lpMenuEdit;

  /// No description provided for @lpEditFindReplace.
  ///
  /// In zh, this message translates to:
  /// **'查找与替换'**
  String get lpEditFindReplace;

  /// No description provided for @lpEditToggleOutline.
  ///
  /// In zh, this message translates to:
  /// **'代码大纲'**
  String get lpEditToggleOutline;

  /// No description provided for @lpEditFormat.
  ///
  /// In zh, this message translates to:
  /// **'格式化代码'**
  String get lpEditFormat;

  /// No description provided for @lpEditScrollToTop.
  ///
  /// In zh, this message translates to:
  /// **'跳回开头'**
  String get lpEditScrollToTop;

  /// No description provided for @lpBtnLibrary.
  ///
  /// In zh, this message translates to:
  /// **'脚本库'**
  String get lpBtnLibrary;

  /// No description provided for @lpLibDialogTitle.
  ///
  /// In zh, this message translates to:
  /// **'EEL2 脚本库与外部目录管理'**
  String get lpLibDialogTitle;

  /// No description provided for @lpLibOpenInExplorer.
  ///
  /// In zh, this message translates to:
  /// **'在文件管理器中浏览'**
  String get lpLibOpenInExplorer;

  /// No description provided for @lpLibDirInvalid.
  ///
  /// In zh, this message translates to:
  /// **'目录不存在或已失效'**
  String get lpLibDirInvalid;

  /// No description provided for @lpLibSaveCurrent.
  ///
  /// In zh, this message translates to:
  /// **'保存当前脚本到库'**
  String get lpLibSaveCurrent;

  /// No description provided for @lpLibCustomDirs.
  ///
  /// In zh, this message translates to:
  /// **'脚本目录'**
  String get lpLibCustomDirs;

  /// No description provided for @lpSlidersPanelTitle.
  ///
  /// In zh, this message translates to:
  /// **'参数调节滑块'**
  String get lpSlidersPanelTitle;

  /// No description provided for @lpSlidersCollapse.
  ///
  /// In zh, this message translates to:
  /// **'收起面板'**
  String get lpSlidersCollapse;

  /// No description provided for @lpSlidersExpand.
  ///
  /// In zh, this message translates to:
  /// **'展开面板'**
  String get lpSlidersExpand;

  /// No description provided for @lpTabScriptSliders.
  ///
  /// In zh, this message translates to:
  /// **'脚本参数'**
  String get lpTabScriptSliders;

  /// No description provided for @lpTabInputChannels.
  ///
  /// In zh, this message translates to:
  /// **'输入通道 (8)'**
  String get lpTabInputChannels;

  /// No description provided for @lpTabOutputChannels.
  ///
  /// In zh, this message translates to:
  /// **'输出通道 (8)'**
  String get lpTabOutputChannels;

  /// No description provided for @lpCustomVarTag.
  ///
  /// In zh, this message translates to:
  /// **'脚本变量'**
  String get lpCustomVarTag;

  /// No description provided for @lpCustomVarHint.
  ///
  /// In zh, this message translates to:
  /// **'脚本内部变量（在 @init 赋初值；若需在宿主中实时调节，可映射至 slider1..8）'**
  String get lpCustomVarHint;

  /// No description provided for @lpInputTrimHint.
  ///
  /// In zh, this message translates to:
  /// **'8 声道统一架构输入前级平衡与主增益'**
  String get lpInputTrimHint;

  /// No description provided for @lpOutputGainHint.
  ///
  /// In zh, this message translates to:
  /// **'8 声道后级独立输出增益补偿 (-15dB ~ +15dB)'**
  String get lpOutputGainHint;

  /// No description provided for @lpResetAll.
  ///
  /// In zh, this message translates to:
  /// **'全部复位'**
  String get lpResetAll;

  /// No description provided for @lpInputMasterGain.
  ///
  /// In zh, this message translates to:
  /// **'全局输入增益'**
  String get lpInputMasterGain;

  /// No description provided for @lpOutputMasterGain.
  ///
  /// In zh, this message translates to:
  /// **'全局输出增益'**
  String get lpOutputMasterGain;

  /// No description provided for @lpNoScriptSliders.
  ///
  /// In zh, this message translates to:
  /// **'脚本未声明可调变量'**
  String get lpNoScriptSliders;

  /// No description provided for @lpTooltipUnapplyToCompile.
  ///
  /// In zh, this message translates to:
  /// **'应用状态下禁止编译，请先取消应用'**
  String get lpTooltipUnapplyToCompile;

  /// No description provided for @lpLibSystemInitial.
  ///
  /// In zh, this message translates to:
  /// **'<系统初始>'**
  String get lpLibSystemInitial;

  /// No description provided for @lpLibDirs.
  ///
  /// In zh, this message translates to:
  /// **'脚本目录'**
  String get lpLibDirs;

  /// No description provided for @lpLibScriptList.
  ///
  /// In zh, this message translates to:
  /// **'脚本列表'**
  String get lpLibScriptList;

  /// No description provided for @lpApoParseError.
  ///
  /// In zh, this message translates to:
  /// **'第 {line} 行语法异常: {error}'**
  String lpApoParseError(int line, String error);

  /// No description provided for @lpApoNoFiltersPreampOnly.
  ///
  /// In zh, this message translates to:
  /// **'纯前级增益模式 (无滤波器)'**
  String get lpApoNoFiltersPreampOnly;

  /// No description provided for @plugScanDirsSelectAll.
  ///
  /// In zh, this message translates to:
  /// **'全选'**
  String get plugScanDirsSelectAll;

  /// No description provided for @plugScanDirsClear.
  ///
  /// In zh, this message translates to:
  /// **'清除全部勾选'**
  String get plugScanDirsClear;

  /// No description provided for @plugScanDirsEnabledCount.
  ///
  /// In zh, this message translates to:
  /// **'已启用 {enabled}/{total}'**
  String plugScanDirsEnabledCount(int enabled, int total);

  /// No description provided for @plugScanDirsBuiltin.
  ///
  /// In zh, this message translates to:
  /// **'内置'**
  String get plugScanDirsBuiltin;

  /// No description provided for @plugScanDirsBuiltinHint.
  ///
  /// In zh, this message translates to:
  /// **'应用自带插件目录，自动创建且不可移除'**
  String get plugScanDirsBuiltinHint;

  /// No description provided for @plugScanDirsRemove.
  ///
  /// In zh, this message translates to:
  /// **'移除该条'**
  String get plugScanDirsRemove;

  /// No description provided for @plugFormatSoon.
  ///
  /// In zh, this message translates to:
  /// **'该格式的扫描与挂载将在后续版本支持'**
  String get plugFormatSoon;

  /// No description provided for @liveprogFontReset.
  ///
  /// In zh, this message translates to:
  /// **'点击恢复默认'**
  String get liveprogFontReset;

  /// No description provided for @presetDeleteTitle.
  ///
  /// In zh, this message translates to:
  /// **'删除预设'**
  String get presetDeleteTitle;

  /// No description provided for @presetDeleteBody.
  ///
  /// In zh, this message translates to:
  /// **'确定删除该预设吗？不可撤销。'**
  String get presetDeleteBody;

  /// No description provided for @presetDeleteAction.
  ///
  /// In zh, this message translates to:
  /// **'删除'**
  String get presetDeleteAction;

  /// No description provided for @presetOverwritten.
  ///
  /// In zh, this message translates to:
  /// **'已覆盖同名预设「{name}」'**
  String presetOverwritten(String name);
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
