// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 07 Tube Simulator (电子管模拟器) ---- */

class _TubeCard extends StatelessWidget {
  final AppModel model;
  const _TubeCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return SectionCard(
      index: kEffectCardIndex['tube'],
      title: l.tubeTitle,
      titleTooltip: l.tubeHint,
      collapsed: !model.tubeOn,
      latencyMs: model.componentLatency('tube').ms,
      latencyEnabled: model.isSectionEnabled('tube'),
      latencyMeasured: model.componentLatency('tube').measured,
      latencyEstimated: model.componentLatency('tube').estimated,
      latencyProbing: model.isProbingLatency('tube'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('tube')
          ? () => model.refreshComponentLatency('tube')
          : null,
      latencyTick: model.getComponentLatencyTick('tube'),
      trailing: ParamSwitch(
        param: ParamRegistry.tubeEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 商业级电子管非线性传递曲线与谐波能量谱
          _TubeScope(model: model, palette: p),
          const SizedBox(height: AuraSpace.sm),
          // 饱和驱动度 (Drive / Saturation)
          ParamSlider(
            param: ParamRegistry.tubeGain,
            model: model,
            customLabel: l.tubeDrive,
            infoMessage: l.tubeHintColor,
          ),
          const SizedBox(height: AuraSpace.md),
          // 电子管音色风格 — 标签与选项同行，选项右对齐
          Row(
            children: [
              Text(l.tubeStyle, style: labelOf(p, color: p.text)),
              const Spacer(),
              ParamChoiceChips(
                param: ParamRegistry.tubeStyle,
                model: model,
                labels: [l.tubeStyleTriode, l.tubeStylePentode, l.tubeStyleTape],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          // 过采样开关已移除：立体声走 vendor 六频带电子管，是否过采样由
          // VTInit 按采样率决定，tube.oversample 只作用于离散多声道路径。
          // 保留引擎默认 1（2x），离散多声道恒为高精度，避免假控件。
          _TubeAdvanced(model: model),
        ],
      ),
    );
  }
}

class _TubeAdvanced extends StatelessWidget {
  final AppModel model;
  const _TubeAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    return AdvancedSection(
      summary:
          'Mix ${(m.tubeMix * 100).toStringAsFixed(0)}% · Comp ${(m.tubeCompensation >= 0 ? "+" : "")}${m.tubeCompensation.toStringAsFixed(1)} dB · AGC: ${m.tubeAutoGain ? "ON" : "OFF"} · ${(m.tubeOutputGain >= 0 ? "+" : "")}${m.tubeOutputGain.toStringAsFixed(1)} dB',
      builder: (context) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ParamSlider(
              param: ParamRegistry.tubeMix,
              model: m,
              customLabel: l.tubeMix,
            ),
            const SizedBox(height: AuraSpace.sm),
            ParamSlider(
              param: ParamRegistry.tubeCompensation,
              model: m,
              customLabel: l.tubeCompensation,
              infoMessage: l.tubeHintTrim,
            ),
            const SizedBox(height: AuraSpace.md),
            // 输出级外框（自动增益补偿与输出增益门）
            OutputGainFrame(
              child: Column(
                children: [
                  ParamAutoGainRow(
                    param: ParamRegistry.tubeAutoGain,
                    model: m,
                    label: l.autoGainCompensation,
                    tooltip: l.autoGainCompensationTooltip,
                  ),
                  const SizedBox(height: AuraSpace.xs),
                  ParamSlider(
                    param: ParamRegistry.tubeOutputGain,
                    model: m,
                    customLabel: l.outputGainGate,
                    infoMessage: l.outputGainGateTooltip,
                  ),
                ],
              ),
            ),
            const SizedBox(height: AuraSpace.sm),
            ChannelRoutingSelector(
              model: m,
              paramKey: 'tube.channels',
            ),
          ],
        );
      },
    );
  }
}

/// 商业级电子管非线性传递曲线与泛音谱示波器
class _TubeScope extends StatelessWidget {
  final AppModel model;
  final AuraPalette palette;

  const _TubeScope({
    required this.model,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final styleLabel = switch (model.tubeStyle) {
      0 => l.tubeTriode,
      1 => l.tubePentode,
      _ => l.tubeTape,
    };
    return Container(
      width: double.infinity,
      height: 114,
      decoration: BoxDecoration(
        color: palette.panel.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: palette.hairline.withValues(alpha: 0.4), width: 1.0),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        child: RepaintBoundary(
          child: CustomPaint(
            size: const Size(double.infinity, 114),
            painter: _TubeScopePainter(
              active: model.tubeOn,
              driveDb: model.tubeGain,
              style: model.tubeStyle,
              styleLabel: styleLabel,
              palette: palette,
            ),
          ),
        ),
      ),
    );
  }
}

class _TubeScopePainter extends CustomPainter {
  final bool active;
  final double driveDb;
  final int style; // 0: 三极管, 1: 五极管, 2: 磁带温润
  final String styleLabel; // 由卡片层按 l10n 组装
  final AuraPalette palette;

  _TubeScopePainter({
    required this.active,
    required this.driveDb,
    required this.style,
    required this.styleLabel,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final normDrive = ((driveDb - (-3.0)) / (12.0 - (-3.0))).clamp(0.0, 1.0);
    final leftW = w * 0.52;

    // ── 1. Left Section: 非线性软削波/饱和传递曲线 ──
    const leftPad = 14.0;
    final plotW = leftW - 24.0;
    const topPad = 18.0;
    final plotH = h - topPad - 16.0;
    final cx = leftPad + plotW / 2.0;
    final cy = topPad + plotH / 2.0;
    final halfW = plotW / 2.0;
    final halfH = plotH / 2.0;

    // Title at top left
    final titleTp = TextPainter(
      text: TextSpan(
        text: 'TRANSFER: $styleLabel',
        style: monoOf(palette, size: 7.0, color: palette.textDim.withValues(alpha: 0.7))
            .copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    titleTp.paint(canvas, const Offset(leftPad, 5.0));

    // Axes
    final axisPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.22)
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(leftPad, cy), Offset(leftPad + plotW, cy), axisPaint);
    canvas.drawLine(Offset(cx, topPad), Offset(cx, topPad + plotH), axisPaint);

    // Diagonal 1:1 linear reference line (dashed or faint)
    final refPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.3)
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(leftPad, topPad + plotH), Offset(leftPad + plotW, topPad), refPaint);

    // Sigmoid Transfer Curve Points
    const steps = 60;
    final curvePoints = <Offset>[];
    for (var i = 0; i <= steps; i++) {
      final t = (i / steps.toDouble()) * 2.0 - 1.0; // [-1.0, 1.0]
      final px = cx + t * halfW;
      double yOut = t;

      if (style == 0) {
        // Triode: Asymmetric saturation (more rounding on positive peaks)
        if (t >= 0) {
          final k = 1.0 + 1.8 * normDrive;
          yOut = (math.exp(k * t) - math.exp(-k * t)) / (math.exp(k * t) + math.exp(-k * t));
          final normK = (math.exp(k) - math.exp(-k)) / (math.exp(k) + math.exp(-k));
          yOut /= normK;
        } else {
          yOut = t * (1.0 - 0.15 * normDrive);
        }
      } else if (style == 1) {
        // Pentode: Symmetric sharp knee saturation
        final k = 1.2 + 2.5 * normDrive;
        yOut = (math.exp(k * t) - math.exp(-k * t)) / (math.exp(k * t) + math.exp(-k * t));
        final normK = (math.exp(k) - math.exp(-k)) / (math.exp(k) + math.exp(-k));
        yOut /= normK;
      } else {
        // Tape: Smooth algebraic sigmoid
        final k = 0.8 * normDrive;
        yOut = (t * (1.0 + k)) / (1.0 + t.abs() * k);
      }

      final py = cy - yOut.clamp(-1.0, 1.0) * halfH;
      curvePoints.add(Offset(px, py));
    }

    final curvePath = Path()..moveTo(curvePoints.first.dx, curvePoints.first.dy);
    for (final pt in curvePoints) {
      curvePath.lineTo(pt.dx, pt.dy);
    }
    final curvePaint = Paint()
      ..color = active ? palette.accent : palette.textDim
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(curvePath, curvePaint);

    // ── 2. Center Divider ──
    final divPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.3)
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(leftW, 8.0), Offset(leftW, h - 8.0), divPaint);

    // ── 3. Right Section: 泛音能量分布谱柱状图 ──
    final rightTitleTp = TextPainter(
      text: TextSpan(
        text: 'HARMONIC SPECTRUM',
        style: monoOf(palette, size: 7.0, color: palette.textDim.withValues(alpha: 0.7))
            .copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    rightTitleTp.paint(canvas, Offset(leftW + 12.0, 5.0));

    // 4 Bars: f0, 2nd, 3rd, 4th+
    final barW = 14.0;
    final barTrackH = h - 42.0;
    final barBaseY = h - 20.0;
    final barSpacing = (w - leftW - 24.0 - 4 * barW) / 3.0;

    // Harmonic levels
    final hLevels = <double>[];
    hLevels.add(1.0); // f0: base 100%
    if (style == 0) {
      // Triode: high 2nd, low 3rd
      hLevels.add((0.18 + 0.68 * normDrive).clamp(0.05, 1.0));
      hLevels.add((0.04 + 0.22 * normDrive).clamp(0.02, 1.0));
      hLevels.add((0.02 + 0.12 * normDrive).clamp(0.01, 1.0));
    } else if (style == 1) {
      // Pentode: high 3rd, moderate 2nd
      hLevels.add((0.08 + 0.25 * normDrive).clamp(0.04, 1.0));
      hLevels.add((0.20 + 0.72 * normDrive).clamp(0.08, 1.0));
      hLevels.add((0.06 + 0.30 * normDrive).clamp(0.03, 1.0));
    } else {
      // Tape: balanced warm 2nd & 3rd
      hLevels.add((0.14 + 0.42 * normDrive).clamp(0.05, 1.0));
      hLevels.add((0.15 + 0.48 * normDrive).clamp(0.06, 1.0));
      hLevels.add((0.03 + 0.16 * normDrive).clamp(0.02, 1.0));
    }

    final barColors = [
      palette.textDim,
      palette.warning, // 2nd: Warmth Amber
      palette.accent2, // 3rd: Bite / Edge
      palette.accent,  // 4th+: High order
    ];
    final barLabels = ['f0', '2nd', '3rd', '4th+'];

    for (var b = 0; b < 4; b++) {
      final bx = leftW + 12.0 + b * (barW + barSpacing);
      final level = hLevels[b];
      final fillH = barTrackH * level;
      final fillY = barBaseY - fillH;

      // Slot Track Background
      final trackPaint = Paint()
        ..color = palette.panelRaised.withValues(alpha: 0.6)
        ..style = PaintingStyle.fill;
      final trackRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(bx, barBaseY - barTrackH, barW, barTrackH),
        const Radius.circular(2.5),
      );
      canvas.drawRRect(trackRRect, trackPaint);

      // Filled Pillar
      final barColor = active ? barColors[b] : palette.textDim;
      final fillPaint = Paint()
        ..color = (b == 0)
            ? barColor.withValues(alpha: active ? 0.35 : 0.15)
            : barColor.withValues(alpha: active ? 0.75 : 0.25)
        ..style = PaintingStyle.fill;
      final fillRRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(bx, fillY, barW, fillH),
        const Radius.circular(2.5),
      );
      canvas.drawRRect(fillRRect, fillPaint);

      // Top Highlight Cap
      if (active && b > 0) {
        final capPaint = Paint()
          ..color = barColor
          ..style = PaintingStyle.fill;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(bx, fillY, barW, 2.0),
            const Radius.circular(1.0),
          ),
          capPaint,
        );
      }

      // Monospace label below
      final labelTp = TextPainter(
        text: TextSpan(
          text: barLabels[b],
          style: monoOf(palette, size: 7.0, color: (active && b > 0) ? barColor : palette.textDim)
              .copyWith(fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      labelTp.paint(canvas, Offset(bx + (barW - labelTp.width) / 2.0, barBaseY + 3.0));
    }
  }

  @override
  bool shouldRepaint(_TubeScopePainter old) =>
      old.active != active ||
      old.driveDb != driveDb ||
      old.style != style ||
      old.palette != palette;
}
