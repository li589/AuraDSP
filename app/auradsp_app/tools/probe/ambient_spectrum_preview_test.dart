// 氛围层视觉预览探针（非门禁）
//
// 用途：把 `_AmbientPainter` 用合成频谱离屏渲染成 PNG，肉眼核对柔化、
// 台阶、冠部高光与明暗主题下的强度。改氛围层参数后跑一次即可对比。
//
// 运行：cd app/auradsp_app && flutter test tools/probe/ambient_spectrum_preview_test.dart
// 产物：build/tmp/ambient_{dark_music,dark_bass,light_music,dark_silent}.png
//
// 之所以放在 tools/probe/ 而不是 test/：`flutter test` 只扫 test/，本文件
// 不会被门禁执行（与 tools/probe/* 的既有定位一致）。
import 'dart:io';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/ui/chrome.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

List<double> _shape({required double bassGain}) {
  const n = 32;
  final out = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final t = i / (n - 1);
    // 更像真实音乐：低频厚、中低频凹陷、2k 附近人声/军鼓峰、6k 齿音小峰、
    // 高频滚降；再叠一点确定性起伏，避免看起来像一条平滑斜坡。
    final v = bassGain * math.exp(-math.pow((t - 0.04) / 0.10, 2)) +
        0.30 * math.exp(-math.pow((t - 0.30) / 0.16, 2)) +
        0.46 * math.exp(-math.pow((t - 0.52) / 0.09, 2)) +
        0.28 * math.exp(-math.pow((t - 0.72) / 0.07, 2)) +
        0.10 * math.exp(-math.pow((t - 0.88) / 0.09, 2)) +
        0.05 +
        0.03 * math.sin(t * 41.0);
    out[i] = v.clamp(0.0, 1.0);
  }
  return out;
}

Future<void> _render(
  String name,
  AuraPalette palette,
  List<double> spectrum,
  Size size, {
  Color? bg,
}) async {
  final sp = ValueNotifier<List<double>>(spectrum);
  final clock = ValueNotifier<int>(0);
  // 探针位于 tools/ 下，分析器按生产代码对待；该钩子本身是 @visibleForTesting。
  // ignore: invalid_use_of_visible_for_testing_member
  final painter = ambientSpectrumPainterForTest(
    spectrum: sp,
    palette: palette,
    clock: clock,
  );

  final rec = ui.PictureRecorder();
  final canvas = ui.Canvas(rec);
  canvas.drawRect(
    Offset.zero & size,
    ui.Paint()..color = bg ?? palette.bg,
  );
  painter.paint(canvas, size);
  final img = await rec.endRecording().toImage(
        size.width.round(),
        size.height.round(),
      );
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  final bytes = Uint8List.view(data!.buffer);
  final f = File('build/tmp/ambient_$name.png');
  f.parent.createSync(recursive: true);
  f.writeAsBytesSync(bytes);
  // ignore: avoid_print
  print('wrote ${f.path} (${bytes.length} B)');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('render ambient spectrum previews', () async {
    const size = Size(1200, 800);
    await _render('dark_music', auraDark, _shape(bassGain: 0.9), size);
    await _render('dark_bass', auraDark, _shape(bassGain: 1.0), size);
    await _render('light_music', auraLight, _shape(bassGain: 0.9), size);
    await _render(
      'dark_silent',
      auraDark,
      List<double>.filled(32, 0),
      size,
    );
  });
}
