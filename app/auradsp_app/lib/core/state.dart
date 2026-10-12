/*
 * state.dart — AppModel：主 isolate 侧的应用状态
 *
 * 职责：持有音频 isolate（唯一 auradsp_handle 所有者），把消息协议翻译为
 * 可观察状态；viz 高频数据走独立 ValueNotifier（30fps），避免整页重建。
 */
import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' show Color, Locale;

import '../engine/audio_isolate.dart';
import '../engine/auradsp_ffi.dart'
    show ParamId, kEngineStageCount, AuraDspLib, VizBands;
import '../engine/debug_log.dart';
import 'config.dart';
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

  // 声场分带
  static const double stereoBand = 0.5;      // 50%

  // 低音重构
  static const double bassIntensity = 0.6;   // 60%
  static const int bassMode = 0;             // 0: 动态增强, 1: 纯净低架, 2: 心理声学谐波
  static const double bassCutoff = 120.0;    // 120 Hz
  static const double bassHarmonics = 0.45;  // 45%
  static const double bassHarmonicBlend = 0.5;// 50% (平衡)
  static const double bassSubFloor = 25.0;   // 25 Hz

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
  int engineState = 0; // 0=bypass 1=processing 2=error
  double latencyMs = 0;
  bool playing = false;
  bool bypass = false;
  String sourceKind = ''; // '' | 'tone' | 'pink' | 'file'

  // 参数镜像（engine 侧真相，UI 只做回显与乐观更新）
  bool bassOn = false, eqOn = false, limiterOn = true;
  double bassGain = ParamDefaults.bassGain,
      stereoMix = ParamDefaults.stereoMix,
      postGain = ParamDefaults.postGain;
  int reverbPreset = -1;
  int channelsMode = 0;

  // Liveprog（v1.1）：status 0=无代码 1=编译成功 <0=引擎错误码
  bool lpEnabled = false;
  int lpStatus = 0;
  String? lpError; // 最近一次编译错误文案（事件条已显示，这里供编辑页内联标红）
  final List<double> lpParams = List.filled(8, 0);

  // 卷积 / IR（v1.1 M4）：meta 由引擎门卫校验后回读
  bool convEnabled = false, convReady = false;
  int convFrames = 0, convChannels = 0, convSrcRate = 0;
  double convPeak = 0.0;
  List<List<double>> convSpectrum = [];

  // M3-a：轻量效果
  bool tubeOn = false, xfeedOn = false;

  // M5/P-002：声场分带（0..1 每带；bandUsed=false 时随总滑块统一）
  final List<double> stereoBands = List.filled(5, 0.5);
  bool stereoBandUsed = false;

  // 脉冲响应干湿比 + VDC
  double convMix = 1.0;
  bool ddcOn = false, ddcReady = false;

  // M5-b：低频搁架
  bool shelfOn = false;
  double shelfFreq = 100, shelfGain = 0;

  // M5-c：空间混响（Freeverb / Spatial Reverb）
  bool fvOn = false;
  double fvDecay = 0.5, fvDamp = 0.5, fvWet = 0.35, fvDry = 1.0;
  double fvRoomSize = 1.2, fvWidth = 1.0;
  bool get isSpatialReverbOn => reverbPreset >= 0 || fvOn;

  // M3.5-a：处理顺序（Dart 镜像；引擎侧表驱动 P-004）
  String? graphOrder;

  // 低音重构（Phase 4）
  double bassIntensity = ParamDefaults.bassIntensity;
  int bassMode = ParamDefaults.bassMode;
  double bassCutoff = ParamDefaults.bassCutoff;
  double bassHarmonics = ParamDefaults.bassHarmonics;
  double bassHarmonicBlend = ParamDefaults.bassHarmonicBlend;
  double bassSubFloor = ParamDefaults.bassSubFloor;

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

  int eqBandsCount = ParamDefaults.eqBandsCount;
  /// 初值先用 48k 网格；构造函数体里 `config` 加载完后会按真实采样率重建
  /// （字段初始化器先于构造函数体执行，那时 config 还没读出来）。
  List<double> eqFrequencies = eqGridFor(ParamDefaults.eqBandsCount, 48000);
  List<double> eqGains = List.filled(15, 0.0);
  double eqQ = ParamDefaults.eqQ;
  int eqFilter = ParamDefaults.eqFilter;
  int eqInterp = ParamDefaults.eqInterp;
  String eqPresetName = 'flat';
  bool eqBypass = false;

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

  AppModel() {
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

    if (config.autoRestoreSession) {
      final session = SessionMemory.load();
      if (session != null) {
        SessionMemory.restoreMemoryImage(this, session);
      } else {
        SessionMemory.save(this);
      }
    }
    _spawn();
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
    if (_isReplayingSession) return;
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
        xfeedOn = (raw['xfeedEnable'] as int) != 0;
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
        fvOn = (raw['fvEnable'] as int) != 0;
        fvDecay = (raw['fvDecay'] as num).toDouble();
        fvDamp = (raw['fvDamp'] as num).toDouble();
        fvWet = (raw['fvWet'] as num).toDouble();
        fvDry = (raw['fvDry'] as num).toDouble();
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
        if (rc != 0) {
          lastGuard = GuardRejection(
              id, (raw['msg'] as String?) ?? 'engine rc=$rc', rc);
          if (id == ParamId.lpCode || id.startsWith('liveprog.')) {
            lpError = lastGuard!.message; // 编辑页内联标红用
          }
          eventSeq.value = ++_guardSeq;
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
        _probing.remove(comp);
        if (rc == 0) {
          final samples = (raw['samples'] as num?)?.toInt() ?? 0;
          _measuredLatencyMs[comp] = samples / deviceRate * 1000.0;
        } else {
          // 测量失败时不强行弹窗骚扰用户，清除旧测量值，在卡片上的 Badge
          // 静默保持「未测量」与 Tooltip 说明即可。
          _measuredLatencyMs.remove(comp);
        }
        notifyListeners();
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
      // 1. 下发全量基础开关与数值
      setInt('bass.enable', bassOn ? 1 : 0);
      setFloat('bass.gain', bassGain);
      setFloat('stereo.mix', stereoMix * stereoWidenMax);
      if (stereoBandUsed) {
        setInt('stereo.bandUsed', 1);
        for (var i = 0; i < 5; i++) {
          setFloat('stereo.band${i + 1}', stereoBands[i]);
        }
      }
      setInt('tube.enable', tubeOn ? 1 : 0);
      setFloat('tube.gain', tubeGain);
      setInt('crossfeed.enable', xfeedOn ? 1 : 0);
      setInt('shelf.enable', shelfOn ? 1 : 0);
      setFloat('shelf.freq', shelfFreq);
      setFloat('shelf.gain', shelfGain);
      setInt('limiter.enable', limiterOn ? 1 : 0);
      setFloat('post.gain', postGain);

      // 2. 混响
      if (reverbPreset >= 0) {
        setInt('reverb.preset', reverbPreset);
      } else if (fvOn) {
        setFloat('freeverb.decay', fvDecay);
        setFloat('freeverb.damp', fvDamp);
        setFloat('freeverb.wet', fvWet);
        setFloat('freeverb.dry', fvDry);
        setInt(ParamId.fvEnable, 1);
      }

      // 3. EQ 状态与曲线
      setInt('eq.enable', eqOn ? 1 : 0);
      _pushEqCurve();

      // 4. 外部文件自校验重载
      if (convIrPath != null && convIrPath!.isNotEmpty && File(convIrPath!).existsSync()) {
        loadConvolverIr(convIrPath!);
        if (convEnabled) setInt(ParamId.convEnable, 1);
      }
      if (ddcPath != null && ddcPath!.isNotEmpty && File(ddcPath!).existsSync()) {
        loadVdc(ddcPath!);
        if (ddcOn) setInt(ParamId.ddcEnable, 1);
      }
      if (lpCode != null && lpCode!.isNotEmpty) {
        setLiveprogCode(lpCode!);
        if (lpEnabled) setInt(ParamId.lpEnable, 1);
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
      case 'limiter.enable': limiterOn = v != 0; break;
      case 'channels.mode': channelsMode = v.toInt(); break;
      case 'tube.enable': tubeOn = v != 0; break;
      case 'crossfeed.enable': xfeedOn = v != 0; break;
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
        if (id == ParamId.fvEnable) { fvOn = v != 0; break; }
        if (id == ParamId.fvDecay) { fvDecay = v; break; }
        if (id == ParamId.fvDamp) { fvDamp = v; break; }
        if (id == ParamId.fvWet) { fvWet = v; break; }
        if (id == ParamId.fvDry) { fvDry = v; break; }
        final m = RegExp(r'^liveprog\.param([1-8])$').firstMatch(id);
        if (m != null) lpParams[int.parse(m.group(1)!) - 1] = v;
    }
  }

  void setStereoMix(double v) {
    stereoMix = v.clamp(0.0, 1.0);
    final macroMultiplier = stereoMix * 2.0;
    setFloat('stereo.mix', stereoMix * stereoWidenMax);
    for (var i = 0; i < 5; i++) {
      final eff = (stereoBands[i] * macroMultiplier).clamp(0.0, 1.0) * stereoWidenMax;
      setFloat('stereo.band${i + 1}', eff);
    }
    notifyListeners();
  }

  void setStereoBand(int index, double baseVal) {
    if (index < 0 || index >= 5) return;
    stereoBands[index] = baseVal.clamp(0.0, 1.0);
    final macroMultiplier = stereoMix * 2.0;
    final eff = (stereoBands[index] * macroMultiplier).clamp(0.0, 1.0) * stereoWidenMax;
    setFloat('stereo.band${index + 1}', eff);
    notifyListeners();
  }

  void resetStereoBand(int index) {
    setStereoBand(index, ParamDefaults.stereoBand);
  }

  /// 双击主滑块时重置立体声扩展并恢复 5 个子带为 0.5 中性
  void resetStereoWiden() {
    stereoMix = ParamDefaults.stereoMix;
    setFloat('stereo.mix', stereoMix * stereoWidenMax);
    for (var i = 0; i < 5; i++) {
      stereoBands[i] = ParamDefaults.stereoBand;
      setFloat('stereo.band${i + 1}', ParamDefaults.stereoBand * stereoWidenMax);
    }
    stereoBandUsed = false;
    notifyListeners();
  }

  void resetStereoBandsToGlobal() {
    for (var i = 0; i < 5; i++) {
      stereoBands[i] = ParamDefaults.stereoBand;
      final macroMultiplier = stereoMix * 2.0;
      final eff = (stereoBands[i] * macroMultiplier).clamp(0.0, 1.0) * stereoWidenMax;
      setFloat('stereo.band${i + 1}', eff);
    }
    stereoBandUsed = false;
    notifyListeners();
  }

  bool get stereoOn => stereoMix > 0.0;

  void setStereoEnabled(bool on) {
    if (on) {
      final target = _lastStereoMix > 0.0 ? _lastStereoMix : 0.5;
      setStereoMix(target);
    } else {
      if (stereoMix > 0.0) {
        _lastStereoMix = stereoMix;
      }
      setStereoMix(0.0);
    }
  }

  /* ---- Liveprog 命令（v1.1） ---- */

  void setGraphOrder(String order) {
    graphOrder = order;
    send({'cmd': 'setParamStr', 'id': 'graph.order', 'text': order});
  }

  /// 获取某个处理链 stage 的启用状态
  bool isStageEnabled(String stageId) {
    return switch (stageId) {
      'tube' => tubeOn,
      'comp' => false,
      'bass' => bassOn,
      'eq' => eqOn,
      'arbmag' => false,
      'convolver' => convEnabled,
      'ddc' => ddcOn,
      'liveprog' => lpEnabled,
      'crossfeed' => xfeedOn,
      'stereo' => stereoMix > 0.0,
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
      case 'bass':
        setInt('bass.enable', bassOn ? 0 : 1);
      case 'eq':
        setInt('eq.enable', eqOn ? 0 : 1);
      case 'convolver':
        setInt(ParamId.convEnable, convEnabled ? 0 : 1);
      case 'ddc':
        setInt(ParamId.ddcEnable, ddcOn ? 0 : 1);
      case 'liveprog':
        setLiveprogEnabled(!lpEnabled);
      case 'crossfeed':
        setInt('crossfeed.enable', xfeedOn ? 0 : 1);
      case 'stereo':
        if (stereoMix > 0.0) {
          setFloat('stereo.mix', 0.0);
        } else {
          setFloat('stereo.mix', 0.5 * stereoWidenMax);
        }
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
    send({'cmd': 'setParamStr', 'id': ParamId.lpCode, 'text': text});
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
    lpCode = null;
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
    setInt(ParamId.xfeedEnable, on ? 1 : 0);
  }

  /// 参数化混响使能：废除品质档拦截限制，无条件自由放行
  void setFreeverbEnabled(bool on, {String? autoQualityMsg}) {
    fvOn = on;
    notifyListeners();
    _markSent(ParamId.fvEnable);
    send({'cmd': 'setParam', 'id': ParamId.fvEnable, 'value': on ? 1 : 0, 'isFloat': false});
  }

  void selectReverbPreset(int id) {
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
      setReverbPreset(-1);
      setFreeverbEnabled(false);
    } else if (id == -2) {
      // 自定义模式
      setFreeverbEnabled(true);
      notifyListeners();
    }
  }

  void setSpatialReverbEnabled(bool on) {
    if (on) {
      selectReverbPreset(reverbPreset >= 0 ? reverbPreset : 0);
    } else {
      selectReverbPreset(-1);
    }
  }

  void setReverbCustomParam(String param, double value) {
    reverbPreset = -2; // 联动切换为自定义模式
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

  void setBassIntensity(double v) {
    bassIntensity = v.clamp(0.0, 1.0);
    final gain = (bassIntensity * 15.0).clamp(0.0, 15.0);
    bassGain = gain;
    setFloat('bass.gain', gain);
    if (bassMode == 1) {
      setFloat('shelf.gain', (bassIntensity * 12.0).clamp(0.0, 12.0));
    }
    notifyListeners();
  }

  void setBassMode(int mode) {
    bassMode = mode;
    if (mode == 1) {
      setInt('shelf.enable', 1);
      setFloat('shelf.freq', bassCutoff);
      setFloat('shelf.gain', (bassIntensity * 12.0).clamp(0.0, 12.0));
    } else {
      setInt('shelf.enable', 0);
    }
    notifyListeners();
  }

  void setBassCutoff(double f) {
    bassCutoff = f;
    setFloat('shelf.freq', f);
    notifyListeners();
  }

  void setBassHarmonics(double h) {
    bassHarmonics = h.clamp(0.0, 1.0);
    notifyListeners();
  }

  void setBassHarmonicBlend(double b) {
    bassHarmonicBlend = b.clamp(0.0, 1.0);
    notifyListeners();
  }

  void setBassSubFloor(double s) {
    bassSubFloor = s;
    notifyListeners();
  }

  /* ---- 电子管模拟器（Phase 4） ---- */

  void setTubeGain(double db) {
    tubeGain = db.clamp(-3.0, 12.0);
    setFloat('tube.gain', tubeGain);
    notifyListeners();
  }

  void setTubeStyle(int style) {
    tubeStyle = style;
    notifyListeners();
  }

  void setTubeOversampling(int os) {
    tubeOversampling = os;
    notifyListeners();
  }

  void setTubeCompensation(double comp) {
    tubeCompensation = comp.clamp(-6.0, 6.0);
    notifyListeners();
  }

  void setTubeMix(double mix) {
    tubeMix = mix.clamp(0.0, 1.0);
    notifyListeners();
  }

  /* ---- 多段图形均衡器（Phase 3） ---- */

  /// C4：按当前采样率重建 EQ 频率网格，增益按**频率**重新映射。
///
/// 裁掉高频带时不能简单截断 gains —— 那样低频段的增益会整体错位。
/// 这里对每个新频点取旧网格中最接近的旧频点上的增益，
/// 于是 Nyquist 以内的部分行为完全不变，只有越界的频带连同其增益一起消失。
void _rebuildEqGridForSampleRate({bool notify = true}) {
  final target = eqGridFor(eqBandsCount, config.sampleRate);
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
  final newGains = <double>[];
  for (final f in target) {
    if (oldFreqs.isEmpty || oldGains.isEmpty) {
      newGains.add(0.0);
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
  }
  eqFrequencies = target;
  eqGains = newGains;
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
    final newFreqs = eqGridFor(count, config.sampleRate);
    final oldFreqs = eqFrequencies;
    final oldGains = eqGains;
    final newGains = <double>[];
    for (final f in newFreqs) {
      if (oldFreqs.isEmpty || oldGains.isEmpty) {
        newGains.add(0.0);
        continue;
      }
      if (f <= oldFreqs.first) {
        newGains.add(oldGains.first);
      } else if (f >= oldFreqs.last) {
        newGains.add(oldGains.last);
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
      }
    }
    eqFrequencies = List.from(newFreqs);
    eqGains = newGains;
    _pushEqCurve();
  }

  void setEqBandGain(int index, double gain) {
    if (index >= 0 && index < eqGains.length) {
      eqGains[index] = gain.clamp(-18.0, 18.0);
      eqPresetName = 'custom';
      _pushEqCurve();
    }
  }

  void setEqQ(double q) {
    eqQ = q.clamp(0.3, 10.0);
    _pushEqCurve();
  }

  void setEqFilter(int filter) {
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
    final nyquist = math.min(20000.0, config.sampleRate / 2.0);
    final buffer = StringBuffer();
    if (eqFrequencies.isNotEmpty && eqFrequencies.first > 20) {
      buffer.write('20:${eqGains.first.toStringAsFixed(1)};');
    }
    for (var i = 0; i < eqFrequencies.length; i++) {
      final f = math.min(eqFrequencies[i], nyquist);
      buffer.write('${f.toStringAsFixed(1)}:${eqGains[i].toStringAsFixed(1)}');
      if (i < eqFrequencies.length - 1) buffer.write(';');
    }
    if (eqFrequencies.isNotEmpty && eqFrequencies.last < nyquist) {
      buffer.write(';${nyquist.toStringAsFixed(1)}:${eqGains.last.toStringAsFixed(1)}');
    }
    _pendingEqCurve = buffer.toString();
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
  static List<double> composeEqOutputSpectrum(
    List<double> eqIn,
    List<double>? respDb, {
    bool bypassed = false,
  }) {
    final out = List<double>.filled(VizBands.count, 0);
    final n = eqIn.length < VizBands.count ? eqIn.length : VizBands.count;
    final flat = bypassed || respDb == null || respDb.length < 2;
    for (var b = 0; b < n; b++) {
      if (flat) {
        out[b] = eqIn[b].clamp(0.0, 1.0);
        continue;
      }
      final hz = VizBands.centerHz(b);
      final db = VizBands.toDb(eqIn[b].clamp(0.0, 1.0)) + _respDbAt(respDb, hz);
      out[b] = VizBands.fromDb(db);
    }
    return out;
  }

  /// 在实测响应（log 均分 fMin..fMax，129 点）上按频率线性插值取 dB。
  static double _respDbAt(List<double> resp, double hz) {
    const fMin = 20.0, fMax = 20000.0;
    final t = (math.log(hz / fMin) / math.log(fMax / fMin)).clamp(0.0, 1.0);
    final x = t * (resp.length - 1);
    final i = x.floor();
    if (i >= resp.length - 1) return resp[resp.length - 1];
    final f = x - i;
    return resp[i] * (1 - f) + resp[i + 1] * f;
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
        db = lib.measureEqResponse(c, config.sampleRate,
            nPoints: eqResponsePoints);
      } catch (_) {
        return;   // 探针异常：保留上一帧曲线
      }
      if (db == null) return;
      eqResponseDb = db;
      eqResponseCurve = c;
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
        convFrames > 0 && convSrcRate > 0) {
      return (ms: (convFrames / convSrcRate) * 1000.0, measured: false);
    }
    return (ms: 0.0, measured: false);
  }

  /// 触发一次真实脉冲探测（控制线程，约数十毫秒，非 RT）。
  void refreshComponentLatency(String compId) {
    if (_probing.contains(compId)) return;
    _probing.add(compId);
    _latencyRefreshTicks[compId] = DateTime.now().millisecondsSinceEpoch;
    notifyListeners();
    // 卷积 / VDC 已支持「带资源探针」：把已加载的文件路径一并下发，
    // 这样它们能被真正实测，而不是恒返回 -1「不支持延迟探测」。
    send({
      'cmd': 'probeComponentLatency',
      'comp': compId,
      'resource': latencyProbeResource(compId) ?? '',
    });
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
        'convolver', 'ddc'
      }.contains(compId);

  /// 探测进行中
  bool isProbingLatency(String compId) => _probing.contains(compId);

  void setSource(String kind, {String? path}) {
    sourceKind = kind == 'stop' ? '' : kind;
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
    SessionMemory.save(this);
    _toIso?.send({'cmd': 'shutdown'});
    _iso?.kill(priority: Isolate.beforeNextEvent);
    _fromIso?.close();
    spectrum.dispose();
    levelL.dispose();
    levelR.dispose();
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
