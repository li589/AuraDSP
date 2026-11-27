// visualizer_paint_bench_test.dart — 可视化各风格 paint 与光栅化成本基准。
//
// 在 1280×720 下以活跃频段驱动全部风格。GPU 风格先等待 FragmentProgram
// 编译并断言走真实 shader，再分别测量 CPU paint 录制和 Picture.toImage +
// readback；tornado 只作为 CPU 粒子路线参与，不再伪装成 GPU shader。
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:auradsp_app/core/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/shaders/gpu_shader_service.dart';
import 'package:auradsp_app/features/visualizer/styles/style_gpu_shader.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_painter_dispatcher.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_sprite_atlas.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_time_aware.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _palette = VisualizerPalette(
  primary: Color(0xFF00E5FF),
  secondary: Color(0xFFFF007F),
  peak: Color(0xFFFFFFFF),
  grid: Color(0x1A00E5FF),
  glow: Color(0x8000E5FF),
  gradient: [Color(0xFF0055FF), Color(0xFF00E5FF)],
);

const _gpuShaderTypes = <VisualizerStyle, GpuShaderType>{
  VisualizerStyle.auroraShader: GpuShaderType.aurora,
  VisualizerStyle.tunnelShader: GpuShaderType.tunnel,
  VisualizerStyle.harmonicWarp: GpuShaderType.harmonicWarp,
  VisualizerStyle.nebulaFlow: GpuShaderType.nebula,
};

/// 生成一帧「活跃」频段：低频隆起 + 中频波动 + 高频细纹，帧间相位推进。
List<double> _fillBands(List<double> bands, double t) {
  for (var i = 0; i < bands.length; i++) {
    final x = i / bands.length;
    final bass = math.exp(-x * 6) * (0.75 + 0.25 * math.sin(t * 2.1));
    final mid =
        0.35 *
        math.exp(-math.pow((x - 0.45) * 3.2, 2)) *
        (0.7 + 0.3 * math.sin(t * 3.7 + i * 0.4));
    final air = 0.12 * (0.5 + 0.5 * math.sin(t * 9.0 + i * 1.7));
    bands[i] = (bass + mid + air).clamp(0.0, 1.0);
  }
  return bands;
}

Future<double> _rasterizeAndReadback(
  ui.Picture picture,
  Size size, {
  required String style,
}) async {
  ui.Image? image;
  try {
    final sw = Stopwatch()..start();
    image = await picture.toImage(size.width.toInt(), size.height.toInt());
    sw.stop();
    final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    expect(
      data,
      isNotNull,
      reason: '$style must return real raster pixels, not a fallback result.',
    );
    expect(
      data!.lengthInBytes,
      size.width.toInt() * size.height.toInt() * 4,
      reason: '$style readback must cover the complete benchmark surface.',
    );
    return sw.elapsedMicroseconds.toDouble();
  } catch (error) {
    fail(
      'Windows Flutter test could not rasterize/read back $style. Missing '
      'shader rasterization capability is a benchmark failure, not a GPU '
      'fallback result: $error',
    );
  } finally {
    image?.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('visualizer CPU recording and real shader raster bench (1280x720)', () async {
    final atlas = VisualizerSpriteAtlas.instance;
    atlas.ensureImage();
    for (var i = 0; i < 200 && atlas.imageOrNull == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(atlas.imageOrNull, isNotNull);

    final shaderService = GpuShaderService.instance;
    for (final entry in _gpuShaderTypes.entries) {
      final compiled = await shaderService.ensureCompiled(entry.value);
      expect(
        compiled,
        isTrue,
        reason:
            'Windows Flutter test must compile ${entry.value.assetPath}; '
            'missing shader capability cannot be reported as a GPU result.',
      );
      expect(
        shaderService.compileStatusFor(entry.value),
        GpuShaderCompileStatus.compiled,
      );
      expect(shaderService.getProgram(entry.value), isNotNull);
      expect(
        shaderService.shaderFor(entry.value),
        isNotNull,
        reason: '${entry.value.assetPath} must create a real FragmentShader.',
      );
    }

    const size = Size(1280, 720);
    const config = VisualizerConfig();
    final synth = WaveformSynthesizer();
    final report = StringBuffer(
      '\n== visualizer paint + raster bench (1280x720, us/frame) ==\n'
      'style           route  cpuAvg  cpuPeak  rasterAvg  rasterPeak  combined',
    );

    for (final style in VisualizerStyle.values) {
      final bands = List<double>.filled(64, 0);
      final peaks = List<double>.filled(64, 0);
      var time = 0.0;
      final painter = buildVisualizerPainter(
        style: style,
        config: config,
        palette: _palette,
        rawBands: bands,
        peaks: peaks,
        waveformSynth: synth,
        time: time,
      );
      final shaderType = _gpuShaderTypes[style];
      if (shaderType != null) {
        expect(
          painter,
          isA<GpuShaderPainter>(),
          reason: '${style.id} must not silently benchmark a CPU fallback.',
        );
        final gpuPainter = painter as GpuShaderPainter;
        expect(gpuPainter.compileStatus, GpuShaderCompileStatus.compiled);
        expect(
          gpuPainter.rendererKind,
          VisualizerRendererKind.gpuShader,
          reason: '${style.id} must not benchmark the CPU fallback.',
        );
        expect(shaderService.shaderFor(shaderType), isNotNull);
      }
      if (style == VisualizerStyle.tornado) {
        expect(
          painter,
          isNot(isA<GpuShaderPainter>()),
          reason: 'Tornado is a CPU particle route, not a GPU shader.',
        );
      }

      ({double cpuUs, ui.Picture picture}) recordFrame() {
        _fillBands(bands, time);
        for (var i = 0; i < peaks.length; i++) {
          peaks[i] = bands[i] * 1.05;
        }
        synth.update(bands, levelLDbfs: -9.0, levelRDbfs: -10.0);
        if (painter is VisualizerTimeAware) {
          (painter as VisualizerTimeAware).setVisualizerTime(time);
        }
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        final sw = Stopwatch()..start();
        painter.paint(canvas, size);
        sw.stop();
        final picture = recorder.endRecording();
        time += 1 / 30;
        return (cpuUs: sw.elapsedMicroseconds.toDouble(), picture: picture);
      }

      // Warm static caches, simulation state, shader instances and raster paths.
      for (var i = 0; i < 5; i++) {
        recordFrame().picture.dispose();
      }
      for (var i = 0; i < 2; i++) {
        final frame = recordFrame();
        await _rasterizeAndReadback(frame.picture, size, style: style.id);
        frame.picture.dispose();
      }

      var cpuTotal = 0.0;
      var cpuPeak = 0.0;
      const frames = 30;
      const rasterFrames = 5;
      final rasterPictures = <ui.Picture>[];
      for (var i = 0; i < frames; i++) {
        final frame = recordFrame();
        cpuTotal += frame.cpuUs;
        if (frame.cpuUs > cpuPeak) cpuPeak = frame.cpuUs;
        if (i >= frames - rasterFrames) {
          rasterPictures.add(frame.picture);
        } else {
          frame.picture.dispose();
        }
      }

      var rasterTotal = 0.0;
      var rasterPeak = 0.0;
      for (final picture in rasterPictures) {
        final us = await _rasterizeAndReadback(picture, size, style: style.id);
        picture.dispose();
        rasterTotal += us;
        if (us > rasterPeak) rasterPeak = us;
      }
      final cpuAvg = cpuTotal / frames;
      final rasterAvg = rasterTotal / rasterFrames;
      final route = painter is GpuShaderPainter ? 'GPU' : 'CPU';
      report.writeln(
        '${style.id.padRight(15)} $route  '
        '${cpuAvg.toStringAsFixed(0).padLeft(6)}  '
        '${cpuPeak.toStringAsFixed(0).padLeft(7)}  '
        '${rasterAvg.toStringAsFixed(0).padLeft(9)}  '
        '${rasterPeak.toStringAsFixed(0).padLeft(10)}  '
        '${(cpuAvg + rasterAvg).toStringAsFixed(0).padLeft(8)}',
      );
      // Picture.toImage in flutter_test is a diagnostic raster path, not the
      // production GPU frame scheduler. Keep the established 33ms gate on CPU
      // recording and report raster cost separately instead of hiding it.
      expect(
        cpuAvg,
        lessThan(33000),
        reason:
            '${style.id} CPU paint avg ${cpuAvg.toStringAsFixed(0)}us '
            'exceeds the existing 33ms frame budget',
      );
    }
    // ignore: avoid_print
    print(report);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
