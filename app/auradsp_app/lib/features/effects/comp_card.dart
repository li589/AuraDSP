// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 01 Compressor (动态压限器) ---- */

class _CompressorCard extends StatelessWidget {
  final AppModel model;
  const _CompressorCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: kEffectCardIndex['comp'],
      title: l.compTitle,
      titleTooltip: l.compHint,
      collapsed: !model.compOn,
      latencyMs: model.componentLatency('comp').ms,
      latencyMeasured: model.componentLatency('comp').measured,
      latencyEstimated: model.componentLatency('comp').estimated,
      latencyProbing: model.isProbingLatency('comp'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('comp')
          ? () => model.refreshComponentLatency('comp')
          : null,
      latencyTick: model.getComponentLatencyTick('comp'),
      trailing: ParamSwitch(
        param: ParamRegistry.compEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 商业级动态响应传输曲线与 GR 衰减条
          _CompressorTransferScope(model: model),
          const SizedBox(height: AuraSpace.sm),
          // 响应时常数（Time Constant）主滑块
          ParamSlider(
            param: ParamRegistry.compTimeconstant,
            model: model,
            customLabel: l.compTimeconstant,
            infoMessage: '控制动态压缩与包络跟踪的释放响应时间。较小时瞬态冲击更明显，较大时动态压缩更平顺通透。',
            customMin: 0.02,
            customUnit: 'ms',
            customFormat: (v) => (v * 1000).toStringAsFixed(0),
          ),
          const SizedBox(height: AuraSpace.sm),
          AdvancedSection(
            summary: '${model.compGranularity == 0 ? l.compGranularityCoarse : (model.compGranularity == 1 ? l.compGranularityNormal : l.compGranularityFine)} · AGC: ${model.compAutoGain ? "ON" : "OFF"} · ${(model.compOutputGain >= 0 ? "+" : "")}${model.compOutputGain.toStringAsFixed(1)} dB',
            builder: (ctx) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 分析颗粒度模式 (Granularity)
                Row(
                  children: [
                    Text(l.compGranularity, style: labelOf(p, color: p.text)),
                    const Spacer(),
                    ParamChoiceChips(
                      param: ParamRegistry.compGranularity,
                      model: model,
                      labels: [
                        l.compGranularityCoarse,
                        l.compGranularityNormal,
                        l.compGranularityFine,
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                // 2. 时频分辨率 (Time-Frequency Resolution)
                Row(
                  children: [
                    Text(l.compTfresolution, style: labelOf(p, color: p.text)),
                    const Spacer(),
                    ParamChoiceChips(
                      param: ParamRegistry.compTfresolution,
                      model: model,
                      labels: [
                        l.compTfresTransient,
                        l.compTfresBalanced,
                        l.compTfresFine,
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.md),
                // 3. 输出级外框（自动增益补偿与输出增益门）
                OutputGainFrame(
                  child: Column(
                    children: [
                      ParamAutoGainRow(
                        param: ParamRegistry.compAutoGain,
                        model: model,
                        label: l.autoGainCompensation,
                        tooltip: l.autoGainCompensationTooltip,
                      ),
                      const SizedBox(height: AuraSpace.xs),
                      ParamOutputGainSlider(
                        param: ParamRegistry.compOutputGain,
                        model: model,
                        label: l.outputGainGate,
                        infoMessage: l.outputGainGateTooltip,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 商业级动态压限特性传输曲线与实时 Gain Reduction 衰减表
class _CompressorTransferScope extends StatefulWidget {
  final AppModel model;
  const _CompressorTransferScope({required this.model});

  @override
  State<_CompressorTransferScope> createState() => _CompressorTransferScopeState();
}

class _CompressorTransferScopeState extends State<_CompressorTransferScope> {
  double _smoothGr = 0.0;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final model = widget.model;

    return ListenableBuilder(
      listenable: Listenable.merge([model.levelL, model.levelR]),
      builder: (context, _) {
        final inDb = math.max(model.levelL.value, model.levelR.value);

        // 颗粒度对应拐点阈值
        final threshold = model.compGranularity == 0
            ? -18.0
            : (model.compGranularity == 1 ? -24.0 : -28.0);
        // 时常数影响压缩比斜率 (3.5 ~ 6.5)
        final ratio = 3.5 + (0.5 - (model.compTimeconstant - 0.14)).clamp(0.0, 3.0);
        const knee = 10.0;
        final makeup = model.compOutputGain + (model.compAutoGain ? 3.5 : 0.0);

        double targetGr = 0.0;
        if (model.compOn && inDb > -48.0) {
          final delta = inDb - threshold;
          double yRaw;
          if (2 * delta < -knee) {
            yRaw = inDb;
          } else if (2 * delta.abs() <= knee) {
            final kTerm = delta + knee / 2.0;
            yRaw = inDb + ((1.0 / ratio) - 1.0) * (kTerm * kTerm) / (2.0 * knee);
          } else {
            yRaw = threshold + delta / ratio;
          }
          targetGr = (inDb - yRaw).clamp(0.0, 24.0);
        }

        // 瞬时响应与平滑回弹 (Ballistics)
        if (targetGr >= _smoothGr) {
          _smoothGr = targetGr;
        } else {
          _smoothGr = _smoothGr * 0.85 + targetGr * 0.15;
          if (_smoothGr < 0.05) _smoothGr = 0.0;
        }

        return Container(
          width: double.infinity,
          height: 130,
          margin: const EdgeInsets.only(bottom: AuraSpace.xs),
          decoration: BoxDecoration(
            color: p.panel.withValues(alpha: 0.75),
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: p.hairline.withValues(alpha: 0.4), width: 1.0),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            child: RepaintBoundary(
              child: CustomPaint(
                size: const Size(double.infinity, 130),
                painter: _CompressorPainter(
                  palette: p,
                  active: model.compOn,
                  threshold: threshold,
                  ratio: ratio,
                  knee: knee,
                  makeup: makeup,
                  inDb: inDb,
                  grDb: _smoothGr,
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _CompressorPainter extends CustomPainter {
  final AuraPalette palette;
  final bool active;
  final double threshold;
  final double ratio;
  final double knee;
  final double makeup;
  final double inDb;
  final double grDb;

  _CompressorPainter({
    required this.palette,
    required this.active,
    required this.threshold,
    required this.ratio,
    required this.knee,
    required this.makeup,
    required this.inDb,
    required this.grDb,
  });

  double _computeOutput(double x) {
    final delta = x - threshold;
    double y;
    if (2 * delta < -knee) {
      y = x;
    } else if (2 * delta.abs() <= knee) {
      final kTerm = delta + knee / 2.0;
      y = x + ((1.0 / ratio) - 1.0) * (kTerm * kTerm) / (2.0 * knee);
    } else {
      y = threshold + delta / ratio;
    }
    return (y + makeup).clamp(-48.0, 6.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    const meterWidth = 36.0;
    final plotWidth = w - meterWidth - 10.0;
    const leftPad = 26.0;
    const bottomPad = 18.0;
    const topPad = 8.0;
    const rightPad = 4.0;
    final pw = plotWidth - leftPad - rightPad;
    final ph = h - topPad - bottomPad;

    if (pw <= 0 || ph <= 0) return;

    double xToPx(double db) => leftPad + ((db + 48.0) / 48.0) * pw;
    double yToPx(double db) => (topPad + ph) - ((db + 48.0) / 48.0) * ph;

    // 1. Grid lines and scale labels
    final gridPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.22)
      ..strokeWidth = 0.8;

    final dbTicks = [-36.0, -24.0, -12.0, 0.0];
    for (final db in dbTicks) {
      final y = yToPx(db);
      canvas.drawLine(Offset(leftPad, y), Offset(leftPad + pw, y), gridPaint);

      final x = xToPx(db);
      canvas.drawLine(Offset(x, topPad), Offset(x, topPad + ph), gridPaint);

      // Y-axis labels
      final tpY = TextPainter(
        text: TextSpan(
          text: '${db.toInt()}',
          style: monoOf(palette, size: 8, color: palette.textDim.withValues(alpha: 0.6)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tpY.paint(canvas, Offset(leftPad - tpY.width - 4, y - tpY.height / 2));

      // X-axis labels
      final tpX = TextPainter(
        text: TextSpan(
          text: '${db.toInt()}',
          style: monoOf(palette, size: 8, color: palette.textDim.withValues(alpha: 0.6)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tpX.paint(canvas, Offset(x - tpX.width / 2, topPad + ph + 3));
    }

    // 2. Linear 1:1 diagonal reference line
    final refPaint = Paint()
      ..color = palette.textDim.withValues(alpha: 0.22)
      ..strokeWidth = 1.0;
    canvas.drawLine(
      Offset(xToPx(-48.0), yToPx(-48.0)),
      Offset(xToPx(0.0), yToPx(0.0)),
      refPaint,
    );

    // 3. Shaded transfer area under curve
    final fillPath = Path();
    fillPath.moveTo(xToPx(-48.0), yToPx(-48.0));
    for (var i = 0; i <= 48; i++) {
      final xDb = -48.0 + i;
      final yDb = _computeOutput(xDb);
      fillPath.lineTo(xToPx(xDb), yToPx(yDb));
    }
    fillPath.lineTo(xToPx(0.0), yToPx(-48.0));
    fillPath.close();

    final fillShader = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        active ? palette.accent.withValues(alpha: 0.22) : palette.textDim.withValues(alpha: 0.08),
        active ? palette.accent.withValues(alpha: 0.02) : Colors.transparent,
      ],
    ).createShader(Rect.fromLTWH(leftPad, topPad, pw, ph));

    final fillPaint = Paint()
      ..shader = fillShader
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // 4. Active compression transfer curve
    final curvePath = Path();
    curvePath.moveTo(xToPx(-48.0), yToPx(_computeOutput(-48.0)));
    for (var i = 1; i <= 48; i++) {
      final xDb = -48.0 + i;
      final yDb = _computeOutput(xDb);
      curvePath.lineTo(xToPx(xDb), yToPx(yDb));
    }

    final curvePaint = Paint()
      ..color = active ? palette.accent : palette.textDim.withValues(alpha: 0.45)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(curvePath, curvePaint);

    // 5. Threshold vertical indicator
    final tx = xToPx(threshold);
    if (tx >= leftPad && tx <= leftPad + pw) {
      final threshPaint = Paint()
        ..color = (active ? palette.accent : palette.textDim).withValues(alpha: 0.35)
        ..strokeWidth = 1.0;
      canvas.drawLine(Offset(tx, topPad), Offset(tx, topPad + ph), threshPaint);
    }

    // 6. Real-time audio ball
    if (active && inDb > -46.0) {
      final ballX = inDb.clamp(-48.0, 0.0);
      final ballY = _computeOutput(ballX);
      final bx = xToPx(ballX);
      final by = yToPx(ballY);

      // Glow halo
      final glowPaint = Paint()
        ..color = palette.accent.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
      canvas.drawCircle(Offset(bx, by), 6.5, glowPaint);

      // Core ball
      final corePaint = Paint()..color = palette.accent;
      canvas.drawCircle(Offset(bx, by), 3.5, corePaint);

      // White center highlight
      final centerPaint = Paint()..color = Colors.white;
      canvas.drawCircle(Offset(bx, by), 1.3, centerPaint);
    }

    // 7. Divider between plot and GR meter
    final divX = w - meterWidth - 4.0;
    final divPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.35)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(divX, topPad), Offset(divX, topPad + ph), divPaint);

    // 8. GR (Gain Reduction) Meter on the right
    final meterX = w - meterWidth + 6.0;
    const trackW = 10.0;
    final trackY = topPad + 14.0;
    final trackH = ph - 24.0;

    // "GR" title
    final grTitleTp = TextPainter(
      text: TextSpan(
        text: 'GR',
        style: monoOf(palette, size: 8, color: palette.textDim).copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    grTitleTp.paint(canvas, Offset(meterX + (trackW - grTitleTp.width) / 2, topPad - 2));

    // Track background
    final trackRRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(meterX, trackY, trackW, trackH),
      const Radius.circular(2.0),
    );
    final trackPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.25)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(trackRRect, trackPaint);

    // GR Fill (pushes down from 0dB at top to -18dB at bottom)
    if (active && grDb > 0.05) {
      final grFrac = (grDb / 18.0).clamp(0.0, 1.0);
      final fillH = grFrac * trackH;
      final fillRect = Rect.fromLTWH(meterX, trackY, trackW, fillH);
      final grShader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          palette.warning,
          palette.accent2,
        ],
      ).createShader(fillRect);
      final grBarPaint = Paint()
        ..shader = grShader
        ..style = PaintingStyle.fill;
      canvas.drawRRect(
        RRect.fromRectAndRadius(fillRect, const Radius.circular(2.0)),
        grBarPaint,
      );
    }

    // Tick marks on GR meter (0, -6, -12, -18)
    final grTicks = [0.0, 6.0, 12.0, 18.0];
    for (final tick in grTicks) {
      final ty = trackY + (tick / 18.0) * trackH;
      final tickPaint = Paint()
        ..color = palette.hairline.withValues(alpha: 0.4)
        ..strokeWidth = 0.8;
      canvas.drawLine(Offset(meterX + trackW + 1, ty), Offset(meterX + trackW + 4, ty), tickPaint);

      if (tick > 0) {
        final tickTp = TextPainter(
          text: TextSpan(
            text: '-${tick.toInt()}',
            style: monoOf(palette, size: 7, color: palette.textDim.withValues(alpha: 0.6)),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tickTp.paint(canvas, Offset(meterX + trackW + 5, ty - tickTp.height / 2));
      }
    }

    // Numerical readout at the bottom of GR meter
    final readText = (active && grDb > 0.1) ? '-${grDb.toStringAsFixed(1)}' : '0.0';
    final readTp = TextPainter(
      text: TextSpan(
        text: readText,
        style: monoOf(
          palette,
          size: 8,
          color: (active && grDb > 0.5) ? palette.warning : palette.textDim,
        ).copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    readTp.paint(canvas, Offset(meterX + (trackW - readTp.width) / 2, trackY + trackH + 3));
  }

  @override
  bool shouldRepaint(covariant _CompressorPainter oldDelegate) {
    return oldDelegate.active != active ||
        oldDelegate.threshold != threshold ||
        oldDelegate.ratio != ratio ||
        oldDelegate.knee != knee ||
        oldDelegate.makeup != makeup ||
        oldDelegate.inDb != inDb ||
        oldDelegate.grDb != grDb ||
        oldDelegate.palette != palette;
  }
}
