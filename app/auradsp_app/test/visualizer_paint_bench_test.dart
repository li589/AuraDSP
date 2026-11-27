// visualizer_paint_bench_test.dart — 可视化各风格 paint() CPU 成本基准。
//
// 目的（2026-11-08 可视化深度优化立项）：此前 P0–P2 优化只有定性结论，
// 没有分风格的帧成本数据，优化顺序靠猜。本测试在 1280×720 下以活跃
// 频段数据驱动全部风格，逐个测量 paint() 的录制成本（PictureRecorder
// 录制，不含 GPU 光栅化），打印 µs/帧表供 CI 日志留档，并以一帧预算
// （30Hz 产帧 ⇒ 33ms）做宽松回归断言——超预算说明该风格在任何机器上
// 都不可能稳住帧率，必须先优化再合入。
//
// 注意：fluid 的模拟步进在 paint 内执行，其成本计入本测量；GPU shader
// 风格在测试环境无 FragmentProgram 时走回退路径，数字仅供参考。
// tornado 使用真实精灵图集与缓存画笔实例，覆盖 900 粒子、短拖尾和单次
// drawRawAtlas 的 CPU 提交成本；图集解码不计入帧耗时。
//
// 基线（2026-11-08，CI J6 runner，run 42494469015）：
//   fluidDynamics 4704us（峰值 6575）——次重风格的 10 倍以上，是唯一
//   需要自适应降质的风格；bars 433 / cyberGrid 261 / milkDrop 172 /
//   oscilloscope 147 / goniometer 125 / pulseOrb 50 / shader 系 14。
import 'dart:math' as math;
import 'dart:ui';

import 'package:auradsp_app/core/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
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

/// 生成一帧「活跃」频段：低频隆起 + 中频波动 + 高频细纹，帧间相位推进。
List<double> _fillBands(List<double> bands, double t) {
  for (var i = 0; i < bands.length; i++) {
    final x = i / bands.length;
    final bass = math.exp(-x * 6) * (0.75 + 0.25 * math.sin(t * 2.1));
    final mid = 0.35 * math.exp(-math.pow((x - 0.45) * 3.2, 2)) *
        (0.7 + 0.3 * math.sin(t * 3.7 + i * 0.4));
    final air = 0.12 * (0.5 + 0.5 * math.sin(t * 9.0 + i * 1.7));
    bands[i] = (bass + mid + air).clamp(0.0, 1.0);
  }
  return bands;
}

List<double> _bands(double t, int n) =>
    _fillBands(List<double>.filled(n, 0), t);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('各风格 paint 成本基准（1280x720，活跃频段）', () async {
    final atlas = VisualizerSpriteAtlas.instance;
    atlas.ensureImage();
    for (var i = 0; i < 200 && atlas.imageOrNull == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(atlas.imageOrNull, isNotNull);

    const size = Size(1280, 720);
    const config = VisualizerConfig();
    final synth = WaveformSynthesizer();
    final report = StringBuffer('\n== visualizer paint bench (us/frame) ==');

    for (final style in VisualizerStyle.values) {
      var t = 0.0;
      CustomPainter? cachedTornado;
      final tornadoBands = List<double>.filled(64, 0.0);
      double paintOnce() {
        final bands = style == VisualizerStyle.tornado
            ? _fillBands(tornadoBands, t)
            : _bands(t, 64);
        synth.update(bands, levelLDbfs: -9.0, levelRDbfs: -10.0);
        final painter = style == VisualizerStyle.tornado
            ? cachedTornado ??= buildVisualizerPainter(
                style: style,
                config: config,
                palette: _palette,
                rawBands: bands,
                peaks: bands.map((v) => v * 1.05).toList(),
                waveformSynth: synth,
                time: t,
              )
            : buildVisualizerPainter(
                style: style,
                config: config,
                palette: _palette,
                rawBands: bands,
                peaks: bands.map((v) => v * 1.05).toList(),
                waveformSynth: synth,
                time: t,
              );
        if (painter is VisualizerTimeAware) {
          (painter as VisualizerTimeAware).setVisualizerTime(t);
        }
        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        final sw = Stopwatch()..start();
        painter.paint(canvas, size);
        sw.stop();
        recorder.endRecording().dispose();
        t += 1 / 30;
        return sw.elapsedMicroseconds.toDouble();
      }

      // 预热（含各风格的静态缓存/场初始化），再测 30 帧取均值与峰值。
      for (var i = 0; i < 5; i++) {
        paintOnce();
      }
      var total = 0.0;
      var peak = 0.0;
      const frames = 30;
      for (var i = 0; i < frames; i++) {
        final us = paintOnce();
        total += us;
        if (us > peak) peak = us;
      }
      final avg = total / frames;
      report.writeln(
          '${style.id.padRight(14)} avg ${avg.toStringAsFixed(0).padLeft(7)} us'
          '  peak ${peak.toStringAsFixed(0).padLeft(7)} us');
      expect(avg, lessThan(33000),
          reason: '${style.id} paint avg ${avg.toStringAsFixed(0)}us '
              'exceeds the 33ms frame budget');
    }
    // ignore: avoid_print
    print(report);
  }, timeout: const Timeout(Duration(minutes: 5)));
}
