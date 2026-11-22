part of 'audio_isolate.dart';

// audio_isolate_asio.dart — ASIO 模式重构 S4：虚拟 ASIO 跨进程双线
//
// 契约单一真相：core/desktop/windows-drivers/04_asio_driver/
// AsioDriverShared.h。
//   参数块 Global\AuraDSP_AsioDriverParams：本 isolate 是唯一写
//   者——虚拟形态（asioFlavor=virtual）下把 paramMirror 序列化为
//   引擎 ApplyParamsString 同格式的参数串写入，驱动泵按 seq 变
//   化应用到 DAW 进程内的引擎实例（此前该引擎恒跑默认参数）。
//   App 不再自开自家驱动会话（去假会话，方案 D1）。
//   遥测块 Global\AuraDSP_AsioDriverTelemetry：驱动写、本
//   isolate 读——100ms 轮询，把 DAW 在场/已处理帧/汇状态转成
//   asiostatus 事件、把峰值/频谱合成与本地引擎同形状的 viz
//   事件（UI 消费管线零改动，镜像 APO 通道先例）。
//
// 平台口径与 APO 通道一致：两类对象无条件构造、惰性激活；非
// Windows 时 kernel32 加载失败即永久静默；任何 FFI 失败都吞掉
// 并只记一条日志，绝不波及音频路径。

const String _asioParamsName = r'Global\AuraDSP_AsioDriverParams';
const String _asioTelemetryName = r'Global\AuraDSP_AsioDriverTelemetry';
const int _asioParamsMagic = 0x50444141; // 'AADP'
const int _asioParamsVersion = 1;
const int _asioParamsBytes = 8192;
const int _asioParamsPayloadOffset = 64;
const int _asioParamsPayloadCap = _asioParamsBytes - _asioParamsPayloadOffset - 1;
const int _asioTelemetryMagic = 0x54444141; // 'AADT'
const int _asioTelemetryBytes = 4096;
// 参数块读者是同用户的 DAW 进程：IU（交互用户）口径——App 与
// DAW 都以同一交互用户运行，IU 足够且必要；WD（Everyone）会让
// 任意本地进程/用户都能向 DAW 侧引擎注入参数串（N1 在 APO 块
// 上已关掉的同类面，2026-11-23 审查补齐到 ASIO 两块）。不需
// APO 的 LPAC 穿透描述符（读者不是 AppContainer）。
const String _asioSharedSddl = 'D:(A;;GA;;;IU)(A;;GA;;;OW)';

/// 参数块发布者（虚拟形态激活；Client 形态下恒空操作）。
class AsioParamPublisher {
  Map<String, ({bool isFloat, double value})>? _mirror;
  Map<String, String>? _strMirror;
  bool Function()? _bypassOf;
  bool Function()? _muteOf;

  /// 虚拟形态控制模式开关（isolate 的 asiomode 分支维护）。
  bool active = false;

  Pointer<Void>? _mapping;
  Pointer<Uint8>? _view;
  Pointer<Uint32>? _u32;
  Pointer<Int32>? _i32;
  bool _permFail = false;
  int _seq = 0;
  Timer? _debounce;

  void bind({
    required Map<String, ({bool isFloat, double value})> mirror,
    required Map<String, String> strMirror,
    required bool Function() bypassOf,
    required bool Function() muteOf,
  }) {
    _mirror = mirror;
    _strMirror = strMirror;
    _bypassOf = bypassOf;
    _muteOf = muteOf;
  }

  Pointer<Void> _createMapping(_ApoWin32 w, Pointer<Utf16> name) {
    final sddl = _asioSharedSddl.toNativeUtf16();
    final pSd = calloc<Pointer<Void>>();
    final pSize = calloc<Uint32>();
    Pointer<Void>? sd;
    try {
      if (w.convertSddl(sddl, 1, pSd, pSize) == 0) return nullptr;
      sd = pSd.value;
      final sa = calloc<_ApoSecurityAttributes>();
      sa.ref.nLength = sizeOf<_ApoSecurityAttributes>();
      sa.ref.lpSecurityDescriptor = sd;
      sa.ref.bInheritHandle = 0;
      try {
        return w.createFileMappingW(nullptr, sa.cast(), _apoPageReadWrite,
            0, _asioParamsBytes, name);
      } finally {
        calloc.free(sa);
      }
    } finally {
      calloc.free(sddl);
      calloc.free(pSd);
      calloc.free(pSize);
      if (sd != null) w.localFree(sd);
    }
  }

  bool _ensure() {
    if (_view != null) return true;
    if (_permFail) return false;
    try {
      final w = _apoWin32();
      final name = _asioParamsName.toNativeUtf16();
      Pointer<Void> handle;
      try {
        handle = w.openFileMappingW(_apoFileMapAllAccess, 0, name);
        if (handle.address == 0) handle = _createMapping(w, name);
      } finally {
        calloc.free(name);
      }
      if (handle.address == 0) {
        _permFail = true;
        dbgLog('asio publisher: cannot create param block');
        return false;
      }
      final view = w.mapViewOfFile(
          handle, _apoFileMapAllAccess, 0, 0, _asioParamsBytes);
      if (view.address == 0) {
        _permFail = true;
        dbgLog('asio publisher: map view failed');
        return false;
      }
      _mapping = handle;
      _view = view.cast();
      _u32 = view.cast();
      _i32 = view.cast();
      if (_u32![0] != _asioParamsMagic ||
          _u32![1] != _asioParamsVersion) {
        // 全新块（零填充）或旧版块：重写块头，seq 自 0 起，下方
        // flushAll 以镜像真值全量铺载荷。
        _u32![0] = _asioParamsMagic;
        _u32![1] = _asioParamsVersion;
        _seq = 0;
        _i32![2] = 0;
        _u32![4] = 0;
      } else {
        _seq = _i32![2];
      }
      dbgLog('asio publisher: param block mapped '
          '(seq=$_seq, handle=0x${_mapping!.address.toRadixString(16)})');
      flushAll();
      return true;
    } catch (e) {
      _permFail = true;
      dbgLog('asio publisher unavailable: $e');
      return false;
    }
  }

  /// 镜像序列化：引擎 ApplyParamsString 同格式 "id=value;..."。
  /// channels.count 由驱动按 DAW 协商声道自钉，不经本块；字符
  /// 串参数只携带 graph.order（分隔格式承载不了任意文本——脚
  /// 本代码/文件路径类不经本块，属 S4 已知约束）。
  String _serialize() {
    final mirror = _mirror;
    if (mirror == null) return '';
    final parts = <String>[];
    final ids = mirror.keys.toList()..sort();
    for (final id in ids) {
      if (id == 'channels.count') continue;
      final e = mirror[id]!;
      if (!e.value.isFinite) continue;
      if (e.isFloat) {
        parts.add('$id=${e.value}');
      } else {
        parts.add('$id=${e.value.toInt()}');
      }
    }
    final order = _strMirror?['graph.order'];
    if (order != null &&
        order.isNotEmpty &&
        !order.contains(';') &&
        !order.contains('=')) {
      parts.add('graph.order=$order');
    }
    return parts.join(';');
  }

  /// 全量落块：载荷 → 字节数 → bypass → seq 最后递增（驱动以
  /// seq 变化触发应用，应用前复核 seq 稳定防读到半写载荷）。
  void flushAll() {
    if (!active) return;
    if (!_ensure()) return;
    var bytes = utf8.encode(_serialize());
    if (bytes.length > _asioParamsPayloadCap) {
      // 在 cap 内最后一个 ';' 处截断，保每条参数完整。
      var end = _asioParamsPayloadCap;
      while (end > 0 && bytes[end] != 0x3B) {
        end--;
      }
      bytes = bytes.sublist(0, end);
      dbgLog('asio publisher: payload truncated to $end bytes');
    }
    final view = _view!;
    for (var i = 0; i < bytes.length; i++) {
      view[_asioParamsPayloadOffset + i] = bytes[i];
    }
    view[_asioParamsPayloadOffset + bytes.length] = 0;
    _u32![4] = bytes.length;
    _i32![3] = (_bypassOf?.call() ?? false) ? 1 : 0;
    _i32![5] = (_muteOf?.call() ?? false) ? 1 : 0;
    _seq += 1;
    _i32![2] = _seq;
  }

  /// 参数镜像变更通知（setParam/setParamStr/bypass 派发点调用）：
  /// 30ms 防抖合并拖动期的高频变更，非激活时空操作。
  void noteChanged() {
    if (!active) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 30), flushAll);
  }
}

/// 遥测块读者（虚拟形态激活）：asiostatus + viz 合成。
class AsioTelemetryReader {
  Pointer<Void>? _mapping;
  Pointer<Uint8>? _view;
  Pointer<Uint32>? _u32;
  Pointer<Int32>? _i32;
  Pointer<Float>? _f32;
  Pointer<Uint16>? _u16;
  Timer? _timer;
  void Function(Map<String, dynamic>)? _send;
  bool _permFail = false;
  bool _absentSent = false;
  int _lastHeartbeat = -1;
  int _staleTicks = 0;
  bool _wasLive = false;

  void start(void Function(Map<String, dynamic>) send) {
    _send = send;
    if (_permFail) return;
    _timer ??= Timer.periodic(const Duration(milliseconds: 100), _tick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _close();
    _wasLive = false;
    _absentSent = false;
    _lastHeartbeat = -1;
    _staleTicks = 0;
  }

  void _close() {
    try {
      if (_view != null) _apoWin32().unmapViewOfFile(_view!.cast());
      if (_mapping != null) _apoWin32().closeHandle(_mapping!);
    } catch (e) {
      dbgLog('asio telemetry close: $e');
    }
    _view = null;
    _mapping = null;
  }

  bool _ensure() {
    if (_view != null) return true;
    if (_permFail) return false;
    try {
      final w = _apoWin32();
      final name = _asioTelemetryName.toNativeUtf16();
      Pointer<Void> handle;
      try {
        handle = w.openFileMappingW(_apoFileMapRead, 0, name);
      } finally {
        calloc.free(name);
      }
      if (handle.address == 0) return false; // DAW 未起：块缺席，下 tick 重试
      final view =
          w.mapViewOfFile(handle, _apoFileMapRead, 0, 0, _asioTelemetryBytes);
      if (view.address == 0) {
        _permFail = true;
        dbgLog('asio telemetry: map view failed');
        return false;
      }
      _mapping = handle;
      _view = view.cast();
      _u32 = view.cast();
      _i32 = view.cast();
      _f32 = view.cast();
      _u16 = view.cast();
      return true;
    } catch (e) {
      _permFail = true;
      dbgLog('asio telemetry unavailable: $e');
      return false;
    }
  }

  static double _peakDb(double lin) {
    if (lin <= 0.000001) return -90.0;
    final db = 20 * math.log(lin) / math.ln10;
    return db < -90.0 ? -90.0 : (db > 6.0 ? 6.0 : db);
  }

  String _readEndpointId() {
    final u16 = _u16!;
    final codes = <int>[];
    for (var i = 0; i < 96; i++) {
      final c = u16[36 + i];
      if (c == 0) break;
      codes.add(c);
    }
    return String.fromCharCodes(codes);
  }

  void _sendAbsent() {
    if (_absentSent) return;
    _absentSent = true;
    _send?.call({
      'evt': 'asiostatus',
      'running': false,
      'dawSeen': 0,
      'dawActive': 0,
    });
  }

  void _sendStaleZeroViz() {
    _send?.call({
      'evt': 'viz',
      'backend': 'asio',
      'spectrum': List<double>.filled(32, 0.0),
      'eqIn': List<double>.filled(32, 0.0),
      'l': -90.0,
      'r': -90.0,
      'stageL': List<double>.filled(32, -90.0),
      'stageR': List<double>.filled(32, -90.0),
      'chCount': 2,
      'chLevels': List<double>.filled(2, -90.0),
      'stageCh': List<double>.filled(64, -90.0),
      'ts': DateTime.now().millisecondsSinceEpoch,
      'seq': -2,
    });
  }

  void _tick(Timer _) {
    final send = _send;
    if (send == null) return;
    if (!_ensure()) {
      _sendAbsent();
      return;
    }
    final u32 = _u32!;
    if (u32[0] != _asioTelemetryMagic) {
      _sendAbsent();
      return;
    }
    final version = u32[1];
    // 与桥侧读口径对齐（AsioBridge 拒绝 version <1 || >2）：未知版本
    // 按块缺席处理，避免未来块升版改布局时静默误读频谱偏移。
    if (version < 1 || version > 2) {
      _sendAbsent();
      return;
    }
    _absentSent = false;
    final running = _i32![3];
    final heartbeat = _i32![4];
    if (running == 1 && heartbeat != _lastHeartbeat) {
      _lastHeartbeat = heartbeat;
      _staleTicks = 0;
    } else {
      _staleTicks++;
    }
    // 心跳停滞 1.5s（15 tick）判 DAW 已离场（块在但泵已停）。
    final live = running == 1 && _staleTicks <= 15;
    final frames = u32[8] + u32[9] * 4294967296.0;
    final peakIn = _f32![10];
    final peakOut = _f32![11];
    send({
      'evt': 'asiostatus',
      'running': live,
      'driver': 'AuraDSP Driver',
      'dawSeen': 1,
      'dawActive': live ? 1 : 0,
      'dawFrames': frames.round(),
      'dawPeakIn': peakIn,
      'dawPeakOut': peakOut,
      'dawSr': u32[5],
      'dawCh': u32[6],
      'dawSinkBits': u32[16],
      'dawSinkRate': u32[14],
      'dawSinkConfigured': u32[17],
      'dawSinkEndpoint': _readEndpointId(),
    });
    if (live) {
      _wasLive = true;
      final outDb = _peakDb(peakOut);
      send({
        'evt': 'viz',
        'backend': 'asio',
        'spectrum': version >= 2
            ? List<double>.generate(32, (i) => _f32![66 + i])
            : List<double>.filled(32, 0.0),
        'eqIn': version >= 2
            ? List<double>.generate(32, (i) => _f32![98 + i])
            : List<double>.filled(32, 0.0),
        // peakOut 是处理后立体声折的单值峰值（块口径），左右同值
        // 呈现；逐声道峰值待块扩容后再分。
        'l': outDb,
        'r': outDb,
        'stageL': List<double>.filled(32, -90.0),
        'stageR': List<double>.filled(32, -90.0),
        'chCount': 2,
        'chLevels': <double>[outDb, outDb],
        'stageCh': List<double>.filled(64, -90.0),
        'ts': DateTime.now().millisecondsSinceEpoch,
        'seq': heartbeat,
      });
    } else if (_wasLive) {
      _wasLive = false;
      _sendStaleZeroViz();
    }
  }
}
