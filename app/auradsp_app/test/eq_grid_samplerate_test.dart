// C4：EQ 频率网格必须感知采样率。
//
// 缺陷（真实可复现）：eqFreqs7/10/15/31 是**硬编码**的常量网格，
// 与采样率无关 —— eqFreqs31 顶端是 20000 Hz。
// 在 32 kHz（Nyquist = 16 kHz）下，_pushEqCurve 用
// `math.min(f, nyquist)` 逐点钳位，于是 12500 / 16000 / 20000
// **三条频带全部塌缩到 16000 Hz**。
//
// 塌缩的后果不是「曲线被截断」，而是给引擎一条**退化坐标轴**：
// 重复频点经排序后并列，vendor 的 makima 在等距零点上求差分，
// 得到的插值结果没有意义 —— 这正是计划里「预设跨采样率失真」所指。
//
// 本文件锁定三条不变式：
//   1. 低采样率下网格不得含越界频点（不得有 ≥ Nyquist 的频带）。
//   2. 网格在 Nyquist 以内必须严格升序且**无重复**。
//   3. 同一组增益在不同采样率下，**低频段的行为必须保持**，
//      只允许高频段被裁掉 —— 不能整条曲线错位。
import 'dart:math' as math;

import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 state.dart 的 _pushEqCurve 同款：把网格钳到 Nyquist 以内。
List<double> clampedGrid(List<double> freqs, int sampleRate) {
  final nyquist = math.min(20000.0, sampleRate / 2.0);
  return freqs.map((f) => math.min(f, nyquist)).toList();
}

/// 引擎侧 build_eq_axis 的等价物：排序 + 去重检测。
List<double> sortedAxis(List<double> xs) {
  final y = List<double>.from(xs)..sort();
  return y;
}

int _countOf(String label) => int.parse(label.replaceAll(RegExp(r'[^0-9]'), ''));

void main() {
  const grids = <String, List<double>>{
    '7段': eqFreqs7,
    '10段': eqFreqs10,
    '15段': eqFreqs15,
    '31段': eqFreqs31,
  };
  const rates = <int>[48000, 44100, 32000, 24000, 16000];

  test('所有出厂网格在 48k 下无重复且升序', () {
    grids.forEach((name, g) {
      expect(g.toSet().length, g.length, reason: '$name 有重复频点');
      for (var i = 1; i < g.length; i++) {
        expect(g[i], greaterThan(g[i - 1]), reason: '$name 未严格升序 @ $i');
      }
    });
  });

  test('低采样率下钳位不得产生重复频点（否则引擎拿到退化轴）', () {
    // 这条在修复前会失败：32k 下 eqFreqs31 的三条高频带塌缩到 16000。
    final offenders = <String>[];
    for (final entry in grids.entries) {
      for (final sr in rates) {
        final c = eqGridFor(_countOf(entry.key), sr);
        final uniq = c.toSet();
        if (uniq.length != c.length) {
          offenders.add('${entry.key} @ ${sr}Hz: '
              '${c.length} 点塌缩为 ${uniq.length}');
        }
      }
    }
    expect(offenders, isEmpty,
        reason: '以下组合在钳位后出现重复频点：\n${offenders.join('\n')}');
  });

  test('低采样率下网格不得含 ≥ Nyquist 的频点', () {
    for (final entry in grids.entries) {
      for (final sr in rates) {
        final nyq = sr / 2.0;
        final over = eqGridFor(_countOf(entry.key), sr).where((f) => f > nyq).toList();
        expect(over, isEmpty,
            reason: '${entry.key} @ ${sr}Hz 含越界频点 ${over.length} 个'
                '${over.isEmpty ? '' : '（最高 ${over.last} Hz）'}');
      }
    }
  });

  test('Nyquist 以内的频带不受采样率影响（只裁高频，不移位）', () {
    // 32 kHz 下 Nyquist = 16 kHz。15 段网格的顶端 16000 **正好等于 Nyquist**，
    // 必须裁掉：中心频率落在 Nyquist 上的滤波器有一半响应在 Nyquist 之上，
    // 必然混叠。留 0.5% 余量后 16000 被裁，顶端落到 10000。
    final at32 = eqGridFor(15, 32000);
    expect(at32.contains(16000.0), isFalse,
        reason: '16000 = Nyquist，中心频率在此处会混叠，必须裁掉');
    expect(at32.last, 10000.0, reason: '裁掉顶端后应落在 10000');
    // 10000 在 Nyquist 以内，必须保留 —— 低频段不得被牵连
    expect(at32.contains(10000.0), isTrue);
    expect(at32.contains(250.0), isTrue);

    final at48 = eqGridFor(31, 48000);
    expect(at48.length, 31, reason: '48 kHz（Nyquist 24k）下应保留全部频带');
    expect(at48.last, 20000.0);

    final at24 = eqGridFor(31, 24000);
    expect(at24.length, lessThan(at48.length),
        reason: '24 kHz（Nyquist 12k）下高频带必须被裁掉');
    expect(at24.toSet().length, at24.length,
        reason: '裁剪后不得出现重复频点（会给引擎一条退化轴）');
    expect(at24.last, lessThan(12000.0),
        reason: '顶端必须严格小于 Nyquist');

    // 16 kHz 采样率（Nyquist 8k）：网格应只剩低频段，但不得为空
    final at16 = eqGridFor(31, 16000);
    expect(at16, isNotEmpty, reason: '极端采样率下仍需至少一个锚点');
    expect(at16.every((f) => f < 8000), isTrue);
  });
}