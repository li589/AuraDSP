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

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/design.dart';
import '../core/path_memory.dart';
import '../core/presets.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';
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
part 'effects/bassmono_card.dart';
part 'effects/shelf_card.dart';
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

/// 效果器卡片序号**单一真相**（分类编号 {类}-{序号}，类按链序：
/// 1 输入整形 / 2 动态控制 / 3 低频 / 4 均衡校准 / 5 空间 / 6 激励与输出）。
///
/// 历史坑：序号原本硬编码在 20 个卡片文件里、各写各的，结果出现 5 个 '00'
/// （input/gate/filter/dyneq 都算 0 号）、2 个 '02'、2 个 '06'，新增或调整
/// 卡片时也无人同步——用户看到的就是「序号全是乱的」。
/// 现在只允许改这一处；卡片侧一律写 `index: kEffectCardIndex['<id>']`。
/// 空间卡去编号（index 传 null，含其内部 5 张搬入子卡）。
///
/// 注意：这是**页面分区序号**，不是处理链顺序。链上顺序见 ChainPage 的
/// kDefaultCoreOrder 与「处理顺序」页，两者不必相同。
const Map<String, String> kEffectCardIndex = {
  'input': '1-1',
  'gate': '1-2',
  'filter': '1-3',
  'comp': '2-1',
  'dyneq': '2-2',
  'loudness': '2-3',
  'bass': '3-1',
  'bassmono': '3-2',
  'shelf': '3-3',
  'eq': '4-1',
  'arbmag': '4-2',
  'ddc': '4-3',
  'exciter': '6-1',
  'tube': '6-2',
  'post': '6-3',
};

/// 效果分类（标题行右侧下拉过滤；空间独占一类）。
/// 'all' 伪类 = 全部链序展开（默认视图，与分类前逐像素一致）。
const Map<String, List<String>> kEffectCategories = {
  'input': ['input', 'gate', 'filter'],
  'dynamics': ['comp', 'dyneq', 'loudness'],
  'bass': ['bass', 'bassmono', 'shelf'],
  'eq': ['eq', 'arbmag', 'ddc'],
  'spatial': ['spatial'],
  'late': ['exciter', 'tube', 'post'],
};

/// 'all' 默认视图的链序（与分类前一致，保证默认零视觉变更）。
const List<String> kEffectPageOrder = [
  'input', 'gate', 'filter', 'dyneq', 'comp', 'bass', 'bassmono', 'shelf',
  'spatial', 'ddc', 'eq', 'arbmag', 'exciter', 'loudness', 'tube', 'post',
];

class EffectsPage extends StatelessWidget {
  final AppModel model;
  const EffectsPage({super.key, required this.model});

  String _categoryLabel(AppLocalizations l, String id) {
    return switch (id) {
      'input' => l.fxCatInput,
      'dynamics' => l.fxCatDynamics,
      'bass' => l.fxCatBass,
      'eq' => l.fxCatEq,
      'spatial' => l.fxCatSpatial,
      'late' => l.fxCatLate,
      _ => l.fxCatAll,
    };
  }

  Widget _cardFor(String id, AppModel model) {
    return switch (id) {
      'input' => _InputCard(model: model),
      'gate' => _GateCard(model: model),
      'filter' => _FilterCard(model: model),
      'dyneq' => _DyneCard(model: model),
      'comp' => _CompressorCard(model: model),
      'bass' => _BassCard(model: model),
      'bassmono' => _BassMonoCard(model: model),
      'shelf' => _ShelfCard(model: model),
      'spatial' => _SpatialCard(model: model),
      'ddc' => _DdcCard(model: model),
      'eq' => _EqualizerCard(model: model),
      'arbmag' => _ArbmagCard(model: model),
      'exciter' => _ExciterCard(model: model),
      'loudness' => _LoudnessCard(model: model),
      'tube' => _TubeCard(model: model),
      'post' => _PostCard(model: model),
      _ => _InputCard(model: model),
    };
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    const order = ['all', 'input', 'dynamics', 'bass', 'eq', 'spatial', 'late'];
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
                    id == 'all' ? l.fxCatAll : _categoryLabel(l, id),
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
            final ids = model.effectsCategory == 'all'
                ? kEffectPageOrder
                : (kEffectCategories[model.effectsCategory] ??
                    kEffectPageOrder);
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [for (final id in ids) _cardFor(id, model)],
            );
          },
        ),
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
              const SizedBox(width: AuraSpace.sm),
              SizedBox(
                width: 60,
                child: Text(
                  '${fmt(displayed)} ${widget.unit}',
                  textAlign: TextAlign.right,
                  style: monoOf(p,
                      size: 12,
                      color: widget.enabled ? p.text : p.textDim),
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
