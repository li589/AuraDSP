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

/// 端点 id 的 FNV-1a 64 哈希（与 ApoEndpointProps.h 的
/// AuraEndpointIdHash 同算法：对 id 的 UTF-16LE 字节流逐字节
/// FNV-1a）。分端点 telemetry 块名与参数块 v3 覆写表键共用。
int apoEndpointHash(String id) {
  var h = 0x14650fb0739d0383; // FNV offset basis 1469598103934665603
  for (final cu in id.codeUnits) {
    h ^= cu & 0xFF;
    h = h * 1099511628211;
    h ^= (cu >> 8) & 0xFF;
    h = h * 1099511628211;
  }
  return h;
}

/// 分端点 telemetry 块名（与 ApoShared.h AuraApoTelemetryNameFor
/// 同构：小写十六进制 16 位）。逐 nibble 提取——哈希 ≥ 2^63 时
/// Dart int 为负，toUnsigned/toRadixString 会带符号，必须绕开。
String apoTelemetryNameFor(String endpointId) {
  final h = apoEndpointHash(endpointId);
  final sb = StringBuffer('Global\\AuraDSP_ApoTelemetry_');
  for (var shift = 60; shift >= 0; shift -= 4) {
    sb.write(((h >> shift) & 0xF).toRadixString(16));
  }
  return sb.toString();
}
// 与心跳/ApoShared.h 同一穿透 SDDL（LS + 交互用户 IU + OW 所有
// 者 + LPAC 包 SID）。2026-11-22 审查 N1：原 Everyone(WD) 全权过
// 宽已收紧为 IU；2026-11-23 补 OW（网络登录令牌无 IU，创建者打
// 不开自建对象，见 ApoShared.h 注）。
const String _apoSharedSddl =
    'D:(A;;GA;;;LS)(A;;GA;;;IU)(A;;GA;;;OW)(A;;GA;;;S-1-15-2-1)(A;;GA;;;S-1-15-2-2)';

/// 参数块发布者：镜像 → 共享块（seqlock 单写者）。
///
/// 创建权口径：Global\\ 对象只有服务/管理员令牌能创建——生产
/// 路径由 APO（LocalService）在 audiodg 内创建本块，本发布者
/// 以「先 Open、不存在再尝试 Create」接入；两者都不成时不永久
/// 放弃，后续每次参数变更都会重试（APO 首次锁定后块即出现）。
/// 只有 Win32 本身不可用（非 Windows）才永久静默。
class ApoParamPublisher {
  /// 文件效果（IR/DDC）当前实际写入参数块的中转路径（按参数
  /// id 记最近一次有效值）：中转孤儿回收的引用集来源之一。
  final Map<String, String> _fileEffectTransit = {};

  /// File-effect transit conversion cache: id -> (source, effective).
  /// transitPathFor reads and SHA-256-hashes the whole file on every
  /// call; without this, every flushAll re-reads the IR/DDC files.
  final Map<String, (String, String)> _fileEffectConvertCache = {};

  String _convertFileEffect(String id, String text) {
    final hit = _fileEffectConvertCache[id];
    if (hit != null && hit.$1 == text) return hit.$2;
    final effective = ApoTransit.transitPathFor(text) ?? '';
    _fileEffectConvertCache[id] = (text, effective);
    _fileEffectTransit[id] = effective;
    return effective;
  }

  /// 当前被参数块引用的中转路径集合（孤儿回收 keep 集）。
  /// True once at least one full snapshot completed; the orphan
  /// GC trusts the keep set only then.
  bool get hasFlushed => _hasFlushed;
  bool _hasFlushed = false;

  Set<String> get referencedTransitPaths =>
      _fileEffectTransit.values.where((p) => p.isNotEmpty).toSet();

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
    // 文件中转（资源计划 P4）：卷积 IR / DDC 文件路径在写块前
    // 换成中转副本路径——audiodg（LocalService）读不到用户原
    // 路径。状态层与 UI 保留原始路径，只有参数块里走副本；
    // 中转失败写空串（引擎卸载），不写读不到的原路径假装可用。
    // 引擎侧还有第二道围栏（ApoEngineHost 只认中转根下路径）。
    var effective = text;
    if (id == ParamId.convIrPath || id == ParamId.ddcLoad) {
      effective = _convertFileEffect(id, text);
    }
    if (!_ensure()) return;
    _beginWrite();
    _writeString(id, effective);
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
    // Convert file-effect paths BEFORE _beginWrite: the conversion
    // reads/hashes (and may copy) whole files; inside the seqlock
    // span it would stretch the block's in-progress window from
    // microseconds to hundreds of milliseconds. onString has always
    // converted outside the span; flushAll now matches. The
    // conversion is also required for correctness: the mirror holds
    // original user paths, which audiodg cannot read and the host
    // fence rejects (found 2026-11-23: entering APO or restoring a
    // session wrote raw paths, file effects silently unloaded
    // until the user re-picked each file).
    final effectiveStrings = <String, String>{};
    for (final e in strMirror.entries) {
      var text = e.value;
      if (e.key == ParamId.convIrPath || e.key == ParamId.ddcLoad) {
        text = _convertFileEffect(e.key, text);
      }
      effectiveStrings[e.key] = text;
    }
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
    for (final e in effectiveStrings.entries) {
      _writeString(e.key, e.value);
    }
    _writeOverrideTable();
    _endWrite();
    _hasFlushed = true;
    dbgLog('apo publisher: full snapshot '
        '(${mirror.length} numeric, ${strMirror.length} strings)');
  }

  /// 参数块 v3 尾段：分端点声道覆写表（第四十一轮）。条目 =
  /// idHash u64 LE + mode i32 + fill i32 + flags u32（恒 3=两项
  /// 均有效）；未用条目清零。worker 按本端点哈希命中后压过参数
  /// 块全局 mode/fill 与 FX 初值（实时变更通道）。
  /// 第四十二轮 S2 起覆写功能废除：本表恒写全零（顺带清掉
  /// r41 会话可能留在块里的旧表），worker 侧消费能力休眠。
  void _writeOverrideTable() {
    const src = <String, ({int mode, int fill})>{};
    var slot = 0;
    for (final e in src.entries) {
      if (slot >= kApoEpOverrideCount) break;
      final off = kApoEpOverrideOffset + slot * kApoEpOverrideEntryBytes;
      final h = apoEndpointHash(e.key);
      for (var i = 0; i < 8; i++) {
        _view![off + i] = (h >> (8 * i)) & 0xFF;
      }
      _view![off + 8] = e.value.mode & 0xFF;
      _view![off + 9] = (e.value.mode >> 8) & 0xFF;
      _view![off + 10] = (e.value.mode >> 16) & 0xFF;
      _view![off + 11] = (e.value.mode >> 24) & 0xFF;
      _view![off + 12] = e.value.fill & 0xFF;
      _view![off + 13] = (e.value.fill >> 8) & 0xFF;
      _view![off + 14] = (e.value.fill >> 16) & 0xFF;
      _view![off + 15] = (e.value.fill >> 24) & 0xFF;
      _u32![(off + 16) ~/ 4] = 3;
      slot++;
    }
    for (; slot < kApoEpOverrideCount; slot++) {
      final off = kApoEpOverrideOffset + slot * kApoEpOverrideEntryBytes;
      for (var i = 0; i < 20; i++) {
        _view![off + i] = 0;
      }
    }
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
  // 分端点目标（第四十一轮）：'' = 旧全局块（无令牌端点回落）；
  // 非空 = 只读该端点的 v7 分块（块名按 id 哈希派生，开块后以
  // 块内身份盖章复核，防哈希碰撞/陈旧块冒名）。
  String _targetId = '';
  bool _magicGaveUp = false;
  bool _stampWarned = false;
  int _lastSeq = -1;
  int _staleTicks = 0;
  bool _staleZeroSent = false;
  int _lastChCount = 2;
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

  /// 切换跟随端点（状态层选中端点变化时经 isolate 命令下发）。
  /// 目标变化即关当前映射，下个 tick 按新块名重开；事件自此带
  /// 新的 endpointId，状态层据此丢弃切换前的迟到事件。
  void setTarget(String endpointId) {
    if (_targetId == endpointId) return;
    _targetId = endpointId;
    _stampWarned = false;
    if (_magicGaveUp) {
      // 旧块魔数不符的放弃只针对旧目标，新目标重新尝试。
      _gaveUp = false;
      _magicGaveUp = false;
    }
    _close();
    dbgLog('apo telemetry: target -> ${endpointId.isEmpty ? '(global)' : endpointId}');
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
    _staleTicks = 0;
    _staleZeroSent = false;
    _lastChCount = 2;
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
      final blockName =
          _targetId.isEmpty ? _apoTelemetryName : apoTelemetryNameFor(_targetId);
      final name = blockName.toNativeUtf16();
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
        _magicGaveUp = true;
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
      if (_absentTicks == 300) {
        // 第十二轮 B2：缺席满 30s 上报状态层监督——「附加全绿但
        // audiodg 内 APO 永不运行」这类静默失效（五~九轮的 ACL/
        // 旧 DLL 类病灶）此前只有一行日志，状态层无从通知用户。
        // 每缺席周期只报一次（_absentTicks 连续计数，块打开即
        // 清零，下一周期重新计）。
        _send?.call({'evt': 'apotelemetry', 'absent': true, 'endpointId': _targetId});
      }
      return;
    }
    _absentTicks = 0;
    if (_targetId.isNotEmpty) {
      // 分端点块身份复核（v7 身份段 @字节 1472，UTF-16 80 字）：
      // 版本不足或盖章与目标不符 → 本 tick 不消费（块名哈希碰撞
      // 或陈旧块冒名的兜底；正常路径恒相符）。
      final u16 = _view!.cast<Uint16>();
      var stampOk = _u32![1] >= 7;
      if (stampOk) {
        final units = <int>[];
        for (var i = 0; i < 80; i++) {
          final cu = u16[736 + i];
          if (cu == 0) break;
          units.add(cu);
        }
        stampOk = String.fromCharCodes(units) == _targetId;
      }
      if (!stampOk) {
        if (!_stampWarned) {
          _stampWarned = true;
          dbgLog('apo telemetry: per-endpoint block identity mismatch '
              '(target=$_targetId ver=${_u32![1]}), not consuming');
        }
        return;
      }
    }
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
      // telemetry v6 生效值回读（第三十五轮）：先落局部变量再进
      // 事件字面量（AOT 纪律，同段下方注记）。
      final effOk = u32[1] >= 6 && u32[kApoTelemetryEffU32 + 2] == 1;
      final effMode = effOk ? u32[kApoTelemetryEffU32] : -1;
      final effFill = effOk ? u32[kApoTelemetryEffU32 + 1] : -1;
      // 声道决议三段回显（第四十七轮 S3，v2 预留位 144..146，
      // 不挑版本：旧宿主恒 0 = 未知）。
      final engChHost = u32[144];
      final userChSeen = u32[145];
      final engChEngine = u32[146];
      _send?.call({
        'evt': 'apotelemetry',
        'endpointId': _targetId,
        'seat': seat == 1,
        'fault': faultNow != 0,
        'rate': u32[4],
        'channels': u32[5],
        'applied': u32[6],
        'taken': u32[8],
        'loadStage': loadStage,
        'loadErr': loadErr,
        'effMode': effMode,
        'effFill': effFill,
        'engChHost': engChHost,
        'userChSeen': userChSeen,
        'engChEngine': engChEngine,
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
    if (seq == _lastSeq) {
      // 第二十二轮：流停止后 APO worker 不再推进 updateSeq
      // （telemetry 是状态面非流，worker 只在有新 viz 帧时写块），
      // 读者若随之沉默，状态层永远停在最后一帧——主页频谱残留
      // 热谱、活动门的无声迟滞只能由新帧武装（2026-11-13 开发机
      // 实测）。冻结满 500ms 补发一帧清零 viz（每冻结周期一
      // 次），让状态层按无声口径收口；seq 恢复推进即复位。
      if (_lastSeq >= 0 && !_staleZeroSent && ++_staleTicks >= 5) {
        _staleZeroSent = true;
        _emitStaleZeroViz();
      }
      return;
    }
    _lastSeq = seq;
    _staleTicks = 0;
    _staleZeroSent = false;
    // 全面复审 S2（APO-11）：telemetry v4 及以前逐声道数据只有 L/R
    // 两路——按立体声口径上报（chCount=2），不得按流声道数合成假
    // 逐声道数据（旧行为 ch3+ 恒 -90 假静音，已废）。
    // 多声道计划 W3（telemetry v5）：块尾（u32[186] 起）带帧
    // channelCount / channelLevels / stageChLevels[21][8]，按真实
    // 声道数展开，口径与进程内 FFI 帧一致（stageCh 21×chCount）。
    final rawChCount = u32[1] >= 5 ? u32[186] : 0;
    final chCount =
        (rawChCount == 4 || rawChCount == 6 || rawChCount == 8)
            ? rawChCount
            : 2;
    final levelL = f32[14];
    final levelR = f32[15];
    final spectrum = List<double>.generate(32, (i) => f32[16 + i]);
    // telemetry v2 起带真实分级回传（处理流显示）；v1 块保持静默
    // 占位（旧 APO DLL 与新 App 混跑的过渡形态）。
    final hasStage = u32[1] >= 2;
    // 输入门控卡 IN/OUT 电平（2026-11-12 补漏）：进程内事件由
    // FFI 帧 stageLevels[12]/[13] 派生（gate 输入/输出级），
    // APO 事件此前未带这四键 → 状态层恒不更新、卡上电平恒空。
    // telemetry 的 stageLevels 与引擎同一布局，直接同口径派生。
    // 必须先落局部变量再进事件字面量：内联三元 f32[...] 写法
    // 会触发 Dart AOT 编译器崩溃（flow_graph untagged->tagged，
    // 开发机二分定位 2026-11-12）。
    final inputInL = hasStage ? f32[80 + 12] : -120.0;
    final inputInR = hasStage ? f32[112 + 12] : -120.0;
    final inputOutL = hasStage ? f32[80 + 13] : -120.0;
    final inputOutR = hasStage ? f32[112 + 13] : -120.0;
    // v5 逐声道表先落局部变量再进事件字面量（同上 AOT 纪律）：
    // channelLevels 在 f32[187..]、stageChLevels 在 f32[195..]
    // （[21][8] 行主序，取前 chCount 列拼 21×chCount stage-major）。
    final chLevels = chCount == 2
        ? <double>[levelL, levelR]
        : List<double>.generate(chCount, (i) => f32[187 + i]);
    final stageCh = chCount == 2
        ? List<double>.filled(32 * 2, -90.0)
        : List<double>.generate(21 * chCount, (idx) {
            final s = idx ~/ chCount;
            final c = idx % chCount;
            return f32[195 + s * 8 + c];
          });
    _lastChCount = chCount;
    _send?.call({
      'evt': 'viz',
      'backend': 'sysapo',
      'endpointId': _targetId,
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
      'inputInL': inputInL,
      'inputInR': inputInR,
      'inputOutL': inputOutL,
      'inputOutR': inputOutR,
      'chCount': chCount,
      'chLevels': chLevels,
      'stageCh': stageCh,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
  }

  /// 冻结补帧：与正常 viz 事件同形状、全部电平/频谱归零（动机见
  /// _tick 的 seq 门注记）。列表先落局部变量再进字面量（AOT
  /// 纪律，同正常帧路径）；声道数沿用最后一帧真值，形状不断裂。
  void _emitStaleZeroViz() {
    final chCount = _lastChCount;
    final chLevels = List<double>.filled(chCount, -120.0);
    final stageCh = chCount == 2
        ? List<double>.filled(32 * 2, -90.0)
        : List<double>.filled(21 * chCount, -120.0);
    _send?.call({
      'evt': 'viz',
      'backend': 'sysapo',
      'endpointId': _targetId,
      'spectrum': List<double>.filled(32, 0.0),
      'eqIn': List<double>.filled(32, 0.0),
      'l': -120.0,
      'r': -120.0,
      'stageL': List<double>.filled(32, -90.0),
      'stageR': List<double>.filled(32, -90.0),
      'inputInL': -120.0,
      'inputInR': -120.0,
      'inputOutL': -120.0,
      'inputOutR': -120.0,
      'chCount': chCount,
      'chLevels': chLevels,
      'stageCh': stageCh,
      'ts': DateTime.now().millisecondsSinceEpoch,
    });
    dbgLog('apo telemetry: seq frozen, emitted zeroed viz frame');
  }
}

const String _apoPluginsName = 'Global\\AuraDSP_ApoPlugins';

/// 插件块发布者（Part I Q2，计划书 D2/D3）：生产实例只保留 APO
/// 模式激活信号与明确的插件“不支持”结果，绝不打开、创建或写入共享块。
/// [trustedTestOnly] 与 [mappingName] 仅供受控测试使用独立 fixture；
/// 生产构造调用不得启用，原生可信测试宿主仍有独立编译宏边界。
class ApoPluginPublisher {
  ApoPluginPublisher({
    this.trustedTestOnly = false,
    String? mappingName,
  }) : _mappingName = mappingName ?? _apoPluginsName;

  final bool trustedTestOnly;
  final String _mappingName;

  bool active = false;

  Pointer<Void>? _mapping;
  Pointer<Uint8>? _view;
  Pointer<Uint32>? _u32;
  bool _permFail = false;
  bool _loggedAbsent = false;
  int _seq = 0;

  final List<_ApoPluginSlotPub> _pub =
      List.generate(kApoPluginSlots, (_) => _ApoPluginSlotPub());

  /// 原始插件路径 → 中转路径缓存（N1 围栏：块里只写中转路径）。
  /// 只缓存成功结果；失败每次同步重试（源文件补齐后可自愈）。
  final Map<String, String> _transitCache = {};

  /// 中转复制在途任务（原始路径 → 任务）。复制是异步 IO（用户
  /// 裁定 2026-11-23）：同步复制大 bundle 会冻结隔离体事件循环
  /// （音频泵与命令处理同循环），且不在任何加载动画窗口内。
  final Map<String, Future<ApoPluginTransitResult>> _transitTasks = {};

  /// 中转失败过的原始路径：同步路径不再自动重试（避免每个轮询
  /// 周期重复整树复制一个坏 bundle）；用户显式加载走
  /// [preparePluginTransit] 时清记重试（新意图）。
  final Set<String> _transitFailed = {};

  /// 中转任务落定（成功/失败）后的回调：隔离体接
  /// syncApoPlugins——成功则把刚落定的路径补发进块，失败则
  /// 维持 withholding 口径收口。
  void Function()? onTransitSettled;

  /// 显式加载前的中转准备（pluginSlotLoad 在 APO 激活时调用）：
  /// 返回中转结果（缓存命中即刻返回）；失败携带用户可见原因。调用方在
  /// 槽位忙态（加载动画）窗口内 await 本方法——复制全程被加载
  /// 动画包含，终态事件在复制落定后才发（用户裁定 2026-11-23）。
  Future<ApoPluginTransitResult> preparePluginTransit(String path) {
    final hit = _transitCache[path];
    if (hit != null && hit.isNotEmpty) {
      return Future.value(ApoPluginTransitResult(path: hit));
    }
    _transitFailed.remove(path);
    return _kickTransit(path);
  }

  /// 启动（或复用在途的）异步中转任务；落定后更新缓存/失败集
  /// 并回调 [onTransitSettled] 触发补同步。
  Future<ApoPluginTransitResult> _kickTransit(String path) {
    final running = _transitTasks[path];
    if (running != null) return running;
    final task = ApoTransit.transitPluginPathForAsync(path).then((result) {
      _transitTasks.remove(path);
      final transitPath = result.path;
      if (transitPath != null && transitPath.isNotEmpty) {
        _transitCache[path] = transitPath;
        _transitFailed.remove(path);
      } else {
        _transitFailed.add(path);
      }
      onTransitSettled?.call();
      return result;
    }).onError((e, st) {
      // ApoTransit 内部已吞错；此处只防契约外异常把任务挂死
      // （在途表残留会让该路径永不重试），仍经同一结果通道收口。
      _transitTasks.remove(path);
      _transitFailed.add(path);
      dbgLog('apo plugin publisher: transit task error for $path: $e');
      onTransitSettled?.call();
      return const ApoPluginTransitResult(errorMessage: '插件中转失败');
    });
    _transitTasks[path] = task;
    return task;
  }

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
    // 生产发布者彻底停用：不得打开、创建或写入插件块。仅显式受控
    // 测试实例保留原 fixture 写入路径；生产 APO 宿主本身仍失败关闭。
    if (!trustedTestOnly) return false;
    if (_view != null) return true;
    if (_permFail) return false;
    try {
      final w = _apoWin32();
      final name = _mappingName.toNativeUtf16();
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
  /// 本轮同步后插件块实际引用的中转路径集合（孤儿回收 keep
  /// 集）：每轮 syncFromMirror 按当前镜像重建。
  final Set<String> currentTransitPaths = {};

  void syncFromMirror(List<PluginSlotCfg> mirror,
      {required bool chainEnabled, required bool pdcEnabled}) {
    if (!active) return;
    if (!_ensure()) return;
    currentTransitPaths.clear();
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
      // N1 中转围栏（2026-11-22）：块里只下发中转根下的插件路径
      // （宿主 ApoEngineHost 同口径校验）。中转失败 → 本槽按未占
      // 用下发（空路径），绝不把原始路径写进块里假装可用——与
      // 文件效果中转失败口径一致；UI 与配置仍保留原始路径。
      final raw =
          (cfg != null && cfg.loaded && cfg.path.isNotEmpty) ? cfg : null;
      var path = '';
      if (raw != null) {
        final t = _transitCache[raw.path];
        if (t != null) {
          path = t;
          currentTransitPaths.add(t);
        } else if (!_transitFailed.contains(raw.path)) {
          // 异步中转（2026-11-23）：本轮先按未占用下发，复制在
          // 后台进行；落定回调 onTransitSettled 触发补同步把
          // 路径补发进块。失败路径进 _transitFailed 后不再自动
          // 重试（显式加载经 preparePluginTransit 清记重试）。
          _kickTransit(raw.path);
        }
        if (path.isEmpty && _transitFailed.contains(raw.path)) {
          dbgLog('apo plugin publisher: transit failed, slot $slot '
              'withheld: ${raw.path}');
        }
      }
      final occupied = path.isNotEmpty;
      final id = occupied ? raw!.id : '';
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
        p.lastState = null;
        p.baseline = null;
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
      final stage = occupied ? raw!.stage : p.stage;
      final mask = occupied ? raw!.channels : p.mask;
      final bypass = occupied ? (raw!.bypass ? 1 : 0) : p.bypass;
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
    p.lastState = List<int>.of(bytes);
    _writeSlotHeader(slot);
    _endWrite();
    dbgLog('apo plugin publisher: state slot=$slot '
        'bytes=${bytes.length} gen=${p.stateGen}');
    return true;
  }

  /// 自动应用去重发布（三动作引擎，2026-11-12）：与最近一次
  /// 已发布字节完全一致时不落块、不推进 stateGen 并返回
  /// false（无变化）；有变化则照常发布并返回 true。没有这层
  /// 去重，300ms 轮询会让 APO 侧以同等频率反复重载同一状态。
  bool publishSlotStateIfChanged(int slot, List<int> bytes) {
    if (!active || slot < 0 || slot >= kApoPluginSlots) return false;
    if (bytes.length > kApoPluginStateBytes) return false;
    final last = _pub[slot].lastState;
    if (last != null && last.length == bytes.length) {
      var same = true;
      for (var i = 0; i < bytes.length; i++) {
        if (last[i] != bytes[i]) {
          same = false;
          break;
        }
      }
      if (same) return false;
    }
    return publishSlotState(slot, bytes);
  }

  /// 编辑器会话基线（恢复动作）：编辑器打开时由 isolate 快照
  /// 当前影子状态；恢复时灌回影子并强制发布。仅存发布器内存，
  /// 不落盘；插件身份变化即作废（syncFromMirror）。
  void setBaseline(int slot, List<int> bytes) {
    if (slot < 0 || slot >= kApoPluginSlots) return;
    _pub[slot].baseline = List<int>.of(bytes);
  }

  List<int>? baselineOf(int slot) =>
      (slot < 0 || slot >= kApoPluginSlots) ? null : _pub[slot].baseline;
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
  // 三动作引擎（2026-11-12）：最近一次已发布状态字节（自动
  // 应用去重比对用）与编辑器会话基线（恢复动作用）。槽位身
  // 份变化时一并作废（见 syncFromMirror 的 identityChanged）。
  List<int>? lastState;
  List<int>? baseline;
}
