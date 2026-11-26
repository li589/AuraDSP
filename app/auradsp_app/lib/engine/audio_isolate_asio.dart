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
// v2：参数块改奇偶 seqlock（与 APO 同协议）。旧 App 的 v1 块被驱动
// 按版本全等整体拒绝，安全降级为默认参数。
const int _asioParamsVersion = 2;
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

/// 参数块载荷序列化。effectiveChannels 只覆盖 channels.count 的发送值，
/// 不修改镜像中的用户原值；能力恢复后可由 isolate 重新派发。
String serializeAsioParamPayload(
  Map<String, ({bool isFloat, double value})> mirror,
  Map<String, String>? strMirror, {
  int? effectiveChannels,
}) {
  final parts = <String>[];
  final ids = mirror.keys.toList()..sort();
  for (final id in ids) {
    final e = mirror[id]!;
    if (!e.value.isFinite) continue;
    final value = id == 'channels.count' && effectiveChannels != null
        ? effectiveChannels.toDouble()
        : e.value;
    if (e.isFloat) {
      parts.add('$id=$value');
    } else {
      parts.add('$id=${value.toInt()}');
    }
  }
  final order = strMirror?['graph.order'];
  if (order != null &&
      order.isNotEmpty &&
      !order.contains(';') &&
      !order.contains('=')) {
    parts.add('graph.order=$order');
  }
  return parts.join(';');
}

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
  int _requestSeq = 0;
  int? _effectiveChannels;
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
        _i32![6] = 0; // W7：端点序号（reserved1[0]）随块头重置归零
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
  /// channels.count 自 W6（2026-11-24）起**随镜像下发**：驱动不再把它
  /// 钉成 DAW 协商宽，App 的 4.0/2.0 档位因此能真正改变 DAW 进程内
  /// 引擎的处理宽度（流宽与引擎宽不一致由驱动 chmap 适配层承担）。
  /// 字符串型参数只携带 graph.order（分隔格式承载不了任意文本——
  /// 脚本代码/文件路径类不经本块，属 S4 已知约束）。
  String _serialize() {
    final mirror = _mirror;
    if (mirror == null) return '';
    return serializeAsioParamPayload(
      mirror,
      _strMirror,
      effectiveChannels: _effectiveChannels,
    );
  }

  /// 全量落块（v2 奇偶 seqlock，与 APO 参数块同协议）：
  /// seq 先置奇数（写入中）→ 写载荷/字节数/bypass/mute → 再置偶数
  /// （稳定）。读者前后各取一次 seq，两次相同且为偶数才采信，写者
  /// 中途改写必被识破。旧"写毕才递增"让读者可在写者未进入写入态时
  /// 开始拷贝，正是撕裂窗口的来源。
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
    // 1) 进入写入态：seq 变奇（(x+1)|1 保证奇数，含上次中断的奇值）。
    _seq = (_seq + 1) | 1;
    _i32![2] = _seq;
    // 2) 写载荷与独立字段（读者看到奇数不会采信）。
    for (var i = 0; i < bytes.length; i++) {
      view[_asioParamsPayloadOffset + i] = bytes[i];
    }
    view[_asioParamsPayloadOffset + bytes.length] = 0;
    _u32![4] = bytes.length;
    _i32![3] = (_bypassOf?.call() ?? false) ? 1 : 0;
    _i32![5] = (_muteOf?.call() ?? false) ? 1 : 0;
    // reserved1[1]（u32[7]，offset 28）：声道档位请求代号。驱动只在
    // init() 捕获，必须与 payload 同处奇偶 seqlock 写入窗口。
    _u32![7] = _requestSeq;
    // 3) 离开写入态：seq 变偶（稳定发布）。
    _seq += 1;
    _i32![2] = _seq;
  }

  /// 输出端点切换通知（W7）：参数块 reserved1[0] 递增，驱动泵在块
  /// 边界读到新序号即重开 WASAPI 汇（Open 内读注册表新端点），
  /// 不必重开 DAW。只在虚拟形态有意义；未激活/映射失败时静默。
  void bumpEndpointSeq() {
    if (!active) return;
    if (!_ensure()) return;
    final next = ((_i32![6] & 0x7FFFFFFF) + 1) & 0x7FFFFFFF;
    _i32![6] = next;
    dbgLog('asio publisher: endpoint seq -> $next');
  }

  /// 声道档位请求代号：先保存（未激活时也保留），激活后经 flushAll
  /// 与 payload 一起在奇偶 seqlock 内发布。Client 形态不激活发布者。
  void setRequestSeq(int requestSeq) {
    _requestSeq = requestSeq & 0xFFFFFFFF;
    if (!active) return;
    flushAll();
  }

  /// 记录能力钳制后的生效声道数并触发落块；用户原值仍只存在于镜像。
  void setEffectiveChannels(int channels) {
    _effectiveChannels = channels;
    noteChanged();
  }

  /// 参数镜像变更通知（setParam/setParamStr/bypass 派发点调用）：
  /// 30ms 防抖合并拖动期的高频变更，非激活时空操作。
  void noteChanged() {
    if (!active) return;
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 30), flushAll);
  }
}

/// v1..v4 遥测的一次一致性快照。身份、token、running 与 dawCh 在拷贝
/// 前后必须完全一致；版本或 updateSeq 变化时整轮放弃，绝不拼半新半旧。
class AsioTelemetrySnapshot {
  const AsioTelemetrySnapshot({
    required this.version,
    required this.writerPid,
    required this.requestSeq,
    required this.running,
    required this.heartbeat,
    required this.sampleRate,
    required this.dawCh,
    required this.bufferSize,
    required this.frames,
    required this.peakIn,
    required this.peakOut,
    required this.sinkBits,
    required this.sinkRate,
    required this.sinkConfigured,
    required this.sinkEndpoint,
  });

  final int version;
  final int writerPid;
  final int? requestSeq;
  final bool running;
  final int heartbeat;
  final int sampleRate;
  final int dawCh;
  final int bufferSize;
  final int frames;
  final double peakIn;
  final double peakOut;
  final int sinkBits;
  final int sinkRate;
  final bool sinkConfigured;
  final String sinkEndpoint;

  static AsioTelemetrySnapshot? tryRead({
    required int Function(int index) readU32,
    required int Function(int index) readI32,
    required double Function(int index) readF32,
    required String Function() readEndpointId,
  }) {
    final magic = readU32(0);
    final version = readU32(1);
    if (magic != _asioTelemetryMagic || version < 1 || version > 4) {
      return null;
    }
    final writerPid = readU32(2);
    final requestSeq = version == 4 ? readU32(146) : null;
    final running = readI32(3) == 1;
    final heartbeat = readI32(4);
    final sampleRate = readU32(5);
    final dawCh = readU32(6);
    final bufferSize = readU32(7);
    final frames = (readU32(8) + readU32(9) * 4294967296.0).round();
    final peakIn = readF32(10);
    final peakOut = readF32(11);
    final updateSeq = readU32(12);
    final sinkBits = readU32(16);
    final sinkRate = readU32(14);
    final sinkConfigured = readU32(17) != 0;
    final sinkEndpoint = readEndpointId();

    final magicAfter = readU32(0);
    final versionAfter = readU32(1);
    final writerPidAfter = readU32(2);
    final requestSeqAfter = versionAfter == 4 ? readU32(146) : null;
    final runningAfter = readI32(3) == 1;
    final heartbeatAfter = readI32(4);
    final dawChAfter = readU32(6);
    final updateSeqAfter = readU32(12);
    if (magicAfter != magic ||
        versionAfter != version ||
        writerPidAfter != writerPid ||
        requestSeqAfter != requestSeq ||
        runningAfter != running ||
        heartbeatAfter != heartbeat ||
        dawChAfter != dawCh ||
        updateSeqAfter != updateSeq) {
      return null;
    }
    return AsioTelemetrySnapshot(
      version: version,
      writerPid: writerPid,
      requestSeq: requestSeq,
      running: running,
      heartbeat: heartbeat,
      sampleRate: sampleRate,
      dawCh: dawCh,
      bufferSize: bufferSize,
      frames: frames,
      peakIn: peakIn,
      peakOut: peakOut,
      sinkBits: sinkBits,
      sinkRate: sinkRate,
      sinkConfigured: sinkConfigured,
      sinkEndpoint: sinkEndpoint,
    );
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
  int _lastDawCh = 2;

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
    _lastDawCh = 2;
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
      'chCount': _lastDawCh,
      'chLevels': List<double>.filled(_lastDawCh, -90.0),
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
    final snapshot = AsioTelemetrySnapshot.tryRead(
      readU32: (index) => u32[index],
      readI32: (index) => _i32![index],
      readF32: (index) => _f32![index],
      readEndpointId: _readEndpointId,
    );
    if (snapshot == null) {
      // 未知版本、无效块或读取期间身份/几何变化：整轮放弃，绝不发布
      // 旧 running/dawCh 与新 token 的混合快照。
      _sendAbsent();
      return;
    }
    _absentSent = false;
    final running = snapshot.running;
    final heartbeat = snapshot.heartbeat;
    if (running && heartbeat != _lastHeartbeat) {
      _lastHeartbeat = heartbeat;
      _staleTicks = 0;
    } else {
      _staleTicks++;
    }
    // 心跳停滞 1.5s（15 tick）判 DAW 已离场（块在但泵已停）。
    final live = running && _staleTicks <= 15;
    send({
      'evt': 'asiostatus',
      'version': snapshot.version,
      'writerPid': snapshot.writerPid,
      'running': live,
      // 原始 running 用于 token 的 stopped→started epoch；心跳过期只
      // 表示读者判活失败，不能伪造一次驱动停止。
      'driverRunning': snapshot.running,
      'driver': 'AuraDSP Driver',
      'dawSeen': 1,
      'dawActive': live ? 1 : 0,
      'dawFrames': snapshot.frames,
      'dawPeakIn': snapshot.peakIn,
      'dawPeakOut': snapshot.peakOut,
      'dawSr': snapshot.sampleRate,
      'dawCh': snapshot.dawCh,
      // v4 尾段 u32[146]（offset 584）。旧版本不得解析/转发 token。
      if (snapshot.version == 4) 'requestSeq': snapshot.requestSeq,
      'dawSinkBits': snapshot.sinkBits,
      'dawSinkRate': snapshot.sinkRate,
      'dawSinkConfigured': snapshot.sinkConfigured,
      'dawSinkEndpoint': snapshot.sinkEndpoint,
    });
    if (live) {
      _wasLive = true;
      final outDb = _peakDb(snapshot.peakOut);
      // v3（r65）：逐声道峰值在块尾（f32 索引 130 起为入、138 起
      // 为出）。声道数取 DAW 协商值；v2 及以下回落立体声合成
      // （peakOut 折叠单值左右同格，与旧版行为一致）。
      final dawCh = snapshot.dawCh;
      var chCount = 2;
      var chLevels = <double>[outDb, outDb];
      if (snapshot.version >= 3 && dawCh >= 2 && dawCh <= 8) {
        chCount = dawCh;
        chLevels = List<double>.generate(
            dawCh, (c) => _peakDb(_f32![138 + c]));
        _lastDawCh = dawCh;
      }
      // W8（2026-11-24）：主页两柱在 `cc<=2` 分支取 l/r，而旧口径
      // 两者都填折叠单值 peakOut —— 矩阵 2.0 下 L/R 物理独立、显示
      // 却恒同亮（user 实测）。v3 有逐声道峰值时以 chLevels[0]/[1]
      // 为准，与本地泵与桥路径的 levelLDbfs/levelRDbfs 同语义；
      // v2 块没有逐声道数据，才回落单值。
      final levelL = chLevels.isNotEmpty ? chLevels[0] : outDb;
      final levelR = chLevels.length > 1 ? chLevels[1] : outDb;
      send({
        'evt': 'viz',
        'backend': 'asio',
        'spectrum': snapshot.version >= 2
            ? List<double>.generate(32, (i) => _f32![66 + i])
            : List<double>.filled(32, 0.0),
        'eqIn': snapshot.version >= 2
            ? List<double>.generate(32, (i) => _f32![98 + i])
            : List<double>.filled(32, 0.0),
        'l': levelL,
        'r': levelR,
        'stageL': List<double>.filled(32, -90.0),
        'stageR': List<double>.filled(32, -90.0),
        'chCount': chCount,
        'chLevels': chLevels,
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
