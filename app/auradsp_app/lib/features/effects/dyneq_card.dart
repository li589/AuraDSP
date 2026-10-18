// part of effects_page.dart —— 全参数动态EQ卡（pre-vendor 音色修整，shelf 之后）。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 00C Dynamic EQ（全参数动态均衡器）----
 * 主卡 = 总开关 + 包络时间（attack/release 全局共用）；
 * 三段（Low shelf / Mid bell / High shelf）各：开关 + 频率 + Q +
 * 静态增益 + 动态量 + 阈值。阈下只做静态整形，超阈后按 range 衰减该频段。 */
class _DyneCard extends StatelessWidget {
  final AppModel model;
  const _DyneCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = model;
    return SectionCard(
      index: kEffectCardIndex['dyneq'],
      title: l.dyneqTitle,
      titleTooltip: l.dyneqHint,
      collapsed: !m.dyneqOn,
      latencyMs: m.componentLatency('dyneq').ms,
      latencyMeasured: m.componentLatency('dyneq').measured,
      latencyEstimated: m.componentLatency('dyneq').estimated,
      latencyProbing: m.isProbingLatency('dyneq'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('dyneq')
          ? () => m.refreshComponentLatency('dyneq')
          : null,
      latencyTick: m.getComponentLatencyTick('dyneq'),
      trailing: AuraSwitch(
        value: m.dyneqOn,
        onChanged: m.setDyneqEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 商业级动态均衡频响图示（对数频率网格 + 3段频响叠加曲线 + 动态受控衰减带）
          _DynamicEqScope(model: m, palette: p),
          const SizedBox(height: AuraSpace.sm),
          // 包络时间（全局共用）
          ValueSlider(
            label: l.dyneqAttack,
            infoMessage: '频段能量越过阈值后压下来的速度。太慢吃掉瞬态，太快可能有咔哒感。',
            value: m.dyneqAttackMs,
            defaultValue: ParamDefaults.dyneqAttack,
            onResetToDefault: () =>
                m.setDyneqAttack(ParamDefaults.dyneqAttack),
            min: 0.1,
            max: 100,
            unit: 'ms',
            enabled: m.dyneqOn,
            format: (v) => v.toStringAsFixed(1),
            onChanged: m.setDyneqAttack,
            onChangedEnd: m.setDyneqAttack,
          ),
          const SizedBox(height: AuraSpace.sm),
          ValueSlider(
            label: l.dyneqRelease,
            infoMessage: '能量跌回阈值以下后松开的速度。太短会有抽吸感，太长压住不放。',
            value: m.dyneqReleaseMs,
            defaultValue: ParamDefaults.dyneqRelease,
            onResetToDefault: () =>
                m.setDyneqRelease(ParamDefaults.dyneqRelease),
            min: 10,
            max: 1000,
            unit: 'ms',
            enabled: m.dyneqOn,
            format: (v) => v.toStringAsFixed(0),
            onChanged: m.setDyneqRelease,
            onChangedEnd: m.setDyneqRelease,
          ),
          const SizedBox(height: AuraSpace.md),
          _DyneBand(model: m, band: 0),
          const SizedBox(height: AuraSpace.md),
          _DyneBand(model: m, band: 1),
          const SizedBox(height: AuraSpace.md),
          _DyneBand(model: m, band: 2),
          const SizedBox(height: AuraSpace.sm),
          ChannelRoutingSelector(
            model: m,
            paramKey: 'dyneq.channels',
          ),
        ],
      ),
    );
  }
}

class _DyneBand extends StatelessWidget {
  final AppModel model;
  final int band; // 0=Low shelf / 1=Mid bell / 2=High shelf
  const _DyneBand({required this.model, required this.band});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = model;
    final String bandLabel =
        band == 0 ? l.dyneqBandLow : (band == 1 ? l.dyneqBandMid : l.dyneqBandHigh);
    final bool bandOn = band == 0 ? m.dyneqLowOn : (band == 1 ? m.dyneqMidOn : m.dyneqHighOn);
    final double freq = band == 0 ? m.dyneqLowFreq : (band == 1 ? m.dyneqMidFreq : m.dyneqHighFreq);
    final double q = band == 0 ? m.dyneqLowQ : (band == 1 ? m.dyneqMidQ : m.dyneqHighQ);
    final double gain = band == 0 ? m.dyneqLowGain : (band == 1 ? m.dyneqMidGain : m.dyneqHighGain);
    final double range = band == 0 ? m.dyneqLowRange : (band == 1 ? m.dyneqMidRange : m.dyneqHighRange);
    final double threshold = band == 0
        ? m.dyneqLowThreshold
        : (band == 1 ? m.dyneqMidThreshold : m.dyneqHighThreshold);
    void Function(bool) setBandOn = band == 0
        ? m.setDyneqLowEnabled
        : (band == 1 ? m.setDyneqMidEnabled : m.setDyneqHighEnabled);
    void Function(double) setFreq = band == 0
        ? m.setDyneqLowFreq
        : (band == 1 ? m.setDyneqMidFreq : m.setDyneqHighFreq);
    void Function(double) setQ = band == 0
        ? m.setDyneqLowQ
        : (band == 1 ? m.setDyneqMidQ : m.setDyneqHighQ);
    void Function(double) setGain = band == 0
        ? m.setDyneqLowGain
        : (band == 1 ? m.setDyneqMidGain : m.setDyneqHighGain);
    void Function(double) setRange = band == 0
        ? m.setDyneqLowRange
        : (band == 1 ? m.setDyneqMidRange : m.setDyneqHighRange);
    void Function(double) setThreshold = band == 0
        ? m.setDyneqLowThreshold
        : (band == 1 ? m.setDyneqMidThreshold : m.setDyneqHighThreshold);
    final double defFreq = band == 0
        ? ParamDefaults.dyneqLowFreq
        : (band == 1 ? ParamDefaults.dyneqMidFreq : ParamDefaults.dyneqHighFreq);
    final double defQ = band == 0
        ? ParamDefaults.dyneqLowQ
        : (band == 1 ? ParamDefaults.dyneqMidQ : ParamDefaults.dyneqHighQ);
    final double defGain = band == 0
        ? ParamDefaults.dyneqLowGain
        : (band == 1 ? ParamDefaults.dyneqMidGain : ParamDefaults.dyneqHighGain);
    final double defRange = band == 0
        ? ParamDefaults.dyneqLowRange
        : (band == 1 ? ParamDefaults.dyneqMidRange : ParamDefaults.dyneqHighRange);
    final double defThreshold = band == 0
        ? ParamDefaults.dyneqLowThreshold
        : (band == 1 ? ParamDefaults.dyneqMidThreshold : ParamDefaults.dyneqHighThreshold);
    final double freqMin = band == 0 ? 20 : (band == 1 ? 200 : 2000);
    final double freqMax = band == 0 ? 500 : (band == 1 ? 8000 : 20000);
    final double qMin = band == 1 ? 0.3 : 0.5;
    final double qMax = band == 1 ? 10 : 2;
    final bool en = m.dyneqOn && bandOn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(bandLabel, style: labelOf(p, color: p.text)),
            const Spacer(),
            if (m.dyneqOn && bandOn) ...[
              MiniGainReductionBar(
                grListenable: band == 0
                    ? m.grDyneqLow
                    : (band == 1 ? m.grDyneqMid : m.grDyneqHigh),
                width: 56.0,
                height: 6.0,
              ),
              const SizedBox(width: AuraSpace.sm),
            ],
            AuraSwitch(
              value: bandOn,
              onChanged: m.dyneqOn ? setBandOn : null,
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqFreq,
          value: freq,
          defaultValue: defFreq,
          onResetToDefault: () => setFreq(defFreq),
          min: freqMin,
          max: freqMax,
          unit: 'Hz',
          enabled: en,
          format: (v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0),
          onChanged: setFreq,
          onChangedEnd: setFreq,
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqQ,
          infoMessage: 'Mid 为钟形带宽；Low/High 为搁架斜率共振。',
          value: q,
          defaultValue: defQ,
          onResetToDefault: () => setQ(defQ),
          min: qMin,
          max: qMax,
          unit: '',
          enabled: en,
          format: (v) => v.toStringAsFixed(2),
          onChanged: setQ,
          onChangedEnd: setQ,
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqGain,
          infoMessage: '静态基础增益，常时有效；动态部分只做衰减。',
          value: gain,
          defaultValue: defGain,
          onResetToDefault: () => setGain(defGain),
          min: -12,
          max: 12,
          unit: 'dB',
          enabled: en,
          format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
          onChanged: setGain,
          onChangedEnd: setGain,
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqRange,
          infoMessage: '频段能量超阈后最大再衰减多少。0 = 纯静态整形。',
          value: range,
          defaultValue: defRange,
          onResetToDefault: () => setRange(defRange),
          min: 0,
          max: 24,
          unit: 'dB',
          enabled: en,
          format: (v) => v.toStringAsFixed(1),
          onChanged: setRange,
          onChangedEnd: setRange,
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqThreshold,
          infoMessage: '该频段包络超过此电平才开始动态衰减。太低误杀，太高不动作。',
          value: threshold,
          defaultValue: defThreshold,
          onResetToDefault: () => setThreshold(defThreshold),
          min: -60,
          max: 0,
          unit: 'dB',
          enabled: en,
          format: (v) => v.toStringAsFixed(0),
          onChanged: setThreshold,
          onChangedEnd: setThreshold,
        ),
        const SizedBox(height: AuraSpace.xs),
        Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            dense: true,
            tilePadding: EdgeInsets.zero,
            childrenPadding: EdgeInsets.zero,
            title: Text('独立动态响应时常数', style: monoOf(p, size: 10, color: p.textDim)),
            children: [
              ValueSlider(
                label: '$bandLabel Attack',
                infoMessage: '该频段专用的起音时间。',
                value: band == 0 ? m.dyneqB1Attack : (band == 1 ? m.dyneqB2Attack : m.dyneqB3Attack),
                defaultValue: 2.0,
                onResetToDefault: () {
                  if (band == 0) {
                    m.setDyneqB1Attack(2.0);
                  } else if (band == 1) {
                    m.setDyneqB2Attack(2.0);
                  } else {
                    m.setDyneqB3Attack(2.0);
                  }
                },
                min: 0.1,
                max: 100,
                unit: 'ms',
                enabled: en,
                format: (v) => v.toStringAsFixed(1),
                onChanged: (v) {
                  if (band == 0) {
                    m.setDyneqB1Attack(v);
                  } else if (band == 1) {
                    m.setDyneqB2Attack(v);
                  } else {
                    m.setDyneqB3Attack(v);
                  }
                },
              ),
              const SizedBox(height: AuraSpace.xs),
              ValueSlider(
                label: '$bandLabel Release',
                infoMessage: '该频段专用的释放时间。',
                value: band == 0 ? m.dyneqB1Release : (band == 1 ? m.dyneqB2Release : m.dyneqB3Release),
                defaultValue: 120.0,
                onResetToDefault: () {
                  if (band == 0) {
                    m.setDyneqB1Release(120.0);
                  } else if (band == 1) {
                    m.setDyneqB2Release(120.0);
                  } else {
                    m.setDyneqB3Release(120.0);
                  }
                },
                min: 10,
                max: 1000,
                unit: 'ms',
                enabled: en,
                format: (v) => v.toStringAsFixed(0),
                onChanged: (v) {
                  if (band == 0) {
                    m.setDyneqB1Release(v);
                  } else if (band == 1) {
                    m.setDyneqB2Release(v);
                  } else {
                    m.setDyneqB3Release(v);
                  }
                },
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// 商业级动态均衡器频响特性图（FabFilter / Ozone 风格）
class _DynamicEqScope extends StatelessWidget {
  final AppModel model;
  final AuraPalette palette;

  const _DynamicEqScope({
    required this.model,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 124,
      decoration: BoxDecoration(
        color: palette.panel.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: palette.hairline.withValues(alpha: 0.4), width: 1.0),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        child: RepaintBoundary(
          child: CustomPaint(
            size: const Size(double.infinity, 124),
            painter: _DynamicEqPainter(
              active: model.dyneqOn,
              palette: palette,
              lowOn: model.dyneqLowOn,
              lowFreq: model.dyneqLowFreq,
              lowGain: model.dyneqLowGain,
              lowRange: model.dyneqLowRange,
              midOn: model.dyneqMidOn,
              midFreq: model.dyneqMidFreq,
              midQ: model.dyneqMidQ,
              midGain: model.dyneqMidGain,
              midRange: model.dyneqMidRange,
              highOn: model.dyneqHighOn,
              highFreq: model.dyneqHighFreq,
              highGain: model.dyneqHighGain,
              highRange: model.dyneqHighRange,
            ),
          ),
        ),
      ),
    );
  }
}

class _DynamicEqPainter extends CustomPainter {
  final bool active;
  final AuraPalette palette;
  final bool lowOn;
  final double lowFreq;
  final double lowGain;
  final double lowRange;
  final bool midOn;
  final double midFreq;
  final double midQ;
  final double midGain;
  final double midRange;
  final bool highOn;
  final double highFreq;
  final double highGain;
  final double highRange;

  _DynamicEqPainter({
    required this.active,
    required this.palette,
    required this.lowOn,
    required this.lowFreq,
    required this.lowGain,
    required this.lowRange,
    required this.midOn,
    required this.midFreq,
    required this.midQ,
    required this.midGain,
    required this.midRange,
    required this.highOn,
    required this.highFreq,
    required this.highGain,
    required this.highRange,
  });

  static const double _minF = 20.0;
  static const double _maxF = 20000.0;
  static const double _maxGain = 18.0;

  double _freqToX(double f, double left, double width) {
    final logMin = math.log(_minF);
    final logMax = math.log(_maxF);
    final clampedF = f.clamp(_minF, _maxF);
    return left + width * ((math.log(clampedF) - logMin) / (logMax - logMin));
  }

  double _gainToY(double g, double cy, double halfH) {
    final clampedG = g.clamp(-_maxGain, _maxGain);
    return cy - (clampedG / _maxGain) * halfH;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    const leftPad = 26.0;
    const rightPad = 14.0;
    const topPad = 12.0;
    const botPad = 18.0;
    final plotW = w - leftPad - rightPad;
    final plotH = h - topPad - botPad;
    final cy = topPad + plotH / 2.0;
    final halfH = plotH / 2.0;

    // ── 1. 对数频率网格与标尺 ──
    final gridPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.18)
      ..strokeWidth = 0.8;

    final freqs = [50.0, 100.0, 200.0, 500.0, 1000.0, 2000.0, 5000.0, 10000.0];
    for (final f in freqs) {
      final x = _freqToX(f, leftPad, plotW);
      canvas.drawLine(Offset(x, topPad), Offset(x, topPad + plotH), gridPaint);
    }

    // Horizontal gain lines (+12dB, -12dB)
    for (final g in [12.0, -12.0]) {
      final y = _gainToY(g, cy, halfH);
      canvas.drawLine(Offset(leftPad, y), Offset(w - rightPad, y), gridPaint);
    }

    // 0dB Center reference line (subtle dash / accent)
    final zeroLinePaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.35)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(leftPad, cy), Offset(w - rightPad, cy), zeroLinePaint);

    // Labels at left (+12, 0, -12)
    void drawGainLabel(String text, double g) {
      final y = _gainToY(g, cy, halfH);
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: monoOf(palette, size: 7.5, color: palette.textDim.withValues(alpha: 0.6)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(leftPad - tp.width - 4.0, y - tp.height / 2.0));
    }

    drawGainLabel('+12', 12.0);
    drawGainLabel('0', 0.0);
    drawGainLabel('-12', -12.0);

    // Freq Labels along bottom
    void drawFreqLabel(String text, double f) {
      final x = _freqToX(f, leftPad, plotW);
      final tp = TextPainter(
        text: TextSpan(
          text: text,
          style: monoOf(palette, size: 7.5, color: palette.textDim.withValues(alpha: 0.6)),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x - tp.width / 2.0, topPad + plotH + 4.0));
    }

    drawFreqLabel('100', 100.0);
    drawFreqLabel('1k', 1000.0);
    drawFreqLabel('10k', 10000.0);

    // ── 2. 计算动态 EQ 静态曲线与动态受控衰减带 ──
    const steps = 100;
    final staticPoints = <Offset>[];
    final dynPoints = <Offset>[];

    for (var i = 0; i <= steps; i++) {
      final t = i / steps.toDouble();
      final f = _minF * math.pow(_maxF / _minF, t);
      final x = leftPad + plotW * t;

      // Low shelf
      final gl = lowOn ? (lowGain / (1.0 + math.pow(f / lowFreq, 2.0))) : 0.0;
      final dl = lowOn ? ((lowGain - lowRange) / (1.0 + math.pow(f / lowFreq, 2.0))) : 0.0;

      // Mid bell
      final u = math.log(f / midFreq) * midQ;
      final gm = midOn ? (midGain / (1.0 + u * u)) : 0.0;
      final dm = midOn ? ((midGain - midRange) / (1.0 + u * u)) : 0.0;

      // High shelf
      final gh = highOn ? (highGain / (1.0 + math.pow(highFreq / f, 2.0))) : 0.0;
      final dh = highOn ? ((highGain - highRange) / (1.0 + math.pow(highFreq / f, 2.0))) : 0.0;

      final totalStatic = gl + gm + gh;
      final totalDyn = dl + dm + dh;

      final ys = _gainToY(totalStatic, cy, halfH);
      final yd = _gainToY(totalDyn, cy, halfH);

      staticPoints.add(Offset(x, ys));
      dynPoints.add(Offset(x, yd));
    }

    // Draw dynamic range shading band
    if (active) {
      final bandPath = Path();
      bandPath.moveTo(staticPoints.first.dx, staticPoints.first.dy);
      for (final pt in staticPoints) {
        bandPath.lineTo(pt.dx, pt.dy);
      }
      for (var i = dynPoints.length - 1; i >= 0; i--) {
        bandPath.lineTo(dynPoints[i].dx, dynPoints[i].dy);
      }
      bandPath.close();

      final bandPaint = Paint()
        ..color = palette.warning.withValues(alpha: 0.16)
        ..style = PaintingStyle.fill;
      canvas.drawPath(bandPath, bandPaint);

      // Dyn curve bottom boundary dashed line
      final dynLinePaint = Paint()
        ..color = palette.warning.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0;
      final dynPath = Path()..moveTo(dynPoints.first.dx, dynPoints.first.dy);
      for (final pt in dynPoints) {
        dynPath.lineTo(pt.dx, pt.dy);
      }
      canvas.drawPath(dynPath, dynLinePaint);
    }

    // Draw main static EQ response curve
    final curvePath = Path()..moveTo(staticPoints.first.dx, staticPoints.first.dy);
    for (final pt in staticPoints) {
      curvePath.lineTo(pt.dx, pt.dy);
    }
    final curvePaint = Paint()
      ..color = active ? palette.accent : palette.textDim
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(curvePath, curvePaint);

    // ── 3. 绘制 3 段频点控制锚点 ──
    void drawAnchor(bool on, double freq, double gain, String label, Color color) {
      final ax = _freqToX(freq, leftPad, plotW);
      final ay = _gainToY(gain, cy, halfH);

      // Faint vertical guide to 0dB line
      final guidePaint = Paint()
        ..color = (on && active ? color : palette.textDim).withValues(alpha: 0.25)
        ..strokeWidth = 0.8;
      canvas.drawLine(Offset(ax, cy), Offset(ax, ay), guidePaint);

      // Glow halo
      if (on && active) {
        final glow = Paint()
          ..color = color.withValues(alpha: 0.4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0);
        canvas.drawCircle(Offset(ax, ay), 5.5, glow);
      }

      // Outer node
      final nodePaint = Paint()
        ..color = palette.panelRaised
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(ax, ay), 3.5, nodePaint);

      final strokePaint = Paint()
        ..color = (on && active) ? color : palette.textDim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(Offset(ax, ay), 3.5, strokePaint);

      // Inner dot
      final innerDot = Paint()
        ..color = (on && active) ? color : palette.textDim
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(ax, ay), 1.5, innerDot);

      // Pill label badge
      final tp = TextPainter(
        text: TextSpan(
          text: label,
          style: monoOf(palette, size: 7.5, color: (on && active) ? color : palette.textDim)
              .copyWith(fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final labelY = (gain >= 0) ? (ay - tp.height - 4.0) : (ay + 4.0);
      tp.paint(canvas, Offset(ax - tp.width / 2.0, labelY));
    }

    drawAnchor(
      lowOn,
      lowFreq,
      lowGain,
      'L · ${lowFreq.toInt()}Hz',
      palette.accent,
    );
    drawAnchor(
      midOn,
      midFreq,
      midGain,
      'M · ${(midFreq >= 1000 ? "${(midFreq / 1000).toStringAsFixed(1)}k" : midFreq.toInt().toString())}Hz',
      palette.warning,
    );
    drawAnchor(
      highOn,
      highFreq,
      highGain,
      'H · ${(highFreq / 1000).toStringAsFixed(1)}k',
      palette.accent2,
    );
  }

  @override
  bool shouldRepaint(_DynamicEqPainter old) =>
      old.active != active ||
      old.palette != palette ||
      old.lowOn != lowOn ||
      old.lowFreq != lowFreq ||
      old.lowGain != lowGain ||
      old.lowRange != lowRange ||
      old.midOn != midOn ||
      old.midFreq != midFreq ||
      old.midQ != midQ ||
      old.midGain != midGain ||
      old.midRange != midRange ||
      old.highOn != highOn ||
      old.highFreq != highFreq ||
      old.highGain != highGain ||
      old.highRange != highRange;
}

