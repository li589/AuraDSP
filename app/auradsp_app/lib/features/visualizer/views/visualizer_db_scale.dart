import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';

/// 右侧 dB 纵轴刻度：0 / -15 / -30 / -45 / -60 dBFS
class VisualizerDbScale extends StatelessWidget {
  const VisualizerDbScale({super.key});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    const marks = ['0', '-15', '-30', '-45', '-60'];
    return SizedBox(
      width: 28,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in marks)
              Text(
                m,
                style: monoOf(
                  p,
                  size: 10,
                  color: p.textDim.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

