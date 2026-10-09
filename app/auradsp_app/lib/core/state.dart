/*
 * state.dart — AppModel：主 isolate 侧的应用状态
 *
 * 职责：持有音频 isolate（唯一 auradsp_handle 所有者），把消息协议翻译为
 * 可观察状态；viz 高频数据走独立 ValueNotifier（30fps），避免整页重建。
 */
import 'dart:isolate';

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
  double bassGain = 0, stereoMix = 0.5, postGain = 0;
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

  // 用户偏好
  AuraThemeId themeId = AuraThemeId.auraDark;
  Locale locale = const Locale('zh');
  int latencyMode = 1; // 0=realtime 1=music 2=quality

  // 高频可视化（独立 notifier，30fps）
  final spectrum = ValueNotifier<List<double>>(List.filled(32, 0));
  final levelL = ValueNotifier<double>(-90);
  final levelR = ValueNotifier<double>(-90);

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

  /// 混响预设（T2 效果）：音乐/实时档下被守卫拦截，这里自动先切品质档再下发。
  /// 两条 setParam 按序进 isolate、按序处理，引擎侧守卫在切档后即放行。
  void setReverbPreset(int v, {required String autoQualityMsg}) {
    if (v >= 0 && reverbBlockedNow()) {
      latencyMode = 2;
      notifyListeners();
      _markSent('mode.latency');
      send({'cmd': 'setParam', 'id': 'mode.latency', 'value': 2, 'isFloat': false});
      lastInfo = autoQualityMsg;
      eventSeq.value = ++_guardSeq;
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
        break;
      case 'eq.enable': eqOn = v != 0; break;
      case 'post.gain': postGain = v; break;
      case 'limiter.enable': limiterOn = v != 0; break;
      case 'channels.mode': channelsMode = v.toInt(); break;
      default:
        final m = RegExp(r'^liveprog\.param([1-8])$').firstMatch(id);
        if (m != null) lpParams[int.parse(m.group(1)!) - 1] = v;
    }
  }

  /* ---- Liveprog 命令（v1.1） ---- */

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

  /// 卷积使能（T2 效果）：音乐/实时档自动先切品质档（与混响同策略）
  void setConvolverEnabled(bool on, {required String autoQualityMsg}) {
    if (on && reverbBlockedNow()) {
      latencyMode = 2;
      notifyListeners();
      _markSent('mode.latency');
      send({'cmd': 'setParam', 'id': 'mode.latency', 'value': 2, 'isFloat': false});
      lastInfo = autoQualityMsg;
      eventSeq.value = ++_guardSeq;
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

  void clearConvolver() {
    convEnabled = false;
    convReady = false;
    convFrames = convChannels = convSrcRate = 0;
    convPeak = 0;
    notifyListeners();
    _markSent(ParamId.convClear);
    send({'cmd': 'setParam', 'id': ParamId.convClear, 'value': 0, 'isFloat': false});
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

  /// 守卫预判：reverb 在 realtime/music 档必被引擎拒绝（ADR-002）
  bool reverbBlockedNow() => latencyMode < 2;

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
