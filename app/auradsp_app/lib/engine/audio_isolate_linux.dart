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

/// 采集型 Source：把 PulseAudioIn 的阻塞读适配到泵的 fill 契约。
/// 采集失败（源消失/服务端重启）→ 本源失效，后续 fill 恒静音并只记
/// 一次日志；模式重选会重建本对象。
class PulseCaptureSource implements Source {
  PulseCaptureSource(this._input);

  final PulseAudioIn _input;
  bool _failed = false;

  String get device => _input.device;
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
  });


  final Source? Function() _getSource;
  final void Function(Source?) _setSource;
  final void Function(Map<String, dynamic>) _send;
  final int Function() _deviceRate;

  final PulseContextService _service = PulseContextService();

  String _mode = 'system';
  PulseCaptureSource? _capture;
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

  Map<String, dynamic> _statusEvent({String? note, bool? active}) {
    bool driverLoaded = false;
    bool virtualPresent = false;
    String? loopbackSource;
    try {
      driverLoaded = _service.asoundLoopbackLoaded();
    } catch (_) {}
    try {
      // sink/source 名单一次会话取齐（probeNames，审查 F3）：原先两次
      // 独立查询各开一条 pa_context 会话，服务端异常时超时翻倍。
      final probe = _service.probeNames();
      virtualPresent =
          probe.sinks.contains(PulseContextService.virtualSinkName);
      for (final n in probe.sources) {
        if (isLoopbackSourceName(n)) {
          loopbackSource = n;
          break;
        }
      }
    } catch (_) {}
    return {
      'evt': 'linuxstatus',
      'mode': _mode,
      'active': active ?? (_capture != null),
      'virtualSink': virtualPresent,
      'driverLoaded': driverLoaded,
      'loopbackSource': loopbackSource,
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
