/*
 * param_schema.dart — AuraDSP 全链路统一参数元数据体系 (SSOT)
 *
 * 规范：定义每一个音频参数的全局唯一标识、归属节、键名、类型、默认值、
 * 取值范围、单位、序列化标志位、UI 分类与双向存取访问器。
 * 驱动 C++ 引擎分发、Dart 状态、预设通用快照/应用与 UI 自绑定控件。
 */

import 'state.dart';

/// 参数数据类型
enum ParamType {
  float,    // 连续浮点 (如 gain: dB, freq: Hz, ratio)
  int32,    // 离散整型 (如 bandsCount, filterType, style)
  boolean,  // 二元布尔开关 (如 enable, autoGain)
  string,   // 字符串/路径/曲线/脚本
  blob,     // 浮点数组 (如 stereo.bands, eq.frequencies)
}

/// UI 布局分类
enum ParamCategory {
  main,       // 卡片主体主显参数
  advanced,   // 折叠高级抽屉内参数
  outputGate, // 每模块输出级 (AGC + Trim)
  routing,    // 路由与设备端点
  hidden,     // 内部状态/纯逻辑参数
}

/// 参数属性标志位 (掩码)
abstract final class ParamFlags {
  static const int none               = 0;
  static const int presetSerializable = 1 << 0; // 是否参与预设持久化 (DSP 参数=1, 设备 GUID=0)
  static const int sessionOnly        = 1 << 1; // 仅存会话记忆，不入公共预设
  static const int realtimeSafe       = 1 << 2; // RT 线程安全 (无锁/无内存分配)
  static const int requiresDspRebuild = 1 << 3; // 修改会触发 DSP 重建 (如 FFT 点数/IR 重载)
  static const int isDerivation       = 1 << 4; // 派生参数 (UI 不直接设值，如 bass.gain)
}

/// 强类型参数描述符
class ParamSpec<T> {
  final String id;             // 引擎全局唯一标识符 (如 "tube.gain", "bass.cutoff")
  final String section;        // 所属处理节 (如 "tube", "bass", "eq")
  final String? subSection;    // 所属子节 (如 dyneq 的 "low", "mid", "high")
  final String key;            // 节内键名 (如 "gain", "cutoff")
  final ParamType type;        // 数据类型
  final T defaultValue;        // 规范默认值 (唯一真相源)
  final double min;            // 最小值 (数值型有效)
  final double max;            // 最大值 (数值型有效)
  final double step;           // 步进 (用于 Slider/微调)
  final String unit;           // 单位标签 (dB, Hz, ms, %, 等)
  final int flags;             // 特性位掩码
  final ParamCategory category;// UI 分类
  final int order;             // 应用排序权重 (默认 0；开关通常设为 100，确保最后开启)
  final String Function(T)? formatter; // 显示格式化闭包
  final List<String>? options; // 枚举型专用备选项列表 (如 Style 0/1/2)

  final T Function(AppModel m) getter;
  final void Function(AppModel m, T value) setter;

  const ParamSpec({
    required this.id,
    required this.section,
    this.subSection,
    required this.key,
    required this.type,
    required this.defaultValue,
    this.min = 0.0,
    this.max = 1.0,
    this.step = 0.01,
    this.unit = '',
    this.flags = ParamFlags.presetSerializable | ParamFlags.realtimeSafe,
    this.category = ParamCategory.main,
    this.order = 0,
    this.formatter,
    this.options,
    required this.getter,
    required this.setter,
  });

  bool get isPresetSerializable => (flags & ParamFlags.presetSerializable) != 0;
  bool get isSessionOnly => (flags & ParamFlags.sessionOnly) != 0;
  bool get isRealtimeSafe => (flags & ParamFlags.realtimeSafe) != 0;
  bool get isDerivation => (flags & ParamFlags.isDerivation) != 0;

  T read(AppModel m) => getter(m);
  void write(AppModel m, T val) => setter(m, clamp(val));

  /// 安全类型转换与兜底
  T cast(dynamic raw) {
    if (raw == null) return defaultValue;
    if (type == ParamType.float) {
      if (raw is num) return raw.toDouble() as T;
      if (raw is String) {
        final parsed = double.tryParse(raw);
        if (parsed != null) return parsed as T;
      }
    } else if (type == ParamType.int32) {
      if (raw is num) return raw.toInt() as T;
      if (raw is String) {
        final parsed = int.tryParse(raw);
        if (parsed != null) return parsed as T;
      }
    } else if (type == ParamType.boolean) {
      if (raw is bool) return raw as T;
      if (raw is num) return (raw != 0) as T;
      if (raw is String) {
        final lower = raw.trim().toLowerCase();
        if (lower == 'true' || lower == '1') return true as T;
        if (lower == 'false' || lower == '0') return false as T;
      }
    } else if (type == ParamType.string) {
      return raw.toString() as T;
    } else if (type == ParamType.blob) {
      if (raw is List) {
        return raw.map((e) => (e as num).toDouble()).toList() as T;
      }
    }
    return defaultValue;
  }

  /// 边界安全钳位
  T clamp(T val) {
    if (type == ParamType.float && val is num) {
      return (val.toDouble().clamp(min, max)) as T;
    }
    if (type == ParamType.int32 && val is num) {
      return (val.toInt().clamp(min.toInt(), max.toInt())) as T;
    }
    return val;
  }
}

/// 处理节定义 (支持复合逻辑自定义拦截钩子)
class ParamSection {
  final String name;
  final List<ParamSpec> specs;
  final bool customApplyOnly;
  final void Function(AppModel m, Map<String, dynamic> sectionData, bool fullRewrite)? postApply;
  final void Function(AppModel m, Map<String, dynamic> sectionData)? customSnapshot;

  ParamSection({
    required this.name,
    required this.specs,
    this.customApplyOnly = false,
    this.postApply,
    this.customSnapshot,
  });
}

/// 集中式参数元数据注册中心 (ParamRegistry)
abstract final class ParamRegistry {
  /* =========================================================================
   * 0. 输入门控 (Input Gate)
   * ========================================================================= */
  static final inputGain = ParamSpec<double>(
    id: 'input.gain', section: 'input', key: 'gain',
    type: ParamType.float, defaultValue: ParamDefaults.inputGain,
    min: -15.0, max: 15.0, step: 0.1, unit: 'dB',
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.inputGain,
    setter: (m, v) => m.setInputGain(v),
  );
  static final inputBalanceL = ParamSpec<double>(
    id: 'input.balance.1', section: 'input', key: 'balanceL',
    type: ParamType.float, defaultValue: ParamDefaults.inputBalanceL,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.inputBalanceL,
    setter: (m, v) => m.setInputBalanceL(v),
  );
  static final inputBalanceR = ParamSpec<double>(
    id: 'input.balance.2', section: 'input', key: 'balanceR',
    type: ParamType.float, defaultValue: ParamDefaults.inputBalanceR,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.inputBalanceR,
    setter: (m, v) => m.setInputBalanceR(v),
  );

  /* =========================================================================
   * 1. 低音增强 (Bass Boost)
   * ========================================================================= */
  static final bassIntensity = ParamSpec<double>(
    id: 'bass.intensity', section: 'bass', key: 'intensity',
    type: ParamType.float, defaultValue: ParamDefaults.bassIntensity,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.bassIntensity,
    setter: (m, v) => m.setBassIntensity(v),
  );
  static final bassMode = ParamSpec<int>(
    id: 'bass.mode', section: 'bass', key: 'mode',
    type: ParamType.int32, defaultValue: ParamDefaults.bassMode,
    min: 0, max: 2,
    options: ['动态增强', '纯净低架', '心理声学谐波'],
    getter: (m) => m.bassMode,
    setter: (m, v) => m.setBassMode(v),
  );
  static final bassCutoff = ParamSpec<double>(
    id: 'bass.cutoff', section: 'bass', key: 'cutoff',
    type: ParamType.float, defaultValue: ParamDefaults.bassCutoff,
    min: 30.0, max: 300.0, step: 1.0, unit: 'Hz',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.bassCutoff,
    setter: (m, v) => m.setBassCutoff(v),
  );
  static final bassHarmonics = ParamSpec<double>(
    id: 'bass.harmonics', section: 'bass', key: 'harmonics',
    type: ParamType.float, defaultValue: ParamDefaults.bassHarmonics,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    category: ParamCategory.advanced,
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.bassHarmonics,
    setter: (m, v) => m.setBassHarmonics(v),
  );
  static final bassHarmonicBlend = ParamSpec<double>(
    id: 'bass.harmonicBlend', section: 'bass', key: 'harmonicBlend',
    type: ParamType.float, defaultValue: ParamDefaults.bassHarmonicBlend,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    category: ParamCategory.advanced,
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.bassHarmonicBlend,
    setter: (m, v) => m.setBassHarmonicBlend(v),
  );
  static final bassSubFloor = ParamSpec<double>(
    id: 'bass.subFloor', section: 'bass', key: 'subFloor',
    type: ParamType.float, defaultValue: ParamDefaults.bassSubFloor,
    min: 10.0, max: 80.0, step: 1.0, unit: 'Hz',
    category: ParamCategory.advanced,
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.bassSubFloor,
    setter: (m, v) => m.setBassSubFloor(v),
  );
  static final bassGain = ParamSpec<double>(
    id: 'bass.gain', section: 'bass', key: 'gain',
    type: ParamType.float, defaultValue: ParamDefaults.bassGain,
    min: 0.0, max: 15.0, step: 0.1, unit: 'dB',
    flags: ParamFlags.presetSerializable | ParamFlags.isDerivation,
    getter: (m) => m.bassGain,
    setter: (m, v) => {}, // 派生字段，由 intensity 计算
  );
  static final bassAutoGain = ParamSpec<bool>(
    id: 'bass.autogain', section: 'bass', key: 'autoGain',
    type: ParamType.boolean, defaultValue: ParamDefaults.bassAutoGain,
    category: ParamCategory.outputGate,
    getter: (m) => m.bassAutoGain,
    setter: (m, v) => m.setBassAutoGain(v),
  );
  static final bassOutputGain = ParamSpec<double>(
    id: 'bass.outputgain', section: 'bass', key: 'outputGain',
    type: ParamType.float, defaultValue: ParamDefaults.bassOutputGain,
    min: -12.0, max: 6.0, step: 0.1, unit: 'dB',
    category: ParamCategory.outputGate,
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.bassOutputGain,
    setter: (m, v) => m.setBassOutputGain(v),
  );
  static final bassEnable = ParamSpec<bool>(
    id: 'bass.enable', section: 'bass', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100, // 最后开开关
    getter: (m) => m.bassOn,
    setter: (m, v) => m.setInt('bass.enable', v ? 1 : 0),
  );

  /* =========================================================================
   * 2. 空间混响 (Spatial Reverb)
   * ========================================================================= */
  static final reverbPreset = ParamSpec<int>(
    id: 'reverb.preset', section: 'reverb', key: 'preset',
    type: ParamType.int32, defaultValue: -1,
    min: -2, max: 17,
    flags: ParamFlags.presetSerializable | ParamFlags.isDerivation,
    getter: (m) => m.reverbPreset,
    setter: (m, v) => m.setReverbPreset(v),
  );
  static final reverbDecay = ParamSpec<double>(
    id: 'reverb.decay', section: 'reverb', key: 'decay',
    type: ParamType.float, defaultValue: ParamDefaults.fvDecay,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    flags: ParamFlags.presetSerializable | ParamFlags.isDerivation,
    getter: (m) => m.fvDecay,
    setter: (m, v) => m.setReverbCustomParam('decay', v),
  );
  static final reverbDamp = ParamSpec<double>(
    id: 'reverb.damp', section: 'reverb', key: 'damp',
    type: ParamType.float, defaultValue: ParamDefaults.fvDamp,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    flags: ParamFlags.presetSerializable | ParamFlags.isDerivation,
    getter: (m) => m.fvDamp,
    setter: (m, v) => m.setReverbCustomParam('damp', v),
  );
  static final reverbWet = ParamSpec<double>(
    id: 'reverb.wet', section: 'reverb', key: 'wet',
    type: ParamType.float, defaultValue: ParamDefaults.fvWet,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    flags: ParamFlags.presetSerializable | ParamFlags.isDerivation,
    getter: (m) => m.fvWet,
    setter: (m, v) => m.setReverbCustomParam('wet', v),
  );
  static final reverbDry = ParamSpec<double>(
    id: 'reverb.dry', section: 'reverb', key: 'dry',
    type: ParamType.float, defaultValue: ParamDefaults.fvDry,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    flags: ParamFlags.presetSerializable | ParamFlags.isDerivation,
    getter: (m) => m.fvDry,
    setter: (m, v) => m.setReverbCustomParam('dry', v),
  );
  static final reverbRoomSize = ParamSpec<double>(
    id: 'reverb.roomSize', section: 'reverb', key: 'roomSize',
    type: ParamType.float, defaultValue: ParamDefaults.fvRoomSize,
    min: 0.1, max: 3.0, step: 0.05, unit: 'x',
    formatter: (v) => '${v.toStringAsFixed(2)}x',
    flags: ParamFlags.presetSerializable | ParamFlags.isDerivation,
    getter: (m) => m.fvRoomSize,
    setter: (m, v) => m.setReverbCustomParam('roomSize', v),
  );
  static final reverbStereoWidth = ParamSpec<double>(
    id: 'reverb.width', section: 'reverb', key: 'stereoWidth',
    type: ParamType.float, defaultValue: ParamDefaults.fvWidth,
    min: 0.0, max: 2.0, step: 0.05, unit: 'x',
    formatter: (v) => '${v.toStringAsFixed(2)}x',
    flags: ParamFlags.presetSerializable | ParamFlags.isDerivation,
    getter: (m) => m.fvWidth,
    setter: (m, v) => m.setReverbCustomParam('width', v),
  );
  static final reverbAutoGain = ParamSpec<bool>(
    id: 'reverb.autogain', section: 'reverb', key: 'autoGain',
    type: ParamType.boolean, defaultValue: ParamDefaults.reverbAutoGain,
    category: ParamCategory.outputGate,
    getter: (m) => m.reverbAutoGain,
    setter: (m, v) => m.setReverbAutoGain(v),
  );
  static final reverbOutputGain = ParamSpec<double>(
    id: 'reverb.outputgain', section: 'reverb', key: 'outputGain',
    type: ParamType.float, defaultValue: ParamDefaults.reverbOutputGain,
    min: -12.0, max: 6.0, step: 0.1, unit: 'dB',
    category: ParamCategory.outputGate,
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.reverbOutputGain,
    setter: (m, v) => m.setReverbOutputGain(v),
  );
  static final reverbEnable = ParamSpec<bool>(
    id: 'reverb.enable', section: 'reverb', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.isSpatialReverbOn,
    setter: (m, v) => m.setSpatialReverbEnabled(v),
  );

  /* =========================================================================
   * 3. 电子管模拟器 (Tube Simulator)
   * ========================================================================= */
  static final tubeGain = ParamSpec<double>(
    id: 'tube.gain', section: 'tube', key: 'gain',
    type: ParamType.float, defaultValue: ParamDefaults.tubeGain,
    min: -3.0, max: 12.0, step: 0.1, unit: 'dB',
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.tubeGain,
    setter: (m, v) => m.setTubeGain(v),
  );
  static final tubeStyle = ParamSpec<int>(
    id: 'tube.style', section: 'tube', key: 'style',
    type: ParamType.int32, defaultValue: ParamDefaults.tubeStyle,
    min: 0, max: 2,
    options: ['三极管 (暖)', '五极管 (利)', '磁带 (温)'],
    getter: (m) => m.tubeStyle,
    setter: (m, v) => m.setTubeStyle(v),
  );
  static final tubeCompensation = ParamSpec<double>(
    id: 'tube.compensation', section: 'tube', key: 'compensation',
    type: ParamType.float, defaultValue: ParamDefaults.tubeCompensation,
    min: -12.0, max: 12.0, step: 0.1, unit: 'dB',
    category: ParamCategory.advanced,
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.tubeCompensation,
    setter: (m, v) => m.setTubeCompensation(v),
  );
  static final tubeMix = ParamSpec<double>(
    id: 'tube.mix', section: 'tube', key: 'mix',
    type: ParamType.float, defaultValue: ParamDefaults.tubeMix,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    category: ParamCategory.advanced,
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.tubeMix,
    setter: (m, v) => m.setTubeMix(v),
  );
  static final tubeAutoGain = ParamSpec<bool>(
    id: 'tube.autogain', section: 'tube', key: 'autoGain',
    type: ParamType.boolean, defaultValue: ParamDefaults.tubeAutoGain,
    category: ParamCategory.outputGate,
    getter: (m) => m.tubeAutoGain,
    setter: (m, v) => m.setTubeAutoGain(v),
  );
  static final tubeOutputGain = ParamSpec<double>(
    id: 'tube.outputgain', section: 'tube', key: 'outputGain',
    type: ParamType.float, defaultValue: ParamDefaults.tubeOutputGain,
    min: -12.0, max: 6.0, step: 0.1, unit: 'dB',
    category: ParamCategory.outputGate,
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.tubeOutputGain,
    setter: (m, v) => m.setTubeOutputGain(v),
  );
  static final tubeOversample = ParamSpec<bool>(
    id: 'tube.oversample', section: 'tube', key: 'oversample',
    type: ParamType.boolean, defaultValue: false,
    category: ParamCategory.advanced,
    getter: (m) => m.tubeOversample,
    setter: (m, v) => m.setTubeOversample(v),
  );
  static final tubeEnable = ParamSpec<bool>(
    id: 'tube.enable', section: 'tube', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.tubeOn,
    setter: (m, v) => m.setInt('tube.enable', v ? 1 : 0),
  );

  /* =========================================================================
   * 4. 图形均衡器 (Multimodal EQ)
   * ========================================================================= */
  static final eqBandsCount = ParamSpec<int>(
    id: 'eq.bandsCount', section: 'eq', key: 'bandsCount',
    type: ParamType.int32, defaultValue: ParamDefaults.eqBandsCount,
    min: 10, max: 31,
    getter: (m) => m.eqBandsCount,
    setter: (m, v) => m.setEqBandsCount(v),
  );
  static final eqQ = ParamSpec<double>(
    id: 'eq.q', section: 'eq', key: 'q',
    type: ParamType.float, defaultValue: ParamDefaults.eqQ,
    min: 0.1, max: 10.0, step: 0.01,
    category: ParamCategory.advanced,
    flags: ParamFlags.presetSerializable | ParamFlags.isDerivation,
    getter: (m) => m.eqQ,
    setter: (m, v) => m.fillEqQ(v),
  );
  static final eqFilter = ParamSpec<int>(
    id: 'eq.filter', section: 'eq', key: 'filter',
    type: ParamType.int32, defaultValue: ParamDefaults.eqFilter,
    min: 0, max: 2,
    category: ParamCategory.advanced,
    options: ['FIR 最小相位', '6阶 IIR', '12阶 IIR'],
    getter: (m) => m.eqFilter,
    setter: (m, v) => m.setEqFilter(v),
  );
  static final eqInterp = ParamSpec<int>(
    id: 'eq.interp', section: 'eq', key: 'interp',
    type: ParamType.int32, defaultValue: ParamDefaults.eqInterp,
    min: 0, max: 1,
    category: ParamCategory.advanced,
    options: ['PCHIP', 'Makima'],
    getter: (m) => m.eqInterp,
    setter: (m, v) => m.setEqInterp(v),
  );
  static final eqPresetName = ParamSpec<String>(
    id: 'eq.presetName', section: 'eq', key: 'presetName',
    type: ParamType.string, defaultValue: 'flat',
    getter: (m) => m.eqPresetName,
    setter: (m, v) => m.eqPresetName = v,
  );
  static final eqBypass = ParamSpec<bool>(
    id: 'eq.bypass', section: 'eq', key: 'bypass',
    type: ParamType.boolean, defaultValue: false,
    getter: (m) => m.eqBypass,
    setter: (m, v) => m.eqBypass = v,
  );
  static final eqAutoGain = ParamSpec<bool>(
    id: 'eq.autogain', section: 'eq', key: 'autoGain',
    type: ParamType.boolean, defaultValue: ParamDefaults.eqAutoGain,
    category: ParamCategory.outputGate,
    getter: (m) => m.eqAutoGain,
    setter: (m, v) => m.setEqAutoGain(v),
  );
  static final eqOutputGain = ParamSpec<double>(
    id: 'eq.outputgain', section: 'eq', key: 'outputGain',
    type: ParamType.float, defaultValue: ParamDefaults.eqOutputGain,
    min: -12.0, max: 6.0, step: 0.1, unit: 'dB',
    category: ParamCategory.outputGate,
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.eqOutputGain,
    setter: (m, v) => m.setEqOutputGain(v),
  );
  static final eqEnable = ParamSpec<bool>(
    id: 'eq.enable', section: 'eq', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.eqOn,
    setter: (m, v) => m.setInt('eq.enable', v ? 1 : 0),
  );

  /* =========================================================================
   * 5. 立体声展宽 (Stereo Widen)
   * ========================================================================= */
  static final stereoMix = ParamSpec<double>(
    id: 'stereo.mix', section: 'stereo', key: 'mix',
    type: ParamType.float, defaultValue: ParamDefaults.stereoMix,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.stereoMix,
    setter: (m, v) => m.setStereoMix(v),
  );
  static final stereoBandUsed = ParamSpec<bool>(
    id: 'stereo.bandUsed', section: 'stereo', key: 'bandUsed',
    type: ParamType.boolean, defaultValue: false,
    order: 50, // 必须在 setStereoMix 之后执行，覆盖 setStereoMix 副作用
    getter: (m) => m.stereoBandUsed,
    setter: (m, v) => m.stereoBandUsed = v,
  );
  static final stereoOn = ParamSpec<bool>(
    id: 'stereo.enable', section: 'stereo', key: 'on',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.stereoOn,
    setter: (m, v) => m.setStereoEnabled(v),
  );
  static final stereoBand1 = ParamSpec<double>(
    id: 'stereo.band.1', section: 'stereo', key: 'band0',
    type: ParamType.float, defaultValue: ParamDefaults.stereoBand,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.stereoBands[0],
    setter: (m, v) => m.setStereoBand(0, v),
  );
  static final stereoBand2 = ParamSpec<double>(
    id: 'stereo.band.2', section: 'stereo', key: 'band1',
    type: ParamType.float, defaultValue: ParamDefaults.stereoBand,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.stereoBands[1],
    setter: (m, v) => m.setStereoBand(1, v),
  );
  static final stereoBand3 = ParamSpec<double>(
    id: 'stereo.band.3', section: 'stereo', key: 'band2',
    type: ParamType.float, defaultValue: ParamDefaults.stereoBand,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.stereoBands[2],
    setter: (m, v) => m.setStereoBand(2, v),
  );
  static final stereoBand4 = ParamSpec<double>(
    id: 'stereo.band.4', section: 'stereo', key: 'band3',
    type: ParamType.float, defaultValue: ParamDefaults.stereoBand,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.stereoBands[3],
    setter: (m, v) => m.setStereoBand(3, v),
  );
  static final stereoBand5 = ParamSpec<double>(
    id: 'stereo.band.5', section: 'stereo', key: 'band4',
    type: ParamType.float, defaultValue: ParamDefaults.stereoBand,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.stereoBands[4],
    setter: (m, v) => m.setStereoBand(4, v),
  );
  static final stereoBands = [stereoBand1, stereoBand2, stereoBand3, stereoBand4, stereoBand5];
  static ParamSpec<bool> get stereoEnable => stereoOn;
  static ParamSpec<double> get stereoWide => stereoMix;

  /* =========================================================================
   * 6. 低频搁架 (Shelf Filter)
   * ========================================================================= */
  static final shelfFreq = ParamSpec<double>(
    id: 'shelf.freq', section: 'shelf', key: 'freq',
    type: ParamType.float, defaultValue: ParamDefaults.shelfFreq,
    min: 40.0, max: 400.0, step: 1.0, unit: 'Hz',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.shelfFreq,
    setter: (m, v) => m.setShelfFreq(v),
  );
  static final shelfGain = ParamSpec<double>(
    id: 'shelf.gain', section: 'shelf', key: 'gain',
    type: ParamType.float, defaultValue: ParamDefaults.shelfGain,
    min: -15.0, max: 15.0, step: 0.1, unit: 'dB',
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.shelfGain,
    setter: (m, v) => m.setShelfGain(v),
  );
  static final shelfEnable = ParamSpec<bool>(
    id: 'shelf.enable', section: 'shelf', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.shelfOn,
    setter: (m, v) => m.setShelfEnabled(v),
  );

  /* =========================================================================
   * 7. 低频单声道化 (Bass Mono)
   * ========================================================================= */
  static final bassmonoFreq = ParamSpec<double>(
    id: 'bassmono.freq', section: 'bassmono', key: 'freq',
    type: ParamType.float, defaultValue: ParamDefaults.bassmonoFreq,
    min: 20.0, max: 300.0, step: 1.0, unit: 'Hz',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.bassmonoFreq,
    setter: (m, v) => m.setBassmonoFreq(v),
  );
  static final bassmonoEnable = ParamSpec<bool>(
    id: 'bassmono.enable', section: 'bassmono', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.bassmonoOn,
    setter: (m, v) => m.setBassmonoEnabled(v),
  );

  /* =========================================================================
   * 7B. 低音塑形 (Bass Shaping) — 合并低频搁架与低频单声道化
   * ========================================================================= */
  static final bassShapingEnable = ParamSpec<bool>(
    id: 'bass_shaping.enable', section: 'bass_shaping', key: 'on',
    type: ParamType.boolean, defaultValue: false,
    flags: ParamFlags.presetSerializable,
    order: 100,
    getter: (m) => m.bassShapingOn,
    setter: (m, v) => m.setBassShapingEnabled(v),
  );

  /* =========================================================================
   * 8. Haas 差分环绕 (Haas Effect)
   * ========================================================================= */
  static final haasDelay = ParamSpec<double>(
    id: 'haas.delay', section: 'haas', key: 'delay',
    type: ParamType.float, defaultValue: ParamDefaults.haasDelayMs,
    min: 0.0, max: 25.0, step: 0.1, unit: 'ms',
    formatter: (v) => v.toStringAsFixed(1),
    getter: (m) => m.haasDelayMs,
    setter: (m, v) => m.setHaasDelay(v),
  );
  static final haasMix = ParamSpec<double>(
    id: 'haas.mix', section: 'haas', key: 'mix',
    type: ParamType.float, defaultValue: ParamDefaults.haasMix,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.haasMix,
    setter: (m, v) => m.setHaasMix(v),
  );
  static final haasSide = ParamSpec<int>(
    id: 'haas.side', section: 'haas', key: 'side',
    type: ParamType.int32, defaultValue: ParamDefaults.haasSideRight,
    min: 0, max: 1,
    options: ['延迟右声道', '延迟左声道'],
    getter: (m) => m.haasSide,
    setter: (m, v) => m.setHaasSide(v),
  );
  static final haasEnable = ParamSpec<bool>(
    id: 'haas.enable', section: 'haas', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.haasOn,
    setter: (m, v) => m.setHaasEnabled(v),
  );

  /* =========================================================================
   * 9. 高频激励器 (Harmonic Exciter)
   * ========================================================================= */
  static final exciterAmount = ParamSpec<double>(
    id: 'exciter.amount', section: 'exciter', key: 'amount',
    type: ParamType.float, defaultValue: ParamDefaults.exciterAmount,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.exciterAmount,
    setter: (m, v) => m.setExciterAmount(v),
  );
  static final exciterHifreq = ParamSpec<double>(
    id: 'exciter.hifreq', section: 'exciter', key: 'hifreq',
    type: ParamType.float, defaultValue: ParamDefaults.exciterHifreq,
    min: 3000.0, max: 10000.0, step: 50.0, unit: 'Hz',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.exciterHifreq,
    setter: (m, v) => m.setExciterHifreq(v),
  );
  static final exciterOversample = ParamSpec<bool>(
    id: 'exciter.oversample', section: 'exciter', key: 'oversample',
    type: ParamType.boolean, defaultValue: false,
    category: ParamCategory.advanced,
    getter: (m) => m.exciterOversample,
    setter: (m, v) => m.setExciterOversample(v),
  );
  static final exciterEnable = ParamSpec<bool>(
    id: 'exciter.enable', section: 'exciter', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.exciterOn,
    setter: (m, v) => m.setExciterEnabled(v),
  );

  /* =========================================================================
   * 9B. 空间音效 (Spatial L1 HRTF)
   * ========================================================================= */
  static final spatialStyle = ParamSpec<int>(
    id: 'spatial.style', section: 'spatial', key: 'style',
    type: ParamType.int32, defaultValue: ParamDefaults.spatialStyle,
    min: 0, max: 2,
    options: ['影院', '定位', '中性'],
    getter: (m) => m.spatialStyle,
    setter: (m, v) => m.setSpatialStyle(v),
  );
  static final spatialRoom = ParamSpec<double>(
    id: 'spatial.room', section: 'spatial', key: 'room',
    type: ParamType.float, defaultValue: ParamDefaults.spatialRoom,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.spatialRoom,
    setter: (m, v) => m.setSpatialRoom(v),
  );
  static final spatialWidth = ParamSpec<double>(
    id: 'spatial.width', section: 'spatial', key: 'width',
    type: ParamType.float, defaultValue: ParamDefaults.spatialWidth,
    min: 0.5, max: 1.5, step: 0.01, unit: '×',
    formatter: (v) => v.toStringAsFixed(2),
    getter: (m) => m.spatialWidth,
    setter: (m, v) => m.setSpatialWidth(v),
  );
  static final spatialCenter = ParamSpec<double>(
    id: 'spatial.center', section: 'spatial', key: 'center',
    type: ParamType.float, defaultValue: ParamDefaults.spatialCenter,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.spatialCenter,
    setter: (m, v) => m.setSpatialCenter(v),
  );
  static final spatialOutGain = ParamSpec<double>(
    id: 'spatial.outgain', section: 'spatial', key: 'outgain',
    type: ParamType.float, defaultValue: ParamDefaults.spatialOutGain,
    min: -12.0, max: 6.0, step: 0.1, unit: 'dB',
    category: ParamCategory.outputGate,
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.spatialOutGain,
    setter: (m, v) => m.setSpatialOutGain(v),
  );
  static final spatialAutoGain = ParamSpec<bool>(
    id: 'spatial.autogain', section: 'spatial', key: 'autoGain',
    type: ParamType.boolean, defaultValue: false,
    category: ParamCategory.outputGate,
    getter: (m) => m.spatialAutoGain,
    setter: (m, v) => m.setSpatialAutoGain(v),
  );
  static final spatialMix = ParamSpec<double>(
    id: 'spatial.mix', section: 'spatial', key: 'mix',
    type: ParamType.float, defaultValue: ParamDefaults.spatialMix,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.spatialMix,
    setter: (m, v) => m.setSpatialMix(v),
  );
  static final spatialElevation = ParamSpec<double>(
    id: 'spatial.elevation', section: 'spatial', key: 'elevation',
    type: ParamType.float, defaultValue: ParamDefaults.spatialElevation,
    min: -30.0, max: 30.0, step: 1.0, unit: '°',
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(0),
    getter: (m) => m.spatialElevation,
    setter: (m, v) => m.setSpatialElevation(v),
  );
  static final spatialBinaural = ParamSpec<bool>(
    id: 'spatial.binaural', section: 'spatial', key: 'binaural',
    type: ParamType.boolean, defaultValue: ParamDefaults.spatialBinaural,
    getter: (m) => m.spatialBinaural,
    setter: (m, v) => m.setSpatialBinaural(v),
  );
  static final spatialHeadAzim = ParamSpec<double>(
    id: 'spatial.headazim', section: 'spatial', key: 'headAzim',
    type: ParamType.float, defaultValue: ParamDefaults.spatialHeadAzim,
    min: -180.0, max: 180.0, step: 1.0, unit: '°',
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(0),
    getter: (m) => m.spatialHeadAzim,
    setter: (m, v) => m.setSpatialHeadAzim(v),
  );
  static final spatialHeadTrack = ParamSpec<bool>(
    id: 'spatial.headtrack', section: 'spatial', key: 'headTrack',
    type: ParamType.boolean, defaultValue: ParamDefaults.spatialHeadTrack,
    getter: (m) => m.spatialHeadTrack,
    setter: (m, v) => m.setSpatialHeadTrack(v),
  );
  static final spatialEnable = ParamSpec<bool>(
    id: 'spatial.enable', section: 'spatial', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.spatialOn,
    setter: (m, v) => m.setSpatialEnabled(v),
  );

  /* =========================================================================
   * 10. 噪声门 (Noise Gate)
   * ========================================================================= */
  static final gateThreshold = ParamSpec<double>(
    id: 'gate.threshold', section: 'gate', key: 'threshold',
    type: ParamType.float, defaultValue: ParamDefaults.gateThreshold,
    min: -60.0, max: 0.0, step: 0.5, unit: 'dB',
    formatter: (v) => v.toStringAsFixed(1),
    getter: (m) => m.gateThreshold,
    setter: (m, v) => m.setGateThreshold(v),
  );
  static final gateAttack = ParamSpec<double>(
    id: 'gate.attack', section: 'gate', key: 'attack',
    type: ParamType.float, defaultValue: ParamDefaults.gateAttack,
    min: 1.0, max: 100.0, step: 1.0, unit: 'ms',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.gateAttackMs,
    setter: (m, v) => m.setGateAttack(v),
  );
  static final gateRelease = ParamSpec<double>(
    id: 'gate.release', section: 'gate', key: 'release',
    type: ParamType.float, defaultValue: ParamDefaults.gateRelease,
    min: 10.0, max: 500.0, step: 5.0, unit: 'ms',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.gateReleaseMs,
    setter: (m, v) => m.setGateRelease(v),
  );
  static final gateHysteresis = ParamSpec<double>(
    id: 'gate.hysteresis', section: 'gate', key: 'hysteresis',
    type: ParamType.float, defaultValue: ParamDefaults.gateHysteresis,
    min: 0.0, max: 12.0, step: 0.5, unit: 'dB',
    formatter: (v) => v.toStringAsFixed(1),
    getter: (m) => m.gateHysteresis,
    setter: (m, v) => m.setGateHysteresis(v),
  );
  static final gateRange = ParamSpec<double>(
    id: 'gate.range', section: 'gate', key: 'range',
    type: ParamType.float, defaultValue: ParamDefaults.gateRange,
    min: -80.0, max: 0.0, step: 1.0, unit: 'dB',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.gateRange,
    setter: (m, v) => m.setGateRange(v),
  );
  static final gateHoldMs = ParamSpec<double>(
    id: 'gate.hold', section: 'gate', key: 'hold',
    type: ParamType.float, defaultValue: ParamDefaults.gateHoldMs,
    min: 0.0, max: 500.0, step: 5.0, unit: 'ms',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.gateHoldMs,
    setter: (m, v) => m.setGateHoldMs(v),
  );
  static final gateAutoGain = ParamSpec<bool>(
    id: 'gate.autogain', section: 'gate', key: 'autoGain',
    type: ParamType.boolean, defaultValue: false,
    category: ParamCategory.outputGate,
    getter: (m) => m.gateAutoGain,
    setter: (m, v) => m.setGateAutoGain(v),
  );
  static final gateEnable = ParamSpec<bool>(
    id: 'gate.enable', section: 'gate', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.gateOn,
    setter: (m, v) => m.setGateEnabled(v),
  );

  /* =========================================================================
   * 11. 齿音消除 (Deesser)
   * ========================================================================= */
  static final deesserFreq = ParamSpec<double>(
    id: 'deesser.freq', section: 'deesser', key: 'freq',
    type: ParamType.float, defaultValue: ParamDefaults.deesserFreq,
    min: 2000.0, max: 10000.0, step: 50.0, unit: 'Hz',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.deesserFreq,
    setter: (m, v) => m.setDeesserFreq(v),
  );
  static final deesserAmount = ParamSpec<double>(
    id: 'deesser.amount', section: 'deesser', key: 'amount',
    type: ParamType.float, defaultValue: 0.5,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.deesserAmount,
    setter: (m, v) => m.setDeesserAmount(v),
  );
  static final deesserEnable = ParamSpec<bool>(
    id: 'deesser.enable', section: 'deesser', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.deesserOn,
    setter: (m, v) => m.setDeesserEnabled(v),
  );

  /* =========================================================================
   * 12. 动态均衡器 (Dynamic EQ: 3 Bands)
   * ========================================================================= */
  static final dyneqAttack = ParamSpec<double>(
    id: 'dyneq.attack', section: 'dyneq', key: 'attack',
    type: ParamType.float, defaultValue: 2.0,
    min: 1.0, max: 100.0, step: 1.0, unit: 'ms',
    getter: (m) => m.dyneqAttackMs,
    setter: (m, v) => m.setDyneqAttack(v),
  );
  static final dyneqRelease = ParamSpec<double>(
    id: 'dyneq.release', section: 'dyneq', key: 'release',
    type: ParamType.float, defaultValue: 120.0,
    min: 10.0, max: 500.0, step: 5.0, unit: 'ms',
    getter: (m) => m.dyneqReleaseMs,
    setter: (m, v) => m.setDyneqRelease(v),
  );
  static final dyneqB1Attack = ParamSpec<double>(
    id: 'dyneq.b1.attack', section: 'dyneq', subSection: 'low', key: 'attack',
    type: ParamType.float, defaultValue: ParamDefaults.dyneqB1Attack,
    min: 0.1, max: 100.0, step: 0.5, unit: 'ms',
    getter: (m) => m.dyneqB1Attack,
    setter: (m, v) => m.setDyneqB1Attack(v),
  );
  static final dyneqB1Release = ParamSpec<double>(
    id: 'dyneq.b1.release', section: 'dyneq', subSection: 'low', key: 'release',
    type: ParamType.float, defaultValue: ParamDefaults.dyneqB1Release,
    min: 10.0, max: 1000.0, step: 5.0, unit: 'ms',
    getter: (m) => m.dyneqB1Release,
    setter: (m, v) => m.setDyneqB1Release(v),
  );
  static final dyneqB2Attack = ParamSpec<double>(
    id: 'dyneq.b2.attack', section: 'dyneq', subSection: 'mid', key: 'attack',
    type: ParamType.float, defaultValue: ParamDefaults.dyneqB2Attack,
    min: 0.1, max: 100.0, step: 0.5, unit: 'ms',
    getter: (m) => m.dyneqB2Attack,
    setter: (m, v) => m.setDyneqB2Attack(v),
  );
  static final dyneqB2Release = ParamSpec<double>(
    id: 'dyneq.b2.release', section: 'dyneq', subSection: 'mid', key: 'release',
    type: ParamType.float, defaultValue: ParamDefaults.dyneqB2Release,
    min: 10.0, max: 1000.0, step: 5.0, unit: 'ms',
    getter: (m) => m.dyneqB2Release,
    setter: (m, v) => m.setDyneqB2Release(v),
  );
  static final dyneqB3Attack = ParamSpec<double>(
    id: 'dyneq.b3.attack', section: 'dyneq', subSection: 'high', key: 'attack',
    type: ParamType.float, defaultValue: ParamDefaults.dyneqB3Attack,
    min: 0.1, max: 100.0, step: 0.5, unit: 'ms',
    getter: (m) => m.dyneqB3Attack,
    setter: (m, v) => m.setDyneqB3Release(v),
  );
  static final dyneqB3Release = ParamSpec<double>(
    id: 'dyneq.b3.release', section: 'dyneq', subSection: 'high', key: 'release',
    type: ParamType.float, defaultValue: ParamDefaults.dyneqB3Release,
    min: 10.0, max: 1000.0, step: 5.0, unit: 'ms',
    getter: (m) => m.dyneqB3Release,
    setter: (m, v) => m.setDyneqB3Release(v),
  );
  // Low Band
  static final dyneqLowEnable = ParamSpec<bool>(
    id: 'dyneq.low.enable', section: 'dyneq', subSection: 'low', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 50,
    getter: (m) => m.dyneqLowOn,
    setter: (m, v) => m.setDyneqLowEnabled(v),
  );
  static final dyneqLowFreq = ParamSpec<double>(
    id: 'dyneq.low.freq', section: 'dyneq', subSection: 'low', key: 'freq',
    type: ParamType.float, defaultValue: 120.0,
    min: 20.0, max: 500.0, step: 1.0, unit: 'Hz',
    getter: (m) => m.dyneqLowFreq,
    setter: (m, v) => m.setDyneqLowFreq(v),
  );
  static final dyneqLowQ = ParamSpec<double>(
    id: 'dyneq.low.q', section: 'dyneq', subSection: 'low', key: 'q',
    type: ParamType.float, defaultValue: 0.707,
    min: 0.1, max: 10.0, step: 0.01,
    getter: (m) => m.dyneqLowQ,
    setter: (m, v) => m.setDyneqLowQ(v),
  );
  static final dyneqLowGain = ParamSpec<double>(
    id: 'dyneq.low.gain', section: 'dyneq', subSection: 'low', key: 'gain',
    type: ParamType.float, defaultValue: 0.0,
    min: -12.0, max: 12.0, step: 0.1, unit: 'dB',
    getter: (m) => m.dyneqLowGain,
    setter: (m, v) => m.setDyneqLowGain(v),
  );
  static final dyneqLowRange = ParamSpec<double>(
    id: 'dyneq.low.range', section: 'dyneq', subSection: 'low', key: 'range',
    type: ParamType.float, defaultValue: 6.0,
    min: 0.0, max: 24.0, step: 0.1, unit: 'dB',
    getter: (m) => m.dyneqLowRange,
    setter: (m, v) => m.setDyneqLowRange(v),
  );
  static final dyneqLowThreshold = ParamSpec<double>(
    id: 'dyneq.low.threshold', section: 'dyneq', subSection: 'low', key: 'threshold',
    type: ParamType.float, defaultValue: -30.0,
    min: -60.0, max: 0.0, step: 0.5, unit: 'dB',
    getter: (m) => m.dyneqLowThreshold,
    setter: (m, v) => m.setDyneqLowThreshold(v),
  );
  // Mid Band
  static final dyneqMidEnable = ParamSpec<bool>(
    id: 'dyneq.mid.enable', section: 'dyneq', subSection: 'mid', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 50,
    getter: (m) => m.dyneqMidOn,
    setter: (m, v) => m.setDyneqMidEnabled(v),
  );
  static final dyneqMidFreq = ParamSpec<double>(
    id: 'dyneq.mid.freq', section: 'dyneq', subSection: 'mid', key: 'freq',
    type: ParamType.float, defaultValue: 1000.0,
    min: 200.0, max: 5000.0, step: 10.0, unit: 'Hz',
    getter: (m) => m.dyneqMidFreq,
    setter: (m, v) => m.setDyneqMidFreq(v),
  );
  static final dyneqMidQ = ParamSpec<double>(
    id: 'dyneq.mid.q', section: 'dyneq', subSection: 'mid', key: 'q',
    type: ParamType.float, defaultValue: 1.0,
    min: 0.1, max: 10.0, step: 0.01,
    getter: (m) => m.dyneqMidQ,
    setter: (m, v) => m.setDyneqMidQ(v),
  );
  static final dyneqMidGain = ParamSpec<double>(
    id: 'dyneq.mid.gain', section: 'dyneq', subSection: 'mid', key: 'gain',
    type: ParamType.float, defaultValue: 0.0,
    min: -12.0, max: 12.0, step: 0.1, unit: 'dB',
    getter: (m) => m.dyneqMidGain,
    setter: (m, v) => m.setDyneqMidGain(v),
  );
  static final dyneqMidRange = ParamSpec<double>(
    id: 'dyneq.mid.range', section: 'dyneq', subSection: 'mid', key: 'range',
    type: ParamType.float, defaultValue: 6.0,
    min: 0.0, max: 24.0, step: 0.1, unit: 'dB',
    getter: (m) => m.dyneqMidRange,
    setter: (m, v) => m.setDyneqMidRange(v),
  );
  static final dyneqMidThreshold = ParamSpec<double>(
    id: 'dyneq.mid.threshold', section: 'dyneq', subSection: 'mid', key: 'threshold',
    type: ParamType.float, defaultValue: -30.0,
    min: -60.0, max: 0.0, step: 0.5, unit: 'dB',
    getter: (m) => m.dyneqMidThreshold,
    setter: (m, v) => m.setDyneqMidThreshold(v),
  );
  // High Band
  static final dyneqHighEnable = ParamSpec<bool>(
    id: 'dyneq.high.enable', section: 'dyneq', subSection: 'high', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 50,
    getter: (m) => m.dyneqHighOn,
    setter: (m, v) => m.setDyneqHighEnabled(v),
  );
  static final dyneqHighFreq = ParamSpec<double>(
    id: 'dyneq.high.freq', section: 'dyneq', subSection: 'high', key: 'freq',
    type: ParamType.float, defaultValue: 6000.0,
    min: 2000.0, max: 20000.0, step: 50.0, unit: 'Hz',
    getter: (m) => m.dyneqHighFreq,
    setter: (m, v) => m.setDyneqHighFreq(v),
  );
  static final dyneqHighQ = ParamSpec<double>(
    id: 'dyneq.high.q', section: 'dyneq', subSection: 'high', key: 'q',
    type: ParamType.float, defaultValue: 0.707,
    min: 0.1, max: 10.0, step: 0.01,
    getter: (m) => m.dyneqHighQ,
    setter: (m, v) => m.setDyneqHighQ(v),
  );
  static final dyneqHighGain = ParamSpec<double>(
    id: 'dyneq.high.gain', section: 'dyneq', subSection: 'high', key: 'gain',
    type: ParamType.float, defaultValue: 0.0,
    min: -12.0, max: 12.0, step: 0.1, unit: 'dB',
    getter: (m) => m.dyneqHighGain,
    setter: (m, v) => m.setDyneqHighGain(v),
  );
  static final dyneqHighRange = ParamSpec<double>(
    id: 'dyneq.high.range', section: 'dyneq', subSection: 'high', key: 'range',
    type: ParamType.float, defaultValue: 6.0,
    min: 0.0, max: 24.0, step: 0.1, unit: 'dB',
    getter: (m) => m.dyneqHighRange,
    setter: (m, v) => m.setDyneqHighRange(v),
  );
  static final dyneqHighThreshold = ParamSpec<double>(
    id: 'dyneq.high.threshold', section: 'dyneq', subSection: 'high', key: 'threshold',
    type: ParamType.float, defaultValue: -30.0,
    min: -60.0, max: 0.0, step: 0.5, unit: 'dB',
    getter: (m) => m.dyneqHighThreshold,
    setter: (m, v) => m.setDyneqHighThreshold(v),
  );
  static final dyneqEnable = ParamSpec<bool>(
    id: 'dyneq.enable', section: 'dyneq', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.dyneqOn,
    setter: (m, v) => m.setDyneqEnabled(v),
  );

  /* =========================================================================
   * 13. 响度补偿 (Loudness Contour)
   * ========================================================================= */
  static final loudnessAmount = ParamSpec<double>(
    id: 'loudness.amount', section: 'loudness', key: 'amount',
    type: ParamType.float, defaultValue: 0.5,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.loudnessAmount,
    setter: (m, v) => m.setLoudnessAmount(v),
  );
  static final loudnessEnable = ParamSpec<bool>(
    id: 'loudness.enable', section: 'loudness', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.loudnessOn,
    setter: (m, v) => m.setLoudnessEnabled(v),
  );

  /* =========================================================================
   * 14. 独立滤波器 (Filter)
   * ========================================================================= */
  static final filterType = ParamSpec<int>(
    id: 'filter.type', section: 'filter', key: 'type',
    type: ParamType.int32, defaultValue: ParamDefaults.filterType,
    min: 0, max: 2,
    options: ['高通 (HP)', '低通 (LP)', '带通 (BP)'],
    getter: (m) => m.filterType,
    setter: (m, v) => m.setFilterType(v),
  );
  static final filterFreq = ParamSpec<double>(
    id: 'filter.freq', section: 'filter', key: 'freq',
    type: ParamType.float, defaultValue: ParamDefaults.filterFreq,
    min: 20.0, max: 20000.0, step: 1.0, unit: 'Hz',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.filterFreq,
    setter: (m, v) => m.setFilterFreq(v),
  );
  static final filterQ = ParamSpec<double>(
    id: 'filter.q', section: 'filter', key: 'q',
    type: ParamType.float, defaultValue: ParamDefaults.filterQ,
    min: 0.1, max: 10.0, step: 0.01,
    getter: (m) => m.filterQ,
    setter: (m, v) => m.setFilterQ(v),
  );
  static final filterEnable = ParamSpec<bool>(
    id: 'filter.enable', section: 'filter', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.filterOn,
    setter: (m, v) => m.setFilterEnabled(v),
  );

  /* =========================================================================
   * 15. 脉冲响应卷积器 (Convolver)
   * ========================================================================= */
  static final convMix = ParamSpec<double>(
    id: 'convolver.mix', section: 'convolver', key: 'mix',
    type: ParamType.float, defaultValue: ParamDefaults.convMix,
    min: 0.0, max: 1.0, step: 0.01, unit: '%',
    formatter: (v) => (v * 100).toStringAsFixed(0),
    getter: (m) => m.convMix,
    setter: (m, v) {
      m.convMix = v;
      m.setFloat('convolver.mix', v);
    },
  );
  static final convEnable = ParamSpec<bool>(
    id: 'convolver.enable', section: 'convolver', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.convEnabled,
    setter: (m, v) => m.setConvolverEnabled(v),
  );

  /* =========================================================================
   * 16. DDC 耳机校准 (Digital Device Correction)
   * ========================================================================= */
  static final ddcEnable = ParamSpec<bool>(
    id: 'ddc.enable', section: 'ddc', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.ddcOn,
    setter: (m, v) => m.setDdcEnabled(v),
  );

  /* =========================================================================
   * 17. 动态压限器 (Compressor)
   * ========================================================================= */
  static final compTimeconstant = ParamSpec<double>(
    id: 'comp.timeconstant', section: 'comp', key: 'timeconstant',
    type: ParamType.float, defaultValue: 0.14,
    min: 0.01, max: 1.0, step: 0.01, unit: 's',
    getter: (m) => m.compTimeconstant,
    setter: (m, v) => m.setCompTimeconstant(v),
  );
  static final compGranularity = ParamSpec<int>(
    id: 'comp.granularity', section: 'comp', key: 'granularity',
    type: ParamType.int32, defaultValue: 1,
    min: 0, max: 2,
    getter: (m) => m.compGranularity,
    setter: (m, v) => m.setCompGranularity(v),
  );
  static final compTfresolution = ParamSpec<int>(
    id: 'comp.tfresolution', section: 'comp', key: 'tfresolution',
    type: ParamType.int32, defaultValue: 1,
    min: 0, max: 2,
    getter: (m) => m.compTfresolution,
    setter: (m, v) => m.setCompTfresolution(v),
  );
  static final compThreshold = ParamSpec<double>(
    id: 'comp.threshold', section: 'comp', key: 'threshold',
    type: ParamType.float, defaultValue: -18.0,
    min: -48.0, max: 0.0, step: 0.5, unit: 'dB',
    formatter: (v) => '${v.toStringAsFixed(1)} dB',
    getter: (m) => m.compThreshold,
    setter: (m, v) => m.setCompThreshold(v),
  );
  static final compRatio = ParamSpec<double>(
    id: 'comp.ratio', section: 'comp', key: 'ratio',
    type: ParamType.float, defaultValue: 4.0,
    min: 1.0, max: 20.0, step: 0.1, unit: ':1',
    formatter: (v) => '${v.toStringAsFixed(1)}:1',
    getter: (m) => m.compRatio,
    setter: (m, v) => m.setCompRatio(v),
  );
  static final compFreqs = List.generate(7, (i) {
    const defaults = [95.0, 200.0, 400.0, 800.0, 1600.0, 3400.0, 7500.0];
    return ParamSpec<double>(
      id: 'comp.freq${i + 1}', section: 'comp', key: 'freq${i + 1}',
      type: ParamType.float, defaultValue: defaults[i],
      min: 20.0, max: 20000.0, step: 1.0, unit: 'Hz',
      formatter: (v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)} kHz' : '${v.toStringAsFixed(0)} Hz',
      getter: (m) => m.compFreqs[i],
      setter: (m, v) => m.setCompFreq(i, v),
    );
  });
  static final compGains = List.generate(7, (i) {
    return ParamSpec<double>(
      id: 'comp.gain${i + 1}', section: 'comp', key: 'gain${i + 1}',
      type: ParamType.float, defaultValue: -0.35,
      min: -1.2, max: 1.2, step: 0.01,
      formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(2),
      getter: (m) => m.compGains[i],
      setter: (m, v) => m.setCompGain(i, v),
    );
  });
  static final compAutoGain = ParamSpec<bool>(
    id: 'comp.autogain', section: 'comp', key: 'autoGain',
    type: ParamType.boolean, defaultValue: ParamDefaults.compAutoGain,
    category: ParamCategory.outputGate,
    getter: (m) => m.compAutoGain,
    setter: (m, v) => m.setCompAutoGain(v),
  );
  static final compOutputGain = ParamSpec<double>(
    id: 'comp.outputgain', section: 'comp', key: 'outputGain',
    type: ParamType.float, defaultValue: ParamDefaults.compOutputGain,
    min: -12.0, max: 6.0, step: 0.1, unit: 'dB',
    category: ParamCategory.outputGate,
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.compOutputGain,
    setter: (m, v) => m.setCompOutputGain(v),
  );
  static final compEnable = ParamSpec<bool>(
    id: 'comp.enable', section: 'comp', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.compOn,
    setter: (m, v) => m.setCompEnabled(v),
  );

  /* =========================================================================
   * 18. 任意响应均衡 (ArbMag EQ)
   * ========================================================================= */
  static final arbmagString = ParamSpec<String>(
    id: 'arbmag.string', section: 'arbmag', key: 'string',
    type: ParamType.string, defaultValue: '',
    getter: (m) => m.arbmagString,
    setter: (m, v) {
      if (v.isNotEmpty) m.setArbmagString(v);
    },
  );
  static final arbmagAutoGain = ParamSpec<bool>(
    id: 'arbmag.autogain', section: 'arbmag', key: 'autoGain',
    type: ParamType.boolean, defaultValue: false,
    category: ParamCategory.outputGate,
    getter: (m) => m.arbmagAutoGain,
    setter: (m, v) => m.setArbmagAutoGain(v),
  );
  static final arbmagOutputGain = ParamSpec<double>(
    id: 'arbmag.outputgain', section: 'arbmag', key: 'outputGain',
    type: ParamType.float, defaultValue: 0.0,
    min: -12.0, max: 6.0, step: 0.1, unit: 'dB',
    category: ParamCategory.outputGate,
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.arbmagOutputGain,
    setter: (m, v) => m.setArbmagOutputGain(v),
  );
  static final arbmagEnable = ParamSpec<bool>(
    id: 'arbmag.enable', section: 'arbmag', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.arbmagOn && m.arbmagReady,
    setter: (m, v) => m.setArbmagEnabled(v),
  );

  /* =========================================================================
   * 19. 交叉反馈 (Crossfeed)
   * ========================================================================= */
  static final crossfeedFcut = ParamSpec<double>(
    id: 'crossfeed.fcut', section: 'crossfeed', key: 'fcut',
    type: ParamType.float, defaultValue: 700.0,
    min: 300.0, max: 2000.0, step: 10.0, unit: 'Hz',
    getter: (m) => m.xfeedFcut,
    setter: (m, v) => m.setCrossfeedFcut(v),
  );
  static final crossfeedFeed = ParamSpec<double>(
    id: 'crossfeed.feed', section: 'crossfeed', key: 'feed',
    type: ParamType.float, defaultValue: 4.5,
    min: 1.0, max: 15.0, step: 0.1, unit: 'dB',
    getter: (m) => m.xfeedFeed,
    setter: (m, v) => m.setCrossfeedFeed(v),
  );
  static final crossfeedMode = ParamSpec<int>(
    id: 'crossfeed.mode', section: 'crossfeed', key: 'mode',
    type: ParamType.int32, defaultValue: 0,
    min: 0, max: 3,
    order: 10,
    options: ['默认', 'Chu Moy', 'Jan Meier', '自定义'],
    getter: (m) => m.xfeedMode,
    setter: (m, v) => m.setCrossfeedMode(v),
  );
  static final crossfeedEnable = ParamSpec<bool>(
    id: 'crossfeed.enable', section: 'crossfeed', key: 'enable',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.xfeedOn,
    setter: (m, v) => m.setCrossfeedEnabled(v),
  );

  /* =========================================================================
   * 20. 动态编程脚本 (Liveprog EEL2)
   * ========================================================================= */
  static final liveprogEnabled = ParamSpec<bool>(
    id: 'liveprog.enable', section: 'liveprog', key: 'enabled',
    type: ParamType.boolean, defaultValue: false,
    order: 100,
    getter: (m) => m.lpEnabled,
    setter: (m, v) => m.setLiveprogEnabled(v),
  );
  static final liveprogCodeHash = ParamSpec<String>(
    id: 'liveprog.codeHash', section: 'liveprog', key: 'codeHash',
    type: ParamType.string, defaultValue: '',
    getter: (m) => _lpCodeHash(m.lpCode),
    setter: (m, v) => {}, // 由 apply 特殊对账消费
  );

  /* =========================================================================
   * 21. 后级增益与主限幅器 (Post Gain & Main Limiter)
   * ========================================================================= */
  static final postGain = ParamSpec<double>(
    id: 'post.gain', section: 'post', key: 'gain',
    type: ParamType.float, defaultValue: ParamDefaults.postGain,
    min: -15.0, max: 15.0, step: 0.1, unit: 'dB',
    formatter: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
    getter: (m) => m.postGain,
    setter: (m, v) => m.setFloat('post.gain', v),
  );
  static final postLimiterEnable = ParamSpec<bool>(
    id: 'limiter.enable', section: 'post', key: 'limiterEnable',
    type: ParamType.boolean, defaultValue: true,
    order: 100,
    getter: (m) => m.limiterOn,
    setter: (m, v) => m.setInt('limiter.enable', v ? 1 : 0),
  );
  static final limiterRelease = ParamSpec<double>(
    id: 'limiter.release', section: 'post', key: 'release',
    type: ParamType.float, defaultValue: ParamDefaults.limiterRelease,
    min: 5.0, max: 500.0, step: 5.0, unit: 'ms',
    formatter: (v) => v.toStringAsFixed(0),
    getter: (m) => m.limiterReleaseMs,
    setter: (m, v) => m.setLimiterRelease(v),
  );
  static final limiterThreshold = ParamSpec<double>(
    id: 'limiter.threshold', section: 'post', key: 'threshold',
    type: ParamType.float, defaultValue: ParamDefaults.limiterThreshold,
    min: -24.0, max: 0.0, step: 0.1, unit: 'dBFS',
    formatter: (v) => v.toStringAsFixed(1),
    getter: (m) => m.limiterThreshold,
    setter: (m, v) => m.setLimiterThreshold(v),
  );
  static final limiterLink = ParamSpec<bool>(
    id: 'limiter.link', section: 'post', key: 'link',
    type: ParamType.boolean, defaultValue: true,
    getter: (m) => m.limiterLink,
    setter: (m, v) => m.setLimiterLink(v),
  );
  static final limiterLookahead = ParamSpec<bool>(
    id: 'limiter.lookahead', section: 'post', key: 'lookahead',
    type: ParamType.boolean, defaultValue: true,
    getter: (m) => m.limiterLookahead,
    setter: (m, v) => m.setLimiterLookahead(v),
  );

  /* =========================================================================
   * 22. 音频路由与设备配置 (Audio Routing & Endpoints)
   * ========================================================================= */
  static final routingModeCategory = ParamSpec<String>(
    id: 'routing.modeCategory', section: 'routing', key: 'modeCategory',
    type: ParamType.string, defaultValue: 'pipeline',
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.modeCategory,
    setter: (m, v) => {},
  );
  static final routingAttachmentMode = ParamSpec<String>(
    id: 'routing.attachmentMode', section: 'routing', key: 'attachmentMode',
    type: ParamType.string, defaultValue: 'sysapo',
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.attachmentMode,
    setter: (m, v) => {},
  );
  static final routingPipelineInput = ParamSpec<String>(
    id: 'routing.pipelineInput', section: 'routing', key: 'pipelineInput',
    type: ParamType.string, defaultValue: 'wasapi',
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.pipelineInput,
    setter: (m, v) => {},
  );
  static final routingPipelineOutput = ParamSpec<String>(
    id: 'routing.pipelineOutput', section: 'routing', key: 'pipelineOutput',
    type: ParamType.string, defaultValue: 'wasapi',
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.pipelineOutput,
    setter: (m, v) => {},
  );
  static final routingPipelineInputDevice = ParamSpec<String>(
    id: 'routing.pipelineInputDevice', section: 'routing', key: 'pipelineInputDevice',
    type: ParamType.string, defaultValue: '',
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.pipelineInputDevice,
    setter: (m, v) => m.setPipelineInputDevice(v),
  );
  static final routingPipelineOutputDevice = ParamSpec<String>(
    id: 'routing.pipelineOutputDevice', section: 'routing', key: 'pipelineOutputDevice',
    type: ParamType.string, defaultValue: '',
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.pipelineOutputDevice,
    setter: (m, v) => m.setPipelineOutputDevice(v),
  );
  static final routingPipelineInputEnabled = ParamSpec<bool>(
    id: 'routing.pipelineInputEnabled', section: 'routing', key: 'pipelineInputEnabled',
    type: ParamType.boolean, defaultValue: true,
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.pipelineInputEnabled,
    setter: (m, v) => m.setPipelineInputEnabled(v),
  );
  static final routingPipelineOutputEnabled = ParamSpec<bool>(
    id: 'routing.pipelineOutputEnabled', section: 'routing', key: 'pipelineOutputEnabled',
    type: ParamType.boolean, defaultValue: true,
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.pipelineOutputEnabled,
    setter: (m, v) => m.setPipelineOutputEnabled(v),
  );
  static final routingAsioDriver = ParamSpec<String>(
    id: 'routing.asioDriver', section: 'routing', key: 'asioDriver',
    type: ParamType.string, defaultValue: '',
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.asioDriver,
    setter: (m, v) => m.setAsioDriver(v),
  );
  static final routingAsioBufSize = ParamSpec<int>(
    id: 'routing.asioBufSize', section: 'routing', key: 'asioBufSize',
    type: ParamType.int32, defaultValue: 0,
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.asioBufSize,
    setter: (m, v) => m.setAsioBufSize(v),
  );
  static final routingAsioOutPair = ParamSpec<int>(
    id: 'routing.asioOutPair', section: 'routing', key: 'asioOutPair',
    type: ParamType.int32, defaultValue: 0,
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.asioOutPair,
    setter: (m, v) => m.setAsioOutPair(v),
  );
  static final routingVaioOutputEndpoint = ParamSpec<String>(
    id: 'routing.vaioOutputEndpoint', section: 'routing', key: 'vaioOutputEndpoint',
    type: ParamType.string, defaultValue: '',
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.vaioOutputEndpoint,
    setter: (m, v) => m.setVaioOutputEndpoint(v),
  );
  static final routingApoTargetEndpoint = ParamSpec<String>(
    id: 'routing.apoTargetEndpoint', section: 'routing', key: 'apoTargetEndpoint',
    type: ParamType.string, defaultValue: '',
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.apoTargetEndpoint,
    setter: (m, v) => m.setApoTargetEndpoint(v),
  );
  static final routingMonitorMirroring = ParamSpec<bool>(
    id: 'routing.monitorMirroring', section: 'routing', key: 'monitorMirroring',
    type: ParamType.boolean, defaultValue: false,
    flags: ParamFlags.presetSerializable | ParamFlags.sessionOnly,
    getter: (m) => m.config.monitorMirroring,
    setter: (m, v) => m.setMonitorMirroring(v),
  );

  /* =========================================================================
   * 全量处理节登记表 (Ordered Sections)
   * ========================================================================= */
  static final List<ParamSection> sections = [
    // 0. 输入
    ParamSection(
      name: 'input',
      specs: [inputGain, inputBalanceL, inputBalanceR],
    ),
    // 1. 低音
    ParamSection(
      name: 'bass',
      specs: [
        bassIntensity, bassMode, bassCutoff, bassHarmonics, bassHarmonicBlend,
        bassSubFloor, bassGain, bassAutoGain, bassOutputGain, bassEnable,
      ],
    ),
    // 2. 混响
    ParamSection(
      name: 'reverb',
      specs: [
        reverbPreset, reverbDecay, reverbDamp, reverbWet, reverbDry,
        reverbRoomSize, reverbStereoWidth, reverbAutoGain, reverbOutputGain, reverbEnable,
      ],
      postApply: (m, rev, fullRewrite) {
        // 自定义混响保护逻辑：preset >= 0 切预设，-1 缺键不碰现值
        final pr = (rev['preset'] as num?)?.toInt() ?? -1;
        if (pr >= 0) {
          m.setReverbPreset(pr);
        } else {
          if (rev['decay'] != null) m.setReverbCustomParam('decay', (rev['decay'] as num).toDouble());
          if (rev['damp'] != null) m.setReverbCustomParam('damp', (rev['damp'] as num).toDouble());
          if (rev['wet'] != null) m.setReverbCustomParam('wet', (rev['wet'] as num).toDouble());
          if (rev['dry'] != null) m.setReverbCustomParam('dry', (rev['dry'] as num).toDouble());
          if (rev['roomSize'] != null) m.setReverbCustomParam('roomSize', (rev['roomSize'] as num).toDouble());
          if (rev['stereoWidth'] != null) m.setReverbCustomParam('width', (rev['stereoWidth'] as num).toDouble());
        }
      },
    ),
    // 3. 电子管
    ParamSection(
      name: 'tube',
      specs: [
        tubeGain, tubeStyle, tubeCompensation, tubeMix,
        tubeAutoGain, tubeOutputGain, tubeOversample, tubeEnable,
      ],
    ),
    // 4. 均衡器
    ParamSection(
      name: 'eq',
      specs: [
        eqBandsCount, eqQ, eqFilter, eqInterp, eqPresetName, eqBypass,
        eqAutoGain, eqOutputGain, eqEnable,
      ],
      customSnapshot: (m, map) {
        map['frequencies'] = List<double>.of(m.eqFrequencies);
        map['gains'] = List<double>.of(m.eqGains);
        map['qs'] = List<double>.of(m.eqQs);
      },
      postApply: (m, eq, fullRewrite) {
        final presetFreqs = (eq['frequencies'] as List?)
            ?.map((e) => (e as num).toDouble())
            .toList();
        if (eq['qs'] is List) {
          final qs = (eq['qs'] as List).map((e) => (e as num).toDouble()).toList();
          m.applyEqQs(presetFreqs, qs);
        } else if (eq['q'] != null) {
          m.fillEqQ((eq['q'] as num).toDouble());
        }
        if (eq['gains'] is List) {
          final list = (eq['gains'] as List).map((e) => (e as num).toDouble()).toList();
          final freqs = (eq['frequencies'] as List?)
              ?.map((e) => (e as num).toDouble()).toList();
          if (freqs != null && freqs.length == list.length && freqs.isNotEmpty) {
            m.applyEqCurve(freqs, list);
          } else {
            m.applyEqGains(list);
          }
        }
      },
    ),
    // 5. 立体声
    ParamSection(
      name: 'stereo',
      specs: [stereoMix, stereoBandUsed, stereoOn],
      customApplyOnly: true,
      customSnapshot: (m, map) {
        map['bands'] = List<double>.of(m.stereoBands);
      },
      postApply: (m, st, fullRewrite) {
        final mixVal = (st['mix'] as num?)?.toDouble();
        if (st['on'] != null) {
          m.stereoOn = st['on'] as bool;
        } else if (mixVal != null) {
          m.stereoOn = mixVal > 0.0;
        }
        if (st['bands'] is List) {
          final bands = (st['bands'] as List).map((e) => (e as num).toDouble()).toList();
          for (var i = 0; i < bands.length && i < 5; i++) {
            m.stereoBands[i] = bands[i].clamp(0.0, 1.0);
          }
        }
        if (st['mix'] != null) {
          m.setStereoMix((st['mix'] as num).toDouble());
        } else if (st['bands'] is List) {
          for (var i = 0; i < 5; i++) {
            m.setStereoBand(i, m.stereoBands[i]);
          }
        }
        if (st['bandUsed'] != null) {
          m.stereoBandUsed = st['bandUsed'] as bool;
        }
      },
    ),
    // 6. 搁架
    ParamSection(
      name: 'shelf',
      specs: [shelfFreq, shelfGain, shelfEnable],
    ),
    // 7. 低频单声道
    ParamSection(
      name: 'bassmono',
      specs: [bassmonoFreq, bassmonoEnable],
    ),
    // 8. Haas
    ParamSection(
      name: 'haas',
      specs: [haasDelay, haasMix, haasSide, haasEnable],
    ),
    // 9. 激励器
    ParamSection(
      name: 'exciter',
      specs: [exciterAmount, exciterHifreq, exciterOversample, exciterEnable],
    ),
    // 9B. 空间音效
    ParamSection(
      name: 'spatial',
      specs: [
        spatialStyle, spatialRoom, spatialWidth, spatialCenter,
        spatialOutGain, spatialAutoGain, spatialMix, spatialElevation,
        spatialBinaural, spatialHeadAzim, spatialHeadTrack, spatialEnable,
      ],
    ),
    // 10. 噪声门
    ParamSection(
      name: 'gate',
      specs: [
        gateThreshold, gateAttack, gateRelease,
        gateHysteresis, gateRange, gateHoldMs,
        gateAutoGain, gateEnable,
      ],
    ),
    // 11. 齿音消除
    ParamSection(
      name: 'deesser',
      specs: [deesserFreq, deesserAmount, deesserEnable],
    ),
    // 12. 动态均衡
    ParamSection(
      name: 'dyneq',
      specs: [
        dyneqAttack, dyneqRelease,
        dyneqB1Attack, dyneqB1Release,
        dyneqB2Attack, dyneqB2Release,
        dyneqB3Attack, dyneqB3Release,
        dyneqLowEnable, dyneqLowFreq, dyneqLowQ, dyneqLowGain, dyneqLowRange, dyneqLowThreshold,
        dyneqMidEnable, dyneqMidFreq, dyneqMidQ, dyneqMidGain, dyneqMidRange, dyneqMidThreshold,
        dyneqHighEnable, dyneqHighFreq, dyneqHighQ, dyneqHighGain, dyneqHighRange, dyneqHighThreshold,
        dyneqEnable,
      ],
    ),
    // 13. 响度补偿
    ParamSection(
      name: 'loudness',
      specs: [loudnessAmount, loudnessEnable],
    ),
    // 14. 独立滤波
    ParamSection(
      name: 'filter',
      specs: [filterType, filterFreq, filterQ, filterEnable],
    ),
    // 15. 卷积器
    ParamSection(
      name: 'convolver',
      specs: [convMix, convEnable],
    ),
    // 16. DDC
    ParamSection(
      name: 'ddc',
      specs: [ddcEnable],
    ),
    // 17. 压缩器
    ParamSection(
      name: 'comp',
      specs: [
        compTimeconstant, compGranularity, compTfresolution,
        compAutoGain, compOutputGain, compEnable,
      ],
    ),
    // 18. ArbMag
    ParamSection(
      name: 'arbmag',
      specs: [arbmagString, arbmagAutoGain, arbmagOutputGain, arbmagEnable],
    ),
    // 19. 交叉反馈
    ParamSection(
      name: 'crossfeed',
      specs: [crossfeedFcut, crossfeedFeed, crossfeedMode, crossfeedEnable],
    ),
    // 20. 脚本
    ParamSection(
      name: 'liveprog',
      specs: [liveprogEnabled, liveprogCodeHash],
      customApplyOnly: true,
      customSnapshot: (m, map) {
        map['params'] = List<double>.of(m.lpParams);
      },
      postApply: (m, lp, fullRewrite) {
        if (lp.isNotEmpty) {
          if (lp['params'] is List) {
            final saved = (lp['params'] as List).map((e) => (e as num).toDouble()).toList();
            for (var i = 0; i < saved.length && i < 8; i++) {
              m.lpParams[i] = saved[i];
            }
          }
          if (lp['enabled'] != null) m.lpEnabled = lp['enabled'] as bool;
          final savedHash = lp['codeHash'] as String?;
          m.lpPresetCodeMismatch = savedHash != null &&
              savedHash.isNotEmpty &&
              savedHash != _lpCodeHash(m.lpCode);
          m.setLiveprogEnabled(m.lpEnabled);
          for (var i = 0; i < 8; i++) {
            m.setLiveprogParam(i, m.lpParams[i]);
          }
        }
      },
    ),
    // 21. 后级
    ParamSection(
      name: 'post',
      specs: [
        postGain, postLimiterEnable,
        limiterRelease, limiterThreshold, limiterLink, limiterLookahead,
      ],
    ),
    // 22. 路由
    ParamSection(
      name: 'routing',
      specs: [
        routingModeCategory, routingAttachmentMode, routingPipelineInput,
        routingPipelineOutput, routingPipelineInputDevice, routingPipelineOutputDevice,
        routingPipelineInputEnabled, routingPipelineOutputEnabled,
        routingAsioDriver, routingAsioBufSize, routingAsioOutPair,
        routingVaioOutputEndpoint, routingApoTargetEndpoint, routingMonitorMirroring,
      ],
      customApplyOnly: true,
      postApply: (m, routing, fullRewrite) {
        if (routing.isEmpty) return;
        if (routing['pipelineInputEnabled'] is bool) {
          m.setPipelineInputEnabled(routing['pipelineInputEnabled'] as bool);
        }
        if (routing['pipelineOutputEnabled'] is bool) {
          m.setPipelineOutputEnabled(routing['pipelineOutputEnabled'] as bool);
        }
        if (routing['monitorMirroring'] is bool) {
          m.setMonitorMirroring(routing['monitorMirroring'] as bool);
        }
        if (routing['pipelineInputDevice'] is String) {
          final dev = routing['pipelineInputDevice'] as String;
          final exists = dev.isNotEmpty &&
              m.wasapiDevices.any((d) => !d.isRender && (d.id == dev || d.name == dev));
          m.setPipelineInputDevice(exists ? dev : '');
        }
        if (routing['pipelineOutputDevice'] is String) {
          final dev = routing['pipelineOutputDevice'] as String;
          final exists = dev.isNotEmpty &&
              m.wasapiDevices.any((d) => d.isRender && (d.id == dev || d.name == dev));
          m.setPipelineOutputDevice(exists ? dev : '');
        }
        if (routing['vaioOutputEndpoint'] is String) {
          final ep = routing['vaioOutputEndpoint'] as String;
          final exists = ep.isNotEmpty &&
              m.vaioPhysicalEndpoints.any((d) => d.name == ep || d.id == ep);
          m.setVaioOutputEndpoint(exists ? ep : '');
        }
        if (routing['apoTargetEndpoint'] is String) {
          final ep = routing['apoTargetEndpoint'] as String;
          final exists = ep.isNotEmpty &&
              (m.vaioPhysicalEndpoints.any((d) => d.name == ep || d.id == ep) ||
                  m.wasapiDevices.any((d) => d.id == ep || d.name == ep));
          m.setApoTargetEndpoint(exists ? ep : '');
        }
        if (routing['asioDriver'] is String) {
          final drv = routing['asioDriver'] as String;
          final names = [for (final d in m.asioDrivers) d['name'] ?? ''];
          final exists = drv.isNotEmpty && names.contains(drv);
          m.setAsioDriver(exists ? drv : (names.isNotEmpty ? names.first : ''));
        }
        if (routing['asioBufSize'] is num) {
          m.setAsioBufSize((routing['asioBufSize'] as num).toInt());
        }
        if (routing['asioOutPair'] is num) {
          m.setAsioOutPair((routing['asioOutPair'] as num).toInt());
        }
      },
    ),
  ];

  static final Map<String, ParamSection> bySection = {
    for (final s in sections) s.name: s,
  };

  static final List<ParamSpec> allParams = [
    for (final s in sections) ...s.specs,
  ];

  static final Map<String, ParamSpec> byId = {
    for (final p in allParams) p.id: p,
  };

  /// 辅助计算脚本代码 FNV-1a 哈希
  static String _lpCodeHash(String? code) {
    if (code == null || code.isEmpty) return '';
    var h = 0x811C9DC5;
    for (var i = 0; i < code.length; i++) {
      h ^= code.codeUnitAt(i);
      h = (h * 0x01000193) & 0xFFFFFFFF;
    }
    return h.toRadixString(16).padLeft(8, '0');
  }
}
