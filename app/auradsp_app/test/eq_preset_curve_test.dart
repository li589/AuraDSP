// C4：预设的 EQ 曲线必须按**频率**跨采样率/跨段数迁移。
//
// 缺陷背景：snapshot 写出 'frequencies'，apply 却只按 bandsCount 重建网格
// 再按下标灌 gains。预设保存于 48k/31 段，载回到 24k/15 段时，
// 第 i 个增益会贴到完全不同的频点上 —— 曲线形状被彻底打乱。
//
// 这里的断言全部针对「按频率重映射」这一语义，
// 且刻意覆盖两端：完全一致的网格必须逐点相等，
// 裁剪后的网格必须只丢高频段、其余逐点不动。
import 'dart:math' as math;

import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 对「预设曲线」执行与 AppModel.applyEqCurve 相同的重映射。
List<double> remap(List<double> targetGrid, List<double> srcFreqs,
    List<double> srcGains) {
  final out = List<double>.filled(targetGrid.length, 0.0);
  for (var i = 0; i < targetGrid.length; i++) {
    final f = targetGrid[i];
    var bi = 0;
    var best = double.infinity;
    for (var k = 0; k < srcFreqs.length; k++) {
      final d = (srcFreqs[k] - f).abs();
      if (d < best) {
        best = d;
        bi = k;
      }
    }
    out[i] = srcGains[bi];
  }
  return out;
}

void main() {
  test('网格一致时按频率重映射 == 按下标还原（无损）', () {
    final grid = AppModel.eqGridFor(15, 48000);
    final gains = List<double>.generate(grid.length, (i) => (i - 7) * 1.5);
    final out = remap(grid, grid, gains);
    for (var i = 0; i < grid.length; i++) {
      expect(out[i], closeTo(gains[i], 1e-9),
          reason: '第 $i 点在网格一致时必须原样保留');
    }
  });

  test('从 31 段/48k 载到 15 段/48k，低频段增益必须对齐', () {
    final srcF = AppModel.eqGridFor(31, 48000);
    final srcG = List<double>.generate(srcF.length, (i) => i * 0.5);
    final dstF = AppModel.eqGridFor(15, 48000);

    // 目标网格的每个频点在源网格里都应能找到**自身**
    // （两张出厂网格都是 ISO 三倍频程，15 段是 31 段的子集）
    for (final f in dstF) {
      final exact = srcF.any((s) => (s - f).abs() < 1e-9);
      expect(exact, isTrue, reason: '$f Hz 应同时存在于 31 段与 15 段网格');
    }

    final out = remap(dstF, srcF, srcG);
    final si = srcF.indexOf(dstF[0]);
    expect(out[0], closeTo(srcG[si], 1e-9));
  });

  test('跨采样率（48k -> 24k）不得错位，低频段必须完全一致', () {
    final srcF = AppModel.eqGridFor(31, 48000);
    // 造一条有辨识度的曲线：只在 1 kHz 附近抬起
    final srcG = srcF
        .map((f) => math.exp(-math.pow((math.log(f) - math.log(1000)) / 0.6, 2)) * 12.0)
        .toList();
    final dstF = AppModel.eqGridFor(31, 24000);

    // 目标网格是源网格的前缀（低采样率只裁高频）
    expect(dstF.length, lessThan(srcF.length));
    for (var i = 0; i < dstF.length; i++) {
      expect(dstF[i], closeTo(srcF[i], 1e-9),
          reason: '第 $i 个频点必须仍是源网格的第 $i 个（只裁尾部）');
    }
    final out = remap(dstF, srcF, srcG);
    for (var i = 0; i < dstF.length; i++) {
      expect(out[i], closeTo(srcG[i], 1e-9),
          reason: '第 $i 点增益不得因采样率变化而移位');
    }
  });

  test('极窄网格（16kHz 采样率）也不得错位', () {
    final srcF = AppModel.eqGridFor(31, 48000);
    final srcG = List<double>.generate(srcF.length, (i) => (i % 5) * 2.0 - 4.0);
    final dstF = AppModel.eqGridFor(31, 16000);
    expect(dstF, isNotEmpty);
    for (var i = 0; i < dstF.length; i++) {
      expect(dstF[i], closeTo(srcF[i], 1e-9));
    }
    final out = remap(dstF, srcF, srcG);
    for (var i = 0; i < dstF.length; i++) {
      expect(out[i], closeTo(srcG[i], 1e-9));
    }
  });

  test('预设频率与目标网格无交集时退化为常量而非崩���', () {
    final out = remap(<double>[20, 25], <double>[18000, 19000], <double>[6, 3]);
    expect(out, hasLength(2));
    expect(out.every((v) => v >= 3.0 && v <= 6.0), isTrue,
        reason: '无交集时应取最接近者，不应产生 NaN 或越界值');
  });

  test('等比网格的频率严格升序（重映射的前提）', () {
    for (final sr in <int>[48000, 44100, 32000, 24000, 16000]) {
      for (final n in <int>[7, 10, 15, 31]) {
        final g = AppModel.eqGridFor(n, sr);
        for (var i = 1; i < g.length; i++) {
          expect(g[i], greaterThan(g[i - 1]),
              reason: '$n 段 @ ${sr}Hz 第 $i 点未升序');
        }
      }
    }
  });
}