/*
 * effect_registry.dart — 处理链阶段唯一事实源（P1/F-01）
 *
 * 背景：链序、链组、电平表槽位、延迟探针支持集此前分别散落在
 * chain_page.dart / state_chain.dart / state.dart / state_events.dart。
 * 新增或调整一个 stage 需要同步 5 张表，漏改即出现「拖拽顺序错位」
 * 「组旁路漏项」「PDI 探针假接通」等隐性故障。
 *
 * 约定：新增 stage 只能在此登记一次；所有列表（UI 顺序、链组、电平表、
 * 全链路延迟、探针支持集）均由本表派生，禁止再建镜像。
 */

/// 单个处理阶段的静态契约。
class EffectStageSpec {
  /// 引擎 stage id（与 C++ kAuraStages / 参数前缀一致）。
  final String id;

  /// 链组 id（chInput/chTone/chEq/chSound/chSpatial/chOut）。
  final String group;

  /// 双声道电平表槽位（-1 表示无表）。
  final int meterIndex;

  /// 是否支持引擎脉冲探针实测（false 时 UI 不显示 ↻）。
  final bool probeSupported;

  /// 是否计入 fullChainLatencyMs 的算法延迟求和。
  final bool countInFullChain;

  /// 默认链序位置（null = 不进入默认链序，如 output）。
  final int? defaultOrder;

  /// 是否对外暴露（保留字段，当前全部 true）。
  final bool exposed;

  const EffectStageSpec({
    required this.id,
    required this.group,
    required this.meterIndex,
    this.probeSupported = false,
    this.countInFullChain = true,
    this.defaultOrder,
    this.exposed = true,
  });
}

/// 全部 stage（顺序与引擎 kAuraStages / 历史 kStageMeta 一致）。
const List<EffectStageSpec> kEffectRegistry = [
  EffectStageSpec(
    id: 'gate',
    group: 'chInput',
    meterIndex: 13,
    probeSupported: true,
    defaultOrder: 0,
  ),
  EffectStageSpec(
    id: 'dyneq',
    group: 'chTone',
    meterIndex: 14,
    probeSupported: true,
    defaultOrder: 2,
  ),
  EffectStageSpec(
    id: 'filter',
    group: 'chInput',
    meterIndex: 15,
    probeSupported: true,
    defaultOrder: 1,
  ),
  EffectStageSpec(
    id: 'bassmono',
    group: 'chTone',
    meterIndex: 16,
    // bassmono 在引擎侧可探针，但 UI 只通过 bass_shaping 别名刷新，
    // 不单独显示 ↻；保持与原支持集一致。
    defaultOrder: 3,
  ),
  EffectStageSpec(
    id: 'tube',
    group: 'chTone',
    meterIndex: 0,
    probeSupported: true,
    defaultOrder: 4,
  ),
  EffectStageSpec(
    id: 'comp',
    group: 'chTone',
    meterIndex: 1,
    probeSupported: true,
    defaultOrder: 5,
  ),
  EffectStageSpec(
    id: 'bass',
    group: 'chTone',
    meterIndex: 2,
    probeSupported: true,
    defaultOrder: 6,
  ),
  EffectStageSpec(
    id: 'eq',
    group: 'chEq',
    meterIndex: 3,
    probeSupported: true,
    defaultOrder: 7,
  ),
  EffectStageSpec(
    id: 'arbmag',
    group: 'chEq',
    meterIndex: 4,
    probeSupported: true,
    defaultOrder: 8,
  ),
  EffectStageSpec(
    id: 'convolver',
    group: 'chEq',
    meterIndex: 5,
    probeSupported: true,
    defaultOrder: 9,
  ),
  EffectStageSpec(
    id: 'ddc',
    group: 'chEq',
    meterIndex: 6,
    probeSupported: true,
    defaultOrder: 10,
  ),
  EffectStageSpec(
    id: 'liveprog',
    group: 'chEq',
    meterIndex: 7,
    countInFullChain: false,
    defaultOrder: 11,
  ),
  EffectStageSpec(
    id: 'crossfeed',
    group: 'chSound',
    meterIndex: 8,
    probeSupported: true,
    defaultOrder: 12,
  ),
  EffectStageSpec(
    id: 'stereo',
    group: 'chSound',
    meterIndex: 9,
    probeSupported: true,
    defaultOrder: 13,
  ),
  EffectStageSpec(
    id: 'haas',
    group: 'chSound',
    meterIndex: 17,
    probeSupported: true,
    defaultOrder: 14,
  ),
  EffectStageSpec(
    id: 'spatial',
    group: 'chSpatial',
    meterIndex: 20,
    probeSupported: true,
    defaultOrder: 15,
  ),
  EffectStageSpec(
    id: 'exciter',
    group: 'chOut',
    meterIndex: 18,
    probeSupported: true,
    defaultOrder: 16,
  ),
  EffectStageSpec(
    id: 'loudness',
    group: 'chOut',
    meterIndex: 19,
    probeSupported: true,
    defaultOrder: 18,
  ),
  EffectStageSpec(
    id: 'reverb',
    // 历史分组：reverb 一直归「输出」组（badge 也显示 Output），
    // 不是空间组；改组会改变整组旁路语义，F-01 只做去重不改行为。
    group: 'chOut',
    meterIndex: 10,
    probeSupported: true,
    defaultOrder: 17,
  ),
  EffectStageSpec(
    id: 'output',
    group: 'chOut',
    meterIndex: 11,
    countInFullChain: false,
  ),
];

/// 非 stage 的探针 id：限幅器常驻，post 与 output 共用限幅器探针。
const List<String> kLatencyProbeExtras = ['limiter', 'post'];

/// 合并卡 → 引擎实名探针（逐段实测求和）。
const Map<String, List<String>> kLatencyProbeAliases = {
  'bass_shaping': ['shelf', 'bassmono'],
};

/// UI stage 元数据（派生）。
final List<({String id, bool exposed})> kStageMeta = [
  for (final e in kEffectRegistry) (id: e.id, exposed: e.exposed),
];

/// 默认链序（派生；output 不参与，顺序由 defaultOrder 决定）。
final List<String> kDefaultCoreOrder = () {
  final ordered = [
    for (final e in kEffectRegistry)
      if (e.defaultOrder != null) e,
  ]..sort((a, b) => a.defaultOrder!.compareTo(b.defaultOrder!));
  return [for (final e in ordered) e.id];
}();

/// 链组成员（派生；组顺序 = 组内首个 stage 在 registry 中出现顺序）。
final Map<String, List<String>> kChainGroups = () {
  final groups = <String, List<String>>{};
  for (final e in kEffectRegistry) {
    groups.putIfAbsent(e.group, () => []).add(e.id);
  }
  return groups;
}();

/// stage 查表（O(1)）。
final Map<String, EffectStageSpec> kEffectStageById = {
  for (final e in kEffectRegistry) e.id: e,
};

/// 全链路算法延迟求和的 stage 集（派生）。
final List<String> kFullChainStageIds = [
  for (final e in kEffectRegistry)
    if (e.countInFullChain) e.id,
];

/// 全部探针 id（stage 支持集 + 非 stage 常驻探针）。
final List<String> kLatencyProbeIds = [
  for (final e in kEffectRegistry)
    if (e.probeSupported) e.id,
  ...kLatencyProbeExtras,
];
