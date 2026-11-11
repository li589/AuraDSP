import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'theme.dart';

/// 全窗极光背景：3 团缓慢漂移的径向光斑 + 暗角（设计 §4.2）。
///
/// 性能口径：不要用 AnimationController.repeat() —— 它按 vsync 60fps
/// 全窗重绘 4 个大半径 RadialGradient（每帧新建 Shader），实测能把 GPU
/// 推到 75%、内存推到 1G+。改为 24 档量化 + 900ms Timer（约 1.1fps），
/// 并用 RepaintBoundary 隔离内容层，重绘成本降到原来的约 2%。
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child});
  final Widget child;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground> {
  static const int _steps = 24;
  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 900), (_) {
      if (!mounted) return;
      setState(() => _step = (_step + 1) % _steps);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _AuroraPainter(_step / _steps),
      child: RepaintBoundary(child: widget.child),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  _AuroraPainter(this.t);
  final double t; // 0..1

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(Offset.zero & size, Paint()..color = Aurora.bg);
    final phase = t * math.pi * 2;
    _blob(canvas, size,
        dx: 0.24 + 0.05 * math.sin(phase),
        dy: 0.16 + 0.04 * math.cos(phase * 0.9),
        r: 0.62,
        color: Aurora.accent.withValues(alpha: 0.14));
    _blob(canvas, size,
        dx: 0.82 + 0.05 * math.cos(phase * 0.7 + 2),
        dy: 0.30 + 0.05 * math.sin(phase * 0.8 + 1),
        r: 0.55,
        color: const Color(0xFF5E7CFF).withValues(alpha: 0.12));
    _blob(canvas, size,
        dx: 0.55 + 0.06 * math.sin(phase * 0.6 + 4),
        dy: 0.95 + 0.03 * math.cos(phase * 0.75),
        r: 0.58,
        color: Aurora.accent2.withValues(alpha: 0.08));
    // 暗角
    final vignette = RadialGradient(
      center: Alignment.center,
      radius: 1.15,
      colors: [Colors.transparent, Colors.black.withValues(alpha: 0.35)],
      stops: const [0.62, 1.0],
    );
    canvas.drawRect(
      Offset.zero & size,
      Paint()..shader = vignette.createShader(Offset.zero & size),
    );
  }

  void _blob(Canvas canvas, Size size,
      {required double dx,
      required double dy,
      required double r,
      required Color color}) {
    final center = Offset(size.width * dx, size.height * dy);
    final radius = size.width * r;
    final shader = RadialGradient(
      colors: [color, color.withValues(alpha: 0)],
    ).createShader(Rect.fromCircle(center: center, radius: radius));
    canvas.drawCircle(center, radius, Paint()..shader = shader);
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => old.t != t;
}

/// 完成页对勾描画动画（路径生长，设计 §4.2）。
class AnimatedCheck extends StatefulWidget {
  const AnimatedCheck({super.key, this.size = 84});
  final double size;

  @override
  State<AnimatedCheck> createState() => _AnimatedCheckState();
}

class _AnimatedCheckState extends State<AnimatedCheck>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 650),
  )..forward();

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _c,
      builder: (context, _) => CustomPaint(
        size: Size.square(widget.size),
        painter: _CheckPainter(_c.value),
      ),
    );
  }
}

class _CheckPainter extends CustomPainter {
  _CheckPainter(this.progress);
  final double progress;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 4;
    final ring = Paint()
      ..color = Aurora.accent.withValues(alpha: 0.9)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3;
    canvas.drawCircle(center, r, ring);

    final p1 = Offset(center.dx - r * 0.45, center.dy + r * 0.02);
    final p2 = Offset(center.dx - r * 0.12, center.dy + r * 0.36);
    final p3 = Offset(center.dx + r * 0.5, center.dy - r * 0.34);
    final path = Path()..moveTo(p1.dx, p1.dy);
    if (progress < 0.4) {
      final t = progress / 0.4;
      path.lineTo(p1.dx + (p2.dx - p1.dx) * t, p1.dy + (p2.dy - p1.dy) * t);
    } else {
      path.lineTo(p2.dx, p2.dy);
      final t = (progress - 0.4) / 0.6;
      path.lineTo(p2.dx + (p3.dx - p2.dx) * t, p2.dy + (p3.dy - p2.dy) * t);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = Aurora.success
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round,
    );
  }

  @override
  bool shouldRepaint(_CheckPainter old) => old.progress != progress;
}
