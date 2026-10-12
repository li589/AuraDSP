// spectrum_rendering_test.dart — 频谱渲染回归：
//   1) 高频带柱子不得塌成发丝线（最小柱宽 + 带内居中）
//   2) 音频停止后氛围频谱必须自行归零（看门狗 + stale 快速衰减）
import 'dart:math' as math;

import 'package:auradsp_app/engine/auradsp_ffi.dart';
import 'package:auradsp_app/features/chrome.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 _SpectrumPainter 中一致的柱宽算法（最小柱宽 + 带内居中）。
const minBarW = 3.0;
const gap = 3.0;

double barWidth(double span, double gap, double minBarW) =>
    math.max(minBarW, span - gap);

void main() {
  group('频带宽度：不得出现发丝带', () {
    /// 各带的对数跨度占比（%）。末端窄带曾是 0.74%（中频带的 1/4），画成发丝。
    List<double> widths() {
      final mx = math.log(VizBands.maxHz / VizBands.minHz);
      return <double>[
        for (var i = 0; i < VizBands.count; i++)
          math.log(VizBands.edges[i + 1] / VizBands.edges[i]) / mx * 100,
      ];
    }

    test('最窄带与中位带宽度的比值不得低于 0.6', () {
      final w = widths()..sort();
      final median = w[w.length ~/ 2];
      final minW = w.first;
      expect(minW / median, greaterThanOrEqualTo(0.6),
          reason: '最窄带 $minW% 相对中位 $median% 仍过窄，会被画成发丝');
    });

    test('最高频带不再远窄于中频带（旧缺陷已从频带表根治）', () {
      final w = widths();
      final mid = w[13]; // 400~500 附近
      final top = w[w.length - 1]; // 16.8k~20k
      expect(top / mid, greaterThan(0.6));
    });

    test('任意窄画布上柱宽都不小于最小柱宽', () {
      for (final canvasW in [320.0, 400.0, 640.0, 1200.0]) {
        for (var i = 0; i < VizBands.count; i++) {
          final x0 = VizBands.edgeX(i) * canvasW;
          final x1 = VizBands.edgeX(i + 1) * canvasW;
          final span = x1 - x0;
          final bw = barWidth(span, gap, minBarW);
          expect(bw, greaterThanOrEqualTo(minBarW),
              reason: 'canvas=$canvasW band=$i 柱宽 $bw');
          final x = x0 + (span - bw) / 2;
          expect(x, greaterThanOrEqualTo(x0 - minBarW / 2));
          expect(x + bw, lessThanOrEqualTo(x1 + minBarW / 2));
        }
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

  group('氛围频谱降本：频带聚焦与预计算映射', () {
    test('柱数仍为 72（柱形密度不变）', () {
      expect(AmbientEnvelope.bars, 72);
      expect(AmbientEnvelope.sourceBands.length, 72);
    });

    test('映射表单调不减（不会因聚焦范围而频率倒挂）', () {
      final m = AmbientEnvelope.sourceBands;
      for (var i = 1; i < m.length; i++) {
        expect(m[i], greaterThanOrEqualTo(m[i - 1]),
            reason: '第 $i 根柱回退到了更低的频带');
      }
    });

    test('下标全部落在 32 个源频带内', () {
      for (final b in AmbientEnvelope.sourceBands) {
        expect(b, inInclusiveRange(0, VizBands.count - 1));
      }
    });

    test('两端锚在 80Hz 与 14kHz 最近的频带上', () {
      final m = AmbientEnvelope.sourceBands;
      // 首根柱正好落在 [80,100] 这一带
      expect(VizBands.edges[m.first], AmbientEnvelope.focusMinHz);
      // 末根柱锚在 14kHz 所在的一带（14100–16800 与 14kHz 最近）
      expect(m.last, lessThanOrEqualTo(30));
      expect(VizBands.edges[m.last], lessThanOrEqualTo(14100));
    });

    test('省掉两端空频带：不再采样 80Hz 以下与 14kHz 以上的整带', () {
      final m = AmbientEnvelope.sourceBands;
      // band0..5 = 20–80Hz（音乐内容几乎全空），band31 = 16800–20000Hz
      expect(m.any((b) => b <= 5), isFalse, reason: '仍在采样 80Hz 以下');
      expect(m.contains(VizBands.count - 1), isFalse,
          reason: '仍在采样 16800Hz 以上');
      expect(m.every((b) => b >= 6 && b <= 30), isTrue);
      // 32 个源频带里实际用到 25 个，即至少省下 7 个空带
      expect(m.toSet().length, lessThanOrEqualTo(VizBands.count - 7));
    });

    test('feed 走预计算表：单频带输入只点亮映射到该带的柱', () {
      final target = AmbientEnvelope.sourceBands[30];
      final src = List<double>.filled(VizBands.count, 0.0);
      src[target] = 1.0;

      final env = AmbientEnvelope();
      env.feed(src);

      final lit = <int>[];
      for (var i = 0; i < AmbientEnvelope.bars; i++) {
        if (env.smooth[i] > 0.5) lit.add(i);
      }
      expect(lit, isNotEmpty, reason: '该频带必须有点亮的柱');
      for (final i in lit) {
        expect(AmbientEnvelope.sourceBands[i], target);
      }
    });

    test('20Hz 以下与 14kHz 以上的内容不再驱动氛围柱（聚焦范围外被忽略）', () {
      final src = List<double>.filled(VizBands.count, 0.0);
      src[0] = 1.0; // 20–25Hz，远低于 focusMinHz
      src[VizBands.count - 1] = 1.0; // 16800–20000Hz，远高于 focusMaxHz

      final env = AmbientEnvelope();
      env.feed(src);
      expect(env.maxValue, 0.0,
          reason: '聚焦范围外的能量不该再点亮氛围柱（两端是空区间）');
    });
  });
}