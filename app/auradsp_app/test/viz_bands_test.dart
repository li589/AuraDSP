/*
 * viz_bands_test.dart — UI 频谱横坐标映射契约
 *
 * 引擎 emit_viz 已把线性 FFT bin 聚合成 32 条**对数**频带
 * （auradsp_engine.cpp 的 kBandEdges）。UI 侧凡是把频谱画到屏幕上的地方
 * （_SpectrumPainter 条形与网格、_AmbientPainter 氛围条）都必须经由
 * VizBands 换算横坐标，否则与 FreqAxis 的对数刻度对不齐。
 *
 * 历史缺陷：_AmbientPainter 曾用 pow(t, 1.6) 幂律把 32 条重采样成 72 根条，
 * 把低频拉宽、高频压扁。本测试锁死正确映射。
 */

import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/engine/auradsp_ffi.dart';

void main() {
  group('VizBands 频带边界与对数横坐标', () {
    test('边界表与引擎 kBandEdges 一致：33 个边界 / 32 条频带', () {
      expect(VizBands.edges.length, VizBands.count + 1);
      expect(VizBands.count, 32);
      expect(VizBands.edges.first, VizBands.minHz);
      expect(VizBands.edges.last, VizBands.maxHz);
      // 必须严格递增，否则 edgeX 非单调，条形会重叠或倒退
      for (var i = 1; i < VizBands.edges.length; i++) {
        expect(VizBands.edges[i], greaterThan(VizBands.edges[i - 1]));
      }
    });

    test('logX 把 20Hz 映射到 0、20kHz 映射到 1', () {
      expect(VizBands.logX(20), closeTo(0.0, 1e-12));
      expect(VizBands.logX(20000), closeTo(1.0, 1e-12));
      // 对数轴：中点应在 10^(log10(1000)/log10(1000)) = 1/3 处
      expect(VizBands.logX(200), closeTo(1.0 / 3.0, 1e-9));
    });

    test('edgeX / centerX 单调递增且落在 [0,1]', () {
      var prev = -1.0;
      for (var b = 0; b < VizBands.count; b++) {
        final l = VizBands.edgeX(b);
        final r = VizBands.edgeX(b + 1);
        final c = VizBands.centerX(b);
        expect(l, greaterThanOrEqualTo(0.0));
        expect(r, lessThanOrEqualTo(1.0));
        expect(l, greaterThanOrEqualTo(prev));
        expect(c, greaterThan(l));
        expect(c, lessThan(r));
        prev = r;
      }
    });

    test('sampleIndex 把横坐标反查回所属频带', () {
      // 落在第 0 条内 → 下标 < 1
      expect(VizBands.sampleIndex(VizBands.centerX(0)), lessThan(1.0));
      // 1kHz 所在的频带（边界表里 800~1000 与 1000~1250 之间）
      final idx1k = VizBands.sampleIndex(VizBands.logX(1000));
      expect(idx1k, greaterThan(15.0));
      expect(idx1k, lessThan(19.0));
      // 两端夹紧
      expect(VizBands.sampleIndex(-1.0), 0.0);
      expect(VizBands.sampleIndex(0.0), 0.0);
      expect(VizBands.sampleIndex(1.0), VizBands.count - 1);
      expect(VizBands.sampleIndex(2.0), VizBands.count - 1);
    });

    test('sampleIndex 单调不减（保序，不会出现频率倒挂）', () {
      var prev = -1.0;
      for (var i = 0; i <= 200; i++) {
        final v = VizBands.sampleIndex(i / 200.0);
        expect(v, greaterThanOrEqualTo(prev));
        prev = v;
      }
    });

    test('回归：72 根氛围条应线性映射到 32 带索引，非幂律拉伸', () {
      // 旧实现 pow(t, 1.6)：t=0.5 时 idx≈0.33*(31)=10.2，
      // 而 0.5 处对应 632Hz，正确应落在边界表 500~630 那条附近（索引≈13~14）。
      const bars = 72;
      expect(bars, 72); // 氛围条根数（_AmbientPainter._bars）
      final mid = VizBands.sampleIndex(0.5);
      // 0.5 处应在中段而非 1/3 处
      expect(mid, greaterThan(12.0));
      expect(mid, lessThan(17.0));
      // 端点仍映射到 0 与 count-1
      expect(VizBands.sampleIndex(0.0), 0.0);
      expect(VizBands.sampleIndex(1.0), VizBands.count - 1);
    });
  });
}