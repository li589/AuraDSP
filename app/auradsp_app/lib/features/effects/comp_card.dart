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
          // 商业级动态响应传输曲线与 GR 衰减条（Ticker 驱动平滑回弹）
          _CompressorTransferScope(model: model),
          const SizedBox(height: AuraSpace.sm),

          // 核心滑块 1：压缩阈值 (Threshold)
          ParamSlider(
            param: ParamRegistry.compThreshold,
            model: model,
            customLabel: '压缩阈值',
            infoMessage: '信号触发动态压限的音量临界门槛。低于此门槛的声音保持原样，高于此门槛的声音将被按比例压制，从而压制过激瞬态。',
          ),
          const SizedBox(height: AuraSpace.sm),

          // 核心滑块 2：压缩比率 (Ratio)
          ParamSlider(
            param: ParamRegistry.compRatio,
            model: model,
            customLabel: '压缩比率',
            infoMessage: '超过阈值部分的衰减陡峭程度。数值越高压制越强（如 10:1 几乎成为限幅），数值越低声音动态越温和通透。',
          ),
          const SizedBox(height: AuraSpace.sm),

          // 核心滑块 3：响应时常数（Time Constant）
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
            summary: '${model.compThreshold.toStringAsFixed(0)} dB · ${model.compRatio.toStringAsFixed(1)}:1 · AGC: ${model.compAutoGain ? "ON" : "OFF"} · ${(model.compOutputGain >= 0 ? "+" : "")}${model.compOutputGain.toStringAsFixed(1)} dB',
            builder: (ctx) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 分析颗粒度模式 (Granularity)
                Row(
                  children: [
                    Text(l.compGranularity, style: labelOf(p, color: p.text)),
                    const SizedBox(width: 4),
                    const InfoBadge(message: '频域分析带宽精细度。粗糙模式响应极快、适合电子流行；精细模式分频更精准、适合人声器乐。'),
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
                    const SizedBox(width: 4),
                    const InfoBadge(message: '算法滤波器时间常数策略。瞬态模式保留微动态；平衡模式通用；零延迟模式无缓冲延迟。'),
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

                // 3. 七频带独立压限频率与增益微调
                Text(
                  '分频段动态压限微调 (7 Bands)',
                  style: labelOf(p, color: p.text).copyWith(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: AuraSpace.xs),
                Text(
                  '可对 7 个频带分别自定义分频中心频率与压限/扩展数值（负值为动态压制，正值为动态扩展）。',
                  style: captionOf(p),
                ),
                const SizedBox(height: AuraSpace.sm),
                Column(
                  children: [
                    for (var i = 0; i < 7; i++) ...[
                      _CompBandRow(
                        bandIndex: i,
                        model: model,
                        palette: p,
                      ),
                      if (i < 6) const SizedBox(height: AuraSpace.xs),
                    ],
                  ],
                ),
                const SizedBox(height: AuraSpace.md),

                // 4. 输出级外框（自动增益补偿与输出增益门）
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
                const SizedBox(height: AuraSpace.sm),
                ChannelRoutingSelector(
                  model: model,
                  paramKey: 'comp.channels',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 7 频带单带独立分频频率 + 动态增益调谐条
class _CompBandRow extends StatelessWidget {
  static const _bandNames = ['极低频', '低频', '中低频', '中频', '中高频', '高频', '超高频'];
  static const _defaultFreqs = [95.0, 200.0, 400.0, 800.0, 1600.0, 3400.0, 7500.0];
  static const _ranges = [
    (30.0, 250.0),
    (80.0, 500.0),
    (180.0, 1000.0),
    (350.0, 2200.0),
    (700.0, 4500.0),
    (1500.0, 9000.0),
    (3000.0, 18000.0),
  ];

  final int bandIndex;
  final AppModel model;
  final AuraPalette palette;

  const _CompBandRow({
    required this.bandIndex,
    required this.model,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final curFreq = model.compFreqs[bandIndex];
    final curGain = model.compGains[bandIndex];
    final defaultFreq = _defaultFreqs[bandIndex];
    final (minFreq, maxFreq) = _ranges[bandIndex];
    final name = _bandNames[bandIndex];

    final freqStr = curFreq >= 1000
        ? '${(curFreq / 1000).toStringAsFixed(1)} kHz'
        : '${curFreq.toStringAsFixed(0)} Hz';
    final gainStr = '${curGain >= 0 ? "+" : ""}${curGain.toStringAsFixed(2)}';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: AuraSpace.xs),
      decoration: BoxDecoration(
        color: palette.panel.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: palette.hairline.withValues(alpha: 0.3)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Band ${bandIndex + 1} ($name)',
                style: monoOf(palette, size: 10, color: palette.text).copyWith(fontWeight: FontWeight.w600),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: palette.accent.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                ),
                child: Text(
                  freqStr,
                  style: monoOf(palette, size: 9, color: palette.accent).copyWith(fontWeight: FontWeight.w600),
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                decoration: BoxDecoration(
                  color: (curGain < 0 ? palette.warning : palette.accent2).withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                ),
                child: Text(
                  gainStr,
                  style: monoOf(palette, size: 9, color: curGain < 0 ? palette.warning : palette.accent2)
                      .copyWith(fontWeight: FontWeight.w600),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          ValueSlider(
            label: '分频中心频率',
            value: curFreq,
            defaultValue: defaultFreq,
            min: minFreq,
            max: maxFreq,
            unit: 'Hz',
            enabled: model.compOn,
            format: (v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0),
            onChanged: (v) => model.setCompFreq(bandIndex, v),
            onChangedEnd: (v) => model.setCompFreq(bandIndex, v),
            onResetToDefault: () => model.setCompFreq(bandIndex, defaultFreq),
          ),
          ValueSlider(
            label: '压限 / 扩展数值',
            infoMessage: '负值为动态压缩压制，正值为动态扩展。默认 -0.35。',
            value: curGain,
            defaultValue: -0.35,
            min: -1.2,
            max: 1.2,
            unit: '',
            enabled: model.compOn,
            format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(2),
            onChanged: (v) => model.setCompGain(bandIndex, v),
            onChangedEnd: (v) => model.setCompGain(bandIndex, v),
            onResetToDefault: () => model.setCompGain(bandIndex, -0.35),
          ),
        ],
      ),
    );
  }
}

/// 商业级动态压限特性传输曲线与实时 Gain Reduction 衰减表（物理 Ticker 驱动，告别停滞）
class _CompressorTransferScope extends StatefulWidget {
  final AppModel model;
  const _CompressorTransferScope({required this.model});

  @override
  State<_CompressorTransferScope> createState() => _CompressorTransferScopeState();
}

class _CompressorTransferScopeState extends State<_CompressorTransferScope>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _smoothGr = 0.0;
  double _targetGr = 0.0;
  double _smoothInDb = -48.0;
  double _targetInDb = -48.0;
  Duration _lastElapsed = Duration.zero;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.model.levelL.addListener(_updateTarget);
    widget.model.levelR.addListener(_updateTarget);
    widget.model.grComp.addListener(_updateTarget);
    widget.model.addListener(_onModelChanged);
    TrayService.instance.isWindowVisible.addListener(_onVisibilityChanged);
    _updateTarget();
  }

  void _onVisibilityChanged() {
    if (!TrayService.instance.isWindowVisible.value) {
      if (_ticker.isActive) {
        _ticker.stop();
        _lastElapsed = Duration.zero;
      }
    } else if (widget.model.compOn) {
      _updateTarget();
    }
  }

  @override
  void dispose() {
    TrayService.instance.isWindowVisible.removeListener(_onVisibilityChanged);
    _ticker.dispose();
    widget.model.levelL.removeListener(_updateTarget);
    widget.model.levelR.removeListener(_updateTarget);
    widget.model.grComp.removeListener(_updateTarget);
    widget.model.removeListener(_onModelChanged);
    super.dispose();
  }

  void _onModelChanged() {
    _updateTarget();
    if (mounted && widget.model.compOn && TrayService.instance.isWindowVisible.value) {
      setState(() {});
    }
  }

  void _updateTarget() {
    final model = widget.model;
    if (!model.compOn || !TrayService.instance.isWindowVisible.value) {
      if (_ticker.isActive) {
        _ticker.stop();
        _lastElapsed = Duration.zero;
      }
      return;
    }

    final inDb = math.max(model.levelL.value, model.levelR.value);
    _targetInDb = inDb.clamp(-48.0, 0.0);

    // 优先采用 C++ 引擎实时输出的精确物理 GR 检波值
    final engineGr = model.grComp.value.abs().clamp(0.0, 24.0);
    if (engineGr > 0.05) {
      _targetGr = engineGr;
    } else {
      final threshold = model.compThreshold;
      final ratio = model.compRatio;
      const knee = 10.0;

      double target = 0.0;
      if (inDb > -48.0) {
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
        target = (inDb - yRaw).clamp(0.0, 24.0);
      }
      _targetGr = target;
    }

    // 瞬态响应 (Attack)
    if (_targetInDb >= _smoothInDb) {
      _smoothInDb = _targetInDb;
    }
    if (_targetGr >= _smoothGr) {
      _smoothGr = _targetGr;
    }

    // 若有电平流动或衰减需求且物理时钟未开，启动 Ticker
    final needsAnimation = _smoothInDb > -46.0 ||
        _targetInDb > -46.0 ||
        _smoothGr > 0.01 ||
        _targetGr > 0.01;

    if (needsAnimation && !_ticker.isActive) {
      _lastElapsed = Duration.zero;
      _ticker.start();
    }
    if (mounted) setState(() {});
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    if (!widget.model.compOn || !TrayService.instance.isWindowVisible.value) {
      if (_ticker.isActive) {
        _ticker.stop();
        _lastElapsed = Duration.zero;
      }
      return;
    }
    if (_lastElapsed == Duration.zero) {
      _lastElapsed = elapsed;
      return;
    }
    final dt = (elapsed - _lastElapsed).inMicroseconds / 1000000.0;
    _lastElapsed = elapsed;

    // 1. 电平物理小球平滑跟随
    final inDecay = math.exp(-dt / 0.12); // ~120ms 释放
    if (_targetInDb >= _smoothInDb) {
      _smoothInDb = _targetInDb;
    } else {
      _smoothInDb = _smoothInDb * inDecay + _targetInDb * (1.0 - inDecay);
    }

    // 2. 衰减表 Gain Reduction 物理平滑跟踪
    final tc = widget.model.compTimeconstant.clamp(0.02, 0.5);
    final grDecay = math.exp(-dt / tc);
    if (_targetGr >= _smoothGr) {
      _smoothGr = _targetGr;
    } else {
      _smoothGr = _smoothGr * grDecay + _targetGr * (1.0 - grDecay);
    }

    final isQuiet = _smoothInDb <= -47.0 &&
        _targetInDb <= -47.0 &&
        _smoothGr <= 0.02 &&
        _targetGr <= 0.01;

    if (isQuiet) {
      _smoothGr = 0.0;
      _smoothInDb = -48.0;
      if (_ticker.isActive) {
        _ticker.stop();
        _lastElapsed = Duration.zero;
      }
    }
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final model = widget.model;
    final threshold = model.compThreshold;
    final ratio = model.compRatio;
    const knee = 10.0;
    final makeup = model.compOutputGain + (model.compAutoGain ? 3.5 : 0.0);

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
              inDb: _smoothInDb,
              grDb: _smoothGr,
            ),
          ),
        ),
      ),
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
