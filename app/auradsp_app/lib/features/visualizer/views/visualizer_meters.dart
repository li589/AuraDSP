import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/state.dart';
import '../../../core/theme.dart';
import '../../../core/ui_helpers.dart';
import '../../../ui/chrome.dart' show StatReadout;
import '../../../ui/widgets.dart' show LevelMeter, SectionCard;

/// 可视化底栏：专业录音室多通道电平与 dBFS 精确实时读数
class VisualizerMeters extends StatelessWidget {
  final AppModel model;
  final bool active;

  const VisualizerMeters({
    super.key,
    required this.model,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return SectionCard(
      index: '01',
      title: l.levelsTitle,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: LevelMeter(
                  level: model.levelL,
                  label: 'L',
                  active: active,
                ),
              ),
              const SizedBox(width: AuraSpace.xl),
              Expanded(
                child: LevelMeter(
                  level: model.levelR,
                  label: 'R',
                  active: active,
                ),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm + 2),
          Align(
            alignment: Alignment.centerRight,
            child: active
                ? ValueListenableBuilder<double>(
                    valueListenable: model.levelL,
                    builder: (_, lDb, _) => ValueListenableBuilder<double>(
                      valueListenable: model.levelR,
                      builder: (_, rDb, _) => Text(
                        'L ${dbfsText(lDb)}  R ${dbfsText(rDb)} dBFS',
                        style: monoOf(p, size: 11, color: p.textDim),
                      ),
                    ),
                  )
                : Text(
                    'L ${dbfsText(-90.0)}  R ${dbfsText(-90.0)} dBFS',
                    style: monoOf(p, size: 11, color: p.textDim),
                  ),
          ),
        ],
      ),
    );
  }
}

/// 峰值读数（页面右上标头）
class VisualizerPeakReadout extends StatelessWidget {
  final ValueListenable<List<double>> spectrum;
  final String label;
  final bool active;

  const VisualizerPeakReadout({
    super.key,
    required this.spectrum,
    required this.label,
    this.active = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    if (!active) {
      return StatReadout(
        label: label,
        value: dbfsText(-90.0),
        unit: 'dBFS',
        size: 20,
        valueColor: p.textDim,
      );
    }
    return ValueListenableBuilder<List<double>>(
      valueListenable: spectrum,
      builder: (_, bands, _) {
        var peak = 0.0;
        for (final v in bands) {
          peak = math.max(peak, v);
        }
        final db = bands.isEmpty || peak <= 0 ? -90.0 : peak * 60 - 60;
        return StatReadout(
          label: label,
          value: dbfsText(db),
          unit: 'dBFS',
          size: 20,
          valueColor: db > -3 ? p.error : p.accent,
        );
      },
    );
  }
}

