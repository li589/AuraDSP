import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

/// OpenTrack UDP 头部跟踪接收器。
///
/// 协议：OpenTrack 默认向 UDP 4242 发送 6 个 little-endian 值：
/// - 48 字节：6 × double（yaw, pitch, roll, x, y, z）
/// - 24 字节：6 × float
/// 旋转量为角度（度），平移量为厘米；本类只消费 yaw。
class HeadTracker {
  RawDatagramSocket? _socket;
  Timer? _timer;
  double? _pending;
  DateTime _lastEmit = DateTime.fromMillisecondsSinceEpoch(0);
  static const int defaultPort = 4242;
  static const int _minIntervalMs = 33; // ~30Hz，引擎侧再做 15ms 平滑

  bool get isRunning => _socket != null;

  Future<bool> start({
    int port = defaultPort,
    required void Function(double yawDeg) onYaw,
  }) async {
    await stop();
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      _socket = socket;
      socket.listen((event) {
        if (event != RawSocketEvent.read) return;
        final datagram = socket.receive();
        if (datagram == null) return;
        final yaw = parseOpenTrackYaw(datagram.data);
        if (yaw == null) return;
        _emit(yaw, onYaw);
      });
      return true;
    } catch (_) {
      _socket = null;
      return false;
    }
  }

  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _pending = null;
    _socket?.close();
    _socket = null;
  }

  void _emit(double yaw, void Function(double) onYaw) {
    final now = DateTime.now();
    final elapsed = now.difference(_lastEmit).inMilliseconds;
    if (elapsed >= _minIntervalMs) {
      _lastEmit = now;
      _pending = null;
      onYaw(yaw);
      return;
    }
    _pending = yaw;
    _timer ??= Timer(Duration(milliseconds: _minIntervalMs - elapsed), () {
      _timer = null;
      final value = _pending;
      _pending = null;
      if (value == null) return;
      _lastEmit = DateTime.now();
      onYaw(value);
    });
  }
}

/// 解析 OpenTrack UDP 包中的 yaw（度）。返回 null 表示长度/数值非法。
double? parseOpenTrackYaw(List<int> bytes) {
  double? value;
  if (bytes.length >= 48) {
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    value = data.getFloat64(0, Endian.little);
  } else if (bytes.length >= 24) {
    final data = ByteData.sublistView(Uint8List.fromList(bytes));
    value = data.getFloat32(0, Endian.little);
  }
  if (value == null || !value.isFinite) return null;
  return value.clamp(-180.0, 180.0).toDouble();
}
