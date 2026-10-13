/*
 * auradsp_ffi.dart — AuraDSP engine_api C ABI 的 dart:ffi 绑定
 *
 * 真相源：engine/auradsp_engine.h（v1.0，11 个导出符号）
 * 仅在音频 isolate 内使用：auradsp_process 契约要求单音频线程独占 handle。
 * 绑定全部显式 Dart 侧签名（Int32/Uint32→int，Double/Float→double）。
 */
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ffi';
import 'dart:math' as math;

import 'package:ffi/ffi.dart';

/// 参数 ID 常量（engine_api 参数模型 v1 + v1.1 liveprog 增量）
abstract final class ParamId {
  static const bassEnable = 'bass.enable';
  static const bassGain = 'bass.gain';
  static const reverbPreset = 'reverb.preset';
  static const stereoMix = 'stereo.mix';
  static const eqEnable = 'eq.enable';
  static const postGain = 'post.gain';
  static const inputGain = 'input.gain';
  static String inputBalance(int ch) => 'input.balance.$ch';
  static const limiterEnable = 'limiter.enable';
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
  // P-011：电子管音色/干湿混合/输出补偿
  static const tubeStyle = 'tube.style';
  static const tubeMix = 'tube.mix';
  static const tubeCompensation = 'tube.compensation';
  static const xfeedEnable = 'crossfeed.enable';
  static const xfeedMode = 'crossfeed.mode';
  static const xfeedFcut = 'crossfeed.fcut';
  static const xfeedFeed = 'crossfeed.feed';
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
  // 低频单声道化（BassMono）
  static const bassmonoEnable = 'bassmono.enable';
  static const bassmonoFreq = 'bassmono.freq';
  // Haas 差分环绕
  static const haasEnable = 'haas.enable';
  static const haasDelay = 'haas.delay';
  static const haasMix = 'haas.mix';
  static const haasSide = 'haas.side';
  // 激励器
  static const exciterEnable = 'exciter.enable';
  static const exciterAmount = 'exciter.amount';
  static const exciterHifreq = 'exciter.hifreq';
  // 每效果输出增益门 + 自动增益补偿（P-010）
  static const bassOutGain = 'bass.outgain';
  static const bassAutoGain = 'bass.autogain';
  static const eqOutGain = 'eq.outgain';
  static const eqAutoGain = 'eq.autogain';
  static const tubeOutGain = 'tube.outgain';
  static const tubeAutoGain = 'tube.autogain';
  static const compOutGain = 'comp.outgain';
  static const compAutoGain = 'comp.autogain';
  static const reverbOutGain = 'reverb.outgain';
  static const reverbAutoGain = 'reverb.autogain';
  // 噪声门 + Deesser + 自动增益补偿
  static const gateEnable = 'gate.enable';
  static const gateThreshold = 'gate.threshold';
  static const gateAttack = 'gate.attack';
  static const gateRelease = 'gate.release';
  static const gateAutoGain = 'gate.autogain';
  static const deesserEnable = 'deesser.enable';
  static const deesserFreq = 'deesser.freq';
  static const deesserAmount = 'deesser.amount';
  // 全参数动态EQ（3 段 Low shelf / Mid bell / High shelf）
  static const dyneqEnable = 'dyneq.enable';
  static const dyneqAttack = 'dyneq.attack';
  static const dyneqRelease = 'dyneq.release';
  static const dyneqLowEnable = 'dyneq.low.enable';
  static const dyneqLowFreq = 'dyneq.low.freq';
  static const dyneqLowQ = 'dyneq.low.q';
  static const dyneqLowGain = 'dyneq.low.gain';
  static const dyneqLowRange = 'dyneq.low.range';
  static const dyneqLowThreshold = 'dyneq.low.threshold';
  static const dyneqMidEnable = 'dyneq.mid.enable';
  static const dyneqMidFreq = 'dyneq.mid.freq';
  static const dyneqMidQ = 'dyneq.mid.q';
  static const dyneqMidGain = 'dyneq.mid.gain';
  static const dyneqMidRange = 'dyneq.mid.range';
  static const dyneqMidThreshold = 'dyneq.mid.threshold';
  static const dyneqHighEnable = 'dyneq.high.enable';
  static const dyneqHighFreq = 'dyneq.high.freq';
  static const dyneqHighQ = 'dyneq.high.q';
  static const dyneqHighGain = 'dyneq.high.gain';
  static const dyneqHighRange = 'dyneq.high.range';
  static const dyneqHighThreshold = 'dyneq.high.threshold';
  // 响度补偿（信号自适应等响度）
  static const loudnessEnable = 'loudness.enable';
  static const loudnessAmount = 'loudness.amount';
  // 心理声学低音（谐波合成，曾经的三死滑块现在有引擎了）
  static const bassHarmonics = 'bass.harmonics';
  static const bassHarmonicBlend = 'bass.harmonicblend';
  static const bassSubFreq = 'bass.subfreq';
  static const bassCutoffF = 'bass.cutoff';
  // 独立滤波器（RBJ HP/LP/BP）
  static const filterEnable = 'filter.enable';
  static const filterType = 'filter.type';
  static const filterFreq = 'filter.freq';
  static const filterQ = 'filter.q';
  // M5-c：参数化混响（Freeverb）
  static const fvEnable = 'freeverb.enable';
  static const fvDecay = 'freeverb.decay';
  static const fvDamp = 'freeverb.damp';
  static const fvWet = 'freeverb.wet';
  static const fvDry = 'freeverb.dry';
  // 动态压限器（Compander）
  static const compEnable = 'comp.enable';
  static const compTimeconstant = 'comp.timeconstant';
  static const compGranularity = 'comp.granularity';
  static const compTfresolution = 'comp.tfresolution';
  // 任意响应 EQ（ArbMag / AutoEq GraphicEQ）
  static const arbmagEnable = 'arbmag.enable';
  static const arbmagString = 'arbmag.string';
  static const arbmagReady = 'arbmag.ready';
  static const arbmagNodeCount = 'arbmag.nodeCount';
  static const arbmagOutGain = 'arbmag.outgain';
  static const arbmagAutoGain = 'arbmag.autogain';
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
/// 对应 C 侧 `AURADSP_VENDOR_STAGES`（engine/auradsp_engine.h）。
/// 注意与 ABI 容量 `AURADSP_STAGE_MAX = 16` 区分：C 结构体的 per-stage 电平
/// 数组物理长度是 16（预留位，恒 -120 dBFS），但只有本值这么多项有数据。
/// 改动 vendor 链长度时，**必须同步修改这两个常量**。
const int kEngineStageCount = 12;

/// 引擎内建的频谱 FFT 点数（auradsp_engine.cpp 的 kVizFftSize）。
/// config.vizFftSize 与之相同时无需下发，避免无谓的缓冲区重建。
const int kVizFftSizeDefault = 4096;

/// 引擎 32 个对数频带的边界（Hz），逐值对应 `auradsp_engine.cpp` 的 `kBandEdges`。
///
/// 引擎侧 `emit_viz` 已把线性 FFT bin 聚合成这 32 条对数带，
/// 因此 UI 收到的频谱**本身就是对数分布**的。
/// UI 侧所有频谱/频轴的横坐标都必须经由本类换算 —— 否则条形、网格与频率标签
/// 会各自用一套映射而互相对不齐（历史上 `chrome.dart` 用 `pow(t, 1.6)` 幂律
/// 重采样 72 根条，把低频拉宽、高频压扁，与 `FreqAxis` 的对数刻度不符）。
abstract final class VizBands {
  static const int count = 32;
  static const double minHz = 20.0;
  static const double maxHz = 20000.0;

  /// 与引擎 `kBandEdges` 逐值一致（见 auradsp_engine.cpp，勿单方面改动）。
  ///
  /// 尾部说明：原为 6300…16000/18000/19000/20000，后三带只有 1kHz 宽，
  /// 对数跨度 0.74%（中频带的 ~1/4），在频谱上被画成发丝。现统一为约 1.19
  /// 等比的 5950→20000，最窄带 2.46%，与全局阶梯一致。
  static const List<double> edges = <double>[
    20, 25, 31, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, //
    630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, //
    5950, 7070, 8400, 10000, 11900, 14100, 16800, 20000,
  ];

  /// 归一化对数横坐标：log(hz/minHz) / log(maxHz/minHz)。
  static double logX(double hz) =>
      math.log(hz / minHz) / math.log(maxHz / minHz);

  /// 第 b 条频带左边界（= 第 b-1 条右边界）的横坐标。
  static double edgeX(int b) => logX(edges[b.clamp(0, count)]);

  /// 第 b 条频带的中心横坐标。
  static double centerX(int b) => (edgeX(b) + edgeX(b + 1)) / 2.0;

  /// b 段频带的中心频率（Hz）。对数刻度频带用几何平均才对齐中点，
  /// 算术平均会系统性偏高（同一组边界下 20–25Hz 算术中点是 22.5Hz，
  /// 但它在对数轴上对应的视觉中点更接近 22.2Hz，误差在高频段更明显）。
  static double centerHz(int b) {
    final lo = edges[b.clamp(0, count)];
    final hi = edges[(b + 1).clamp(0, count)];
    return math.sqrt(lo * hi);
  }

  /// 引擎把 -75..0 dBFS 线性映射到 [0,1]（见 auradsp_engine.cpp 的 emit_viz）。
  ///
  /// 任何「频带值 ↔ dB」的换算都必须走这里：EQ 输出谱要把归一化值还原成
  /// dBFS、加上实测响应、再归一化回去，三步的口径必须与引擎完全一致，
  /// 偏一点就会让合成结果整体错位。
  static const double dbSpan = 75.0;

  static double toDb(double v) => v * dbSpan - dbSpan;

  static double fromDb(double db) => ((db + dbSpan) / dbSpan).clamp(0.0, 1.0);

  /// 在引擎实测响应数组上按频率线性插值取 dB。
  ///
  /// 该数组按 `minHz..responseFMax` 对数均分；调用方不得各自重写同一映射，
  /// 否则曲线绘制与频谱合成会系统性错位。
  static double responseDbAt(List<double> response, double hz,
      {double? responseFMax}) {
    if (response.length < 2) return 0.0;
    final hiHz = responseFMax ?? maxHz;
    final clampedHz = hz.clamp(minHz, hiHz);
    final t = (math.log(clampedHz / minHz) / math.log(hiHz / minHz))
        .clamp(0.0, 1.0);
    final x = t * (response.length - 1);
    final i = x.floor();
    if (i >= response.length - 1) return response[response.length - 1];
    final f = x - i;
    return response[i] * (1 - f) + response[i + 1] * f;
  }

  /// 给定归一化对数横坐标，返回源频带的小数下标，用于「N 条 ← 32 带」重采样。
  static double sampleIndex(double x) {
    final last = (count - 1).toDouble();
    if (x <= 0) return 0;
    if (x >= 1) return last;
    for (var b = 0; b < count; b++) {
      final lo = edgeX(b);
      final hi = edgeX(b + 1);
      if (x < hi || b == count - 1) {
        final t = (hi - lo) <= 1e-12 ? 0.0 : (x - lo) / (hi - lo);
        return (b + t).clamp(0.0, last);
      }
    }
    return last;
  }
}

/// auradsp_viz_frame（408 字节：8+8+128+128+4+4+64+64）
final class VizFrame extends Struct {
  @Uint64()
  external int seq;
  @Double()
  external double timestampMs;

@Array(32)
    external Array<Float> spectrum;

    /// vendor 链入口（均衡器输入）的 32 段频谱，语义与 [spectrum] 相同。
    ///
    /// 均衡器面板的背景柱必须用它，而不是 [spectrum]（整链最终输出，
    /// 含 EQ 之后的混响/卷积/Freeverb/插件）。EQ 在 libjamesdsp 单体链
    /// 内部拿不到输出，输出谱由 UI 用实测响应合成。
    @Array(32)
    external Array<Float> eqInSpectrum;

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

    List<double> eqInSpectrumToList() =>
        List<double>.generate(32, (i) => eqInSpectrum[i]);

    List<double> stageLevelsLToList() =>
        List<double>.generate(kEngineStageCount, (i) => stageLevelsL[i]);

    List<double> stageLevelsRToList() =>
        List<double>.generate(kEngineStageCount, (i) => stageLevelsR[i]);

    double get inputLevelInL => stageLevelsL[12];
    double get inputLevelInR => stageLevelsR[12];
    double get inputLevelOutL => stageLevelsL[13];
    double get inputLevelOutR => stageLevelsR[13];
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

  // C2：分块扫描（枚举 → 小步取元数据 → 收尾）。步间由 Dart 让出事件循环，
  // 扫描不再是单个长阻塞 FFI 调用。
  late final int Function(Pointer<Void>, Pointer<Utf8>, int) pluginScanBegin =
      dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Pointer<Utf8>,
                      Int32)>>('auradsp_plugin_scan_begin')
          .asFunction();

  late final int Function(Pointer<Void>, int) pluginScanStep = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_scan_step')
      .asFunction();

  late final int Function(Pointer<Void>, Pointer<Int32>) pluginScanProgress =
      dylib
          .lookup<NativeFunction<Int32 Function(Pointer<Void>, Pointer<Int32>)>>(
              'auradsp_plugin_scan_progress')
          .asFunction();

  late final int Function(Pointer<Void>) pluginScanEnd = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>)>>(
          'auradsp_plugin_scan_end')
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

  /// C3：异步挂载/卸载。提交立即返回（微秒级），重活在引擎控制线程执行，
  /// 不阻塞调用方（音频 isolate 的事件循环）。轮询 [pluginSlotTaskState]
  /// 直到终态：0=无任务 1=进行中 2=成功 3=失败。
  late final int Function(Pointer<Void>, int, Pointer<Utf8>, Pointer<Utf8>)
      pluginSlotLoadAsync = dylib
          .lookup<
              NativeFunction<
                  Int32 Function(Pointer<Void>, Int32, Pointer<Utf8>,
                      Pointer<Utf8>)>>('auradsp_plugin_slot_load_async')
          .asFunction();

  late final int Function(Pointer<Void>, int) pluginSlotUnloadAsync = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_slot_unload_async')
      .asFunction();

  late final int Function(Pointer<Void>, int) pluginSlotTaskState = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_slot_task_state')
      .asFunction();

  late final int Function(Pointer<Void>, int, int) pluginSlotSetBypass = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32, Int32)>>(
          'auradsp_plugin_slot_set_bypass')
      .asFunction();

  // E3：补齐读取旁路状态的绑定（set 有、get 无，导致 UI 只能盲写不能回读）。
  // 槽位越界时引擎返回 1（旁路中），与 set 的失败语义区分。
  late final int Function(Pointer<Void>, int) pluginSlotGetBypass = dylib
      .lookup<NativeFunction<Int32 Function(Pointer<Void>, Int32)>>(
          'auradsp_plugin_slot_get_bypass')
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
  late final int Function(Pointer<Utf8>, double, Pointer<Uint32>) probeComponent =
      dylib
          .lookup<NativeFunction<
              Int32 Function(Pointer<Utf8>, Double, Pointer<Uint32>)>>(
              'auradsp_probe_component')
          .asFunction<int Function(Pointer<Utf8>, double, Pointer<Uint32>)>();

  /// 带资源探测：convolver / ddc 需要 IR / VDC 才能在探针内就绪，
  /// 未给路径时引擎返回 -1（不可测），而不是编造数字。
  /// resourcePath 传 null 表示走与 probeComponent 完全一致的旧行为。
  late final int Function(Pointer<Utf8>, Pointer<Utf8>, double,
      Pointer<Uint32>) probeComponentWithResource = dylib
          .lookup<
              NativeFunction<Int32 Function(Pointer<Utf8>, Pointer<Utf8>,
                  Double, Pointer<Uint32>)>>('auradsp_probe_component_with_resource')
          .asFunction<
              int Function(Pointer<Utf8>, Pointer<Utf8>, double,
                  Pointer<Uint32>)>();

  /// C2：EQ 实际频率响应实测。curve 用 eq.curve 同格式（"f:g;f:g;..."）。
  ///
  /// **不接收 handle**，引擎内部自建私有 jdsp 实例 —— 复用调用方的会和音频
  /// 线程争同一个卷积器的内部历史。纯函数，可在 UI isolate 调用。
  ///
  /// **实测约 29 ms**（129 点）：makima + 最小相位 IR 设计 + FFT 是固有开销。
  /// 因此**绝不能**放进音频 isolate（那会挤掉渲染回调，正是 P-006 的爆音成因），
  /// 也不能逐帧调用。调用方需自行防抖 + 缓存，详见 `AppModel.eqResponseDb`。
  /// C 侧签名：
///   int auradsp_probe_eq_response(int sample_rate, const char* curve,
///                                 int n_points, double f_max, float* out_db)
/// ——共 5 个参数，其中 [sample_rate] 与 [curve] 是 int / const char*，
/// 在 x64 上分别占 1 个寄存器槽，与 Dart 侧的 int / Pointer 一一对应。
late final int Function(int, Pointer<Utf8>, int, double, Pointer<Float>)
    probeEqResponse = dylib
        .lookup<
            NativeFunction<
                Int32 Function(Int, Pointer<Utf8>, Int, Double,
                    Pointer<Float>)>>('auradsp_probe_eq_response')
        .asFunction<
            int Function(int, Pointer<Utf8>, int, double, Pointer<Float>)>();

  /// 响应探针实际使用的上限频率：与引擎侧钳位公式保持一致。
  ///
  /// 采样率足够高时就是默认 `fMax`；低采样率下引擎会按 Nyquist 收窄。
  /// UI 侧插值必须用同一个上限，否则低采样率下高频会被整体错位。
  static double responseFMax({
    required int sampleRate,
    double fMin = 20.0,
    double fMax = 20000.0,
  }) =>
      fMax.clamp(fMin + 1.0, sampleRate / 2.0 * 0.999).toDouble();

  /// [probeEqResponse] 的安全封装：负责字符串/输出缓冲的分配与释放。
  ///
  /// 返回 null 表示失败（非法曲线等），此时调用方应保留上一帧曲线，
  /// 而不是画一条空白 —— 探针失败不该让 UI 变瞎。
  List<double>? measureEqResponse(String curve, int sampleRate,
      {int nPoints = 129, double fMin = 20.0, double fMax = 20000.0}) {
    if (nPoints < 2 || nPoints > 1024) return null;
    // 用一次性 Allocator 托管两处原生内存，作用域结束即释放，
    // 避免裸 free() 与类成员同名导致的遮蔽问题。
    final alloc = Arena();
    try {
      final out = alloc<Float>(nPoints);
      final text = curve.toNativeUtf8(allocator: alloc);
      final hi = responseFMax(
        sampleRate: sampleRate,
        fMin: fMin,
        fMax: fMax,
      );
      final rc = probeEqResponse(sampleRate, text, nPoints, hi, out);
      /* 非法输入返回非 0 是**契约**，不是异常：调用方据此回退到本地插值。
       * 刻意不写成 assert —— 那样会把「预期被拒绝」变成崩溃，
       * 而拒绝本身正是这里要测的行为。 */
      if (rc != 0) return null;
      return List<double>.generate(nPoints, (i) => out[i], growable: false);
    } finally {
      alloc.releaseAll();
    }
  }

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

  /// 插件宿主：分块扫描 —— 枚举候选，返回候选总数
  static int pluginScanBeginWrap(AuraDspLib lib, Pointer<Void> handle,
      {String dir = '', bool deep = false}) {
    final dirPtr = dir.isEmpty ? nullptr : dir.toNativeUtf8();
    try {
      return lib.pluginScanBegin(handle, dirPtr, deep ? 1 : 0);
    } finally {
      if (dirPtr != nullptr) malloc.free(dirPtr);
    }
  }

  /// 插件宿主：分块扫描 —— 处理至多 maxItems 个候选，返回本步处理数（<=0 结束）
  static int pluginScanStepWrap(AuraDspLib lib, Pointer<Void> handle,
      {int maxItems = 8}) {
    return lib.pluginScanStep(handle, maxItems);
  }

  /// 插件宿主：分块扫描 —— 返回 (已处理, 候选总数)
  static ({int processed, int total}) pluginScanProgressWrap(
      AuraDspLib lib, Pointer<Void> handle) {
    final totalPtr = malloc<Int32>();
    try {
      final processed = lib.pluginScanProgress(handle, totalPtr);
      return (processed: processed, total: totalPtr.value);
    } finally {
      malloc.free(totalPtr);
    }
  }

  /// 插件宿主：分块扫描 —— 收尾并返回最终插件数
  static int pluginScanEndWrap(AuraDspLib lib, Pointer<Void> handle) {
    return lib.pluginScanEnd(handle);
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

  /// C3：异步提交槽位加载（非阻塞）。返回 1=已受理，0=被拒绝（该槽已有任务进行中）。
  static int pluginSlotLoadAsyncWrap(AuraDspLib lib, Pointer<Void> handle, int slot,
      String path, {String id = ''}) {
    final pathPtr = path.toNativeUtf8();
    final idPtr = id.toNativeUtf8();
    try {
      return lib.pluginSlotLoadAsync(handle, slot, pathPtr, idPtr);
    } finally {
      malloc.free(pathPtr);
      malloc.free(idPtr);
    }
  }

  /// C3：异步提交槽位卸载（非阻塞）。返回 1=已受理，0=被拒绝。
  static int pluginSlotUnloadAsyncWrap(AuraDspLib lib, Pointer<Void> handle, int slot) {
    return lib.pluginSlotUnloadAsync(handle, slot);
  }

  /// C3：查询槽位任务状态。0=无任务 1=进行中 2=成功 3=失败。
  static int pluginSlotTaskStateWrap(AuraDspLib lib, Pointer<Void> handle, int slot) {
    return lib.pluginSlotTaskState(handle, slot);
  }

  /// 槽位设置旁路
  static int pluginSlotSetBypassWrap(
      AuraDspLib lib, Pointer<Void> handle, int slot, bool bypass) {
    return lib.pluginSlotSetBypass(handle, slot, bypass ? 1 : 0);
  }

  /// 槽位读取旁路状态（E3）。返回 true 表示旁路中。
  static bool pluginSlotGetBypassWrap(
      AuraDspLib lib, Pointer<Void> handle, int slot) {
    return lib.pluginSlotGetBypass(handle, slot) != 0;
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
