/*
 * state.dart — AppModel：主 isolate 侧的应用状态
 *
 * 职责：持有音频 isolate（唯一 auradsp_handle 所有者），把消息协议翻译为
 * 可观察状态；viz 高频数据走独立 ValueNotifier（30fps），避免整页重建。
 */
import 'dart:async';
import 'dart:convert' show jsonDecode, utf8;
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
import 'audio_modes.dart';
import 'eel_slider_parser.dart';
import 'plugin_manager.dart';
import 'param_schema.dart';
import 'presets.dart';
import 'session_memory.dart';
import 'theme.dart';
import 'tray_service.dart';

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

/// 右上徽标 / 主页 hero 的四态显示口径（见 [AppModel.engineDisplay]）。
enum EngineDisplay { error, bypass, idle, processing }

class EngineInfo {
  final int abi;
  final String version;
  final int deviceRate, deviceCh, bufferFrames;
  EngineInfo(this.abi, this.version, this.deviceRate, this.deviceCh,
      this.bufferFrames);
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

  // 空间音效 L1（影院预设默认；style 切换会整体覆盖下面三个）
  static const int spatialStyle = 0;         // 0=影院 1=定位 2=中性
  static const double spatialRoom = 0.7;     // [0,1]
  static const double spatialWidth = 1.0;    // [0.5,1.5]
  static const double spatialCenter = 0.8;  // [0,1]
  static const double spatialOutGain = 0.0;  // [-12,6] dB

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

  // 噪声门 + Deesser + 迟滞/底线/保持
  static const double gateThreshold = -40.0;   // dB [-60,0]
  static const double gateAttack = 10.0;       // ms [1,100]
  static const double gateRelease = 100.0;     // ms [10,500]
  static const double gateHysteresis = 3.0;    // dB [0,12]
  static const double gateRange = -60.0;       // dB [-80,0]
  static const double gateHoldMs = 20.0;       // ms [0,500]
  static const double deesserFreq = 6000.0;    // Hz [2000,10000]
  static const double deesserAmount = 0.5;     // [0,1]

  // Modern Lookahead Limiter (自适应前瞻与立体声联动)
  static const double limiterRelease = 50.0;   // ms [5,500]
  static const double limiterThreshold = -0.1; // dBFS [-24,0]
  static const bool limiterLink = true;        // true=联动, false=独立
  static const bool limiterLookahead = true;   // true=1.5ms lookahead, false=0-latency

  // 2x 多相半带过采样 (HQ Oversampling)
  static const bool exciterOversample = false;
  static const bool tubeOversample = false;

  // 全参数动态EQ（3 段）
  static const double dyneqAttack = 2.0;       // ms [0.1,100]
  static const double dyneqRelease = 120.0;    // ms [10,1000]
  static const double dyneqB1Attack = 2.0;
  static const double dyneqB1Release = 120.0;
  static const double dyneqB2Attack = 2.0;
  static const double dyneqB2Release = 120.0;
  static const double dyneqB3Attack = 2.0;
  static const double dyneqB3Release = 120.0;
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
  // 频谱门：进程内 playing 或 VB/ASIO/VAIO 桥活着都算 live。
  bool get liveSpectrum => playing || vbActive || asioActive || vaioActive;
  // 四态显示口径（右上徽标/主页 hero 共用）：engineState==0 混了"用户旁路"与
  // "无源空闲"，以前一刀切标"旁路"，导致开关 OFF 却处处显示旁路。拆开：
  // 开关开→旁路；开关没开但引擎报 0→空闲；引擎 1→看有没有活数据。
  EngineDisplay get engineDisplay {
    if (engineState == 2) return EngineDisplay.error;
    if (bypass) return EngineDisplay.bypass;
    if (engineState == 0) return EngineDisplay.idle;
    return liveSpectrum ? EngineDisplay.processing : EngineDisplay.idle;
  }
  bool bypass = false;
  String sourceKind = ''; // '' | 'tone' | 'pink' | 'file'
  String sourcePath = ''; // 文件源路径（isolate 重启后重推音源用；tone/pink 为空）
  // WASAPI 输出缺失（默认端点被独占/幽灵）：isolate 降级就绪的报错原文；
  // 非空即降级态（引擎照跑，VB/ASIO 不受影响），进程内试音等重试恢复。
  String wasapiError = '';
  String sourceExt = ''; // 文件源扩展名（小写无点，如 'mp3'/'wav'；非文件源为空）

  // P3: 全链路数据驱动参数体系：强类型 Spec 动态存储与访问器
  final Map<String, dynamic> _paramValues = {};

  /// 强类型通用参数读取
  T getParam<T>(ParamSpec<T> spec) {
    final val = _paramValues[spec.id];
    if (val != null) return spec.cast(val);
    final current = spec.read(this);
    _paramValues[spec.id] = current;
    return current;
  }

  /// 强类型通用参数设值
  void setParam<T>(ParamSpec<T> spec, T value, {bool notify = true}) {
    final clamped = spec.clamp(value);
    _paramValues[spec.id] = clamped;
    spec.write(this, clamped);
    if (notify) notifyListeners();
  }

  /// 按参数 ID 通用读取
  dynamic getParamById(String id) {
    final spec = ParamRegistry.byId[id];
    if (spec != null) return getParam(spec);
    return _paramValues[id];
  }

  /// 按参数 ID 通用设值
  void setParamById(String id, dynamic value, {bool notify = true}) {
    final spec = ParamRegistry.byId[id];
    if (spec != null) {
      setParam(spec, spec.cast(value), notify: notify);
    } else {
      _paramValues[id] = value;
      if (value is num) {
        setFloat(id, value.toDouble());
      } else if (value is bool) {
        setInt(id, value ? 1 : 0);
      } else if (value is String) {
        send({'cmd': 'setParamStr', 'id': id, 'text': value});
      }
      if (notify) notifyListeners();
    }
  }

  /// 检查某处理节是否处于激活状态（用于自绑定组件 enabled 联动）
  bool isSectionEnabled(String section) {
    if (section == 'input' || section == 'routing') return true;
    if (section == 'post') return limiterOn;
    if (section == 'shelf' || section == 'bassmono' || section == 'bass_shaping') {
      return bassShapingOn;
    }
    return isStageEnabled(section);
  }

  // 参数镜像（engine 侧真相，UI 只做回显与乐观更新）
  bool bassOn = false, eqOn = false, limiterOn = true;
  double limiterReleaseMs = ParamDefaults.limiterRelease;
  double limiterThreshold = ParamDefaults.limiterThreshold;
  bool limiterLink = ParamDefaults.limiterLink;
  bool limiterLookahead = ParamDefaults.limiterLookahead;
  double bassGain = ParamDefaults.bassGain,
      stereoMix = ParamDefaults.stereoMix,
      postGain = ParamDefaults.postGain,
      inputGain = ParamDefaults.inputGain,
      inputBalanceL = ParamDefaults.inputBalanceL,
      inputBalanceR = ParamDefaults.inputBalanceR;
  int reverbPreset = -1;
  int channelsMode = 0;
  // 音频处理模式 id（AudioModes.optionsFor(currentOs) 取值；'auto' 表跟随当前引擎）。
  // 引擎接线待后续版本，当前仅持久化 + UI 展示。
  String audioMode = 'auto';
  // VB-Callback 桥状态（isolate 回推；inactive 时为空）。
  bool vbActive = false;
  Map<String, dynamic> vbInfo = {};
  // VB 总线掩码（bit g=第 g 条总线进 DSP；落盘，进桥时下发；CHANGE 重建不丢）。
  int vbBusMask = 0xFF;
  // ASIO 常驻桥状态（04 桥；isolate 回推，与 VB 桥互斥——一次只跑一个后端）。
  bool asioActive = false;
  Map<String, dynamic> asioInfo = {};
  // asio_detect 驱动清单（isolate 回推；[{name,dll,clsid}]，name 为 UTF-8 显示名）。
  List<Map<String, String>> asioDrivers = [];
  String asioDriversNote = ''; // 桥缺失/无驱动时的原因（设置页展示）
  // AuraVAIO 桥状态（01 桥；isolate 回推，与 VB/ASIO 互斥）。
  bool vaioActive = false;
  Map<String, dynamic> vaioInfo = {};
  Map<String, dynamic> vaioDetectInfo = {};

  // ADR-009 范式与细分项快捷 getter
  String get modeCategory => config.modeCategory;
  String get attachmentMode => config.attachmentMode;
  String get pipelineInput => config.pipelineInput;
  String get pipelineOutput => config.pipelineOutput;
  String get pipelineInputDevice => config.pipelineInputDevice;
  String get pipelineOutputDevice => config.pipelineOutputDevice;
  String get apoTargetEndpoint => config.apoTargetEndpoint;
  bool get monitorMirroring => config.monitorMirroring;
  bool get pipelineInputEnabled => config.pipelineInputEnabled;
  bool get pipelineOutputEnabled => config.pipelineOutputEnabled;
  List<AudioDeviceItem> wasapiDevices = [];

  List<AudioDeviceItem> get filteredWasapiInputs {
    final list = <AudioDeviceItem>[];
    for (final d in wasapiDevices) {
      final n = d.name.toLowerCase();
      if (n.contains('auravaio') ||
          n.contains('auradsp virtual asio') ||
          n.contains('auradsp asio')) {
        continue;
      }
      list.add(d);
    }
    if (list.isEmpty) {
      list.addAll([
        const AudioDeviceItem(
            id: 'def_render',
            name: '系统扬声器 / 扬声器 (Realtek High Definition Audio)',
            isRender: true),
        const AudioDeviceItem(
            id: 'def_mic',
            name: '麦克风阵列 (适用于数字麦克风的英特尔® 智音技术)',
            isRender: false),
        const AudioDeviceItem(
            id: 'def_stereo_mix',
            name: '立体声混音 (Realtek Audio)',
            isRender: false),
      ]);
    }
    return list;
  }

  List<AudioDeviceItem> get filteredWasapiOutputs {
    final list = <AudioDeviceItem>[];
    for (final d in wasapiDevices) {
      if (!d.isRender) continue;
      final n = d.name.toLowerCase();
      if (n.contains('auravaio') ||
          n.contains('auradsp virtual asio') ||
          n.contains('auradsp asio')) {
        continue;
      }
      list.add(d);
    }
    if (list.isEmpty) {
      final eps = (vaioDetectInfo['endpoints'] as List?) ?? [];
      for (final ep in eps) {
        String name = '';
        String id = '';
        if (ep is Map) {
          name = (ep['name'] as String?) ?? '';
          id = (ep['id'] as String?) ?? name;
        } else if (ep is String) {
          if (ep.startsWith('{') && ep.contains('name:')) {
            final m = RegExp(r'name:\s*(.*?)(?:,\s*id:|\s*})').firstMatch(ep);
            name = m != null ? m.group(1)!.trim() : ep;
            id = name;
          } else {
            name = ep;
            id = ep;
          }
        }
        if (name.isEmpty) continue;
        final n = name.toLowerCase();
        if (!n.contains('auravaio') &&
            !n.contains('auradsp virtual asio') &&
            !n.contains('auradsp asio')) {
          list.add(AudioDeviceItem(id: id, name: name, isRender: true));
        }
      }
      if (list.isEmpty) {
        list.addAll([
          const AudioDeviceItem(
              id: 'def_render_realtek',
              name: '扬声器 (Realtek High Definition Audio)',
              isRender: true),
          const AudioDeviceItem(
              id: 'def_render_usb',
              name: '耳机 (USB Audio Device)',
              isRender: true),
        ]);
      }
    }
    return list;
  }

  /// 解析后的 VAIO 物理输出端点列表（过滤掉虚拟驱动自身，供 UI 选择真实物理扬声器/耳机）
  List<AudioDeviceItem> get vaioPhysicalEndpoints {
    final list = <AudioDeviceItem>[];
    final eps = (vaioDetectInfo['endpoints'] as List?) ?? [];
    for (final ep in eps) {
      String name = '';
      String id = '';
      if (ep is Map) {
        name = (ep['name'] as String?) ?? '';
        id = (ep['id'] as String?) ?? name;
      } else if (ep is String) {
        if (ep.startsWith('{') && ep.contains('name:')) {
          final m = RegExp(r'name:\s*(.*?)(?:,\s*id:|\s*})').firstMatch(ep);
          name = m != null ? m.group(1)!.trim() : ep;
          id = name;
        } else {
          name = ep;
          id = ep;
        }
      }
      if (name.isEmpty) continue;
      final lower = name.toLowerCase();
      if (lower.contains('auravaio') ||
          lower.contains('auradsp virtual asio') ||
          lower.contains('auradsp asio')) {
        continue;
      }
      list.add(AudioDeviceItem(id: id, name: name, isRender: true));
    }
    // 若 VAIO 探测结果暂未就绪，使用 filteredWasapiOutputs 兜底
    if (list.isEmpty) {
      for (final d in filteredWasapiOutputs) {
        list.add(d);
      }
    }
    return list;
  }

  /// 获取有效输入设备（在就按记忆，不在/离线走默认 ''）
  String get effectivePipelineInputDevice {
    final dev = config.pipelineInputDevice;
    if (dev.isEmpty) return '';
    final exists = filteredWasapiInputs.any((d) => d.id == dev || d.name == dev);
    return exists ? dev : '';
  }

  /// 获取有效输出设备（在就按记忆，不在/离线走默认 ''）
  String get effectivePipelineOutputDevice {
    final dev = config.pipelineOutputDevice;
    if (dev.isEmpty) return '';
    final exists = filteredWasapiOutputs.any((d) => d.id == dev || d.name == dev);
    return exists ? dev : '';
  }

  /// 获取有效 VAIO 物理输出端点（在就按记忆，不在/离线走默认 ''）
  String get effectiveVaioOutputEndpoint {
    final ep = config.vaioOutputEndpoint;
    if (ep.isEmpty) return '';
    final exists = vaioPhysicalEndpoints.any((d) => d.name == ep || d.id == ep);
    return exists ? ep : '';
  }

  // ASIO 驱动注册状态 (AuraDSP Virtual ASIO Driver)
  bool asioDriverInstalled = false;
  // System APO 挂载状态与运行时遥测
  bool apoAttached = false;
  bool apoHeartbeatAlive = false;
  int apoHeartbeatSeq = 0;
  int apoHeartbeatSr = 0;
  int apoHeartbeatFrames = 0;
  List<Map<String, dynamic>> apoInstalledEndpoints = [];
  bool isApoOperating = false;
  bool apoCompositeMode = false;

  // 底层驱动与音频服务异常信息跟踪（用于 UI 内联报警与用户引导）
  String? lastAudioError;
  String? lastVaioError;
  String? lastAsioError;
  String? lastApoError;

  void clearAudioError() {
    lastAudioError = null;
    notifyListeners();
  }

  void clearVaioError() {
    lastVaioError = null;
    notifyListeners();
  }

  void clearAsioError() {
    lastAsioError = null;
    notifyListeners();
  }

  void clearApoError() {
    lastApoError = null;
    notifyListeners();
  }

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
  bool tubeOversample = ParamDefaults.tubeOversample;
  int xfeedMode = 0; // 0: Default, 1: Chu Moy, 2: Jan Meier, 3: Custom
  double xfeedFcut = 700.0; // 300..2000 Hz
  double xfeedFeed = 4.5; // 1.0..15.0 dB

  // 动态压限器（Compander）
  bool compOn = false;
  double compTimeconstant = 0.14;
  int compGranularity = 1;
  int compTfresolution = 1;
  double compThreshold = -18.0;
  double compRatio = 4.0;
  final List<double> compFreqs = [95.0, 200.0, 400.0, 800.0, 1600.0, 3400.0, 7500.0];
  final List<double> compGains = [-0.35, -0.35, -0.35, -0.35, -0.35, -0.35, -0.35];

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

  // M5-b：低音塑形（Bass Shaping：合并低频搁架与单声道化）
  bool shelfOn = false;
  double shelfFreq = 100, shelfGain = 0;
  // 低频单声道化（BassMono，链头）
  bool bassmonoOn = false;
  double bassmonoFreq = 120;
  bool get bassShapingOn => shelfOn || bassmonoOn;
  // Haas 差分环绕（stereo 后 / reverb 前）
  bool haasOn = false;
  double haasDelayMs = 12, haasMix = 1.0;
  int haasSide = 0; // 0=延迟右 1=延迟左
  // 空间音效 L1（haas 后 / exciter 前；默认关闭，用户显式开启）
  bool spatialOn = false;
  int spatialStyle = 0;
  double spatialRoom = 0.7, spatialWidth = 1.0, spatialCenter = 0.8;
  double spatialOutGain = 0.0;
  bool spatialAutoGain = false;
  // 头跟预留（Phase 2 stub：透传 + 持久化，无 UI；传感器就绪后 DSP 按
  // azimuth 旋转摆位，详见 engine_internal.h spatial_headazim 注释）。
  double spatialHeadAzim = 0.0;
  bool spatialHeadTrack = false;
  // 5.1 源模式（Phase 2）：0=混缩（默认） 1=直通；fileChannels>2 时设置页露芯片。
  int source51Mode = 0;
  // 当前文件源声道数（isolate playing 事件回填；直通/UI 门控据此判定）。
  int fileChannels = 2;
  // 效果页分类过滤（会话内有效，不持久化；默认第一类「前置整形」，无"全部"）。
  String effectsCategory = 'front';
  // 激励器（Haas 后 / reverb 前，最后一道音色工序）
  bool exciterOn = false;
  double exciterAmount = 0.3, exciterHifreq = 5000;
  bool exciterOversample = ParamDefaults.exciterOversample;

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

  // 噪声门（链头）+ Deesser + 自动增益补偿 + 迟滞/底线/保持
  bool gateOn = false;
  double gateThreshold = -40, gateAttackMs = 10, gateReleaseMs = 100;
  double gateHysteresis = ParamDefaults.gateHysteresis;
  double gateRange = ParamDefaults.gateRange;
  double gateHoldMs = ParamDefaults.gateHoldMs;
  bool gateAutoGain = false;
  bool deesserOn = false;
  double deesserFreq = 6000, deesserAmount = 0.5;

  // 全参数动态EQ（3 段；默认全关）
  bool dyneqOn = false;
  double dyneqAttackMs = ParamDefaults.dyneqAttack;
  double dyneqReleaseMs = ParamDefaults.dyneqRelease;
  double dyneqB1Attack = ParamDefaults.dyneqB1Attack;
  double dyneqB1Release = ParamDefaults.dyneqB1Release;
  double dyneqB2Attack = ParamDefaults.dyneqB2Attack;
  double dyneqB2Release = ParamDefaults.dyneqB2Release;
  double dyneqB3Attack = ParamDefaults.dyneqB3Attack;
  double dyneqB3Release = ParamDefaults.dyneqB3Release;
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
  /// 引擎回显的 eq.curve 下发原串（字符串回读对账用；null=引擎无副本）。
  /// 引擎存的是原串副本（不重序列化），故可与 `_pushEqCurve` 输出直接比对
  /// 检测引擎侧钳位/漂移。不回灌 eqGains/eqFreqs（避免与用户拖拽打架）。
  String? engineEqCurve;
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
  /// 脏跟踪（2026-10-16 决策 #3）：最近一次成功应用预设时的状态指纹。
  /// null = 从未应用过预设（如全新安装），此时「偏离预设」无从谈起。
  String? appliedPresetFingerprint;
  /// 当前状态是否偏离已应用预设（任意一点偏离即 true → UI 显示
  /// 「自定义（未保存）」）。由 evaluatePresetDirty()（防抖保存回调内
  /// 统一触发）刷新，随 SessionMemory v5 持久化，重启后不丢。
  bool presetDirty = false;
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

  // 动态衰减量计量 (Gain Reduction, dB, 负值或 0.0)
  final grLimiter = ValueNotifier<double>(0.0);
  final grComp = ValueNotifier<double>(0.0);
  final grGate = ValueNotifier<double>(0.0);
  final grDyneqLow = ValueNotifier<double>(0.0);
  final grDyneqMid = ValueNotifier<double>(0.0);
  final grDyneqHigh = ValueNotifier<double>(0.0);

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

  /// 回读对账（2026-10-16 决策 #4）：
  /// 防抖回读已发出、'params' 事件未归时置位；_readbackRequestedAt 为发出
  /// 时刻，_lastEditAt 为最近一次用户编辑时刻。若编辑晚于发出 → 该轮回读
  /// **过期**，归来的事件不得采用（否则把用户最新一次改动回滚成旧值）。
  bool _readbackPending = false;
  int _readbackRequestedAt = 0;
  int _lastEditAt = 0;

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
    // 存量 audioMode 归一化到当前平台合法集（未知回平台默认并落盘）。
    audioMode = AudioModes.normalize(config.audioMode);
    if (audioMode != config.audioMode) {
      config.audioMode = audioMode;
      ConfigManager.save(config);
    }
    if (!testing) {
      checkAsioDriverStatus();
      checkApoStatus();
    }
    // VB 总线掩码：落盘值 0（=全关，无意义）回全开；其余取低 8 bit。
    final m = config.vbBusMask & 0xFF;
    vbBusMask = m == 0 ? 0xFF : m;
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
        // 回放守卫：restoreMemoryImage → apply 会触发各 setter 的
        // scheduleAutoSave；不置位则启动 500ms 后必把刚读入的数据
        // 原样写回磁盘（自写），且与引擎异步 getParams 存在竞态窗口。
        _isReplayingSession = true;
        try {
          SessionMemory.restoreMemoryImage(this, session);
        } finally {
          _isReplayingSession = false;
        }
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
    _lastEditAt = DateTime.now().millisecondsSinceEpoch;
    _debounceSaveTimer?.cancel();
    _debounceSaveTimer = Timer(
      Duration(milliseconds: config.autoSaveDebounceMs),
      () {
        SessionMemory.save(this);
        // 决策 #4：参数风暴平息后防抖回读引擎，全量 getParams 对账。
        // 与 setParam 同端口 FIFO —— 读到的必含此前全部改动，无同端竞态。
        scheduleReadback();
      },
    );
  }

  /// 防抖回读（决策 #4）：拉一次引擎全量 getParams，'params' 事件归来后
  /// 由分支顶部守卫决定采用或丢弃。快速频繁改动时每个 settle 窗口
  /// （autoSaveDebounceMs）只花一次往返，不在 setter 热路径上。
  void scheduleReadback() {
    if (_testing || _isReplayingSession) return;
    _readbackPending = true;
    _readbackRequestedAt = DateTime.now().millisecondsSinceEpoch;
    _toIso?.send({'cmd': 'getParams'});
  }

  /// 重算「偏离已应用预设」脏标记并按需通知 UI（2026-10-16 决策 #3）。
  /// 生产路径：防抖自动保存回调（SessionMemory.save 内部）统一触发——
  /// 用户快速频繁改动时，每 500ms 只花一次 snapshot 指纹的开销；
  /// 测试（_testing）可直呼。
  bool evaluatePresetDirty() {
    final fp = PresetLibrary.fingerprintOf(this);
    final dirty =
        appliedPresetFingerprint != null && fp != appliedPresetFingerprint;
    if (dirty != presetDirty) {
      presetDirty = dirty;
      notifyListeners();
    }
    return dirty;
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
    TrayService.instance.isWindowVisible.addListener(_onWindowVisibilityChanged);
  }

  void _onWindowVisibilityChanged() {
    send({'cmd': 'setVizSuspended', 'value': !TrayService.instance.isWindowVisible.value});
  }

  @visibleForTesting
  void handleMessageForTesting(dynamic raw) => _onMessage(raw);

  void _onMessage(dynamic raw) {
    if (raw is! Map) return;
    switch (raw['evt'] as String) {
      case 'isoReady':
        _toIso = raw['port'] as SendPort;
        if (!TrayService.instance.isWindowVisible.value) {
          send({'cmd': 'setVizSuspended', 'value': true});
        }
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
        _fatalRetries = 0; // 活过来了，backoff 计数清零
        // 输出恢复即清除降级标记（deviceRate>0 = 真有设备）。
        if ((raw['deviceRate'] as num?)?.toInt() != 0) wasapiError = '';
        notifyListeners();
        if (config.autoRestoreSession) {
          replaySessionToEngine();
        } else {
          _toIso?.send({'cmd': 'getParams'});
        }
        // 持久化的是 VB 模式：就绪后自动进桥（与用户上次状态一致）。
        if (audioMode == 'vbcallback') {
          _toIso?.send({'cmd': 'vbmode', 'on': true});
        }
        // 持久化的是 ASIO 模式：就绪后自动进桥（isolate 内部自带 detect）。
        if (audioMode == 'asio') {
          _toIso?.send({
            'cmd': 'asiomode',
            'on': true,
            'driver': config.asioDriver,
            'bufSize': config.asioBufSize,
            'outPair': config.asioOutPair,
          });
        }
        // 持久化的是 AuraVAIO 模式：就绪后自动进桥。
        if (audioMode == 'vaio') {
          _toIso?.send({
            'cmd': 'vaiomode',
            'on': true,
            'outputEndpoint': config.vaioOutputEndpoint,
          });
        }
        // isolate 重启（采样率切换）：标准 session 回放只管参数，不管音源选择
        // 与 bypass 开关——这里补推（model 级状态是真相源）。
        if (_pendingRestartPush) {
          _pendingRestartPush = false;
          if (bypass) send({'cmd': 'bypass', 'value': true});
          send({'cmd': 'source51', 'value': source51Mode});
          if (sourceKind.isNotEmpty) {
            send({
              'cmd': 'source',
              'kind': sourceKind,
              'path': sourcePath.isEmpty ? null : sourcePath
            });
            playing = true;
          } else {
            playing = false;
          }
          notifyListeners();
        }
        break;
      case 'params':
        // 决策 #4 对账守卫：用户触发（防抖）的回读若在发出后又有新编辑，
        // 则该轮回读已过期——采用会把最新改动回滚成旧值，直接丢弃。
        // 连接期/重放期回读（_readbackPending=false）不设防，照常全量采用。
        if (_readbackPending) {
          _readbackPending = false;
          if (_lastEditAt > _readbackRequestedAt) break;
        }
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
        shelfFreq = (raw['shelfFreq'] as num).toDouble().clamp(40.0, 400.0);
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
        if (raw['spatialEnable'] != null) {
          spatialOn = (raw['spatialEnable'] as int) != 0;
        }
        if (raw['spatialStyle'] != null) {
          spatialStyle = (raw['spatialStyle'] as int).clamp(0, 2);
        }
        if (raw['spatialRoom'] != null) {
          spatialRoom = (raw['spatialRoom'] as num).toDouble();
        }
        if (raw['spatialWidth'] != null) {
          spatialWidth = (raw['spatialWidth'] as num).toDouble();
        }
        if (raw['spatialCenter'] != null) {
          spatialCenter = (raw['spatialCenter'] as num).toDouble();
        }
        if (raw['spatialOutGain'] != null) {
          spatialOutGain = (raw['spatialOutGain'] as num).toDouble();
        }
        if (raw['spatialAutoGain'] != null) {
          spatialAutoGain = (raw['spatialAutoGain'] as int) != 0;
        }
        if (raw['spatialHeadAzim'] != null) {
          spatialHeadAzim = (raw['spatialHeadAzim'] as num).toDouble();
        }
        if (raw['spatialHeadTrack'] != null) {
          spatialHeadTrack = (raw['spatialHeadTrack'] as int) != 0;
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
        if (raw['exciterOversample'] != null) exciterOversample = (raw['exciterOversample'] as int) != 0;
        if (raw['tubeOversample'] != null) tubeOversample = (raw['tubeOversample'] as int) != 0;
        if (raw['limiterRelease'] != null) limiterReleaseMs = (raw['limiterRelease'] as num).toDouble();
        if (raw['limiterThreshold'] != null) limiterThreshold = (raw['limiterThreshold'] as num).toDouble();
        if (raw['limiterLink'] != null) limiterLink = (raw['limiterLink'] as int) != 0;
        if (raw['limiterLookahead'] != null) limiterLookahead = (raw['limiterLookahead'] as int) != 0;
        if (raw['gateHysteresis'] != null) gateHysteresis = (raw['gateHysteresis'] as num).toDouble();
        if (raw['gateRange'] != null) gateRange = (raw['gateRange'] as num).toDouble();
        if (raw['gateHoldMs'] != null) gateHoldMs = (raw['gateHoldMs'] as num).toDouble();
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
        if (raw['dyneqB1Attack'] != null) dyneqB1Attack = (raw['dyneqB1Attack'] as num).toDouble();
        if (raw['dyneqB1Release'] != null) dyneqB1Release = (raw['dyneqB1Release'] as num).toDouble();
        if (raw['dyneqB2Attack'] != null) dyneqB2Attack = (raw['dyneqB2Attack'] as num).toDouble();
        if (raw['dyneqB2Release'] != null) dyneqB2Release = (raw['dyneqB2Release'] as num).toDouble();
        if (raw['dyneqB3Attack'] != null) dyneqB3Attack = (raw['dyneqB3Attack'] as num).toDouble();
        if (raw['dyneqB3Release'] != null) dyneqB3Release = (raw['dyneqB3Release'] as num).toDouble();
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
        if (raw['fvEnable'] != null) fvOn = (raw['fvEnable'] as int) != 0;
        if (raw['fvDecay'] != null) fvDecay = (raw['fvDecay'] as num).toDouble();
        if (raw['fvDamp'] != null) fvDamp = (raw['fvDamp'] as num).toDouble();
        if (raw['fvWet'] != null) fvWet = (raw['fvWet'] as num).toDouble();
        if (raw['fvDry'] != null) fvDry = (raw['fvDry'] as num).toDouble();
        if (raw['compEnable'] != null) compOn = (raw['compEnable'] as int) != 0;
        if (raw['compTimeconstant'] != null) compTimeconstant = (raw['compTimeconstant'] as num).toDouble();
        if (raw['compGranularity'] != null) compGranularity = raw['compGranularity'] as int;
        if (raw['compTfresolution'] != null) compTfresolution = raw['compTfresolution'] as int;
        if (raw['compFreqs'] is List) {
          final list = (raw['compFreqs'] as List).map((e) => (e as num).toDouble()).toList();
          for (var i = 0; i < math.min(list.length, compFreqs.length); i++) {
            compFreqs[i] = list[i];
          }
        }
        if (raw['compGains'] is List) {
          final list = (raw['compGains'] as List).map((e) => (e as num).toDouble()).toList();
          for (var i = 0; i < math.min(list.length, compGains.length); i++) {
            compGains[i] = list[i];
          }
        }
        if (raw['arbmagReady'] != null) arbmagReady = (raw['arbmagReady'] as int) != 0;
        if (raw['arbmagNodeCount'] != null) arbmagNodeCount = raw['arbmagNodeCount'] as int;
        /* 字符串回读对账（预设 §8.1 / 调研 §1.2-1.3；null=引擎无副本或超 cap）：
         * - lpCode：编辑器内容即真相（v2 铁律）——只在本地为空时补位，
         *   绝不覆盖用户正在编辑的文本；用于引擎重起后回填与分叉检测。
         * - arbmagString：引擎是已应用曲线的真相源（可能被解析器钳位/规范化），
         *   非空即采纳，m 副本与之对齐。
         * - eqCurve：引擎回显的是下发原串（引擎存原串副本，不重序列化）——
         *   存独立对账字段，不回灌 eqGains/eqFreqs（避免 toStringAsFixed(1)
         *   舍入漂移与用户拖拽打架）。 */
        final rbLp = raw['lpCode'];
        if (rbLp is String && rbLp.isNotEmpty && (lpCode == null || lpCode!.isEmpty)) {
          lpCode = rbLp;
        }
        final rbArb = raw['arbmagString'];
        if (rbArb is String && rbArb.isNotEmpty && rbArb != arbmagString) {
          arbmagString = rbArb;
        }
        final rbEq = raw['eqCurve'];
        if (rbEq is String) engineEqCurve = rbEq.isEmpty ? null : rbEq;
        if (raw['arbmagEnable'] != null) {
          final en = (raw['arbmagEnable'] as int) != 0;
          if (arbmagReady && arbmagOn && !en) {
            _markSent(ParamId.arbmagEnable);
            send({'cmd': 'setParam', 'id': ParamId.arbmagEnable, 'value': 1, 'isFloat': false});
          } else if (!arbmagOn || arbmagReady) {
            arbmagOn = en;
          }
        }

        // P3: 全量回读补齐此前遗漏的 14 类参数（输入/增益/分带/混响/EQ/EEL2/链顺序等）
        if (raw['inputGain'] != null) inputGain = (raw['inputGain'] as num).toDouble();
        if (raw['inputBalanceL'] != null) inputBalanceL = (raw['inputBalanceL'] as num).toDouble();
        if (raw['inputBalanceR'] != null) inputBalanceR = (raw['inputBalanceR'] as num).toDouble();
        if (raw['tubeGain'] != null) tubeGain = (raw['tubeGain'] as num).toDouble();
        if (raw['stereoEnable'] != null) stereoOn = (raw['stereoEnable'] as int) != 0;
        if (raw['stereoBands'] is List) {
          final bands = (raw['stereoBands'] as List);
          for (var i = 0; i < bands.length && i < 5; i++) {
            stereoBands[i] = (bands[i] as num).toDouble();
          }
        }
        if (raw['fvRoomSize'] != null) fvRoomSize = (raw['fvRoomSize'] as num).toDouble();
        if (raw['fvWidth'] != null) fvWidth = (raw['fvWidth'] as num).toDouble();
        if (raw['eqBandsCount'] != null) eqBandsCount = raw['eqBandsCount'] as int;
        if (raw['eqFilter'] != null) eqFilter = raw['eqFilter'] as int;
        if (raw['eqInterp'] != null) eqInterp = raw['eqInterp'] as int;
        if (raw['eqQ'] != null) eqQ = (raw['eqQ'] as num).toDouble();
        if (raw['bassMode'] != null) bassMode = raw['bassMode'] as int;
        if (raw['bassIntensity'] != null) bassIntensity = (raw['bassIntensity'] as num).toDouble();
        if (raw['lpParams'] is List) {
          final lpp = (raw['lpParams'] as List);
          for (var i = 0; i < lpp.length && i < 8; i++) {
            lpParams[i] = (lpp[i] as num).toDouble();
          }
        }
        if (raw['chainOrder'] is String && (raw['chainOrder'] as String).isNotEmpty) {
          graphOrder = raw['chainOrder'] as String;
        }

        // P3: 全量同步至通用字典 _paramValues，保证 SSOT 与引擎状态绝对一致
        for (final spec in ParamRegistry.allParams) {
          _paramValues[spec.id] = spec.read(this);
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
// 设备被占是持续态（对端独占释放前不会好）：backoff 重起，
// 5 次约 10s 还起不来才认命留 fatal 屏。其它错误直接留屏。
        if (fatalMsg?.contains('0x8889000a') == true) {
          _scheduleFatalRetry();
        }
        break;
      case 'wasapiLost':
        // 运行中端点被独占（旧 client 在对端释放前永好不了）：只有还在进程内
        // 模式才重起；用户若已切走（桥模式），忽略（桥侧自有重建/状态）。
        if (audioMode != 'vbcallback' && audioMode != 'asio') {
          _fatalRetries = 0;
          _restartIsolate();
          notifyListeners();
        }
        break;
      case 'wasapiError':
        // 输出缺失但引擎正常：不清 fatal、不红屏，设备卡展示原因 + 重试。
        wasapiError = (raw['msg'] as String?) ?? 'output unavailable';
        notifyListeners();
        break;
      case 'state':
        engineState = raw['state'] as int;
        latencyMs = (raw['latencyMs'] as num).toDouble();
        notifyListeners();
        break;
      case 'playing':
        playing = raw['playing'] as bool;
        if (raw['srcCh'] is int) {
          fileChannels = (raw['srcCh'] as int).clamp(1, 8);
        }
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
        if (!TrayService.instance.isWindowVisible.value) break;
        spectrum.value = (raw['spectrum'] as List).cast<double>();
        if (raw['eqIn'] != null) {
          eqInSpectrum.value = (raw['eqIn'] as List).cast<double>();
        }
        levelL.value = (raw['l'] as num).toDouble();
        levelR.value = (raw['r'] as num).toDouble();
        if (raw['stageL'] != null) {
          final sL = (raw['stageL'] as List).cast<num>().map((e) => e.toDouble()).toList();
          stageLevelsL.value = sL;
          if (sL.length >= 30) {
            grLimiter.value = sL[24];
            grComp.value = sL[25];
            grGate.value = sL[26];
            grDyneqLow.value = sL[27];
            grDyneqMid.value = sL[28];
            grDyneqHigh.value = sL[29];
          }
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
      case 'vbstatus':
        final was = vbActive;
        vbActive = (raw['running'] as bool?) ?? false;
        vbInfo = Map<String, dynamic>.from(raw);
        if (vbActive && !was) {
          // VB 上升沿：清掉上一会话的残留帧，基线归零，活数据随后流入。
          spectrum.value = List<double>.filled(32, 0.0);
          eqInSpectrum.value = List<double>.filled(32, 0.0);
          levelL.value = -90.0;
          levelR.value = -90.0;
          grLimiter.value = 0.0;
          grComp.value = 0.0;
          grGate.value = 0.0;
          grDyneqLow.value = 0.0;
          grDyneqMid.value = 0.0;
          grDyneqHigh.value = 0.0;
          // 长度必须与声明一致（kEngineStageCount=12；此前误写 5，
          // _StageStereoMeter 按 0..18 索引，越界回退 -120 造成 LED 恒灭）。
          stageLevelsL.value = List<double>.filled(kEngineStageCount, -90.0);
          stageLevelsR.value = List<double>.filled(kEngineStageCount, -90.0);
        }
        notifyListeners();
        break;
      case 'asiostatus':
        final wasA = asioActive;
        asioActive = (raw['running'] as bool?) ?? false;
        asioInfo = Map<String, dynamic>.from(raw);
        if (asioActive && !wasA) {
          // ASIO 上升沿：同 VB——清残留帧，基线归零（长度同上，12）。
          spectrum.value = List<double>.filled(32, 0.0);
          eqInSpectrum.value = List<double>.filled(32, 0.0);
          levelL.value = -90.0;
          levelR.value = -90.0;
          grLimiter.value = 0.0;
          grComp.value = 0.0;
          grGate.value = 0.0;
          grDyneqLow.value = 0.0;
          grDyneqMid.value = 0.0;
          grDyneqHigh.value = 0.0;
          stageLevelsL.value = List<double>.filled(kEngineStageCount, -90.0);
          stageLevelsR.value = List<double>.filled(kEngineStageCount, -90.0);
        }
        // Phase 4：驱动请求重置（kAsioResetRequest，采样率/设备变化等）→
        // 复用热切换（stop→start 新参数；C++ 侧 start 时清标志，不会循环）。
        if (asioActive && (raw['resetPending'] as int? ?? 0) == 1) {
          _sendAsioRestart();
        }
        notifyListeners();
        break;
      case 'vaiostatus':
        final wasV = vaioActive;
        vaioActive = (raw['running'] as bool?) ?? false;
        vaioInfo = Map<String, dynamic>.from(raw);
        if (vaioActive && !wasV) {
          spectrum.value = List<double>.filled(32, 0.0);
          eqInSpectrum.value = List<double>.filled(32, 0.0);
          levelL.value = -90.0;
          levelR.value = -90.0;
          stageLevelsL.value = List<double>.filled(kEngineStageCount, -90.0);
          stageLevelsR.value = List<double>.filled(kEngineStageCount, -90.0);
        }
        notifyListeners();
        break;
      case 'vaiodetect':
        vaioDetectInfo = Map<String, dynamic>.from(raw);
        notifyListeners();
        break;
      case 'asiodrivers':
        // 驱动清单（isolate 内 asio_detect 的结果；桥缺失/无驱动时 note 有原因）。
        asioDrivers = [
          for (final d in (raw['drivers'] as List?) ?? [])
            Map<String, String>.from(d as Map),
        ];
        asioDriversNote = (raw['note'] as String?) ?? '';
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
      setInt(ParamId.tubeOversample, tubeOversample ? 1 : 0);
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
      setInt(ParamId.spatialEnable, spatialOn ? 1 : 0);
      setInt(ParamId.spatialStyle, spatialStyle);
      setFloat(ParamId.spatialRoom, spatialRoom);
      setFloat(ParamId.spatialWidth, spatialWidth);
      setFloat(ParamId.spatialCenter, spatialCenter);
      setFloat(ParamId.spatialOutGain, spatialOutGain);
      setInt(ParamId.spatialAutoGain, spatialAutoGain ? 1 : 0);
      setFloat(ParamId.spatialHeadAzim, spatialHeadAzim);
      setInt(ParamId.spatialHeadTrack, spatialHeadTrack ? 1 : 0);
      setInt(ParamId.exciterEnable, exciterOn ? 1 : 0);
      setFloat(ParamId.exciterAmount, exciterAmount);
      setFloat(ParamId.exciterHifreq, exciterHifreq);
      setInt(ParamId.exciterOversample, exciterOversample ? 1 : 0);
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
      setFloat(ParamId.gateHysteresis, gateHysteresis);
      setFloat(ParamId.gateRange, gateRange);
      setFloat(ParamId.gateHoldMs, gateHoldMs);
      setInt(ParamId.gateAutoGain, gateAutoGain ? 1 : 0);
      setInt(ParamId.deesserEnable, deesserOn ? 1 : 0);
      setFloat(ParamId.deesserFreq, deesserFreq);
      setFloat(ParamId.deesserAmount, deesserAmount);
      // 全参数动态EQ
      setInt(ParamId.dyneqEnable, dyneqOn ? 1 : 0);
      setFloat(ParamId.dyneqAttack, dyneqAttackMs);
      setFloat(ParamId.dyneqRelease, dyneqReleaseMs);
      setFloat(ParamId.dyneqB1Attack, dyneqB1Attack);
      setFloat(ParamId.dyneqB1Release, dyneqB1Release);
      setFloat(ParamId.dyneqB2Attack, dyneqB2Attack);
      setFloat(ParamId.dyneqB2Release, dyneqB2Release);
      setFloat(ParamId.dyneqB3Attack, dyneqB3Attack);
      setFloat(ParamId.dyneqB3Release, dyneqB3Release);
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
      setFloat(ParamId.limiterRelease, limiterReleaseMs);
      setFloat(ParamId.limiterThreshold, limiterThreshold);
      setInt(ParamId.limiterLink, limiterLink ? 1 : 0);
      setInt(ParamId.limiterLookahead, limiterLookahead ? 1 : 0);
      setFloat('post.gain', postGain);

      // 动态压限器
      setFloat(ParamId.compTimeconstant, compTimeconstant);
      setInt(ParamId.compGranularity, compGranularity);
      setInt(ParamId.compTfresolution, compTfresolution);
      for (var i = 0; i < 7; i++) {
        setFloat('comp.freq${i + 1}', compFreqs[i]);
        setFloat('comp.gain${i + 1}', compGains[i]);
      }
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
    _paramValues[id] = v;
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
        if (id == ParamId.shelfFreq) { shelfFreq = v.clamp(40.0, 400.0); break; }
        if (id == ParamId.shelfGain) { shelfGain = v; break; }
        if (id == ParamId.bassmonoEnable) { bassmonoOn = v != 0; break; }
        if (id == ParamId.bassmonoFreq) { bassmonoFreq = v; break; }
        if (id == ParamId.haasEnable) { haasOn = v != 0; break; }
        if (id == ParamId.haasDelay) { haasDelayMs = v; break; }
        if (id == ParamId.haasMix) { haasMix = v; break; }
        if (id == ParamId.haasSide) { haasSide = v != 0 ? 1 : 0; break; }
        if (id == ParamId.spatialEnable) { spatialOn = v != 0; break; }
        if (id == ParamId.spatialStyle) { spatialStyle = v.toInt().clamp(0, 2); break; }
        if (id == ParamId.spatialRoom) { spatialRoom = v; break; }
        if (id == ParamId.spatialWidth) { spatialWidth = v; break; }
        if (id == ParamId.spatialCenter) { spatialCenter = v; break; }
        if (id == ParamId.spatialOutGain) { spatialOutGain = v; break; }
        if (id == ParamId.spatialAutoGain) { spatialAutoGain = v != 0; break; }
        if (id == ParamId.spatialHeadAzim) { spatialHeadAzim = v; break; }
        if (id == ParamId.spatialHeadTrack) { spatialHeadTrack = v != 0; break; }
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
        if (id == ParamId.gateHysteresis) { gateHysteresis = v; break; }
        if (id == ParamId.gateRange) { gateRange = v; break; }
        if (id == ParamId.gateHoldMs) { gateHoldMs = v; break; }
        if (id == ParamId.exciterOversample) { exciterOversample = v != 0; break; }
        if (id == ParamId.tubeOversample) { tubeOversample = v != 0; break; }
        if (id == ParamId.limiterRelease) { limiterReleaseMs = v; break; }
        if (id == ParamId.limiterThreshold) { limiterThreshold = v; break; }
        if (id == ParamId.limiterLink) { limiterLink = v != 0; break; }
        if (id == ParamId.limiterLookahead) { limiterLookahead = v != 0; break; }
        if (id == ParamId.dyneqB1Attack) { dyneqB1Attack = v; break; }
        if (id == ParamId.dyneqB1Release) { dyneqB1Release = v; break; }
        if (id == ParamId.dyneqB2Attack) { dyneqB2Attack = v; break; }
        if (id == ParamId.dyneqB2Release) { dyneqB2Release = v; break; }
        if (id == ParamId.dyneqB3Attack) { dyneqB3Attack = v; break; }
        if (id == ParamId.dyneqB3Release) { dyneqB3Release = v; break; }
        if (id == ParamId.fvEnable) { fvOn = v != 0; break; }
        if (id == ParamId.fvDecay) { fvDecay = v; break; }
        if (id == ParamId.fvDamp) { fvDamp = v; break; }
        if (id == ParamId.fvWet) { fvWet = v; break; }
        if (id == ParamId.fvDry) { fvDry = v; break; }
        if (id == ParamId.compEnable) { compOn = v != 0; break; }
        if (id == ParamId.compTimeconstant) { compTimeconstant = v; break; }
        if (id == ParamId.compGranularity) { compGranularity = v.toInt(); break; }
        if (id == ParamId.compTfresolution) { compTfresolution = v.toInt(); break; }
        if (id.startsWith('comp.freq')) {
          final idx = int.tryParse(id.replaceFirst('comp.freq', ''));
          if (idx != null && idx >= 1 && idx <= 7) {
            compFreqs[idx - 1] = v;
            break;
          }
        }
        if (id.startsWith('comp.gain')) {
          final idx = int.tryParse(id.replaceFirst('comp.gain', ''));
          if (idx != null && idx >= 1 && idx <= 7) {
            compGains[idx - 1] = v;
            break;
          }
        }
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
    _markSent('stereo.enable');
    send({
      'cmd': 'setParam',
      'id': 'stereo.enable',
      'value': stereoOn ? 1 : 0,
      'isFloat': false,
    });
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

  /// 双击主滑块时重置立体声扩展并恢复 5 个子带为 0.5 中性（不关闭开关）
  void resetStereoWiden() {
    stereoMix = ParamDefaults.stereoMix;
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
    // chainOrder 在 snapshot/会话 schema 内，必须持久化，
    // 否则处理链重排重启即丢（此前唯一漏掉的大类用户动作）。
    scheduleAutoSave();
  }

  /// chain 行电平表映射：返回该 stage 在 AURADSP_STAGE_MAX (32) 中的固定槽位索引。
  /// 引擎 stagePeak 按效果 id 落槽，不跟 graph.order 走——重排后
  /// 灯位不动才是对的；跟实时 order 走反而会在重排后全错位。
  /// 0..11: vendor 12 stages
  /// 12: gate in (内部前测点)
  /// 13: gate stage out
  /// 14: dyneq stage out
  /// 15: filter stage out
  /// 16: bassmono stage out
  /// 17: haas stage out
  /// 18: exciter stage out
  /// 19: loudness stage out
  /// 20: spatial stage out（Phase 2 接入链页）
  /// 21..31: 预留/扩展插件槽
  int stageMeterIndex(String id) => switch (id) {
    'tube' => 0,
    'comp' => 1,
    'bass' => 2,
    'eq' => 3,
    'arbmag' => 4,
    'convolver' => 5,
    'ddc' => 6,
    'liveprog' => 7,
    'crossfeed' => 8,
    'stereo' => 9,
    'reverb' => 10,
    'output' => 11,
    'gate' => 13,
    'dyneq' => 14,
    'filter' => 15,
    'bassmono' => 16,
    'haas' => 17,
    'exciter' => 18,
    'loudness' => 19,
    'spatial' => 20,
    _ => -1,
  };

  /// 链组成员（Phase 2；与 chain_page.dart kChainGroups 同构，core 不得 import
  /// features，故此处镜像一份，改动时两边同步）。
  static const _chainGroupMembers = {
    'chInput': ['gate', 'filter'],
    'chTone': ['dyneq', 'bassmono', 'tube', 'comp', 'bass'],
    'chEq': ['eq', 'arbmag', 'convolver', 'ddc', 'liveprog'],
    'chSound': ['crossfeed', 'stereo', 'haas'],
    'chSpatial': ['spatial'],
    'chOut': ['exciter', 'reverb', 'loudness', 'output'],
  };

  /// 整组旁路/启用：把组内成员逐个拨到目标态（复用 toggleStage，含 reverb
  /// 特殊语义）。output（限幅器）常驻，跳过——整组旁路不得静音整机。
  void setChainGroup(String group, bool on) {
    final members = _chainGroupMembers[group];
    if (members == null) return;
    for (final id in members) {
      if (id == 'output') continue;
      if (isStageEnabled(id) != on) toggleStage(id);
    }
  }

  /// 获取某个处理链 stage 的启用状态
  bool isStageEnabled(String stageId) {
    return switch (stageId) {
      'tube' => tubeOn,
      'comp' => compOn,
      'bassmono' || 'shelf' || 'bass_shaping' => bassShapingOn,
      'gate' => gateOn,
      'dyneq' => dyneqOn,
      'filter' => filterOn,
      'loudness' => loudnessOn,
      'haas' => haasOn,
      'spatial' => spatialOn,
      'exciter' => exciterOn,
      'bass' => bassOn,
      'eq' => eqOn,
      'arbmag' => arbmagOn,
      'convolver' => convEnabled,
      'ddc' => ddcOn,
      'liveprog' => lpEnabled,
      'crossfeed' => xfeedOn,
      'stereo' => stereoOn,
      'reverb' => reverbPreset >= 0 ||
          // 自定义态 -2：fvOn 即开着，判关会让链视图与耳朵打架。
          (reverbPreset == -2 && fvOn),
      'output' => limiterOn,
      _ => false,
    };
  }

  /// 切换某个处理链 stage 的启用/旁路状态
  void toggleStage(String stageId) {
    switch (stageId) {
      case 'tube':
        setInt('tube.enable', tubeOn ? 0 : 1);
      case 'bass_shaping' || 'shelf' || 'bassmono':
        setBassShapingEnabled(!bassShapingOn);
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
      case 'spatial':
        setSpatialEnabled(!spatialOn);
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
          // -1→preset 0；-2→重申自定义（setSpatialReverbEnabled 内保护，
          // 直接 setReverbPreset(0) 会吃掉自定义参数）。
          setSpatialReverbEnabled(true);
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
    // Auto-bypass：即使无 IR 文件，也如实下发 enable 状态。
    // 底层引擎在 ir_ready=0 时自动内部直通 (Convolver1DDisable)，
    // 回读也能如实反映 convEnable=1，避免无文件开启后被回读冲刷关闭。
    send({
      'cmd': 'setParam',
      'id': ParamId.convEnable,
      'value': on ? 1 : 0,
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
    if (_measuredLatencyMs.containsKey('haas')) {
      _measuredLatencyMs['haas'] = haasDelayMs;
    }
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

  /// 空间音效 L1：总开关 + 风格（三预设即整组联动，引擎+界面同步覆盖）。
  void setSpatialEnabled(bool on) {
    spatialOn = on;
    setInt(ParamId.spatialEnable, on ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  void setSpatialStyle(int style) {
    spatialStyle = style.clamp(0, 2);
    // 与引擎 style 联动预设同值（set_param 侧同样会覆盖，Dart 先行保证 UI 即时）。
    if (spatialStyle == 0) {
      spatialRoom = 0.7;
      spatialWidth = 1.0;
      spatialCenter = 0.8;
    } else if (spatialStyle == 1) {
      spatialRoom = 0.25;
      spatialWidth = 1.1;
      spatialCenter = 0.5;
    } else {
      spatialRoom = 0.0;
      spatialWidth = 1.0;
      spatialCenter = 0.5;
    }
    setInt(ParamId.spatialStyle, spatialStyle);
    setFloat(ParamId.spatialRoom, spatialRoom);
    setFloat(ParamId.spatialWidth, spatialWidth);
    setFloat(ParamId.spatialCenter, spatialCenter);
    notifyListeners();
    scheduleAutoSave();
  }

  void setSpatialRoom(double v) {
    spatialRoom = v.clamp(0.0, 1.0);
    setFloat(ParamId.spatialRoom, spatialRoom);
    notifyListeners();
    scheduleAutoSave();
  }

  void setSpatialWidth(double v) {
    spatialWidth = v.clamp(0.5, 1.5);
    setFloat(ParamId.spatialWidth, spatialWidth);
    notifyListeners();
    scheduleAutoSave();
  }

  void setSpatialCenter(double v) {
    spatialCenter = v.clamp(0.0, 1.0);
    setFloat(ParamId.spatialCenter, spatialCenter);
    notifyListeners();
    scheduleAutoSave();
  }

  void setSpatialOutGain(double v) {
    spatialOutGain = v.clamp(-12.0, 6.0);
    setFloat(ParamId.spatialOutGain, spatialOutGain);
    notifyListeners();
    scheduleAutoSave();
  }

  void setSpatialAutoGain(bool on) {
    spatialAutoGain = on;
    setInt(ParamId.spatialAutoGain, on ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  /// 头跟 stub：仅存取透传（无 UI；传感器接入后由驱动层高频下发 azimuth）。
  void setSpatialHeadAzim(double v) {
    spatialHeadAzim = v.clamp(-180.0, 180.0);
    setFloat(ParamId.spatialHeadAzim, spatialHeadAzim);
    notifyListeners();
    scheduleAutoSave();
  }

  void setSpatialHeadTrack(bool on) {
    spatialHeadTrack = on;
    setInt(ParamId.spatialHeadTrack, on ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  /// 5.1 源模式切换（直通只在本地渲染 + raw 就绪 + 设备声道足够时生效，
  /// 否则自动回落混缩；桥注入试音恒走 fold，不受此开关影响）。
  void setSource51Mode(int mode) {
    source51Mode = mode.clamp(0, 1);
    send({'cmd': 'source51', 'value': source51Mode});
    notifyListeners();
    scheduleAutoSave();
  }

  /// 效果页分类切换（纯视图过滤，不动引擎；会话内有效）。
  void setEffectsCategory(String c) {
    effectsCategory = c;
    notifyListeners();
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
        setFloat('freeverb.roomsize', value);
      case 'width':
        fvWidth = value;
        setFloat('freeverb.width', value);
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

  void setCompThreshold(double v) {
    compThreshold = v;
    // 宏观阈值联动压缩强度：阈值越深(-dB)，压限系数越负
    final strength = ((-v) / 48.0).clamp(0.0, 1.0);
    for (var i = 0; i < 7; i++) {
      compGains[i] = (-strength * 0.9).clamp(-1.2, 1.2);
      setFloat('comp.gain${i + 1}', compGains[i]);
    }
    notifyListeners();
    scheduleAutoSave();
  }

  void setCompRatio(double v) {
    compRatio = v;
    notifyListeners();
    scheduleAutoSave();
  }

  void setCompFreq(int band, double freq) {
    if (band < 0 || band >= 7) return;
    compFreqs[band] = freq;
    setFloat('comp.freq${band + 1}', freq);
    notifyListeners();
    scheduleAutoSave();
  }

  void setCompGain(int band, double gain) {
    if (band < 0 || band >= 7) return;
    compGains[band] = gain;
    setFloat('comp.gain${band + 1}', gain);
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

  void setGateHysteresis(double v) {
    gateHysteresis = v.clamp(0.0, 12.0);
    setFloat(ParamId.gateHysteresis, gateHysteresis);
    notifyListeners();
  }

  void setGateRange(double v) {
    gateRange = v.clamp(-80.0, 0.0);
    setFloat(ParamId.gateRange, gateRange);
    notifyListeners();
  }

  void setGateHoldMs(double v) {
    gateHoldMs = v.clamp(0.0, 500.0);
    setFloat(ParamId.gateHoldMs, gateHoldMs);
    notifyListeners();
  }

  void setExciterOversample(bool on) {
    exciterOversample = on;
    setInt(ParamId.exciterOversample, on ? 1 : 0);
    notifyListeners();
  }

  void setTubeOversample(bool on) {
    tubeOversample = on;
    setInt(ParamId.tubeOversample, on ? 1 : 0);
    notifyListeners();
  }

  void setLimiterRelease(double v) {
    limiterReleaseMs = v.clamp(5.0, 500.0);
    setFloat(ParamId.limiterRelease, limiterReleaseMs);
    notifyListeners();
  }

  void setLimiterThreshold(double v) {
    limiterThreshold = v.clamp(-24.0, 0.0);
    setFloat(ParamId.limiterThreshold, limiterThreshold);
    notifyListeners();
  }

  void setLimiterLink(bool on) {
    limiterLink = on;
    setInt(ParamId.limiterLink, on ? 1 : 0);
    notifyListeners();
  }

  void setLimiterLookahead(bool on) {
    limiterLookahead = on;
    setInt(ParamId.limiterLookahead, on ? 1 : 0);
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
    dyneqB1Attack = dyneqAttackMs;
    dyneqB2Attack = dyneqAttackMs;
    dyneqB3Attack = dyneqAttackMs;
    setFloat(ParamId.dyneqAttack, dyneqAttackMs);
    notifyListeners();
  }

  void setDyneqRelease(double v) {
    dyneqReleaseMs = v.clamp(10.0, 1000.0);
    dyneqB1Release = dyneqReleaseMs;
    dyneqB2Release = dyneqReleaseMs;
    dyneqB3Release = dyneqReleaseMs;
    setFloat(ParamId.dyneqRelease, dyneqReleaseMs);
    notifyListeners();
  }

  void setDyneqB1Attack(double v) {
    dyneqB1Attack = v.clamp(0.1, 100.0);
    setFloat(ParamId.dyneqB1Attack, dyneqB1Attack);
    notifyListeners();
  }
  void setDyneqB1Release(double v) {
    dyneqB1Release = v.clamp(10.0, 1000.0);
    setFloat(ParamId.dyneqB1Release, dyneqB1Release);
    notifyListeners();
  }
  void setDyneqB2Attack(double v) {
    dyneqB2Attack = v.clamp(0.1, 100.0);
    setFloat(ParamId.dyneqB2Attack, dyneqB2Attack);
    notifyListeners();
  }
  void setDyneqB2Release(double v) {
    dyneqB2Release = v.clamp(10.0, 1000.0);
    setFloat(ParamId.dyneqB2Release, dyneqB2Release);
    notifyListeners();
  }
  void setDyneqB3Attack(double v) {
    dyneqB3Attack = v.clamp(0.1, 100.0);
    setFloat(ParamId.dyneqB3Attack, dyneqB3Attack);
    notifyListeners();
  }
  void setDyneqB3Release(double v) {
    dyneqB3Release = v.clamp(10.0, 1000.0);
    setFloat(ParamId.dyneqB3Release, dyneqB3Release);
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

  /* ---- 低音塑形（Bass Shaping：合并低频搁架与单声道化） ---- */

  void setBassShapingEnabled(bool on) {
    shelfOn = on;
    bassmonoOn = on;
    setInt(ParamId.shelfEnable, on ? 1 : 0);
    setInt(ParamId.bassmonoEnable, on ? 1 : 0);
    notifyListeners();
    scheduleAutoSave();
  }

  /* ---- 低频搁架（M5-b，自研 RBJ low-shelf；此前有引擎/回放无 UI） ---- */

  void setShelfEnabled(bool on) {
    shelfOn = on;
    setInt(ParamId.shelfEnable, on ? 1 : 0);
    notifyListeners();
  }

  void setShelfFreq(double f) {
    shelfFreq = f.clamp(40.0, 400.0);
    setFloat(ParamId.shelfFreq, shelfFreq);
    notifyListeners();
  }

  void setShelfGain(double db) {
    shelfGain = db.clamp(-15.0, 15.0);
    setFloat(ParamId.shelfGain, shelfGain);
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
/// 进程内模式：重启 isolate（spawn 路径按新采样率建链，就绪后走标准 session
/// 回放：参数/脚本/IR/插件/音源/bypass 全回来，约 1 秒静音间隙）。
/// 桥模式跟对端走：仅落盘（回进程内/下次启动生效），设置页有 hint 明示。
bool _pendingRestartPush = false; // isolate 重启后就绪时重推音源/bypass
void setSampleRate(int rate) {
  if (rate == config.sampleRate) return;
  config.sampleRate = rate;
  ConfigManager.save(config);
  _rebuildEqGridForSampleRate();
  if (audioMode == 'vbcallback' || audioMode == 'asio') {
    notifyListeners();
    return;
  }
  _pendingRestartPush = true;
  _restartIsolate();
  notifyListeners();
}

/// WASAPI 输出重试（降级态用户手动触发）：本质是重启 isolate 再协商一次。
void retryWasapi() {
  wasapiError = '';
  _fatalRetries = 0;
  _restartIsolate();
  notifyListeners();
}

/// isolate 重启（采样率等 spawn 期配置变更用）：关旧端口、杀旧实例、重起。
/// 就绪后标准回放 + _pendingRestartPush 重推音源/bypass。
void _restartIsolate() {
  try {
    _fromIso?.close();
  } catch (_) {}
  _fromIso = null;
  _toIso = null;
  try {
    _iso?.kill(priority: Isolate.immediate);
  } catch (_) {}
  _iso = null;
  conn = EngineConn.connecting;
  playing = false; // 就绪前不画频谱；重推音源后由 setSource 恢复
  _spawn();
}

// fatal-backoff 重试计数（'ready' 到达即清零；只对设备失效用）。
int _fatalRetries = 0;

/// fatal 屏退避重启：对端独占释放前重起多少次都没用，但 VB 侧切设备/重启引擎
/// 会顺手释放，2s 间隔探 5 次能覆盖大多数窗口；10s 还不行就留屏（用户改对端）。
void _scheduleFatalRetry() {
  if (_fatalRetries >= 5) return;
  _fatalRetries++;
  Future.delayed(const Duration(seconds: 2), () {
    if (conn != EngineConn.ready &&
        audioMode != 'vbcallback' &&
        audioMode != 'asio') {
      _restartIsolate();
      notifyListeners();
    }
  });
}

/// 音频处理模式切换：非法 id 直接忽略；合法即落盘 + 通知。
/// vbcallback/asio 切入/切出时联动 isolate 启停对应桥（WASAPI 路径随之
/// 暂停/恢复）；其余模式当前仅持久化选择（引擎接线待后续版本，重启生效）。
void setAudioMode(String id) {
  final valid = AudioModes.normalize(id);
  config.modeCategory = AudioModes.categoryForMode(valid);
  if (config.modeCategory == AudioModes.categoryAttachment) {
    config.attachmentMode = (valid == 'vbcallback')
        ? AudioModes.attachVoicemeeterApi
        : AudioModes.attachSysApo;
  } else {
    config.pipelineOutput = (valid == 'asio')
        ? AudioModes.outputAsioClient
        : (valid == 'vaio' ? AudioModes.outputVaio : AudioModes.outputWasapi);
  }
  if (valid == audioMode && config.audioMode == valid) return;
  final wasVb = audioMode == 'vbcallback';
  final isVb = valid == 'vbcallback';
  final wasAsio = audioMode == 'asio';
  final isAsio = valid == 'asio';
  final wasVaio = audioMode == 'vaio';
  final isVaio = valid == 'vaio';
  audioMode = valid;
  config.audioMode = valid;
  ConfigManager.save(config);
  if (wasVb != isVb) {
    // 进桥先推掩码（isolate 记 session 变量，start 时同步进桥；桥未起时仅记录）。
    if (isVb) _toIso?.send({'cmd': 'setBusMask', 'mask': vbBusMask});
    _toIso?.send({'cmd': 'vbmode', 'on': isVb});
    if (!isVb) {
      vbActive = false;
      vbInfo = {};
    }
  }
  if (wasAsio != isAsio) {
    // asiomode 内部自带 detect（无论能否启动都回 asiodrivers 事件给设置页）。
    _toIso?.send({
      'cmd': 'asiomode',
      'on': isAsio,
      'driver': config.asioDriver,
      'bufSize': config.asioBufSize,
      'outPair': config.asioOutPair,
    });
    if (!isAsio) {
      asioActive = false;
      asioInfo = {};
    }
  }
  if (wasVaio != isVaio) {
    _toIso?.send({
      'cmd': 'vaiomode',
      'on': isVaio,
      'outputEndpoint': config.vaioOutputEndpoint,
    });
    if (!isVaio) {
      vaioActive = false;
      vaioInfo = {};
    }
  }
  notifyListeners();
}

/// ADR-009: 切换音频范式（附加模式 vs 普通管线模式）
void setModeCategory(String category) {
  if (category != AudioModes.categoryAttachment &&
      category != AudioModes.categoryPipeline) {
    return;
  }
  config.modeCategory = category;
  final composed = AudioModes.composeMode(
    category: category,
    attachmentMode: config.attachmentMode,
    pipelineOut: config.pipelineOutput,
  );
  if (composed != audioMode) {
    setAudioMode(composed);
  } else {
    ConfigManager.save(config);
    notifyListeners();
  }
}

/// ADR-009: 切换附加模式子类型（System APO vs Voicemeeter API）
void setAttachmentMode(String mode) {
  config.attachmentMode = mode;
  if (modeCategory == AudioModes.categoryAttachment) {
    final composed = AudioModes.composeMode(
      category: AudioModes.categoryAttachment,
      attachmentMode: mode,
    );
    if (composed != audioMode) {
      setAudioMode(composed);
    } else {
      ConfigManager.save(config);
      notifyListeners();
    }
  } else {
    ConfigManager.save(config);
    notifyListeners();
  }
}

/// ADR-009: 切换管线输入源（Virtual ASIO / AuraVAIO / WASAPI）
void setPipelineInput(String inType) {
  config.pipelineInput = inType;
  ConfigManager.save(config);
  notifyListeners();
}

/// ADR-009: 切换管线输出端（WASAPI Render / AuraVAIO / ASIO Client）
void setPipelineOutput(String outType) {
  config.pipelineOutput = outType;
  if (modeCategory == AudioModes.categoryPipeline) {
    final composed = AudioModes.composeMode(
      category: AudioModes.categoryPipeline,
      pipelineOut: outType,
    );
    if (composed != audioMode) {
      setAudioMode(composed);
    } else {
      ConfigManager.save(config);
      notifyListeners();
    }
  } else {
    ConfigManager.save(config);
    notifyListeners();
  }
}

void setPipelineInputDevice(String device) {
  config.pipelineInputDevice = device;
  ConfigManager.save(config);
  notifyListeners();
}

void setPipelineOutputDevice(String device) {
  config.pipelineOutputDevice = device;
  ConfigManager.save(config);
  notifyListeners();
}

void setPipelineInputEnabled(bool enabled) {
  config.pipelineInputEnabled = enabled;
  ConfigManager.save(config);
  notifyListeners();
}

void setPipelineOutputEnabled(bool enabled) {
  config.pipelineOutputEnabled = enabled;
  ConfigManager.save(config);
  notifyListeners();
}

/// 刷新所有 WASAPI 端点与音频设备
Future<void> refreshAudioDevices() async {
  refreshVaioDetect();
  if (_testing || !Platform.isWindows) return;
  try {
    final exe = _findApoInspectExe();
    if (exe != null && exe.existsSync()) {
      final res = await Process.run(exe.path, [], stdoutEncoding: utf8);
      if (res.exitCode == 0) {
        final stdout = (res.stdout as String).trim();
        final lines = stdout.split('\n');
        final lastLine = lines.isNotEmpty ? lines.last.trim() : '';
        if (lastLine.isNotEmpty) {
          final json = jsonDecode(lastLine) as Map<String, dynamic>;
          final eps = (json['endpoints'] as List?) ?? [];
          final items = <AudioDeviceItem>[];
          for (final ep in eps) {
            if (ep is Map) {
              final name = (ep['name'] as String?) ?? '';
              final dir = (ep['direction'] as String?) ?? 'render';
              final id = (ep['id'] as String?) ?? '';
              final state = (ep['state'] as num?)?.toInt() ?? 1;
              if (name.isNotEmpty && state == 1) {
                items.add(AudioDeviceItem(
                  id: id,
                  name: name,
                  isRender: dir == 'render',
                  active: true,
                ));
              }
            }
          }
          if (items.isNotEmpty) {
            wasapiDevices = items;
            lastAudioError = null;
            notifyListeners();
          }
        }
      } else {
        lastAudioError = '端点探测工具退出异常 (代码: ${res.exitCode})';
        notifyListeners();
      }
    }
  } catch (e) {
    lastAudioError = '刷新音频设备失败: $e';
    notifyListeners();
  }
}

File? _findApoInspectExe() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    final candidate = File('${dir.path}/core/desktop/windows-drivers/out/Release/apo_inspect.exe');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

File? _findVaioInstallScript() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    final candidate = File(
        '${dir.path}/core/desktop/windows-drivers/01_vaio_driver/install_driver.ps1');
    if (candidate.existsSync()) return candidate;
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

/// 一键 UAC 提权安装 AuraVAIO 虚拟声卡驱动
Future<bool> installVaioDriver({bool elevated = true}) async {
  if (!Platform.isWindows) return false;
  try {
    final script = _findVaioInstallScript();
    if (script == null) {
      lastVaioError = '未找到 install_driver.ps1 安装脚本';
      notifyListeners();
      return false;
    }
    ProcessResult res;
    if (elevated) {
      // 通过 PowerShell Start-Process -Verb RunAs 唤起 Windows UAC 管理员提权确认框
      final cmd =
          'Start-Process powershell -Verb RunAs -Wait -ArgumentList \'-ExecutionPolicy\', \'Bypass\', \'-File\', \'"${script.path}"\', \'-Action\', \'install\', \'-Config\', \'Release\'';
      res = await Process.run('powershell', ['-Command', cmd]);
    } else {
      res = await Process.run('powershell', [
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Action',
        'install',
        '-Config',
        'Release',
      ]);
    }
    refreshVaioDetect();
    await refreshAudioDevices();
    final ok = res.exitCode == 0;
    if (!ok) {
      lastVaioError = 'AuraVAIO 安装未完成 (退出码: ${res.exitCode})，请在 UAC 弹窗中选择允许提权';
    } else {
      lastVaioError = null;
    }
    notifyListeners();
    return ok;
  } catch (e) {
    lastVaioError = '安装驱动异常: $e';
    notifyListeners();
    return false;
  }
}

/// 一键 UAC 提权卸载 AuraVAIO 虚拟声卡驱动
Future<bool> uninstallVaioDriver({bool elevated = true}) async {
  if (!Platform.isWindows) return false;
  try {
    final script = _findVaioInstallScript();
    if (script == null) return false;
    ProcessResult res;
    if (elevated) {
      final cmd =
          'Start-Process powershell -Verb RunAs -Wait -ArgumentList \'-ExecutionPolicy\', \'Bypass\', \'-File\', \'"${script.path}"\', \'-Action\', \'uninstall\', \'-RemoveTestCert\'';
      res = await Process.run('powershell', ['-Command', cmd]);
    } else {
      res = await Process.run('powershell', [
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        script.path,
        '-Action',
        'uninstall',
        '-RemoveTestCert',
      ]);
    }
    refreshVaioDetect();
    await refreshAudioDevices();
    final ok = res.exitCode == 0;
    if (ok) lastVaioError = null;
    notifyListeners();
    return ok;
  } catch (e) {
    lastVaioError = '卸载异常: $e';
    notifyListeners();
    return false;
  }
}

void setApoTargetEndpoint(String endpoint) {
  config.apoTargetEndpoint = endpoint;
  ConfigManager.save(config);
  notifyListeners();
}

void setMonitorMirroring(bool enabled) {
  config.monitorMirroring = enabled;
  ConfigManager.save(config);
  notifyListeners();
}

void setApoAttached(bool attached) {
  apoAttached = attached;
  notifyListeners();
}

/// 检查 AuraDSP Virtual ASIO 驱动在 Windows 系统的注册状态
Future<void> checkAsioDriverStatus() async {
  if (!Platform.isWindows) {
    asioDriverInstalled = false;
    notifyListeners();
    return;
  }
  try {
    final res = await Process.run('reg.exe', ['query', r'HKLM\SOFTWARE\ASIO\AuraDSP Driver']);
    asioDriverInstalled = (res.exitCode == 0);
  } catch (_) {
    asioDriverInstalled = false;
  }
  notifyListeners();
}

/// 一键注册 AuraDSP 虚拟 ASIO 驱动到系统（支持 Windows UAC 提权授权）
Future<bool> registerAsioDriver({bool elevated = true}) async {
  if (!Platform.isWindows) return false;
  try {
    final script = _findAsioRegisterScript();
    if (script != null) {
      ProcessResult res;
      if (elevated) {
        // 唤起 Windows UAC 提权对话框执行注册
        final cmd =
            'Start-Process powershell -Verb RunAs -Wait -ArgumentList \'-ExecutionPolicy\', \'Bypass\', \'-File\', \'"${script.path}"\', \'-Action\', \'register\'';
        res = await Process.run('powershell', ['-Command', cmd]);
      } else {
        res = await Process.run('powershell', [
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-Action',
          'register'
        ]);
      }
      await checkAsioDriverStatus();
      final ok = res.exitCode == 0 && asioDriverInstalled;
      if (!ok) {
        lastAsioError = 'ASIO 驱动注册未完成，请确认在 UAC 提权弹窗中选择“是”以授予管理员权限';
      } else {
        lastAsioError = null;
      }
      notifyListeners();
      return ok;
    }
  } catch (e) {
    lastAsioError = 'ASIO 驱动注册异常: $e';
    notifyListeners();
  }
  return false;
}

/// 一键反注册 AuraDSP 虚拟 ASIO 驱动（支持 Windows UAC 提权授权）
Future<bool> unregisterAsioDriver({bool elevated = true}) async {
  if (!Platform.isWindows) return false;
  try {
    final script = _findAsioRegisterScript();
    if (script != null) {
      ProcessResult res;
      if (elevated) {
        final cmd =
            'Start-Process powershell -Verb RunAs -Wait -ArgumentList \'-ExecutionPolicy\', \'Bypass\', \'-File\', \'"${script.path}"\', \'-Action\', \'unregister\'';
        res = await Process.run('powershell', ['-Command', cmd]);
      } else {
        res = await Process.run('powershell', [
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script.path,
          '-Action',
          'unregister'
        ]);
      }
      await checkAsioDriverStatus();
      final ok = res.exitCode == 0 && !asioDriverInstalled;
      if (!ok) {
        lastAsioError = 'ASIO 驱动注销未完成';
      } else {
        lastAsioError = null;
      }
      notifyListeners();
      return ok;
    }
  } catch (e) {
    lastAsioError = 'ASIO 驱动注销异常: $e';
    notifyListeners();
  }
  return false;
}

File? _findAsioRegisterScript() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    final candidates = [
      File('${dir.path}/core/desktop/windows-drivers/04_asio_driver/register_driver.ps1'),
      File('${dir.path}/scripts/register_driver.ps1'),
      File('${dir.path}/register_driver.ps1'),
      File('${dir.path}/../scripts/register_driver.ps1'),
    ];
    for (final c in candidates) {
      if (c.existsSync()) return c;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

File? _findApoConfigScript() {
  var dir = Directory.current;
  for (var i = 0; i < 4; i++) {
    final candidates = [
      File('${dir.path}/core/desktop/windows-drivers/03_system_apo/apo_config.py'),
      File('${dir.path}/scripts/apo_config.py'),
      File('${dir.path}/apo_config.py'),
      File('${dir.path}/../scripts/apo_config.py'),
    ];
    for (final c in candidates) {
      if (c.existsSync()) return c;
    }
    final parent = dir.parent;
    if (parent.path == dir.path) break;
    dir = parent;
  }
  return null;
}

void setApoCompositeMode(bool enabled) {
  apoCompositeMode = enabled;
  notifyListeners();
}

/// 检查 System APO 在系统注册与端点挂载状态，并检测心跳
Future<void> checkApoStatus({double timeout = 0.4}) async {
  if (!Platform.isWindows) {
    apoAttached = false;
    apoHeartbeatAlive = false;
    notifyListeners();
    return;
  }
  try {
    final script = _findApoConfigScript();
    if (script != null) {
      final res = await Process.run('python', [
        script.path,
        'status',
        '--timeout',
        timeout.toString(),
        '--json',
      ]);
      if (res.exitCode == 0) {
        final out = res.stdout.toString().trim();
        final lines = out.split(RegExp(r'\r?\n')).where((l) => l.trim().startsWith('{')).toList();
        if (lines.isNotEmpty) {
          final data = jsonDecode(lines.last) as Map<String, dynamic>;
          final rawInstalled = data['installed_endpoints'] as List?;
          final installed = rawInstalled != null
              ? rawInstalled.map((e) => Map<String, dynamic>.from(e as Map)).toList()
              : <Map<String, dynamic>>[];
          apoInstalledEndpoints = installed;

          final target = config.apoTargetEndpoint;
          if (target.isEmpty) {
            apoAttached = installed.isNotEmpty;
          } else {
            apoAttached = installed.any((e) {
              final short = e['short_guid']?.toString().toLowerCase() ?? '';
              final name = e['DeviceName']?.toString().toLowerCase() ?? '';
              final id = e['EndpointId']?.toString().toLowerCase() ?? '';
              final t = target.toLowerCase();
              return short.contains(t) || name.contains(t) || id.contains(t) || t.contains(short);
            });
          }

          final hb = data['heartbeat'] as Map<String, dynamic>?;
          if (hb != null && hb['alive'] == true) {
            apoHeartbeatAlive = true;
            apoHeartbeatSeq = (hb['seq'] as num?)?.toInt() ?? 0;
            apoHeartbeatSr = (hb['sr'] as num?)?.toInt() ?? 0;
            apoHeartbeatFrames = (hb['frames'] as num?)?.toInt() ?? 0;
          } else {
            apoHeartbeatAlive = false;
          }
          lastApoError = null;
          notifyListeners();
          return;
        }
      }
    }
  } catch (e) {
    // 保持安静回退
  }
  notifyListeners();
}

/// 一键将 System APO 挂载到指定音频端点（支持 Windows UAC 提权授权，支持复合插槽）
Future<bool> attachSystemApo({
  String? endpointNameOrId,
  bool? composite,
  bool elevated = true,
}) async {
  if (!Platform.isWindows) return false;
  isApoOperating = true;
  lastApoError = null;
  notifyListeners();

  try {
    final script = _findApoConfigScript();
    if (script == null) {
      lastApoError = '未找到 apo_config.py 驱动管理脚本';
      isApoOperating = false;
      notifyListeners();
      return false;
    }

    final target = (endpointNameOrId != null && endpointNameOrId.isNotEmpty)
        ? endpointNameOrId
        : config.apoTargetEndpoint;
    if (target.isEmpty) {
      lastApoError = '请先选择需要附加的音频端点';
      isApoOperating = false;
      notifyListeners();
      return false;
    }

    final useComposite = composite ?? apoCompositeMode;
    ProcessResult res;
    if (elevated) {
      final modeArg = useComposite ? ", '--composite'" : "";
      final cmd =
          "Start-Process python -Verb RunAs -Wait -ArgumentList '\"${script.path}\"', 'install', '\"$target\"', '--yes', '--force'$modeArg";
      res = await Process.run('powershell', ['-Command', cmd]);
    } else {
      final args = [
        script.path,
        'install',
        target,
        '--yes',
        '--force',
        if (useComposite) '--composite',
        '--json',
      ];
      res = await Process.run('python', args);
    }

    await Future.delayed(const Duration(milliseconds: 600));
    await checkApoStatus(timeout: 0.6);

    final ok = (res.exitCode == 0) && apoAttached;
    if (!ok && lastApoError == null) {
      lastApoError = 'System APO 附加未生效，请确认在 UAC 提权弹窗中选择“是”以授予管理员权限';
    }
    isApoOperating = false;
    notifyListeners();
    return ok;
  } catch (e) {
    lastApoError = 'System APO 附加异常: $e';
    isApoOperating = false;
    notifyListeners();
    return false;
  }
}

/// 一键卸载已挂载的 System APO 并精确还原原始系统/厂商 APO
Future<bool> detachSystemApo({
  String? endpointNameOrId,
  bool elevated = true,
}) async {
  if (!Platform.isWindows) return false;
  isApoOperating = true;
  lastApoError = null;
  notifyListeners();

  try {
    final script = _findApoConfigScript();
    if (script == null) {
      lastApoError = '未找到 apo_config.py 驱动管理脚本';
      isApoOperating = false;
      notifyListeners();
      return false;
    }

    final target = (endpointNameOrId != null && endpointNameOrId.isNotEmpty)
        ? endpointNameOrId
        : config.apoTargetEndpoint;
    ProcessResult res;
    if (elevated) {
      final targetArg = target.isNotEmpty ? ", '\"$target\"'" : "";
      final cmd =
          "Start-Process python -Verb RunAs -Wait -ArgumentList '\"${script.path}\"', 'uninstall'$targetArg, '--yes'";
      res = await Process.run('powershell', ['-Command', cmd]);
    } else {
      final args = [
        script.path,
        'uninstall',
        if (target.isNotEmpty) target,
        '--yes',
        '--json',
      ];
      res = await Process.run('python', args);
    }

    await Future.delayed(const Duration(milliseconds: 600));
    await checkApoStatus(timeout: 0.6);

    final ok = (res.exitCode == 0);
    if (!ok && lastApoError == null) {
      lastApoError = 'System APO 卸载未完成，请确认在 UAC 提权弹窗中选择“是”';
    }
    isApoOperating = false;
    notifyListeners();
    return ok;
  } catch (e) {
    lastApoError = 'System APO 卸载异常: $e';
    isApoOperating = false;
    notifyListeners();
    return false;
  }
}

/// VB 总线开关：落盘 + 通知；桥在跑则即时下发（mask 活在 ctx，CHANGE 重建不丢）。
void setVbBus(int group, bool on) {
  if (group < 0 || group > 7) return;
  final next = on ? (vbBusMask | (1 << group)) : (vbBusMask & ~(1 << group));
  if (next == vbBusMask) return;
  vbBusMask = next & 0xFF;
  config.vbBusMask = vbBusMask;
  ConfigManager.save(config);
  _toIso?.send({'cmd': 'setBusMask', 'mask': vbBusMask});
  notifyListeners();
}

/// ASIO 驱动重选：落盘 + 通知；桥在跑则热切换（stop→start 新参数）。
void setAsioDriver(String name) {
  if (config.asioDriver == name) return;
  config.asioDriver = name;
  ConfigManager.save(config);
  if (asioActive) _sendAsioRestart();
  notifyListeners();
}

/// ASIO 缓冲档：0=驱动 preferredSize；桥在跑则热切换。
void setAsioBufSize(int frames) {
  if (config.asioBufSize == frames) return;
  config.asioBufSize = frames;
  ConfigManager.save(config);
  if (asioActive) _sendAsioRestart();
  notifyListeners();
}

/// ASIO 输出对起始声道（L=R+1 配对）；桥在跑则热切换。
void setAsioOutPair(int ch) {
  if (config.asioOutPair == ch) return;
  config.asioOutPair = ch;
  ConfigManager.save(config);
  if (asioActive) _sendAsioRestart();
  notifyListeners();
}

/// 触发一次 ASIO 驱动清单刷新（设置页进入/下拉点开时调）。
void refreshAsioDrivers() {
  _toIso?.send({'cmd': 'asiodetect'});
}

/// AuraVAIO 物理输出端点重选：落盘 + 通知；桥在跑则热切换。
void setVaioOutputEndpoint(String endpoint) {
  if (config.vaioOutputEndpoint == endpoint) return;
  config.vaioOutputEndpoint = endpoint;
  ConfigManager.save(config);
  if (vaioActive) {
    _toIso?.send({
      'cmd': 'vaiorestart',
      'outputEndpoint': config.vaioOutputEndpoint,
    });
  }
  notifyListeners();
}

/// 触发一次 AuraVAIO 驱动与端点探测。
void refreshVaioDetect() {
  _toIso?.send({'cmd': 'vaiodetect'});
}

void _sendAsioRestart() {
  _toIso?.send({
    'cmd': 'asiorestart',
    'driver': config.asioDriver,
    'bufSize': config.asioBufSize,
    'outPair': config.asioOutPair,
  });
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

  /// 该组件当前可显示的延迟，带**来源**三态。
  ///
  /// - [measured]  = true：来自真实脉冲响应实测（引擎 auradsp_probe_component）。
  /// - [estimated] = true：来自标称表/解析推算，**不是**测出来的。UI 必须以
  ///   「≈」前缀 + 差异化配色展示，不能与实测混为一谈——旧实现把这两类都塞进
  ///   `measured:false`，徽标于是显示「未测量」，把已知的估算值白白丢掉。
  /// - 两者皆 false：真的没有可用数值，UI 显示「未测量」。
  ///
  /// 标称值必须与引擎 `compute_latency`（engine/chain/engine_chain.cpp 顶部
  /// 的 kLat* 表）保持一致，否则卡片读数与总延迟口径会互相矛盾。
  ({double ms, bool measured, bool estimated}) componentLatency(String compId) {
    final m = _measuredLatencyMs[compId];
    if (m != null) return (ms: m, measured: true, estimated: false);
    // 解析兜底：只有 convolver 能从已知的 IR 长度算出真正的附加延迟
    if (compId == 'convolver' && convEnabled && convReady &&
        convFrames > 0 && deviceRate > 0) {
      return (ms: (convFrames / deviceRate) * 1000.0, measured: false, estimated: true);
    }
    if (compId == 'comp' && compOn) {
      return (ms: 85.0, measured: false, estimated: true);
    }
    // Haas = 纯延迟线，按当前设定值标称（引擎 compute_latency 同值动态上报）。
    if (compId == 'haas' && haasOn) {
      return (ms: haasDelayMs, measured: false, estimated: true);
    }
    // 空间音效 = 直达径 ITD 名义 1ms（kLatSpatial；反射/混响尾是并行能量不计入）。
    // 探针结构性失明（亚毫秒直达 + 并行反射），与 haas 同 posture：只标称不测。
    if (compId == 'spatial' && spatialOn) {
      return (ms: 1.0, measured: false, estimated: true);
    }
    if (compId == 'arbmag' && arbmagOn && arbmagReady) {
      return (ms: 2.67, measured: false, estimated: true);
    }
    // VDC：二阶节链按样本处理，标称 6ms（kLatDdc）。已加载时优先等实测。
    if (compId == 'ddc' && ddcOn && ddcReady) {
      return (ms: 6.0, measured: false, estimated: true);
    }
    if (compId == 'bass_shaping' && bassShapingOn) {
      return (ms: 0.0, measured: false, estimated: true);
    }
    return (ms: 0.0, measured: false, estimated: false);
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
    if (compId == 'haas') {
      _probing.add('haas');
      _latencyRefreshTicks['haas'] = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
      Future.delayed(const Duration(milliseconds: 120), () {
        _probing.remove('haas');
        _measuredLatencyMs['haas'] = haasDelayMs;
        notifyListeners();
      });
      return;
    }
    if (compId == 'bass_shaping') {
      _probing.add('bass_shaping');
      _latencyRefreshTicks['bass_shaping'] = DateTime.now().millisecondsSinceEpoch;
      notifyListeners();
      Future.delayed(const Duration(milliseconds: 100), () {
        _probing.remove('bass_shaping');
        _measuredLatencyMs['bass_shaping'] = 0.0;
        notifyListeners();
      });
      return;
    }
    _probing.add(compId);
    _latencyRefreshTicks[compId] = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();

    final res = latencyProbeResource(compId) ?? '';
    final rate = info?.deviceRate.toDouble() ?? 48000.0;
    final enginePath = AuraDspLib.loadedPath;

    try {
      final result = await Isolate.run(() {
        final l = AuraDspLib.load(enginePath);
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

  /// 该组件是否支持实测。
  ///
  /// 必须与引擎 `probe_is_supported`（engine/chain/engine_probe.cpp）保持一致。
  /// 历史坑：这个集合**定义了却从未被任何 UI 使用**，于是 ↻ 按钮对所有 20 张
  /// 卡片无条件显示，而引擎只认其中一部分——用户点一下必然得到「未测量」，
  /// 还附带一次约 341ms 窗口的无效测量。现在卡片侧用它来决定是否给 ↻。
  ///
  /// convolver / ddc 需外部资源（IR / VDC），资源已加载时同样可测；
  /// 未加载时探针返回 -1，UI 走标称估算而不是假装能测。
  /// input 不是效果器（无延迟可测）；haas 探针结构性失明（见引擎注释）。
  static bool isLatencyProbeSupported(String compId) =>
      const {
        'bass', 'reverb', 'eq', 'tube', 'crossfeed', 'limiter', 'post', 'shelf',
        'convolver', 'ddc', 'bassmono', 'exciter', 'stereo', 'comp', 'arbmag',
        'dyneq', 'filter', 'gate', 'loudness', 'haas', 'bass_shaping',
      }.contains(compId);

  /// 探测进行中
  bool isProbingLatency(String compId) => _probing.contains(compId);

  void setSource(String kind, {String? path}) {
    sourceKind = kind == 'stop' ? '' : kind;
    sourcePath = (kind == 'file' && path != null) ? path : '';
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
    if (ok) {
      activePresetName = name;
      // 保存即锚定（决策 #3）：当前状态 = 该预设内容，脏标记归零。
      appliedPresetFingerprint = PresetLibrary.fingerprintOf(this);
      presetDirty = false;
    }
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
    // 「恢复默认」必须连带清除会话记忆：否则 autoRestoreSession 开启时
    // 下次启动 restoreMemoryImage 把旧参数全部还原（用户心智：全部归零）。
    // 先取消挂起的防抖保存——否则 500ms 后的 timer 会把文件写回来。
    _debounceSaveTimer?.cancel();
    SessionMemory.clear();
    notifyListeners();
  }

  /// 废除品质档限定拦截，所有效果均自由放行
  @override
  void dispose() {
    TrayService.instance.isWindowVisible.removeListener(_onWindowVisibilityChanged);
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
    grLimiter.dispose();
    grComp.dispose();
    grGate.dispose();
    grDyneqLow.dispose();
    grDyneqMid.dispose();
    grDyneqHigh.dispose();
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

/// 延迟徽标配色档位：四阶声学色彩动力学（直通/零开销为弱灰，录音监听级为绿，影视游戏级为金，缓冲级为红）
Color latencyColor(double ms, AuraPalette p) {
  if (ms <= 0) return p.textDim;
  if (ms <= 10) return p.success;
  if (ms <= 30) return p.warning;
  return p.accent2;
}
