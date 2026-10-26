/*
 * liveprog_sliders_panel.dart — EEL2 编辑器底部内嵌脚本滑块调节面板
 *
 * 紧随控制台下方，提供自适应参数调节与统一边框质感。
 */
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/state.dart';
import '../../../core/theme.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../chrome.dart';
import '../eel_editor_support.dart';

class LiveprogSlidersPanel extends StatefulWidget {
  final AppModel model;
  final Map<int, EelSliderMeta> activeSliders;

  const LiveprogSlidersPanel({
    super.key,
    required this.model,
    required this.activeSliders,
  });

  @override
  State<LiveprogSlidersPanel> createState() => _LiveprogSlidersPanelState();
}

class _LiveprogSlidersPanelState extends State<LiveprogSlidersPanel> {
  bool _expanded = true;
  bool _showAll = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = AppLocalizations.of(context)!;
    final m = widget.model;

    final displayedIndices = _showAll
        ? List.generate(8, (i) => i + 1)
        : (widget.activeSliders.keys.toList()..sort());

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AuraSpace.sm),
      decoration: BoxDecoration(
        color: p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 标题与控制条
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 14, color: p.accent),
              const SizedBox(width: AuraSpace.xs),
              Text(
                l.lpSlidersPanelTitle,
                style: monoOf(p, size: 11, color: p.text),
              ),
              const SizedBox(width: AuraSpace.xs),
              Text(
                '(${widget.activeSliders.length}/8)',
                style: monoOf(p, size: 10, color: p.textDim),
              ),
              const Spacer(),
              if (_expanded)
                AuraChip(
                  _showAll ? l.lpShowAll : l.lpAdaptive(widget.activeSliders.length),
                  icon: Icons.tune_rounded,
                  selected: !_showAll,
                  onTap: () => setState(() => _showAll = !_showAll),
                ),
              const SizedBox(width: AuraSpace.xs),
              IconButton(
                icon: Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: p.textDim,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: _expanded ? l.lpSlidersCollapse : l.lpSlidersExpand,
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ],
          ),

          if (_expanded) ...[
            const SizedBox(height: AuraSpace.xs),
            Divider(color: p.hairline, height: 1),
            const SizedBox(height: AuraSpace.sm),
            ListenableBuilder(
              listenable: m,
              builder: (context, _) {
                if (!_showAll && widget.activeSliders.isEmpty) {
                  return Container(
                    padding: const EdgeInsets.symmetric(
                        vertical: AuraSpace.md, horizontal: AuraSpace.sm),
                    alignment: Alignment.center,
                    child: Column(
                      children: [
                        Icon(Icons.tune_outlined, size: 24, color: p.textDim),
                        const SizedBox(height: 4),
                        Text(
                          l.lpNoSliders,
                          style: captionOf(p),
                        ),
                        const SizedBox(height: 4),
                        OutlinedButton.icon(
                          onPressed: () => setState(() => _showAll = true),
                          icon: const Icon(Icons.expand_more_rounded, size: 14),
                          label: Text(l.lpExpandSliders),
                          style: OutlinedButton.styleFrom(
                            foregroundColor: p.accent,
                            side: BorderSide(color: p.hairline),
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                  );
                }

                return Column(
                  children: [
                    for (final idx in displayedIndices)
                      _LpSliderRow(
                        model: m,
                        index: idx - 1,
                        meta: widget.activeSliders[idx],
                      ),
                  ],
                );
              },
            ),
          ],
        ],
      ),
    );
  }
}

class _LpSliderRow extends StatelessWidget {
  final AppModel model;
  final int index;
  final EelSliderMeta? meta;

  const _LpSliderRow({
    required this.model,
    required this.index,
    this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    var minVal = meta?.minVal ?? 0.0;
    var maxVal = meta?.maxVal ?? 1.0;
    if (minVal > maxVal) {
      final tmp = minVal;
      minVal = maxVal;
      maxVal = tmp;
    } else if (minVal == maxVal) {
      maxVal = minVal + 1.0;
    }
    final displayName = meta?.displayName ?? 'slider${index + 1}';
    final rawName = 'slider${index + 1}';
    final currentVal = model.lpParams[index].clamp(minVal, maxVal);

    return Padding(
      padding: const EdgeInsets.only(bottom: AuraSpace.xs + 2),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        meta != null ? FontWeight.bold : FontWeight.normal,
                    color: meta != null ? p.accent : p.text,
                  ),
                ),
                Text(
                  rawName,
                  style: monoOf(p, size: 9.5, color: p.textDim),
                ),
              ],
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6.5),
              ),
              child: Slider(
                value: currentVal,
                min: minVal,
                max: maxVal,
                onChanged: (v) => model.setLiveprogParam(index, v),
              ),
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          SizedBox(
            width: 58,
            child: Text(
              currentVal.toStringAsFixed(2),
              textAlign: TextAlign.right,
              style: monoOf(p, size: 12, color: p.text),
            ),
          ),
        ],
      ),
    );
  }
}
