// part of audio_isolate.dart —— Linux 三模式（ADR-012 D-5）接线，S5a 新增。
//
// 语义与 Windows 的桥模式同构：模式切换命令到达时组建/拆除音频管线，
// 泵本身不感知模式。Linux 三条管线：
//   system  —— S3 的本地路径：源为 App 内源（tone/file/pink），输出到
//              默认 sink，本文件不介入；
//   virtual —— 先经 PulseContextService 确保 auradsp_virtual 虚拟 sink
//              存在，再把它的 monitor 源接为泵的 Source（外部 App 的
//              声音播放进虚拟 sink → 引擎处理 → 默认真实 sink 输出）；
//   driver  —— 采集 snd-aloop 在 PA 侧的源；模块未加载/源不存在时
//              不报错：回推 linuxstatus 事件，由设置页提示用户先加载
//              snd-aloop（方案 S5a 验收口径）。
part of 'audio_isolate.dart';

/// 采集型 Source 的统一面（PA 与 ALSA 两种实现）：泵只认 Source，
/// 控制器还要 device/failed/dispose 做状态回推与拆除。
abstract class LinuxCaptureSource implements Source {
  String get device;
  bool get failed;
  void dispose();
}

/// 采集型 Source：把 PulseAudioIn 的阻塞读适配到泵的 fill 契约。
/// 采集失败（源消失/服务端重启）→ 本源失效，后续 fill 恒静音并只记
/// 一次日志；模式重选会重建本对象。
class PulseCaptureSource implements LinuxCaptureSource {
  PulseCaptureSource(this._input);

  final PulseAudioIn _input;
  bool _failed = false;

  @override
  String get device => _input.device;
  @override
  bool get failed => _failed;

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    if (_failed) {
      for (var i = 0; i < frames * 2; i++) {
        out[i] = 0;
      }
      return;
    }
    try {
      _input.read(out, frames);
    } catch (e) {
      _failed = true;
      dbgLog('PULSE-IN capture failed (silenced): $e');
      for (var i = 0; i < frames * 2; i++) {
        out[i] = 0;
      }
    }
  }

  @override
  void dispose() {
    _input.close();
  }
}

/// ALSA 直连版采集 Source（专家模式 driver 路径）：语义与
/// PulseCaptureSource 一致（失败置 failed 后恒静音、只记一次）。
class AlsaCaptureSource implements LinuxCaptureSource {
  AlsaCaptureSource(this._input);

  final AlsaAudioIn _input;
  bool _failed = false;

  @override
  String get device => _input.device;
  @override
  bool get failed => _failed;

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    if (_failed) {
      for (var i = 0; i < frames * 2; i++) {
        out[i] = 0;
      }
      return;
    }
    try {
      _input.read(out, frames);
    } catch (e) {
      _failed = true;
      dbgLog('ALSA-IN capture failed (silenced): $e');
      for (var i = 0; i < frames * 2; i++) {
        out[i] = 0;
      }
    }
  }

  @override
  void dispose() {
    _input.close();
  }
}

/// Linux 模式管线管理（isolate 侧）。只经构造注入的四个回调触碰
/// isolate 的局部状态（source 槽、事件口、设备率），自身持有 PA 侧
/// 对象。所有方法同步阻塞（pa_context 会话），只在命令处理里调用。
class LinuxModeController {
  // 注入构造（私有命名 initializing formals；唯一调用点同在本 library）。
  LinuxModeController({
    required this._getSource,
    required this._setSource,
    required this._send,
    required this._deviceRate,
    this.alsaExpert = false,
    this.alsaCaptureDevice = '',
  });


  final Source? Function() _getSource;
  final void Function(Source?) _setSource;
  final void Function(Map<String, dynamic>) _send;
  final int Function() _deviceRate;

  /// ALSA 专家模式（二期）：driver 模式的采集改走 ALSA 直连。
  /// 后端在 isolate 生成时定死（切换后端会重启 isolate），故为
  /// 普通字段而非回调。
  final bool alsaExpert;
  final String alsaCaptureDevice;

  final PulseContextService _service = PulseContextService();

  String _mode = 'system';
  LinuxCaptureSource? _capture;
  Source? _savedSource;

  String get mode => _mode;

  void _detachCapture({required bool restoreSaved}) {
    final cap = _capture;
    if (cap == null) return;
    _capture = null;
    cap.dispose();
    if (identical(_getSource(), cap)) {
      _setSource(restoreSaved ? _savedSource : null);
    }
    _savedSource = null;
  }

  void _attachCapture(String device) {
    _detachCapture(restoreSaved: false);
    final current = _getSource();
    _savedSource = current; // 切回 system 时恢复（测试源等）
    final input = PulseAudioIn();
    input.open(device: device, rate: _deviceRate());
    final cap = PulseCaptureSource(input);
    _capture = cap;
    _setSource(cap);
    dbgLog('LINUXMODE capture attached: $device');
  }

  /// ALSA 直连版 attach（driver 专家路径）：设备名是 ALSA PCM 名
  /// （默认 hw:Loopback，配置 alsaCaptureDevice 非空时覆盖）。
  void _attachAlsaCapture() {
    _detachCapture(restoreSaved: false);
    final current = _getSource();
    _savedSource = current;
    final device =
        alsaCaptureDevice.trim().isEmpty ? 'hw:Loopback' : alsaCaptureDevice;
    final input = AlsaAudioIn();
    input.open(device: device, rate: _deviceRate());
    // ALSA 无服务端重采样：协商率与泵运行率（输出率）不一致时
    // 按错率消费会变速变调——当场落败（外层给本路径专属 note），
    // 不让错误静默进管线（打磨一期）。
    if (!alsaRateMatches(
        negotiated: input.sampleRate, pumpRate: _deviceRate())) {
      final got = input.sampleRate;
      input.close();
      throw StateError('ALSA capture rate mismatch: $device negotiated '
          '$got Hz but the pump runs at ${_deviceRate()} Hz');
    }
    final cap = AlsaCaptureSource(input);
    _capture = cap;
    _setSource(cap);
    dbgLog('LINUXMODE capture attached (ALSA): $device');
  }

  Map<String, dynamic> _statusEvent({String? note, bool? active}) {
    bool driverLoaded = false;
    bool virtualPresent = false;
    String? loopbackSource;
    String? defaultSink;
    try {
      driverLoaded = _service.asoundLoopbackLoaded();
    } catch (e, st) {
      swallow(e, st);
    }
    try {
      // sink/source 名单与默认 sink 一次会话取齐（probeNames，审查 F3）：
      // 原先多次独立查询各开一条 pa_context 会话，服务端异常时超时翻倍。
      final probe = _service.probeNames();
      defaultSink = probe.defaultSink;
      virtualPresent =
          probe.sinks.contains(PulseContextService.virtualSinkName);
      for (final n in probe.sources) {
        if (isLoopbackSourceName(n)) {
          loopbackSource = n;
          break;
        }
      }
    } catch (e, st) {
      swallow(e, st);
    }
    return {
      'evt': 'linuxstatus',
      'mode': _mode,
      'active': active ?? (_capture != null),
      'virtualSink': virtualPresent,
      'driverLoaded': driverLoaded,
      'loopbackSource': loopbackSource,
      // 设备面板展示用：PulseAudio 默认输出与当前采集源（无采集时为空）。
      'defaultSink': defaultSink,
      'captureSource': _capture?.device ?? '',
      'note': ?note,
    };
  }

  /// 只查询不改管线（设置页打开/isolate 就绪时用）。
  void reportStatus() {
    _send(_statusEvent());
  }

  /// 应用模式（'system' | 'virtual' | 'driver'）。失败不抛：以
  /// linuxstatus 事件回推结果，让 UI 决定提示而非红屏。
  void applyMode(String mode) {
    _mode = mode;
    try {
      _applyModeInner(mode);
    } finally {
      // 每条路径（含各早退分支）都留一行结果日志：driver 缺模块这类
      // 「预期内不可用」与真故障在日志上必须可区分（S5a 实测教训）。
      dbgLog('LINUXMODE applied: mode=$_mode capture=${_capture?.device}');
    }
  }

  void _applyModeInner(String mode) {
    try {
      switch (mode) {
        case 'virtual':
          final ensured = _service.ensureVirtualSink();
          if (!ensured) {
            _detachCapture(restoreSaved: true);
            _send(_statusEvent(note: 'virtual-sink-unavailable', active: false));
            return;
          }
          final def = _service.defaultSinkName();
          if (def == PulseContextService.virtualSinkName) {
            dbgLog('LINUXMODE warning: default sink IS the virtual sink; '
                'output would feed back into capture');
          }
          _attachCapture(PulseContextService.virtualMonitorName);
          _send(_statusEvent(active: true));
          break;
        case 'driver':
          if (!_service.asoundLoopbackLoaded()) {
            _detachCapture(restoreSaved: true);
            _send(_statusEvent(note: 'snd-aloop-not-loaded', active: false));
            return;
          }
          if (alsaExpert) {
            // 专家路径：ALSA 直采 hw:Loopback，绕开 PA 枚举（.monitor
            // 源选择/卡序等一期坑整类不存在于这条路径）。打开失败
            // 落到外层 catch 之前先给本路径专属 note，日志带真实原因。
            try {
              _attachAlsaCapture();
            } catch (e) {
              dbgLog('LINUXMODE driver ALSA attach failed: $e');
              _detachCapture(restoreSaved: true);
              _send(_statusEvent(
                  note: 'alsa-capture-unavailable', active: false));
              return;
            }
            _send(_statusEvent(active: true));
            break;
          }
          final src = _service.findLoopbackSource();
          if (src == null) {
            _detachCapture(restoreSaved: true);
            _send(_statusEvent(
                note: 'loopback-source-unavailable', active: false));
            return;
          }
          _attachCapture(src);
          _send(_statusEvent(active: true));
          break;
        case 'system':
        default:
          _mode = 'system';
          _detachCapture(restoreSaved: true);
          _send(_statusEvent(active: false));
          break;
      }
    } catch (e) {
      dbgLog('LINUXMODE apply($mode) failed: $e');
      _detachCapture(restoreSaved: true);
      _send(_statusEvent(note: 'pulse-unavailable', active: false));
    }
  }

  void dispose() {
    _detachCapture(restoreSaved: false);
  }
}
