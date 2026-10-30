import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart' show CustomPainter, Alignment, RadialGradient;

import '../models/visualizer_themes.dart';
import '../shaders/gpu_shader_service.dart';

/// Hardware-accelerated GPU Fragment Shader Visualizer Painter
class GpuShaderPainter extends CustomPainter {
  final GpuShaderType shaderType;
  final List<double> bands;
  final VisualizerPalette palette;
  final double time;
  final double sensitivity;

  GpuShaderPainter({
    required this.shaderType,
    required this.bands,
    required this.palette,
    required this.time,
    required this.sensitivity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.width <= 0 || size.height <= 0) return;

    // Extract tri-band energy
    var bass = 0.0, mid = 0.0, treble = 0.0;
    if (bands.length >= 16) {
      bass = ((bands[0] + bands[1] + bands[2] + bands[3]) / 4.0 * sensitivity).clamp(0.0, 2.0);
      mid = ((bands[8] + bands[10] + bands[12]) / 3.0 * sensitivity).clamp(0.0, 2.0);
      treble = ((bands[20] + bands[24] + bands[28]) / 3.0 * sensitivity).clamp(0.0, 2.0);
    }

    final shader = GpuShaderService.instance.shaderFor(shaderType);
    if (shader != null) {
      // Uniform indices mapping:
      // vec2 uResolution (floats 0, 1)
      shader.setFloat(0, size.width);
      shader.setFloat(1, size.height);

      // float uTime (float 2)
      shader.setFloat(2, time);

      // float uBass, uMid, uTreble (floats 3, 4, 5)
      shader.setFloat(3, bass);
      shader.setFloat(4, mid);
      shader.setFloat(5, treble);

      // vec4 uColor1 (floats 6, 7, 8, 9)
      final c1 = palette.primary;
      shader.setFloat(6, c1.r);
      shader.setFloat(7, c1.g);
      shader.setFloat(8, c1.b);
      shader.setFloat(9, c1.a);

      // vec4 uColor2 (floats 10, 11, 12, 13)
      final c2 = palette.secondary;
      shader.setFloat(10, c2.r);
      shader.setFloat(11, c2.g);
      shader.setFloat(12, c2.b);
      shader.setFloat(13, c2.a);

      final paint = Paint()..shader = shader;
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), paint);
    } else {
      // Graceful fallback gradient if shader is compiling or unsupported
      _drawFallback(canvas, size, bass, mid);
    }
  }

  void _drawFallback(Canvas canvas, Size size, double bass, double mid) {
    final rect = Rect.fromLTWH(0, 0, size.width, size.height);
    final center = Offset(size.width / 2.0, size.height / 2.0);
    final r = math.min(size.width, size.height) * (0.3 + bass * 0.2);

    final bgPaint = Paint()
      ..shader = RadialGradient(
        center: Alignment.center,
        radius: 0.85,
        colors: [
          palette.secondary.withValues(alpha: 0.25 + bass * 0.2),
          palette.primary.withValues(alpha: 0.08),
          const Color(0x00000000),
        ],
      ).createShader(rect);
    canvas.drawRect(rect, bgPaint);

    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0 + bass * 3.0
      ..color = palette.primary.withValues(alpha: 0.7);
    canvas.drawCircle(center, r, ringPaint);
  }

  @override
  bool shouldRepaint(covariant GpuShaderPainter oldDelegate) => true;
}
