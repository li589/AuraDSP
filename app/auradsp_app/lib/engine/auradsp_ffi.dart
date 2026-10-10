/*
 * auradsp_ffi.dart — AuraDSP engine_api C ABI 的 dart:ffi 绑定
 *
 * 真相源：core/desktop/engine_api/auradsp_engine.h（v1.0，11 个导出符号）
 * 仅在音频 isolate 内使用：auradsp_process 契约要求单音频线程独占 handle。
 * 绑定全部显式 Dart 侧签名（Int32/Uint32→int，Double/Float→double）。
 */
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// 参数 ID 常量（engine_api 参数模型 v1 + v1.1 liveprog 增量）
abstract final class ParamId {
  static const bassEnable = 'bass.enable';
  static const bassGain = 'bass.gain';
  static const reverbPreset = 'reverb.preset';
  static const stereoMix = 'stereo.mix';
  static const eqEnable = 'eq.enable';
  static const postGain = 'post.gain';
  static const limiterEnable = 'limiter.enable';
  static const modeLatency = 'mode.latency';
  static const channelsMode = 'channels.mode';
  // v1.1：Liveprog（EEL2 实时可编程 DSP）
  static const lpEnable = 'liveprog.enable';
  static const lpCode = 'liveprog.code';
  static const lpUnload = 'liveprog.unload';
  static const lpStatus = 'liveprog.status';
  static List<String> lpParams() => List.generate(8, (i) => 'liveprog.param${i + 1}');
  // v1.1：卷积 / 脉冲响应（M4）
  static const convEnable = 'convolver.enable';
  static const convIrPath = 'convolver.ir.path';
  static const convClear = 'convolver.clear';
  static const convReady = 'convolver.ready';
  static const convFrames = 'convolver.ir.frames';
  static const convChannels = 'convolver.ir.channels';
  static const convSrcRate = 'convolver.ir.srcRate';
  static const convPeak = 'convolver.ir.peak';
  static const convIrSpectrum = 'convolver.ir.spectrum';
  // M3-a：轻量效果开关
  static const tubeEnable = 'tube.enable';
  static const tubeGain = 'tube.gain';
  static const xfeedEnable = 'crossfeed.enable';
  // M5/P-002：声场分带
  static String stereoBand(int i) => 'stereo.band${i + 1}'; // i: 0..4
  static const stereoBandUsed = 'stereo.bandUsed';
  // 脉冲响应干湿比（P-005）+ VDC
  static const convMix = 'convolver.mix';
  static const ddcLoad = 'ddc.load';
  static const ddcEnable = 'ddc.enable';
  static const ddcReady = 'ddc.ready';
  // M5-b：低频搁架（low-shelf，engine wrapper 自研 biquad）
  static const shelfEnable = 'shelf.enable';
  static const shelfFreq = 'shelf.freq';
  static const shelfGain = 'shelf.gain';
  // M5-c：参数化混响（Freeverb）
  static const fvEnable = 'freeverb.enable';
  static const fvDecay = 'freeverb.decay';
  static const fvDamp = 'freeverb.damp';
  static const fvWet = 'freeverb.wet';
  static const fvDry = 'freeverb.dry';
}

/// auradsp_status（engine_api 枚举）
abstract final class Status {
  static const ok = 0;
  static const eParam = -1;
  static const eUnsupported = -2;
  static const eLatencyGuard = -3;
  static const eState = -4;
  static const eIo = -5;
}

/// auradsp_state
abstract final class EngineState {
  static const bypass = 0;
  static const processing = 1;
  static const error = 2;
}

/// vendor 处理链的**实际** stage 数（graph.order 合法集合大小）。
///
/// 对应 C 侧 `AURADSP_VENDOR_STAGES`（core/desktop/engine_api/auradsp_engine.h）。
/// 注意与 ABI 容量 `AURADSP_STAGE_MAX = 16` 区分：C 结构体的 per-stage 电平
/// 数组物理长度是 16（预留位，恒 -120 dBFS），但只有本值这么多项有数据。
/// 改动 vendor 链长度时，**必须同步修改这两个常量**。
const int kEngineStageCount = 12;

/// 引擎内建的频谱 FFT 点数（auradsp_engine.cpp 的 kVizFftSize）。
/// config.vizFftSize 与之相同时无需下发，避免无谓的缓冲区重建。
const int kVizFftSizeDefault = 4096;

/// auradsp_viz_frame（280 字节：8+8+128+4+4+64+64）
final class VizFrame extends Struct {
  @Uint64()
  external int seq;
  @Double()
  external double timestampMs;

  @Array(32)
  external Array<Float> spectrum;

  @Float()
  external double levelLDbfs;
  @Float()
  external double levelRDbfs;
@Array(16)
  external Array<Float> stageLevelsL;

  @Array(16)
  external Array<Float> stageLevelsR;

  List<double> spectrumToList() =>
      List<double>.generate(32, (i) => spectrum[i]);

  List<double> stageLevelsLToList() =>
      List<double>.generate(kEngineStageCount, (i) => stageLevelsL[i]);

  List<double> stageLevelsRToList() =>
      List<double>.generate(kEngineStageCount, (i) => stageLevelsR[i]);
}

/// auradsp_engine.dll 符号绑定（加载成功后不可变）
final class AuraDspLib {
  final DynamicLibrary dylib;

  late final Pointer<Void> Function(double, int) create = dylib
      .lookup<NativeFunction<Pointer<Void> Function(Float, Int32)>>(
          'auradsp_create')
      .asFunction<Pointer<Void> Function(double, int)>();

  late final void Function(Pointer<Void>) destroy = dylib
      .lookup<NativeFunction<Void Function(Pointer<Void>)>>('auradsp_destroy')
      .asFunction();

  late final void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>, int)
      process = dylib
          .lookup<
              NativeFunction<
                  Void Function(Pointer<Void>, Pointer<Float>, Pointer<Float>,
                      Int32)>>('auradsp_process')
          .asFunction();

  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>, int)
      setParam = dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>,
                      Uint32)>>('auradsp_set_param')
          .asFunction();

  late final int Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>, int)
      getParam = dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Uint8>, Pointer<Void>,
                      Uint32)>>('auradsp_get_param')
          .asFunction();

  late final int Function(Pointer<Void>) getState = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'auradsp_get_state')
      .asFunction();

  late final double Function(Pointer<Void>) getLatencyMs = dylib
      .lookup<NativeFunction<Double Function(Pointer<Void>)>>(
          'auradsp_get_latency_ms')
      .asFunction();

  late final Pointer<Utf8> Function(Pointer<Void>) lastError = dylib
      .lookup<NativeFunction<Pointer<Utf8> Function(Pointer<Void>)>>(
          'auradsp_last_error')
      .asFunction();

  late final int Function(Pointer<Void>, Pointer<VizFrame>, int) vizRead =
      dylib
          .lookup<
              NativeFunction<
                  Uint32 Function(Pointer<Void>, Pointer<VizFrame>,
                      Uint32)>>('auradsp_viz_read')
          .asFunction();

  late final Pointer<Utf8> Function() version = dylib
      .lookup<NativeFunction<Pointer<Utf8> Function()>>('auradsp_version')
      .asFunction();

  late final int Function() abi = dylib
      .lookup<NativeFunction<Uint32 Function()>>('auradsp_abi')
      .asFunction();

  // M1 第三方插件宿主导出符号
  late final int Function(Pointer<Void>, Pointer<Utf8>, int) pluginScan =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Utf8>,
                      Int32)>>('auradsp_plugin_scan')
          .asFunction();

  late final int Function(Pointer<Void>) pluginGetCount = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'auradsp_plugin_get_count')
      .asFunction();

  late final int Function(Pointer<Void>, int, Pointer<Utf8>, int) pluginGetItem =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>,
                      Int32)>>('auradsp_plugin_get_item')
          .asFunction();

  late final int Function(Pointer<Void>, Pointer<Utf8>, int) pluginGetAll =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Utf8>,
                      Int32)>>('auradsp_plugin_get_all')
          .asFunction();

  late final int Function(Pointer<Void>, Pointer<Utf8>, Pointer<Utf8>) pluginLoad =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Utf8>,
                      Pointer<Utf8>)>>('auradsp_plugin_load')
          .asFunction();

  late final int Function(Pointer<Void>) pluginUnload = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'auradsp_plugin_unload')
      .asFunction();

  late final int Function(Pointer<Void>, int) pluginSetBypass = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_set_bypass')
      .asFunction();

  late final int Function(Pointer<Void>) pluginGetBypass = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'auradsp_plugin_get_bypass')
      .asFunction();

  late final int Function(Pointer<Void>) pluginGetLatency = dylib
      .lookup<NativeFunction<Uint32 Function(Pointer<Void>)>>(
          'auradsp_plugin_get_latency')
      .asFunction();

  late final int Function(Pointer<Void>, Pointer<Utf8>, int) pluginGetStatus =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Utf8>,
                      Int32)>>('auradsp_plugin_get_status')
          .asFunction();

  // M1 多插槽与原生 GUI 编辑器、预设管理导出符号
  late final int Function(Pointer<Void>) pluginGetNumSlots = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'auradsp_plugin_get_num_slots')
      .asFunction();

  late final int Function(Pointer<Void>, int, Pointer<Utf8>, Pointer<Utf8>) pluginSlotLoad =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>,
                      Pointer<Utf8>)>>('auradsp_plugin_slot_load')
          .asFunction();

  late final int Function(Pointer<Void>, int) pluginSlotUnload = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_slot_unload')
      .asFunction();

  late final int Function(Pointer<Void>, int, int) pluginSlotSetBypass = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32, Int32)>>(
          'auradsp_plugin_slot_set_bypass')
      .asFunction();

  late final int Function(Pointer<Void>, int) pluginSlotGetLatency = dylib
      .lookup<NativeFunction<Uint32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_slot_get_latency')
      .asFunction();

  late final int Function(Pointer<Void>, int, Pointer<Utf8>, int) pluginSlotGetStatus =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>,
                      Int32)>>('auradsp_plugin_slot_get_status')
          .asFunction();

  late final int Function(Pointer<Void>, int, Pointer<Utf8>) pluginSlotShowEditor =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Int32,
                      Pointer<Utf8>)>>('auradsp_plugin_slot_show_editor')
          .asFunction();

  late final int Function(Pointer<Void>, int) pluginSlotCloseEditor = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_slot_close_editor')
      .asFunction();

  late final int Function(Pointer<Void>, int) pluginSlotIsEditorOpen = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_slot_is_editor_open')
      .asFunction();

  late final int Function(Pointer<Void>, int, Pointer<Utf8>) pluginSlotSavePreset =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Int32,
                      Pointer<Utf8>)>>('auradsp_plugin_slot_save_preset')
          .asFunction();

  late final int Function(Pointer<Void>, int, Pointer<Utf8>) pluginSlotLoadPreset =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Int32,
                      Pointer<Utf8>)>>('auradsp_plugin_slot_load_preset')
          .asFunction();

  late final int Function(Pointer<Void>, int, int) pluginSlotSetInsertStage = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32, Int32)>>(
          'auradsp_plugin_slot_set_insert_stage')
      .asFunction();

  late final int Function(Pointer<Void>, int) pluginSlotGetInsertStage = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_slot_get_insert_stage')
      .asFunction();

  /// 组件延迟实测：真实脉冲响应测量，返回算法延迟（样本数）。
  /// 见 auradsp_engine.h 的 auradsp_probe_component 契约。
  /// 每次调用约数十毫秒（引擎内部建/毁一个探针 handle），只能按需调用，
  /// 绝不要放进音频路径。
  late final int Function(Pointer<Void>, double, Pointer<Uint32>) probeComponent =
      dylib
          .lookup<NativeFunction<
              Int32 Function(Pointer<Void>, Double, Pointer<Uint32>)>>(
              'auradsp_probe_component')
          .asFunction<int Function(Pointer<Void>, double, Pointer<Uint32>)>();

  AuraDspLib._(this.dylib);

  static AuraDspLib? _cached;

  /// 尝试加载引擎 DLL；找不到时抛 [StateError]（路径清单供 UI 提示）。
  ///
  /// 候选路径顺序：exe 同级 → `engine/` 子目录 → 环境变量
  /// `AURADSP_ENGINE_DLL` 指定���绝对路径。
  /// 刻意**不含**任何硬编码的开发机绝对路径——那属于本机配置，
  /// 不是产品行为；开发期请设 `AURADSP_ENGINE_DLL` 指向
  /// `core/desktop/windows/out/Release/auradsp_engine.dll`。
  static AuraDspLib load() {
    if (_cached != null) return _cached!;
    final candidates = <String>[
      'auradsp_engine.dll', // exe 旁（bundle root）
      'engine\\auradsp_engine.dll', // engine/ 子目录
    ];
    final envPath = Platform.environment['AURADSP_ENGINE_DLL'];
    if (envPath != null && envPath.isNotEmpty) candidates.add(envPath);
    Object? lastErr;
    for (final path in candidates) {
      try {
        _cached = AuraDspLib._(DynamicLibrary.open(path));
        return _cached!;
      } catch (e) {
        lastErr = e;
      }
    }
    throw StateError(
        'auradsp_engine.dll not found (tried: ${candidates.join(", ")}) — $lastErr');
  }

  /// 便捷：字符串参数 ID → 原生 buffer
  static Pointer<Uint8> idBytes(String id) {
    final units = utf8.encode(id);
    final p = malloc<Uint8>(units.length + 1);
    for (var i = 0; i < units.length; i++) {
      p[i] = units[i];
    }
    p[units.length] = 0;
    return p;
  }

  /// set_param 包装：int 值按 i32 传，double 值按 f32 传
  static int setValue(AuraDspLib lib, Pointer<Void> handle, String id,
      {required bool isFloat, required double value}) {
    final idp = idBytes(id);
    try {
      if (isFloat) {
        final vp = malloc<Float>()..value = value;
        try {
          return lib.setParam(handle, idp, vp.cast(), 4);
        } finally {
          malloc.free(vp);
        }
      } else {
        final vp = malloc<Int32>()..value = value.toInt();
        try {
          return lib.setParam(handle, idp, vp.cast(), 4);
        } finally {
          malloc.free(vp);
        }
      }
    } finally {
      malloc.free(idp);
    }
  }

  /// set_param 包装：UTF-8 字符串值（bytes = 字节数，不含 NUL）。
  /// 用于 liveprog.code 等字符串参数（engine_api v1.1）。
  static int setString(AuraDspLib lib, Pointer<Void> handle, String id, String text) {
    final idp = idBytes(id);
    final units = utf8.encode(text);
    final vp = malloc<Uint8>(units.length + 1);
    try {
      for (var i = 0; i < units.length; i++) {
        vp[i] = units[i];
      }
      vp[units.length] = 0;
      return lib.setParam(handle, idp, vp.cast(), units.length);
    } finally {
      malloc.free(vp);
      malloc.free(idp);
    }
  }

  /// get_param 包装：i32
  static int getInt(AuraDspLib lib, Pointer<Void> handle, String id) {
    final idp = idBytes(id);
    final vp = malloc<Int32>();
    try {
      final rc = lib.getParam(handle, idp, vp.cast(), 4);
      return rc == 0 ? vp.value : -999999;
    } finally {
      malloc.free(vp);
      malloc.free(idp);
    }
  }

  /// 插件宿主：扫描插件目录并返回发现数
  static int pluginScanWrap(AuraDspLib lib, Pointer<Void> handle,
      {String dir = '', bool deep = false}) {
    final dirPtr = dir.isEmpty ? nullptr : dir.toNativeUtf8();
    try {
      return lib.pluginScan(handle, dirPtr, deep ? 1 : 0);
    } finally {
      if (dirPtr != nullptr) malloc.free(dirPtr);
    }
  }

  /// 插件宿主：获取全部已扫描插件的 JSON 字符串
  static String pluginGetAllJson(AuraDspLib lib, Pointer<Void> handle,
      {int maxBytes = 262144}) {
    final buf = malloc<Uint8>(maxBytes);
    try {
      final written = lib.pluginGetAll(handle, buf.cast(), maxBytes);
      if (written <= 0) return '[]';
      return buf.cast<Utf8>().toDartString();
    } finally {
      malloc.free(buf);
    }
  }

  /// 插件宿主：加载插件
  static int pluginLoadWrap(AuraDspLib lib, Pointer<Void> handle, String path,
      {String id = ''}) {
    final pathPtr = path.toNativeUtf8();
    final idPtr = id.toNativeUtf8();
    try {
      return lib.pluginLoad(handle, pathPtr, idPtr);
    } finally {
      malloc.free(pathPtr);
      malloc.free(idPtr);
    }
  }

  /// 插件宿主：卸载插件
  static int pluginUnloadWrap(AuraDspLib lib, Pointer<Void> handle) {
    return lib.pluginUnload(handle);
  }

  /// 插件宿主：设置旁路
  static int pluginSetBypassWrap(AuraDspLib lib, Pointer<Void> handle, bool bypass) {
    return lib.pluginSetBypass(handle, bypass ? 1 : 0);
  }

  /// 插件宿主：获取宿主状态 JSON
  static String pluginGetStatusJson(AuraDspLib lib, Pointer<Void> handle,
      {int maxBytes = 8192}) {
    final buf = malloc<Uint8>(maxBytes);
    try {
      final written = lib.pluginGetStatus(handle, buf.cast(), maxBytes);
      if (written <= 0) return '{}';
      return buf.cast<Utf8>().toDartString();
    } finally {
      malloc.free(buf);
    }
  }

  // ---- 多插槽与编辑器、预设管理包装方法 ----

  /// 槽位加载插件
  static int pluginSlotLoadWrap(AuraDspLib lib, Pointer<Void> handle, int slot,
      String path, {String id = ''}) {
    final pathPtr = path.toNativeUtf8();
    final idPtr = id.toNativeUtf8();
    try {
      return lib.pluginSlotLoad(handle, slot, pathPtr, idPtr);
    } finally {
      malloc.free(pathPtr);
      malloc.free(idPtr);
    }
  }

  /// 槽位卸载插件
  static int pluginSlotUnloadWrap(AuraDspLib lib, Pointer<Void> handle, int slot) {
    return lib.pluginSlotUnload(handle, slot);
  }

  /// 槽位设置旁路
  static int pluginSlotSetBypassWrap(
      AuraDspLib lib, Pointer<Void> handle, int slot, bool bypass) {
    return lib.pluginSlotSetBypass(handle, slot, bypass ? 1 : 0);
  }

  /// 槽位获取状态 JSON
  static String pluginSlotGetStatusJson(
      AuraDspLib lib, Pointer<Void> handle, int slot,
      {int maxBytes = 8192}) {
    final buf = malloc<Uint8>(maxBytes);
    try {
      final written = lib.pluginSlotGetStatus(handle, slot, buf.cast(), maxBytes);
      if (written <= 0) return '{}';
      return buf.cast<Utf8>().toDartString();
    } finally {
      malloc.free(buf);
    }
  }

  /// 打开插件原生 GUI 编辑器窗口
  static int pluginSlotShowEditorWrap(
      AuraDspLib lib, Pointer<Void> handle, int slot,
      {String title = ''}) {
    final titlePtr = title.isEmpty ? nullptr : title.toNativeUtf8();
    try {
      return lib.pluginSlotShowEditor(handle, slot, titlePtr);
    } finally {
      if (titlePtr != nullptr) malloc.free(titlePtr);
    }
  }

  /// 关闭插件原生 GUI 编辑器窗口
  static int pluginSlotCloseEditorWrap(
      AuraDspLib lib, Pointer<Void> handle, int slot) {
    return lib.pluginSlotCloseEditor(handle, slot);
  }

  /// 保存插件预设
  static int pluginSlotSavePresetWrap(
      AuraDspLib lib, Pointer<Void> handle, int slot, String filePath) {
    final pathPtr = filePath.toNativeUtf8();
    try {
      return lib.pluginSlotSavePreset(handle, slot, pathPtr);
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// 加载插件预设
  static int pluginSlotLoadPresetWrap(
      AuraDspLib lib, Pointer<Void> handle, int slot, String filePath) {
    final pathPtr = filePath.toNativeUtf8();
    try {
      return lib.pluginSlotLoadPreset(handle, slot, pathPtr);
    } finally {
      malloc.free(pathPtr);
    }
  }

  /// 设置插件在处理链上的插入阶段 (0: Pre-DSP, 1: Pre-Vendor, 2: Post-Vendor, 3: Post-Reverb, 4: Post-Limiter)
  static int pluginSlotSetInsertStageWrap(
      AuraDspLib lib, Pointer<Void> handle, int slot, int stage) {
    return lib.pluginSlotSetInsertStage(handle, slot, stage);
  }

  /// 获取插件在处理链上的插入阶段
  static int pluginSlotGetInsertStageWrap(
      AuraDspLib lib, Pointer<Void> handle, int slot) {
    return lib.pluginSlotGetInsertStage(handle, slot);
  }
}
