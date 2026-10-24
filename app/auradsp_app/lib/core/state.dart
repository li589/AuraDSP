/*
 * state.dart — AppModel：主 isolate 侧的应用状态
 *
 * 职责：持有音频 isolate（唯一 auradsp_handle 所有者），把消息协议翻译为
 * 可观察状态；viz 高频数据走独立 ValueNotifier（30fps），避免整页重建。
 */
import 'dart:async';
import 'dart:convert' show jsonDecode, utf8;
import 'dart:io';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, Locale;

import '../engine/audio_isolate.dart';
import 'nav.dart';
import '../engine/auradsp_ffi.dart'
    show
        ParamId,
        kEngineStageCount,
        AuraDspLib,
        VizBands,
        kVizChannelMax,
        kVizStageTelemetry;
import '../engine/debug_log.dart';
import '../engine/head_tracker.dart';
import 'config.dart';
import 'audio_modes.dart';
import 'eel_slider_parser.dart';
import 'plugin_manager.dart';
import 'param_schema.dart';
import 'presets.dart';
import 'session_memory.dart';
import 'theme.dart';
import 'tray_service.dart';

part 'state/state_models.dart';
part 'state/state_core.dart';
part 'state/state_events.dart';
part 'state/state_session.dart';
part 'state/state_chain.dart';
part 'state/state_effects.dart';
part 'state/state_eq.dart';
part 'state/state_audio_modes.dart';
part 'state/state_vb_asio.dart';

// ---- 文件地图（2026-10-22 P0-P6 拆分）----------------------------------
//
// 入口（本文件）= 实例字段 + 构造/dispose + 留类 static + 少量核心方法。
// 按域拆分的 part 文件统一用 `extension Xxx on AppModel`（同库作用域，
// 实例调用 / tear-off / 跨 part 互调均解析不变）：
//
//   state_models.dart       6 个数据类 + ParamDefaults（纯顶层声明）
//   state_core.dart         引擎命令原语 / 强类型参数访问 / 乐观镜像 /
//                           isolate 生命周期 / 测试钩子
//   state_events.dart       isolate 事件路由（_onMessage 全量 case）/
//                           同因事件去重 / 组件延迟探测
//   state_session.dart      会话回放 / 预设脏跟踪 / 防抖自动保存 /
//                           主题本地化 / 自定义目录 / 采样率
//   state_chain.dart        处理链 stage/组/顺序 / 立体声链 / Liveprog /
//                           卷积/VDC/DDC / 低音斜坡
//   state_effects.dart      ~150 个同构效果 setter（comp/ddc/bass/
//                           spatial/reverb/gate/dyneq/loudness/...）
//   state_eq.dart           EQ 网格/曲线/预设 + 引擎响应探测 +
//                           EQ 静态助手（顶层函数/常量）
//   state_audio_modes.dart  音频模式/管线/设备枚举/VAIO 驱动/ASIO 注册/
//                           System APO 运维
//   state_vb_asio.dart      Voicemeeter 桥总线/插件组 + ASIO 驱动 +
//                           VAIO 输出端点
//
// 两条 extension 铁律（踩坑沉淀，改动前必读）：
//   1. notifyListeners() 是 ChangeNotifier @protected——extension 非子类
//      不可直呼，迁出方法统一改调类体内转发 _notifyUi()。
//   2. extension 作用域不含被扩展类型的 static 成员——纯函数/常量助手
//      放 part 文件顶层；对外 static（外部 AppModel.xxx 调用）留类体，
//      extension 内引用加 AppModel. 限定。

class AppModel extends ChangeNotifier {
  final HeadTracker _headTracker = HeadTracker();

  /// 声场展宽的引擎侧安全上限。
  /// libjamesdsp 的展宽在 mix=1.0 时执行 `band - centre`（中置完全剥离），
  /// 单声道内容会直接归零（表现为"拉满几乎没声音"）。UI 0..100% 线性映射到
  /// 引擎 0..0.75，既保留可感知的展宽，又不会把人声剥空。
  /// 声场展宽的引擎满量程（UI 0..1 → 引擎 0..本值）。
  ///
  /// 此前这里是 `static const = 0.75`，config 里的同名字段被持久化、被单测断言，
  /// 却从未参与换算——改 config.json 对听感零影响。现在直接读 config。
  /// 引擎侧上限仍是 1.0（vendor mix=1.0 会走 band-centre 中置全剥离导致静音），
  /// 故这里夹到 1.0 以内。
  double get stereoWidenMax => config.stereoWidenMax.clamp(0.0, 1.0);

  SendPort? _toIso;
  Isolate? _iso;

  // 引擎连接与状态
  EngineConn conn = EngineConn.connecting;
  String? fatalMsg;
  EngineInfo? info;

  /// 设备实际采样率（插件延迟、IR 时长等「样本 → 毫秒」换算的唯一依据）。
  /// 引擎创建后固定不变；info 尚未就绪时回退 48k。
  int get deviceRate => info?.deviceRate ?? 48000;

  /// EQ 建模必须使用的采样率：协商后的实际引擎采样率。
  ///
  /// `config.sampleRate` 只是发给设备的请求值，设备可能拒绝并回退到原生采样率。
  /// 频率网格、曲线钳位和响应探针都必须用实际值，否则三者在不同的采样率假设下
  /// 各自为政。info 尚未就绪时暂时用配置值，`ready` 事件到达后会按实际值重建。
  int get engineRate {
    final negotiated = info?.deviceRate ?? 0;
    if (negotiated > 0) return negotiated;
    return config.sampleRate > 0 ? config.sampleRate : 48000;
  }

  int engineState = 0; // 0=bypass 1=processing 2=error
  double latencyMs = 0;
  bool playing = false;
  // 频谱门：进程内 playing 或 VB/ASIO/VAIO 桥活着都算 live。
  bool get liveSpectrum => playing || vbActive || asioActive || vaioActive;
  // 四态显示口径（右上徽标/主页 hero 共用）：engineState==0 混了"用户旁路"与
  // "无源空闲"，以前一刀切标"旁路"，导致开关 OFF 却处处显示旁路。拆开：
  // 开关开→旁路；开关没开但引擎报 0→空闲；引擎 1→看有没有活数据。
  EngineDisplay get engineDisplay {
    if (engineState == 2) return EngineDisplay.error;
    if (bypass) return EngineDisplay.bypass;
    if (engineState == 0) return EngineDisplay.idle;
    return liveSpectrum ? EngineDisplay.processing : EngineDisplay.idle;
  }

  bool bypass = false;
  String sourceKind = ''; // '' | 'tone' | 'pink' | 'file'
  String sourcePath = ''; // 文件源路径（isolate 重启后重推音源用；tone/pink 为空）
  // WASAPI 输出缺失（默认端点被独占/幽灵）：isolate 降级就绪的报错原文；
  // 非空即降级态（引擎照跑，VB/ASIO 不受影响），进程内试音等重试恢复。
  String wasapiError = '';
  String sourceExt = ''; // 文件源扩展名（小写无点，如 'mp3'/'wav'；非文件源为空）

  // P3: 全链路数据驱动参数体系：强类型 Spec 动态存储与访问器
  final Map<String, dynamic> _paramValues = {};

  // 参数镜像（engine 侧真相，UI 只做回显与乐观更新）
  bool bassOn = false, eqOn = false, limiterOn = true;
  double limiterReleaseMs = ParamDefaults.limiterRelease;
  double limiterThreshold = ParamDefaults.limiterThreshold;
  bool limiterLink = ParamDefaults.limiterLink;
  bool limiterLookahead = ParamDefaults.limiterLookahead;
  double bassGain = ParamDefaults.bassGain,
      stereoMix = ParamDefaults.stereoMix,
      postGain = ParamDefaults.postGain,
      inputGain = ParamDefaults.inputGain,
      inputBalanceL = ParamDefaults.inputBalanceL,
      inputBalanceR = ParamDefaults.inputBalanceR;
  int reverbPreset = -1;
  int channelsMode = 0;
  // 音频处理模式 id（AudioModes.optionsFor(currentOs) 取值；'auto' 表跟随当前引擎）。
  // 引擎接线待后续版本，当前仅持久化 + UI 展示。
  String audioMode = 'auto';
  // VB-Callback 桥状态（isolate 回推；inactive 时为空）。
  bool vbActive = false;
  Map<String, dynamic> vbInfo = {};
  /// 当前可见页（shell 维护；P0-1 IndexedStack 保活后，页面定时器与高频
  /// 可视化消费点据此门控）。R2（2026-10-23）：改为 ValueNotifier——离屏页
  /// 30fps 高频消费点（频谱/电平/各级电平表）订阅它，仅在对应页可见时
  /// 才订阅数据通知器（IndexedStack 保活 = 离屏页仍在树上，SDK 实证全子
  /// 节点仍参与 layout，纯 VLB 消费点会随数据 30fps 重建）。
  final visiblePage = ValueNotifier<AppPage>(AppPage.home);
  // VB 总线掩码（bit g=第 g 条总线进 DSP；落盘，进桥时下发；CHANGE 重建不丢）。
  int vbBusMask = 0xFF;
  // 按路插件处理掩码（bit g=组 g 总线吃插件链；落盘，进桥时下发）。
  int vbPluginGroupMask = 0xFF;
  // v2 按路编辑器目标总线（会话级，不落盘）。
  // 取值：kVbRouteUnselected(-2)=未选择（初值；v3.3 已撤除「全部」，
  // 本值不承载任何合法路语义）；0-7=具体路；-1=无有效选中路。
  // 插件页「打开界面」按钮跟随此值路由；选中路失效时由
  // _fallbackVbPluginEditorGroup() 回落到最低有效路。
  int vbPluginEditorGroup = kVbRouteUnselected;

  /// 插件页下拉的有效路掩码 = 通道开着 且 插件勾选
  /// （busMask 关的组整组直通不进引擎，调参不上流；复选框关的组链级停跑）。
  int get vbEffectiveRouteMask => vbBusMask & vbPluginGroupMask & 0xFF;
  // ASIO 常驻桥状态（04 桥；isolate 回推，与 VB 桥互斥——一次只跑一个后端）。
  bool asioActive = false;
  Map<String, dynamic> asioInfo = {};
  // asio_detect 驱动清单（isolate 回推；[{name,dll,clsid}]，name 为 UTF-8 显示名）。
  List<Map<String, String>> asioDrivers = [];
  String asioDriversNote = ''; // 桥缺失/无驱动时的原因（设置页展示）
  // AuraVAIO 桥状态（01 桥；isolate 回推，与 VB/ASIO 互斥）。
  bool vaioActive = false;
  Map<String, dynamic> vaioInfo = {};
  Map<String, dynamic> vaioDetectInfo = {};

  // ADR-009 范式与细分项快捷 getter
  String get modeCategory => config.modeCategory;
  String get attachmentMode => config.attachmentMode;
  String get pipelineInput => config.pipelineInput;
  String get pipelineOutput => config.pipelineOutput;
  String get pipelineInputDevice => config.pipelineInputDevice;
  String get pipelineOutputDevice => config.pipelineOutputDevice;
  String get apoTargetEndpoint => config.apoTargetEndpoint;
  bool get monitorMirroring => config.monitorMirroring;
  bool get pipelineInputEnabled => config.pipelineInputEnabled;
  bool get pipelineOutputEnabled => config.pipelineOutputEnabled;
  List<AudioDeviceItem> wasapiDevices = [];

  List<AudioDeviceItem> get filteredWasapiInputs {
    final list = <AudioDeviceItem>[];
    for (final d in wasapiDevices) {
      final n = d.name.toLowerCase();
      if (n.contains('auravaio') ||
          n.contains('auradsp virtual asio') ||
          n.contains('auradsp asio')) {
        continue;
      }
      list.add(d);
    }
    if (list.isEmpty) {
      list.addAll([
        const AudioDeviceItem(
          id: 'def_render',
          name: '系统扬声器 / 扬声器 (Realtek High Definition Audio)',
          isRender: true,
        ),
        const AudioDeviceItem(
          id: 'def_mic',
          name: '麦克风阵列 (适用于数字麦克风的英特尔® 智音技术)',
          isRender: false,
        ),
        const AudioDeviceItem(
          id: 'def_stereo_mix',
          name: '立体声混音 (Realtek Audio)',
          isRender: false,
        ),
      ]);
    }
    return list;
  }

  List<AudioDeviceItem> get filteredWasapiOutputs {
    final list = <AudioDeviceItem>[];
    for (final d in wasapiDevices) {
      if (!d.isRender) continue;
      final n = d.name.toLowerCase();
      if (n.contains('auravaio') ||
          n.contains('auradsp virtual asio') ||
          n.contains('auradsp asio')) {
        continue;
      }
      list.add(d);
    }
    if (list.isEmpty) {
      final eps = (vaioDetectInfo['endpoints'] as List?) ?? [];
      for (final ep in eps) {
        String name = '';
        String id = '';
        if (ep is Map) {
          name = (ep['name'] as String?) ?? '';
          id = (ep['id'] as String?) ?? name;
        } else if (ep is String) {
          if (ep.startsWith('{') && ep.contains('name:')) {
            final m = RegExp(r'name:\s*(.*?)(?:,\s*id:|\s*})').firstMatch(ep);
            name = m != null ? m.group(1)!.trim() : ep;
            id = name;
          } else {
            name = ep;
            id = ep;
          }
        }
        if (name.isEmpty) continue;
        final n = name.toLowerCase();
        if (!n.contains('auravaio') &&
            !n.contains('auradsp virtual asio') &&
            !n.contains('auradsp asio')) {
          list.add(AudioDeviceItem(id: id, name: name, isRender: true));
        }
      }
      if (list.isEmpty) {
        list.addAll([
          const AudioDeviceItem(
            id: 'def_render_realtek',
            name: '扬声器 (Realtek High Definition Audio)',
            isRender: true,
          ),
          const AudioDeviceItem(
            id: 'def_render_usb',
            name: '耳机 (USB Audio Device)',
            isRender: true,
          ),
        ]);
      }
    }
    return list;
  }

  /// 解析后的 VAIO 物理输出端点列表（过滤掉虚拟驱动自身，供 UI 选择真实物理扬声器/耳机）
  List<AudioDeviceItem> get vaioPhysicalEndpoints {
    final list = <AudioDeviceItem>[];
    final eps = (vaioDetectInfo['endpoints'] as List?) ?? [];
    for (final ep in eps) {
      String name = '';
      String id = '';
      if (ep is Map) {
        name = (ep['name'] as String?) ?? '';
        id = (ep['id'] as String?) ?? name;
      } else if (ep is String) {
        if (ep.startsWith('{') && ep.contains('name:')) {
          final m = RegExp(r'name:\s*(.*?)(?:,\s*id:|\s*})').firstMatch(ep);
          name = m != null ? m.group(1)!.trim() : ep;
          id = name;
        } else {
          name = ep;
          id = ep;
        }
      }
      if (name.isEmpty) continue;
      final lower = name.toLowerCase();
      if (lower.contains('auravaio') ||
          lower.contains('auradsp virtual asio') ||
          lower.contains('auradsp asio')) {
        continue;
      }
      list.add(AudioDeviceItem(id: id, name: name, isRender: true));
    }
    // 若 VAIO 探测结果暂未就绪，使用 filteredWasapiOutputs 兜底
    if (list.isEmpty) {
      for (final d in filteredWasapiOutputs) {
        list.add(d);
      }
    }
    return list;
  }

  /// 获取有效输入设备（在就按记忆，不在/离线走默认 ''）
  String get effectivePipelineInputDevice {
    final dev = config.pipelineInputDevice;
    if (dev.isEmpty) return '';
    final exists = filteredWasapiInputs.any(
      (d) => d.id == dev || d.name == dev,
    );
    return exists ? dev : '';
  }

  /// 获取有效输出设备（在就按记忆，不在/离线走默认 ''）
  String get effectivePipelineOutputDevice {
    final dev = config.pipelineOutputDevice;
    if (dev.isEmpty) return '';
    final exists = filteredWasapiOutputs.any(
      (d) => d.id == dev || d.name == dev,
    );
    return exists ? dev : '';
  }

  /// 获取有效 VAIO 物理输出端点（在就按记忆，不在/离线走默认 ''）
  String get effectiveVaioOutputEndpoint {
    final ep = config.vaioOutputEndpoint;
    if (ep.isEmpty) return '';
    final exists = vaioPhysicalEndpoints.any((d) => d.name == ep || d.id == ep);
    return exists ? ep : '';
  }

  // ASIO 驱动注册状态 (AuraDSP Virtual ASIO Driver)
  bool asioDriverInstalled = false;
  // System APO 挂载状态与运行时遥测
  bool apoAttached = false;
  bool apoHeartbeatAlive = false;
  int apoHeartbeatSeq = 0;
  int apoHeartbeatSr = 0;
  int apoHeartbeatFrames = 0;
  List<Map<String, dynamic>> apoInstalledEndpoints = [];
  bool isApoOperating = false;
  bool apoCompositeMode = false;

  // 底层驱动与音频服务异常信息跟踪（用于 UI 内联报警与用户引导）
  String? lastAudioError;
  String? lastVaioError;
  String? lastAsioError;
  String? lastApoError;

  // Liveprog（v1.1）：status 0=无代码 1=编译成功 <0=引擎错误码
  bool lpEnabled = false;
  int lpStatus = 0;
  String? lpError; // 最近一次编译错误文案（事件条已显示，这里供编辑页内联标红）
  final List<double> lpParams = List.filled(8, 0);
  // v3：上次 liveprog.code 下发的引擎侧编译耗时（ms），-1 = 未知。
  // isolate 早已实测 tookMs（此前只记日志），现回传供胶囊展示与慢编译提醒。
  int lpCompileMs = -1;
  // v2：预设存档时的代码指纹与当前编辑器代码不一致（全文不在预设里，
  // 恢复的滑块可能对不上号；UI 预留徽标位，当前仅置位不展示）。
  bool lpPresetCodeMismatch = false;
  // v2：上次应用代码的滑块声明签名。签名不变的重应用（改注释/调格式）
  // 保留用户已调的滑块值；声明变化才采纳新默认值。
  String _lpDeclSig = '';

  // 卷积 / IR（v1.1 M4）：meta 由引擎门卫校验后回读
  bool convEnabled = false, convReady = false;
  int convFrames = 0, convChannels = 0, convSrcRate = 0;
  double convPeak = 0.0;
  List<List<double>> convSpectrum = [];

  /// IR 是否经过重采样：比较文件原始采样率与协商后的实际设备采样率。
  ///
  /// 不能用硬编码采样率，因为请求采样率可能被设备拒绝，
  /// 引擎实际一律按协商后的采样率工作。
  static bool irWasResampled({required int srcRate, required int deviceRate}) =>
      srcRate != 0 && srcRate != deviceRate;

  // M3-a：轻量效果
  bool tubeOn = false, xfeedOn = false;
  bool tubeOversample = ParamDefaults.tubeOversample;
  int xfeedMode = 0; // 0: Default, 1: Chu Moy, 2: Jan Meier, 3: Custom
  double xfeedFcut = 700.0; // 300..2000 Hz
  double xfeedFeed = 4.5; // 1.0..15.0 dB

  // 动态压限器（Compander）
  bool compOn = false;
  double compTimeconstant = 0.14;
  int compGranularity = 1;
  int compTfresolution = 1;
  double compThreshold = -18.0;
  double compRatio = 4.0;
  final List<double> compFreqs = [
    95.0,
    200.0,
    400.0,
    800.0,
    1600.0,
    3400.0,
    7500.0,
  ];
  final List<double> compGains = [
    -0.35,
    -0.35,
    -0.35,
    -0.35,
    -0.35,
    -0.35,
    -0.35,
  ];

  // M5/P-002：声场分带（0..1 每带；bandUsed=false 时随总滑块统一）
  final List<double> stereoBands = List.filled(5, 0.5);
  bool stereoBandUsed = false;
  // 声场开关（v1.2）：独立于滑块值的生效位。
  // 旧语义 stereoOn = mix>0 导致“滑块拉到 0 即关开关→滑块被禁用→卡死”，
  // 现开关只管是否生效，关闭时引擎侧收 0、UI 滑块值保留。
  bool stereoOn = false;

  // 脉冲响应干湿比 + VDC
  double convMix = 1.0;
  bool ddcOn = false, ddcReady = false;

  // M5-b：低音塑形（Bass Shaping：合并低频搁架与单声道化）
  bool shelfOn = false;
  double shelfFreq = 100, shelfGain = 0;
  // 低频单声道化（BassMono，链头）
  bool bassmonoOn = false;
  double bassmonoFreq = 120;
  bool get bassShapingOn => shelfOn || bassmonoOn;
  // Haas 差分环绕（stereo 后 / reverb 前）
  bool haasOn = false;
  double haasDelayMs = 12, haasMix = 1.0;
  int haasSide = 0; // 0=延迟右 1=延迟左
  // 空间音效 L1（haas 后 / exciter 前；默认关闭，用户显式开启）
  bool spatialOn = false;
  int spatialStyle = 0;
  double spatialRoom = 0.7, spatialWidth = 1.0, spatialCenter = 0.8;
  double spatialOutGain = 0.0;
  bool spatialAutoGain = false;
  double spatialMix = 1.0;
  double spatialElevation = 0.0;
  bool spatialBinaural = false;
  bool spatialFdn = false;
  double spatialLate = 0.25;
  // 头跟预留（Phase 2 stub：透传 + 持久化，无 UI；传感器就绪后 DSP 按
  // azimuth 旋转摆位，详见 engine_internal.h spatial_headazim 注释）。
  double spatialHeadAzim = 0.0;
  bool spatialHeadTrack = false;
  // 5.1 源模式（Phase 2）：0=混缩（默认） 1=直通；fileChannels>2 时设置页露芯片。
  int source51Mode = 0;
  // 当前文件源声道数（isolate playing 事件回填；直通/UI 门控据此判定）。
  int fileChannels = 2;
  // 效果页分类过滤（会话内有效，不持久化；默认第一类「前置整形」，无"全部"）。
  String effectsCategory = 'front';
  // 激励器（Haas 后 / reverb 前，最后一道音色工序）
  bool exciterOn = false;
  double exciterAmount = 0.3, exciterHifreq = 5000;
  bool exciterOversample = ParamDefaults.exciterOversample;

  // M5-c：空间混响（Freeverb / Spatial Reverb）
  bool fvOn = false;
  double fvDecay = 0.5, fvDamp = 0.5, fvWet = 0.35, fvDry = 1.0;
  double fvRoomSize = 1.2, fvWidth = 1.0;
  bool get isSpatialReverbOn => reverbPreset >= 0 || fvOn;

  // M3.5-a：处理顺序（Dart 镜像；引擎侧表驱动 P-004）
  String? graphOrder;

  // 自动增益补偿与输出增益门
  bool bassAutoGain = ParamDefaults.bassAutoGain;
  double bassOutputGain = ParamDefaults.bassOutputGain;
  bool eqAutoGain = ParamDefaults.eqAutoGain;
  double eqOutputGain = ParamDefaults.eqOutputGain;
  bool reverbAutoGain = ParamDefaults.reverbAutoGain;
  double reverbOutputGain = ParamDefaults.reverbOutputGain;
  bool tubeAutoGain = ParamDefaults.tubeAutoGain;
  double tubeOutputGain = ParamDefaults.tubeOutputGain;
  bool compAutoGain = ParamDefaults.compAutoGain;
  double compOutputGain = ParamDefaults.compOutputGain;

  // 噪声门（链头）+ Deesser + 自动增益补偿 + 迟滞/底线/保持
  bool gateOn = false;
  double gateThreshold = -40, gateAttackMs = 10, gateReleaseMs = 100;
  double gateHysteresis = ParamDefaults.gateHysteresis;
  double gateRange = ParamDefaults.gateRange;
  double gateHoldMs = ParamDefaults.gateHoldMs;
  bool gateAutoGain = false;
  bool deesserOn = false;
  double deesserFreq = 6000, deesserAmount = 0.5;

  // 全参数动态EQ（3 段；默认全关）
  bool dyneqOn = false;
  double dyneqAttackMs = ParamDefaults.dyneqAttack;
  double dyneqReleaseMs = ParamDefaults.dyneqRelease;
  double dyneqB1Attack = ParamDefaults.dyneqB1Attack;
  double dyneqB1Release = ParamDefaults.dyneqB1Release;
  double dyneqB2Attack = ParamDefaults.dyneqB2Attack;
  double dyneqB2Release = ParamDefaults.dyneqB2Release;
  double dyneqB3Attack = ParamDefaults.dyneqB3Attack;
  double dyneqB3Release = ParamDefaults.dyneqB3Release;
  bool dyneqLowOn = false, dyneqMidOn = false, dyneqHighOn = false;
  double dyneqLowFreq = ParamDefaults.dyneqLowFreq;
  double dyneqLowQ = ParamDefaults.dyneqLowQ;
  double dyneqLowGain = ParamDefaults.dyneqLowGain;
  double dyneqLowRange = ParamDefaults.dyneqLowRange;
  double dyneqLowThreshold = ParamDefaults.dyneqLowThreshold;
  double dyneqMidFreq = ParamDefaults.dyneqMidFreq;
  double dyneqMidQ = ParamDefaults.dyneqMidQ;
  double dyneqMidGain = ParamDefaults.dyneqMidGain;
  double dyneqMidRange = ParamDefaults.dyneqMidRange;
  double dyneqMidThreshold = ParamDefaults.dyneqMidThreshold;
  double dyneqHighFreq = ParamDefaults.dyneqHighFreq;
  double dyneqHighQ = ParamDefaults.dyneqHighQ;
  double dyneqHighGain = ParamDefaults.dyneqHighGain;
  double dyneqHighRange = ParamDefaults.dyneqHighRange;
  double dyneqHighThreshold = ParamDefaults.dyneqHighThreshold;

  // 响度补偿（Stage 3 后 / 安全钳位前，最后一道音色工序）
  bool loudnessOn = false;
  double loudnessAmount = 0.5;
  bool arbmagOn = ParamDefaults.arbmagOn;
  String arbmagString = ParamDefaults.arbmagString;
  bool arbmagReady = false;
  int arbmagNodeCount = 0;

  /// 引擎回显的 eq.curve 下发原串（字符串回读对账用；null=引擎无副本）。
  /// 引擎存的是原串副本（不重序列化），故可与 `_pushEqCurve` 输出直接比对
  /// 检测引擎侧钳位/漂移。不回灌 eqGains/eqFreqs（避免与用户拖拽打架）。
  String? engineEqCurve;
  bool arbmagAutoGain = ParamDefaults.arbmagAutoGain;
  double arbmagOutputGain = ParamDefaults.arbmagOutputGain;

  // 低音重构（Phase 4）
  double bassIntensity = ParamDefaults.bassIntensity;
  int bassMode = ParamDefaults.bassMode;
  double bassCutoff = ParamDefaults.bassCutoff;
  double bassHarmonics = ParamDefaults.bassHarmonics;
  double bassHarmonicBlend = ParamDefaults.bassHarmonicBlend;
  double bassSubFloor = ParamDefaults.bassSubFloor;

  // 独立滤波器（gate 后 / bassmono 前）
  bool filterOn = false;
  int filterType = ParamDefaults.filterType;
  double filterFreq = ParamDefaults.filterFreq;
  double filterQ = ParamDefaults.filterQ;

  // 电子管模拟器（Phase 4）
  double tubeGain = ParamDefaults.tubeGain;
  int tubeStyle = ParamDefaults.tubeStyle;
  double tubeCompensation = ParamDefaults.tubeCompensation;
  double tubeMix = ParamDefaults.tubeMix;

  int eqBandsCount = ParamDefaults.eqBandsCount;

  /// 初值先用 48k 网格；构造函数体里 `config` 加载完后会按真实采样率重建
  /// （字段初始化器先于构造函数体执行，那时 config 还没读出来）。
  List<double> eqFrequencies = eqGridFor(ParamDefaults.eqBandsCount, 48000);
  List<double> eqGains = List.filled(15, 0.0);

  /// 每个可调频点的 Q 值（与 [eqFrequencies] 等长对齐）。
  ///
  /// vendor 的任意幅度 FIR 路径本身没有“每点 Q”的概念，这里按参数均衡器语义
  /// 处理：每个频点是一座 RBJ 峰值钟形，Q 决定钟形宽度；下发前先把全部钟形
  /// 按 dB 叠加成目标曲线（见 [eqTargetGains]），再走既有的 `eq.curve` 通道。
  /// 因此 Q 的变化一定会改变曲线签名与引擎实测响应——Q 是真参，不是摆设。
  List<double> eqQs = List.filled(15, ParamDefaults.eqQ);

  /// 旧版全局 Q（兼容旧预设/会话里的标量 `q`）：新 Q 数组的缺省填充值。
  /// 新建频带与读到无 `qs` 的旧数据时，用它补齐。
  double eqQ = ParamDefaults.eqQ;
  int eqFilter = ParamDefaults.eqFilter;
  int eqInterp = ParamDefaults.eqInterp;
  String eqPresetName = 'flat';
  bool eqBypass = false;

  /// EQ 是否真正作用于音频链：全局开关与旁路必须同时满足。
  ///
  /// 背景谱合成和响应曲线都要用这个统一条件，不能只看旁路，
  /// 否则全局关闭后仍会叠加一条已失效的旧响应。
  bool get isEqActive => eqOn && !eqBypass;

  // 组件级延迟评估刷新时间戳
  final Map<String, int> _latencyRefreshTicks = {};
  int getComponentLatencyTick(String compId) =>
      _latencyRefreshTicks[compId] ?? 0;

  // 用户偏好与外置配置
  late AppConfig config;
  String? activePresetName;

  /// 脏跟踪（2026-10-16 决策 #3）：最近一次成功应用预设时的状态指纹。
  /// null = 从未应用过预设（如全新安装），此时「偏离预设」无从谈起。
  String? appliedPresetFingerprint;

  /// 当前状态是否偏离已应用预设（任意一点偏离即 true → UI 显示
  /// 「自定义（未保存）」）。由 evaluatePresetDirty()（防抖保存回调内
  /// 统一触发）刷新，随 SessionMemory v5 持久化，重启后不丢。
  bool presetDirty = false;
  String? convIrPath;
  String? ddcPath;
  String? ddcFileName;
  String? ddcDetails;
  double _lastStereoMix = 0.5;
  String? lpCode;
  Timer? _debounceSaveTimer;
  bool _isReplayingSession = false;

  AuraThemeId themeId = AuraThemeId.auraDark;
  Locale locale = const Locale('zh');
  // 注：延迟档（ADR-002）已由 ADR-006 撤销，不再有 latencyMode。
  // 延迟改为纯测量展示（组件级徽标 + 底栏总延迟），任何效果都可自由使能。

  // 高频可视化（独立 notifier，30fps）
  /// 1s 级状态心跳（P0-2，2026-10-23）：VB/VAIO/ASIO status 每秒到达，
  /// 只推这个 notifier 喂高频读数组件（电平表/保护行/设备读数），
  /// **不再**触发粗粒度 notifyListeners——否则 IndexedStack 保活后
  /// 离屏页面会被每秒整树重建。
  final ValueNotifier<int> hbTick = ValueNotifier<int>(0);
  final spectrum = ValueNotifier<List<double>>(List.filled(32, 0));

  /// vendor 链入口（= 均衡器输入）的 32 段频谱，口径与 [spectrum] 相同。
  ///
  /// [spectrum] 取的是整条链的**最终输出**——EQ 之后的混响 / 卷积 /
  /// Freeverb / 插件全都算在内。拿它当均衡器面板的背景柱，用户看到的
  /// 频谱并不是均衡器输出的东西，调 EQ 时背景柱几乎不动。
  final eqInSpectrum = ValueNotifier<List<double>>(List.filled(32, 0));
  final levelL = ValueNotifier<double>(-90);
  final levelR = ValueNotifier<double>(-90);
  // [M3.5-c] 12 个 stage 的实时双声道微型电平 (dBFS)
  final stageLevelsL = ValueNotifier<List<double>>(
    List.filled(kEngineStageCount, -120.0),
  );
  final stageLevelsR = ValueNotifier<List<double>>(
    List.filled(kEngineStageCount, -120.0),
  );
  // 输入门控实时本级输入/输出电平 (dBFS)
  final inputMeterInL = ValueNotifier<double>(-120.0);
  final inputMeterInR = ValueNotifier<double>(-120.0);
  final inputMeterOutL = ValueNotifier<double>(-120.0);
  final inputMeterOutR = ValueNotifier<double>(-120.0);

  // [Phase B 多声道电平] per-channel 电平（ADR-003，2026-10-24）。
  // stereo 时 [0]/[1] 与 levelL/R 同源一致；MC（5.1/7.1）为全声道。
  // vizChannelCount=0（无帧/断流）时 UI 回退 L/R 两柱行为。
  final vizChannelCount = ValueNotifier<int>(0);
  /// 定长 kChannelMax；未用声道 -120。
  final vizChannelLevels = ValueNotifier<List<double>>(
    List.filled(kVizChannelMax, -120.0),
  );
  /// 扁平 [stage * kChannelMax + ch]，stage 0..kVizStageTelemetry-1 有效；
  /// 21..31（预留/GR）恒 -120。GR 单值仍读 stageLevelsL 的 L 列。
  final vizStageChLevels = ValueNotifier<List<double>>(
    List.filled(kVizStageTelemetry * kVizChannelMax, -120.0),
  );

  // 动态衰减量计量 (Gain Reduction, dB, 负值或 0.0)
  final grLimiter = ValueNotifier<double>(0.0);
  final grComp = ValueNotifier<double>(0.0);
  final grGate = ValueNotifier<double>(0.0);
  final grDyneqLow = ValueNotifier<double>(0.0);
  final grDyneqMid = ValueNotifier<double>(0.0);
  final grDyneqHigh = ValueNotifier<double>(0.0);

  // 一次性事件（shell 监听弹 snackbar）
  final eventSeq = ValueNotifier<int>(0);
  GuardRejection? lastGuard;
  String? lastEngineError;
  String? lastInfo; // 非错误提示（如"已自动切到品质档"）
  int _guardSeq = 0;

  void clearLastInfo() {
    lastInfo = null;
  }

  void clearLastGuard() {
    lastGuard = null;
  }

  void clearLastEngineError() {
    lastEngineError = null;
  }

  /* ---- 事件同因抑制（防通知条刷屏，2026-10-18 UI 排查）----
   * 引擎 guard 拒绝（paramResult rc!=0）与 isolate 错误（error 事件）在
   * 历史上零去重：预设全量 apply / session 回放 / EQ 曲线节流下发 /
   * liveprog 编译失败重试，任何一条批量路径都会把 N 个拒绝排成一串
   * 4s SnackBar 连续弹出；同一问题反复出现时更是持续不断。
   * 用户诉求：「出问题通知一两次就够了」。
   * 口径：同一 (kind|key|msg) 在 [_kEventDedupWindowMs] 内只放行第一次，
   * 后续同因静默抑制（不 bump eventSeq、不动一次性事件字段）；
   * 窗口外再次出现视为新事件，正常提示。不同成因永远立即放行。 */
  String _lastEventKey = '';
  int _lastEventAt = 0;
  int _lastEventSuppressed = 0;

  /// 测试可注入的时钟（ epoch ms ）；null = 系统时钟。
  @visibleForTesting
  int? debugNowOverride;

  /// 被抑制的同因事件累计次数（诊断/测试用；放行时不清零，
  /// 由下一次同因抑制继续累加，窗口外重新出现时自然失去参照）。
  @visibleForTesting
  int get debugEventSuppressedCount => _lastEventSuppressed;

  /// 参数下发时刻（id → epoch ms），用于测量 点击→引擎确认 回环耗时
  final Map<String, int> _pendingSentAt = {};

  /// 回读对账（2026-10-16 决策 #4）：
  /// 防抖回读已发出、'params' 事件未归时置位；_readbackRequestedAt 为发出
  /// 时刻，_lastEditAt 为最近一次用户编辑时刻。若编辑晚于发出 → 该轮回读
  /// **过期**，归来的事件不得采用（否则把用户最新一次改动回滚成旧值）。
  bool _readbackPending = false;
  int _readbackRequestedAt = 0;
  int _lastEditAt = 0;

  late final PluginManager pluginManager;
  String? savedPluginPath;
  String savedPluginId = '';
  bool savedPluginBypass = false;
  bool savedPluginPdc = false;
  final List<SavedPluginSlot> savedPluginSlots = [];

  ReceivePort? _fromIso;

  /// 测试隔离开关（Issue #2）：testing=true 时跳过音频 isolate 拉起
  /// 与 session 落盘（构造回放/防抖自动保存/dispose 保存）。
  /// 磁盘沙箱本身已有 `ConfigManager.baseDir`（FLUTTER_TEST 自动指临时目录），
  /// 这里解决的是另一半：真 isolate（拉 DLL + 开 WASAPI 设备）与竞态回读。
  /// 生产代码一律默认 false，行为零变化。
  final bool _testing;

  /// ChangeNotifier 保护成员的库内转发。
  ///
  /// 拆分后 AppModel 的方法迁入 `extension ... on AppModel`（part 文件），
  /// 而 `notifyListeners()` 是 `@protected`——扩展不是 ChangeNotifier 子类，
  /// 直呼触发 invalid_use_of_protected_member。所有迁出的方法统一改调
  /// `_notifyUi()`，与类体内 notifyListeners() 完全同义。
  bool _notifyScheduled = false;
  bool _disposed = false;

  /// 同帧多次变更合并为一次 notifyListeners（P0-2）：批量恢复/心跳边缘
  /// 场景避免 N 次整树重建。microtask 在本帧绘制前执行，交互无感知。
  /// 测试模式（AppModel(testing:true)）保持同步通知——既有断言按
  /// 「setParam 调用后立刻可数」编写，合并属生产侧优化。
  void _notifyUi() {
    if (_testing) {
      if (!_disposed) notifyListeners();
      return;
    }
    if (_notifyScheduled || _disposed) return;
    _notifyScheduled = true;
    scheduleMicrotask(() {
      _notifyScheduled = false;
      if (!_disposed) notifyListeners();
    });
  }

  // ignore: prefer_initializing_formals (testing 是公开测试 API，不可用 this._testing 私有形参)
  AppModel({bool testing = false}) : _testing = testing {
    config = ConfigManager.load();
    // 存量 audioMode 归一化到当前平台合法集（未知回平台默认并落盘）。
    audioMode = AudioModes.normalize(config.audioMode);
    if (audioMode != config.audioMode) {
      config.audioMode = audioMode;
      ConfigManager.save(config);
    }
    if (!testing) {
      checkAsioDriverStatus();
      checkApoStatus();
    }
    // VB 总线掩码：落盘值 0（=全关，无意义）回全开；其余取低 8 bit。
    final m = config.vbBusMask & 0xFF;
    vbBusMask = m == 0 ? 0xFF : m;
    // 按路插件掩码：0（全关）是用户显式选择，直接取用；键缺失时
    // fromJson 已给默认 0xFF。
    vbPluginGroupMask = config.vbPluginGroupMask & 0xFF;
    /* C4：按真实采样率重建 EQ 网格。必须放在 config 加载之后 ——
     * 字段初始化器早于构造函数体，那时 config 还是默认值。
     * 不重建的话，低采样率用户拿到的是含越界频点的出厂网格。 */
    _rebuildEqGridForSampleRate(notify: false);
    locale = Locale(config.locale);
    themeId = AuraThemeId.values.firstWhere(
      (t) => t.name == config.themeId,
      orElse: () => AuraThemeId.auraDark,
    );
    pluginManager = PluginManager(
      commandSender: (msg) {
        _toIso?.send(msg);
      },
    );
    // F-3：启动即同步 VB 多总线标志（配置里已是 vbcallback 时，-1 路
    // 从一开始就不是合法路——不能等首次模式切换才生效）。
    pluginManager.setVbMultiBus(audioMode == 'vbcallback');
    pluginManager.addListener(notifyListeners);
    pluginManager.setCustomDirs(config.customPluginDirs);
    pluginManager.loadCache();

    if (config.autoRestoreSession && !_testing) {
      final session = SessionMemory.load();
      if (session != null) {
        // 回放守卫：restoreMemoryImage → apply 会触发各 setter 的
        // scheduleAutoSave；不置位则启动 500ms 后必把刚读入的数据
        // 原样写回磁盘（自写），且与引擎异步 getParams 存在竞态窗口。
        _isReplayingSession = true;
        try {
          SessionMemory.restoreMemoryImage(this, session);
        } finally {
          _isReplayingSession = false;
        }
      } else {
        SessionMemory.save(this);
      }
    }
    if (!_testing) _spawn();
  }

  /// vendor 链 12 stage 白名单（与引擎 kAuraStages 对齐；Issue #4）。
  ///
  /// 链页展示序混有 engine 自研 stage（gate/filter/dyneq/…），而 vendor
  /// JamesDSPRebuildChain 要求恰好 12 个已知 id——混发必 E_PARAM。
  /// 此处过滤只保序去杂，不补不增：缺 vendor id 时引擎照常拒收并 set_error。
  /// engine 自研 stage 的顺序本就钉死在 process_stereo_chain，过滤不丢任何功能。
  static const _vendorStageIds = {
    'tube',
    'comp',
    'bass',
    'eq',
    'arbmag',
    'convolver',
    'ddc',
    'liveprog',
    'crossfeed',
    'stereo',
    'reverb',
    'output',
  };

  static String filterVendorOrder(String order) => order
      .split(',')
      .map((s) => s.trim())
      .where(_vendorStageIds.contains)
      .join(',');

  /* ---- 多段图形均衡器（Phase 3） ---- */

  /// C4：按当前采样率重建 EQ 频率网格，增益按**频率**重新映射。
  ///
  /// 裁掉高频带时不能简单截断 gains —— 那样低频段的增益会整体错位。
  /// 这里对每个新频点取旧网格中最接近的旧频点上的增益，
  /// 于是 Nyquist 以内的部分行为完全不变，只有越界的频带连同其增益一起消失。
  /// 采样率变更后由调用方触发，重建网格并把新值落盘。
  /// 进程内模式：重启 isolate（spawn 路径按新采样率建链，就绪后走标准 session
  /// 回放：参数/脚本/IR/插件/音源/bypass 全回来，约 1 秒静音间隙）。
  /// 桥模式跟对端走：仅落盘（回进程内/下次启动生效），设置页有 hint 明示。
  bool _pendingRestartPush = false; // isolate 重启后就绪时重推音源/bypass
  /// isolate 重启（采样率等 spawn 期配置变更用）：关旧端口、杀旧实例、重起。
  /// 就绪后标准回放 + _pendingRestartPush 重推音源/bypass。
  int _restartToken = 0;

  // fatal-backoff 重试计数（'ready' 到达即清零；只对设备失效用）。
  int _fatalRetries = 0;

  // eq.curve 节流状态（常量 A3 与下发逻辑见 state_eq.dart）。
  String? _pendingEqCurve;
  Timer? _eqCurveTimer;
  DateTime _lastEqCurveSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  double _bassRampCur = 0.0;
  double? _bassRampTarget;
  Timer? _bassGainTimer;
  bool _bassDisableAfterRamp = false;

  /// 引擎实测响应（dB），长度 [eqResponsePoints]；null 表示尚未取得。
  /// 绘制时应与 [eqResponseCurve] 比对，不一致说明已过期，需回退近似。
  List<double>? eqResponseDb;

  /// [eqResponseDb] 的实际上限频率：引擎按采样率 Nyquist 收窄，
  /// 不能假设恒为 20000Hz。
  double? eqResponseFMax;

  /// [eqResponseDb] 对应的曲线字符串，用于失效判定。
  String? eqResponseCurve;

  Timer? _eqResponseTimer;

  /// UI 侧的引擎句柄。探针必须由 **UI isolate** 直接调用：
  /// 音频 isolate 正在驱动 WASAPI，在那里跑 29 ms 的探针必然造成 underrun。
  AuraDspLib? _ffiLib;

  /* ---- 组件级微型延迟（真实脉冲响应实测，非查表） ---- */

  /// 实测得到的组件算法延迟（毫秒）。未探测过的组件返回 null，
  /// UI 必须显示"未测量"而不是编一个数字。
  final Map<String, double> _measuredLatencyMs = {};

  /// 正在探测中的组件（UI 据此显示进度并禁用重复点击）。
  final Set<String> _probing = {};

  /// 该组件当前可显示的延迟，带**来源**三态。
  ///
  /// - [measured]  = true：来自真实脉冲响应实测（引擎 auradsp_probe_component）。
  /// - [estimated] = true：来自**实时计算**（目前仅 convolver 的 IR 长度换算，
  ///   是精确数学而非预设常数）。2026-10-19 起不再有任何「预设延迟数值」：
  ///   comp/haas/spatial/arbmag/ddc 的硬编码标称已全部删除，改为 ↻ 实测
  ///   （haas/spatial 探针本轮已支持）。
  /// - 两者皆 false：真的没有可用数值，UI 显示「未测量」。
  ({double ms, bool measured, bool estimated}) componentLatency(String compId) {
    final m = _measuredLatencyMs[compId];
    if (m != null) return (ms: m, measured: true, estimated: false);
    // 解析兜底：只有 convolver 能从已知的 IR 长度算出真正的附加延迟
    // （convFrames/deviceRate 实时计算，非预设常数）。
    if (compId == 'convolver' &&
        convEnabled &&
        convReady &&
        convFrames > 0 &&
        deviceRate > 0) {
      return (
        ms: (convFrames / deviceRate) * 1000.0,
        measured: false,
        estimated: true,
      );
    }
    return (ms: 0.0, measured: false, estimated: false);
  }

  /// 该组件是否支持实测。
  ///
  /// 必须与引擎 `probe_is_supported`（engine/chain/engine_probe.cpp 的
  /// kSupported 表）保持一致——历史上这个集合与引擎两张皮：UI 给 ↻ 但
  /// 引擎一律返回 -1，用户点任何一次都只得到「未测量」（2026-10-16 修）；
  /// 2026-10-18 再修反向漂移：haas（引擎注释明示探针结构性失明，必测出
  /// 0ms 造假）与 bass_shaping（引擎无此 id，其探针名是 shelf）曾在本
  /// 集合中，配 refreshComponentLatency 的假测量分支把标称值冒充实测。
  /// 现集合 = 引擎 kSupported 中有卡片的部分 + 两个资源型组件
  /// （convolver / ddc：资源已加载时可测，未加载时如实报「未测量」）。
  /// param_contract_test Part G 以引擎源文件断言该集合不得越界。
  /// 2026-10-19：haas / spatial 入列——引擎探针改逐声道首非零取最大后
  /// 两者均可如实测量（haas 测当前延迟、spatial 测 0ms 诚实链延迟）。
  static bool isLatencyProbeSupported(String compId) => const {
    'bass',
    'reverb',
    'eq',
    'tube',
    'crossfeed',
    'limiter',
    'post',
    'comp',
    'exciter',
    'stereo',
    'arbmag',
    'dyneq',
    'filter',
    'gate',
    'loudness',
    'convolver',
    'ddc',
    'haas',
    'spatial',
  }.contains(compId);

  /// 探针别名：卡片 compId → 引擎 probe_is_supported 实名列表。
  ///
  /// 低音塑形是合并卡（shelf + bassmono 两段引擎 stage），Dart 侧没有
  /// 'bass_shaping' 这个探针名（引擎只认 shelf/bassmono，二者均在
  /// kSupported）。↻ 实测时对两个实名分别打脉冲，样本延迟求和 =
  /// 合并卡总算法延迟。param_contract_test Part G 校验别名目标必须
  /// 全部在引擎支持集内。
  static const Map<String, List<String>> kLatencyProbeAliases = {
    'bass_shaping': ['shelf', 'bassmono'],
  };

  /// 该组件是否显示 ↻ 刷新按钮。
  /// 2026-10-19：haas/spatial 探针已支持后，全部卡片都是真探针或别名探针
  /// ——三档口径收敛为两档，不再有「只刷新标称」的档位。
  static bool hasLatencyRefresh(String compId) =>
      isLatencyProbeSupported(compId) ||
      kLatencyProbeAliases.containsKey(compId);

  void toggleBypass() {
    bypass = !bypass;
    notifyListeners();
    send({'cmd': 'bypass', 'value': bypass});
  }

  void resetConfig() {
    config = ConfigManager.resetToDefaults();
    // 「恢复默认」必须连带清除会话记忆：否则 autoRestoreSession 开启时
    // 下次启动 restoreMemoryImage 把旧参数全部还原（用户心智：全部归零）。
    // 先取消挂起的防抖保存——否则 500ms 后的 timer 会把文件写回来。
    _debounceSaveTimer?.cancel();
    SessionMemory.clear();
    notifyListeners();
  }

  /// 废除品质档限定拦截，所有效果均自由放行
  @override
  void dispose() {
    _disposed = true;
    hbTick.dispose();
    visiblePage.dispose();
    _headTracker.stop();
    TrayService.instance.isWindowVisible.removeListener(
      _onWindowVisibilityChanged,
    );
    _debounceSaveTimer?.cancel();
    _bassGainTimer?.cancel();
    _eqCurveTimer?.cancel();
    _eqResponseTimer?.cancel();
    // 测试隔离：testing 构造不落盘（且 _iso/_fromIso 本来就是 null，?. 本就安全）。
    if (!_testing) SessionMemory.save(this);
    _toIso?.send({'cmd': 'shutdown'});
    _iso?.kill(priority: Isolate.beforeNextEvent);
    _fromIso?.close();
    spectrum.dispose();
    eqInSpectrum.dispose();
    levelL.dispose();
    levelR.dispose();
    stageLevelsL.dispose();
    stageLevelsR.dispose();
    inputMeterInL.dispose();
    inputMeterInR.dispose();
    inputMeterOutL.dispose();
    inputMeterOutR.dispose();
    grLimiter.dispose();
    grComp.dispose();
    grGate.dispose();
    grDyneqLow.dispose();
    grDyneqMid.dispose();
    grDyneqHigh.dispose();
    eventSeq.dispose();
    pluginManager.removeListener(notifyListeners);
    pluginManager.dispose();
    super.dispose();
  }
}

/// dBFS 线性表读数（等宽显示用）
String dbfsText(double db) {
  if (db <= -90) return '-INF';
  final v = db.abs() < 0.05 ? 0.0 : db;
  return '${v >= 0 ? '' : '-'}${v.abs().toStringAsFixed(1)}';
}

/// 延迟徽标配色档位：四阶声学色彩动力学（直通/零开销为弱灰，录音监听级为绿，影视游戏级为金，缓冲级为红）
Color latencyColor(double ms, AuraPalette p) {
  if (ms <= 0) return p.textDim;
  if (ms <= 10) return p.success;
  if (ms <= 30) return p.warning;
  return p.accent2;
}
