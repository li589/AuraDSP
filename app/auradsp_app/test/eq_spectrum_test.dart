// eq_spectrum_test.dart — 均衡器面板背景谱的合成契约
//
// 用户反馈「效果 → 多段图形均衡器 中的这个图是显示的全链输出频谱，
// 应该显示均衡器输出的频谱」。
//
// EQ 在 libjamesdsp 的单体链内部，拿不到输出 tap；因此引擎下发 EQ 输入谱，
// UI 按 |Y(f)| = |X(f)|·|H_eq(f)| 合成输出谱（LTI 系统幅度谱乘法定理）。
// 这里钉住合成端的口径：换算必须与引擎一致、bypass 必须退化成恒等、缺响应时
// 必须安全退化，而不是给出一段编出来的谱。
import 'dart:math' as math;

import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/presets.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/engine/auradsp_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造与真实用户目录隔离的 AppModel：构造会读写配置与会话，
/// 测试结果不能依赖本机残留文件。
void _withIsolatedModel(void Function(AppModel m) body) {
  final dir = Directory.systemTemp.createTempSync('auradsp_eq_q_test');
  ConfigManager.baseDirOverride = dir.path;
  final m = AppModel(testing: true);
  try {
    body(m);
  } finally {
    m.dispose();
    ConfigManager.baseDirOverride = null;
    try {
      dir.deleteSync(recursive: true);
    } catch (_) {}
  }
}

/// 一条平坦（0 dB）的响应曲线，长度与引擎探针一致。
List<double> flatResponse() => List<double>.filled(129, 0.0);

/// 在 log 均分 20Hz..20kHz 的响应数组上，于 [hz] 处造一个宽 [halfWidth]
/// 个索引的凹陷，其余频带保持 0 dB——用来确认插值定位落在正确的频带上。
///
/// 宽度不能取 1：频带是取带内 max(mag)，采样点落在带中心，而单点凹口在
/// 线性插值下只有恰好命中那个索引才生效，band17 的中心 1118Hz 会落到
/// 凹口之外——那样测的就成了"凹口够不够宽"，而不是"定位对不对"。
List<double> responseWithDbAt(double hz, double db, {int halfWidth = 4}) {
  final r = List<double>.filled(129, 0.0);
  final t = math.log(hz / 20.0) / math.log(20000.0 / 20.0);
  final c = (t.clamp(0.0, 1.0) * 128).round();
  for (var i = c - halfWidth; i <= c + halfWidth; i++) {
    if (i >= 0 && i <= 128) r[i] = db;
  }
  return r;
}

void main() {
  group('频带值 ↔ dB 换算契约', () {
    test('toDb/fromDb 与引擎的 -75..0 dBFS 归一化互为逆运算', () {
      expect(VizBands.toDb(0.0), -75.0);
      expect(VizBands.toDb(1.0), 0.0);
      for (final v in [0.0, 0.13, 0.5, 0.87, 1.0]) {
        expect(VizBands.fromDb(VizBands.toDb(v)), closeTo(v, 1e-9));
      }
    });

    test('fromDb 越界即钳位（+18dB 提升不会溢出到 1.0 之外）', () {
      expect(VizBands.fromDb(18.0), 1.0);
      expect(VizBands.fromDb(-120.0), 0.0);
    });

    test('centerHz 用几何平均，落在所属频带边界之间', () {
      for (var b = 0; b < VizBands.count; b++) {
        final lo = VizBands.edges[b];
        final hi = VizBands.edges[b + 1];
        final c = VizBands.centerHz(b);
        expect(c, greaterThan(lo), reason: 'band$b 中心低于下界');
        expect(c, lessThan(hi), reason: 'band$b 中心高于上界');
      }
    });
  });

  group('EQ 输出频谱合成', () {
    test('响应平坦时输出谱等于输入谱', () {
      final eqIn = List<double>.generate(32, (i) => 0.3 + 0.01 * i);
      final out = composeEqOutputSpectrum(eqIn, flatResponse());
      for (var b = 0; b < 32; b++) {
        expect(out[b], closeTo(eqIn[b], 1e-6), reason: 'band$b');
      }
    });

    test('整体 +12dB 的响应会把每个频带等量抬高', () {
      final eqIn = List<double>.filled(32, 0.5);   // -37.5 dBFS
      final flatPlus = List<double>.filled(129, 12.0);
      final out = composeEqOutputSpectrum(eqIn, flatPlus);
      expect(VizBands.toDb(out.first), closeTo(VizBands.toDb(0.5) + 12.0, 0.01));
      expect(VizBands.toDb(out.last), closeTo(VizBands.toDb(0.5) + 12.0, 0.01));
    });

    test('提升不会溢出 [0,1]，压低不会变负', () {
      final hot = composeEqOutputSpectrum(
          List<double>.filled(32, 0.95), List<double>.filled(129, 18.0));
      expect(hot.every((v) => v <= 1.0 + 1e-9), isTrue);
      final cold = composeEqOutputSpectrum(
          List<double>.filled(32, 0.10), List<double>.filled(129, -18.0));
      expect(cold.every((v) => v >= 0.0 - 1e-9), isTrue);
    });

    test('bypass 时退化为恒等：EQ 不生效，输出就是输入', () {
      final eqIn = List<double>.generate(32, (i) => 0.2 + 0.02 * i);
      final wild = List<double>.generate(129, (i) => (i.isEven ? 18 : -18));
      final out = composeEqOutputSpectrum(eqIn, wild, bypassed: true);
      for (var b = 0; b < 32; b++) {
        expect(out[b], closeTo(eqIn[b], 1e-9), reason: 'band$b');
      }
    });

    test('响应尚未测得（null / 过短）时安全退化为输入谱', () {
      final eqIn = List<double>.generate(32, (i) => 0.4);
      for (final resp in <List<double>?>[null, <double>[1.0], <double>[]]) {
        final out = composeEqOutputSpectrum(eqIn, resp);
        for (var b = 0; b < 32; b++) {
          expect(out[b], closeTo(eqIn[b], 1e-9));
        }
      }
    });

    test('输入谱短于 32 段时不越界，缺段补 0', () {
      final out = composeEqOutputSpectrum([0.5, 0.6], flatResponse());
      expect(out.length, 32);
      expect(out[0], closeTo(0.5, 1e-9));
      expect(out[1], closeTo(0.6, 1e-9));
      expect(out.sublist(2).every((v) => v == 0.0), isTrue);
    });

    test('输出长度恒为 32（绘制端按固定长度索引）', () {
      expect(composeEqOutputSpectrum(const [], flatResponse()).length,
          32);
      expect(
          composeEqOutputSpectrum(List<double>.filled(64, 0.5),
                  flatResponse())
              .length,
          32);
    });

    test('responseFMax 与引擎 Nyquist 钳位公式一致', () {
      expect(AuraDspLib.responseFMax(sampleRate: 48000), 20000.0);
      expect(AuraDspLib.responseFMax(sampleRate: 16000),
          closeTo(16000 / 2 * 0.999, 1e-9));
    });

    test('responseDbAt 使用响应的实际上限频率', () {
      final response = List<double>.generate(129, (i) => i.toDouble());
      expect(
          VizBands.responseDbAt(response, 10000.0, responseFMax: 10000.0),
          closeTo(128.0, 1e-9));
      expect(
          VizBands.responseDbAt(response, 20000.0, responseFMax: 10000.0),
          closeTo(128.0, 1e-9));
    });

    test('responseDbAt 与绘制端共用同一对数映射', () {
      final response = List<double>.generate(129, (i) => i.toDouble());
      expect(VizBands.responseDbAt(response, 20.0), closeTo(0.0, 1e-9));
      expect(VizBands.responseDbAt(response, 20000.0), closeTo(128.0, 1e-9));
      expect(VizBands.responseDbAt(response, 10.0), closeTo(0.0, 1e-9));
      expect(VizBands.responseDbAt(response, 40000.0), closeTo(128.0, 1e-9));
      expect(VizBands.responseDbAt(const <double>[1.0], 1000.0), 0.0);
    });

    test('响应签名过期时退化为输入谱', () {
      final eqIn = List<double>.filled(32, 0.6);
      final out = composeEqOutputSpectrum(
        eqIn,
        List<double>.filled(129, 18.0),
        responseCurve: 'curve-a',
        expectedCurve: 'curve-b',
      );
      for (var b = 0; b < 32; b++) {
        expect(out[b], closeTo(eqIn[b], 1e-9), reason: 'band$b');
      }
    });

    test('响应签名一致时正常合成', () {
      final eqIn = List<double>.filled(32, 0.5);
      final out = composeEqOutputSpectrum(
        eqIn,
        List<double>.filled(129, 12.0),
        responseCurve: 'curve-a',
        expectedCurve: 'curve-a',
      );
      expect(VizBands.toDb(out.first), closeTo(VizBands.toDb(0.5) + 12.0, 0.01));
    });

    test('定点增益只影响其附近的频带（确认插值定位正确）', () {      // 只在 1kHz 附近给 -15dB，其余平坦
      final resp = responseWithDbAt(1000.0, -15.0);
      final eqIn = List<double>.filled(32, 0.6);
      final out = composeEqOutputSpectrum(eqIn, resp);
      // band17 = [1000, 1250]，正是 1kHz 所在的那一带
      expect(VizBands.edges[17], lessThanOrEqualTo(1000.0));
      expect(VizBands.edges[18], greaterThan(1000.0));
      expect(VizBands.toDb(out[17]), lessThan(VizBands.toDb(eqIn[17]) - 10.0),
          reason: '1kHz 所在的 band17 必须被压低');
      expect(VizBands.toDb(out[10]), closeTo(VizBands.toDb(eqIn[10]), 1.0),
          reason: '远离 1kHz 的低频带（band10）不应被牵连');
      expect(VizBands.toDb(out[24]), closeTo(VizBands.toDb(eqIn[24]), 1.0),
          reason: '远离 1kHz 的高频带（band24）不应被牵连');
    });
  });

  group('每点 Q（参量钟形合成）', () {
    test('eqOpModeForFilter 映射与引擎注释一致', () {
      expect(eqOpModeForFilter(0), 0);
      expect(eqOpModeForFilter(1), 2);
      expect(eqOpModeForFilter(2), 5);
      expect(eqOpModeForFilter(99), 0);
    });

    test('单频点中心即峰值，增益为 0 时 Q 无意义', () {
      const centers = [100.0, 1000.0, 10000.0];
      final atCenter = eqTargetGains(
        targetFreqs: [1000.0],
        centers: centers,
        peakGains: [0.0, 12.0, 0.0],
        qs: [1.0, 1.414, 1.0],
        sampleRate: 48000,
      );
      expect(atCenter.single, closeTo(12.0, 0.3));
      final flat = eqTargetGains(
        targetFreqs: centers,
        centers: centers,
        peakGains: [0.0, 0.0, 0.0],
        qs: [10.0, 0.3, 5.0],
        sampleRate: 48000,
      );
      for (final v in flat) {
        expect(v, closeTo(0.0, 1e-9));
      }
    });

    test('窄 Q 只动本带、宽 Q 波及邻带', () {
      const centers = [100.0, 1000.0, 10000.0];
      const peaks = [0.0, 12.0, 0.0];
      List<double> at(double q) => eqTargetGains(
            targetFreqs: centers,
            centers: centers,
            peakGains: peaks,
            qs: [1.414, q, 1.414],
            sampleRate: 48000,
          );
      final narrow = at(10.0);
      final wide = at(0.3);
      expect(narrow[1], closeTo(12.0, 0.5));
      expect(wide[1], closeTo(12.0, 0.5));
      expect(narrow[0].abs(), lessThan(wide[0].abs()));
      expect(narrow[2].abs(), lessThan(wide[2].abs()));
    });

    test('setEqBandQ 逐点设置、钳位并标记 custom', () {
      _withIsolatedModel((m) {
        final idx = m.eqFrequencies.indexOf(1000.0);
        expect(idx, greaterThanOrEqualTo(0));
        m.setEqBandQ(idx, 5.0);
        expect(m.eqQs[idx], closeTo(5.0, 1e-9));
        expect(m.eqPresetName, 'custom');
        m.setEqBandQ(idx, 99.0);
        expect(m.eqQs[idx], 10.0);
        m.setEqBandQ(-1, 5.0);
        m.setEqBandQ(9999, 5.0);
      });
    });

    test('applyEqQs 按频率重映射', () {
      _withIsolatedModel((m) {
        m.applyEqQs([100.0, 1000.0], [0.5, 5.0]);
        expect(m.eqQs[m.eqFrequencies.indexOf(100.0)], closeTo(0.5, 1e-9));
        expect(m.eqQs[m.eqFrequencies.indexOf(1000.0)], closeTo(5.0, 1e-9));
      });
    });

    test('预设快照携带 qs；旧标量 q 按全频带填充', () {
      _withIsolatedModel((m) {
        m.setEqBandQ(0, 3.0);
        final snap = PresetLibrary.snapshot(m, name: '__q__');
        final eq = snap.params['eq'] as Map;
        expect((eq['qs'] as List)[0], closeTo(3.0, 1e-9));

        m.setEqBandQ(0, 1.0);
        PresetLibrary.apply(m, snap);
        expect(m.eqQs[0], closeTo(3.0, 1e-9));

        final legacy = AuraPreset(
          name: '__legacy_q__',
          createdAt: DateTime.now().toIso8601String(),
          params: {
            'eq': {'q': 2.0},
          },
        );
        PresetLibrary.apply(m, legacy);
        expect(m.eqQs.every((q) => (q - 2.0).abs() < 1e-9), isTrue);
      });
    });

    test('快照是深拷贝：事后改动模型不污染已拍快照', () {
      _withIsolatedModel((m) {
        m.setEqBandQ(0, 3.0);
        m.setEqBandGain(0, 6.0);
        final snap = PresetLibrary.snapshot(m, name: '__snap__');
        m.setEqBandQ(0, 1.0);
        m.setEqBandGain(0, -6.0);
        final eq = snap.params['eq'] as Map;
        expect((eq['qs'] as List)[0], closeTo(3.0, 1e-9));
        expect((eq['gains'] as List)[0], closeTo(6.0, 1e-9));
      });
    });
  });
}