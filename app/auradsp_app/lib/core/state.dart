/*
 * state.dart — AppModel：主 isolate 侧的应用状态
 *
 * 职责：持有音频 isolate（唯一 auradsp_handle 所有者），把消息协议翻译为
 * 可观察状态；viz 高频数据走独立 ValueNotifier（30fps），避免整页重建。
 */
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, Locale;

import '../engine/audio_isolate.dart';
import '../engine/auradsp_ffi.dart' show ParamId;
import '../engine/debug_log.dart';
import 'theme.dart';

enum EngineConn { connecting, ready, fatal }

class EngineInfo {
  final int abi;
  final String version;
  final int deviceRate, deviceCh, bufferFrames;
  EngineInfo(this.abi, this.version, this.deviceRate, this.deviceCh,
      this.bufferFrames);
}

class GuardRejection {
  final String paramId, message;
  final int rc;
  GuardRejection(this.paramId, this.message, this.rc);
}

/// 集中式出厂默认值真相源（与 C++ 引擎 auradsp_create 初始状态严格对齐）
abstract class ParamDefaults {
  static const double bassGain = 0.0;        // [0, 15] dB
  static const double stereoMix = 0.0;       // [0, 1] (0% ~ 100%)
  static const double convMix = 1.0;         // [0, 1] (100% 纯湿)
  static const double postGain = 0.0;        // [-15, 15] dB

  // Freeverb 空间混响
  static const double fvDecay = 0.5;         // 50%
  static const double fvDamp = 0.5;          // 50%
  static const double fvWet = 0.35;          // 35%
  static const double fvDry = 1.0;           // 100%
  static const double fvRoomSize = 1.2;      // 1.2x
  static const double fvWidth = 1.0;         // 100%

  // 低频搁架 (Shelf)
  static const double shelfFreq = 100.0;     // 100 Hz
  static const double shelfGain = 0.0;       // 0.0 dB

  // 声场分带
  static const double stereoBand = 0.5;      // 50%

  // 低音重构
  static const double bassIntensity = 0.6;   // 60%
  static const int bassMode = 0;             // 0: 动态增强, 1: 纯净低架, 2: 心理声学谐波
  static const double bassCutoff = 120.0;    // 120 Hz
  static const double bassHarmonics = 0.45;  // 45%
  static const double bassHarmonicBlend = 0.5;// 50% (平衡)
  static const double bassSubFloor = 25.0;   // 25 Hz

  // 电子管模拟器
  static const double tubeGain = 4.5;        // +4.5 dB
  static const int tubeStyle = 0;            // 0: 三极管, 1: 五极管, 2: 磁带温润
  static const int tubeOversampling = 2;     // 2x
  static const double tubeCompensation = 0.0;// 0.0 dB
  static const double tubeMix = 1.0;         // 100%

  // 多段图形均衡器
  static const int eqBandsCount = 15;        // 15段
  static const double eqQ = 1.414;           // Q 锐度
  static const int eqFilter = 0;             // 0: FIR, 1: 6阶 IIR, 2: 12阶 IIR
  static const int eqInterp = 1;             // 1: Makima, 0: PCHIP
}

class AppModel extends ChangeNotifier {
  /// 声场展宽的引擎侧安全上限。
  /// libjamesdsp 的展宽在 mix=1.0 时执行 `band - centre`（中置完全剥离），
  /// 单声道内容会直接归零（表现为"拉满几乎没声音"）。UI 0..100% 线性映射到
  /// 引擎 0..0.75，既保留可感知的展宽，又不会把人声剥空。
  static const stereoWidenMax = 0.75;

  SendPort? _toIso;
  Isolate? _iso;

  // 引擎连接与状态
  EngineConn conn = EngineConn.connecting;
  String? fatalMsg;
  EngineInfo? info;
  int engineState = 0; // 0=bypass 1=processing 2=error
  double latencyMs = 0;
  bool playing = false;
  bool bypass = false;
  String sourceKind = ''; // '' | 'tone' | 'pink' | 'file'

  // 参数镜像（engine 侧真相，UI 只做回显与乐观更新）
  bool bassOn = false, eqOn = false, limiterOn = true;
  double bassGain = ParamDefaults.bassGain,
      stereoMix = ParamDefaults.stereoMix,
      postGain = ParamDefaults.postGain;
  int reverbPreset = -1;
  int channelsMode = 0;

  // Liveprog（v1.1）：status 0=无代码 1=编译成功 <0=引擎错误码
  bool lpEnabled = false;
  int lpStatus = 0;
  String? lpError; // 最近一次编译错误文案（事件条已显示，这里供编辑页内联标红）
  final List<double> lpParams = List.filled(8, 0);

  // 卷积 / IR（v1.1 M4）：meta 由引擎门卫校验后回读
  bool convEnabled = false, convReady = false;
  int convFrames = 0, convChannels = 0, convSrcRate = 0;
  double convPeak = 0.0;
  List<List<double>> convSpectrum = [];

  // M3-a：轻量效果
  bool tubeOn = false, xfeedOn = false;

  // M5/P-002：声场分带（0..1 每带；bandUsed=false 时随总滑块统一）
  final List<double> stereoBands = List.filled(5, 0.5);
  bool stereoBandUsed = false;

  // 脉冲响应干湿比 + VDC
  double convMix = 1.0;
  bool ddcOn = false, ddcReady = false;

  // M5-b：低频搁架
  bool shelfOn = false;
  double shelfFreq = 100, shelfGain = 0;

  // M5-c：空间混响（Freeverb / Spatial Reverb）
  bool fvOn = false;
  double fvDecay = 0.5, fvDamp = 0.5, fvWet = 0.35, fvDry = 1.0;
  double fvRoomSize = 1.2, fvWidth = 1.0;
  bool get isSpatialReverbOn => reverbPreset >= 0 || fvOn;

  // M3.5-a：处理顺序（Dart 镜像；引擎侧表驱动 P-004）
  String? graphOrder;

  // 低音重构（Phase 4）
  double bassIntensity = ParamDefaults.bassIntensity;
  int bassMode = ParamDefaults.bassMode;
  double bassCutoff = ParamDefaults.bassCutoff;
  double bassHarmonics = ParamDefaults.bassHarmonics;
  double bassHarmonicBlend = ParamDefaults.bassHarmonicBlend;
  double bassSubFloor = ParamDefaults.bassSubFloor;

  // 电子管模拟器（Phase 4）
  double tubeGain = ParamDefaults.tubeGain;
  int tubeStyle = ParamDefaults.tubeStyle;
  int tubeOversampling = ParamDefaults.tubeOversampling;
  double tubeCompensation = ParamDefaults.tubeCompensation;
  double tubeMix = ParamDefaults.tubeMix;

  // 多段图形均衡器（Phase 3）
  static const List<double> eqFreqs7 = [50, 150, 400, 1000, 3000, 8000, 16000];
  static const List<double> eqFreqs10 = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  static const List<double> eqFreqs15 = [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000];
  static const List<double> eqFreqs31 = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000];

  int eqBandsCount = ParamDefaults.eqBandsCount;
  List<double> eqFrequencies = List.from(eqFreqs15);
  List<double> eqGains = List.filled(15, 0.0);
  double eqQ = ParamDefaults.eqQ;
  int eqFilter = ParamDefaults.eqFilter;
  int eqInterp = ParamDefaults.eqInterp;
  String eqPresetName = 'flat';
  bool eqBypass = false;

  // 组件级延迟评估刷新时间戳
  final Map<String, int> _latencyRefreshTicks = {};
  int getComponentLatencyTick(String compId) => _latencyRefreshTicks[compId] ?? 0;

  // 用户偏好
  AuraThemeId themeId = AuraThemeId.auraDark;
  Locale locale = const Locale('zh');
  int latencyMode = 2; // 0=realtime 1=music 2=quality (默认品质/无限制，废除硬性拦截规则)

  // 高频可视化（独立 notifier，30fps）
  final spectrum = ValueNotifier<List<double>>(List.filled(32, 0));
  final levelL = ValueNotifier<double>(-90);
  final levelR = ValueNotifier<double>(-90);
  // [M3.5-c] 12 个 stage 的实时双声道微型电平 (dBFS)
  final stageLevelsL = ValueNotifier<List<double>>(List.filled(12, -120.0));
  final stageLevelsR = ValueNotifier<List<double>>(List.filled(12, -120.0));

  // 一次性事件（shell 监听弹 snackbar）
  final eventSeq = ValueNotifier<int>(0);
  GuardRejection? lastGuard;
  String? lastEngineError;
  String? lastInfo; // 非错误提示（如"已自动切到品质档"）
  int _guardSeq = 0;

  /// 参数下发时刻（id → epoch ms），用于测量 点击→引擎确认 回环耗时
  final Map<String, int> _pendingSentAt = {};

  void _markSent(String id) {
    _pendingSentAt[id] = DateTime.now().millisecondsSinceEpoch;
  }

  ReceivePort? _fromIso;

  AppModel() {
    _spawn();
  }

  void _spawn() {
    conn = EngineConn.connecting;
    notifyListeners();
    final port = ReceivePort();
    _fromIso = port;
    Isolate.spawn(audioIsolateMain, {'toMain': port.sendPort}).then((iso) {
      _iso = iso;
    });
    port.listen(_onMessage);
  }

  void _onMessage(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['evt'] as String) {
      case 'isoReady':
        _toIso = raw['port'] as SendPort;
        break;
      case 'ready':
        info = EngineInfo(raw['abi'] as int, raw['version'] as String,
            raw['deviceRate'] as int, raw['deviceCh'] as int,
            raw['bufferFrames'] as int);
        latencyMs = (raw['latencyMs'] as num).toDouble();
        conn = EngineConn.ready;
        engineState = 1;
        notifyListeners();
        _toIso?.send({'cmd': 'getParams'});
        break;
      case 'params':
        bassOn = (raw['bassEnable'] as int) != 0;
        bassGain = (raw['bassGain'] as num).toDouble();
        reverbPreset = raw['reverbPreset'] as int;
        // 引擎真相是 0..stereoWidenMax，换算回 UI 显示刻度 0..1
        stereoMix =
            ((raw['stereoMix'] as num).toDouble() / stereoWidenMax).clamp(0.0, 1.0);
        eqOn = (raw['eqEnable'] as int) != 0;
        postGain = (raw['postGain'] as num).toDouble();
        limiterOn = (raw['limiterEnable'] as int) != 0;
        latencyMode = raw['latencyMode'] as int;
        lpEnabled = (raw['lpEnable'] as int) != 0;
        lpStatus = raw['lpStatus'] as int;
        convEnabled = (raw['convEnable'] as int) != 0;
        convReady = (raw['convReady'] as int) != 0;
        convFrames = raw['convFrames'] as int;
        convChannels = raw['convChannels'] as int;
        convSrcRate = raw['convSrcRate'] as int;
        convPeak = (raw['convPeak'] as num).toDouble();
        if (raw['convSpectrum'] != null) {
          convSpectrum = (raw['convSpectrum'] as List)
              .map((e) => (e as List).cast<double>().toList())
              .toList();
        } else if (!convReady) {
          convSpectrum = [];
        }
        tubeOn = (raw['tubeEnable'] as int) != 0;
        xfeedOn = (raw['xfeedEnable'] as int) != 0;
        stereoBandUsed = (raw['stereoBandUsed'] as int) != 0;
        convMix = (raw['convMix'] as num).toDouble();
        ddcOn = (raw['ddcEnable'] as int) != 0;
        ddcReady = (raw['ddcReady'] as int) != 0;
        shelfOn = (raw['shelfEnable'] as int) != 0;
        shelfFreq = (raw['shelfFreq'] as num).toDouble();
        shelfGain = (raw['shelfGain'] as num).toDouble();
        fvOn = (raw['fvEnable'] as int) != 0;
        fvDecay = (raw['fvDecay'] as num).toDouble();
        fvDamp = (raw['fvDamp'] as num).toDouble();
        fvWet = (raw['fvWet'] as num).toDouble();
        fvDry = (raw['fvDry'] as num).toDouble();
        notifyListeners();
        break;
      case 'liveprog':
        lpStatus = raw['status'] as int;
        if (lpStatus == 1) lpError = null;
        notifyListeners();
        break;
      case 'fatal':
        conn = EngineConn.fatal;
        fatalMsg = raw['msg'] as String;
        notifyListeners();
        break;
      case 'state':
        engineState = raw['state'] as int;
        latencyMs = (raw['latencyMs'] as num).toDouble();
        notifyListeners();
        break;
      case 'playing':
        playing = raw['playing'] as bool;
        notifyListeners();
        break;
      case 'paramResult':
        final rc = raw['rc'] as int;
        final id = raw['id'] as String;
        final t0 = _pendingSentAt.remove(id);
        if (t0 != null) {
          // 点击 → 引擎确认 的回环耗时（定位"生效慢"到底慢在哪一段）
          dbgLog('rt $id = ${DateTime.now().millisecondsSinceEpoch - t0}ms rc=$rc');
        }
        if (rc != 0) {
          lastGuard = GuardRejection(
              id, (raw['msg'] as String?) ?? 'engine rc=$rc', rc);
          if (id == ParamId.lpCode || id.startsWith('liveprog.')) {
            lpError = lastGuard!.message; // 编辑页内联标红用
          }
          eventSeq.value = ++_guardSeq;
          notifyListeners();
          // 引擎拒绝 → 回读引擎真相，抹掉 _mirror 的乐观假象
          // （否则界面会一直显示"已选中"，但引擎里根本没生效）
          _toIso?.send({'cmd': 'getParams'});
        } else if (id == ParamId.convIrPath) {
          // IR 加载成功 → 回读 meta（frames/channels/srcRate/peak）
          _toIso?.send({'cmd': 'getParams'});
        }
        break;
      case 'viz':
        spectrum.value = (raw['spectrum'] as List).cast<double>();
        levelL.value = (raw['l'] as num).toDouble();
        levelR.value = (raw['r'] as num).toDouble();
        if (raw['stageL'] != null) {
          stageLevelsL.value = (raw['stageL'] as List).cast<num>().map((e) => e.toDouble()).toList();
        }
        if (raw['stageR'] != null) {
          stageLevelsR.value = (raw['stageR'] as List).cast<num>().map((e) => e.toDouble()).toList();
        }
        break;
      case 'error':
        lastEngineError = raw['msg'] as String;
        eventSeq.value = ++_guardSeq;
        notifyListeners();
        break;
    }
  }

  void send(Map<String, dynamic> m) {
    _toIso?.send(m);
  }

  void consumeEvent() {
    lastGuard = null;
    lastEngineError = null;
    lastInfo = null;
  }

  /* ---- 命令 ---- */

  /// 混响预设：废除品质档拦截限制，无条件自由放行
  void setReverbPreset(int v, {String? autoQualityMsg}) {
    if (v >= 0 && latencyMode < 2) {
      latencyMode = 2;
      notifyListeners();
      _markSent('mode.latency');
      send({'cmd': 'setParam', 'id': 'mode.latency', 'value': 2, 'isFloat': false});
    }
    setInt('reverb.preset', v);
  }

  void setLatencyMode(int mode) {
    latencyMode = mode;
    notifyListeners();
    _markSent('mode.latency');
    send({'cmd': 'setParam', 'id': 'mode.latency', 'value': mode, 'isFloat': false});
  }

  void setInt(String id, int v) {
    _mirror(id, v.toDouble());
    _markSent(id);
    notifyListeners();
    send({'cmd': 'setParam', 'id': id, 'value': v, 'isFloat': false});
  }

  void setFloat(String id, double v) {
    _mirror(id, v);
    _markSent(id);
    notifyListeners();
    send({'cmd': 'setParam', 'id': id, 'value': v, 'isFloat': true});
  }

  /// 乐观镜像；被守卫拒绝时由 EventBanner 明示，引擎 params/state 纠正
  void _mirror(String id, double v) {
    switch (id) {
      case 'bass.enable': bassOn = v != 0; break;
      case 'bass.gain': bassGain = v; break;
      case 'reverb.preset': reverbPreset = v.toInt(); break;
      case 'stereo.mix':
        // UI 刻度 0..1 → 存显示值；引擎侧收到 v * stereoWidenMax
        stereoMix = (v / stereoWidenMax).clamp(0.0, 1.0);
        // 总滑块语义 = 回统一模式（引擎侧同时清 vendor bandMixUsed），
        // UI 镜像必须同步清，否则会一直显示"分带生效中"而造成与主滑块冲突
        stereoBandUsed = false;
        break;
      case 'eq.enable': eqOn = v != 0; break;
      case 'post.gain': postGain = v; break;
      case 'limiter.enable': limiterOn = v != 0; break;
      case 'channels.mode': channelsMode = v.toInt(); break;
      case 'tube.enable': tubeOn = v != 0; break;
      case 'crossfeed.enable': xfeedOn = v != 0; break;
      default:
        final mb = RegExp(r'^stereo\.band([1-5])\$').firstMatch(id);
        if (mb != null) {
          stereoBands[int.parse(mb.group(1)!) - 1] = v.clamp(0.0, 1.0);
          stereoBandUsed = true;
          break;
        }
        if (id == ParamId.convMix) { convMix = v; break; }
        if (id == ParamId.ddcEnable) { ddcOn = v != 0; break; }
        if (id == ParamId.ddcReady) { ddcReady = v != 0; break; }
        if (id == ParamId.shelfEnable) { shelfOn = v != 0; break; }
        if (id == ParamId.shelfFreq) { shelfFreq = v; break; }
        if (id == ParamId.shelfGain) { shelfGain = v; break; }
        if (id == ParamId.fvEnable) { fvOn = v != 0; break; }
        if (id == ParamId.fvDecay) { fvDecay = v; break; }
        if (id == ParamId.fvDamp) { fvDamp = v; break; }
        if (id == ParamId.fvWet) { fvWet = v; break; }
        if (id == ParamId.fvDry) { fvDry = v; break; }
        final m = RegExp(r'^liveprog\.param([1-8])$').firstMatch(id);
        if (m != null) lpParams[int.parse(m.group(1)!) - 1] = v;
    }
  }

  /// 双击主滑块时重置声场展宽并清除分带模式（恢复 5 个子带为 0.5 中性）
  void resetStereoWiden() {
    setFloat('stereo.mix', ParamDefaults.stereoMix);
    resetStereoBandsToGlobal();
  }

  void resetStereoBandsToGlobal() {
    for (var i = 0; i < 5; i++) {
      stereoBands[i] = ParamDefaults.stereoBand;
      setFloat('stereo.band${i + 1}', ParamDefaults.stereoBand);
    }
    stereoBandUsed = false;
    notifyListeners();
  }

  /* ---- Liveprog 命令（v1.1） ---- */

  void setGraphOrder(String order) {
    graphOrder = order;
    send({'cmd': 'setParamStr', 'id': 'graph.order', 'text': order});
  }

  /// 获取某个处理链 stage 的启用状态
  bool isStageEnabled(String stageId) {
    return switch (stageId) {
      'tube' => tubeOn,
      'comp' => false,
      'bass' => bassOn,
      'eq' => eqOn,
      'arbmag' => false,
      'convolver' => convEnabled,
      'ddc' => ddcOn,
      'liveprog' => lpEnabled,
      'crossfeed' => xfeedOn,
      'stereo' => stereoMix > 0.0,
      'reverb' => reverbPreset >= 0,
      'output' => limiterOn,
      _ => false,
    };
  }

  /// 切换某个处理链 stage 的启用/旁路状态
  void toggleStage(String stageId) {
    switch (stageId) {
      case 'tube':
        setInt('tube.enable', tubeOn ? 0 : 1);
      case 'bass':
        setInt('bass.enable', bassOn ? 0 : 1);
      case 'eq':
        setInt('eq.enable', eqOn ? 0 : 1);
      case 'convolver':
        setInt(ParamId.convEnable, convEnabled ? 0 : 1);
      case 'ddc':
        setInt(ParamId.ddcEnable, ddcOn ? 0 : 1);
      case 'liveprog':
        setLiveprogEnabled(!lpEnabled);
      case 'crossfeed':
        setInt('crossfeed.enable', xfeedOn ? 0 : 1);
      case 'stereo':
        if (stereoMix > 0.0) {
          setFloat('stereo.mix', 0.0);
        } else {
          setFloat('stereo.mix', 0.5 * stereoWidenMax);
        }
      case 'reverb':
        if (reverbPreset >= 0) {
          setInt('reverb.preset', -1);
        } else {
          setReverbPreset(0, autoQualityMsg: '启用混响：已自动切换到品质模式');
        }
      case 'output':
        setInt('limiter.enable', limiterOn ? 0 : 1);
    }
  }

  void setStringParam(String id, String text) {
    send({'cmd': 'setParamStr', 'id': id, 'text': text});
  }

  void setLiveprogCode(String text) {
    lpError = null;
    send({'cmd': 'setParamStr', 'id': ParamId.lpCode, 'text': text});
  }

  void setLiveprogEnabled(bool on) {
    lpEnabled = on;
    notifyListeners();
    _markSent(ParamId.lpEnable);
    send({'cmd': 'setParam', 'id': ParamId.lpEnable, 'value': on ? 1 : 0, 'isFloat': false});
  }

  void unloadLiveprog() {
    lpEnabled = false;
    lpStatus = 0;
    lpError = null;
    notifyListeners();
    _markSent(ParamId.lpUnload);
    send({'cmd': 'setParam', 'id': ParamId.lpUnload, 'value': 0, 'isFloat': false});
  }

  void setLiveprogParam(int index, double v) {
    setFloat('liveprog.param${index + 1}', v);
  }

  /* ---- 卷积 / IR 命令（v1.1 M4） ---- */

  /// 卷积使能：废除品质档拦截限制，无条件自由放行
  void setConvolverEnabled(bool on, {String? autoQualityMsg}) {
    if (on && latencyMode < 2) {
      latencyMode = 2;
      notifyListeners();
      _markSent('mode.latency');
      send({'cmd': 'setParam', 'id': 'mode.latency', 'value': 2, 'isFloat': false});
    }
    convEnabled = on;
    notifyListeners();
    _markSent(ParamId.convEnable);
    send({'cmd': 'setParam', 'id': ParamId.convEnable, 'value': on ? 1 : 0, 'isFloat': false});
  }

  void loadConvolverIr(String path) {
    // 字符串参数复用 setParamStr 通道；meta 由 paramResult→getParams 回读
    send({'cmd': 'setParamStr', 'id': ParamId.convIrPath, 'text': path});
  }

  void setTubeEnabled(bool on) {
    setInt(ParamId.tubeEnable, on ? 1 : 0);
  }

  void setCrossfeedEnabled(bool on) {
    setInt(ParamId.xfeedEnable, on ? 1 : 0);
  }

  /// 参数化混响使能：废除品质档拦截限制，无条件自由放行
  void setFreeverbEnabled(bool on, {String? autoQualityMsg}) {
    if (on && latencyMode < 2) {
      latencyMode = 2;
      notifyListeners();
      _markSent('mode.latency');
      send({'cmd': 'setParam', 'id': 'mode.latency', 'value': 2, 'isFloat': false});
    }
    fvOn = on;
    notifyListeners();
    _markSent(ParamId.fvEnable);
    send({'cmd': 'setParam', 'id': ParamId.fvEnable, 'value': on ? 1 : 0, 'isFloat': false});
  }

  void selectReverbPreset(int id) {
    reverbPreset = id;
    if (id >= 0 && id <= 7) {
      final (decay, damp, wet, dry, roomSize, width) = switch (id) {
        0 => (0.85, 0.25, 0.45, 1.0, 1.5, 1.0), // 大音乐厅
        1 => (0.75, 0.30, 0.40, 1.0, 1.3, 1.0), // 音乐厅
        2 => (0.65, 0.35, 0.35, 1.0, 1.1, 0.9), // 中音乐厅
        3 => (0.55, 0.40, 0.30, 1.0, 0.9, 0.85), // 小音乐厅
        4 => (0.45, 0.45, 0.28, 1.0, 0.8, 0.8), // 大房间
        5 => (0.35, 0.50, 0.25, 1.0, 0.65, 0.75), // 中房间
        6 => (0.25, 0.55, 0.20, 1.0, 0.5, 0.7), // 小房间
        _ => (0.70, 0.15, 0.35, 1.0, 1.0, 1.0), // 板式混响
      };
      fvDecay = decay;
      fvDamp = damp;
      fvWet = wet;
      fvDry = dry;
      fvRoomSize = roomSize;
      fvWidth = width;
      setFreeverbEnabled(true);
      setFloat('freeverb.decay', decay);
      setFloat('freeverb.damp', damp);
      setFloat('freeverb.wet', wet);
      setFloat('freeverb.dry', dry);
      setReverbPreset(id);
    } else if (id == -1) {
      setReverbPreset(-1);
      setFreeverbEnabled(false);
    } else if (id == -2) {
      // 自定义模式
      setFreeverbEnabled(true);
      notifyListeners();
    }
  }

  void setSpatialReverbEnabled(bool on) {
    if (on) {
      selectReverbPreset(reverbPreset >= 0 ? reverbPreset : 0);
    } else {
      selectReverbPreset(-1);
    }
  }

  void setReverbCustomParam(String param, double value) {
    reverbPreset = -2; // 联动切换为自定义模式
    switch (param) {
      case 'decay':
        fvDecay = value;
        setFloat('freeverb.decay', value);
      case 'damp':
        fvDamp = value;
        setFloat('freeverb.damp', value);
      case 'wet':
        fvWet = value;
        setFloat('freeverb.wet', value);
      case 'dry':
        fvDry = value;
        setFloat('freeverb.dry', value);
      case 'roomSize':
        fvRoomSize = value;
        notifyListeners();
      case 'width':
        fvWidth = value;
        notifyListeners();
    }
  }

  void loadVdc(String path) {
    send({'cmd': 'setParamStr', 'id': ParamId.ddcLoad, 'text': path});
  }

  void setDdcEnabled(bool on) {
    setInt(ParamId.ddcEnable, on ? 1 : 0);
  }

  void clearConvolver() {
    convEnabled = false;
    convReady = false;
    convFrames = convChannels = convSrcRate = 0;
    convPeak = 0;
    convSpectrum = [];
    notifyListeners();
    _markSent(ParamId.convClear);
    send({'cmd': 'setParam', 'id': ParamId.convClear, 'value': 0, 'isFloat': false});
  }

  /* ---- 低音增强重构（Phase 4） ---- */

  void setBassIntensity(double v) {
    bassIntensity = v.clamp(0.0, 1.0);
    final gain = (bassIntensity * 15.0).clamp(0.0, 15.0);
    bassGain = gain;
    setFloat('bass.gain', gain);
    if (bassMode == 1) {
      setFloat('shelf.gain', (bassIntensity * 12.0).clamp(0.0, 12.0));
    }
    notifyListeners();
  }

  void setBassMode(int mode) {
    bassMode = mode;
    if (mode == 1) {
      setInt('shelf.enable', 1);
      setFloat('shelf.freq', bassCutoff);
      setFloat('shelf.gain', (bassIntensity * 12.0).clamp(0.0, 12.0));
    } else {
      setInt('shelf.enable', 0);
    }
    notifyListeners();
  }

  void setBassCutoff(double f) {
    bassCutoff = f;
    setFloat('shelf.freq', f);
    notifyListeners();
  }

  void setBassHarmonics(double h) {
    bassHarmonics = h.clamp(0.0, 1.0);
    notifyListeners();
  }

  void setBassHarmonicBlend(double b) {
    bassHarmonicBlend = b.clamp(0.0, 1.0);
    notifyListeners();
  }

  void setBassSubFloor(double s) {
    bassSubFloor = s;
    notifyListeners();
  }

  /* ---- 电子管模拟器（Phase 4） ---- */

  void setTubeGain(double db) {
    tubeGain = db.clamp(-3.0, 12.0);
    setFloat('tube.gain', tubeGain);
    notifyListeners();
  }

  void setTubeStyle(int style) {
    tubeStyle = style;
    notifyListeners();
  }

  void setTubeOversampling(int os) {
    tubeOversampling = os;
    notifyListeners();
  }

  void setTubeCompensation(double comp) {
    tubeCompensation = comp.clamp(-6.0, 6.0);
    notifyListeners();
  }

  void setTubeMix(double mix) {
    tubeMix = mix.clamp(0.0, 1.0);
    notifyListeners();
  }

  /* ---- 多段图形均衡器（Phase 3） ---- */

  void setEqBandsCount(int count) {
    if (count == eqBandsCount) return;
    eqBandsCount = count;
    final List<double> newFreqs = switch (count) {
      7 => eqFreqs7,
      10 => eqFreqs10,
      31 => eqFreqs31,
      _ => eqFreqs15,
    };
    final oldFreqs = eqFrequencies;
    final oldGains = eqGains;
    final newGains = <double>[];
    for (final f in newFreqs) {
      if (oldFreqs.isEmpty || oldGains.isEmpty) {
        newGains.add(0.0);
        continue;
      }
      if (f <= oldFreqs.first) {
        newGains.add(oldGains.first);
      } else if (f >= oldFreqs.last) {
        newGains.add(oldGains.last);
      } else {
        var idx = 0;
        while (idx < oldFreqs.length - 1 && oldFreqs[idx + 1] < f) {
          idx++;
        }
        final logF0 = math.log(oldFreqs[idx]);
        final logF1 = math.log(oldFreqs[idx + 1]);
        final logTarget = math.log(f);
        final ratio = (logTarget - logF0) / (logF1 - logF0);
        newGains.add(oldGains[idx] + ratio * (oldGains[idx + 1] - oldGains[idx]));
      }
    }
    eqFrequencies = List.from(newFreqs);
    eqGains = newGains;
    _pushEqCurve();
  }

  void setEqBandGain(int index, double gain) {
    if (index >= 0 && index < eqGains.length) {
      eqGains[index] = gain.clamp(-18.0, 18.0);
      eqPresetName = 'custom';
      _pushEqCurve();
    }
  }

  void setEqQ(double q) {
    eqQ = q.clamp(0.3, 10.0);
    _pushEqCurve();
  }

  void setEqFilter(int filter) {
    eqFilter = filter;
    notifyListeners();
  }

  void setEqInterp(int interp) {
    eqInterp = interp;
    notifyListeners();
  }

  void toggleEqBypass() {
    eqBypass = !eqBypass;
    setInt('eq.enable', (eqOn && !eqBypass) ? 1 : 0);
    notifyListeners();
  }

  void flattenEq() {
    eqGains = List.filled(eqFrequencies.length, 0.0);
    eqPresetName = 'flat';
    _pushEqCurve();
  }

  void applyEqPreset(String style) {
    eqPresetName = style;
    final newGains = List.filled(eqFrequencies.length, 0.0);
    for (var i = 0; i < eqFrequencies.length; i++) {
      final f = eqFrequencies[i];
      final logF = math.log(f) / math.ln10; // log10
      var g = 0.0;
      switch (style) {
        case 'pop':
          if (logF <= 2.2) {
            g = 3.0 * (1.0 - (logF - 1.3) / 0.9);
          } else if (logF <= 3.2) {
            g = -1.0;
          } else {
            g = 3.0 * ((logF - 3.2) / 1.1);
          }
        case 'rock':
          if (logF <= 2.0) {
            g = 4.5;
          } else if (logF <= 3.0) {
            g = -2.0;
          } else if (logF <= 3.6) {
            g = 1.0;
          } else {
            g = 4.0;
          }
        case 'jazz':
          if (logF <= 2.3) {
            g = 2.5;
          } else if (logF <= 3.3) {
            g = 1.5;
          } else {
            g = -1.0;
          }
        case 'classical':
          if (logF >= 3.0 && logF <= 3.8) {
            g = 1.5;
          } else {
            g = 0.5;
          }
        case 'vocal':
          if (logF <= 2.0) {
            g = -3.5;
          } else if (logF >= 2.8 && logF <= 3.6) {
            g = 4.0;
          } else {
            g = 0.0;
          }
        case 'smile':
          final x = (logF - 2.8) / 1.5;
          g = (x * x) * 8.0 - 3.0;
        case 'bass_boost':
          if (logF <= 2.3) {
            g = 6.0 * (1.0 - (logF - 1.3) / 1.0);
          } else {
            g = 0.0;
          }
        case 'treble_boost':
          if (logF >= 3.3) {
            g = 5.0 * ((logF - 3.3) / 1.0);
          } else {
            g = 0.0;
          }
        case 'flat':
        default:
          g = 0.0;
      }
      newGains[i] = g.clamp(-18.0, 18.0);
    }
    eqGains = newGains;
    _pushEqCurve();
  }

  void _pushEqCurve() {
    final buffer = StringBuffer();
    if (eqFrequencies.isNotEmpty && eqFrequencies.first > 20) {
      buffer.write('20:${eqGains.first.toStringAsFixed(1)};');
    }
    for (var i = 0; i < eqFrequencies.length; i++) {
      buffer.write('${eqFrequencies[i].toStringAsFixed(1)}:${eqGains[i].toStringAsFixed(1)}');
      if (i < eqFrequencies.length - 1) buffer.write(';');
    }
    if (eqFrequencies.isNotEmpty && eqFrequencies.last < 20000) {
      buffer.write(';20000:${eqGains.last.toStringAsFixed(1)}');
    }
    final curveStr = buffer.toString();
    setStringParam('eq.curve', curveStr);
    notifyListeners();
  }

  /* ---- 组件级微型延迟评估（Phase 4） ---- */

  double getComponentLatency(String compId) {
    return switch (compId) {
      'bass' => bassOn ? 0.0 : 0.0,
      'tube' => tubeOn ? 0.0 : 0.0,
      'eq' => eqOn ? 0.0 : 0.0,
      'stereo' => stereoMix > 0 ? 0.8 : 0.0,
      'reverb' => isSpatialReverbOn ? 30.0 : 0.0,
      'convolver' => (convEnabled && convReady && convFrames > 0 && convSrcRate > 0)
          ? ((convFrames / convSrcRate) * 1000.0)
          : 0.0,
      'ddc' => ddcOn ? 3.0 : 0.0,
      'post' => 0.0,
      _ => 0.0,
    };
  }

  void refreshComponentLatency(String compId) {
    _latencyRefreshTicks[compId] = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
  }

  void setSource(String kind, {String? path}) {
    sourceKind = kind == 'stop' ? '' : kind;
    playing = kind != 'stop';
    notifyListeners();
    send({'cmd': 'source', 'kind': kind, 'path': path});
  }

  void toggleBypass() {
    bypass = !bypass;
    notifyListeners();
    send({'cmd': 'bypass', 'value': bypass});
  }

  void setTheme(AuraThemeId id) {
    themeId = id;
    notifyListeners();
  }

  void setLocale(Locale l) {
    locale = l;
    notifyListeners();
  }

  /// 废除品质档限定拦截，所有效果均自由放行
  bool reverbBlockedNow() => false;

  @override
  void dispose() {
    _toIso?.send({'cmd': 'shutdown'});
    _iso?.kill(priority: Isolate.beforeNextEvent);
    _fromIso?.close();
    spectrum.dispose();
    levelL.dispose();
    levelR.dispose();
    eventSeq.dispose();
    super.dispose();
  }
}

/// dBFS 线性表读数（等宽显示用）
String dbfsText(double db) {
  if (db <= -90) return '-INF';
  final v = db.abs() < 0.05 ? 0.0 : db;
  return '${v >= 0 ? '' : '-'}${v.abs().toStringAsFixed(1)}';
}

/// 延迟徽标配色档位
Color latencyColor(double ms, AuraPalette p) {
  if (ms <= 10) return p.success;
  if (ms <= 30) return p.warning;
  return p.accent2;
}
