// part of state.dart —— P1 按区拆分，纯搬运零改行。
part of '../state.dart';

class SavedPluginSlot {
  final int slot;
  final String path;
  final String id;
  final bool bypass;
  final int stage;
  final int channels;
  /// F-6（2026-10-23）：VB 各路 Ch 记忆（长度 8，下标=组）。
  /// null = 旧会话无此字段（回落全 0xFF，与历史行为一致）。
  final List<int>? routeChannels;
  const SavedPluginSlot({
    required this.slot,
    required this.path,
    this.id = '',
    this.bypass = false,
    this.stage = 3,
    this.channels = 0xFF,
    this.routeChannels,
  });
}

enum EngineConn { connecting, ready, fatal }

/// 右上徽标 / 主页 hero 的四态显示口径（见 [AppModel.engineDisplay]）。
enum EngineDisplay { error, bypass, idle, processing }

class EngineInfo {
  final int abi;
  final String version;
  final int deviceRate, deviceCh, bufferFrames;
  EngineInfo(
    this.abi,
    this.version,
    this.deviceRate,
    this.deviceCh,
    this.bufferFrames,
  );
}

class AudioDeviceItem {
  final String id;
  final String name;
  final bool isRender; // true: 播放端点 (内录/环回)；false: 录音端点 (麦克风/输入录制)
  final bool active;
  const AudioDeviceItem({
    required this.id,
    required this.name,
    required this.isRender,
    this.active = true,
  });

  /// 正常人可读的友好显示名称（清理调试残余、原始 Map toString 字符串、去除裸 GUID）
  String get friendlyName {
    var n = name.trim();
    // 1. 防御 Map.toString() 残留（如 `{name: Realtek Audio, id: ...}`）
    if (n.startsWith('{') && n.contains('name:')) {
      final m = RegExp(r'name:\s*(.*?)(?:,\s*id:|\s*})').firstMatch(n);
      if (m != null) {
        n = m.group(1)!.trim();
      }
    }
    // 2. 避免裸 GUID
    if (n.startsWith('{0.0.') && n.length > 30) {
      return '音频端点 (${n.substring(n.length - 8, n.length - 1)})';
    }
    return n;
  }
}

class GuardRejection {
  final String paramId, message;
  final int rc;
  GuardRejection(this.paramId, this.message, this.rc);
}

/// 集中式出厂默认值真相源（与 C++ 引擎 auradsp_create 初始状态严格对齐）
abstract class ParamDefaults {
  static const double bassGain = 0.0; // [0, 15] dB
  static const double stereoMix = 0.5; // [0, 1] 中性档 0.5（C3 统一单源，2026-10-19）
  static const double convMix = 1.0; // [0, 1] (100% 纯湿)
  static const double postGain = 0.0; // [-15, 15] dB
  static const double inputGain = 0.0; // [-15, 15] dB
  static const double inputBalanceL = 1.0; // 100%
  static const double inputBalanceR = 1.0; // 100%

  // Freeverb 空间混响
  static const double fvDecay = 0.5; // 50%
  static const double fvDamp = 0.5; // 50%
  static const double fvWet = 0.35; // 35%
  static const double fvDry = 1.0; // 100%
  static const double fvRoomSize = 1.2; // 1.2x
  static const double fvWidth = 1.0; // 100%

  // 低频搁架 (Shelf)
  static const double shelfFreq = 100.0; // 100 Hz
  static const double shelfGain = 0.0; // 0.0 dB

  // 低频单声道化 (BassMono)
  static const double bassmonoFreq = 120.0; // 120 Hz [20,300]

  // Haas 差分环绕
  static const double haasDelayMs = 12.0; // 12 ms [0,25]
  static const double haasMix = 1.0; // [0,1]
  static const int haasSideRight = 0; // 0=延迟右 1=延迟左
  static const int haasSideLeft = 1;

  // 空间音效 L1（影院预设默认；style 切换会整体覆盖下面三个）
  static const int spatialStyle = 0; // 0=影院 1=定位 2=中性
  static const double spatialRoom = 0.7; // [0,1]
  static const double spatialWidth = 1.0; // [0.5,1.5]
  static const double spatialCenter = 0.8; // [0,1]
  static const double spatialOutGain = 0.0; // [-12,6] dB
  static const double spatialMix = 1.0; // [0,1]
  static const double spatialElevation = 0.0; // [-30,30] 度
  static const double spatialHeadAzim = 0.0; // [-180,180] 度
  static const bool spatialHeadTrack = false;
  static const bool spatialBinaural = false; // 6/8ch→2ch 双耳虚拟环绕
  static const bool spatialFdn = false; // FDN 晚期混响
  static const double spatialLate = 0.25; // [0,1]

  // 激励器
  static const double exciterAmount = 0.3; // [0,1]
  static const double exciterHifreq = 5000.0; // 5 kHz [3000,10000]

  // 声场分带
  static const double stereoBand = 0.5; // 50%

  // 低音重构
  static const double bassIntensity = 0.6; // 60%
  static const int bassMode = 0; // 0: 动态增强, 1: 纯净低架, 2: 心理声学谐波
  static const double bassCutoff = 120.0; // 120 Hz
  static const double bassHarmonics = 0.45; // 45%
  static const double bassHarmonicBlend = 0.5; // 50% (平衡)
  static const double bassSubFloor = 25.0; // 25 Hz

  // 独立滤波器
  static const int filterType = 0; // 0=HP 1=LP 2=BP
  static const double filterFreq = 80.0; // 80 Hz
  static const double filterQ = 0.707; // Q

  // 电子管模拟器
  static const double tubeGain = 4.5; // +4.5 dB
  static const int tubeStyle = 0; // 0: 三极管, 1: 五极管, 2: 磁带温润
  static const double tubeCompensation = 0.0; // 0.0 dB
  static const double tubeMix = 1.0; // 100%

  // 多段图形均衡器
  static const int eqBandsCount = 15; // 15段
  static const double eqQ = 1.414; // Q 锐度
  static const int eqFilter = 0; // 0: FIR, 1: 6阶 IIR, 2: 12阶 IIR
  static const int eqInterp = 1; // 1: Makima, 0: PCHIP

  // 自动增益补偿与输出增益门
  static const bool bassAutoGain = false;
  static const double bassOutputGain = 0.0; // [-12, 6] dB
  static const bool eqAutoGain = false;
  static const double eqOutputGain = 0.0; // [-12, 6] dB
  static const bool reverbAutoGain = false;
  static const double reverbOutputGain = 0.0; // [-12, 6] dB
  static const bool tubeAutoGain = false;
  static const double tubeOutputGain = 0.0; // [-12, 6] dB
  static const bool compAutoGain = false;
  static const double compOutputGain = 0.0; // [-12, 6] dB

  // 噪声门 + Deesser + 迟滞/底线/保持
  static const double gateThreshold = -40.0; // dB [-60,0]
  static const double gateAttack = 10.0; // ms [1,100]
  static const double gateRelease = 100.0; // ms [10,500]
  static const double gateHysteresis = 3.0; // dB [0,12]
  static const double gateRange = -60.0; // dB [-80,0]
  static const double gateHoldMs =
      10.0; // ms [0,500]；B-3 定案：Dart 对齐引擎（听感无差异→保持出厂值）
  static const double deesserFreq = 6000.0; // Hz [2000,10000]
  static const double deesserAmount = 0.5; // [0,1]

  // Modern Lookahead Limiter (自适应前瞻与立体声联动)
  static const double limiterRelease =
      100.0; // ms [5,500]；B-3 定案：Dart 对齐引擎（听感无差异→平滑优先出厂值）
  static const double limiterThreshold = -0.1; // dBFS [-24,0]
  static const bool limiterLink = true; // true=联动, false=独立
  static const bool limiterLookahead = false; // B-3(A1)：对齐引擎默认 0=零延迟

  // 2x 多相半带过采样 (HQ Oversampling)；B-3(A1)：默认对齐引擎（1=2x 高精）
  static const bool exciterOversample = true;
  static const bool tubeOversample = true;

  // 全参数动态EQ（3 段）
  static const double dyneqAttack = 2.0; // ms [0.1,100]
  static const double dyneqRelease = 120.0; // ms [10,1000]
  static const double dyneqB1Attack = 20.0; // B-3(A1)：对齐引擎 dyneq_b1_attack=20
  static const double dyneqB1Release = 120.0;
  static const double dyneqB2Attack = 10.0; // B-3(A1)：对齐引擎 dyneq_b2_attack=10
  static const double dyneqB2Release =
      100.0; // B-3(A1)：对齐引擎 dyneq_b2_release=100
  static const double dyneqB3Attack = 2.0;
  static const double dyneqB3Release = 120.0;
  static const double dyneqLowFreq = 120.0; // Hz [20,500]
  static const double dyneqLowQ = 0.707; // shelf S [0.5,2]
  static const double dyneqLowGain = 0.0; // dB [-12,12]
  static const double dyneqLowRange = 6.0; // dB [0,24]
  static const double dyneqLowThreshold = -30.0; // dBFS [-60,0]
  static const double dyneqMidFreq = 1000.0; // Hz [200,8000]
  static const double dyneqMidQ = 1.0; // bell Q [0.3,10]
  static const double dyneqMidGain = 0.0;
  static const double dyneqMidRange = 6.0;
  static const double dyneqMidThreshold = -30.0;
  static const double dyneqHighFreq = 6000.0; // Hz [2000,20000]
  static const double dyneqHighQ = 0.707;
  static const double dyneqHighGain = 0.0;
  static const double dyneqHighRange = 6.0;
  static const double dyneqHighThreshold = -30.0;

  // 响度补偿
  static const double loudnessAmount = 0.5; // [0,1]
  static const bool arbmagAutoGain = false;
  static const double arbmagOutputGain = 0.0; // [-12, 6] dB

  // 任意响应 EQ (ArbMag)
  static const bool arbmagOn = false;
  static const String arbmagString = '';
}
