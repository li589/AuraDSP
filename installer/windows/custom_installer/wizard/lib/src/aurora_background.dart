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
/// 2026-11-12 再降载：安装/卸载运行中与等待提权时经 [auroraFrozen]
/// 冻结步进（重活期间背景静止）；窗口不可见（生命周期非 resumed）
/// 时同样停表——软件渲染环境下每次全窗渐变重绘都是整屏 shader 填充。
class AuroraBackground extends StatefulWidget {
  const AuroraBackground({super.key, required this.child});
  final Widget child;

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

/// 背景冻结开关（app 层在运行安装/卸载或等待提权时置位）：
/// 冻结期间极光停留在当前档位，不再周期重绘。
final ValueNotifier<bool> auroraFrozen = ValueNotifier<bool>(false);

class _AuroraBackgroundState extends State<AuroraBackground>
    with WidgetsBindingObserver {
  static const int _steps = 24;
  Timer? _timer;
  int _step = 0;
  bool _lifecycleResumed = true;

  bool get _shouldRun =>
      _lifecycleResumed && !auroraFrozen.value;

  void _syncTimer() {
    if (_shouldRun) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 900), (_) {
        if (!mounted) return;
        setState(() => _step = (_step + 1) % _steps);
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    auroraFrozen.addListener(_syncTimer);
    _syncTimer();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _lifecycleResumed = state == AppLifecycleState.resumed;
    _syncTimer();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    auroraFrozen.removeListener(_syncTimer);
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

/// 步进式旋转指示（替代 CircularProgressIndicator 的 60fps 连续
/// 动画，2026-11-12 降载）：120ms 一档（约 8fps）推进弧段，每档
/// 只重绘自身小区域，整窗合成频率随之从 60 降到约 8——软件渲染
/// 环境（虚拟机/远程桌面）下这是 GPU 占用的主导项。
class SteppedSpinner extends StatefulWidget {
  const SteppedSpinner({super.key, this.size = 36});
  final double size;

  @override
  State<SteppedSpinner> createState() => _SteppedSpinnerState();
}

class _SteppedSpinnerState extends State<SteppedSpinner> {
  Timer? _timer;
  int _step = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (mounted) setState(() => _step++);
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
      size: Size.square(widget.size),
      painter: _SpinnerPainter(_step * math.pi / 6),
    );
  }
}

class _SpinnerPainter extends CustomPainter {
  _SpinnerPainter(this.angle);
  final double angle;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = size.width * 0.11;
    final rect = Offset.zero & size;
    final paint = Paint()
      ..color = Aurora.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round;
    canvas.drawArc(rect.deflate(stroke / 2), angle, math.pi * 1.35, false,
        paint);
  }

  @override
  bool shouldRepaint(_SpinnerPainter old) => old.angle != angle;
}

/// 步进式进度条：确定值时静态绘制（仅值变化才重绘）；不确定态
/// 以 125ms 步进扫动（约 8fps），替代 Material 不确定进度条的
/// 60fps 连续动画（2026-11-12 降载，同 SteppedSpinner 口径）。
class SteppedProgressBar extends StatefulWidget {
  const SteppedProgressBar({super.key, required this.value, this.height = 10});
  final double? value; // 0..1；null = 不确定态
  final double height;

  @override
  State<SteppedProgressBar> createState() => _SteppedProgressBarState();
}

class _SteppedProgressBarState extends State<SteppedProgressBar> {
  Timer? _timer;
  int _step = 0;

  void _syncTimer() {
    if (widget.value == null) {
      _timer ??= Timer.periodic(const Duration(milliseconds: 125), (_) {
        if (mounted) setState(() => _step++);
      });
    } else {
      _timer?.cancel();
      _timer = null;
    }
  }

  @override
  void initState() {
    super.initState();
    _syncTimer();
  }

  @override
  void didUpdateWidget(SteppedProgressBar old) {
    super.didUpdateWidget(old);
    _syncTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: Size(double.infinity, widget.height),
      painter: _BarPainter(widget.value, _step % 24 / 24),
    );
  }
}

class _BarPainter extends CustomPainter {
  _BarPainter(this.value, this.phase);
  final double? value;
  final double phase;

  @override
  void paint(Canvas canvas, Size size) {
    final r = Radius.circular(size.height / 2);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Offset.zero & size, r),
      Paint()..color = Aurora.panelRaised,
    );
    final v = value;
    double x0, w;
    if (v != null) {
      x0 = 0;
      w = size.width * v.clamp(0.0, 1.0);
    } else {
      w = size.width * 0.35;
      x0 = (size.width - w) * phase;
    }
    if (w <= 0) return;
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(x0, 0, w, size.height), r),
      Paint()..color = Aurora.accent,
    );
  }

  @override
  bool shouldRepaint(_BarPainter old) =>
      old.value != value || old.phase != phase;
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
