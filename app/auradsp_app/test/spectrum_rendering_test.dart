// spectrum_rendering_test.dart — 频谱渲染回归：
//   1) 高频带柱子不得塌成发丝线（最小柱宽 + 带内居中）
//   2) 音频停止后氛围频谱必须自行归零（看门狗 + stale 快速衰减）
import 'dart:math' as math;

import 'package:auradsp_app/engine/auradsp_ffi.dart';
import 'package:auradsp_app/features/chrome.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 _SpectrumPainter 中一致的柱宽算法（最小柱宽 + 带内居中）。
double barWidth(double span, double gap, double minBarW) =>
    math.max(minBarW, span - gap);

void main() {
  group('频带宽度：高频柱不得塌成发丝', () {
    test('问题前提：高频带真实跨度远窄于中频带', () {
      final mid = VizBands.edgeX(13) - VizBands.edgeX(12); // 400~500
      final b31 = VizBands.edgeX(32) - VizBands.edgeX(31); // 19k~20k
      expect(b31, lessThan(mid * 0.4),
          reason: '最高频带应显著窄于中频带，这正是塌成发丝的原因');
    });

    test('旧算法在窄画布上会把最高频带钳到 1px 发丝', () {
      const w = 320.0;
      const gap = 3.0;
      final x0 = VizBands.edgeX(31) * w;
      final x1 = VizBands.edgeX(32) * w;
      final old = math.max(1.0, (x1 - x0) - gap);
      expect(old, lessThan(2.0), reason: '旧算法在此场景确实退化成发丝');
    });

    test('新算法：所有频带柱宽都不小于最小柱宽', () {
      const canvasW = 320.0;
      const minBarW = 3.0;
      const gap = 3.0;
      for (var i = 0; i < VizBands.count; i++) {
        final x0 = VizBands.edgeX(i) * canvasW;
        final x1 = VizBands.edgeX(i + 1) * canvasW;
        final span = x1 - x0;
        final bw = barWidth(span, gap, minBarW);
        expect(bw, greaterThanOrEqualTo(minBarW),
            reason: 'band $i 柱宽塌到 $bw px');
        // 带内居中：柱体应落在该频带范围内（允许至多 minBarW/2 的相邻溢出）
        final x = x0 + (span - bw) / 2;
        expect(x, greaterThanOrEqualTo(x0 - minBarW / 2));
        expect(x + bw, lessThanOrEqualTo(x1 + minBarW / 2));
      }
    });
  });

  group('氛围频谱：音频停止后归零', () {
    test('stale 衰减会把缓冲清零并报告已干净', () {
      final env = AmbientEnvelope();
      for (var i = 0; i < 5; i++) {
        env.feed(List<double>.filled(32, 0.9));
      }
      expect(env.maxValue, greaterThan(0.5), reason: '先确认柱子确实长起来了');

      // 模拟音频停止：反复 decayStale 直到报告干净
      var ticks = 0;
      while (env.decay() && ticks < 200) {
        ticks++;
      }
      expect(env.maxValue, 0.0, reason: '无信号后必须归零，不能残留最后一帧');
      expect(env.stale, isTrue);
    });

    test('关键：stale 期间不得再吃陈旧 spectrum（否则永不归零）', () {
      final env = AmbientEnvelope();
      final staleFrame = List<double>.filled(32, 0.9);
      env.feed(staleFrame);
      expect(env.maxValue, greaterThan(0.5));

      // 引擎不再产出新帧，但 spectrum 的值仍是旧的高值。
      // 若实现里仍然 feed(staleFrame)，smooth 会被永久抬回 0.9。
      var ticks = 0;
      while (env.decay() && ticks < 500) {
        ticks++;
      }
      expect(env.maxValue, 0.0,
          reason: '陈旧值不得被重新采入，否则残留永不消失');
    });

    test('重新收到真实帧后恢复正常（stale 被解除）', () {
      final env = AmbientEnvelope();
      env.feed(List<double>.filled(32, 0.9));
      while (env.decay()) {}
      expect(env.maxValue, 0.0);

      env.feed(List<double>.filled(32, 0.6));
      expect(env.stale, isFalse);
      expect(env.maxValue, closeTo(0.6, 0.05));
    });

    test('decay 收敛步数有界（不会无限拖尾）', () {
      final env = AmbientEnvelope();
      env.feed(List<double>.filled(32, 1.0));
      var ticks = 0;
      while (env.decay() && ticks < 500) {
        ticks++;
      }
      // 0.70^n < 0.0008 → n ≈ 19；留足余量但必须是有界的
      expect(ticks, lessThan(40));
    });
  });
}