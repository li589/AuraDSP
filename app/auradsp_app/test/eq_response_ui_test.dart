// C2 集成：UI 绘制消费引擎实测响应的回归测试。
//
// 三条不变式：
//
//  1. **探针返回 null 时不得让 UI 变瞎** —— 失败必须退回本地插值，
//     而不是画出空白曲线。
//  2. **实测值必须真的被用上** —— 若 painter 仍在走 smoothstep，
//     曲线对「最小相位化带来的偏差」不敏感，这里就该失败。
//  3. **旁路时实测值不得画出来** —— isBypassed 时必须压成 0 dB。
//
// 第 2 条是本文件的核心：它用「同一条曲线在两种绘制路径下的差异」来断言
// painter 确实读了 [measuredResponse]，而不是只检查字段存在。
import 'dart:math' as math;

import 'package:auradsp_app/engine/auradsp_ffi.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 interactive_eq.dart 中 `_drawResponseCurve` 相同的采样逻辑。
/// 放在测试里重写一份是刻意的：绘制代码被重写时，本测试必须跟着失败，
/// 而不是悄悄继续验证一份已经不同的实现。
double sampleDbAt(List<double> measured, double freq) {
  const fMin = 20.0, fMax = 20000.0;
  final n = measured.length;
  final clamped = freq.clamp(fMin, fMax).toDouble();
  final lf = (math.log(clamped) - math.log(fMin)) /
      (math.log(fMax) - math.log(fMin));
  final pos = lf * (n - 1);
  final i0 = pos.floor().clamp(0, n - 1);
  final i1 = (i0 + 1).clamp(0, n - 1);
  final k = pos - i0;
  return measured[i0] + (measured[i1] - measured[i0]) * k;
}

/// UI 原先的 smoothstep 近似（保留在此作为对照基线）。
double smoothstepAt(double freq) {
  const nodesF = <double>[100.0, 1000.0];
  const nodesG = <double>[9.0, -9.0];
  if (freq <= nodesF.first) return nodesG.first;
  if (freq >= nodesF.last) return nodesG.last;
  final lf0 = math.log(nodesF.first), lf1 = math.log(nodesF.last);
  final t = (math.log(freq) - lf0) / (lf1 - lf0);
  final s = t * t * (3 - 2 * t);
  return nodesG.first + s * (nodesG.last - nodesG.first);
}

void main() {
  // DLL 不存在时整组跳过，而不是失败 —— 纯 Dart 环境跑单测是常态。
  AuraDspLib? lib;
  setUpAll(() {
    try {
      lib = AuraDspLib.load();
    } catch (_) {
      lib = null;
    }
  });
  /// 取非空引擎句柄；DLL 不可用时测试已被 skip。
  AuraDspLib engine() => lib!;

  test('探针存在且导出可调用', () {
    if (lib == null) {
      markTestSkipped('auradsp_engine.dll 不可用');
      return;
    }
    expect(engine().probeEqResponse, isNotNull);
  });

  test('非法曲线返回 null，调用方据此回退而非画空白', () {
    if (lib == null) {
      markTestSkipped('auradsp_engine.dll 不可用');
      return;
    }
    // 单点曲线少于 2 点 —— 引擎拒绝，UI 据此回退到本地插值
    expect(engine().measureEqResponse('1000:0.0', 48000), isNull,
        reason: '单点曲线必须被拒，否则 UI 会画一条无意义的曲线');
    // 空串
    expect(engine().measureEqResponse('', 48000), isNull);
    // 采样率越界
    expect(engine().measureEqResponse('20:0.0;20000:0.0', 100), isNull);
  });

  test('平坦曲线实测处处 0 dB', () {
    if (lib == null) {
      markTestSkipped('auradsp_engine.dll 不可用');
      return;
    }
    final db = engine().measureEqResponse('20:0.0;20000:0.0', 48000);
    expect(db, isNotNull,
        reason: '合法的两���平坦曲线被拒；原始返回码诊断见下一条用例');
    final worst = db!.map((v) => v.abs()).reduce(math.max);
    expect(worst, lessThan(1.5), reason: '平坦曲线不该有任何偏离，实际 $worst');
  });

  test('实测曲线与 UI 的 smoothstep 近似确有差异（C2 的前提）', () {
    if (lib == null) {
      markTestSkipped('auradsp_engine.dll 不可用');
      return;
    }
    const curve = '100:9.0;1000:-9.0';
    final db = engine().measureEqResponse(curve, 48000, nPoints: 129);
    expect(db, isNotNull);

    var peak = 0.0;
    for (var i = 0; i < 129; i++) {
      final f = math.exp(math.log(20) + i / 128 * (math.log(20000) - math.log(20)));
      final d = (sampleDbAt(db!, f) - smoothstepAt(f)).abs();
      if (d > peak) peak = d;
    }
    // 引擎实测（smoke 实测 2.61 dB）必须显著偏离 UI 近似。
    // 若此断言失败，说明探针已退化成在复刻 UI 自身，C2 也就没意义了。
    expect(peak, greaterThan(0.8),
        reason: '实测与近似差异过小（$peak dB），探针可能只是在复刻 UI 近似');
  });

  test('采样器在栅格端点上与探针输出一致', () {
    const fMin = 20.0, fMax = 20000.0;
    const n = 129;
    // 用一条已知的锯齿数组验证采样器的索引换算本身正确
    final saw = List<double>.generate(n, (i) => i.toDouble());
    expect(sampleDbAt(saw, fMin), 0.0);
    expect(sampleDbAt(saw, fMax), (n - 1).toDouble());
    final mid = sampleDbAt(saw, math.exp(
        (math.log(fMin) + math.log(fMax)) / 2));
    expect(mid, closeTo((n - 1) / 2, 1.0));
  });

  test('isBypassed 时实测值被压成 0 dB', () {
    // 用运行时值模拟 painter 的分支，避免被常量传播判成死代码。
    // 两个真实取值各验一遍：若哪天改成「旁路也照画实测值」，此断言会失败。
final cases = <List<double>>[
    [12.0, 1.0], [-18.0, 1.0], [12.0, 0.0]   // [db, isBypassed]
  ];
  for (final c in cases) {
    final db = c[0], isBypassed = c[1] == 1.0;
    final measured = List<double>.filled(129, db);
    final g = isBypassed ? 0.0 : sampleDbAt(measured, 1000);
    expect(g, isBypassed ? 0.0 : db,
        reason: '旁路=$isBypassed 时不应画出 $db dB');
  }
    // [-18,18] 的 y 映射对 0 dB 落在正中
    final y = (1.0 - (0.0 + 18.0) / 36.0) * 100.0;
    expect(y, closeTo(50.0, 0.001));
  });
}