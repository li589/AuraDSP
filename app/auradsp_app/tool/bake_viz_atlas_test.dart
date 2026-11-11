import 'dart:io';
import 'dart:ui' as ui;

import 'package:auradsp_app/features/visualizer/styles/visualizer_atlas_bake.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 离线图集生成器（不属于常规测试套件，需显式指定文件运行）：
///
/// ```
/// cd app/auradsp_app
/// flutter test tool/bake_viz_atlas_test.dart
/// ```
///
/// 产物：`assets/viz/atlas_v1.png`（1024×1024 RGBA PNG）。
/// 绘制代码与运行期 legacy 烘焙共用 [paintVizAtlas]，种子全部固定，
/// 因此可重复执行且结果稳定（同一引擎版本下逐像素一致）。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('bake viz atlas to PNG asset', () async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    paintVizAtlas(canvas);
    final picture = recorder.endRecording();
    final image = await picture.toImage(
      VizAtlasLayout.size,
      VizAtlasLayout.size,
    );
    picture.dispose();

    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    expect(bytes, isNotNull, reason: 'PNG 编码失败');

    final file = File('assets/viz/atlas_v1.png');
    await file.parent.create(recursive: true);
    final data = bytes!.buffer
        .asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
    await file.writeAsBytes(data, flush: true);

    final size = await file.length();
    // ignore: avoid_print
    print(
      '[bake_viz_atlas] wrote ${file.absolute.path} '
      'bytes=$size image=${VizAtlasLayout.size}x${VizAtlasLayout.size}',
    );
    expect(size, greaterThan(0));
  });
}
