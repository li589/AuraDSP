// bridge_manager.dart — 桥注册表 + 生命周期 + 统一桥契约（DSP↔桥解耦 P1）
//
// 目标（docs/10-架构/桥惰性加载与全后端静音门控及DSP解耦落地方案-2026-10-29.md）：
//   1. 「用到哪个后端才启用哪个」：注册表按 id 惰性 load，未选中的桥全程不 open；
//   2. 三桥同构面收敛为 AudioBridgeCommon，isolate 不再按后端写三份分支；
//   3. 桥专属面（start 参数、VB 掩码等）仍留在各自绑定类，避免为统一而统一。
//
// 驻留策略：Dart 侧没有 FreeLibrary/dlclose 能力，且桥会持有第三方 DLL
// （VoicemeeterRemote64.dll / ASIO 驱动等）引用——stop 后仅停会话、DLL 驻留
// 是唯一安全策略（与方案 §2.1 默认一致；`AURADSP_BRIDGE_UNLOAD` 无法从 Dart
// 实现，不做半吊子开关）。
import 'dart:convert';
import 'dart:ffi';

import 'package:ffi/ffi.dart';

import '../platform/platform_profile.dart';
import 'auradsp_ffi.dart' show VizFrame;
import 'audio_abridge.dart';
import 'audio_bridge.dart' show abStart;
import 'audio_vaio_bridge.dart';
import 'audio_vbridge.dart';
import 'bridge_plugin_ffi.dart';
import 'debug_log.dart';

import '../core/error_sink.dart';

/// 三桥（VM/ASIO/VAIO）及未来平台桥的最小公共控制面。
///
/// 只收录「语义完全同构」的导出；detect/start 的参数与返回形状各桥不同，
/// 留在各自绑定类里。
abstract interface class AudioBridgeCommon {
  BridgePluginFfi get plugin;

  Map<String, dynamic>? status();

  int stop();

  int setParam(String id, {required bool isFloat, required double value});

  int setParamStr(String id, String text);

  int setBypass(bool on);

  Map<String, dynamic>? vizRead();

  int testStart(int kind,
      {Pointer<Float>? pcm, int frames, int ch, int rate});

  int testStop();

  int? getIntParam(String id);

  String? getParamStr(String id);
}

typedef _DetectC = Int32 Function(Pointer<Utf8>, Int32);
typedef _DetectDart = int Function(Pointer<Utf8>, int);
typedef _StopC = Int32 Function();
typedef _StopDart = int Function();
typedef _StatusC = Int32 Function(Pointer<Utf8>, Int32);
typedef _StatusDart = int Function(Pointer<Utf8>, int);
typedef _SetParamC = Int32 Function(Pointer<Utf8>, Int32, Pointer<Void>);
typedef _SetParamDart = int Function(Pointer<Utf8>, int, Pointer<Void>);
typedef _VizReadC = Int32 Function(Pointer<Void>, Int32);
typedef _VizReadDart = int Function(Pointer<Void>, int);
typedef _TestStartC = Int32 Function(Int32, Pointer<Float>, Int32, Int32, Int32);
typedef _TestStartDart = int Function(int, Pointer<Float>, int, int, int);
typedef _TestStopC = Int32 Function();
typedef _TestStopDart = int Function();
typedef _BypassC = Int32 Function(Int32);
typedef _BypassDart = int Function(int);
typedef _SetParamStrC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _SetParamStrDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);
typedef _GetParamC = Int32 Function(Pointer<Utf8>, Int32, Pointer<Void>);
typedef _GetParamDart = int Function(Pointer<Utf8>, int, Pointer<Void>);
typedef _GetParamStrC = Int32 Function(Pointer<Utf8>, Pointer<Utf8>, Int32);
typedef _GetParamStrDart = int Function(Pointer<Utf8>, Pointer<Utf8>, int);

/// 三桥共用 FFI 实现：公共面按常量 `ab_*` 绑定（过渡期清理后唯一导出面），
/// 方法体与旧三份拷贝逐字同构。绑定类只保留「桥专属导出」。
class AudioBridgeCore {
  AudioBridgeCore(this.dylib, this.prefix, {String? logTag})
      : logTag = logTag ?? '$prefix-ffi';

  final DynamicLibrary dylib;

  /// 旧前缀（'vb' / 'asio' / 'vaio'）：桥专属导出 + 插件槽面。
  final String prefix;

  /// 统一启动（configJson 承载桥专属宿主参数）。
  int start(String engineDll, String params, String configJson) =>
      abStart(dylib, engineDll, params, configJson);

  /// 错误/异常节流日志 tag（沿用旧值：vb-ffi / ab-ffi / vaio-ffi）。
  final String logTag;

  late final BridgePluginFfi plugin = BridgePluginFfi(dylib, prefix);
  late final _DetectDart _detect =
      dylib.lookupFunction<_DetectC, _DetectDart>('ab_detect');
  late final _StopDart _stop =
      dylib.lookupFunction<_StopC, _StopDart>('ab_stop');
  late final _StatusDart _status =
      dylib.lookupFunction<_StatusC, _StatusDart>('ab_status');
  late final _SetParamDart _setParam =
      dylib.lookupFunction<_SetParamC, _SetParamDart>('ab_set_param');
  late final _VizReadDart _vizRead =
      dylib.lookupFunction<_VizReadC, _VizReadDart>('ab_viz_read');
  late final _TestStartDart _testStart = dylib
      .lookupFunction<_TestStartC, _TestStartDart>('ab_test_start');
  late final _TestStopDart _testStop =
      dylib.lookupFunction<_TestStopC, _TestStopDart>('ab_test_stop');
  late final _BypassDart _bypass =
      dylib.lookupFunction<_BypassC, _BypassDart>('ab_bypass');
  late final _SetParamStrDart _setParamStr = dylib.lookupFunction<
      _SetParamStrC, _SetParamStrDart>('ab_set_param_str');
  late final _GetParamDart _getParam =
      dylib.lookupFunction<_GetParamC, _GetParamDart>('ab_get_param');
  late final _GetParamStrDart _getParamStr = dylib.lookupFunction<
      _GetParamStrC, _GetParamStrDart>('ab_get_param_str');

  /// 原始 detect JSON（各桥自行解释形状）。
  Map<String, dynamic>? detectJson(int cap) {
    final buf = malloc<Uint8>(cap).cast<Utf8>();
    try {
      final n = _detect(buf, cap);
      if (n <= 0) return null;
      return jsonDecode(buf.toDartString(length: n)) as Map<String, dynamic>?;
    } catch (e, st) {
      swallowThrottled(e, st, logTag);
      return null;
    } finally {
      malloc.free(buf);
    }
  }

  int stop() => _stop();

  Map<String, dynamic>? statusJson(int cap) {
    final buf = malloc<Uint8>(cap).cast<Utf8>();
    try {
      final n = _status(buf, cap);
      if (n <= 0) return null;
      return jsonDecode(buf.toDartString(length: n)) as Map<String, dynamic>?;
    } catch (e, st) {
      swallowThrottled(e, st, logTag);
      return null;
    } finally {
      malloc.free(buf);
    }
  }

  int setParam(String id, {required bool isFloat, required double value}) {
    final idp = id.toNativeUtf8();
    try {
      if (isFloat) {
        final vp = malloc<Float>();
        try {
          vp.value = value;
          return _setParam(idp.cast(), 1, vp.cast());
        } finally {
          malloc.free(vp);
        }
      } else {
        final vp = malloc<Int32>();
        try {
          vp.value = value.toInt();
          return _setParam(idp.cast(), 0, vp.cast());
        } finally {
          malloc.free(vp);
        }
      }
    } finally {
      malloc.free(idp);
    }
  }

  /// 读可视化帧，返回与 isolate viz 事件同形 map（调用方节流）。
  Map<String, dynamic>? vizRead() {
    final buf = malloc<VizFrame>(4);
    try {
      final n = _vizRead(buf.cast(), 4);
      if (n <= 0) return null;
      final fr = (buf + (n - 1)).ref;
      return {
        'spectrum': fr.spectrumToList(),
        'eqIn': fr.eqInSpectrumToList(),
        'l': fr.levelLDbfs,
        'r': fr.levelRDbfs,
        'stageL': fr.stageLevelsLToList(),
        'stageR': fr.stageLevelsRToList(),
        'inputInL': fr.inputLevelInL,
        'inputInR': fr.inputLevelInR,
        'inputOutL': fr.inputLevelOutL,
        'inputOutR': fr.inputLevelOutR,
        // [Phase B 多声道电平] per-channel 遥测（与 isolate 主路径同形）
        'chCount': fr.channelCount,
        'chLevels': fr.channelLevelsToList(),
        'stageCh': fr.stageChLevelsTelemetry(),
        'ts': fr.timestampMs,
        'seq': fr.seq,
      };
    } catch (e, st) {
      swallowThrottled(e, st, logTag);
      return null;
    } finally {
      malloc.free(buf);
    }
  }

  /// 测试注入：kind 1=正弦440 2=粉噪 3=文件（pcm 交织立体声 float32）。
  /// bridge 内拷贝，返回后调用方可释放。
  int testStart(int kind,
      {Pointer<Float>? pcm, int frames = 0, int ch = 2, int rate = 0}) {
    final p = pcm ?? nullptr;
    return _testStart(kind, p, frames, ch, rate);
  }

  int testStop() => _testStop();

  int setBypass(bool on) => _bypass(on ? 1 : 0);

  /// 字符串参数（liveprog.code / arbmag.string）：返回成功 handle 数/0 语义
  /// 由各桥定义，<0=失败。
  int setParamStr(String id, String text) {
    final idp = id.toNativeUtf8();
    final tp = text.toNativeUtf8();
    try {
      return _setParamStr(idp.cast(), tp.cast(), tp.length);
    } finally {
      malloc.free(idp);
      malloc.free(tp);
    }
  }

  /// int 参数回读（group0），失败返回 null。
  int? getIntParam(String id) {
    final idp = id.toNativeUtf8();
    final vp = malloc<Int32>();
    try {
      final rc = _getParam(idp.cast(), 0, vp.cast());
      return rc == 0 ? vp.value : null;
    } catch (e, st) {
      swallowThrottled(e, st, logTag);
      return null;
    } finally {
      malloc.free(idp);
      malloc.free(vp);
    }
  }

  /// 字符串参数回读（group0），失败返回 null。
  String? getParamStr(String id) {
    final idp = id.toNativeUtf8();
    final buf = malloc<Uint8>(256 * 1024 + 1).cast<Utf8>();
    try {
      final n = _getParamStr(idp.cast(), buf, 256 * 1024 + 1);
      if (n <= 0) return null;
      return buf.toDartString(length: n);
    } catch (e, st) {
      swallowThrottled(e, st, logTag);
      return null;
    } finally {
      malloc.free(idp);
      malloc.free(buf);
    }
  }
}

/// 桥注册项：未来平台（Linux/Android/…）新增后端 = 实现契约 + 注册一项，
/// 不动引擎、不动 UI（方案 §4.3）。
class BridgeDesc {
  const BridgeDesc({
    required this.id,
    required this.displayName,
    required this.dllName,
    required this.envVar,
    required this.prefix,
    required this.load,
  });

  /// 稳定标识（'vm' / 'asio' / 'vaio'），命令与事件按它分派。
  final String id;
  final String displayName;

  /// 产品打包名（诊断/文档用；实际候选路径由各绑定类负责）。
  final String dllName;
  final String envVar;

  /// 导出前缀（过渡期；P5 统一 ab_* 后由绑定内部切换）。
  final String prefix;
  final AudioBridgeCommon Function() load;
}

/// 内置三桥。刻意不 const：`load` 是各绑定类的静态方法，避免跨文件常量环。
List<BridgeDesc> builtinBridgeDescs() => [
      BridgeDesc(
        id: 'vm',
        displayName: 'Voicemeeter',
        dllName: PlatformProfile.bridgeLibraryName('vm'),
        envVar: PlatformProfile.bridgeEnvVar('vm'),
        prefix: 'vb',
        load: AuraVmBridge.load,
      ),
      BridgeDesc(
        id: 'asio',
        displayName: 'ASIO',
        dllName: PlatformProfile.bridgeLibraryName('asio'),
        envVar: PlatformProfile.bridgeEnvVar('asio'),
        prefix: 'asio',
        load: AuraAsioBridge.load,
      ),
      BridgeDesc(
        id: 'vaio',
        displayName: 'AuraVAIO',
        dllName: PlatformProfile.bridgeLibraryName('vaio'),
        envVar: PlatformProfile.bridgeEnvVar('vaio'),
        prefix: 'vaio',
        load: AuraVaioBridge.load,
      ),
    ];

/// 桥插件槽会话镜像（path/id/bypass/stage/channels）。
///
/// 桥各自持有独立引擎；Dart 在命令到达时同步记下，桥 start 成功后回放，
/// 桥 stop 后同步回本地引擎。插件内部旋钮值不在镜像内（已知 MVP 限制）。
class PluginSlotCfg {
  bool loaded = false;
  String path = '';
  String id = '';
  bool bypass = false;
  int stage = 3;
  int channels = 0xFF;
}

/// 桥生命周期与互斥的唯一入口（音频 isolate 内使用）。
///
/// - [load]：注册项惰性 load；DLL 驻留（见文件头）。
/// - [switchTo]/[clearActive]/[isActive]：当前真正出声的后端（null = WASAPI
///   本地路径）唯一记账；isolate 不再维护按后端三份 bool。
/// - 镜像回放：参数/字符串/插件三份复制粘贴收敛为一次调用。
class BridgeManager {
  BridgeManager({List<BridgeDesc>? descs})
      : _descs = {for (final d in (descs ?? builtinBridgeDescs())) d.id: d};

  final Map<String, BridgeDesc> _descs;
  final Map<String, AudioBridgeCommon> _instances = {};

  AudioBridgeCommon? _active;
  String? _activeId;

  AudioBridgeCommon? get active => _active;
  String? get activeId => _activeId;

  /// 当前出声后端是否为 [id]（isolate 的唯一真相源；不再维护三份 bool）。
  bool isActive(String id) => _activeId == id && _active != null;

  /// 已加载的桥实例（DLL 驻留：stop 不删表）。收尾时逐实例停会话用。
  Iterable<AudioBridgeCommon> get loadedBridges => _instances.values;

  BridgeDesc? descOf(String id) => _descs[id];

  /// 取绑定实例；首次调用才 `DynamicLibrary.open`（惰性加载）。
  /// 加载失败抛出（调用方转成 *status note，与旧行为一致）。
  /// DLL 驻留：stop 后再次进入直接复用同一实例。
  T load<T extends AudioBridgeCommon>(String id) {
    final existing = _instances[id];
    if (existing != null) return existing as T;
    final desc = _descs[id];
    if (desc == null) throw StateError('unknown bridge: $id');
    final inst = desc.load();
    _instances[id] = inst;
    return inst as T;
  }

  /// 切换当前出声后端。调用方必须已停掉旧桥（音频 isolate 的
  /// stopOtherBridges 收口）；这里只做唯一记账，意外叠加时留痕——D4-a 不允许
  /// 两路同时出声，出现即说明切换路径有 bug。
  void switchTo(String id, AudioBridgeCommon bridge) {
    final prev = _activeId;
    if (prev != null && prev != id) {
      dbgLog('bridge: switchTo $prev -> $id without stop');
    }
    _activeId = id;
    _active = bridge;
  }

  /// 清除当前后端（仅当仍是该实例时），stop 路径专用。
  void clearActive(AudioBridgeCommon bridge) {
    if (identical(_active, bridge)) {
      _active = null;
      _activeId = null;
    }
  }

  /// 桥 start 成功后按镜像回放浮点参数 + 字符串参数 + 旁路态。
  void replaySession(AudioBridgeCommon b, {
    required Map<String, ({bool isFloat, double value})> params,
    required Map<String, String> paramsStr,
    required bool bypass,
  }) {
    var n = 0;
    for (final e in params.entries) {
      b.setParam(e.key, isFloat: e.value.isFloat, value: e.value.value);
      ++n;
    }
    var ns = 0;
    for (final e in paramsStr.entries) {
      if (b.setParamStr(e.key, e.value) >= 0) ++ns;
    }
    final bypassRc = b.setBypass(bypass);
    dbgLog('bridge(${_activeId ?? '?'}): replay params=$n str=$ns '
        'bypass=$bypass rc=$bypassRc');
  }

  /// 桥 start 成功后按插件槽镜像回放（桥内引擎是新建的空状态）。
  /// [send] 用于把回执事件发回主 isolate（事件名/字段与旧实现一致）。
  void replayPluginMirror(AudioBridgeCommon b,
      List<PluginSlotCfg> slots, void Function(Map<String, dynamic>) send) {
    final pb = b.plugin;
    var ok = 0;
    var failed = 0;
    for (var i = 0; i < slots.length; ++i) {
      final c = slots[i];
      if (!c.loaded) continue;
      final rc = pb.load(i, c.path, id: c.id);
      if (rc == 1) {
        pb.setChannels(i, c.channels);
        pb.setInsertStage(i, c.stage);
        pb.setBypass(i, c.bypass);
        c.stage = pb.getInsertStage(i);
        c.bypass = pb.getBypass(i);
        c.channels = pb.getChannels(i);
        ++ok;
        send({
          'evt': 'pluginSlotLoaded',
          'slot': i,
          'path': c.path,
          'rc': 1,
          'status': pb.getStatus(i),
          'stage': c.stage,
          'busy': false,
        });
        send({
          'evt': 'pluginSlotBypass',
          'slot': i,
          'bypass': c.bypass,
          'rc': 1,
          'status': pb.getStatus(i),
        });
      } else {
        c.loaded = false;
        ++failed;
        send({
          'evt': 'pluginSlotLoaded',
          'slot': i,
          'path': c.path,
          'rc': 0,
          'status': pb.getStatus(i),
          'stage': 3,
          'busy': false,
        });
      }
    }
    dbgLog('plugin: bridge replay ok=$ok failed=$failed');
  }
}


