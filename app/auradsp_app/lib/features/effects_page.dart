/*
 * effects_page.dart — 控制页：对齐 engine_api 参数模型 v1
 *
 * 规范落地：
 * - Phase 1: 视觉降噪与术语规整，废除品质档拦截
 * - Phase 2: 空间混响二合一，双向状态机联动，3D 声学室动态尺寸映射
 * - Phase 3: 多段交互式 EQ 频谱面板与发光 Q 旋钮
 * - Phase 4: 低音重构（谐波注入）、电子管模拟器卡片与组件级微型延迟徽标
 */
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

import '../core/channel_layout.dart';
import '../core/debug/debug_trace.dart';
import '../core/design.dart';
import '../core/nav.dart';
import '../core/param_schema.dart';
import '../core/io/resource_gate.dart';
import '../core/path_memory.dart';
import '../core/presets.dart';
import '../core/notice.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../platform/adapters.dart';
import '../core/ui_helpers.dart';
import '../engine/auradsp_ffi.dart' show kVizChannelMax;
import '../l10n/gen/app_localizations.dart';
import 'chrome.dart';
import 'interactive_eq.dart';
import 'widgets.dart';

part 'effects/input_card.dart';
part 'effects/gate_card.dart';
part 'effects/dyneq_card.dart';
part 'effects/filter_card.dart';
part 'effects/comp_card.dart';
part 'effects/bass_card.dart';
part 'effects/cards_common.dart';
part 'effects/reverb_card.dart';
part 'effects/bass_shaping_card.dart';
part 'effects/convolver_card.dart';
part 'effects/ddc_card.dart';
part 'effects/eq_card.dart';
part 'effects/arbmag_card.dart';
part 'effects/crossfeed_card.dart';
part 'effects/stereo_card.dart';
  part 'effects/haas_card.dart';
  part 'effects/spatial_card.dart';
part 'effects/exciter_card.dart';
part 'effects/loudness_card.dart';
part 'effects/tube_card.dart';
part 'effects/post_card.dart';
part 'effects/preset_card.dart';
part 'effects/channel_routing_selector.dart';
part 'effects/pair_route_selector.dart';
part 'effects/gain_reduction_meter.dart';

/// 单张效果卡的元数据：分类、类内序号、构造函数（P1/F-03 单一事实源）。
///
/// [category] 为 null 表示"共享卡别名"（如 bassmono/shelf 复用低音塑形卡），
/// 只用于 [kEffectCardIndex] 查序号，不进入分类列表。
/// [index] 为 null 表示该类不编号（空间卡）。
class _EffectCardSpec {
  final String id;
  final String? category;
  final String? index;
  final Widget Function(AppModel) builder;

  const _EffectCardSpec(this.id, this.category, this.index, this.builder);
}

// ---- 卡片构造器（switch 分支收敛为表驱动）------------------------------
Widget _buildInputCard(AppModel m) => _InputCard(model: m);
Widget _buildGateCard(AppModel m) => _GateCard(model: m);
Widget _buildFilterCard(AppModel m) => _FilterCard(model: m);
Widget _buildBassShapingCard(AppModel m) => _BassShapingCard(model: m);
Widget _buildCompressorCard(AppModel m) => _CompressorCard(model: m);
Widget _buildDyneCard(AppModel m) => _DyneCard(model: m);
Widget _buildLoudnessCard(AppModel m) => _LoudnessCard(model: m);
Widget _buildBassCard(AppModel m) => _BassCard(model: m);
Widget _buildEqualizerCard(AppModel m) => _EqualizerCard(model: m);
Widget _buildArbmagCard(AppModel m) => _ArbmagCard(model: m);
Widget _buildStereoCard(AppModel m) => _StereoCard(model: m);
Widget _buildCrossfeedCard(AppModel m) => _CrossfeedCard(model: m);
Widget _buildHaasCard(AppModel m) => _HaasCard(model: m);
Widget _buildConvolverCard(AppModel m) => _ConvolverCard(model: m);
Widget _buildDdcCard(AppModel m) => _DdcCard(model: m);
Widget _buildSpatialCard(AppModel m) => _SpatialCard(model: m);
Widget _buildSpatialReverbCard(AppModel m) => _SpatialReverbCard(model: m);
Widget _buildExciterCard(AppModel m) => _ExciterCard(model: m);
Widget _buildTubeCard(AppModel m) => _TubeCard(model: m);
Widget _buildPostCard(AppModel m) => _PostCard(model: m);

/// 效果器卡片序号**单一真相**：**每类内**从 1 纯数字递增（类由标题行下拉
/// 标明，卡片序号只在本类内计数，故无前缀）。空间卡单独成类、不编号。
///
/// 历史坑：序号原本硬编码在 20 个卡片文件里、各写各的，结果出现 5 个 '00'
/// （input/gate/filter/dyneq 都算 0 号）、2 个 '02'、2 个 '06'，新增或调整
/// 卡片时也无人同步——用户看到的就是「序号全是乱的」。
/// 现在只允许改这一处；卡片侧一律写 `index: kEffectCardIndex['<id>']`。
/// 空间卡去编号（index 传 null，含其内部 5 张搬入子卡）。
///
/// 注意：这是**页面分区序号**，不是处理链顺序。链上顺序见 ChainPage 的
/// kDefaultCoreOrder 与「处理顺序」页，两者不必相同。
const List<_EffectCardSpec> _effectCards = [
  // 前置整形（front）
  _EffectCardSpec('input', 'front', '1', _buildInputCard),
  _EffectCardSpec('gate', 'front', '2', _buildGateCard),
  _EffectCardSpec('filter', 'front', '3', _buildFilterCard),
  _EffectCardSpec('bass_shaping', 'front', '4', _buildBassShapingCard),
  // 共享卡别名：bassmono/shelf 复用低音塑形卡（同序号，不入分类）
  _EffectCardSpec('bassmono', null, '4', _buildBassShapingCard),
  _EffectCardSpec('shelf', null, '4', _buildBassShapingCard),
  // 核心处理（core）
  _EffectCardSpec('comp', 'core', '1', _buildCompressorCard),
  _EffectCardSpec('dyneq', 'core', '2', _buildDyneCard),
  _EffectCardSpec('loudness', 'core', '3', _buildLoudnessCard),
  _EffectCardSpec('bass', 'core', '4', _buildBassCard),
  _EffectCardSpec('eq', 'core', '5', _buildEqualizerCard),
  _EffectCardSpec('arbmag', 'core', '6', _buildArbmagCard),
  // 立体声专用（stereo_only）
  _EffectCardSpec('stereo', 'stereo_only', '1', _buildStereoCard),
  _EffectCardSpec('crossfeed', 'stereo_only', '2', _buildCrossfeedCard),
  _EffectCardSpec('haas', 'stereo_only', '3', _buildHaasCard),
  _EffectCardSpec('convolver', 'stereo_only', '4', _buildConvolverCard),
  _EffectCardSpec('ddc', 'stereo_only', '5', _buildDdcCard),
  // 空间效果（spatial）：单独成类，不编号
  _EffectCardSpec('spatial', 'spatial', null, _buildSpatialCard),
  _EffectCardSpec('reverb', 'spatial', null, _buildSpatialReverbCard),
  // 激励与输出（late）
  _EffectCardSpec('exciter', 'late', '1', _buildExciterCard),
  _EffectCardSpec('tube', 'late', '2', _buildTubeCard),
  _EffectCardSpec('post', 'late', '3', _buildPostCard),
];

/// 卡片 id → 类内序号（由 [_effectCards] 派生，禁止另行手写）。
final Map<String, String?> kEffectCardIndex = {
  for (final e in _effectCards) e.id: e.index,
};

/// 效果分类（标题行右侧下拉过滤；无"全部"，按类分页展示）。
/// 顺序 = [_effectCards] 中分类首次出现顺序（front→core→stereo_only→
/// spatial→late），下拉项直接消费该顺序。
final Map<String, List<String>> kEffectCategories = () {
  final categories = <String, List<String>>{};
  for (final e in _effectCards) {
    final category = e.category;
    if (category == null) continue;
    categories.putIfAbsent(category, () => []).add(e.id);
  }
  return categories;
}();

final Map<String, _EffectCardSpec> _effectCardById = {
  for (final e in _effectCards) e.id: e,
};

class EffectsPage extends StatelessWidget {
  final AppModel model;
  const EffectsPage({super.key, required this.model});

  String _categoryLabel(AppLocalizations l, String id) {
    return switch (id) {
      'front' => l.fxCatFront,
      'core' => l.fxCatCore,
      'stereo_only' => l.fxCatStereoOnly,
      'spatial' => l.fxCatSpatial,
      'late' => l.fxCatLate,
      _ => l.fxCatCore,
    };
  }

  Widget _cardFor(String id, AppModel model) =>
      (_effectCardById[id] ?? _effectCardById['input']!).builder(model);

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    // 下拉顺序由卡片注册表派生（分类首次出现顺序）。
    final order = kEffectCategories.keys;
    return PageScaffold(
      eyebrow: l.pageEffectsEyebrow,
      title: l.pageEffectsTitle,
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => SizedBox(
          width: 168,
          child: AuraDropdown<String>(
            value: model.effectsCategory,
            isExpanded: true,
            items: [
              for (final id in order)
                DropdownMenuItem<String>(
                  value: id,
                  child: Text(
                    _categoryLabel(l, id),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: (v) {
              if (v != null) model.setEffectsCategory(v);
            },
          ),
        ),
      ),
      children: [
        ListenableBuilder(
          listenable: model,
          builder: (_, _) {
            final ids = kEffectCategories[model.effectsCategory] ??
                kEffectCategories['front']!;
            // 卡片间留空（用户反馈：全类连排过密无间距）。
            // 每卡独立 ListenableBuilder：拖动某卡滑块只重建该卡，
            // 不重建整类卡片（分类只影响列表构成，不影响卡片内部响应）。
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < ids.length; i++) ...[
                  ListenableBuilder(
                    key: ValueKey(ids[i]),
                    listenable: model,
                    builder: (_, _) => _cardFor(ids[i], model),
                  ),
                  if (i < ids.length - 1)
                    const SizedBox(height: AuraSpace.md),
                ],
              ],
            );
          },
        ),
        const SizedBox(height: AuraSpace.md),
        _PresetCard(model: model),
      ],
    );
  }
}

/* ---- 00 Input Gate (输入门控：常驻不可关闭、总增益旋钮、本级 IN/OUT 电平对比、高级区条形声道平衡) ---- */

/* ---- 参数滑块 ---- */

class ValueSlider extends StatefulWidget {
  final String label;
  final double value;
  final double defaultValue;
  final double min, max;
  final String unit;
  final bool enabled;
  final String Function(double)? format;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangedEnd;
  final VoidCallback? onResetToDefault;
  final bool overridden;
  final String? overriddenNote;

  /// 标签旁问号徽标的说明文案（null 不渲染；用于替代滑块下方常驻 hint 行）
  final String? infoMessage;

  const ValueSlider({
    super.key,
    required this.label,
    required this.value,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    this.onChangedEnd,
    this.onResetToDefault,
    this.enabled = true,
    this.format,
    this.overridden = false,
    this.overriddenNote,
    this.infoMessage,
  });

  @override
  State<ValueSlider> createState() => _ValueSliderState();
}

class _ValueSliderState extends State<ValueSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final displayed = _dragging ?? widget.value;
    final fmt = widget.format ?? (v) => v.toStringAsFixed(1);
    final isCustom = (widget.value - widget.defaultValue).abs() > 1e-4;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AuraSpace.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 140,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelOf(p,
                            color: widget.enabled ? p.text : p.textDim),
                      ),
                    ),
                    if (widget.infoMessage != null) ...[
                      const SizedBox(width: AuraSpace.xxs),
                      InfoBadge(message: widget.infoMessage!),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: Slider(
                  value: displayed.clamp(widget.min, widget.max),
                  min: widget.min,
                  max: widget.max,
                  onChanged: widget.enabled
                      ? (v) {
                          setState(() => _dragging = v);
                          DebugTrace.instance.uiControl(
                            widget.label,
                            v,
                            widget: 'slider',
                          );
                          widget.onChanged(v);
                        }
                      : null,
                  onChangeEnd: widget.enabled
                      ? (v) {
                          setState(() => _dragging = null);
                          widget.onChangedEnd?.call(v);
                        }
                      : null,
                ),
              ),
              SizedBox(
                width: 60,
                child: Builder(
                  builder: (context) {
                    final raw = fmt(displayed).trim();
                    final u = widget.unit.trim();
                    final bool alreadyHasUnit = u.isEmpty ||
                        raw.endsWith(u) ||
                        raw.endsWith('dB') ||
                        raw.endsWith('Hz') ||
                        raw.endsWith('kHz') ||
                        raw.endsWith('%') ||
                        raw.endsWith('ms') ||
                        raw.endsWith('s') ||
                        raw.endsWith(':1');
                    final text = alreadyHasUnit ? raw : '$raw $u';
                    return Text(
                      text,
                      textAlign: TextAlign.right,
                      style: monoOf(p,
                          size: 12,
                          color: widget.enabled ? p.text : p.textDim),
                    );
                  },
                ),
              ),
              if (widget.onResetToDefault != null) ...[
                const SizedBox(width: AuraSpace.xs),
                Tooltip(
                  message: l10nOf(context).sliderResetTip,
                  child: InkWell(
                    onTap: widget.onResetToDefault,
                    borderRadius: BorderRadius.circular(AuraRadius.xs),
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(
                        Icons.refresh_rounded,
                        size: 14,
                        color: isCustom ? p.accent : p.textDim.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (widget.overridden && widget.overriddenNote != null)
            Padding(
              padding: const EdgeInsets.only(left: 140),
              child: Text(
                widget.overriddenNote!,
                style: captionOf(p, color: p.warning),
              ),
            ),
        ],
      ),
    );
  }
}
