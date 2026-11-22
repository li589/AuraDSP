import 'package:flutter/material.dart';

import '../plugins/projectm_bridge_contract.dart';
import 'style_milkdrop.dart';
import 'visualizer_time_aware.dart';

/// Paints the latest native projectM RGBA frame and falls back to the existing
/// procedural painter until the native bridge produces its first frame.
class ProjectMPainter extends CustomPainter implements VisualizerTimeAware {
  final ProjectMBridge bridge;
  final MilkdropPainter fallbackPainter;

  ProjectMPainter({
    required this.bridge,
    required this.fallbackPainter,
  }) : super(repaint: bridge.frameListenable);

  @override
  void setVisualizerTime(double t) => fallbackPainter.setVisualizerTime(t);

  @override
  void paint(Canvas canvas, Size size) {
    final image = bridge.currentFrame;
    if (image == null) {
      fallbackPainter.paint(canvas, size);
      return;
    }
    final src = Rect.fromLTWH(
      0,
      0,
      image.width.toDouble(),
      image.height.toDouble(),
    );
    final dst = Offset.zero & size;
    canvas.drawImageRect(
      image,
      src,
      dst,
      Paint()..filterQuality = FilterQuality.low,
    );
  }

  @override
  bool shouldRepaint(covariant ProjectMPainter oldDelegate) =>
      oldDelegate.bridge != bridge ||
      oldDelegate.fallbackPainter != fallbackPainter;
}
