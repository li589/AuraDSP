// part of audio_isolate.dart —— Windows 管线本地捕获链（全接线 W2，
// 2026-11-10）。与 audio_isolate_linux.dart 的 LinuxModeController
// 同构：模式命令到达时组建/拆除采集管线，泵本身不感知。
//
// 语义（用户裁定「全接线」）：管线输入 = WASAPI 且输出 =
// WASAPI 时，链路 = 本地链——WasapiCapture（渲染端点回录或
// 捕获端点直采）作 Source 喂本地引擎，WasapiOut 渲染到
// pipelineOutputDevice 指定端点（不再恒绑系统默认端点）。
// 输入 = VAIO/ASIO 时仍走既有桥链，本控制器只负责在桥启动
// 时拆除捕获链（互斥）。
part of 'audio_isolate.dart';

/// 采集型 Source 的 Windows 面（与 LinuxCaptureSource 同形）：
/// 泵只认 Source，控制器还要 failed/dispose 做状态回推与拆除。
abstract class WindowsCaptureSource implements Source {
  bool get failed;
  void dispose();
}

/// 把 WasapiCapture 的推模型（设备成包到达）适配到泵的拉
/// 模型 fill 契约：内部环形 FIFO 承接排包，fill 按需取帧、
/// 不足补零（欠载语义与 Linux 捕获源/FileSource 一致）。
///
/// 采样率：捕获设备优先在 init 时请求引擎率（WASAPI 服务端
/// 转换）；协商率仍与泵率不同时在此做线性重采样（FileSource
/// 同式，分数游标跨调用保留）。
class WasapiCaptureSourceImpl implements WindowsCaptureSource {
  WasapiCaptureSourceImpl(this._capture);

  final WasapiCapture _capture;
  bool _failed = false;

  @override
  bool get failed => _failed;

  /// 失效一次性回调（控制器回推 capturestatus 用）。
  void Function()? onFailed;

  static const int _capFrames = 16384;
  final Float32List _fifo = Float32List(_capFrames * 2);
  int _r = 0; // 读游标（帧）
  int _n = 0; // 在仓帧数
  double _frac = 0; // 重采样分数游标（输入帧坐标）
  Float32List? _scratch;

  @override
  void fill(Float32List out, int frames, int deviceRate) {
    if (_failed) {
      _zero(out, frames);
      return;
    }
    try {
      _drain();
    } catch (e, st) {
      _failed = true;
      swallow(e, st);
      dbgLog('capturemode: capture source failed: $e');
      onFailed?.call();
      _zero(out, frames);
      return;
    }
    final capRate = _capture.sampleRate;
    if (capRate == deviceRate) {
      final take = math.min(frames, _n);
      for (var i = 0; i < take; i++) {
        final idx = ((_r + i) % _capFrames) * 2;
        out[i * 2] = _fifo[idx];
        out[i * 2 + 1] = _fifo[idx + 1];
      }
      _r = (_r + take) % _capFrames;
      _n -= take;
      _zeroFrom(out, take, frames);
    } else {
      final ratio = capRate / deviceRate;
      var avail = 0;
      if (_n >= 2) {
        avail = ((_n - 1 - _frac) / ratio).floor() + 1;
        if (avail < 0) avail = 0;
      }
      final produce = math.min(frames, avail);
      for (var i = 0; i < produce; i++) {
        final pos = _frac + i * ratio;
        final i0 = pos.floor();
        final f = pos - i0;
        final a = ((_r + i0) % _capFrames) * 2;
        final b = ((_r + i0 + 1) % _capFrames) * 2;
        out[i * 2] = _fifo[a] * (1 - f) + _fifo[b] * f;
        out[i * 2 + 1] = _fifo[a + 1] * (1 - f) + _fifo[b + 1] * f;
      }
      _zeroFrom(out, produce, frames);
      final consumed = _frac + produce * ratio;
      final drop = consumed.floor();
      _r = (_r + drop) % _capFrames;
      _n -= drop;
      _frac = consumed - drop;
    }
  }

  void _drain() {
    final free = _capFrames - _n;
    // 仓满时本轮不排包：drainInto 守整包契约（装不下整包
    // 不读），剩余空间过小时强行排包只会把新包永久留在
    // 设备缓冲里错位——留待消费腾出空间后再排。
    if (free < 2048) return;
    _scratch ??=
        Float32List(math.max(8192, _capture.bufferFrames * 2) * 2);
    final maxIn = math.min(free, _scratch!.length ~/ 2);
    final got = _capture.drainInto(_scratch!, maxIn);
    for (var i = 0; i < got; i++) {
      final idx = ((_r + _n + i) % _capFrames) * 2;
      _fifo[idx] = _scratch![i * 2];
      _fifo[idx + 1] = _scratch![i * 2 + 1];
    }
    _n += got;
  }

  void _zero(Float32List out, int frames) => _zeroFrom(out, 0, frames);

  void _zeroFrom(Float32List out, int from, int frames) {
    for (var i = from; i < frames; i++) {
      out[i * 2] = 0;
      out[i * 2 + 1] = 0;
    }
  }

  @override
  void dispose() {
    try {
      _capture.stop();
    } catch (e, st) {
      swallow(e, st);
    }
  }
}

/// Windows 捕获链管理（isolate 侧）。只经构造注入的回调触碰
/// isolate 的局部状态（source 槽、audioOut 槽、事件口、引擎
/// 率），自身持有捕获设备对象。所有方法同步调用（COM 会话），
/// 只在命令处理里调用。
class WindowsCaptureController {
  WindowsCaptureController({
    required this._getSource,
    required this._setSource,
    required this._getAudioOut,
    required this._setAudioOut,
    required this._send,
    required this._engineRate,
  });

  final Source? Function() _getSource;
  final void Function(Source?) _setSource;
  final AudioOut? Function() _getAudioOut;
  final void Function(AudioOut?) _setAudioOut;
  final void Function(Map<String, dynamic>) _send;
  final double Function() _engineRate;

  WasapiCaptureSourceImpl? _capture;
  Source? _savedSource;

  bool get active => _capture != null;

  void _sendStatus(bool activeNow, String note) {
    _send({'evt': 'capturestatus', 'active': activeNow, 'note': note});
  }

  /// 拆捕获链：存档源按 [restoreSaved] 恢复（显式关链时
  /// 恢复用户先前的测试源；被桥接管/被新源覆盖时不恢复）。
  void detach({required bool restoreSaved}) {
    final cap = _capture;
    if (cap == null) return;
    _capture = null;
    cap.dispose();
    if (identical(_getSource(), cap)) {
      _setSource(restoreSaved ? _savedSource : null);
    }
    _savedSource = null;
    _sendStatus(false, '');
    dbgLog('capturemode: detached');
  }

  /// 组建捕获链：输出端点对齐（必要时重建 WasapiOut 并校验
  /// 协商率 == 引擎率）→ 捕获设备 init/start → 装源。
  /// 任一步失败都回推 capturestatus(active:false, note)，
  /// 不抛（命令处理层无恢复语义，状态以事件为准）。
  void attach({
    required String captureEndpoint,
    required bool loopback,
    required String outputEndpoint,
  }) {
    detach(restoreSaved: false);
    _savedSource = _getSource();
    final engineRate = _engineRate();

    final cur = _getAudioOut();
    final curId = cur is WasapiOut ? cur.endpointId : null;
    if (cur == null || curId != outputEndpoint) {
      if (!_rebuildOutput(outputEndpoint, engineRate)) {
        _sendStatus(false, 'output-init-failed');
        return;
      }
    }
    final out = _getAudioOut();
    if (out != null && engineRate > 0 && out.sampleRate != engineRate) {
      // 设备拒绝以引擎率协商：本地链照常跑会变速变调，
      // 拒绝起链（输出保持已重建状态，用户可换端点或改
      // 引擎采样率后重试）。
      dbgLog('capturemode: rate mismatch out=${out.sampleRate} '
          'engine=$engineRate — refuse to attach');
      _sendStatus(false, 'rate-mismatch');
      return;
    }

    final cap = WasapiCapture();
    try {
      cap.init(
        endpointId: captureEndpoint,
        loopback: loopback,
        requestedSampleRate: engineRate > 0 ? engineRate.toInt() : null,
      );
      cap.start();
    } catch (e) {
      dbgLog('capturemode: capture init failed: $e');
      _sendStatus(false, 'capture-init-failed');
      return;
    }
    final src = WasapiCaptureSourceImpl(cap)..onFailed = _sendCaptureLost;
    _capture = src;
    _setSource(src);
    _sendStatus(true, '');
    dbgLog('capturemode: attached cap='
        '${captureEndpoint.isEmpty ? "(default)" : captureEndpoint} '
        'loopback=$loopback capRate=${cap.sampleRate} '
        'outRate=${out?.sampleRate}');
  }

  /// 按端点 ID 重建本地输出（新 WasapiOut 实例；旧实例先
  /// stop）。失败时回滚到默认端点实例（尽力保住本地输出），
  /// 回滚也失败则置空（泵的降级路径接管）。
  bool _rebuildOutput(String endpointId, double engineRate) {
    final old = _getAudioOut();
    try {
      old?.stop();
    } catch (e, st) {
      swallow(e, st);
    }
    final n = WasapiOut()..endpointId = endpointId;
    try {
      n.init(requestedSampleRate: engineRate > 0 ? engineRate.toInt() : null);
      n.start();
    } catch (e) {
      dbgLog('capturemode: output rebuild failed ($endpointId): $e');
      final back = WasapiOut();
      try {
        back.init(
            requestedSampleRate: engineRate > 0 ? engineRate.toInt() : null);
        back.start();
        _setAudioOut(back);
      } catch (e2, st2) {
        swallow(e2, st2);
        _setAudioOut(null);
      }
      return false;
    }
    _setAudioOut(n);
    dbgLog('capturemode: output rebuilt endpoint='
        '${endpointId.isEmpty ? "(default)" : endpointId} '
        'rate=${n.sampleRate}');
    return true;
  }

  void _sendCaptureLost() {
    dbgLog('capturemode: capture lost');
    _sendStatus(false, 'capture-lost');
  }
}
