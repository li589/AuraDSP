// 龙卷风视觉预览探针（非门禁）
//
// 用途：离屏渲染 ParticleTornadoPainter，肉眼核对「站不直」与音乐反应。
// 运行：cd app/auradsp_app && flutter test tools/probe/tornado_preview_test.dart
// 产物：build/tmp/tornado_{quiet,loud}.png + 控制台输出两图差异度。
//
// 放 tools/probe/ 的理由与 ambient_spectrum_preview_test 相同：不进门禁。
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/core/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/styles/style_tornado.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 合成「音乐感」频谱：低频厚 + 中频人声峰 + 高频滚降 + 少量起伏。
List<double> _shape({required double gain}) {
  const n = 32;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final t = i / (n - 1);
    final v = gain * (0.95 * math.exp(-math.pow((t - 0.04) / 0.10, 2)) +
        0.32 * math.exp(-math.pow((t - 0.30) / 0.16, 2)) +
        0.48 * math.exp(-math.pow((t - 0.52) / 0.09, 2)) +
        0.26 * math.exp(-math.pow((t - 0.72) / 0.07, 2)) +
        0.10 * math.exp(-math.pow((t - 0.88) / 0.09, 2)) +
        0.05 +
        0.03 * math.sin(t * 41.0));
    out[i] = v.clamp(0.0, 1.0);
  }
  return out;
}

Future<ui.Image> _render(
  VisualizerPalette palette,
  List<double> bands,
  Size size, {
  required double t0,
  required int warm,
}) async {
  final painter = ParticleTornadoPainter(
    bands: bands,
    palette: palette,
    bloom: 0.6,
    animationTime: t0,
  );

  // 静态积分器（_smoothedBass/_pulse/_spin）需要预热收敛，否则首帧是假象
  final warmRec = ui.PictureRecorder();
  final warmCanvas = ui.Canvas(warmRec);
  for (var i = 0; i < warm; i++) {
    painter
      ..animationTime = t0 + i / 60.0
      ..paint(warmCanvas, size);
  }
  warmRec.endRecording().dispose();

  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(Offset.zero & size, ui.Paint()..color = const Color(0xFF070B14));
  painter.animationTime = t0 + warm / 60.0;
  painter.paint(canvas, size);
  return rec.endRecording().toImage(size.width.round(), size.height.round());
}

/// 变化像素占比：稀疏粒子场里整幅均值会被大量黑背景稀释，
/// 用「采样点中亮度变化超过阈值的比例」才对得上肉眼感知。
Future<double> _changedFraction(ui.Image a, ui.Image b) async {
  final wa = (await a.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  final wb = (await b.toByteData(format: ui.ImageByteFormat.rawRgba))!.buffer.asUint8List();
  var changed = 0;
  var cnt = 0;
  for (var i = 0; i < wa.lengthInBytes; i += 64) {
    final d = (wa[i] - wb[i]).abs() + (wa[i + 1] - wb[i + 1]).abs();
    if (d > 24) changed++;
    cnt++;
  }
  return changed / cnt;
}

Future<void> _save(ui.Image img, String name) async {
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  final f = File('build/tmp/tornado_$name.png');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(Uint8List.view(data!.buffer));
  // ignore: avoid_print
  print('wrote ${f.path}');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('龙卷风：安静 vs 嘈杂渲染对比', () async {
    const size = Size(900, 700);
    final palette = VisualizerPalette.resolve(VisualizerColorTheme.neonCyber, auraDark);

    final quiet = await _render(palette, _shape(gain: 0.35), size,
        t0: 4.0, warm: 60);
    final loud = await _render(palette, _shape(gain: 1.0), size,
        t0: 8.0, warm: 60);

    await _save(quiet, 'quiet');
    await _save(loud, 'loud');

    final frac = await _changedFraction(quiet, loud);
    // ignore: avoid_print
    print('quiet-vs-loud changedFraction = ${(frac * 100).toStringAsFixed(1)}% '
        '(实测旧实现 1.2% / 新实现 3.5%，阈值取 2.5%)');
    expect(frac, greaterThan(0.025),
        reason: '两种音乐状态的画面必须有可感知差异（律动感的下限）');
  });
}
