// part of effects_page.dart —— 动态增益衰减计量 (Gain Reduction Meter) 与过采样徽标
part of '../effects_page.dart';

/* =========================================================================
 * 1. 垂直下坠式 GR 仪表 (Gain Reduction Meter)
 * 母带级动态处理器视觉基石：顶部为 0 dBFS，电平越过阈值后自顶向下向下坠落，
 * 采用 3 阶声学色彩动力学 (琥珀/橙红/猩红) + Peak-Hold 峰值保持线。
 * ========================================================================= */

class GainReductionMeter extends StatefulWidget {
  final ValueListenable<double> grListenable;
  final String label;
  final double height;
  final double width;
  final double maxDb;

  const GainReductionMeter({
    super.key,
    required this.grListenable,
    this.label = 'GR',
    this.height = 140.0,
    this.width = 32.0,
    this.maxDb = 24.0,
  });

  @override
  State<GainReductionMeter> createState() => _GainReductionMeterState();
}

class _GainReductionMeterState extends State<GainReductionMeter>
    with SingleTickerProviderStateMixin {
  late final Ticker _ticker;
  double _currentGr = 0.0;
  double _peakGr = 0.0;
  int _peakHoldFrames = 0;
  static const int kHoldFrames = 25; // ~400ms peak hold at 60fps

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_onTick);
    widget.grListenable.addListener(_onGrChanged);
    final v = widget.grListenable.value.abs().clamp(0.0, widget.maxDb);
    _currentGr = v;
    _peakGr = v;
  }

  void _onGrChanged() {
    final v = widget.grListenable.value.abs().clamp(0.0, widget.maxDb);
    _currentGr = v;
    if (v >= _peakGr) {
      _peakGr = v;
      _peakHoldFrames = kHoldFrames;
    }
    if ((_currentGr > 0.05 || _peakGr > 0.05) &&
        !_ticker.isActive &&
        mounted &&
        PlatformAdapters.instance.window.isVisible) {
      _ticker.start();
    }
  }

  void _onTick(Duration elapsed) {
    if (!mounted) return;
    if (!PlatformAdapters.instance.window.isVisible) {
      if (_ticker.isActive) _ticker.stop();
      return;
    }

    bool needRepaint = false;
    // 峰值保持与缓慢衰减
    if (_peakHoldFrames > 0) {
      _peakHoldFrames--;
    } else if (_peakGr > _currentGr) {
      _peakGr = math.max(_currentGr, _peakGr - 0.6); // 衰减速率
      needRepaint = true;
    }

    if (_currentGr > 0 || _peakGr > 0 || needRepaint) {
      setState(() {});
    } else {
      if (_ticker.isActive) _ticker.stop();
    }
  }

  @override
  void dispose() {
    widget.grListenable.removeListener(_onGrChanged);
    _ticker.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isDormant = _currentGr <= 0.05 && _peakGr <= 0.05;

    return Container(
      width: widget.width,
      height: widget.height,
      padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 2),
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          // 顶部标签与数值
          Text(
            widget.label,
            style: monoOf(p, size: 9, color: p.textDim).copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 2),
          Text(
            _currentGr <= 0.05 ? '0.0' : '-${_currentGr.toStringAsFixed(1)}',
            style: monoOf(
              p,
              size: 8,
              color: isDormant ? p.textDim.withValues(alpha: 0.5) : const Color(0xFFFF9500),
            ).copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 4),
          // 仪表绘制区
          Expanded(
            child: CustomPaint(
              size: Size.infinite,
              painter: _GainReductionMeterPainter(
                currentGr: _currentGr,
                peakGr: _peakGr,
                maxDb: widget.maxDb,
                palette: p,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _GainReductionMeterPainter extends CustomPainter {
  final double currentGr;
  final double peakGr;
  final double maxDb;
  final AuraPalette palette;

  _GainReductionMeterPainter({
    required this.currentGr,
    required this.peakGr,
    required this.maxDb,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final trackRect = Rect.fromLTWH(size.width * 0.45, 0, size.width * 0.45, size.height);
    final bgPaint = Paint()..color = palette.hairline.withValues(alpha: 0.15);
    canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, const Radius.circular(2)),
      bgPaint,
    );

    // 刻度标线 (0, -3, -6, -12, -18, -24)
    final textStyle = TextStyle(
      color: palette.textDim.withValues(alpha: 0.6),
      fontSize: 7.0,
      fontFamily: 'Consolas',
      fontWeight: FontWeight.w500,
    );
    final tickMarks = [0.0, 3.0, 6.0, 12.0, 18.0, 24.0];
    for (final tick in tickMarks) {
      if (tick > maxDb) continue;
      final y = (tick / maxDb) * size.height;
      // 刻度线
      canvas.drawLine(
        Offset(trackRect.left - 3, y.clamp(0.0, size.height - 1)),
        Offset(trackRect.left, y.clamp(0.0, size.height - 1)),
        Paint()
          ..color = palette.hairline.withValues(alpha: 0.4)
          ..strokeWidth = 1.0,
      );
      // 刻度数字
      if (tick == 0 || tick == 6 || tick == 12 || tick == 24) {
        final tp = TextPainter(
          text: TextSpan(text: '${tick.toInt()}', style: textStyle),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(trackRect.left - 4 - tp.width, y - tp.height / 2));
      }
    }

    // 绘制下坠衰减条 (从顶部 0 往下生长)
    if (currentGr > 0.05) {
      final grRatio = (currentGr / maxDb).clamp(0.0, 1.0);
      final fillHeight = size.height * grRatio;
      final fillRect = Rect.fromLTWH(trackRect.left, 0, trackRect.width, fillHeight);

      // 三阶色彩渐变 (0~-3: 金色, -3~-10: 橙红, -10~-24: 霓虹烈红)
      final gradient = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: const [
          Color(0xFFF5A623),
          Color(0xFFFF8A00),
          Color(0xFFFF3B30),
        ],
        stops: const [0.0, 0.45, 1.0],
      );

      final barPaint = Paint()
        ..shader = gradient.createShader(trackRect);
      canvas.drawRRect(
        RRect.fromRectAndRadius(fillRect, const Radius.circular(2)),
        barPaint,
      );
    }

    // 绘制 Peak-Hold 瞬态保持线
    if (peakGr > 0.1) {
      final peakRatio = (peakGr / maxDb).clamp(0.0, 1.0);
      final peakY = (size.height * peakRatio).clamp(1.0, size.height - 1.0);
      canvas.drawLine(
        Offset(trackRect.left - 1, peakY),
        Offset(trackRect.right + 1, peakY),
        Paint()
          ..color = const Color(0xFFFFFFFF)
          ..strokeWidth = 1.5,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _GainReductionMeterPainter oldDelegate) {
    return oldDelegate.currentGr != currentGr ||
        oldDelegate.peakGr != peakGr ||
        oldDelegate.palette != palette;
  }
}

/* =========================================================================
 * 2. 水平紧凑迷你 GR 表 (Mini Gain Reduction Bar)
 * 专为频段、通道等空间受限场景设计：右端为 0 dBFS，自右向左动态收缩。
 * ========================================================================= */

class MiniGainReductionBar extends StatelessWidget {
  final ValueListenable<double> grListenable;
  final double width;
  final double height;
  final double maxDb;

  const MiniGainReductionBar({
    super.key,
    required this.grListenable,
    this.width = 64.0,
    this.height = 6.0,
    this.maxDb = 18.0,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ValueListenableBuilder<double>(
      valueListenable: grListenable,
      builder: (context, grValue, child) {
        final gr = grValue.abs().clamp(0.0, maxDb);
        final ratio = gr / maxDb;
        final hasReduction = gr > 0.05;

        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: width,
              height: height,
              decoration: BoxDecoration(
                color: p.panel.withValues(alpha: 0.8),
                borderRadius: BorderRadius.circular(height / 2),
                border: Border.all(color: p.hairline.withValues(alpha: 0.2)),
              ),
              child: Stack(
                alignment: Alignment.centerRight,
                children: [
                  if (hasReduction)
                    FractionallySizedBox(
                      alignment: Alignment.centerRight,
                      widthFactor: ratio,
                      child: Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(height / 2),
                          gradient: const LinearGradient(
                            begin: Alignment.centerRight,
                            end: Alignment.centerLeft,
                            colors: [
                              Color(0xFFF5A623),
                              Color(0xFFFF5E3A),
                            ],
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 32,
              child: Text(
                hasReduction ? '-${gr.toStringAsFixed(1)}' : '0.0',
                style: monoOf(
                  p,
                  size: 9,
                  color: hasReduction ? const Color(0xFFFF8A00) : p.textDim.withValues(alpha: 0.4),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

/* =========================================================================
 * 3. 噪声门状态指示灯 (Gate Activity Indicator)
 * 实时反馈门控状态：OPEN (导通发光) / HOLD / CLOSED (压制消音)
 * ========================================================================= */

class GateActivityIndicator extends StatelessWidget {
  final ValueListenable<double> grGate;

  const GateActivityIndicator({
    super.key,
    required this.grGate,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ValueListenableBuilder<double>(
      valueListenable: grGate,
      builder: (context, gr, child) {
        // gr 接近 0 时说明完全开门；低于 -12dB 说明几乎全关
        final isOpen = gr > -3.0;
        final isMuted = gr < -15.0;

        Color dotColor;
        String statusText;
        if (isOpen) {
          dotColor = const Color(0xFF2BD48D); // 纯绿通透
          statusText = l10nOf(context).gateStateOpen;
        } else if (isMuted) {
          dotColor = p.textDim.withValues(alpha: 0.4); // 灰色关闭
          statusText = l10nOf(context).gateStateClosed;
        } else {
          dotColor = const Color(0xFFF5A623); // 琥珀正在动作
          statusText = l10nOf(context).gateStateHold;
        }

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: dotColor.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: dotColor.withValues(alpha: 0.3)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  boxShadow: isOpen
                      ? [
                          BoxShadow(
                            color: dotColor.withValues(alpha: 0.6),
                            blurRadius: 4,
                            spreadRadius: 1,
                          )
                        ]
                      : null,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                statusText,
                style: monoOf(p, size: 9, color: dotColor).copyWith(fontWeight: FontWeight.w700),
              ),
            ],
          ),
        );
      },
    );
  }
}

/* =========================================================================
 * 4. 2x 多相半带过采样徽标开关 (HQ Oversample Badge)
 * 芯片级晶体质感徽标，消除带内非线性折叠混叠失真。
 * ========================================================================= */

class HqOversampleBadge extends StatelessWidget {
  final bool active;
  final ValueChanged<bool> onChanged;

  const HqOversampleBadge({
    super.key,
    required this.active,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final color = active ? p.accent : p.textDim.withValues(alpha: 0.5);

    return InkWell(
      onTap: () => onChanged(!active),
      borderRadius: BorderRadius.circular(AuraRadius.sm),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: active ? p.accent.withValues(alpha: 0.15) : p.panel.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(
            color: active ? p.accent.withValues(alpha: 0.5) : p.hairline.withValues(alpha: 0.3),
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.auto_awesome,
              size: 11,
              color: color,
            ),
            const SizedBox(width: 4),
            Text(
              '2x HQ Oversampling',
              style: monoOf(
                p,
                size: 10,
                color: color,
              ).copyWith(fontWeight: active ? FontWeight.w700 : FontWeight.w500),
            ),
          ],
        ),
      ),
    );
  }
}
