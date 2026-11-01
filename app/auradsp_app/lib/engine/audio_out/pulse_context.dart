// pulse_context.dart —— Linux PulseAudio 服务端管理（异步 API 的同步门面）。
//
// 用途（ADR-012 D-5 的 virtual / driver 两模式）：
//   - virtual：查/加载 module-null-sink 虚拟设备（sink 名 auradsp_virtual）；
//   - driver：查 snd-aloop 在 PulseAudio 侧呈现的采集源、读 /proc/asound/cards
//     判断内核模块是否加载；
//   - 通用：默认 sink 查询（防「默认输出=虚拟 sink」的自反馈环）。
//
// ADR-012 定的口径：走 libpulse 的 pa_context，不 fork pactl 等外部命令。
// pa_context 是回调式异步 API；本类用 pa_mainloop 做阻塞 iterate，把它包成
// 同步门面——只在「模式切换」这种用户节奏的时刻调用（音频 isolate 的命令
// 处理里），绝不在实时泵路径上出现。每次调用开一条短命 context，用完即断。
//
// 纯函数部分（asound 卡表解析、loopback 源名匹配）无 FFI 依赖，供单测直测。
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../debug_log.dart';
import '../native_library_loader.dart';

/* ---------------- 纯逻辑（可单测） ---------------- */

/// /proc/asound/cards 内容里是否含 Loopback 声卡（snd-aloop 已加载）。
bool asoundCardsHasLoopback(String cardsContent) =>
    cardsContent.contains('Loopback');

/// PulseAudio 采集源名是否对应 snd-aloop 声卡。
/// 原生 PA 的 ALSA 源名形如 alsa_input.platform-snd_aloop.0.analog-stereo，
/// PipeWire 兼容层形如 alsa_input.pci-…Loopback…；两种命名都按关键字匹配。
bool isLoopbackSourceName(String name) {
  final n = name.toLowerCase();
  return n.contains('loopback') || n.contains('snd_aloop');
}

/* ---------------- pa_context FFI ---------------- */

// pa_context_state: 0 UNCONNECTED 1 CONNECTING 2 AUTHORIZING
//                   3 SETTING_NAME 4 READY 5 FAILED 6 TERMINATED
const _paContextReady = 4;
const _paContextFailed = 5;
const _paContextTerminated = 6;
// pa_operation_state: 0 RUNNING 1 DONE 2 CANCELLED（本类以回调标志判完成）

typedef _MainloopNewNative = Pointer<Void> Function();
typedef _MainloopGetApiNative = Pointer<Void> Function(Pointer<Void>);
typedef _MainloopIterateNative = Int32 Function(Pointer<Void>, Int32,
    Pointer<Int32>);
typedef _MainloopFreeNative = Void Function(Pointer<Void>);
typedef _ContextNewNative = Pointer<Void> Function(
    Pointer<Void>, Pointer<Utf8>);
typedef _ContextConnectNative = Int32 Function(
    Pointer<Void>, Pointer<Utf8>, Uint32, Pointer<Void>);
typedef _ContextGetStateNative = Int32 Function(Pointer<Void>);
typedef _ContextSetStateCallbackNative = Void Function(
    Pointer<Void>, Pointer<NativeFunction<_StateCbNative>>, Pointer<Void>);
typedef _StateCbNative = Void Function(Pointer<Void>, Pointer<Void>);
typedef _ContextInfoListNative = Pointer<Void> Function(Pointer<Void>,
    Pointer<NativeFunction<_InfoCbNative>>, Pointer<Void>);
typedef _InfoCbNative = Void Function(
    Pointer<Void>, Pointer<Void>, Int32, Pointer<Void>);
typedef _ContextServerInfoNative = Pointer<Void> Function(
    Pointer<Void>, Pointer<NativeFunction<_ServerInfoCbNative>>, Pointer<Void>);
typedef _ServerInfoCbNative = Void Function(
    Pointer<Void>, Pointer<Void>, Pointer<Void>);
typedef _ContextLoadModuleNative = Pointer<Void> Function(
    Pointer<Void>,
    Pointer<Utf8>,
    Pointer<Utf8>,
    Pointer<NativeFunction<_LoadModuleCbNative>>,
    Pointer<Void>);
typedef _LoadModuleCbNative = Void Function(
    Pointer<Void>, Uint32, Pointer<Void>);
typedef _OperationGetStateNative = Int32 Function(Pointer<Void>);
typedef _OperationUnrefNative = Void Function(Pointer<Void>);
typedef _ContextDisconnectNative = Void Function(Pointer<Void>);
typedef _ContextUnrefNative = Void Function(Pointer<Void>);
typedef _StrerrorNative = Pointer<Utf8> Function(Int32);
typedef _ContextErrnoNative = Int32 Function(Pointer<Void>);

class _PulseMainLib {
  _PulseMainLib._(this._lib);

  final DynamicLibrary _lib;

  late final mainloopNew =
      _lib.lookupFunction<_MainloopNewNative, Pointer<Void> Function()>(
          'pa_mainloop_new');
  late final mainloopGetApi = _lib.lookupFunction<_MainloopGetApiNative,
      Pointer<Void> Function(Pointer<Void>)>('pa_mainloop_get_api');
  late final mainloopIterate = _lib.lookupFunction<_MainloopIterateNative,
      int Function(Pointer<Void>, int, Pointer<Int32>)>('pa_mainloop_iterate');
  late final mainloopFree =
      _lib.lookupFunction<_MainloopFreeNative, void Function(Pointer<Void>)>(
          'pa_mainloop_free');
  late final contextNew = _lib.lookupFunction<_ContextNewNative,
      Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>)>('pa_context_new');
  late final contextConnect = _lib.lookupFunction<_ContextConnectNative,
      int Function(Pointer<Void>, Pointer<Utf8>, int, Pointer<Void>)>(
      'pa_context_connect');
  late final contextGetState =
      _lib.lookupFunction<_ContextGetStateNative, int Function(Pointer<Void>)>(
          'pa_context_get_state');
  late final contextSetStateCallback = _lib.lookupFunction<
      _ContextSetStateCallbackNative,
      void Function(Pointer<Void>,
          Pointer<NativeFunction<_StateCbNative>>, Pointer<Void>)>(
      'pa_context_set_state_callback');
  late final contextGetSinkInfoList = _lib.lookupFunction<
      _ContextInfoListNative,
      Pointer<Void> Function(Pointer<Void>,
          Pointer<NativeFunction<_InfoCbNative>>, Pointer<Void>)>(
      'pa_context_get_sink_info_list');
  late final contextGetSourceInfoList = _lib.lookupFunction<
      _ContextInfoListNative,
      Pointer<Void> Function(Pointer<Void>,
          Pointer<NativeFunction<_InfoCbNative>>, Pointer<Void>)>(
      'pa_context_get_source_info_list');
  late final contextGetServerInfo = _lib.lookupFunction<
      _ContextServerInfoNative,
      Pointer<Void> Function(Pointer<Void>,
          Pointer<NativeFunction<_ServerInfoCbNative>>, Pointer<Void>)>(
      'pa_context_get_server_info');
  late final contextLoadModule = _lib.lookupFunction<_ContextLoadModuleNative,
      Pointer<Void> Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>,
          Pointer<NativeFunction<_LoadModuleCbNative>>, Pointer<Void>)>(
      'pa_context_load_module');
  late final operationGetState = _lib.lookupFunction<
      _OperationGetStateNative, int Function(Pointer<Void>)>(
      'pa_operation_get_state');
  late final operationUnref =
      _lib.lookupFunction<_OperationUnrefNative, void Function(Pointer<Void>)>(
          'pa_operation_unref');
  late final contextDisconnect = _lib.lookupFunction<_ContextDisconnectNative,
      void Function(Pointer<Void>)>('pa_context_disconnect');
  late final contextUnref =
      _lib.lookupFunction<_ContextUnrefNative, void Function(Pointer<Void>)>(
          'pa_context_unref');
  late final contextErrno =
      _lib.lookupFunction<_ContextErrnoNative, int Function(Pointer<Void>)>(
          'pa_context_errno');
  late final strerror =
      _lib.lookupFunction<_StrerrorNative, Pointer<Utf8> Function(int)>(
          'pa_strerror');

  static _PulseMainLib load() {
    return _PulseMainLib._(NativeLibraryLoader.openFirst(
        const ['libpulse.so.0', 'libpulse.so'],
        what: 'libpulse'));
  }

  String errorText(int code) {
    try {
      return strerror(code).toDartString();
    } catch (_) {
      return 'pa error $code';
    }
  }
}

/// 一次 context 会话：连接、跑若干 operation、断开。同步阻塞，带总时限。
class _Session {
  _Session(this.lib);

  final _PulseMainLib lib;
  Pointer<Void> _mainloop = nullptr;
  Pointer<Void> _context = nullptr;
  final _stateCell = malloc<Int32>()..value = 0;
  late final NativeCallable<_StateCbNative> _stateCb =
      NativeCallable<_StateCbNative>.isolateLocal(_onState);

  void _onState(Pointer<Void> ctx, Pointer<Void> userdata) {
    _stateCell.value = lib.contextGetState(ctx);
  }

  void open({Duration timeout = const Duration(seconds: 5)}) {
    _mainloop = lib.mainloopNew();
    if (_mainloop == nullptr) throw StateError('pa_mainloop_new failed');
    final api = lib.mainloopGetApi(_mainloop);
    final name = 'AuraDSP'.toNativeUtf8();
    try {
      _context = lib.contextNew(api, name);
    } finally {
      malloc.free(name);
    }
    if (_context == nullptr) throw StateError('pa_context_new failed');
    lib.contextSetStateCallback(_context, _stateCb.nativeFunction, nullptr);
    if (lib.contextConnect(_context, nullptr, 0, nullptr) < 0) {
      throw StateError(
          'pa_context_connect failed: ${lib.errorText(lib.contextErrno(_context))}');
    }
    final deadline = DateTime.now().add(timeout);
    while (true) {
      final st = _stateCell.value;
      if (st == _paContextReady) return;
      if (st == _paContextFailed || st == _paContextTerminated) {
        throw StateError(
            'pa_context not ready (state=$st): ${lib.errorText(lib.contextErrno(_context))}');
      }
      if (DateTime.now().isAfter(deadline)) {
        throw StateError('pa_context connect timeout');
      }
      lib.mainloopIterate(_mainloop, 1, nullptr);
    }
  }

  /// 跑一个异步 operation 直到完成/失败；[pump] 在每次 iterate 后被调。
  void runOperation(Pointer<Void> op, bool Function() isDone,
      {Duration timeout = const Duration(seconds: 5)}) {
    if (op == nullptr) {
      throw StateError(
          'pa operation rejected: ${lib.errorText(lib.contextErrno(_context))}');
    }
    final deadline = DateTime.now().add(timeout);
    try {
      while (!isDone()) {
        if (lib.operationGetState(op) != 0 /* RUNNING */) break;
        if (DateTime.now().isAfter(deadline)) {
          throw StateError('pa operation timeout');
        }
        lib.mainloopIterate(_mainloop, 1, nullptr);
      }
    } finally {
      lib.operationUnref(op);
    }
  }

  Pointer<Void> get context => _context;

  void close() {
    if (_context != nullptr) {
      lib.contextDisconnect(_context);
      lib.contextUnref(_context);
      _context = nullptr;
    }
    if (_mainloop != nullptr) {
      lib.mainloopFree(_mainloop);
      _mainloop = nullptr;
    }
    _stateCb.close();
    malloc.free(_stateCell);
  }
}

/* ---------------- 服务 ---------------- */

class PulseContextService {
  static const String virtualSinkName = 'auradsp_virtual';
  // 描述只能是无空格 token：PA 模块参数解析器对 sink_properties 内层
  // 引号的转义口径与直觉相反——带引号的 "AuraDSP Virtual" 被服务端以
  // invalid index 拒绝，裸 token 通过（2026-11-01 pa_context 探针实测）。
  static const String virtualSinkDescription = 'AuraDSP-Virtual';
  static String get virtualMonitorName => '$virtualSinkName.monitor';

  _PulseMainLib? _libField;
  _PulseMainLib get _lib => _libField ??= _PulseMainLib.load();

  /// 在一个会话里收集 sink/source 名列表（info 结构首字段即 name）。
  List<String> _listNames({required bool sinks}) {
    final session = _Session(_lib)..open();
    final names = <String>[];
    final doneCell = malloc<Int32>()..value = 0;
    final cb = NativeCallable<_InfoCbNative>.isolateLocal(
        (Pointer<Void> ctx, Pointer<Void> info, int eol, Pointer<Void> ud) {
      if (eol != 0) {
        doneCell.value = 1;
        return;
      }
      if (info != nullptr) {
        final namePtr = info.cast<Pointer<Utf8>>().value;
        if (namePtr != nullptr) names.add(namePtr.toDartString());
      }
    });
    try {
      final op = sinks
          ? _lib.contextGetSinkInfoList(
              session.context, cb.nativeFunction, nullptr)
          : _lib.contextGetSourceInfoList(
              session.context, cb.nativeFunction, nullptr);
      session.runOperation(op, () => doneCell.value == 1);
    } finally {
      cb.close();
      malloc.free(doneCell);
      session.close();
    }
    return names;
  }

  List<String> sinkNames() => _listNames(sinks: true);
  List<String> sourceNames() => _listNames(sinks: false);

  bool virtualSinkPresent() => sinkNames().contains(virtualSinkName);

  /// 默认 sink 名（pa_server_info 布局：4 个指针(32B) + pa_sample_spec
  /// (12B) 后，指针成员按 8B 对齐补齐到偏移 48 处为 default_sink_name）。
  String? defaultSinkName() {
    final session = _Session(_lib)..open();
    final doneCell = malloc<Int32>()..value = 0;
    String? result;
    final cb = NativeCallable<_ServerInfoCbNative>.isolateLocal(
        (Pointer<Void> ctx, Pointer<Void> info, Pointer<Void> ud) {
      try {
        if (info != nullptr) {
          final p = (info.cast<Uint8>() + 48).cast<Pointer<Utf8>>().value;
          if (p != nullptr) result = p.toDartString();
        }
      } catch (_) {
        // 结构偏移异常时静默放弃（仅用于防环警告，不值得冒崩溃风险）。
      }
      doneCell.value = 1;
    });
    try {
      final op =
          _lib.contextGetServerInfo(session.context, cb.nativeFunction, nullptr);
      session.runOperation(op, () => doneCell.value == 1);
    } finally {
      cb.close();
      malloc.free(doneCell);
      session.close();
    }
    return result;
  }

  /// 确保虚拟 sink 存在：缺失则 pa_context_load_module 加载
  /// module-null-sink 并复查。返回最终是否存在。
  bool ensureVirtualSink() {
    if (virtualSinkPresent()) return true;
    final session = _Session(_lib)..open();
    final idxCell = malloc<Uint32>()..value = 0xFFFFFFFF;
    final doneCell = malloc<Int32>()..value = 0;
    final cb = NativeCallable<_LoadModuleCbNative>.isolateLocal(
        (Pointer<Void> ctx, int idx, Pointer<Void> ud) {
      idxCell.value = idx;
      doneCell.value = 1;
    });
    final modName = 'module-null-sink'.toNativeUtf8();
    final modArgs =
        'sink_name=$virtualSinkName sink_properties=device.description=$virtualSinkDescription'
            .toNativeUtf8();
    try {
      final op = _lib.contextLoadModule(
          session.context, modName, modArgs, cb.nativeFunction, nullptr);
      session.runOperation(op, () => doneCell.value == 1);
      dbgLog('PULSE module-null-sink load idx=${idxCell.value}');
    } finally {
      malloc.free(modName);
      malloc.free(modArgs);
      cb.close();
      malloc.free(idxCell);
      malloc.free(doneCell);
      session.close();
    }
    return virtualSinkPresent();
  }

  /// snd-aloop 采集源（PA 侧名字）；不存在返回 null。
  String? findLoopbackSource() {
    for (final n in sourceNames()) {
      if (isLoopbackSourceName(n)) return n;
    }
    return null;
  }

  /// snd-aloop 内核模块是否已加载（/proc/asound/cards 本地真值）。
  /// 本文件即 Linux 平台层，直接读 procfs（与 debug_log 读文件同性质）。
  bool asoundLoopbackLoaded() {
    try {
      return asoundCardsHasLoopback(File('/proc/asound/cards').readAsStringSync());
    } catch (_) {
      return false;
    }
  }
}
