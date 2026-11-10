part of 'audio_isolate.dart';

// audio_isolate_apo.dart — System APO 真处理的 App 侧通道（设计 P1）
//
// docs/10-架构/SystemAPO引擎嵌入设计-2026-11-10.md D4/D7：
//   参数块 Global\AuraDSP_ApoParams：本 isolate 是唯一写者——把
//   既有 paramMirror/paramStrMirror 增量同步进共享块（seqlock），
//   APO 的 worker 线程读块应用到 audiodg 内的引擎。
//   回传块 Global\AuraDSP_ApoTelemetry：APO 写、本 isolate 读——
//   sysapo 生效期间 100ms 轮询，把电平/频谱合成与本地引擎同形
//   状的 viz 事件发给 UI（UI 消费管线零改动）。
//
// 平台口径：两类对象都在两平台无条件构造、惰性激活；非 Windows
// 时 kernel32 加载失败即永久静默（与本 isolate 其它平台对象的
// 惰性口径一致）。任何 FFI 失败都不得波及音频路径：全部吞掉并
// 只记一条日志。

/// kernel32/advapi32 的惰性绑定（映射与安全描述符 API）。
class _ApoWin32 {
  _ApoWin32() {
    final k32 = DynamicLibrary.open('kernel32.dll');
    final a32 = DynamicLibrary.open('advapi32.dll');
    createFileMappingW = k32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>,
            Uint32, Uint32, Uint32, Pointer<Utf16>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Void>, int, int,
            int, Pointer<Utf16>)>('CreateFileMappingW');
    openFileMappingW = k32.lookupFunction<
        Pointer<Void> Function(Uint32, Int32, Pointer<Utf16>),
        Pointer<Void> Function(int, int, Pointer<Utf16>)>(
        'OpenFileMappingW');
    mapViewOfFile = k32.lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, Uint32, Uint32,
            IntPtr),
        Pointer<Void> Function(Pointer<Void>, int, int, int, int)>(
        'MapViewOfFile');
    unmapViewOfFile = k32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('UnmapViewOfFile');
    closeHandle = k32.lookupFunction<Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)>('CloseHandle');
    localFree = k32.lookupFunction<Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)>('LocalFree');
    convertSddl = a32.lookupFunction<
        Int32 Function(Pointer<Utf16>, Uint32, Pointer<Pointer<Void>>,
            Pointer<Uint32>),
        int Function(Pointer<Utf16>, int, Pointer<Pointer<Void>>,
            Pointer<Uint32>)>(
        'ConvertStringSecurityDescriptorToSecurityDescriptorW');
  }

  late final Pointer<Void> Function(
      Pointer<Void>, Pointer<Void>, int, int, int, Pointer<Utf16>)
      createFileMappingW;
  late final Pointer<Void> Function(int, int, Pointer<Utf16>)
      openFileMappingW;
  late final Pointer<Void> Function(Pointer<Void>, int, int, int, int)
      mapViewOfFile;
  late final int Function(Pointer<Void>) unmapViewOfFile;
  late final int Function(Pointer<Void>) closeHandle;
  late final Pointer<Void> Function(Pointer<Void>) localFree;
  late final int Function(
      Pointer<Utf16>, int, Pointer<Pointer<Void>>, Pointer<Uint32>)
      convertSddl;
}

_ApoWin32? _apoWin32Cache;
_ApoWin32 _apoWin32() => _apoWin32Cache ??= _ApoWin32();

final class _ApoSecurityAttributes extends Struct {
  @Uint32()
  external int nLength;
  external Pointer<Void> lpSecurityDescriptor;
  @Int32()
  external int bInheritHandle;
}

const int _apoPageReadWrite = 0x04;
const int _apoFileMapAllAccess = 0x000F001F;
const int _apoFileMapRead = 0x00000004;
const String _apoParamsName = 'Global\\AuraDSP_ApoParams';
const String _apoTelemetryName = 'Global\\AuraDSP_ApoTelemetry';
// 与心跳/ApoShared.h 同一穿透 SDDL（LS + Everyone + LPAC 包 SID）。
const String _apoSharedSddl =
    'D:(A;;GA;;;LS)(A;;GA;;;WD)(A;;GA;;;S-1-15-2-1)(A;;GA;;;S-1-15-2-2)';

/// 参数块发布者：镜像 → 共享块（seqlock 单写者）。
class ApoParamPublisher {
  Map<String, ({bool isFloat, double value})>? _mirror;
  Map<String, String>? _strMirror;
  bool Function()? _bypassOf;

  Pointer<Void>? _mapping;
  Pointer<Uint8>? _view;
  Pointer<Uint32>? _u32;
  Pointer<Int32>? _i32;
  Pointer<Float>? _f32;
  bool _gaveUp = false;
  int _seq = 0;

  void bind({
    required Map<String, ({bool isFloat, double value})> mirror,
    required Map<String, String> strMirror,
    required bool Function() bypassOf,
  }) {
    _mirror = mirror;
    _strMirror = strMirror;
    _bypassOf = bypassOf;
  }

  bool _ensure() {
    if (_view != null) return true;
    if (_gaveUp) return false;
    try {
      final w = _apoWin32();
      // 穿透安全描述符（audiodg 的 LPAC 身份必须能打开本块）。
      final sddl = _apoSharedSddl.toNativeUtf16();
      final pSd = calloc<Pointer<Void>>();
      final pSize = calloc<Uint32>();
      Pointer<Void>? sd;
      try {
        if (w.convertSddl(sddl, 1, pSd, pSize) == 0) return _fail();
        sd = pSd.value;
        final sa = calloc<_ApoSecurityAttributes>();
        sa.ref.nLength = sizeOf<_ApoSecurityAttributes>();
        sa.ref.lpSecurityDescriptor = sd;
        sa.ref.bInheritHandle = 0;
        final name = _apoParamsName.toNativeUtf16();
        try {
          _mapping = w.createFileMappingW(nullptr.cast(), sa.cast(),
              _apoPageReadWrite, 0, kApoBlockMappingBytes, name);
        } finally {
          calloc.free(name);
          calloc.free(sa);
        }
      } finally {
        calloc.free(sddl);
        calloc.free(pSd);
        calloc.free(pSize);
        if (sd != null) w.localFree(sd);
      }
      if (_mapping == null || _mapping!.address == 0) return _fail();
      final view = w.mapViewOfFile(
          _mapping!, _apoFileMapAllAccess, 0, 0, kApoBlockMappingBytes);
      if (view.address == 0) return _fail();
      _view = view.cast();
      _u32 = view.cast();
      _i32 = view.cast();
      _f32 = view.cast();
      // 头初始化（若映射是上一 App 会话遗留的，序号接着用现有值，
      // 随后 flushAll 整体重写保证一致）。
      _seq = _u32![2];
      _u32![0] = 0x41504152; // 'APAR'
      _u32![1] = 1;
      _u32![4] = kApoNumParamCount;
      dbgLog('apo publisher: param block mapped (seq=$_seq)');
      flushAll();
      return true;
    } catch (e) {
      _gaveUp = true;
      dbgLog('apo publisher unavailable: $e');
      return false;
    }
  }

  bool _fail() {
    _gaveUp = true;
    dbgLog('apo publisher: create mapping failed');
    return false;
  }

  void _beginWrite() {
    _seq += 1; // 奇数 = 写入中
    _u32![2] = _seq;
  }

  void _endWrite() {
    _seq += 1; // 偶数 = 稳定
    _u32![2] = _seq;
  }

  void _writeNumeric(String id, double value) {
    final idx = kApoNumParamIndex[id];
    if (idx == null) return;
    final t = kApoNumParamTypes[idx];
    if (t == 0) {
      _f32![16 + idx] = value;
    } else if (t == 1) {
      _i32![16 + idx] = value.toInt();
    } else {
      _i32![16 + idx] = value != 0 ? 1 : 0;
    }
  }

  void _writeString(String id, String text) {
    final slot = kApoStrSlotIndex[id];
    if (slot == null) return;
    final cap = kApoStrSlotCaps[slot];
    final off = kApoStrSlotOffsets[slot];
    var bytes = utf8.encode(text);
    if (bytes.length > cap - 1) {
      var end = cap - 1;
      // 不截断 UTF-8 多字节字符的中间（续字节 10xxxxxx 回退）。
      while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
      bytes = bytes.sublist(0, end);
    }
    for (var i = 0; i < bytes.length; i++) {
      _view![off + i] = bytes[i];
    }
    _view![off + bytes.length] = 0;
    _u32![5 + slot] = bytes.length;
  }

  /// 单个数值参数变更（setParam 镜像写入点调用）。
  void onNumeric(String id, double value) {
    if (!kApoNumParamIndex.containsKey(id)) return;
    if (!_ensure()) return;
    _beginWrite();
    _writeNumeric(id, value);
    _endWrite();
  }

  /// 单个字符串参数变更（setParamStr 镜像写入点调用）。
  void onString(String id, String text) {
    if (!kApoStrSlotIndex.containsKey(id)) return;
    if (!_ensure()) return;
    _beginWrite();
    _writeString(id, text);
    _endWrite();
  }

  /// 旁路旗变更（'bypass' 命令点调用）。
  void onBypass(bool v) {
    if (!_ensure()) return;
    _beginWrite();
    _u32![3] = v ? 1 : 0;
    _endWrite();
  }

  /// 全量重写（映射新建后与 'apopublish' 命令时）：在一个 seqlock
  /// 跨度内把当前镜像整体落块；镜像里没有的字符串槽清零用长。
  void flushAll() {
    if (_view == null) {
      _ensure();
      return; // _ensure 成功时已在其内部 flushAll（避免递归重复）
    }
    final mirror = _mirror;
    final strMirror = _strMirror;
    if (mirror == null || strMirror == null) return;
    _beginWrite();
    _u32![3] = (_bypassOf?.call() ?? false) ? 1 : 0;
    for (final e in mirror.entries) {
      _writeNumeric(e.key, e.value.value);
    }
    for (var s = 0; s < kApoStrSlotCaps.length; s++) {
      _u32![5 + s] = 0;
    }
    for (final e in strMirror.entries) {
      _writeString(e.key, e.value);
    }
    _endWrite();
    dbgLog('apo publisher: full snapshot '
        '(${mirror.length} numeric, ${strMirror.length} strings)');
  }
}

/// telemetry 读者：sysapo 生效期间轮询回传块，合成 viz 事件。
class ApoTelemetryReader {
  Pointer<Void>? _mapping;
  Pointer<Uint8>? _view;
  Pointer<Uint32>? _u32;
  Pointer<Float>? _f32;
  Timer? _timer;
  void Function(Map<String, dynamic>)? _send;
  int _lastSeq = -1;
  int _lastSeat = -1;
  bool _gaveUp = false;

  void start(void Function(Map<String, dynamic>) send) {
    _send = send;
    if (_gaveUp) return;
    _timer ??= Timer.periodic(const Duration(milliseconds: 100), _tick);
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _close();
  }

  void _close() {
    try {
      if (_view != null) _apoWin32().unmapViewOfFile(_view!.cast());
      if (_mapping != null) _apoWin32().closeHandle(_mapping!);
    } catch (e) {
      dbgLog('apo telemetry close: $e');
    }
    _view = null;
    _mapping = null;
    _lastSeq = -1;
    _lastSeat = -1;
  }

  bool _open() {
    try {
      final w = _apoWin32();
      final name = _apoTelemetryName.toNativeUtf16();
      try {
        _mapping = w.openFileMappingW(_apoFileMapRead, 0, name);
      } finally {
        calloc.free(name);
      }
      if (_mapping == null || _mapping!.address == 0) {
        _mapping = null;
        return false; // APO 尚未创建回传块，下个 tick 再试（非故障）
      }
      final view = w.mapViewOfFile(_mapping!, _apoFileMapRead, 0, 0, 4096);
      if (view.address == 0) {
        _close();
        return false;
      }
      _view = view.cast();
      _u32 = view.cast();
      _f32 = view.cast();
      if (_u32![0] != 0x4154454C) {
        // 'ATEL' 不符：不是本协议的块（版本错位），放弃本次会话。
        dbgLog('apo telemetry: magic mismatch, reader disabled');
        _gaveUp = true;
        _close();
        return false;
      }
      return true;
    } catch (e) {
      // kernel32 不存在（非 Windows）等：永久静默。
      _gaveUp = true;
      _timer?.cancel();
      _timer = null;
      return false;
    }
  }

  void _tick(Timer _) {
    if (_view == null && !_open()) return;
    final u32 = _u32!;
    final f32 = _f32!;
    // 字段序与 ApoShared.h 的 ApoTelemetryBlock 严格对应：
    // 0 magic 1 version 2 seatState 3 ownerPid 4 sampleRate
    // 5 channels 6 paramsApplied 7 fault 8 seatTaken 9 updateSeq
    // 10..13 peakIn/Out L/R（float）14/15 levelL/R dB 16..47 spectrum
    final seat = u32[2];
    if (seat != _lastSeat) {
      _lastSeat = seat;
      dbgLog('apo telemetry: seat=${seat == 1 ? 'claimed' : 'free'} '
          'fault=${u32[7]} applied=${u32[6]}');
    }
    if (seat != 1) return;
    final seq = u32[9];
    if (seq == _lastSeq) return;
    _lastSeq = seq;
    final channels = u32[5];
    final chCount = channels >= 1 && channels <= 8 ? channels : 2;
    final levelL = f32[14];
    final levelR = f32[15];
    final spectrum = List<double>.generate(32, (i) => f32[16 + i]);
    _send?.call({
      'evt': 'viz',
      'backend': 'sysapo',
      'spectrum': spectrum,
      'eqIn': List<double>.filled(32, 0.0),
      'l': levelL,
      'r': levelR,
      'stageL': List<double>.filled(32, -90.0),
      'stageR': List<double>.filled(32, -90.0),
      'chCount': chCount,
      'chLevels': List<double>.generate(
          chCount, (i) => i == 0 ? levelL : (i == 1 ? levelR : -90.0)),
      'stageCh': List<double>.filled(32 * chCount, -90.0),
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }
}
