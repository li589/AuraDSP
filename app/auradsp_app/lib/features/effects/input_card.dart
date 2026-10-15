// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
class _InputCard extends StatelessWidget {
  final AppModel model;
  const _InputCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: kEffectCardIndex['input'],
      title: l.inputGate,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 上半区：左侧全通道总增益旋钮 + 右侧多通道本级 IN/OUT 电平对比表
          LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 460;
              final knobWidget = _InputMasterGainKnob(
                gain: model.inputGain,
                onChanged: model.setInputGain,
                onReset: () => model.setInputGain(0.0),
                label: l.inputGain,
                palette: p,
              );
              final meterWidget = _InputStageMeterMatrix(
                model: model,
                palette: p,
                l10n: l,
              );

              if (isCompact) {
                return Column(
                  children: [
                    Center(child: knobWidget),
                    const SizedBox(height: AuraSpace.md),
                    meterWidget,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 140,
                    child: Center(child: knobWidget),
                  ),
                  Container(
                    width: 1,
                    height: 100,
                    margin: const EdgeInsets.symmetric(horizontal: AuraSpace.sm),
                    color: p.hairline.withValues(alpha: 0.5),
                  ),
                  Expanded(child: meterWidget),
                ],
              );
            },
          ),
          const SizedBox(height: AuraSpace.md),

          // 下半区：高级展开区 - 声道平衡功能 (条形控制)
          AdvancedSection(
            summary: 'L: ${(model.inputBalanceL * 100).round()}% · R: ${(model.inputBalanceR * 100).round()}%',
            helpTooltip: l.channelBalanceHint,
            builder: (ctx) => _InputBalanceAdvanced(
              model: model,
              palette: p,
              l10n: l,
            ),
          ),
        ],
      ),
    );
  }
}

class _InputMasterGainKnob extends StatefulWidget {
  final double gain;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;
  final String label;
  final AuraPalette palette;

  const _InputMasterGainKnob({
    required this.gain,
    required this.onChanged,
    required this.onReset,
    required this.label,
    required this.palette,
  });

  @override
  State<_InputMasterGainKnob> createState() => _InputMasterGainKnobState();
}

class _InputMasterGainKnobState extends State<_InputMasterGainKnob> {
  double? _dragStartY;
  double? _dragStartGain;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final gainText = (widget.gain >= 0 ? '+' : '') + widget.gain.toStringAsFixed(1);

    return GestureDetector(
      onDoubleTap: widget.onReset,
      onVerticalDragStart: (details) {
        _dragStartY = details.localPosition.dy;
        _dragStartGain = widget.gain;
      },
      onVerticalDragUpdate: (details) {
        if (_dragStartY != null && _dragStartGain != null) {
          final dy = _dragStartY! - details.localPosition.dy;
          final newGain = (_dragStartGain! + dy * 0.1).clamp(-15.0, 15.0);
          final snapped = (newGain * 10).round() / 10.0;
          widget.onChanged(snapped);
        }
      },
      onVerticalDragEnd: (_) {
        _dragStartY = null;
        _dragStartGain = null;
      },
      child: Tooltip(
        message: '${widget.label}: $gainText dB\n上下拖拽微调 · 双击归零',
        child: Container(
          color: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size(68, 68),
                painter: _GainKnobPainter(gain: widget.gain, palette: p),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    gainText,
                    style: monoOf(p, size: 13, color: p.accent).copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'dB',
                    style: monoOf(p, size: 9.5, color: p.textDim),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                widget.label,
                style: captionOf(p).copyWith(fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GainKnobPainter extends CustomPainter {
  final double gain; // -15.0 to 15.0
  final AuraPalette palette;

  const _GainKnobPainter({required this.gain, required this.palette});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 5;

    // 轨道角度：-135° (135°) 到 +135° (405°)，12点钟正上方 270° 对应 0.0 dB
    const startAngle = 135.0 * math.pi / 180.0;
    const sweepTotal = 270.0 * math.pi / 180.0;
    const zeroAngle = 270.0 * math.pi / 180.0;

    // 1. 轨道底环
    final trackPaint = Paint()
      ..color = palette.hairline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepTotal,
      false,
      trackPaint,
    );

    // 2. 0 dB 刻度指示线（正上方 12 点钟）
    final tickPaint = Paint()
      ..color = palette.textDim.withValues(alpha: 0.6)
      ..strokeWidth = 1.2;
    canvas.drawLine(
      Offset(center.dx, center.dy - radius - 3),
      Offset(center.dx, center.dy - radius + 3),
      tickPaint,
    );

    // 3. 有效增益发光弧
    final halfSweep = sweepTotal / 2.0;
    final normalized = (gain / 15.0).clamp(-1.0, 1.0);
    final sweep = normalized * halfSweep;

    if (sweep.abs() > 0.005) {
      final activePaint = Paint()
        ..color = palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        zeroAngle,
        sweep,
        false,
        activePaint,
      );
    }

    // 4. 中心圆盘
    final discPaint = Paint()
      ..color = palette.panelRaised
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - 6.5, discPaint);

    final discBorder = Paint()
      ..color = palette.hairline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, radius - 6.5, discBorder);

    // 5. 指针指示点
    final pointerAngle = zeroAngle + sweep;
    final dotX = center.dx + (radius - 12) * math.cos(pointerAngle);
    final dotY = center.dy + (radius - 12) * math.sin(pointerAngle);
    final dotPaint = Paint()..color = palette.accent;
    canvas.drawCircle(Offset(dotX, dotY), 2.6, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _GainKnobPainter oldDelegate) =>
      oldDelegate.gain != gain || oldDelegate.palette != palette;
}

class _InputStageMeterMatrix extends StatelessWidget {
  final AppModel model;
  final AuraPalette palette;
  final AppLocalizations l10n;

  const _InputStageMeterMatrix({
    required this.model,
    required this.palette,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        model.inputMeterInL,
        model.inputMeterInR,
        model.inputMeterOutL,
        model.inputMeterOutR,
      ]),
      builder: (context, _) {
        final inL = model.inputMeterInL.value;
        final inR = model.inputMeterInR.value;
        final outL = model.inputMeterOutL.value;
        final outR = model.inputMeterOutR.value;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: AuraSpace.xs + 2),
          decoration: BoxDecoration(
            color: palette.panelRaised.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: palette.hairline.withValues(alpha: 0.7)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶栏：本级输入 (IN) 与 本级输出 (OUT) 胶囊标签
              Row(
                children: [
                  _StageBadge(
                    label: l10n.inputStageIn,
                    color: palette.textDim,
                    icon: Icons.input_rounded,
                  ),
                  const Spacer(),
                  Icon(Icons.arrow_forward_rounded,
                      size: 12, color: palette.textDim.withValues(alpha: 0.5)),
                  const Spacer(),
                  _StageBadge(
                    label: l10n.inputStageOut,
                    color: palette.accent,
                    icon: Icons.output_rounded,
                  ),
                ],
              ),
              const SizedBox(height: AuraSpace.xs + 2),
              // 电平柱阵列
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // IN L & R
                  _MeterChannelBar(label: 'L', db: inL, palette: palette),
                  _MeterChannelBar(label: 'R', db: inR, palette: palette),
                  // 分贝刻度尺
                  _MeterScaleRuler(palette: palette),
                  // OUT L & R
                  _MeterChannelBar(label: 'L', db: outL, palette: palette),
                  _MeterChannelBar(label: 'R', db: outR, palette: palette),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StageBadge extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _StageBadge({
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _MeterScaleRuler extends StatelessWidget {
  final AuraPalette palette;
  const _MeterScaleRuler({required this.palette});

  @override
  Widget build(BuildContext context) {
    const ticks = ['0', '-6', '-18', '-36'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final t in ticks) ...[
            Text(
              t,
              style: monoOf(palette, size: 7.5, color: palette.textDim.withValues(alpha: 0.7)),
            ),
          ],
          const SizedBox(height: 14), // 对齐下方声道标签行高
        ],
      ),
    );
  }
}

class _MeterChannelBar extends StatelessWidget {
  final String label;
  final double db;
  final AuraPalette palette;

  const _MeterChannelBar({
    required this.label,
    required this.db,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final isClip = db > -0.05;
    final dbStr = (db <= -59.5 || db.isNaN || db.isInfinite)
        ? '-∞'
        : (db >= 0 ? '+${db.toStringAsFixed(1)}' : db.toStringAsFixed(1));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 峰值过载 LED
        Container(
          width: 8,
          height: 3,
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: isClip ? const Color(0xFFEF4444) : const Color(0xFFEF4444).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
        // 阶梯式 LED 柱
        CustomPaint(
          size: const Size(10, 52),
          painter: _ChannelLedPainter(db: db, palette: palette),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: monoOf(palette, size: 9, color: palette.text).copyWith(fontWeight: FontWeight.bold),
        ),
        Text(
          dbStr,
          style: monoOf(palette, size: 7.5, color: isClip ? const Color(0xFFEF4444) : palette.textDim),
        ),
      ],
    );
  }
}

class _ChannelLedPainter extends CustomPainter {
  final double db;
  final AuraPalette palette;
  static const int kSegments = 10;

  const _ChannelLedPainter({required this.db, required this.palette});

  static double _norm(double db) {
    if (db.isNaN || db.isInfinite || db <= -60.0) return 0.0;
    if (db >= 0.0) return 1.0;
    return ((db + 60.0) / 60.0).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final normVal = _norm(db);
    final litCount = (normVal * kSegments).round().clamp(0, kSegments);
    final segH = (size.height - (kSegments - 1) * 1.5) / kSegments;

    for (var s = 0; s < kSegments; s++) {
      final segBottom = size.height - s * (segH + 1.5);
      final segTop = segBottom - segH;
      final isLit = s < litCount;

      final Color litColor;
      if (s >= 9) {
        litColor = const Color(0xFFEF4444); // 红色
      } else if (s >= 7) {
        litColor = const Color(0xFFF59E0B); // 琥珀黄
      } else {
        litColor = const Color(0xFF10B981); // 翠绿
      }

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, segTop, size.width, segH),
        const Radius.circular(0.8),
      );

      final paint = Paint()
        ..color = isLit ? litColor : litColor.withValues(alpha: 0.12)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChannelLedPainter oldDelegate) =>
      oldDelegate.db != db || oldDelegate.palette != palette;
}

class _InputBalanceAdvanced extends StatelessWidget {
  final AppModel model;
  final AuraPalette palette;
  final AppLocalizations l10n;

  const _InputBalanceAdvanced({
    required this.model,
    required this.palette,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final isCustom = (model.inputBalanceL - 1.0).abs() > 0.001 ||
        (model.inputBalanceR - 1.0).abs() > 0.001;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isCustom)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AuraSpace.xs),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.refresh_rounded, size: 13),
                label: const Text('重置 100%', style: TextStyle(fontSize: 11)),
                onPressed: () {
                  model.setInputBalanceL(1.0);
                  model.setInputBalanceR(1.0);
                },
              ),
            ),
          ),
        _ChannelBalanceBar(
          label: l10n.channelLeft,
          value: model.inputBalanceL,
          masterGainDb: model.inputGain,
          onChanged: model.setInputBalanceL,
          onReset: () => model.setInputBalanceL(1.0),
          palette: palette,
          l10n: l10n,
        ),
        const SizedBox(height: AuraSpace.sm),
        _ChannelBalanceBar(
          label: l10n.channelRight,
          value: model.inputBalanceR,
          masterGainDb: model.inputGain,
          onChanged: model.setInputBalanceR,
          onReset: () => model.setInputBalanceR(1.0),
          palette: palette,
          l10n: l10n,
        ),
      ],
    );
  }
}

class _ChannelBalanceBar extends StatelessWidget {
  final String label;
  final double value; // 0.0 ~ 2.0 (0% ~ 200%)
  final double masterGainDb;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;
  final AuraPalette palette;
  final AppLocalizations l10n;

  const _ChannelBalanceBar({
    required this.label,
    required this.value,
    required this.masterGainDb,
    required this.onChanged,
    required this.onReset,
    required this.palette,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final percent = (value * 100).round();
    final isCustom = (value - 1.0).abs() > 0.001;

    // 计算最终合成音量: 总控 (dB) * 单控 (线性比例)
    final String finalDesc;
    if (value <= 0.0001) {
      finalDesc = '-∞ dB (0%)';
    } else {
      final finalDb = masterGainDb + (20.0 * math.log(value) / math.ln10);
      final finalPct = ((math.pow(10.0, masterGainDb / 20.0) * value) * 100).round();
      final sign = finalDb >= 0 ? '+' : '';
      finalDesc = '$sign${finalDb.toStringAsFixed(1)} dB ($finalPct%)';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: AuraSpace.xs),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        border: Border.all(color: p.hairline.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: labelOf(p, size: 12).copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: AuraSpace.sm),
              // 单控百分比徽标
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: isCustom ? p.accent.withValues(alpha: 0.15) : p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                  border: Border.all(
                    color: isCustom ? p.accent.withValues(alpha: 0.4) : p.hairline,
                    width: 0.8,
                  ),
                ),
                child: Text(
                  '$percent%',
                  style: monoOf(p, size: 10, color: isCustom ? p.accent : p.textDim)
                      .copyWith(fontWeight: isCustom ? FontWeight.bold : FontWeight.normal),
                ),
              ),
              const Spacer(),
              // 最终音量合成显示
              Text(
                '最终: $finalDesc',
                style: monoOf(p, size: 10.5, color: isCustom ? p.accent : p.textDim),
              ),
              if (isCustom) ...[
                const SizedBox(width: AuraSpace.xs),
                Tooltip(
                  message: '双击或点击恢复 100%',
                  child: InkWell(
                    onTap: onReset,
                    borderRadius: BorderRadius.circular(AuraRadius.xs),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.refresh_rounded, size: 13, color: p.accent),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AuraSpace.xxs),
          // 条形滑块控制
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              activeTrackColor: p.accent,
              inactiveTrackColor: p.hairline,
              thumbColor: p.accent,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: value.clamp(0.0, 2.0),
              min: 0.0,
              max: 2.0,
              divisions: 200,
              onChanged: (v) {
                final snapped = (v * 100).round() / 100.0;
                onChanged(snapped);
              },
            ),
          ),
        ],
      ),
    );
  }
}
