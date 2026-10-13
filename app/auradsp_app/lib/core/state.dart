/*
 * state.dart — AppModel：主 isolate 侧的应用状态
 *
 * 职责：持有音频 isolate（唯一 auradsp_handle 所有者），把消息协议翻译为
 * 可观察状态；viz 高频数据走独立 ValueNotifier（30fps），避免整页重建。
 */
import 'dart:async';
import 'dart:io';
import 'dart:ffi';
import 'dart:isolate';
import 'package:ffi/ffi.dart';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, Locale;

import '../engine/audio_isolate.dart';
import '../engine/auradsp_ffi.dart'
    show ParamId, kEngineStageCount, AuraDspLib, VizBands;
import '../engine/debug_log.dart';
import 'config.dart';
import 'eel_slider_parser.dart';
import 'plugin_manager.dart';
import 'presets.dart';
import 'session_memory.dart';
import 'theme.dart';

class SavedPluginSlot {
  final int slot;
  final String path;
  final String id;
  final bool bypass;
  final int stage;
  const SavedPluginSlot({
    required this.slot,
    required this.path,
    this.id = '',
    this.bypass = false,
    this.stage = 3,
  });
}

enum EngineConn { connecting, ready, fatal }

class EngineInfo {
  final int abi;
  final String version;
  final int deviceRate, deviceCh, bufferFrames;
  EngineInfo(this.abi, this.version, this.deviceRate, this.deviceCh,
      this.bufferFrames);
}

class GuardRejection {
  final String paramId, message;
  final int rc;
  GuardRejection(this.paramId, this.message, this.rc);
}

/// 集中式出厂默认值真相源（与 C++ 引擎 auradsp_create 初始状态严格对齐）
abstract class ParamDefaults {
  static const double bassGain = 0.0;        // [0, 15] dB
  static const double stereoMix = 0.0;       // [0, 1] (0% ~ 100%)
  static const double convMix = 1.0;         // [0, 1] (100% 纯湿)
  static const double postGain = 0.0;        // [-15, 15] dB
  static const double inputGain = 0.0;       // [-15, 15] dB
  static const double inputBalanceL = 1.0;   // 100%
  static const double inputBalanceR = 1.0;   // 100%

  // Freeverb 空间混响
  static const double fvDecay = 0.5;         // 50%
  static const double fvDamp = 0.5;          // 50%
  static const double fvWet = 0.35;          // 35%
  static const double fvDry = 1.0;           // 100%
  static const double fvRoomSize = 1.2;      // 1.2x
  static const double fvWidth = 1.0;         // 100%

  // 低频搁架 (Shelf)
  static const double shelfFreq = 100.0;     // 100 Hz
  static const double shelfGain = 0.0;       // 0.0 dB

  // 低频单声道化 (BassMono)
  static const double bassmonoFreq = 120.0;  // 120 Hz [20,300]

  // Haas 差分环绕
  static const double haasDelayMs = 12.0;    // 12 ms [0,25]
  static const double haasMix = 1.0;         // [0,1]
  static const int haasSideRight = 0;        // 0=延迟右 1=延迟左
  static const int haasSideLeft = 1;

  // 激励器
  static const double exciterAmount = 0.3;   // [0,1]
  static const double exciterHifreq = 5000.0; // 5 kHz [3000,10000]

  // 声场分带
  static const double stereoBand = 0.5;      // 50%

  // 低音重构
  static const double bassIntensity = 0.6;   // 60%
  static const int bassMode = 0;             // 0: 动态增强, 1: 纯净低架, 2: 心理声学谐波
  static const double bassCutoff = 120.0;    // 120 Hz
  static const double bassHarmonics = 0.45;  // 45%
  static const double bassHarmonicBlend = 0.5;// 50% (平衡)
  static const double bassSubFloor = 25.0;   // 25 Hz

  // 独立滤波器
  static const int filterType = 0;           // 0=HP 1=LP 2=BP
  static const double filterFreq = 80.0;     // 80 Hz
  static const double filterQ = 0.707;       // Q

  // 电子管模拟器
  static const double tubeGain = 4.5;        // +4.5 dB
  static const int tubeStyle = 0;            // 0: 三极管, 1: 五极管, 2: 磁带温润
  static const int tubeOversampling = 2;     // 2x
  static const double tubeCompensation = 0.0;// 0.0 dB
  static const double tubeMix = 1.0;         // 100%

  // 多段图形均衡器
  static const int eqBandsCount = 15;        // 15段
  static const double eqQ = 1.414;           // Q 锐度
  static const int eqFilter = 0;             // 0: FIR, 1: 6阶 IIR, 2: 12阶 IIR
  static const int eqInterp = 1;             // 1: Makima, 0: PCHIP

  // 自动增益补偿与输出增益门
  static const bool bassAutoGain = false;
  static const double bassOutputGain = 0.0;     // [-12, 6] dB
  static const bool eqAutoGain = false;
  static const double eqOutputGain = 0.0;       // [-12, 6] dB
  static const bool reverbAutoGain = false;
  static const double reverbOutputGain = 0.0;   // [-12, 6] dB
  static const bool tubeAutoGain = false;
  static const double tubeOutputGain = 0.0;     // [-12, 6] dB
  static const bool compAutoGain = false;
  static const double compOutputGain = 0.0;     // [-12, 6] dB

  // 噪声门 + Deesser
  static const double gateThreshold = -40.0;   // dB [-60,0]
  static const double gateAttack = 10.0;       // ms [1,100]
  static const double gateRelease = 100.0;     // ms [10,500]
  static const double deesserFreq = 6000.0;    // Hz [2000,10000]
  static const double deesserAmount = 0.5;     // [0,1]

  // 全参数动态EQ（3 段）
  static const double dyneqAttack = 2.0;       // ms [0.1,100]
  static const double dyneqRelease = 120.0;    // ms [10,1000]
  static const double dyneqLowFreq = 120.0;    // Hz [20,500]
  static const double dyneqLowQ = 0.707;       // shelf S [0.5,2]
  static const double dyneqLowGain = 0.0;      // dB [-12,12]
  static const double dyneqLowRange = 6.0;     // dB [0,24]
  static const double dyneqLowThreshold = -30.0; // dBFS [-60,0]
  static const double dyneqMidFreq = 1000.0;   // Hz [200,8000]
  static const double dyneqMidQ = 1.0;         // bell Q [0.3,10]
  static const double dyneqMidGain = 0.0;
  static const double dyneqMidRange = 6.0;
  static const double dyneqMidThreshold = -30.0;
  static const double dyneqHighFreq = 6000.0;  // Hz [2000,20000]
  static const double dyneqHighQ = 0.707;
  static const double dyneqHighGain = 0.0;
  static const double dyneqHighRange = 6.0;
  static const double dyneqHighThreshold = -30.0;

  // 响度补偿
  static const double loudnessAmount = 0.5;    // [0,1]
  static const bool arbmagAutoGain = false;
  static const double arbmagOutputGain = 0.0;   // [-12, 6] dB

  // 任意响应 EQ (ArbMag)
  static const bool arbmagOn = false;
  static const String arbmagString = '';
}

class AppModel extends ChangeNotifier {
  /// 声场展宽的引擎侧安全上限。
  /// libjamesdsp 的展宽在 mix=1.0 时执行 `band - centre`（中置完全剥离），
  /// 单声道内容会直接归零（表现为"拉满几乎没声音"）。UI 0..100% 线性映射到
  /// 引擎 0..0.75，既保留可感知的展宽，又不会把人声剥空。
  /// 声场展宽的引擎满量程（UI 0..1 → 引擎 0..本值）。
  ///
  /// 此前这里是 `static const = 0.75`，config 里的同名字段被持久化、被单测断言，
  /// 却从未参与换算——改 config.json 对听感零影响。现在直接读 config。
  /// 引擎侧上限仍是 1.0（vendor mix=1.0 会走 band-centre 中置全剥离导致静音），
  /// 故这里夹到 1.0 以内。
  double get stereoWidenMax => config.stereoWidenMax.clamp(0.0, 1.0);

  SendPort? _toIso;
  Isolate? _iso;

  // 引擎连接与状态
  EngineConn conn = EngineConn.connecting;
  String? fatalMsg;
  EngineInfo? info;

  /// 设备实际采样率（插件延迟、IR 时长等「样本 → 毫秒」换算的唯一依据）。
  /// 引擎创建后固定不变；info 尚未就绪时回退 48k。
  int get deviceRate => info?.deviceRate ?? 48000;

  /// EQ 建模必须使用的采样率：协商后的实际引擎采样率。
  ///
  /// `config.sampleRate` 只是发给设备的请求值，设备可能拒绝并回退到原生采样率。
  /// 频率网格、曲线钳位和响应探针都必须用实际值，否则三者在不同的采样率假设下
  /// 各自为政。info 尚未就绪时暂时用配置值，`ready` 事件到达后会按实际值重建。
  int get engineRate {
    final negotiated = info?.deviceRate ?? 0;
    if (negotiated > 0) return negotiated;
    return config.sampleRate > 0 ? config.sampleRate : 48000;
  }
  int engineState = 0; // 0=bypass 1=processing 2=error
  double latencyMs = 0;
  bool playing = false;
  bool bypass = false;
  String sourceKind = ''; // '' | 'tone' | 'pink' | 'file'
  String sourceExt = ''; // 文件源扩展名（小写无点，如 'mp3'/'wav'；非文件源为空）

  // 参数镜像（engine 侧真相，UI 只做回显与乐观更新）
  bool bassOn = false, eqOn = false, limiterOn = true;
  double bassGain = ParamDefaults.bassGain,
      stereoMix = ParamDefaults.stereoMix,
      postGain = ParamDefaults.postGain,
      inputGain = ParamDefaults.inputGain,
      inputBalanceL = ParamDefaults.inputBalanceL,
      inputBalanceR = ParamDefaults.inputBalanceR;
  int reverbPreset = -1;
  int channelsMode = 0;

  // Liveprog（v1.1）：status 0=无代码 1=编译成功 <0=引擎错误码
  bool lpEnabled = false;
  int lpStatus = 0;
  String? lpError; // 最近一次编译错误文案（事件条已显示，这里供编辑页内联标红）
  final List<double> lpParams = List.filled(8, 0);
  // v3：上次 liveprog.code 下发的引擎侧编译耗时（ms），-1 = 未知。
  // isolate 早已实测 tookMs（此前只记日志），现回传供胶囊展示与慢编译提醒。
  int lpCompileMs = -1;
  // v2：预设存档时的代码指纹与当前编辑器代码不一致（全文不在预设里，
  // 恢复的滑块可能对不上号；UI 预留徽标位，当前仅置位不展示）。
  bool lpPresetCodeMismatch = false;
  // v2：上次应用代码的滑块声明签名。签名不变的重应用（改注释/调格式）
  // 保留用户已调的滑块值；声明变化才采纳新默认值。
  String _lpDeclSig = '';

  // 卷积 / IR（v1.1 M4）：meta 由引擎门卫校验后回读
  bool convEnabled = false, convReady = false;
  int convFrames = 0, convChannels = 0, convSrcRate = 0;
  double convPeak = 0.0;
  List<List<double>> convSpectrum = [];

  /// IR 是否经过重采样：比较文件原始采样率与协商后的实际设备采样率。
  ///
  /// 不能用硬编码采样率，因为请求采样率可能被设备拒绝，
  /// 引擎实际一律按协商后的采样率工作。
  static bool irWasResampled({required int srcRate, required int deviceRate}) =>
      srcRate != 0 && srcRate != deviceRate;

  // M3-a：轻量效果
  bool tubeOn = false, xfeedOn = false;
  int xfeedMode = 0; // 0: Default, 1: Chu Moy, 2: Jan Meier, 3: Custom
  double xfeedFcut = 700.0; // 300..2000 Hz
  double xfeedFeed = 4.5; // 1.0..15.0 dB

  // 动态压限器（Compander）
  bool compOn = false;
  double compTimeconstant = 0.14;
  int compGranularity = 1;
  int compTfresolution = 1;

  // M5/P-002：声场分带（0..1 每带；bandUsed=false 时随总滑块统一）
  final List<double> stereoBands = List.filled(5, 0.5);
  bool stereoBandUsed = false;
  // 声场开关（v1.2）：独立于滑块值的生效位。
  // 旧语义 stereoOn = mix>0 导致“滑块拉到 0 即关开关→滑块被禁用→卡死”，
  // 现开关只管是否生效，关闭时引擎侧收 0、UI 滑块值保留。
  bool stereoOn = false;

  // 脉冲响应干湿比 + VDC
  double convMix = 1.0;
  bool ddcOn = false, ddcReady = false;

  // M5-b：低频搁架
  bool shelfOn = false;
  double shelfFreq = 100, shelfGain = 0;
  // 低频单声道化（BassMono，链头）
  bool bassmonoOn = false;
  double bassmonoFreq = 120;
  // Haas 差分环绕（stereo 后 / reverb 前）
  bool haasOn = false;
  double haasDelayMs = 12, haasMix = 1.0;
  int haasSide = 0; // 0=延迟右 1=延迟左
  // 激励器（Haas 后 / reverb 前，最后一道音色工序）
  bool exciterOn = false;
  double exciterAmount = 0.3, exciterHifreq = 5000;

  // M5-c：空间混响（Freeverb / Spatial Reverb）
  bool fvOn = false;
  double fvDecay = 0.5, fvDamp = 0.5, fvWet = 0.35, fvDry = 1.0;
  double fvRoomSize = 1.2, fvWidth = 1.0;
  bool get isSpatialReverbOn => reverbPreset >= 0 || fvOn;

  // M3.5-a：处理顺序（Dart 镜像；引擎侧表驱动 P-004）
  String? graphOrder;

  // 自动增益补偿与输出增益门
  bool bassAutoGain = ParamDefaults.bassAutoGain;
  double bassOutputGain = ParamDefaults.bassOutputGain;
  bool eqAutoGain = ParamDefaults.eqAutoGain;
  double eqOutputGain = ParamDefaults.eqOutputGain;
  bool reverbAutoGain = ParamDefaults.reverbAutoGain;
  double reverbOutputGain = ParamDefaults.reverbOutputGain;
  bool tubeAutoGain = ParamDefaults.tubeAutoGain;
  double tubeOutputGain = ParamDefaults.tubeOutputGain;
  bool compAutoGain = ParamDefaults.compAutoGain;
  double compOutputGain = ParamDefaults.compOutputGain;

  // 噪声门（链头）+ Deesser + 自动增益补偿
  bool gateOn = false;
  double gateThreshold = -40, gateAttackMs = 10, gateReleaseMs = 100;
  bool gateAutoGain = false;
  bool deesserOn = false;
  double deesserFreq = 6000, deesserAmount = 0.5;

  // 全参数动态EQ（3 段；默认全关）
  bool dyneqOn = false;
  double dyneqAttackMs = ParamDefaults.dyneqAttack;
  double dyneqReleaseMs = ParamDefaults.dyneqRelease;
  bool dyneqLowOn = false, dyneqMidOn = false, dyneqHighOn = false;
  double dyneqLowFreq = ParamDefaults.dyneqLowFreq;
  double dyneqLowQ = ParamDefaults.dyneqLowQ;
  double dyneqLowGain = ParamDefaults.dyneqLowGain;
  double dyneqLowRange = ParamDefaults.dyneqLowRange;
  double dyneqLowThreshold = ParamDefaults.dyneqLowThreshold;
  double dyneqMidFreq = ParamDefaults.dyneqMidFreq;
  double dyneqMidQ = ParamDefaults.dyneqMidQ;
  double dyneqMidGain = ParamDefaults.dyneqMidGain;
  double dyneqMidRange = ParamDefaults.dyneqMidRange;
  double dyneqMidThreshold = ParamDefaults.dyneqMidThreshold;
  double dyneqHighFreq = ParamDefaults.dyneqHighFreq;
  double dyneqHighQ = ParamDefaults.dyneqHighQ;
  double dyneqHighGain = ParamDefaults.dyneqHighGain;
  double dyneqHighRange = ParamDefaults.dyneqHighRange;
  double dyneqHighThreshold = ParamDefaults.dyneqHighThreshold;

  // 响度补偿（Stage 3 后 / 安全钳位前，最后一道音色工序）
  bool loudnessOn = false;
  double loudnessAmount = 0.5;
  bool arbmagOn = ParamDefaults.arbmagOn;
  String arbmagString = ParamDefaults.arbmagString;
  bool arbmagReady = false;
  int arbmagNodeCount = 0;
  bool arbmagAutoGain = ParamDefaults.arbmagAutoGain;
  double arbmagOutputGain = ParamDefaults.arbmagOutputGain;

  // 低音重构（Phase 4）
  double bassIntensity = ParamDefaults.bassIntensity;
  int bassMode = ParamDefaults.bassMode;
  double bassCutoff = ParamDefaults.bassCutoff;
  double bassHarmonics = ParamDefaults.bassHarmonics;
  double bassHarmonicBlend = ParamDefaults.bassHarmonicBlend;
  double bassSubFloor = ParamDefaults.bassSubFloor;

  // 独立滤波器（gate 后 / bassmono 前）
  bool filterOn = false;
  int filterType = ParamDefaults.filterType;
  double filterFreq = ParamDefaults.filterFreq;
  double filterQ = ParamDefaults.filterQ;

  // 电子管模拟器（Phase 4）
  double tubeGain = ParamDefaults.tubeGain;
  int tubeStyle = ParamDefaults.tubeStyle;
  int tubeOversampling = ParamDefaults.tubeOversampling;
  double tubeCompensation = ParamDefaults.tubeCompensation;
  double tubeMix = ParamDefaults.tubeMix;

  // 多段图形均衡器（Phase 3）
  static const List<double> eqFreqs7 = [50, 150, 400, 1000, 3000, 8000, 16000];
  static const List<double> eqFreqs10 = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000];
  static const List<double> eqFreqs15 = [25, 40, 63, 100, 160, 250, 400, 630, 1000, 1600, 2500, 4000, 6300, 10000, 16000];
  static const List<double> eqFreqs31 = [20, 25, 31.5, 40, 50, 63, 80, 100, 125, 160, 200, 250, 315, 400, 500, 630, 800, 1000, 1250, 1600, 2000, 2500, 3150, 4000, 5000, 6300, 8000, 10000, 12500, 16000, 20000];

  /// C4：按当前采样率裁掉超过 Nyquist 的频带。
  ///
  /// 出厂网格是硬编码常量，顶端到 20 kHz，与采样率无关。原先在
  /// `_pushEqCurve` 里逐点 `math.min(f, nyquist)` 钳位 —— 这会让**多条
  /// 频带塌缩到同一个频率**：24 kHz（Nyquist 12k）下 31 段网格的
  /// 12500/16000/20000 三条全部变成 12000，连同 6300 以上的一串，
  /// 最终 31 个点塌成大量重复。引擎拿到这条退化坐标轴后，
  /// vendor 的 makima 在等距零点上求差分，插值结果毫无意义。
  ///
  /// 正确做法是**按频率裁掉整条频带**，让网格始终严格升序无重复；
  /// 增益随频带一起丢弃（`setEqBandsCount` 的重映射已按频率对齐，
  /// 低频段行为不受影响）。
  ///
  /// Nyquist 上限取 fs/2 并留一点点余量：恰好等于 Nyquist 的频点
  /// 在最小相位 IR 设计里仍属边界，稳妥起见一并裁掉。
  static List<double> eqGridFor(int count, int sampleRate) {
    final List<double> base = switch (count) {
      7 => eqFreqs7,
      10 => eqFreqs10,
      31 => eqFreqs31,
      _ => eqFreqs15,
    };
    if (sampleRate <= 0) return List<double>.from(base);
    final double nyq = sampleRate / 2.0;
    if (nyq >= 20000.0) return List<double>.from(base);
    final cut = base.where((f) => f < nyq * 0.995).toList();
    /* 极端采样率下（如 8 kHz，Nyquist 4k）可能一条不剩。
     * 此时退回该网格的最低频点，保住「至少一个锚点」——
     * 空网格会让引擎拒绝整条曲线（build_eq_axis 要求 >=2 点），
     * 那比一条退化但可用的曲线更糟。 */
    if (cut.isEmpty) return <double>[base.first];
    return cut;
  }

  /// UI 架构选项 → vendor `operatingMode`。
  ///
  /// 0 = 最小相位 FIR（默认，与探针同路）；
  /// 1 = 6 阶 IIR（`operatingMode=2`）；
  /// 2 = 12 阶 IIR（`operatingMode=5`）。
  /// 未知值回退到 FIR，保证可听、可测。
  static int eqOpModeForFilter(int filter) => switch (filter) {
        1 => 2,
        2 => 5,
        _ => 0,
      };

  /// 单座 RBJ 峰值钟形在频率 f 处的幅度（dB）。
  ///
  /// Q 的语义与教科书参数均衡器一致：Q 越大钟形越窄。
  /// 增益为 0 时恒返回 0（此时 Q 无声学意义，也不该影响目标曲线）。
  static double eqPeakingDb({
    required double f,
    required double center,
    required double gainDb,
    required double q,
    required int sampleRate,
  }) {
    if (gainDb.abs() < 1e-9) return 0.0;
    if (f <= 0 || center <= 0 || sampleRate <= 0) return 0.0;
    final qq = q.clamp(0.3, 10.0);
    final a = math.pow(10.0, gainDb / 40.0);
    final w0 = 2.0 * math.pi * center / sampleRate;
    final alpha = math.sin(w0) / (2.0 * qq);
    final cosW0 = math.cos(w0);
    final b0 = 1.0 + alpha * a;
    final b1 = -2.0 * cosW0;
    final b2 = 1.0 - alpha * a;
    final a0 = 1.0 + alpha / a;
    final a1 = -2.0 * cosW0;
    final a2 = 1.0 - alpha / a;
    final w = 2.0 * math.pi * f / sampleRate;
    final cosW = math.cos(w);
    final cos2W = math.cos(2.0 * w);
    final sinW = math.sin(w);
    final sin2W = math.sin(2.0 * w);
    final numRe = b0 + b1 * cosW + b2 * cos2W;
    final numIm = -(b1 * sinW + b2 * sin2W);
    final denRe = a0 + a1 * cosW + a2 * cos2W;
    final denIm = -(a1 * sinW + a2 * sin2W);
    final magSq =
        (numRe * numRe + numIm * numIm) / (denRe * denRe + denIm * denIm);
    if (magSq <= 0) return 0.0;
    return 10.0 * math.log(magSq) / math.ln10;
  }

  /// 把“各频点峰值增益 + 各点 Q”合成为引擎目标曲线。
  ///
  /// 对目标轴上每个频点，把全部钟形按 dB 相加（级联参量均衡的幅度叠加律）。
  /// 返回值与 [targetFreqs] 等长，可直接序列化为 `eq.curve` 的增益列。
  static List<double> eqTargetGains({
    required List<double> targetFreqs,
    required List<double> centers,
    required List<double> peakGains,
    required List<double> qs,
    required int sampleRate,
  }) {
    final n = math.min(
        centers.length, math.min(peakGains.length, qs.length));
    return List<double>.generate(targetFreqs.length, (i) {
      var total = 0.0;
      for (var b = 0; b < n; b++) {
        total += eqPeakingDb(
          f: targetFreqs[i],
          center: centers[b],
          gainDb: peakGains[b],
          q: qs[b],
          sampleRate: sampleRate,
        );
      }
      return total;
    });
  }

  int eqBandsCount = ParamDefaults.eqBandsCount;
  /// 初值先用 48k 网格；构造函数体里 `config` 加载完后会按真实采样率重建
  /// （字段初始化器先于构造函数体执行，那时 config 还没读出来）。
  List<double> eqFrequencies = eqGridFor(ParamDefaults.eqBandsCount, 48000);
  List<double> eqGains = List.filled(15, 0.0);

  /// 每个可调频点的 Q 值（与 [eqFrequencies] 等长对齐）。
  ///
  /// vendor 的任意幅度 FIR 路径本身没有“每点 Q”的概念，这里按参数均衡器语义
  /// 处理：每个频点是一座 RBJ 峰值钟形，Q 决定钟形宽度；下发前先把全部钟形
  /// 按 dB 叠加成目标曲线（见 [eqTargetGains]），再走既有的 `eq.curve` 通道。
  /// 因此 Q 的变化一定会改变曲线签名与引擎实测响应——Q 是真参，不是摆设。
  List<double> eqQs = List.filled(15, ParamDefaults.eqQ);

  /// 旧版全局 Q（兼容旧预设/会话里的标量 `q`）：新 Q 数组的缺省填充值。
  /// 新建频带与读到无 `qs` 的旧数据时，用它补齐。
  double eqQ = ParamDefaults.eqQ;
  int eqFilter = ParamDefaults.eqFilter;
  int eqInterp = ParamDefaults.eqInterp;
  String eqPresetName = 'flat';
  bool eqBypass = false;

  /// EQ 是否真正作用于音频链：全局开关与旁路必须同时满足。
  ///
  /// 背景谱合成和响应曲线都要用这个统一条件，不能只看旁路，
  /// 否则全局关闭后仍会叠加一条已失效的旧响应。
  bool get isEqActive => eqOn && !eqBypass;

  // 组件级延迟评估刷新时间戳
  final Map<String, int> _latencyRefreshTicks = {};
  int getComponentLatencyTick(String compId) => _latencyRefreshTicks[compId] ?? 0;

  // 用户偏好与外置配置
  late AppConfig config;
  String? activePresetName;
  String? convIrPath;
  String? ddcPath;
  String? ddcFileName;
  String? ddcDetails;
  double _lastStereoMix = 0.5;
  String? lpCode;
  Timer? _debounceSaveTimer;
  bool _isReplayingSession = false;

  AuraThemeId themeId = AuraThemeId.auraDark;
  Locale locale = const Locale('zh');
  // 注：延迟档（ADR-002）已由 ADR-006 撤销，不再有 latencyMode。
  // 延迟改为纯测量展示（组件级徽标 + 底栏总延迟），任何效果都可自由使能。

  // 高频可视化（独立 notifier，30fps）
  final spectrum = ValueNotifier<List<double>>(List.filled(32, 0));

  /// vendor 链入口（= 均衡器输入）的 32 段频谱，口径与 [spectrum] 相同。
  ///
  /// [spectrum] 取的是整条链的**最终输出**——EQ 之后的混响 / 卷积 /
  /// Freeverb / 插件全都算在内。拿它当均衡器面板的背景柱，用户看到的
  /// 频谱并不是均衡器输出的东西，调 EQ 时背景柱几乎不动。
  final eqInSpectrum = ValueNotifier<List<double>>(List.filled(32, 0));
  final levelL = ValueNotifier<double>(-90);
  final levelR = ValueNotifier<double>(-90);
  // [M3.5-c] 12 个 stage 的实时双声道微型电平 (dBFS)
  final stageLevelsL =
      ValueNotifier<List<double>>(List.filled(kEngineStageCount, -120.0));
  final stageLevelsR =
      ValueNotifier<List<double>>(List.filled(kEngineStageCount, -120.0));
  // 输入门控实时本级输入/输出电平 (dBFS)
  final inputMeterInL = ValueNotifier<double>(-120.0);
  final inputMeterInR = ValueNotifier<double>(-120.0);
  final inputMeterOutL = ValueNotifier<double>(-120.0);
  final inputMeterOutR = ValueNotifier<double>(-120.0);

  // 一次性事件（shell 监听弹 snackbar）
  final eventSeq = ValueNotifier<int>(0);
  GuardRejection? lastGuard;
  String? lastEngineError;
  String? lastInfo; // 非错误提示（如"已自动切到品质档"）
  int _guardSeq = 0;

  void clearLastInfo() {
    lastInfo = null;
  }

  void clearLastGuard() {
    lastGuard = null;
  }

  void clearLastEngineError() {
    lastEngineError = null;
  }

  /// 参数下发时刻（id → epoch ms），用于测量 点击→引擎确认 回环耗时
  final Map<String, int> _pendingSentAt = {};

  void _markSent(String id) {
    _pendingSentAt[id] = DateTime.now().millisecondsSinceEpoch;
  }

  late final PluginManager pluginManager;
  String? savedPluginPath;
  String savedPluginId = '';
  bool savedPluginBypass = false;
  final List<SavedPluginSlot> savedPluginSlots = [];

  ReceivePort? _fromIso;

  /// 测试隔离开关（Issue #2）：testing=true 时跳过音频 isolate 拉起
  /// 与 session 落盘（构造回放/防抖自动保存/dispose 保存）。
  /// 磁盘沙箱本身已有 `ConfigManager.baseDir`（FLUTTER_TEST 自动指临时目录），
  /// 这里解决的是另一半：真 isolate（拉 DLL + 开 WASAPI 设备）与竞态回读。
  /// 生产代码一律默认 false，行为零变化。
  final bool _testing;

  // ignore: prefer_initializing_formals (testing 是公开测试 API，不可用 this._testing 私有形参)
  AppModel({bool testing = false}) : _testing = testing {
    config = ConfigManager.load();
    /* C4：按真实采样率重建 EQ 网格。必须放在 config 加载之后 ——
     * 字段初始化器早于构造函数体，那时 config 还是默认值。
     * 不重建的话，低采样率用户拿到的是含越界频点的出厂网格。 */
    _rebuildEqGridForSampleRate(notify: false);
    locale = Locale(config.locale);
    themeId = AuraThemeId.values.firstWhere(
      (t) => t.name == config.themeId,
      orElse: () => AuraThemeId.auraDark,
    );
    pluginManager = PluginManager(commandSender: (msg) {
      _toIso?.send(msg);
    });
    pluginManager.addListener(notifyListeners);
    pluginManager.setCustomDirs(config.customPluginDirs);
    pluginManager.loadCache();

    if (config.autoRestoreSession && !_testing) {
      final session = SessionMemory.load();
      if (session != null) {
        SessionMemory.restoreMemoryImage(this, session);
      } else {
        SessionMemory.save(this);
      }
    }
    if (!_testing) _spawn();
  }

  void addCustomPluginDir(String dir) {
    final path = dir.trim();
    if (path.isNotEmpty && !config.customPluginDirs.contains(path)) {
      config.customPluginDirs.add(path);
      ConfigManager.save(config);
      pluginManager.setCustomDirs(config.customPluginDirs);
      notifyListeners();
    }
  }

  void removeCustomPluginDir(String dir) {
    if (config.customPluginDirs.remove(dir)) {
      ConfigManager.save(config);
      pluginManager.setCustomDirs(config.customPluginDirs);
      notifyListeners();
    }
  }

  void addCustomScriptDir(String dir) {
    final path = dir.trim();
    if (path.isNotEmpty && !config.customScriptDirs.contains(path)) {
      config.customScriptDirs.add(path);
      ConfigManager.save(config);
      notifyListeners();
    }
  }

  void removeCustomScriptDir(String dir) {
    if (config.customScriptDirs.remove(dir)) {
      ConfigManager.save(config);
      notifyListeners();
    }
  }

  void scheduleAutoSave() {
    if (_testing || _isReplayingSession) return;
    _debounceSaveTimer?.cancel();
    _debounceSaveTimer = Timer(
      Duration(milliseconds: config.autoSaveDebounceMs),
      () => SessionMemory.save(this),
    );
  }

  void _spawn() {
    conn = EngineConn.connecting;
    notifyListeners();
    final port = ReceivePort();
    _fromIso = port;
    // 把 config 里真正被引擎消费的字段随 isolate 一起传下去。
    // 此前这些字段只被序列化到 config.json，生产代码从不读取（改配置零效果）。
    Isolate.spawn(audioIsolateMain, {
      'toMain': port.sendPort,
      'maxBlockFrames': config.maxBlockFrames,
      'vizFps': config.vizFps,
      'sampleRate': config.sampleRate,
      'vizFftSize': config.vizFftSize,
      'maxIrDurationSeconds': config.maxIrDurationSeconds,
      'maxFileSizeMb': config.maxFileSizeMb,
    }).then((iso) {
      _iso = iso;
    });
    port.listen(_onMessage);
  }

  void _onMessage(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['evt'] as String) {
      case 'isoReady':
        _toIso = raw['port'] as SendPort;
        break;
      case 'ready':
        info = EngineInfo(raw['abi'] as int, raw['version'] as String,
            raw['deviceRate'] as int, raw['deviceCh'] as int,
            raw['bufferFrames'] as int);
        // 协商采样率可能与请求值不同：EQ 网格必须按实际引擎采样率重建，
        // 否则曲线、响应和生产链使用三套不同的频率假设。
        _rebuildEqGridForSampleRate(notify: false);
        latencyMs = (raw['latencyMs'] as num).toDouble();
        conn = EngineConn.ready;
        engineState = 1;
        notifyListeners();
        if (config.autoRestoreSession) {
          replaySessionToEngine();
        } else {
          _toIso?.send({'cmd': 'getParams'});
        }
        break;
      case 'params':
        bassOn = (raw['bassEnable'] as int) != 0;
        bassGain = (raw['bassGain'] as num).toDouble();
        reverbPreset = raw['reverbPreset'] as int;
        // 引擎真相是 0..stereoWidenMax，换算回 UI 显示刻度 0..1
        stereoMix =
            ((raw['stereoMix'] as num).toDouble() / stereoWidenMax).clamp(0.0, 1.0);
        eqOn = (raw['eqEnable'] as int) != 0;
        postGain = (raw['postGain'] as num).toDouble();
        limiterOn = (raw['limiterEnable'] as int) != 0;
        lpEnabled = (raw['lpEnable'] as int) != 0;
        lpStatus = raw['lpStatus'] as int;
        convEnabled = (raw['convEnable'] as int) != 0;
        convReady = (raw['convReady'] as int) != 0;
        // auto-bypass 的另一半：资源在此刻就绪且用户开关为开 → 立即生效，
        // 无需用户再拨一次开关。
        if (convReady && convEnabled) {
          _markSent(ParamId.convEnable);
          send({
            'cmd': 'setParam',
            'id': ParamId.convEnable,
            'value': 1,
            'isFloat': false
          });
        }
        convFrames = raw['convFrames'] as int;
        convChannels = raw['convChannels'] as int;
        convSrcRate = raw['convSrcRate'] as int;
        convPeak = (raw['convPeak'] as num).toDouble();
        if (raw['convSpectrum'] != null) {
          convSpectrum = (raw['convSpectrum'] as List)
              .map((e) => (e as List).cast<double>().toList())
              .toList();
        } else if (!convReady) {
          convSpectrum = [];
        }
        tubeOn = (raw['tubeEnable'] as int) != 0;
        // P-011：电子管音色/混合/补偿回读
        if (raw['tubeStyle'] != null) tubeStyle = (raw['tubeStyle'] as int).clamp(0, 2);
        if (raw['tubeMix'] != null) tubeMix = (raw['tubeMix'] as num).toDouble().clamp(0.0, 1.0);
        if (raw['tubeCompensation'] != null) {
          tubeCompensation = (raw['tubeCompensation'] as num).toDouble().clamp(-12.0, 12.0);
        }
        xfeedOn = (raw['xfeedEnable'] as int) != 0;
        if (raw['xfeedMode'] != null) xfeedMode = raw['xfeedMode'] as int;
        if (raw['xfeedFcut'] != null) xfeedFcut = (raw['xfeedFcut'] as num).toDouble();
        if (raw['xfeedFeed'] != null) xfeedFeed = (raw['xfeedFeed'] as num).toDouble();
        stereoBandUsed = (raw['stereoBandUsed'] as int) != 0;
        convMix = (raw['convMix'] as num).toDouble();
        // auto-bypass 的另一半：资源此刻就绪且用户开关为开 → 立即生效。
        // 同样必须直接 send，绕开 _mirror 对 ddcOn 的回写（否则开关被翻回）。
        if (ddcReady && ddcOn && (raw['ddcEnable'] as int) == 0) {
          _markSent(ParamId.ddcEnable);
          send({
            'cmd': 'setParam',
            'id': ParamId.ddcEnable,
            'value': 1,
            'isFloat': false
          });
        }
        shelfOn = (raw['shelfEnable'] as int) != 0;
        shelfFreq = (raw['shelfFreq'] as num).toDouble();
        shelfGain = (raw['shelfGain'] as num).toDouble();
        if (raw['bassmonoEnable'] != null) {
          bassmonoOn = (raw['bassmonoEnable'] as int) != 0;
        }
        if (raw['bassmonoFreq'] != null) {
          bassmonoFreq = (raw['bassmonoFreq'] as num).toDouble();
        }
        if (raw['haasEnable'] != null) {
          haasOn = (raw['haasEnable'] as int) != 0;
        }
        if (raw['haasDelay'] != null) {
          haasDelayMs = (raw['haasDelay'] as num).toDouble();
        }
        if (raw['haasMix'] != null) {
          haasMix = (raw['haasMix'] as num).toDouble();
        }
        if (raw['haasSide'] != null) {
          haasSide = (raw['haasSide'] as int) != 0 ? 1 : 0;
        }
        if (raw['exciterEnable'] != null) {
          exciterOn = (raw['exciterEnable'] as int) != 0;
        }
        if (raw['exciterAmount'] != null) {
          exciterAmount = (raw['exciterAmount'] as num).toDouble();
        }
        if (raw['exciterHifreq'] != null) {
          exciterHifreq = (raw['exciterHifreq'] as num).toDouble();
        }
        // P-010：每效果输出增益门 + 自动补偿
        if (raw['bassOutGain'] != null) bassOutputGain = (raw['bassOutGain'] as num).toDouble();
        if (raw['bassAutoGain'] != null) bassAutoGain = (raw['bassAutoGain'] as int) != 0;
        if (raw['eqOutGain'] != null) eqOutputGain = (raw['eqOutGain'] as num).toDouble();
        if (raw['eqAutoGain'] != null) eqAutoGain = (raw['eqAutoGain'] as int) != 0;
        if (raw['tubeOutGain'] != null) tubeOutputGain = (raw['tubeOutGain'] as num).toDouble();
        if (raw['tubeAutoGain'] != null) tubeAutoGain = (raw['tubeAutoGain'] as int) != 0;
        if (raw['compOutGain'] != null) compOutputGain = (raw['compOutGain'] as num).toDouble();
        if (raw['compAutoGain'] != null) compAutoGain = (raw['compAutoGain'] as int) != 0;
        if (raw['reverbOutGain'] != null) reverbOutputGain = (raw['reverbOutGain'] as num).toDouble();
        if (raw['reverbAutoGain'] != null) reverbAutoGain = (raw['reverbAutoGain'] as int) != 0;
        if (raw['gateEnable'] != null) gateOn = (raw['gateEnable'] as int) != 0;
        if (raw['gateThreshold'] != null) gateThreshold = (raw['gateThreshold'] as num).toDouble();
        if (raw['gateAttack'] != null) gateAttackMs = (raw['gateAttack'] as num).toDouble();
        if (raw['gateRelease'] != null) gateReleaseMs = (raw['gateRelease'] as num).toDouble();
        if (raw['gateAutoGain'] != null) gateAutoGain = (raw['gateAutoGain'] as int) != 0;
        if (raw['deesserEnable'] != null) deesserOn = (raw['deesserEnable'] as int) != 0;
        if (raw['deesserFreq'] != null) deesserFreq = (raw['deesserFreq'] as num).toDouble();
        if (raw['deesserAmount'] != null) deesserAmount = (raw['deesserAmount'] as num).toDouble();
        if (raw['dyneqEnable'] != null) dyneqOn = (raw['dyneqEnable'] as int) != 0;
        if (raw['dyneqAttack'] != null) dyneqAttackMs = (raw['dyneqAttack'] as num).toDouble();
        if (raw['dyneqRelease'] != null) dyneqReleaseMs = (raw['dyneqRelease'] as num).toDouble();
        if (raw['dyneqLowEnable'] != null) dyneqLowOn = (raw['dyneqLowEnable'] as int) != 0;
        if (raw['dyneqLowFreq'] != null) dyneqLowFreq = (raw['dyneqLowFreq'] as num).toDouble();
        if (raw['dyneqLowQ'] != null) dyneqLowQ = (raw['dyneqLowQ'] as num).toDouble();
        if (raw['dyneqLowGain'] != null) dyneqLowGain = (raw['dyneqLowGain'] as num).toDouble();
        if (raw['dyneqLowRange'] != null) dyneqLowRange = (raw['dyneqLowRange'] as num).toDouble();
        if (raw['dyneqLowThreshold'] != null) dyneqLowThreshold = (raw['dyneqLowThreshold'] as num).toDouble();
        if (raw['dyneqMidEnable'] != null) dyneqMidOn = (raw['dyneqMidEnable'] as int) != 0;
        if (raw['dyneqMidFreq'] != null) dyneqMidFreq = (raw['dyneqMidFreq'] as num).toDouble();
        if (raw['dyneqMidQ'] != null) dyneqMidQ = (raw['dyneqMidQ'] as num).toDouble();
        if (raw['dyneqMidGain'] != null) dyneqMidGain = (raw['dyneqMidGain'] as num).toDouble();
        if (raw['dyneqMidRange'] != null) dyneqMidRange = (raw['dyneqMidRange'] as num).toDouble();
        if (raw['dyneqMidThreshold'] != null) dyneqMidThreshold = (raw['dyneqMidThreshold'] as num).toDouble();
        if (raw['dyneqHighEnable'] != null) dyneqHighOn = (raw['dyneqHighEnable'] as int) != 0;
        if (raw['dyneqHighFreq'] != null) dyneqHighFreq = (raw['dyneqHighFreq'] as num).toDouble();
        if (raw['dyneqHighQ'] != null) dyneqHighQ = (raw['dyneqHighQ'] as num).toDouble();
        if (raw['dyneqHighGain'] != null) dyneqHighGain = (raw['dyneqHighGain'] as num).toDouble();
        if (raw['dyneqHighRange'] != null) dyneqHighRange = (raw['dyneqHighRange'] as num).toDouble();
        if (raw['dyneqHighThreshold'] != null) dyneqHighThreshold = (raw['dyneqHighThreshold'] as num).toDouble();
        if (raw['loudnessEnable'] != null) loudnessOn = (raw['loudnessEnable'] as int) != 0;
        if (raw['loudnessAmount'] != null) loudnessAmount = (raw['loudnessAmount'] as num).toDouble();
        if (raw['bassHarmonics'] != null) bassHarmonics = (raw['bassHarmonics'] as num).toDouble();
        if (raw['bassHarmonicBlend'] != null) bassHarmonicBlend = (raw['bassHarmonicBlend'] as num).toDouble();
        if (raw['bassSubFreq'] != null) bassSubFloor = (raw['bassSubFreq'] as num).toDouble();
        if (raw['bassCutoffF'] != null) bassCutoff = (raw['bassCutoffF'] as num).toDouble();
        if (raw['filterEnable'] != null) filterOn = (raw['filterEnable'] as int) != 0;
        if (raw['filterType'] != null) filterType = (raw['filterType'] as int).clamp(0, 2);
        if (raw['filterFreq'] != null) filterFreq = (raw['filterFreq'] as num).toDouble();
        if (raw['filterQ'] != null) filterQ = (raw['filterQ'] as num).toDouble();
        fvOn = (raw['fvEnable'] as int) != 0;
        fvDecay = (raw['fvDecay'] as num).toDouble();
        fvDamp = (raw['fvDamp'] as num).toDouble();
        fvWet = (raw['fvWet'] as num).toDouble();
        fvDry = (raw['fvDry'] as num).toDouble();
        if (raw['compEnable'] != null) compOn = (raw['compEnable'] as int) != 0;
        if (raw['compTimeconstant'] != null) compTimeconstant = (raw['compTimeconstant'] as num).toDouble();
        if (raw['compGranularity'] != null) compGranularity = raw['compGranularity'] as int;
        if (raw['compTfresolution'] != null) compTfresolution = raw['compTfresolution'] as int;
        if (raw['arbmagReady'] != null) arbmagReady = (raw['arbmagReady'] as int) != 0;
        if (raw['arbmagNodeCount'] != null) arbmagNodeCount = raw['arbmagNodeCount'] as int;
        if (raw['arbmagEnable'] != null) {
          final en = (raw['arbmagEnable'] as int) != 0;
          if (arbmagReady && arbmagOn && !en) {
            _markSent(ParamId.arbmagEnable);
            send({'cmd': 'setParam', 'id': ParamId.arbmagEnable, 'value': 1, 'isFloat': false});
          } else if (!arbmagOn || arbmagReady) {
            arbmagOn = en;
          }
        }
        notifyListeners();
        break;
      case 'arbmag':
        arbmagNodeCount = (raw['nodes'] as int?) ?? 0;
        arbmagReady = (raw['ready'] as int?) == 1;
        if (arbmagReady && arbmagOn) {
          _markSent(ParamId.arbmagEnable);
          send({'cmd': 'setParam', 'id': ParamId.arbmagEnable, 'value': 1, 'isFloat': false});
        }
        notifyListeners();
        break;
      case 'liveprog':
        lpStatus = raw['status'] as int;
        if (lpStatus == 1) lpError = null;
        notifyListeners();
        break;
      case 'fatal':
        conn = EngineConn.fatal;
        fatalMsg = raw['msg'] as String;
        notifyListeners();
        break;
      case 'state':
        engineState = raw['state'] as int;
        latencyMs = (raw['latencyMs'] as num).toDouble();
        notifyListeners();
        break;
      case 'playing':
        playing = raw['playing'] as bool;
        notifyListeners();
        break;
      case 'paramResult':
        final rc = raw['rc'] as int;
        final id = raw['id'] as String;
        final t0 = _pendingSentAt.remove(id);
        if (t0 != null) {
          // 点击 → 引擎确认 的回环耗时（定位"生效慢"到底慢在哪一段）
          dbgLog('rt $id = ${DateTime.now().millisecondsSinceEpoch - t0}ms rc=$rc');
        }
        // v3：脚本编译耗时回传（成功失败都记，供胶囊展示）
        if (id == ParamId.lpCode && raw['tookMs'] is int) {
          lpCompileMs = raw['tookMs'] as int;
        }
        if (rc != 0) {
          lastGuard = GuardRejection(
              id, (raw['msg'] as String?) ?? 'engine rc=$rc', rc);
          if (id == ParamId.lpCode || id.startsWith('liveprog.')) {
            lpError = lastGuard!.message; // 编辑页内联标红用
          }          eventSeq.value = ++_guardSeq;
          notifyListeners();
          // 引擎拒绝 → 回读引擎真相，抹掉 _mirror 的乐观假象
          // （否则界面会一直显示"已选中"，但引擎里根本没生效）
          _toIso?.send({'cmd': 'getParams'});
        } else if (id == ParamId.convIrPath) {
          // IR 加载成功 → 回读 meta（frames/channels/srcRate/peak）
          _toIso?.send({'cmd': 'getParams'});
        }
        break;
      case 'viz':
        spectrum.value = (raw['spectrum'] as List).cast<double>();
        if (raw['eqIn'] != null) {
          eqInSpectrum.value = (raw['eqIn'] as List).cast<double>();
        }
        levelL.value = (raw['l'] as num).toDouble();
        levelR.value = (raw['r'] as num).toDouble();
        if (raw['stageL'] != null) {
          stageLevelsL.value = (raw['stageL'] as List).cast<num>().map((e) => e.toDouble()).toList();
        }
        if (raw['stageR'] != null) {
          stageLevelsR.value = (raw['stageR'] as List).cast<num>().map((e) => e.toDouble()).toList();
        }
        if (raw['inputInL'] != null) {
          inputMeterInL.value = (raw['inputInL'] as num).toDouble();
        }
        if (raw['inputInR'] != null) {
          inputMeterInR.value = (raw['inputInR'] as num).toDouble();
        }
        if (raw['inputOutL'] != null) {
          inputMeterOutL.value = (raw['inputOutL'] as num).toDouble();
        }
        if (raw['inputOutR'] != null) {
          inputMeterOutR.value = (raw['inputOutR'] as num).toDouble();
        }
        break;
      case 'error':
        lastEngineError = raw['msg'] as String;
        eventSeq.value = ++_guardSeq;
        notifyListeners();
        break;
      case 'pluginScanProgress':
        // C2：扫描分块推进中的进度回执（已处理候选 / 候选总数 / 已发现插件）。
        pluginManager.onPluginScanProgress(
          raw['done'] as int? ?? 0,
          raw['total'] as int? ?? 0,
          raw['found'] as int? ?? 0,
        );
        // 不 notifyListeners 由被监听对象自身触发（见 onPluginScanProgress），
        // 这里仅保证 UI 至少刷新一次。
        notifyListeners();
        break;
      case 'pluginScanned':
        pluginManager.onPluginScanned(raw['count'] as int, raw['json']);
        notifyListeners();
        break;
      case 'pluginList':
        pluginManager.onPluginList(raw['json']);
        notifyListeners();
        break;
      case 'pluginLoaded':
        pluginManager.onPluginLoaded(
            raw['path'] as String, raw['rc'] as int, raw['status']);
        scheduleAutoSave();
        notifyListeners();
        break;
      case 'pluginUnloaded':
        pluginManager.onPluginUnloaded(raw['rc'] as int, raw['status']);
        scheduleAutoSave();
        notifyListeners();
        break;
      case 'pluginBypass':
        pluginManager.onPluginBypass(raw['bypass'] as bool, raw['status']);
        scheduleAutoSave();
        notifyListeners();
        break;
      case 'pluginStatus':
        pluginManager.onPluginStatus(raw['status']);
        notifyListeners();
        break;
      case 'pluginSlotLoaded':
        pluginManager.onPluginSlotLoaded(
            raw['slot'] as int,
            raw['path'] as String,
            raw['rc'] as int,
            raw['status'],
            (raw['stage'] as num).toInt());
        scheduleAutoSave();
        notifyListeners();
        break;
      case 'pluginSlotBusy':
        pluginManager.onPluginSlotBusy(
            raw['slot'] as int, raw['busy'] as bool);
        break;
      case 'pluginSlotUnloaded':
        pluginManager.onPluginSlotUnloaded(
            raw['slot'] as int, raw['rc'] as int, raw['status']);
        scheduleAutoSave();
        notifyListeners();
        break;
      case 'pluginSlotBypass':
        pluginManager.onPluginSlotBypass(
            raw['slot'] as int, raw['bypass'] as bool, raw['status']);
        scheduleAutoSave();
        notifyListeners();
        break;
      case 'pluginSlotStatus':
        pluginManager.onPluginSlotStatus(
            raw['slot'] as int, raw['status'], (raw['stage'] as num).toInt());
        notifyListeners();
        break;
      case 'pluginSlotInsertStage':
        pluginManager.onPluginSlotInsertStage(
            raw['slot'] as int, (raw['stage'] as num).toInt(), raw['rc'] as int);
        scheduleAutoSave();
        notifyListeners();
        break;
      case 'pluginSlotPresetSaved':
        lastInfo = '预设已保存成功';
        eventSeq.value = ++_guardSeq;
        notifyListeners();
        break;
      case 'pluginSlotPresetLoaded':
        lastInfo = '预设已载入成功';
        eventSeq.value = ++_guardSeq;
        scheduleAutoSave();
        notifyListeners();
        break;
      case 'pluginSlotEditorResult':
        // 此前该事件被发出却无人处理：插件原生 GUI 打开失败对用户完全静默。
        final slot = (raw['slot'] as num?)?.toInt() ?? 0;
        final isShow = raw['action'] == 'show';
        final ok = (raw['rc'] as num?)?.toInt() != 0;
        if (ok) {
          lastInfo = isShow ? '插件 ${slot + 1} 界面已打开' : '插件 ${slot + 1} 界面已关闭';
        } else {
          lastEngineError = isShow
              ? '插件 ${slot + 1} 未能打开界面（该插件可能不提供 GUI，或初始化失败）'
              : '插件 ${slot + 1} 关闭界面失败';
        }
        eventSeq.value = ++_guardSeq;
        notifyListeners();
        break;
      case 'componentLatency':
        final comp = raw['comp'] as String? ?? '';
        final rc = (raw['rc'] as num?)?.toInt() ?? -2;
        final samples = (raw['samples'] as num?)?.toInt() ?? 0;
        _onComponentLatencyResult(comp, rc, samples);
        break;
      default:
        // 兜底：未知事件至少留痕，避免再次出现「发了但静默丢弃」。
        // 绝不 notifyListeners()，未知事件不应引发 UI 重建。
        break;
    }
  }

  void send(Map<String, dynamic> m) {
    _toIso?.send(m);
  }
  /* ---- 命令 ---- */

  /// 混响预设：废除品质档拦截限制，无条件自由放行
  void setReverbPreset(int v, {String? autoQualityMsg}) {
    setInt('reverb.preset', v);
  }

  void setInt(String id, int v) {
    _mirror(id, v.toDouble());
    _markSent(id);
    notifyListeners();
    if (id == 'bass.enable' && v == 0) {
      // 先渐变到 0 再关闭，避免直接置 0 造成「哒」一声。
      _disableBassRamped();
    } else {
      send({'cmd': 'setParam', 'id': id, 'value': v, 'isFloat': false});
    }
    scheduleAutoSave();
  }

  void setFloat(String id, double v) {
    _mirror(id, v);
    _markSent(id);
    notifyListeners();
    if (id == 'bass.gain') {
      // 低音拖动约 60Hz 触发，而 BassBoostSetParam 运行在**驱动 WASAPI 的
      // 同一线程**上（setParam 与 pump 同属一个 isolate）——不存在数据竞争，
      // 真实成因是每次调用既阻塞音频泵、又造成系数阶跃。
      // 单纯节流只降低频率、仍是阶跃（实测仍有「哒哒」声），故改为
      // 20Hz 起步的**渐变爬坡**：每步最多 0.6 dB，等效于等功率交叉淡化。
      _bassRampTarget = v;
      _kickBassRamp();
    } else {
      send({'cmd': 'setParam', 'id': id, 'value': v, 'isFloat': true});
    }
    scheduleAutoSave();
  }

  void _sendBassGain(double v) {
    _markSent('bass.gain');
    send({'cmd': 'setParam', 'id': 'bass.gain', 'value': v, 'isFloat': true});
  }

  /// 推进一格并安排下一步；到达目标后收尾（含关闭时的延迟 disable）。
  void _stepBassRamp() {
    _bassGainTimer = null;
    final target = _bassRampTarget;
    if (target == null) return;
    final diff = target - _bassRampCur;
    if (diff > _bassGainStepDb) {
      _bassRampCur += _bassGainStepDb;
    } else if (diff < -_bassGainStepDb) {
      _bassRampCur -= _bassGainStepDb;
    } else {
      _bassRampCur = target;
    }
    _sendBassGain(_bassRampCur);
    _kickBassRamp();
  }

  void _kickBassRamp() {
    final target = _bassRampTarget;
    if (target == null) return;
    if ((target - _bassRampCur).abs() <= _bassGainStepDb) {
      if (_bassRampCur != target) {
        _bassRampCur = target;
        _sendBassGain(target);
      }
      _bassRampTarget = null;
      if (_bassDisableAfterRamp) {
        // 已渐变到 0，此时关开关才不会「哒」一声。
        _bassDisableAfterRamp = false;
        _markSent('bass.enable');
        send(
            {'cmd': 'setParam', 'id': 'bass.enable', 'value': 0, 'isFloat': false});
      }
      _bassGainTimer?.cancel();
      _bassGainTimer = null;
      return;
    }
    _bassGainTimer ??= Timer(
        const Duration(milliseconds: _bassGainMinIntervalMs), _stepBassRamp);
  }

  /// 关闭低音：先把增益渐变到 0，再下发 disable（无爆音的旁路）。
  void _disableBassRamped() {
    if (_bassRampCur <= 0.0) {
      _markSent('bass.enable');
      send(
          {'cmd': 'setParam', 'id': 'bass.enable', 'value': 0, 'isFloat': false});
      return;
    }
    _bassRampTarget = 0.0;
    _bassDisableAfterRamp = true;
    _kickBassRamp();
  }


  Future<void> replaySessionToEngine() async {
    _isReplayingSession = true;
    try {
      // 0. 输入门控（总增益与声道平衡）
      setFloat(ParamId.inputGain, inputGain);
      setFloat(ParamId.inputBalance(1), inputBalanceL);
      setFloat(ParamId.inputBalance(2), inputBalanceR);

      // 1. 下发全量基础开关与数值
      setInt('bass.enable', bassOn ? 1 : 0);
      setFloat('bass.gain', bassGain);
      // 声场（v1.2）：开关位独立后，直发 bypass _mirror（旧 setFloat 会把
      // UI 的 mix/band 回写冲掉）；关闭时下发 0，UI 值保留。开时与旧行为一致。
      final stereoK = stereoOn ? 1.0 : 0.0;
      _markSent('stereo.mix');
      send({
        'cmd': 'setParam',
        'id': 'stereo.mix',
        'value': stereoMix * stereoWidenMax * stereoK,
        'isFloat': true,
      });
      if (stereoBandUsed) {
        setInt('stereo.bandUsed', 1);
        for (var i = 0; i < 5; i++) {
          final bandId = 'stereo.band${i + 1}';
          _markSent(bandId);
          send({
            'cmd': 'setParam',
            'id': bandId,
            'value': stereoBands[i] * stereoK,
            'isFloat': true,
          });
        }
      }
      setInt('tube.enable', tubeOn ? 1 : 0);
      setFloat('tube.gain', tubeGain);
      // P-011：电子管音色/混合/补偿
      setInt(ParamId.tubeStyle, tubeStyle);
      setFloat(ParamId.tubeMix, tubeMix);
      setFloat(ParamId.tubeCompensation, tubeCompensation);
      setInt('crossfeed.enable', xfeedOn ? 1 : 0);
      setInt(ParamId.xfeedMode, xfeedMode);
      setFloat(ParamId.xfeedFcut, xfeedFcut);
      setFloat(ParamId.xfeedFeed, xfeedFeed);
      setInt('shelf.enable', shelfOn ? 1 : 0);
      setFloat('shelf.freq', shelfFreq);
      setFloat('shelf.gain', shelfGain);
      setInt(ParamId.bassmonoEnable, bassmonoOn ? 1 : 0);
      setFloat(ParamId.bassmonoFreq, bassmonoFreq);
      setInt(ParamId.haasEnable, haasOn ? 1 : 0);
      setFloat(ParamId.haasDelay, haasDelayMs);
      setFloat(ParamId.haasMix, haasMix);
      setInt(ParamId.haasSide, haasSide);
      setInt(ParamId.exciterEnable, exciterOn ? 1 : 0);
      setFloat(ParamId.exciterAmount, exciterAmount);
      setFloat(ParamId.exciterHifreq, exciterHifreq);
      // P-010：每效果输出增益门 + 自动补偿
      setFloat(ParamId.bassOutGain, bassOutputGain);
      setInt(ParamId.bassAutoGain, bassAutoGain ? 1 : 0);
      setFloat(ParamId.eqOutGain, eqOutputGain);
      setInt(ParamId.eqAutoGain, eqAutoGain ? 1 : 0);
      setFloat(ParamId.tubeOutGain, tubeOutputGain);
      setInt(ParamId.tubeAutoGain, tubeAutoGain ? 1 : 0);
      setFloat(ParamId.compOutGain, compOutputGain);
      setInt(ParamId.compAutoGain, compAutoGain ? 1 : 0);
      setFloat(ParamId.reverbOutGain, reverbOutputGain);
      setInt(ParamId.reverbAutoGain, reverbAutoGain ? 1 : 0);
      // 噪声门 + Deesser
      setInt(ParamId.gateEnable, gateOn ? 1 : 0);
      setFloat(ParamId.gateThreshold, gateThreshold);
      setFloat(ParamId.gateAttack, gateAttackMs);
      setFloat(ParamId.gateRelease, gateReleaseMs);
      setInt(ParamId.gateAutoGain, gateAutoGain ? 1 : 0);
      setInt(ParamId.deesserEnable, deesserOn ? 1 : 0);
      setFloat(ParamId.deesserFreq, deesserFreq);
      setFloat(ParamId.deesserAmount, deesserAmount);
      // 全参数动态EQ
      setInt(ParamId.dyneqEnable, dyneqOn ? 1 : 0);
      setFloat(ParamId.dyneqAttack, dyneqAttackMs);
      setFloat(ParamId.dyneqRelease, dyneqReleaseMs);
      setInt(ParamId.dyneqLowEnable, dyneqLowOn ? 1 : 0);
      setFloat(ParamId.dyneqLowFreq, dyneqLowFreq);
      setFloat(ParamId.dyneqLowQ, dyneqLowQ);
      setFloat(ParamId.dyneqLowGain, dyneqLowGain);
      setFloat(ParamId.dyneqLowRange, dyneqLowRange);
      setFloat(ParamId.dyneqLowThreshold, dyneqLowThreshold);
      setInt(ParamId.dyneqMidEnable, dyneqMidOn ? 1 : 0);
      setFloat(ParamId.dyneqMidFreq, dyneqMidFreq);
      setFloat(ParamId.dyneqMidQ, dyneqMidQ);
      setFloat(ParamId.dyneqMidGain, dyneqMidGain);
      setFloat(ParamId.dyneqMidRange, dyneqMidRange);
      setFloat(ParamId.dyneqMidThreshold, dyneqMidThreshold);
      setInt(ParamId.dyneqHighEnable, dyneqHighOn ? 1 : 0);
      setFloat(ParamId.dyneqHighFreq, dyneqHighFreq);
      setFloat(ParamId.dyneqHighQ, dyneqHighQ);
      setFloat(ParamId.dyneqHighGain, dyneqHighGain);
      setFloat(ParamId.dyneqHighRange, dyneqHighRange);
      setFloat(ParamId.dyneqHighThreshold, dyneqHighThreshold);
      setInt(ParamId.loudnessEnable, loudnessOn ? 1 : 0);
      setFloat(ParamId.loudnessAmount, loudnessAmount);
      setFloat(ParamId.bassHarmonics, bassHarmonics);
      setFloat(ParamId.bassHarmonicBlend, bassHarmonicBlend);
      setFloat(ParamId.bassSubFreq, bassSubFloor);
      setFloat(ParamId.bassCutoffF, bassCutoff);
      setInt(ParamId.filterEnable, filterOn ? 1 : 0);
      setInt(ParamId.filterType, filterType);
      setFloat(ParamId.filterFreq, filterFreq);
      setFloat(ParamId.filterQ, filterQ);
      setFloat(ParamId.arbmagOutGain, arbmagOutputGain);
      setInt(ParamId.arbmagAutoGain, arbmagAutoGain ? 1 : 0);
      setInt('limiter.enable', limiterOn ? 1 : 0);
      setFloat('post.gain', postGain);

      // 动态压限器
      setFloat(ParamId.compTimeconstant, compTimeconstant);
      setInt(ParamId.compGranularity, compGranularity);
      setInt(ParamId.compTfresolution, compTfresolution);
      setInt(ParamId.compEnable, compOn ? 1 : 0);

      // 2. 混响
      if (isSpatialReverbOn) {
        setFloat('freeverb.decay', fvDecay);
        setFloat('freeverb.damp', fvDamp);
        setFloat('freeverb.wet', fvWet);
        setFloat('freeverb.dry', fvDry);
        setInt(ParamId.fvEnable, 1);
        if (reverbPreset >= 0) {
          setInt('reverb.preset', reverbPreset);
        }
      } else {
        setInt(ParamId.fvEnable, 0);
        setInt('reverb.preset', -1);
      }

      // 3. EQ 状态与曲线
      setInt('eq.enable', eqOn ? 1 : 0);
      _pushEqCurve();

      // 4. 外部文件自校验重载
      if (convIrPath != null && convIrPath!.isNotEmpty && File(convIrPath!).existsSync()) {
        loadConvolverIr(convIrPath!);
        if (convEnabled) setInt(ParamId.convEnable, 1);
      }
      // 干湿比有独立引擎参数，重启后必须重推，否则界面显示的混合比
      // 与引擎默认值不一致（“记忆与滑块打架”的成因之一）。
      setFloat('convolver.mix', convMix);
      if (ddcPath != null && ddcPath!.isNotEmpty && File(ddcPath!).existsSync()) {
        loadVdc(ddcPath!);
        if (ddcOn) setInt(ParamId.ddcEnable, 1);
      }
      if (lpCode != null && lpCode!.isNotEmpty) {
        setLiveprogCode(lpCode!);
        if (lpEnabled) setInt(ParamId.lpEnable, 1);
        // 脚本滑块 1..8 有独立引擎参数，重启后必须重推，
        // 否则界面显示的滑块值与引擎归零值不一致（同上）。
        for (var i = 0; i < 8 && i < lpParams.length; i++) {
          setFloat('liveprog.param${i + 1}', lpParams[i]);
        }
      }
      if (arbmagString.isNotEmpty) {
        setArbmagString(arbmagString);
        if (arbmagOn) {
          setInt(ParamId.arbmagEnable, 1);
        }
      }
      if (graphOrder != null && graphOrder!.isNotEmpty) {
        setGraphOrder(graphOrder!);
      }

      // 5. 恢复第三方插件挂载与旁路（多插槽）
      if (savedPluginSlots.isNotEmpty) {
        for (final item in savedPluginSlots) {
          if (item.path.isNotEmpty && File(item.path).existsSync()) {
            send({
              'cmd': 'pluginSlotLoad',
              'slot': item.slot,
              'path': item.path,
              'id': item.id,
            });
            if (item.stage != PluginInsertStage.defaultStage) {
              send({
                'cmd': 'pluginSlotSetInsertStage',
                'slot': item.slot,
                'stage': item.stage,
              });
            }
            if (item.bypass) {
              send({
                'cmd': 'pluginSlotSetBypass',
                'slot': item.slot,
                'bypass': true,
              });
            }
          }
        }
      } else if (savedPluginPath != null &&
          savedPluginPath!.isNotEmpty &&
          File(savedPluginPath!).existsSync()) {
        send({
          'cmd': 'pluginSlotLoad',
          'slot': 0,
          'path': savedPluginPath!,
          'id': savedPluginId,
        });
        if (savedPluginBypass) {
          send({'cmd': 'pluginSlotSetBypass', 'slot': 0, 'bypass': true});
        }
      }
    } finally {
      _isReplayingSession = false;
      _toIso?.send({'cmd': 'getParams'});
    }
  }

  /// 乐观镜像；被守卫拒绝时由 EventBanner 明示，引擎 params/state 纠正
  void _mirror(String id, double v) {
    switch (id) {
      case 'bass.enable': bassOn = v != 0; break;
      case 'bass.gain': bassGain = v; break;
      case 'reverb.preset': reverbPreset = v.toInt(); break;
      case 'stereo.mix':
        // UI 刻度 0..1 → 存显示值；引擎侧收到 v * stereoWidenMax
        stereoMix = (v / stereoWidenMax).clamp(0.0, 1.0);
        // 总滑块语义 = 回统一模式（引擎侧同时清 vendor bandMixUsed），
        // UI 镜像必须同步清，否则会一直显示"分带生效中"而造成与主滑块冲突
        stereoBandUsed = false;
        break;
      case 'eq.enable': eqOn = v != 0; break;
      case 'post.gain': postGain = v; break;
      case 'input.gain': inputGain = v; break;
      case 'input.balance.1': inputBalanceL = v; break;
      case 'input.balance.2': inputBalanceR = v; break;
      case 'limiter.enable': limiterOn = v != 0; break;
      case 'channels.mode': channelsMode = v.toInt(); break;
      case 'tube.enable': tubeOn = v != 0; break;
      case 'tube.style': tubeStyle = v.toInt().clamp(0, 2); break;
      case 'tube.mix': tubeMix = v.clamp(0.0, 1.0); break;
      case 'tube.compensation': tubeCompensation = v.clamp(-12.0, 12.0); break;
      case 'crossfeed.enable': xfeedOn = v != 0; break;
      case 'crossfeed.mode': xfeedMode = v.toInt(); break;
      case 'crossfeed.fcut': xfeedFcut = v; break;
      case 'crossfeed.feed': xfeedFeed = v; break;
      default:
        // 注意：这里必须用 raw string 里的裸 $ 收尾。写成 r'...\$' 是
        // 反斜杠+美元，在 ECMAScript 正则里是 IdentityEscape，匹配**字面 $ 字符**，
        // 于是 'stereo.band1' 永远不匹配 → 分带镜像与 stereoBandUsed 全程失效
        // （下方 liveprog.param 同类写法即为正确示范）。
        final mb = RegExp(r'^stereo\.band([1-5])$').firstMatch(id);
        if (mb != null) {
          stereoBands[int.parse(mb.group(1)!) - 1] = v.clamp(0.0, 1.0);
          stereoBandUsed = true;
          break;
        }
        if (id == ParamId.convMix) { convMix = v; break; }
        if (id == ParamId.ddcEnable) { ddcOn = v != 0; break; }
        if (id == ParamId.ddcReady) { ddcReady = v != 0; break; }
        if (id == ParamId.shelfEnable) { shelfOn = v != 0; break; }
        if (id == ParamId.shelfFreq) { shelfFreq = v; break; }
        if (id == ParamId.shelfGain) { shelfGain = v; break; }
        if (id == ParamId.bassmonoEnable) { bassmonoOn = v != 0; break; }
        if (id == ParamId.bassmonoFreq) { bassmonoFreq = v; break; }
        if (id == ParamId.haasEnable) { haasOn = v != 0; break; }
        if (id == ParamId.haasDelay) { haasDelayMs = v; break; }
        if (id == ParamId.haasMix) { haasMix = v; break; }
        if (id == ParamId.haasSide) { haasSide = v != 0 ? 1 : 0; break; }
        if (id == ParamId.exciterEnable) { exciterOn = v != 0; break; }
        if (id == ParamId.exciterAmount) { exciterAmount = v; break; }
        if (id == ParamId.exciterHifreq) { exciterHifreq = v; break; }
        if (id == ParamId.bassOutGain) { bassOutputGain = v; break; }
        if (id == ParamId.bassAutoGain) { bassAutoGain = v != 0; break; }
        if (id == ParamId.eqOutGain) { eqOutputGain = v; break; }
        if (id == ParamId.eqAutoGain) { eqAutoGain = v != 0; break; }
        if (id == ParamId.tubeOutGain) { tubeOutputGain = v; break; }
        if (id == ParamId.tubeAutoGain) { tubeAutoGain = v != 0; break; }
        if (id == ParamId.compOutGain) { compOutputGain = v; break; }
        if (id == ParamId.compAutoGain) { compAutoGain = v != 0; break; }
        if (id == ParamId.reverbOutGain) { reverbOutputGain = v; break; }
        if (id == ParamId.reverbAutoGain) { reverbAutoGain = v != 0; break; }
        if (id == ParamId.gateEnable) { gateOn = v != 0; break; }
        if (id == ParamId.gateThreshold) { gateThreshold = v; break; }
        if (id == ParamId.gateAttack) { gateAttackMs = v; break; }
        if (id == ParamId.gateRelease) { gateReleaseMs = v; break; }
        if (id == ParamId.gateAutoGain) { gateAutoGain = v != 0; break; }
        if (id == ParamId.deesserEnable) { deesserOn = v != 0; break; }
        if (id == ParamId.deesserFreq) { deesserFreq = v; break; }
        if (id == ParamId.loudnessEnable) { loudnessOn = v != 0; break; }
        if (id == ParamId.loudnessAmount) { loudnessAmount = v; break; }
        if (id == ParamId.bassHarmonics) { bassHarmonics = v; break; }
        if (id == ParamId.bassHarmonicBlend) { bassHarmonicBlend = v; break; }
        if (id == ParamId.bassSubFreq) { bassSubFloor = v; break; }
        if (id == ParamId.bassCutoffF) { bassCutoff = v; break; }
        if (id == ParamId.filterEnable) { filterOn = v != 0; break; }
        if (id == ParamId.filterType) { filterType = v.toInt().clamp(0, 2); break; }
        if (id == ParamId.filterFreq) { filterFreq = v; break; }
        if (id == ParamId.filterQ) { filterQ = v; break; }
        if (id == ParamId.deesserAmount) { deesserAmount = v; break; }
        if (id == ParamId.dyneqEnable) { dyneqOn = v != 0; break; }
        if (id == ParamId.dyneqAttack) { dyneqAttackMs = v; break; }
        if (id == ParamId.dyneqRelease) { dyneqReleaseMs = v; break; }
        if (id == ParamId.dyneqLowEnable) { dyneqLowOn = v != 0; break; }
        if (id == ParamId.dyneqLowFreq) { dyneqLowFreq = v; break; }
        if (id == ParamId.dyneqLowQ) { dyneqLowQ = v; break; }
        if (id == ParamId.dyneqLowGain) { dyneqLowGain = v; break; }
        if (id == ParamId.dyneqLowRange) { dyneqLowRange = v; break; }
        if (id == ParamId.dyneqLowThreshold) { dyneqLowThreshold = v; break; }
        if (id == ParamId.dyneqMidEnable) { dyneqMidOn = v != 0; break; }
        if (id == ParamId.dyneqMidFreq) { dyneqMidFreq = v; break; }
        if (id == ParamId.dyneqMidQ) { dyneqMidQ = v; break; }
        if (id == ParamId.dyneqMidGain) { dyneqMidGain = v; break; }
        if (id == ParamId.dyneqMidRange) { dyneqMidRange = v; break; }
        if (id == ParamId.dyneqMidThreshold) { dyneqMidThreshold = v; break; }
        if (id == ParamId.dyneqHighEnable) { dyneqHighOn = v != 0; break; }
        if (id == ParamId.dyneqHighFreq) { dyneqHighFreq = v; break; }
        if (id == ParamId.dyneqHighQ) { dyneqHighQ = v; break; }
        if (id == ParamId.dyneqHighGain) { dyneqHighGain = v; break; }
        if (id == ParamId.dyneqHighRange) { dyneqHighRange = v; break; }
        if (id == ParamId.dyneqHighThreshold) { dyneqHighThreshold = v; break; }
        if (id == ParamId.fvEnable) { fvOn = v != 0; break; }
        if (id == ParamId.fvDecay) { fvDecay = v; break; }
        if (id == ParamId.fvDamp) { fvDamp = v; break; }
        if (id == ParamId.fvWet) { fvWet = v; break; }
        if (id == ParamId.fvDry) { fvDry = v; break; }
        if (id == ParamId.compEnable) { compOn = v != 0; break; }
        if (id == ParamId.compTimeconstant) { compTimeconstant = v; break; }
        if (id == ParamId.compGranularity) { compGranularity = v.toInt(); break; }
        if (id == ParamId.compTfresolution) { compTfresolution = v.toInt(); break; }
        if (id == ParamId.arbmagEnable) { arbmagOn = v != 0; break; }
        if (id == ParamId.arbmagReady) { arbmagReady = v != 0; break; }
        if (id == ParamId.arbmagOutGain) { arbmagOutputGain = v; break; }
        if (id == ParamId.arbmagAutoGain) { arbmagAutoGain = v != 0; break; }
        final m = RegExp(r'^liveprog\.param([1-8])$').firstMatch(id);
        if (m != null) lpParams[int.parse(m.group(1)!) - 1] = v;
    }
  }

  /// 声场链统一推送：开关关闭时引擎侧一律收 0（静默），
  /// UI 滑块值不动。直发 bypass _mirror，避免回写冲掉 UI 位置。
  void _pushStereoChain() {
    final k = stereoOn ? 1.0 : 0.0;
    _markSent('stereo.mix');
    send({
      'cmd': 'setParam',
      'id': 'stereo.mix',
      'value': stereoMix * stereoWidenMax * k,
      'isFloat': true,
    });
    final macroMultiplier = stereoMix * 2.0;
    for (var i = 0; i < 5; i++) {
      final id = 'stereo.band${i + 1}';
      final eff =
          (stereoBands[i] * macroMultiplier).clamp(0.0, 1.0) * stereoWidenMax * k;
      _markSent(id);
      send({'cmd': 'setParam', 'id': id, 'value': eff, 'isFloat': true});
    }
    scheduleAutoSave();
  }

  void setStereoMix(double v) {
    stereoMix = v.clamp(0.0, 1.0);
    // 保持旧 setFloat 路径的 _mirror 副作用：5 个分带推送曾把 bandUsed 置 true。
    stereoBandUsed = true;
    _pushStereoChain();
    notifyListeners();
  }

  void setStereoBand(int index, double baseVal) {
    if (index < 0 || index >= 5) return;
    stereoBands[index] = baseVal.clamp(0.0, 1.0);
    // 同上：旧 _mirror 分带分支置 bandUsed = true。
    stereoBandUsed = true;
    _pushStereoChain();
    notifyListeners();
  }

  void resetStereoBand(int index) {
    setStereoBand(index, ParamDefaults.stereoBand);
  }

  /// 双击主滑块时重置立体声扩展并恢复 5 个子带为 0.5 中性
  void resetStereoWiden() {
    stereoMix = ParamDefaults.stereoMix;
    stereoOn = false;
    for (var i = 0; i < 5; i++) {
      stereoBands[i] = ParamDefaults.stereoBand;
    }
    stereoBandUsed = false;
    _pushStereoChain();
    notifyListeners();
  }

  void resetStereoBandsToGlobal() {
    for (var i = 0; i < 5; i++) {
      stereoBands[i] = ParamDefaults.stereoBand;
    }
    stereoBandUsed = false;
    _pushStereoChain();
    notifyListeners();
  }

  void setStereoEnabled(bool on) {
    stereoOn = on;
    if (on && stereoMix <= 0.0) {
      stereoMix = _lastStereoMix > 0.0 ? _lastStereoMix : 0.5;
    }
    if (!on && stereoMix > 0.0) {
      _lastStereoMix = stereoMix;
    }
    _pushStereoChain();
    notifyListeners();
  }

  /* ---- Liveprog 命令（v1.1） ---- */

  /// vendor 链 12 stage 白名单（与引擎 kAuraStages 对齐；Issue #4）。
  ///
  /// 链页展示序混有 engine 自研 stage（gate/filter/dyneq/…），而 vendor
  /// JamesDSPRebuildChain 要求恰好 12 个已知 id——混发必 E_PARAM。
  /// 此处过滤只保序去杂，不补不增：缺 vendor id 时引擎照常拒收并 set_error。
  /// engine 自研 stage 的顺序本就钉死在 process_stereo_chain，过滤不丢任何功能。
  static const _vendorStageIds = {
    'tube', 'comp', 'bass', 'eq', 'arbmag', 'convolver', 'ddc', 'liveprog',
    'crossfeed', 'stereo', 'reverb', 'output',
  };

  static String filterVendorOrder(String order) => order
      .split(',')
      .map((s) => s.trim())
      .where(_vendorStageIds.contains)
      .join(',');

  void setGraphOrder(String order) {
    graphOrder = order;
    send({'cmd': 'setParamStr', 'id': 'graph.order', 'text': filterVendorOrder(order)});
  }

  /// 获取某个处理链 stage 的启用状态
  bool isStageEnabled(String stageId) {
    return switch (stageId) {
      'tube' => tubeOn,
      'comp' => compOn,
      'bassmono' => bassmonoOn,
      'gate' => gateOn,
      'dyneq' => dyneqOn,
      'filter' => filterOn,
      'loudness' => loudnessOn,
      'haas' => haasOn,
      'exciter' => exciterOn,
      'bass' => bassOn,
      'eq' => eqOn,
      'arbmag' => arbmagOn,
      'convolver' => convEnabled,
      'ddc' => ddcOn,
      'liveprog' => lpEnabled,
      'crossfeed' => xfeedOn,
      'stereo' => stereoOn,
      'reverb' => reverbPreset >= 0,
      'output' => limiterOn,
      _ => false,
    };
  }

  /// 切换某个处理链 stage 的启用/旁路状态
  void toggleStage(String stageId) {
    switch (stageId) {
      case 'tube':
        setInt('tube.enable', tubeOn ? 0 : 1);
      case 'bassmono':
        setBassmonoEnabled(!bassmonoOn);
      case 'gate':
        setGateEnabled(!gateOn);
      case 'dyneq':
        setDyneqEnabled(!dyneqOn);
      case 'filter':
        setFilterEnabled(!filterOn);
      case 'loudness':
        setLoudnessEnabled(!loudnessOn);
      case 'haas':
        setHaasEnabled(!haasOn);
      case 'exciter':
        setExciterEnabled(!exciterOn);
      case 'comp':
        setCompEnabled(!compOn);
      case 'bass':
        setInt('bass.enable', bassOn ? 0 : 1);
      case 'eq':
        setInt('eq.enable', eqOn ? 0 : 1);
      case 'arbmag':
        setArbmagEnabled(!arbmagOn);
      case 'convolver':
        setInt(ParamId.convEnable, convEnabled ? 0 : 1);
      case 'ddc':
        setDdcEnabled(!ddcOn);
      case 'liveprog':
        setLiveprogEnabled(!lpEnabled);
      case 'crossfeed':
        setInt('crossfeed.enable', xfeedOn ? 0 : 1);
      case 'stereo':
        setStereoEnabled(!stereoOn);
      case 'reverb':
        if (reverbPreset >= 0) {
          setInt('reverb.preset', -1);
        } else {
          setReverbPreset(0);
        }
      case 'output':
        setInt('limiter.enable', limiterOn ? 0 : 1);
    }
  }

  void setStringParam(String id, String text) {
    send({'cmd': 'setParamStr', 'id': id, 'text': text});
    scheduleAutoSave();
  }

  void setLiveprogCode(String text) {
    lpError = null;
    lpCode = text;
    lpPresetCodeMismatch = false;
    lpCompileMs = -1;
    send({'cmd': 'setParamStr', 'id': ParamId.lpCode, 'text': text});
    // 单一默认值源（v2 §3.2）：脚本内 sliderN: 声明优先。
    // 引擎 LoadCode 已把 8 滑块清零，这里全量回推对齐；声明签名不变时
    // 保留用户已调值（只做回推），声明变化才采纳新默认值。
    // 同一 isolate SendPort 保序：code → 默认值 → 调用方后续值。
    final metas = EelSliderParser.parse(text);
    final sig = StringBuffer();
    for (var i = 1; i <= 8; i++) {
      final meta = metas[i];
      if (meta != null) {
        sig.write(
            '$i:${meta.defaultVal}:${meta.minVal}:${meta.maxVal};');
      }
    }
    if (sig.toString() != _lpDeclSig) {
      _lpDeclSig = sig.toString();
      for (var i = 1; i <= 8; i++) {
        final meta = metas[i];
        if (meta != null) {
          var d = meta.defaultVal;
          if (meta.minVal <= meta.maxVal) {
            d = d.clamp(meta.minVal, meta.maxVal);
          }
          lpParams[i - 1] = d;
        }
      }
    }
    for (var i = 0; i < 8; i++) {
      setLiveprogParam(i, lpParams[i]);
    }
    scheduleAutoSave();
  }

  void setLiveprogEnabled(bool on) {
    lpEnabled = on;
    notifyListeners();
    _markSent(ParamId.lpEnable);
    send({'cmd': 'setParam', 'id': ParamId.lpEnable, 'value': on ? 1 : 0, 'isFloat': false});
    scheduleAutoSave();
  }

  void unloadLiveprog() {
    lpEnabled = false;
    lpStatus = 0;
    lpError = null;
    lpPresetCodeMismatch = false;
    lpCompileMs = -1;
    // v2 §3.2：不再清 lpCode——编辑器内容即真相，卸载只关使能；
    // 下次应用同签名代码时滑块值予以保留（见 setLiveprogCode）。
    notifyListeners();
    _markSent(ParamId.lpUnload);
    send({'cmd': 'setParam', 'id': ParamId.lpUnload, 'value': 0, 'isFloat': false});
    scheduleAutoSave();
  }

  void setLiveprogParam(int index, double v) {
    setFloat('liveprog.param${index + 1}', v);
  }

  /* ---- 卷积 / IR 命令（v1.1 M4） ---- */

  /// 卷积使能：废除品质档拦截限制，无条件自由放行
  void setConvolverEnabled(bool on, {String? autoQualityMsg}) {
    convEnabled = on;
    if (on && !convReady) {
      if (convIrPath != null && convIrPath!.isNotEmpty && File(convIrPath!).existsSync()) {
        loadConvolverIr(convIrPath!);
      }
    }
    notifyListeners();
    _markSent(ParamId.convEnable);
    // Auto-bypass：用户要求「开关保持开启、无文件时效果内部直通，
    // 待合格 IR 加载成功后自动生效」。因此 UI 的开关状态与引擎的生效状态
    // 解耦：无资源时只对引擎下发 enable=0（内部直通），UI 仍显示为开启。
    send({
      'cmd': 'setParam',
      'id': ParamId.convEnable,
      'value': (on && convReady) ? 1 : 0,
      'isFloat': false
    });
    scheduleAutoSave();
  }

  void loadConvolverIr(String path) {
    convIrPath = path;
    // 字符串参数复用 setParamStr 通道；meta 由 paramResult→getParams 回读
    send({'cmd': 'setParamStr', 'id': ParamId.convIrPath, 'text': path});
    scheduleAutoSave();
  }

  void setTubeEnabled(bool on) {
    setInt(ParamId.tubeEnable, on ? 1 : 0);
  }

  void setCrossfeedEnabled(bool on) {
    xfeedOn = on;
    setInt(ParamId.xfeedEnable, on ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  void setCrossfeedMode(int mode) {
    xfeedMode = mode.clamp(0, 3);
    if (xfeedMode == 0) {
      xfeedFcut = 700.0;
      xfeedFeed = 4.5;
    } else if (xfeedMode == 1) {
      xfeedFcut = 700.0;
      xfeedFeed = 6.0;
    } else if (xfeedMode == 2) {
      xfeedFcut = 650.0;
      xfeedFeed = 9.5;
    }
    setInt(ParamId.xfeedMode, xfeedMode);
    notifyListeners();
    scheduleAutoSave();
  }

  void setCrossfeedFcut(double v) {
    xfeedFcut = v.clamp(300.0, 2000.0);
    xfeedMode = 3; // 联动切为自定义模式
    setInt(ParamId.xfeedMode, 3);
    setFloat(ParamId.xfeedFcut, xfeedFcut);
    notifyListeners();
    scheduleAutoSave();
  }

  void setCrossfeedFeed(double v) {
    xfeedFeed = v.clamp(1.0, 15.0);
    xfeedMode = 3; // 联动切为自定义模式
    setInt(ParamId.xfeedMode, 3);
    setFloat(ParamId.xfeedFeed, xfeedFeed);
    notifyListeners();
    scheduleAutoSave();
  }

  /// 低频单声道化（BassMono）：开关与分频点（stereo 解耦教训：独立开关位，
  /// 频率滑块到下限不关开关）。
  void setBassmonoEnabled(bool on) {
    bassmonoOn = on;
    setInt(ParamId.bassmonoEnable, on ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  void setBassmonoFreq(double v) {
    bassmonoFreq = v.clamp(20.0, 300.0);
    setFloat(ParamId.bassmonoFreq, bassmonoFreq);
    notifyListeners();
    scheduleAutoSave();
  }

  /// Haas 差分环绕：右声道延迟 + 干湿混合（左声道恒直通，保单声道兼容）。
  void setHaasEnabled(bool on) {
    haasOn = on;
    setInt(ParamId.haasEnable, on ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  void setHaasDelay(double v) {
    haasDelayMs = v.clamp(0.0, 25.0);
    setFloat(ParamId.haasDelay, haasDelayMs);
    notifyListeners();
    scheduleAutoSave();
  }

  void setHaasMix(double v) {
    haasMix = v.clamp(0.0, 1.0);
    setFloat(ParamId.haasMix, haasMix);
    notifyListeners();
    scheduleAutoSave();
  }

  /// 差分延迟侧：0=延迟右声道，1=延迟左声道（另一侧恒直通）。
  void setHaasSide(int side) {
    haasSide = side.clamp(0, 1);
    setInt(ParamId.haasSide, haasSide);
    notifyListeners();
    scheduleAutoSave();
  }

  /// 激励器：只暴露 amount/hifreq，drive 固定 2.0（防调出刺耳）。
  void setExciterEnabled(bool on) {
    exciterOn = on;
    setInt(ParamId.exciterEnable, on ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  void setExciterAmount(double v) {
    exciterAmount = v.clamp(0.0, 1.0);
    setFloat(ParamId.exciterAmount, exciterAmount);
    notifyListeners();
    scheduleAutoSave();
  }

  void setExciterHifreq(double v) {
    exciterHifreq = v.clamp(3000.0, 10000.0);
    setFloat(ParamId.exciterHifreq, exciterHifreq);
    notifyListeners();
    scheduleAutoSave();
  }

  void setInputGain(double v) {
    inputGain = v;
    setFloat(ParamId.inputGain, v);
    notifyListeners();
  }

  void setInputBalanceL(double v) {
    inputBalanceL = v;
    setFloat(ParamId.inputBalance(1), v);
    notifyListeners();
  }

  void setInputBalanceR(double v) {
    inputBalanceR = v;
    setFloat(ParamId.inputBalance(2), v);
    notifyListeners();
  }

  /// 参数化混响使能：废除品质档拦截限制，无条件自由放行
  void setFreeverbEnabled(bool on, {String? autoQualityMsg}) {
    fvOn = on;
    notifyListeners();
    _markSent(ParamId.fvEnable);
    send({'cmd': 'setParam', 'id': ParamId.fvEnable, 'value': on ? 1 : 0, 'isFloat': false});
  }

  void selectReverbPreset(int id) {
    final wasCustom = reverbPreset == -2;
    reverbPreset = id;
    if (id >= 0 && id <= 7) {
      final (decay, damp, wet, dry, roomSize, width) = switch (id) {
        0 => (0.85, 0.25, 0.45, 1.0, 1.5, 1.0), // 大音乐厅
        1 => (0.75, 0.30, 0.40, 1.0, 1.3, 1.0), // 音乐厅
        2 => (0.65, 0.35, 0.35, 1.0, 1.1, 0.9), // 中音乐厅
        3 => (0.55, 0.40, 0.30, 1.0, 0.9, 0.85), // 小音乐厅
        4 => (0.45, 0.45, 0.28, 1.0, 0.8, 0.8), // 大房间
        5 => (0.35, 0.50, 0.25, 1.0, 0.65, 0.75), // 中房间
        6 => (0.25, 0.55, 0.20, 1.0, 0.5, 0.7), // 小房间
        _ => (0.70, 0.15, 0.35, 1.0, 1.0, 1.0), // 板式混响
      };
      fvDecay = decay;
      fvDamp = damp;
      fvWet = wet;
      fvDry = dry;
      fvRoomSize = roomSize;
      fvWidth = width;
      setFreeverbEnabled(true);
      setFloat('freeverb.decay', decay);
      setFloat('freeverb.damp', damp);
      setFloat('freeverb.wet', wet);
      setFloat('freeverb.dry', dry);
      setReverbPreset(id);
    } else if (id == -1) {
      // Issue #3 方案A：从自定义态（-2）关闭只关声音，不丢标记。
      // engine 照常收 -1（vendor 关）+ fv 关；Dart 侧保留 -2，开回来走 -2 分支
      // 恢复自定义参数。从 preset/-1 关则照旧落 -1。
      setReverbPreset(-1);
      setFreeverbEnabled(false);
      if (wasCustom) reverbPreset = -2;
    } else if (id == -2) {
      // 自定义模式
      setFreeverbEnabled(true);
      notifyListeners();
    }
  }

  void setSpatialReverbEnabled(bool on) {
    if (on) {
      if (reverbPreset == -2) {
        // 自定义态：只开开关，不碰参数。旧逻辑无条件切 preset 0，
        // 会吃掉刚恢复/刚调好的自定义值（预设恢复实测：wet 0.5 -> 0.45）。
        selectReverbPreset(-2);
      } else {
        selectReverbPreset(reverbPreset >= 0 ? reverbPreset : 0);
      }
    } else {
      selectReverbPreset(-1);
    }
  }

  void setReverbCustomParam(String param, double value) {
    reverbPreset = -2; // 联动切换为自定义模式
    if (!fvOn) {
      setFreeverbEnabled(true);
    }
    switch (param) {
      case 'decay':
        fvDecay = value;
        setFloat('freeverb.decay', value);
      case 'damp':
        fvDamp = value;
        setFloat('freeverb.damp', value);
      case 'wet':
        fvWet = value;
        setFloat('freeverb.wet', value);
      case 'dry':
        fvDry = value;
        setFloat('freeverb.dry', value);
      case 'roomSize':
        fvRoomSize = value;
        notifyListeners();
      case 'width':
        fvWidth = value;
        notifyListeners();
    }
  }

  void parseVdcMetadata(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return;
      ddcFileName = path.split(RegExp(r'[\\/]')).last;
      final lines = f.readAsLinesSync();
      final rates = <String>[];
      int maxPoles = 0;
      for (final line in lines) {
        if (line.startsWith('SR_')) {
          final parts = line.split(':');
          if (parts.isNotEmpty) {
            final sr = parts[0].replaceAll('SR_', '');
            rates.add('$sr Hz');
            if (parts.length > 1) {
              final coeffs = parts[1].split(',');
              final stages = coeffs.length ~/ 5;
              if (stages > maxPoles) maxPoles = stages;
            }
          }
        }
      }
      ddcDetails = rates.isNotEmpty
          ? '${rates.join(', ')} · ${maxPoles > 0 ? '$maxPoles 阶双二阶' : '校准矩阵'}'
          : '已解析校准矩阵';
    } catch (_) {
      ddcFileName = path.split(RegExp(r'[\\/]')).last;
      ddcDetails = '已加载校准文件';
    }
  }

  void loadVdc(String path) {
    ddcPath = path;
    parseVdcMetadata(path);
    send({'cmd': 'setParamStr', 'id': ParamId.ddcLoad, 'text': path});
    // D3：字符串参数走 meta 通道，不主动 getParams 的话 ddcReady 永远不会
    // 翻转，卡片就一直停在「未加载」且 ddcReady 驱动的 UI 不刷新。
    _toIso?.send({'cmd': 'getParams'});
    scheduleAutoSave();
    notifyListeners();
  }

  void setDdcEnabled(bool on) {
    ddcOn = on;
    if (on && !ddcReady) {
      if (ddcPath != null && ddcPath!.isNotEmpty && File(ddcPath!).existsSync()) {
        loadVdc(ddcPath!);
      }
    }
    // 同卷积：auto-bypass，UI 开关与引擎生效状态解耦。
    // 必须直接 send 而不能用 setInt —— _mirror 会把 ddcEnable 镜像回 ddcOn
    // (state.dart:760)，下发 0 会把刚打开的开关立刻翻回关闭态。
    _markSent(ParamId.ddcEnable);
    send({
      'cmd': 'setParam',
      'id': ParamId.ddcEnable,
      'value': (on && ddcReady) ? 1 : 0,
      'isFloat': false
    });
    // 绕过 setInt 后原本由它代劳的 UI 刷新没了，必须自己通知。
    // 漏掉这行会导致「关不掉」——模型已改但界面不重绘，直到别处触发刷新才生效。
    notifyListeners();
    scheduleAutoSave();
  }

  void setCompEnabled(bool on) {
    compOn = on;
    setInt(ParamId.compEnable, on ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  void setCompTimeconstant(double v) {
    compTimeconstant = v;
    setFloat(ParamId.compTimeconstant, v);
    notifyListeners();
    scheduleAutoSave();
  }

  void setCompGranularity(int v) {
    compGranularity = v;
    setInt(ParamId.compGranularity, v);
    notifyListeners();
    scheduleAutoSave();
  }

  void setCompTfresolution(int v) {
    compTfresolution = v;
    setInt(ParamId.compTfresolution, v);
    notifyListeners();
    scheduleAutoSave();
  }

  void clearConvolver() {
    convEnabled = false;
    convReady = false;
    convIrPath = null;
    convFrames = convChannels = convSrcRate = 0;
    convPeak = 0;
    convSpectrum = [];
    notifyListeners();
    _markSent(ParamId.convClear);
    send({'cmd': 'setParam', 'id': ParamId.convClear, 'value': 0, 'isFloat': false});
    scheduleAutoSave();
  }

  /* ---- 低音增强重构（Phase 4） ---- */

  void setBassAutoGain(bool v) {
    bassAutoGain = v;
    setInt(ParamId.bassAutoGain, v ? 1 : 0);
    notifyListeners();
  }

  void setBassOutputGain(double v) {
    bassOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.bassOutGain, bassOutputGain);
    notifyListeners();
  }

  void setEqAutoGain(bool v) {
    eqAutoGain = v;
    setInt(ParamId.eqAutoGain, v ? 1 : 0);
    notifyListeners();
  }

  void setEqOutputGain(double v) {
    eqOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.eqOutGain, eqOutputGain);
    notifyListeners();
  }

  void setReverbAutoGain(bool v) {
    reverbAutoGain = v;
    setInt(ParamId.reverbAutoGain, v ? 1 : 0);
    notifyListeners();
  }

  void setReverbOutputGain(double v) {
    reverbOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.reverbOutGain, reverbOutputGain);
    notifyListeners();
  }

  void setTubeAutoGain(bool v) {
    tubeAutoGain = v;
    setInt(ParamId.tubeAutoGain, v ? 1 : 0);
    notifyListeners();
  }

  void setTubeOutputGain(double v) {
    tubeOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.tubeOutGain, tubeOutputGain);
    notifyListeners();
  }

  void setCompAutoGain(bool v) {
    compAutoGain = v;
    setInt(ParamId.compAutoGain, v ? 1 : 0);
    notifyListeners();
  }

  void setCompOutputGain(double v) {
    compOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.compOutGain, compOutputGain);
    notifyListeners();
  }

  /// 噪声门（链头第一道）：阈值/attack/release 全下发；自动增益补偿独立开关。
  void setGateEnabled(bool on) {
    gateOn = on;
    setInt(ParamId.gateEnable, on ? 1 : 0);
    notifyListeners();
  }

  void setGateThreshold(double v) {
    gateThreshold = v.clamp(-60.0, 0.0);
    setFloat(ParamId.gateThreshold, gateThreshold);
    notifyListeners();
  }

  void setGateAttack(double v) {
    gateAttackMs = v.clamp(1.0, 100.0);
    setFloat(ParamId.gateAttack, gateAttackMs);
    notifyListeners();
  }

  void setGateRelease(double v) {
    gateReleaseMs = v.clamp(10.0, 500.0);
    setFloat(ParamId.gateRelease, gateReleaseMs);
    notifyListeners();
  }

  void setGateAutoGain(bool v) {
    gateAutoGain = v;
    setInt(ParamId.gateAutoGain, v ? 1 : 0);
    notifyListeners();
  }

  /// Deesser（高级区）：开关 + 侧链频率 + 强度。
  void setDeesserEnabled(bool on) {
    deesserOn = on;
    setInt(ParamId.deesserEnable, on ? 1 : 0);
    notifyListeners();
  }

  void setDeesserFreq(double v) {
    deesserFreq = v.clamp(2000.0, 10000.0);
    setFloat(ParamId.deesserFreq, deesserFreq);
    notifyListeners();
  }

  void setDeesserAmount(double v) {
    deesserAmount = v.clamp(0.0, 1.0);
    setFloat(ParamId.deesserAmount, deesserAmount);
    notifyListeners();
  }

  /// 全参数动态EQ：总开关 + 包络时间 + 3 段 ×（开关/频率/Q/静态增益/动态量/阈值）。
  void setDyneqEnabled(bool on) {
    dyneqOn = on;
    setInt(ParamId.dyneqEnable, on ? 1 : 0);
    notifyListeners();
  }

  void setDyneqAttack(double v) {
    dyneqAttackMs = v.clamp(0.1, 100.0);
    setFloat(ParamId.dyneqAttack, dyneqAttackMs);
    notifyListeners();
  }

  void setDyneqRelease(double v) {
    dyneqReleaseMs = v.clamp(10.0, 1000.0);
    setFloat(ParamId.dyneqRelease, dyneqReleaseMs);
    notifyListeners();
  }

  void setDyneqLowEnabled(bool on) {
    dyneqLowOn = on;
    setInt(ParamId.dyneqLowEnable, on ? 1 : 0);
    notifyListeners();
  }


  void setDyneqLowFreq(double v) {
    dyneqLowFreq = v.clamp(20.0, 500.0);
    setFloat(ParamId.dyneqLowFreq, dyneqLowFreq);
    notifyListeners();
  }

  void setDyneqLowQ(double v) {
    dyneqLowQ = v.clamp(0.5, 2.0);
    setFloat(ParamId.dyneqLowQ, dyneqLowQ);
    notifyListeners();
  }

  void setDyneqLowGain(double v) {
    dyneqLowGain = v.clamp(-12.0, 12.0);
    setFloat(ParamId.dyneqLowGain, dyneqLowGain);
    notifyListeners();
  }

  void setDyneqLowRange(double v) {
    dyneqLowRange = v.clamp(0.0, 24.0);
    setFloat(ParamId.dyneqLowRange, dyneqLowRange);
    notifyListeners();
  }

  void setDyneqLowThreshold(double v) {
    dyneqLowThreshold = v.clamp(-60.0, 0.0);
    setFloat(ParamId.dyneqLowThreshold, dyneqLowThreshold);
    notifyListeners();
  }

  void setDyneqMidEnabled(bool on) {
    dyneqMidOn = on;
    setInt(ParamId.dyneqMidEnable, on ? 1 : 0);
    notifyListeners();
  }


  void setDyneqMidFreq(double v) {
    dyneqMidFreq = v.clamp(200.0, 8000.0);
    setFloat(ParamId.dyneqMidFreq, dyneqMidFreq);
    notifyListeners();
  }

  void setDyneqMidQ(double v) {
    dyneqMidQ = v.clamp(0.3, 10.0);
    setFloat(ParamId.dyneqMidQ, dyneqMidQ);
    notifyListeners();
  }

  void setDyneqMidGain(double v) {
    dyneqMidGain = v.clamp(-12.0, 12.0);
    setFloat(ParamId.dyneqMidGain, dyneqMidGain);
    notifyListeners();
  }

  void setDyneqMidRange(double v) {
    dyneqMidRange = v.clamp(0.0, 24.0);
    setFloat(ParamId.dyneqMidRange, dyneqMidRange);
    notifyListeners();
  }

  void setDyneqMidThreshold(double v) {
    dyneqMidThreshold = v.clamp(-60.0, 0.0);
    setFloat(ParamId.dyneqMidThreshold, dyneqMidThreshold);
    notifyListeners();
  }

  void setDyneqHighEnabled(bool on) {
    dyneqHighOn = on;
    setInt(ParamId.dyneqHighEnable, on ? 1 : 0);
    notifyListeners();
  }


  void setDyneqHighFreq(double v) {
    dyneqHighFreq = v.clamp(2000.0, 20000.0);
    setFloat(ParamId.dyneqHighFreq, dyneqHighFreq);
    notifyListeners();
  }

  void setDyneqHighQ(double v) {
    dyneqHighQ = v.clamp(0.5, 2.0);
    setFloat(ParamId.dyneqHighQ, dyneqHighQ);
    notifyListeners();
  }

  void setDyneqHighGain(double v) {
    dyneqHighGain = v.clamp(-12.0, 12.0);
    setFloat(ParamId.dyneqHighGain, dyneqHighGain);
    notifyListeners();
  }

  void setDyneqHighRange(double v) {
    dyneqHighRange = v.clamp(0.0, 24.0);
    setFloat(ParamId.dyneqHighRange, dyneqHighRange);
    notifyListeners();
  }

  void setDyneqHighThreshold(double v) {
    dyneqHighThreshold = v.clamp(-60.0, 0.0);
    setFloat(ParamId.dyneqHighThreshold, dyneqHighThreshold);
    notifyListeners();
  }

  /// 响度补偿：信号越静，低频 + 高频补得越多（简化等响曲线）。
  void setLoudnessEnabled(bool on) {
    loudnessOn = on;
    setInt(ParamId.loudnessEnable, on ? 1 : 0);
    notifyListeners();
  }

  void setLoudnessAmount(double v) {
    loudnessAmount = v.clamp(0.0, 1.0);
    setFloat(ParamId.loudnessAmount, loudnessAmount);
    notifyListeners();
  }

  /* ---- 任意响应 EQ（ArbMag / AutoEq GraphicEQ） ---- */

  void setArbmagEnabled(bool on) {
    arbmagOn = on;
    _markSent(ParamId.arbmagEnable);
    send({
      'cmd': 'setParam',
      'id': ParamId.arbmagEnable,
      'value': (on && arbmagReady) ? 1 : 0,
      'isFloat': false,
    });
    notifyListeners();
    scheduleAutoSave();
  }

  void setArbmagString(String s) {
    arbmagString = s;
    send({'cmd': 'setParamStr', 'id': ParamId.arbmagString, 'text': s});
    _toIso?.send({'cmd': 'getParams'});
    notifyListeners();
    scheduleAutoSave();
  }

  void clearArbmag() {
    arbmagReady = false;
    arbmagNodeCount = 0;
    arbmagString = '';
    _markSent(ParamId.arbmagEnable);
    send({'cmd': 'setParam', 'id': ParamId.arbmagEnable, 'value': 0, 'isFloat': false});
    send({'cmd': 'setParamStr', 'id': ParamId.arbmagString, 'text': ''});
    notifyListeners();
    scheduleAutoSave();
  }

  void setArbmagAutoGain(bool v) {
    arbmagAutoGain = v;
    setInt(ParamId.arbmagAutoGain, v ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  void setArbmagOutputGain(double v) {
    arbmagOutputGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.arbmagOutGain, arbmagOutputGain);
    notifyListeners();
    scheduleAutoSave();
  }

  void setBassIntensity(double v) {
    bassIntensity = v.clamp(0.0, 1.0);
    final gain = (bassIntensity * 15.0).clamp(0.0, 15.0);
    bassGain = gain;
    // v3.1 重构：强度只驱动 vendor bass，不再碰 shelf 引擎。
    // shelf 由自己的卡/预设节独立管理（老快照的 shelf 态走 shelf 节恢复）。
    setFloat('bass.gain', gain);
    notifyListeners();
  }

  /// ViPER 三模式 = 谐波配方宏（0=自然低音 / 1=纯净低音 / 2=超重低音）。
  /// 不再碰 shelf 引擎；配方写入谐波三滑块（随后的 slider 恢复会覆盖为快照真值）。
  void setBassMode(int mode) {
    bassMode = mode;
    if (mode == 1) {
      setBassHarmonics(0.35);
      setBassHarmonicBlend(0.5);
    } else if (mode == 2) {
      setBassHarmonics(0.7);
      setBassHarmonicBlend(0.7);
    } else {
      setBassHarmonics(0.0);
    }
    notifyListeners();
  }

  void setBassCutoff(double f) {
    bassCutoff = f;
    // v3.1：cutoff 改驱心理声学 LP，不再写 shelf.freq。
    setFloat(ParamId.bassCutoffF, bassCutoff);
    notifyListeners();
  }

  void setBassHarmonics(double h) {
    bassHarmonics = h.clamp(0.0, 1.0);
    setFloat(ParamId.bassHarmonics, bassHarmonics);
    notifyListeners();
  }

  void setBassHarmonicBlend(double b) {
    bassHarmonicBlend = b.clamp(0.0, 1.0);
    setFloat(ParamId.bassHarmonicBlend, bassHarmonicBlend);
    notifyListeners();
  }

  void setBassSubFloor(double s) {
    bassSubFloor = s;
    setFloat(ParamId.bassSubFreq, bassSubFloor);
    notifyListeners();
  }

  /// 独立滤波器（RBJ HP/LP/BP，gate 后 / bassmono 前）。
  void setFilterEnabled(bool on) {
    filterOn = on;
    setInt(ParamId.filterEnable, on ? 1 : 0);
    notifyListeners();
  }

  void setFilterType(int t) {
    filterType = t.clamp(0, 2);
    setInt(ParamId.filterType, filterType);
    notifyListeners();
  }

  void setFilterFreq(double f) {
    filterFreq = f.clamp(20.0, 20000.0);
    setFloat(ParamId.filterFreq, filterFreq);
    notifyListeners();
  }

  void setFilterQ(double q) {
    filterQ = q.clamp(0.3, 10.0);
    setFloat(ParamId.filterQ, filterQ);
    notifyListeners();
  }

  /* ---- 电子管模拟器（Phase 4） ---- */

  void setTubeGain(double db) {
    tubeGain = db.clamp(-3.0, 12.0);
    setFloat('tube.gain', tubeGain);
    notifyListeners();
  }

  void setTubeStyle(int style) {
    // P-011：引擎 tube.style 已接线（vendor character 开关，RT 安全）。
    tubeStyle = style.clamp(0, 2);
    setInt(ParamId.tubeStyle, tubeStyle);
    notifyListeners();
  }

  void setTubeOversampling(int os) {
    // 引擎侧无对应参数（vendor 按采样率自动过采样，手动无意义）：只存 UI/预设兼容，不下发。
    tubeOversampling = os;
    notifyListeners();
  }

  void setTubeCompensation(double comp) {
    // P-011：引擎 tube.compensation 已接线（vendor 湿信号补偿）。
    tubeCompensation = comp.clamp(-12.0, 12.0);
    setFloat(ParamId.tubeCompensation, tubeCompensation);
    notifyListeners();
  }

  void setTubeMix(double mix) {
    // P-011：引擎 tube.mix 已接线（vendor 干湿混合）。
    tubeMix = mix.clamp(0.0, 1.0);
    setFloat(ParamId.tubeMix, tubeMix);
    notifyListeners();
  }

  /* ---- 多段图形均衡器（Phase 3） ---- */

  /// C4：按当前采样率重建 EQ 频率网格，增益按**频率**重新映射。
///
/// 裁掉高频带时不能简单截断 gains —— 那样低频段的增益会整体错位。
/// 这里对每个新频点取旧网格中最接近的旧频点上的增益，
/// 于是 Nyquist 以内的部分行为完全不变，只有越界的频带连同其增益一起消失。
void _rebuildEqGridForSampleRate({bool notify = true}) {
  final target = eqGridFor(eqBandsCount, engineRate);
  if (target.isEmpty) return;
  if (target.length == eqFrequencies.length) {
    var same = true;
    for (var i = 0; i < target.length; i++) {
      if ((target[i] - eqFrequencies[i]).abs() > 1e-9) {
        same = false;
        break;
      }
    }
    if (same) return;   // 无变化，不必重推曲线
  }
  final oldFreqs = eqFrequencies;
  final oldGains = eqGains;
  final oldQs = eqQs;
  final newGains = <double>[];
  final newQs = <double>[];
  for (final f in target) {
    if (oldFreqs.isEmpty || oldGains.isEmpty) {
      newGains.add(0.0);
      newQs.add(eqQ);
      continue;
    }
    var bi = 0;
    var best = double.infinity;
    for (var i = 0; i < oldFreqs.length; i++) {
      final d = (oldFreqs[i] - f).abs();
      if (d < best) {
        best = d;
        bi = i;
      }
    }
    newGains.add(oldGains[bi]);
    newQs.add(bi < oldQs.length ? oldQs[bi] : eqQ);
  }
  eqFrequencies = target;
  eqGains = newGains;
  eqQs = newQs;
  _pushEqCurve();
  if (notify) notifyListeners();
}

/// 采样率变更后由调用方触发，重建网格并把新值落盘。
void setSampleRate(int rate) {
  if (rate == config.sampleRate) return;
  config.sampleRate = rate;
  ConfigManager.save(config);
  _rebuildEqGridForSampleRate();
}

void setEqBandsCount(int count) {
    if (count == eqBandsCount) return;
    eqBandsCount = count;
    /* C4：网格按采样率裁剪，避免高频带在 Nyquist 处塌缩成重复点 */
    final newFreqs = eqGridFor(count, engineRate);
    final oldFreqs = eqFrequencies;
    final oldGains = eqGains;
    final oldQs = eqQs;
    final newGains = <double>[];
    final newQs = <double>[];
    for (final f in newFreqs) {
      if (oldFreqs.isEmpty || oldGains.isEmpty) {
        newGains.add(0.0);
        newQs.add(eqQ);
        continue;
      }
      if (f <= oldFreqs.first) {
        newGains.add(oldGains.first);
        newQs.add(oldQs.isNotEmpty ? oldQs.first : eqQ);
      } else if (f >= oldFreqs.last) {
        newGains.add(oldGains.last);
        newQs.add(oldQs.isNotEmpty ? oldQs.last : eqQ);
      } else {
        var idx = 0;
        while (idx < oldFreqs.length - 1 && oldFreqs[idx + 1] < f) {
          idx++;
        }
        final logF0 = math.log(oldFreqs[idx]);
        final logF1 = math.log(oldFreqs[idx + 1]);
        final logTarget = math.log(f);
        final ratio = (logTarget - logF0) / (logF1 - logF0);
        newGains.add(oldGains[idx] + ratio * (oldGains[idx + 1] - oldGains[idx]));
        // Q 是频带属性，不做对数插值：取最近频带的 Q，保持钟形宽度语义。
        var bi = 0;
        var best = double.infinity;
        for (var i = 0; i < oldFreqs.length; i++) {
          final d = (oldFreqs[i] - f).abs();
          if (d < best) {
            best = d;
            bi = i;
          }
        }
        newQs.add(bi < oldQs.length ? oldQs[bi] : eqQ);
      }
    }
    eqFrequencies = List.from(newFreqs);
    eqGains = newGains;
    eqQs = newQs;
    _pushEqCurve();
  }

  void setEqBandGain(int index, double gain) {
    if (index >= 0 && index < eqGains.length) {
      eqGains[index] = gain.clamp(-18.0, 18.0);
      eqPresetName = 'custom';
      _pushEqCurve();
    }
  }

  /// 设置单个频点的 Q（0.3~10.0）。
  ///
  /// Q 会进入目标曲线合成（见 [_pushEqCurve]），因此必然改变曲线签名、
  /// 触发引擎重建与响应重测——与增益同一待遇。
  void setEqBandQ(int index, double q) {
    if (index < 0 || index >= eqQs.length) return;
    eqQs[index] = q.clamp(0.3, 10.0);
    eqPresetName = 'custom';
    _pushEqCurve();
  }

  void setEqQ(double q) {
    // 旧版全局 Q：只更新缺省值（新频带补齐与旧预设兼容用），不再重推曲线。
    // 各频点的实际 Q 一律走 [eqQs] + [setEqBandQ]。
    eqQ = q.clamp(0.3, 10.0);
    notifyListeners();
  }

  void setEqFilter(int filter) {
    // 架构选择目前只属于 UI/预设状态，尚未映射到引擎工作模式。
    eqFilter = filter;
    notifyListeners();
  }

  /// 按**频率**应用一条 EQ 曲线（C4）。
///
/// 预设里存的是「频点 + 增益」配对，而载入时的网格由当前采样率与段数决定，
/// 两者不一定一致。若按下标灌入，低采样率裁掉高频带后整条曲线会错位。
/// 这里对当前网格的每个频点，取预设中最接近的那个频点上的增益 ——
/// 于是采样率/段数只影响取样密度，曲线形状不变。
///
/// 预设频点与当前网格无交集时（例如预设来自更高采样率、而当前网格低到
/// 只能覆盖极低频）则整体取预设的第一个增益，至少不丢整条曲线。
void applyEqCurve(List<double> freqs, List<double> gains) {
  if (freqs.isEmpty || gains.isEmpty) return;
  if (freqs.length != gains.length) {
    applyEqGains(gains);
    return;
  }
  final out = List<double>.filled(eqFrequencies.length, 0.0);
  for (var i = 0; i < eqFrequencies.length; i++) {
    final f = eqFrequencies[i];
    var bi = 0;
    var best = double.infinity;
    for (var k = 0; k < freqs.length; k++) {
      final d = (freqs[k] - f).abs();
      if (d < best) {
        best = d;
        bi = k;
      }
    }
    out[i] = gains[bi].clamp(-18.0, 18.0);
  }
  for (var i = 0; i < eqGains.length; i++) {
    eqGains[i] = i < out.length ? out[i] : 0.0;
  }
  _pushEqCurve();
}

/// 按**频率**应用一条 Q 曲线（与 [applyEqCurve] 同构）。
///
/// 预设/会话里的 `qs` 与当前网格不对齐时，按最近频点重映射；
/// 长度对不上频率表时按下标截断对齐；缺省用 [eqQ] 补齐。
void applyEqQs(List<double>? freqs, List<double> qs) {
  if (qs.isEmpty) return;
  final aligned = List<double>.filled(eqFrequencies.length, eqQ);
  if (freqs != null && freqs.length == qs.length && freqs.isNotEmpty) {
    for (var i = 0; i < eqFrequencies.length; i++) {
      final f = eqFrequencies[i];
      var bi = 0;
      var best = double.infinity;
      for (var k = 0; k < freqs.length; k++) {
        final d = (freqs[k] - f).abs();
        if (d < best) {
          best = d;
          bi = k;
        }
      }
      aligned[i] = qs[bi].clamp(0.3, 10.0);
    }
  } else {
    for (var i = 0; i < aligned.length && i < qs.length; i++) {
      aligned[i] = qs[i].clamp(0.3, 10.0);
    }
  }
  eqQs = aligned;
  _pushEqCurve();
}

/// 用同一个 Q 填满全部频点（兼容只有标量 `q` 的旧预设/会话）。
void fillEqQ(double q) {
  eqQ = q.clamp(0.3, 10.0);
  eqQs = List<double>.filled(eqFrequencies.length, eqQ);
  _pushEqCurve();
}

/// 整表写入 EQ 增益并重推曲线。
  /// 必须走本方法而不能直接 `eqGains[i] = v`：eqGains 是裸 `List<double>`，
  /// 直接赋值不会触发 _pushEqCurve()，引擎会继续用上一条曲线
  /// （预设恢复 EQ 时就是这么丢增益的）。
  void applyEqGains(List<double> gains) {
    for (var i = 0; i < gains.length && i < eqGains.length; i++) {
      eqGains[i] = gains[i].clamp(-18.0, 18.0);
    }
    _pushEqCurve();
  }

  void setEqInterp(int interp) {
    // 插值选择目前只属于 UI/预设状态，尚未映射到引擎工作模式。
    eqInterp = interp;
    notifyListeners();
  }

  void toggleEqBypass() {
    eqBypass = !eqBypass;
    setInt('eq.enable', (eqOn && !eqBypass) ? 1 : 0);
    notifyListeners();
  }

  void flattenEq() {
    eqGains = List.filled(eqFrequencies.length, 0.0);
    eqPresetName = 'flat';
    _pushEqCurve();
  }

  void applyEqPreset(String style) {
    eqPresetName = style;
    final newGains = List.filled(eqFrequencies.length, 0.0);
    for (var i = 0; i < eqFrequencies.length; i++) {
      final f = eqFrequencies[i];
      final logF = math.log(f) / math.ln10; // log10
      var g = 0.0;
      switch (style) {
        case 'pop':
          if (logF <= 2.2) {
            g = 3.0 * (1.0 - (logF - 1.3) / 0.9);
          } else if (logF <= 3.2) {
            g = -1.0;
          } else {
            g = 3.0 * ((logF - 3.2) / 1.1);
          }
        case 'rock':
          if (logF <= 2.0) {
            g = 4.5;
          } else if (logF <= 3.0) {
            g = -2.0;
          } else if (logF <= 3.6) {
            g = 1.0;
          } else {
            g = 4.0;
          }
        case 'jazz':
          if (logF <= 2.3) {
            g = 2.5;
          } else if (logF <= 3.3) {
            g = 1.5;
          } else {
            g = -1.0;
          }
        case 'classical':
          if (logF >= 3.0 && logF <= 3.8) {
            g = 1.5;
          } else {
            g = 0.5;
          }
        case 'vocal':
          if (logF <= 2.0) {
            g = -3.5;
          } else if (logF >= 2.8 && logF <= 3.6) {
            g = 4.0;
          } else {
            g = 0.0;
          }
        case 'smile':
          final x = (logF - 2.8) / 1.5;
          g = (x * x) * 8.0 - 3.0;
        case 'bass_boost':
          if (logF <= 2.3) {
            g = 6.0 * (1.0 - (logF - 1.3) / 1.0);
          } else {
            g = 0.0;
          }
        case 'treble_boost':
          if (logF >= 3.3) {
            g = 5.0 * ((logF - 3.3) / 1.0);
          } else {
            g = 0.0;
          }
        case 'flat':
        default:
          g = 0.0;
      }
      newGains[i] = g.clamp(-18.0, 18.0);
    }
    eqGains = newGains;
    _pushEqCurve();
  }

  // A3: eq.curve 合并下发。拖滑块约 60Hz 触发，而引擎侧
  // MultimodalEqualizerAxisInterpolation（makima + 最小相位 IR + FFT 卷积刷新）
  // 实测约 760µs，且运行在驱动 WASAPI 的音频 isolate 上，会挤掉渲染回调造成爆音。
  // 这里合并为 ≤20Hz 并保证尾部补发；UI 的 notifyListeners 仍即时，不影响手感。
  static const int _eqCurveMinIntervalMs = 50;
  String? _pendingEqCurve;
  Timer? _eqCurveTimer;
  DateTime _lastEqCurveSentAt = DateTime.fromMillisecondsSinceEpoch(0);

  static const int _bassGainMinIntervalMs = 50; // 20 Hz
  static const double _bassGainStepDb = 0.6; // 每步最多推进 0.6 dB
  double _bassRampCur = 0.0;
  double? _bassRampTarget;
  Timer? _bassGainTimer;
  bool _bassDisableAfterRamp = false;

  void _pushEqCurve() {
    // C3：锚点与频点都必须落在 Nyquist 以内。引擎原先只按 f<=96000 校验，
    // 低采样率（如 32k，Nyquist=16k）下硬编码的 20000 锚点会变成越界点。
    final nyquist = math.min(20000.0, engineRate / 2.0);
    // 先列出要序列化的目标频率轴（含 20Hz 起点与 Nyquist 终点），
    // 再按各频点峰值增益 + Q 合成该轴上的目标增益（见 [eqTargetGains]）。
    final axis = <double>[];
    if (eqFrequencies.isNotEmpty && eqFrequencies.first > 20) {
      axis.add(20.0);
    }
    for (var i = 0; i < eqFrequencies.length; i++) {
      axis.add(math.min(eqFrequencies[i], nyquist));
    }
    if (eqFrequencies.isNotEmpty && eqFrequencies.last < nyquist) {
      axis.add(nyquist);
    }
    final target = eqTargetGains(
      targetFreqs: axis,
      centers: eqFrequencies,
      peakGains: eqGains,
      qs: eqQs,
      sampleRate: engineRate,
    );
    final buffer = StringBuffer(
        'eqm:$eqInterp:${eqOpModeForFilter(eqFilter)};');
    for (var i = 0; i < axis.length; i++) {
      buffer.write('${axis[i].toStringAsFixed(1)}:${target[i].toStringAsFixed(1)}');
      if (i < axis.length - 1) buffer.write(';');
    }
    final curve = buffer.toString();
    // 内容完全相同时不再重推：Q 在平直频带上本就无声学意义，
    // 重推只会白白触发一次 EQ 卷积重建。
    if (curve == _pendingEqCurve || curve == eqResponseCurve) {
      notifyListeners();
      return;
    }
    _pendingEqCurve = curve;
    _flushEqCurve();
    _scheduleEqResponse();
    notifyListeners();
  }

  /* ---- C2：UI 曲线消费引擎实测响应 ----
   *
   * UI 原本在 log-f 上做 smoothstep 插值，而引擎走 makima + 最小相位 IR +
   * FFT 卷积 —— 最小相位化会引入过冲与频带间相互影响，两者本就不等
   * （实测最大偏差 2.61 dB）。这里让 UI 改画引擎的实测值。
   *
   * 探针一次约 29 ms，因此：
   *   - **绝不放进音频 isolate**（会挤掉渲染回调，P-006 的爆音成因）；
   *   - 只在拖拽**停下**后防抖触发，不逐帧调；
   *   - 按曲线字符串缓存，重复请求直接命中；
   *   - 失败时保留上一帧，绝不让 UI 变瞎。
   */
  static const int eqResponsePoints = 129;

  /// 引擎实测响应（dB），长度 [eqResponsePoints]；null 表示尚未取得。
  /// 绘制时应与 [eqResponseCurve] 比对，不一致说明已过期，需回退近似。
  List<double>? eqResponseDb;

  /// [eqResponseDb] 的实际上限频率：引擎按采样率 Nyquist 收窄，
  /// 不能假设恒为 20000Hz。
  double? eqResponseFMax;

  /// 合成「均衡器输出频谱」：把引擎下发的 EQ 输入谱叠加实测响应。
  ///
  /// EQ 位于 libjamesdsp 的单体链内部（processFloatMultiplexd 一次跑完全链），
  /// 拿不到它的输出 tap。但 EQ 是 LTI 系统，逐频点有严格的
  /// **|Y(f)| = |X(f)| · |H_eq(f)|**（这是线性系统幅度谱的乘法定理，
  /// 与相位无关），而 |H_eq| 正好就是 [eqResponseDb] 测到的东西。
  /// 于是输出谱 = 输入谱(dBFS) + 响应(dB)，是精确值而非近似。
  ///
  /// [bypassed] 为 true 时 H_eq ≡ 0（EQ 被旁路，链内不生效），
  /// 此时输出谱就等于输入谱——与 [_SpectrumEQPainter] 对曲线的处理一致。
  /// [responseCurve] 是 [respDb] 的来源签名，[expectedCurve] 是当前待显示曲线；
  /// 两者不一致说明响应尚未追上曲线，此时同样退化为输入谱，而不是用旧响应合成。
  static List<double> composeEqOutputSpectrum(
    List<double> eqIn,
    List<double>? respDb, {
    bool bypassed = false,
    String? responseCurve,
    String? expectedCurve,
    double? responseFMax,
  }) {
    final out = List<double>.filled(VizBands.count, 0);
    final n = eqIn.length < VizBands.count ? eqIn.length : VizBands.count;
    final responseCurrent =
        expectedCurve == null || responseCurve == expectedCurve;
    final flat =
        bypassed || respDb == null || respDb.length < 2 || !responseCurrent;
    for (var b = 0; b < n; b++) {
      if (flat) {
        out[b] = eqIn[b].clamp(0.0, 1.0);
        continue;
      }
      final hz = VizBands.centerHz(b);
      final db = VizBands.toDb(eqIn[b].clamp(0.0, 1.0)) +
          VizBands.responseDbAt(respDb, hz, responseFMax: responseFMax);
      out[b] = VizBands.fromDb(db);
    }
    return out;
  }

  /// 当前应显示的 EQ 曲线签名：待下发的新曲线优先，已测得的旧曲线次之。
  ///
  /// 响应探针有约 220ms 防抖，曲线变化后响应必然滞后。用该签名调用合成或绘制，
  /// 才能在响应追上之前退化，而不是用旧响应合成出一条已不存在的输出谱。
  String? get currentEqCurveSignature => _pendingEqCurve ?? eqResponseCurve;

  /// 用模型当前状态合成 EQ 输出谱：全局关闭或旁路时退化为输入谱，
  /// 响应签名过期时同样退化为输入谱。
  List<double> eqOutputSpectrum() {
    return composeEqOutputSpectrum(
      eqInSpectrum.value,
      eqResponseDb,
      bypassed: !isEqActive,
      responseCurve: eqResponseCurve,
      expectedCurve: currentEqCurveSignature,
      responseFMax: eqResponseFMax,
    );
  }

  /// [eqResponseDb] 对应的曲线字符串，用于失效判定。
  String? eqResponseCurve;

  Timer? _eqResponseTimer;

  /// UI 侧的引擎句柄。探针必须由 **UI isolate** 直接调用：
  /// 音频 isolate 正在驱动 WASAPI，在那里跑 29 ms 的探针必然造成 underrun。
  AuraDspLib? _ffiLib;

  AuraDspLib? get _probeLib {
    _ffiLib ??= () {
      try {
        return AuraDspLib.load();
      } catch (_) {
        return null;   // DLL 缺失：UI 退回近似曲线，不崩
      }
    }();
    return _ffiLib;
  }

  void _scheduleEqResponse() {
    _eqResponseTimer?.cancel();
    _eqResponseTimer = Timer(const Duration(milliseconds: 220), () {
      _eqResponseTimer = null;
      final c = _pendingEqCurve;
      if (c == null || c == eqResponseCurve) return;   // 缓存命中，无需重算
      final lib = _probeLib;
      if (lib == null) return;
      List<double>? db;
      try {
        db = lib.measureEqResponse(c, engineRate,
            nPoints: eqResponsePoints);
      } catch (_) {
        return;   // 探针异常：保留上一帧曲线
      }
      if (db == null) return;
      eqResponseDb = db;
      eqResponseCurve = c;
      eqResponseFMax = AuraDspLib.responseFMax(sampleRate: engineRate);
      notifyListeners();
    });
  }

  /// 带尾部补发的节流。
  ///
  /// 注意：不能在每次调用时取消并重建定时器——持续拖拽下定时器会被无限推迟，
  /// 曲线将永不更新。这里只在没有定时器在跑时补一个，保证每周期必发一次。
  void _flushEqCurve() {
    final pending = _pendingEqCurve;
    if (pending == null) return;
    final elapsed = DateTime.now().difference(_lastEqCurveSentAt).inMilliseconds;
    if (elapsed >= _eqCurveMinIntervalMs) {
      _eqCurveTimer?.cancel();
      _eqCurveTimer = null;
      _pendingEqCurve = null;
      _lastEqCurveSentAt = DateTime.now();
      setStringParam('eq.curve', pending);
    } else {
      _eqCurveTimer ??= Timer(
          Duration(milliseconds: _eqCurveMinIntervalMs - elapsed), _flushEqCurve);
    }
  }

  /* ---- 组件级微型延迟（真实脉冲响应实测，非查表） ---- */

  /// 实测得到的组件算法延迟（毫秒）。未探测过的组件返回 null，
  /// UI 必须显示"未测量"而不是编一个数字。
  final Map<String, double> _measuredLatencyMs = {};

  /// 正在探测中的组件（UI 据此显示进度并禁用重复点击）。
  final Set<String> _probing = {};

  /// 该组件当前可显示的延迟。
  ///
  /// 优先用**实测值**；未实测时对需要外部资源的组件（卷积/VDC/Liveprog）
  /// 才退回解析估算，并把来源标出来供 UI 如实展示。
  ({double ms, bool measured}) componentLatency(String compId) {
    final m = _measuredLatencyMs[compId];
    if (m != null) return (ms: m, measured: true);
    // 解析兜底：只有 convolver 能从已知的 IR 长度算出真正的附加延迟
    if (compId == 'convolver' && convEnabled && convReady &&
        convFrames > 0 && deviceRate > 0) {
      return (ms: (convFrames / deviceRate) * 1000.0, measured: false);
    }
    if (compId == 'comp' && compOn) {
      return (ms: 85.0, measured: false);
    }
    // Haas = 纯延迟线，按当前设定值标称（引擎 compute_latency 同值动态上报）。
    if (compId == 'haas' && haasOn) {
      return (ms: haasDelayMs, measured: false);
    }
    if (compId == 'arbmag' && arbmagOn && arbmagReady) {
      return (ms: 2.67, measured: false);
    }
    return (ms: 0.0, measured: false);
  }

  void _onComponentLatencyResult(String comp, int rc, int samples) {
    _probing.remove(comp);
    if (rc == 0) {
      _measuredLatencyMs[comp] = samples / deviceRate * 1000.0;
    } else {
      // 测量失败时不强行弹窗骚扰用户，清除旧测量值，在卡片上的 Badge
      // 静默保持「未测量」与 Tooltip 说明即可。
      _measuredLatencyMs.remove(comp);
    }
    notifyListeners();
  }

  /// 触发一次真实脉冲探测。
  /// 关键架构优化：采用独立后台 Isolate.run 异步执行，绝不塞进 audio_isolate 实时音频泵，
  /// 彻底消除测量时因阻塞音频泵循环引发的 WASAPI 缓冲区欠载爆音与声音卡顿。
  void refreshComponentLatency(String compId) async {
    if (_probing.contains(compId)) return;
    _probing.add(compId);
    _latencyRefreshTicks[compId] = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();

    final res = latencyProbeResource(compId) ?? '';
    final rate = info?.deviceRate.toDouble() ?? 48000.0;

    try {
      final result = await Isolate.run(() {
        final l = AuraDspLib.load();
        final out = malloc<Uint32>();
        final compPtr = compId.toNativeUtf8();
        int rc;
        try {
          out.value = 0;
          if (res.isEmpty) {
            rc = l.probeComponent(compPtr, rate, out);
          } else {
            final p = res.toNativeUtf8();
            try {
              rc = l.probeComponentWithResource(compPtr, p, rate, out);
            } finally {
              malloc.free(p);
            }
          }
          final samples = rc == 0 ? out.value.toInt() : 0;
          return {'rc': rc, 'samples': samples};
        } finally {
          malloc.free(out);
          malloc.free(compPtr);
        }
      });
      _onComponentLatencyResult(compId, result['rc'] as int, result['samples'] as int);
    } catch (_) {
      _onComponentLatencyResult(compId, -2, 0);
    }
  }

  /// 该组件实测所需的外部资源路径；无则返回 null（走无资源探针）。
  String? latencyProbeResource(String compId) {
    switch (compId) {
      case 'convolver':
        final p = convIrPath;
        return (p != null && p.isNotEmpty && File(p).existsSync()) ? p : null;
      case 'ddc':
        final p = ddcPath;
        return (p != null && p.isNotEmpty && File(p).existsSync()) ? p : null;
      default:
        return null;
    }
  }

  /// 该组件是否支持实测。卷积/VDC 需外部资源，但资源已加载时同样可测。
  static bool isLatencyProbeSupported(String compId) =>
      const {
        'bass', 'reverb', 'eq', 'tube', 'crossfeed', 'limiter', 'post', 'shelf',
        'convolver', 'ddc', 'bassmono', 'exciter', 'stereo', 'comp'
        // haas 不入列：探针双声道脉冲对单侧延迟失明（必然测 0ms），
        // 刷新回退到 componentLatency 的标称延迟（跟随 slider，诚实）。
      }.contains(compId);

  /// 探测进行中
  bool isProbingLatency(String compId) => _probing.contains(compId);

  void setSource(String kind, {String? path}) {
    sourceKind = kind == 'stop' ? '' : kind;
    // 文件源记住扩展名（mp3/wav 芯片各自高亮；isolate 侧按扩展名选解码器）。
    sourceExt = '';
    if (kind == 'file' && path != null) {
      final dot = path.lastIndexOf('.');
      if (dot >= 0 && dot < path.length - 1) {
        sourceExt = path.substring(dot + 1).toLowerCase();
      }
    }
    playing = kind != 'stop';
    notifyListeners();
    send({'cmd': 'source', 'kind': kind, 'path': path});
  }

  void toggleBypass() {
    bypass = !bypass;
    notifyListeners();
    send({'cmd': 'bypass', 'value': bypass});
  }

  bool saveAsUserPreset(String name, {String category = 'Custom', String description = ''}) {
    final preset = PresetLibrary.snapshot(this, name: name, category: category, description: description);
    final ok = PresetLibrary.saveUserPreset(preset);
    if (ok) activePresetName = name;
    notifyListeners();
    scheduleAutoSave();
    return ok;
  }

  void loadPreset(AuraPreset preset) {
    PresetLibrary.apply(this, preset);
    notifyListeners();
    scheduleAutoSave();
  }

  void setTheme(AuraThemeId id) {
    themeId = id;
    config.themeId = id.name;
    ConfigManager.save(config);
    notifyListeners();
    scheduleAutoSave();
  }

  void setLocale(Locale l) {
    locale = l;
    config.locale = l.languageCode;
    ConfigManager.save(config);
    notifyListeners();
    scheduleAutoSave();
  }

  void setAutoRestoreSession(bool enable) {
    config.autoRestoreSession = enable;
    if (_testing) {
      // 测试隔离：只改内存开关，不碰磁盘。
      notifyListeners();
      return;
    }
    ConfigManager.save(config);
    if (enable) {
      SessionMemory.save(this);
    } else {
      SessionMemory.clear();
    }
    notifyListeners();
  }

  void resetConfig() {
    config = ConfigManager.resetToDefaults();
    notifyListeners();
  }

  /// 废除品质档限定拦截，所有效果均自由放行
  @override
  void dispose() {
    _debounceSaveTimer?.cancel();
    // 测试隔离：testing 构造不落盘（且 _iso/_fromIso 本来就是 null，?. 本就安全）。
    if (!_testing) SessionMemory.save(this);
    _toIso?.send({'cmd': 'shutdown'});
    _iso?.kill(priority: Isolate.beforeNextEvent);
    _fromIso?.close();
    spectrum.dispose();
    eqInSpectrum.dispose();
    levelL.dispose();
    levelR.dispose();
    stageLevelsL.dispose();
    stageLevelsR.dispose();
    inputMeterInL.dispose();
    inputMeterInR.dispose();
    inputMeterOutL.dispose();
    inputMeterOutR.dispose();
    eventSeq.dispose();
    super.dispose();
  }
}

/// dBFS 线性表读数（等宽显示用）
String dbfsText(double db) {
  if (db <= -90) return '-INF';
  final v = db.abs() < 0.05 ? 0.0 : db;
  return '${v >= 0 ? '' : '-'}${v.abs().toStringAsFixed(1)}';
}

/// 延迟徽标配色档位
Color latencyColor(double ms, AuraPalette p) {
  if (ms <= 10) return p.success;
  if (ms <= 30) return p.warning;
  return p.accent2;
}
