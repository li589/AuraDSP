// A-06：EQ 目标曲线的采样率语义。
//
// 缺陷背景：同一预设在不同设备采样率下频响漂移。引擎 DSP 在非常见
// 采样率下经 ASRC 折叠到 44.1k/48k 工作域，但目标曲线曾按设备率
// （96k/192k）生成，RBJ 钟形的 f/fs 归一化让带宽随设备率变化，
// V-Shape 20k 一度差 9 dB、Pop 10k 差 9.5 dB。
//
// 本文件锁定两条不变式：
//   1. 设备率 → 工作率的映射与 jdspController.c 的 JamesDSPInit 一致。
//   2. 同一组中心/增益/Q 在任何设备率下生成的目标曲线必须完全相同
//      （共享 48k 参考率），否则预设会随设备率变声。
import 'dart:math' as math;

import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/engine/auradsp_ffi.dart' show AuraDspLib;
import 'package:flutter_test/flutter_test.dart';

/// 与 `_pushEqCurve` 同款频率轴：20 Hz 起点 + 15 段网格 + 工作域 Nyquist。
List<double> eqAxisFor(int deviceRate) {
  final workRate = eqWorkingRateFor(deviceRate);
  final nyquist = math.min(20000.0, workRate / 2.0);
  final axis = <double>[];
  if (eqFreqs15.first > 20) axis.add(20.0);
  for (final f in eqFreqs15) {
    axis.add(math.min(f, nyquist));
  }
  if (eqFreqs15.last < nyquist) axis.add(nyquist);
  return axis;
}

void main() {
  test('设备率 → 引擎工作率映射与 JamesDSPInit 一致', () {
    const expected = <int, int>{
      0: 48000,
      22050: 44100,
      32000: 48000,
      44100: 44100,
      48000: 48000,
      88200: 44100,
      96000: 48000,
      176400: 44100,
      192000: 48000,
    };
    expected.forEach((device, work) {
      expect(
        eqWorkingRateFor(device),
        work,
        reason: '${device}Hz 设备的 DSP 工作率应为 ${work}Hz',
      );
    });
  });

  test('同一组 EQ 频带在 44.1/48/96/192k 下目标曲线逐点一致', () {
    // V-Shape 的 15 段增益；16 kHz +7 dB 是原先漂移最大的频带。
    const centers = <double>[
      25, 40, 63, 100, 160, 250, 400, 630, 1000, //
      1600, 2500, 4000, 6300, 10000, 16000,
    ];
    const gains = <double>[
      1.4, 0.9, -0.1, -1.2, -2.5, -2.6, -1.0, 0.1, 0.2, //
      0.4, 1.1, 2.0, 2.8, 3.8, 7.0,
    ];
    const qs = <double>[
      1.414, 1.414, 1.414, 1.414, 1.414, 1.414, 1.414, 1.414, //
      1.414, 1.414, 1.414, 1.414, 1.414, 1.414, 1.414,
    ];

    List<double> curveFor(int deviceRate) {
      return eqTargetGains(
        targetFreqs: eqAxisFor(deviceRate),
        centers: centers,
        peakGains: gains,
        qs: qs,
        sampleRate: eqTargetReferenceRate,
      );
    }

    final reference = curveFor(48000);
    for (final rate in <int>[44100, 96000, 192000]) {
      final curve = curveFor(rate);
      expect(
        curve.length,
        reference.length,
        reason: '${rate}Hz 的频率轴长度必须与 48k 一致',
      );
      for (var i = 0; i < curve.length; i++) {
        expect(
          curve[i],
          closeTo(reference[i], 1e-9),
          reason:
              '${rate}Hz 第 $i 点（${eqAxisFor(rate)[i]} Hz）'
              '与 48k 目标曲线不一致',
        );
      }
    }
  });

  test('16 kHz 频带在 20 kHz 的目标增益固定按 48k 参考率', () {
    // 16k +7 dB / Q=1.414 的裙边在 20k：48k 参考率约 +1.109 dB，
    // 若误按 44.1k 工作率计算会掉到 +0.456 dB（差 0.65 dB），
    // 这正是共享参考率要消除的跨率漂移。
    final g = eqTargetGains(
      targetFreqs: const <double>[20000.0],
      centers: const <double>[16000.0],
      peakGains: const <double>[7.0],
      qs: const <double>[1.414],
      sampleRate: eqTargetReferenceRate,
    );
    expect(g.single, closeTo(1.109, 0.02));
  });

  test('响应探针上限：44.1/48/96/192k 均为 20 kHz，低采样率仍受设备 Nyquist 约束', () {
    for (final rate in <int>[44100, 48000, 96000, 192000]) {
      final workRate = eqWorkingRateFor(rate);
      final fMax = math.min(
        AuraDspLib.responseFMax(sampleRate: workRate),
        AuraDspLib.responseFMax(sampleRate: rate),
      );
      expect(fMax, closeTo(20000.0, 1e-9), reason: '${rate}Hz 的响应探针应覆盖到 20k');
    }
    // 32k 设备：工作域 48k，但可回放上限仍是 16k，UI 不应显示到 20k。
    expect(
      math.min(
        AuraDspLib.responseFMax(sampleRate: eqWorkingRateFor(32000)),
        AuraDspLib.responseFMax(sampleRate: 32000),
      ),
      lessThan(16000.0),
    );
  });
}
