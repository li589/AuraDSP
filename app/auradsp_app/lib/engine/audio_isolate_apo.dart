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
///
/// 创建权口径：Global\\ 对象只有服务/管理员令牌能创建——生产
/// 路径由 APO（LocalService）在 audiodg 内创建本块，本发布者
/// 以「先 Open、不存在再尝试 Create」接入；两者都不成时不永久
/// 放弃，后续每次参数变更都会重试（APO 首次锁定后块即出现）。
/// 只有 Win32 本身不可用（非 Windows）才永久静默。
class ApoParamPublisher {
  Map<String, ({bool isFloat, double value})>? _mirror;
  Map<String, String>? _strMirror;
  bool Function()? _bypassOf;

  Pointer<Void>? _mapping;
  Pointer<Uint8>? _view;
  Pointer<Uint32>? _u32;
  Pointer<Int32>? _i32;
  Pointer<Float>? _f32;
  bool _permFail = false;
  bool _loggedAbsent = false;
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

  Pointer<Void> _createMapping(_ApoWin32 w, Pointer<Utf16> name) {
    // 穿透安全描述符（audiodg 的 LPAC 身份必须能打开本块）。
    final sddl = _apoSharedSddl.toNativeUtf16();
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
            0, kApoBlockMappingBytes, name);
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
      final name = _apoParamsName.toNativeUtf16();
      Pointer<Void> handle;
      try {
        handle = w.openFileMappingW(_apoFileMapAllAccess, 0, name);
        if (handle.address == 0) handle = _createMapping(w, name);
      } finally {
        calloc.free(name);
      }
      if (handle.address == 0) {
        // 块尚不存在（APO 未首锁且本令牌无创建权）：下次再试。
        if (!_loggedAbsent) {
          _loggedAbsent = true;
          dbgLog('apo publisher: param block absent, will retry');
        }
        return false;
      }
      final view = w.mapViewOfFile(
          handle, _apoFileMapAllAccess, 0, 0, kApoBlockMappingBytes);
      if (view.address == 0) {
        _permFail = true;
        dbgLog('apo publisher: map view failed');
        return false;
      }
      _mapping = handle;
      _view = view.cast();
      _u32 = view.cast();
      _i32 = view.cast();
      _f32 = view.cast();
      if (_u32![0] != 0x41504152) {
        // 全新块（系统零填充）：写头；序号从 0 起。
        _u32![0] = 0x41504152; // 'APAR'
        _u32![1] = kApoParamBlockVersion;
        _u32![4] = kApoNumParamCount;
        _seq = 0;
        _u32![2] = 0;
      } else {
        _seq = _u32![2];
        if (_u32![1] != kApoParamBlockVersion ||
            _u32![4] != kApoNumParamCount) {
          // 存量旧版块（布局版本不符）：字符串槽的有效位随数值槽
          // 总数移位，旧位图不可平移解读——整表清位图，由下方
          // flushAll 以本发布者镜像真值重铺，再盖新版戳。worker
          // 以版本全等为门，清零窗口内整块被拒、无误用。
          for (var i = 0; i < 16; i++) {
            _u32![16 + i] = 0;
          }
          _u32![1] = kApoParamBlockVersion;
          _u32![4] = kApoNumParamCount;
          dbgLog('apo publisher: stale param block re-stamped '
              'to v$kApoParamBlockVersion');
        }
      }
      dbgLog('apo publisher: param block mapped '
          '(seq=$_seq, handle=0x${_mapping!.address.toRadixString(16)})');
      flushAll();
      return true;
    } catch (e) {
      _permFail = true;
      dbgLog('apo publisher unavailable: $e');
      return false;
    }
  }

  void _beginWrite() {
    _seq += 1; // 奇数 = 写入中
    _u32![2] = _seq;
  }

  void _endWrite() {
    _seq += 1; // 偶数 = 稳定
    _u32![2] = _seq;
  }

  void _setMaskBit(int bit) {
    final byteIdx = kApoBlockMaskOffset + bit ~/ 8;
    _view![byteIdx] = _view![byteIdx] | (1 << (bit % 8));
  }

  void _writeNumeric(String id, double value) {
    final idx = kApoNumParamIndex[id];
    if (idx == null) return;
    _setMaskBit(idx);
    final t = kApoNumParamTypes[idx];
    final slot = kApoBlockValuesOffset ~/ 4 + idx;
    if (t == 0) {
      _f32![slot] = value;
    } else if (t == 1) {
      _i32![slot] = value.toInt();
    } else {
      _i32![slot] = value != 0 ? 1 : 0;
    }
  }

  void _writeString(String id, String text) {
    final slot = kApoStrSlotIndex[id];
    if (slot == null) return;
    _setMaskBit(kApoNumParamCount + slot);
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

  /// 已记过日志的未入块 id（每 id 一次，防刷屏）。
  final Set<String> _unmappedLogged = {};

  void _logUnmapped(String id) {
    if (_unmappedLogged.add(id)) {
      dbgLog('apo publisher: param not in block layout, skipped: $id');
    }
  }

  /// 单个数值参数变更（setParam 镜像写入点调用）。
  void onNumeric(String id, double value) {
    if (!kApoNumParamIndex.containsKey(id)) {
      // 全面复审 S3（APO-1）：未入块不再静默丢弃——生成器的分类
      // 完备性断言保证每个可写数值参数或入块或有豁免理由，此处
      // 命中即豁免项（文件型开关/几何/墓碑），留一行日志可审计。
      _logUnmapped(id);
      return;
    }
    if (!_ensure()) return;
    _beginWrite();
    _writeNumeric(id, value);
    _endWrite();
  }

  /// 单个字符串参数变更（setParamStr 镜像写入点调用）。
  void onString(String id, String text) {
    if (!kApoStrSlotIndex.containsKey(id)) {
      _logUnmapped(id);
      return;
    }
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
  /// 跨度内把当前镜像整体落块；有效位图按镜像重建（未在镜像中
  /// 的参数不置位，APO 侧保持引擎默认值）；镜像里没有的字符
  /// 串槽清零用长。
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
    for (var i = 0; i < 64; i++) {
      _view![kApoBlockMaskOffset + i] = 0;
    }
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
  int _lastFault = -1;
  int _lastLoadStage = -1;
  String _lastPluginSig = '';
  int _tickCount = 0;
  int _absentTicks = 0;
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
    _lastFault = -1;
    _lastLoadStage = -1;
    _absentTicks = 0;
    _lastPluginSig = '';
    _tickCount = 0;
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
    if (_view == null && !_open()) {
      // 第五轮 S6：块长期缺席一次性落盘——回传块由 audiodg 内的
      // APO 在流启动时创建；sysapo 已附加且有流经过仍缺席，基本
      // 可断定装机的 AuraApo.dll 是真处理之前的旧版（只有心跳、
      // 无 telemetry/参数块），与「引擎加载失败」（块在、seat 空）
      // 一行分清（第五轮项 7 复盘：r2 日志里读者全程静默、seat
      // 首 tick 日志缺失，反推块根本不存在）。
      _absentTicks++;
      if (_absentTicks == 50) {
        dbgLog('apo telemetry: block absent for 5s '
            '(APO not creating it — pre-engine APO build?)');
      }
      return;
    }
    _absentTicks = 0;
    final u32 = _u32!;
    final f32 = _f32!;
    // 字段序与 ApoShared.h 的 ApoTelemetryBlock 严格对应：
    // 0 magic 1 version 2 seatState 3 ownerPid 4 sampleRate
    // 5 channels 6 paramsApplied 7 fault 8 seatTaken 9 updateSeq
    // 10..13 peakIn/Out L/R（float）14/15 levelL/R dB 16..47 spectrum
    // v2 追加：48..79 eqInSpectrum 80..111 stageL 112..143 stageR
    final seat = u32[2];
    final faultNow = u32[7];
    // telemetry v4 加载诊断（第五轮 S3）：v4 前恒 0（未试）。
    final loadStage = u32[1] >= 4 ? u32[kApoTelemetryLoadDiagU32] : 0;
    final loadErr = u32[1] >= 4 ? u32[kApoTelemetryLoadDiagU32 + 1] : 0;
    _tickCount++;
    // 状态事件（P3）：座位/故障跳变即发，另每 2s 心跳刷新一次
    // 已应用数等缓变字段；状态层据此驱动 APO 面板的引擎状态行。
    if (seat != _lastSeat ||
        faultNow != _lastFault ||
        loadStage != _lastLoadStage ||
        _tickCount % 20 == 0) {
      if (seat != _lastSeat) {
        dbgLog('apo telemetry: seat=${seat == 1 ? 'claimed' : 'free'} '
            'fault=$faultNow applied=${u32[6]}');
      }
      if (loadStage != _lastLoadStage) {
        dbgLog('apo telemetry: loadStage=$loadStage err=$loadErr');
      }
      _send?.call({
        'evt': 'apotelemetry',
        'seat': seat == 1,
        'fault': faultNow != 0,
        'rate': u32[4],
        'channels': u32[5],
        'applied': u32[6],
        'taken': u32[8],
        'loadStage': loadStage,
        'loadErr': loadErr,
      });
      _lastSeat = seat;
      _lastFault = faultNow;
      _lastLoadStage = loadStage;
    }
    if (seat != 1) return;
    // telemetry v3 插件段（Part I Q2/D5）：合成 apoPluginStatus
    // 事件（Q3 状态层消费并与本地同形状的槽状态合并）。签名变
    // 化即发，另随 2s 心跳刷新。faultStage 由类别推导（类别码
    // 只带类别：process_crash 归处理级、其余故障归加载级）。
    if (u32[1] >= 3) {
      const catNames = [
        'none',
        'not_found',
        'unreadable',
        'load_failed',
        'entry_missing',
        'arch_mismatch',
        'init_crash',
        'process_crash',
      ];
      final slots = <Map<String, dynamic>>[];
      var sig = '';
      for (var i = 0; i < kApoPluginSlots; i++) {
        final b = kApoTelemetryPluginsOffset ~/ 4 +
            i * kApoTelemetryPluginSlotU32;
        final flags = u32[b];
        final loaded = (flags & 0xFF) != 0;
        final bypassed = ((flags >> 8) & 0xFF) != 0;
        final fault = ((flags >> 16) & 0xFF) != 0;
        final catCode = (flags >> 24) & 0xFF;
        final cat =
            catCode < catNames.length ? catNames[catCode] : 'load_failed';
        slots.add({
          'slot': i,
          'hasActive': loaded,
          'bypassed': bypassed,
          'fault': fault,
          'faultStage':
              !fault ? 'none' : (cat == 'process_crash' ? 'process' : 'load'),
          'faultCategory': fault ? cat : 'none',
          'latency': u32[b + 1],
          'inRms': f32[b + 2],
          'outRms': f32[b + 3],
          'processCalls': u32[b + 4],
          'appliedLoadGen': u32[b + 5],
          'appliedStateGen': u32[b + 6],
        });
        sig = '$sig|$loaded,$bypassed,$fault,$catCode,'
            '${u32[b + 1]},${u32[b + 4]},${u32[b + 5]},${u32[b + 6]}';
      }
      if (sig != _lastPluginSig || _tickCount % 20 == 0) {
        _lastPluginSig = sig;
        _send?.call({'evt': 'apoPluginStatus', 'slots': slots});
      }
    }
    final seq = u32[9];
    if (seq == _lastSeq) return;
    _lastSeq = seq;
    // 全面复审 S2（APO-11）：telemetry 逐声道数据只有 L/R 两路；
    // 此前按流真实声道数合成 chLevels（ch3+ 恒 -90 假静音）与
    // stageCh 全 -90 表，多声道端点下主页电平排呈假数据。viz 按
    // 立体声口径上报（chCount=2），待 telemetry 块带逐声道电平
    // 后再展开。
    const chCount = 2;
    final levelL = f32[14];
    final levelR = f32[15];
    final spectrum = List<double>.generate(32, (i) => f32[16 + i]);
    // telemetry v2 起带真实分级回传（处理流显示）；v1 块保持静默
    // 占位（旧 APO DLL 与新 App 混跑的过渡形态）。
    final hasStage = u32[1] >= 2;
    _send?.call({
      'evt': 'viz',
      'backend': 'sysapo',
      'spectrum': spectrum,
      'eqIn': hasStage
          ? List<double>.generate(32, (i) => f32[48 + i])
          : List<double>.filled(32, 0.0),
      'l': levelL,
      'r': levelR,
      'stageL': hasStage
          ? List<double>.generate(32, (i) => f32[80 + i])
          : List<double>.filled(32, -90.0),
      'stageR': hasStage
          ? List<double>.generate(32, (i) => f32[112 + i])
          : List<double>.filled(32, -90.0),
      'chCount': chCount,
      'chLevels': List<double>.generate(
          chCount, (i) => i == 0 ? levelL : (i == 1 ? levelR : -90.0)),
      'stageCh': List<double>.filled(32 * chCount, -90.0),
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }
}

const String _apoPluginsName = 'Global\\AuraDSP_ApoPlugins';

/// 插件块发布者（Part I Q2，计划书 D2/D3）：pluginMirror →
/// 共享块（seqlock 单写者，与参数发布者同口径）。创建权同参数
/// 块：APO 在 audiodg 内创建、本发布者 Open 优先。仅在 sysapo
/// 会话激活时工作（active 由 'apopublish'/'apotelemetry' 命令
/// 点置位），其余模式完全静默、零 FFI 尝试。
class ApoPluginPublisher {
  bool active = false;

  Pointer<Void>? _mapping;
  Pointer<Uint8>? _view;
  Pointer<Uint32>? _u32;
  bool _permFail = false;
  bool _loggedAbsent = false;
  int _seq = 0;

  final List<_ApoPluginSlotPub> _pub =
      List.generate(kApoPluginSlots, (_) => _ApoPluginSlotPub());
  bool _hdrSeen = false;
  bool _pubChain = true;
  bool _pubPdc = false;

  Pointer<Void> _createMapping(_ApoWin32 w, Pointer<Utf16> name) {
    final sddl = _apoSharedSddl.toNativeUtf16();
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
            0, kApoPluginBlockBytes, name);
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
      final name = _apoPluginsName.toNativeUtf16();
      Pointer<Void> handle;
      try {
        handle = w.openFileMappingW(_apoFileMapAllAccess, 0, name);
        if (handle.address == 0) handle = _createMapping(w, name);
      } finally {
        calloc.free(name);
      }
      if (handle.address == 0) {
        if (!_loggedAbsent) {
          _loggedAbsent = true;
          dbgLog('apo plugin publisher: block absent, will retry');
        }
        return false;
      }
      final view = w.mapViewOfFile(
          handle, _apoFileMapAllAccess, 0, 0, kApoPluginBlockBytes);
      if (view.address == 0) {
        _permFail = true;
        dbgLog('apo plugin publisher: map view failed');
        return false;
      }
      _mapping = handle;
      _view = view.cast();
      _u32 = view.cast();
      if (_u32![0] != kApoPluginsMagic) {
        // 全新块：写头（链开关默认开、PDC 默认关，与引擎默认一致）。
        _u32![0] = kApoPluginsMagic;
        _u32![1] = kApoPluginsVersion;
        _u32![3] = kApoPluginBlockBytes;
        _u32![4] = 1;
        _u32![5] = 0;
        _seq = 0;
        _u32![2] = 0;
        // 发布模型作废重来：首个 sync 全量落块（含 loadGen 推进）。
        for (final p in _pub) {
          p.occupied = false;
          p.path = '';
          p.id = '';
        }
        _hdrSeen = false;
      } else {
        _seq = _u32![2];
      }
      dbgLog('apo plugin publisher: block mapped '
          '(seq=$_seq, handle=0x${_mapping!.address.toRadixString(16)})');
      return true;
    } catch (e) {
      _permFail = true;
      dbgLog('apo plugin publisher unavailable: $e');
      return false;
    }
  }

  void _beginWrite() {
    _seq += 1;
    _u32![2] = _seq;
  }

  void _endWrite() {
    _seq += 1;
    _u32![2] = _seq;
  }

  void _writeSlotHeader(int slot) {
    final p = _pub[slot];
    final base = apoPluginSlotOffset(slot) ~/ 4;
    _u32![base + 0] = p.format;
    _u32![base + 1] = p.stage;
    _u32![base + 2] = p.mask;
    _u32![base + 3] = p.bypass;
    _u32![base + 4] = p.loadGen;
    _u32![base + 5] = p.stateGen;
    _u32![base + 6] = p.pathBytes;
    _u32![base + 7] = p.stateBytes;
  }

  void _writeUtf8Region(int offset, int cap, String text) {
    var bytes = utf8.encode(text);
    if (bytes.length > cap - 1) {
      var end = cap - 1;
      while (end > 0 && (bytes[end] & 0xC0) == 0x80) {
        end--;
      }
      bytes = bytes.sublist(0, end);
    }
    for (var i = 0; i < bytes.length; i++) {
      _view![offset + i] = bytes[i];
    }
    _view![offset + bytes.length] = 0;
  }

  static int _formatOf(String path) {
    final p = path.toLowerCase();
    if (p.endsWith('.clap')) return kApoPluginFormatClap;
    if (p.contains('.vst3')) return kApoPluginFormatVst3;
    return kApoPluginFormatVst2;
  }

  /// 镜像同步（状态轮询/'apopublish' 调用）：仅 diff 落块；
  /// 身份（占用/路径/id/格式）变化推进 loadGen，其余字段变化
  /// 只改槽头。
  void syncFromMirror(List<PluginSlotCfg> mirror,
      {required bool chainEnabled, required bool pdcEnabled}) {
    if (!active) return;
    if (!_ensure()) return;
    var wrote = false;
    _beginWrite();
    if (!_hdrSeen || chainEnabled != _pubChain) {
      _u32![4] = chainEnabled ? 1 : 0;
      _pubChain = chainEnabled;
      wrote = true;
    }
    if (!_hdrSeen || pdcEnabled != _pubPdc) {
      _u32![5] = pdcEnabled ? 1 : 0;
      _pubPdc = pdcEnabled;
      wrote = true;
    }
    _hdrSeen = true;
    for (var slot = 0; slot < kApoPluginSlots; slot++) {
      final cfg = slot < mirror.length ? mirror[slot] : null;
      final p = _pub[slot];
      final occupied = cfg != null && cfg.loaded && cfg.path.isNotEmpty;
      final path = occupied ? cfg.path : '';
      final id = occupied ? cfg.id : '';
      final format = occupied ? _formatOf(path) : 0;
      final identityChanged =
          occupied != p.occupied || path != p.path || id != p.id ||
              format != p.format;
      if (identityChanged) {
        p.occupied = occupied;
        p.path = path;
        p.id = id;
        p.format = format;
        p.loadGen += 1;
        p.stateBytes = 0;
        final base = apoPluginSlotOffset(slot);
        _writeUtf8Region(base + kApoPluginSlotPathOffset,
            kApoPluginPathBytes, path);
        p.pathBytes = utf8.encode(path).length;
        if (p.pathBytes > kApoPluginPathBytes - 1) {
          p.pathBytes = kApoPluginPathBytes - 1;
        }
        _writeUtf8Region(
            base + kApoPluginSlotIdOffset, kApoPluginIdBytes, id);
        _writeSlotHeader(slot);
        wrote = true;
      }
      final stage = occupied ? cfg.stage : p.stage;
      final mask = occupied ? cfg.channels : p.mask;
      final bypass = occupied ? (cfg.bypass ? 1 : 0) : p.bypass;
      if (stage != p.stage || mask != p.mask || bypass != p.bypass) {
        p.stage = stage;
        p.mask = mask;
        p.bypass = bypass;
        _writeSlotHeader(slot);
        wrote = true;
      }
    }
    _endWrite();
    if (wrote) dbgLog('apo plugin publisher: synced');
  }

  /// 故障重试（Q3）：身份不变也推进 loadGen 并重写身份区，
  /// APO worker 见代次变化即重载该槽（成功清闩锁、失败维持）。
  void forceReload(int slot) {
    if (!active || slot < 0 || slot >= kApoPluginSlots) return;
    if (!_ensure()) return;
    final p = _pub[slot];
    if (!p.occupied) return;
    _beginWrite();
    p.loadGen += 1;
    final base = apoPluginSlotOffset(slot);
    _writeUtf8Region(
        base + kApoPluginSlotPathOffset, kApoPluginPathBytes, p.path);
    _writeUtf8Region(
        base + kApoPluginSlotIdOffset, kApoPluginIdBytes, p.id);
    _writeSlotHeader(slot);
    _endWrite();
    dbgLog('apo plugin publisher: force reload slot=$slot gen=${p.loadGen}');
  }

  /// 状态发布（D3 影子链收获点，Q3 接入）：字节写入状态区并
  /// 推进 stateGen。超限（>512KiB）拒绝并返回 false——该槽在
  /// APO 侧保持旧状态，UI 侧由 Q3 按「状态过大」提示。
  bool publishSlotState(int slot, List<int> bytes) {
    if (!active || slot < 0 || slot >= kApoPluginSlots) return false;
    if (bytes.length > kApoPluginStateBytes) {
      dbgLog('apo plugin publisher: state too large '
          '(${bytes.length} > $kApoPluginStateBytes) slot=$slot');
      return false;
    }
    if (!_ensure()) return false;
    final base = apoPluginSlotOffset(slot) + kApoPluginSlotStateOffset;
    _beginWrite();
    for (var i = 0; i < bytes.length; i++) {
      _view![base + i] = bytes[i];
    }
    final p = _pub[slot];
    p.stateBytes = bytes.length;
    p.stateGen += 1;
    _writeSlotHeader(slot);
    _endWrite();
    dbgLog('apo plugin publisher: state slot=$slot '
        'bytes=${bytes.length} gen=${p.stateGen}');
    return true;
  }
}

class _ApoPluginSlotPub {
  bool occupied = false;
  String path = '';
  String id = '';
  int format = 0;
  int stage = 3;
  int mask = 0xFF;
  int bypass = 0;
  int loadGen = 0;
  int stateGen = 0;
  int pathBytes = 0;
  int stateBytes = 0;
}
