import 'dart:math' as math;
import 'dart:typed_data';

import 'package:auradsp_app/engine/audio_isolate.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('WaveSource（第四十四轮 S4）', () {
    test('正弦：RMS 与过零数符合 440Hz/0.3 幅', () {
      final src = WaveSource(freq: 440);
      final buf = Float32List(4800 * 2); // 0.1s @48k
      src.fill(buf, 4800, 48000);
      var sumSq = 0.0;
      var crossings = 0;
      for (var i = 0; i < 4800; i++) {
        final v = buf[i * 2];
        expect(buf[i * 2 + 1], v, reason: '双声道同值');
        sumSq += v * v;
        if (i > 0 && (buf[(i - 1) * 2] < 0) != (v < 0)) crossings++;
      }
      final rms = math.sqrt(sumSq / 4800);
      expect(rms, closeTo(0.3 / math.sqrt2, 0.01));
      expect(crossings, inInclusiveRange(86, 90)); // 2*440*0.1
    });

    test('方波：样本恒 ±0.3', () {
      final src = WaveSource(shape: 'square', freq: 100);
      final buf = Float32List(4800 * 2);
      src.fill(buf, 4800, 48000);
      for (var i = 0; i < 4800; i++) {
        expect(buf[i * 2].abs(), closeTo(0.3, 1e-6));
      }
    });

    test('三角波：峰值达 ±0.3 且连续', () {
      final src = WaveSource(shape: 'triangle', freq: 100);
      final buf = Float32List(480 * 2); // 恰一个周期 @48k/100Hz
      src.fill(buf, 480, 48000);
      var mx = 0.0;
      for (var i = 0; i < 480; i++) {
        mx = math.max(mx, buf[i * 2].abs());
      }
      expect(mx, greaterThan(0.29));
    });

    test('热改频率：相位连续、无跳变', () {
      final src = WaveSource(freq: 440);
      final buf = Float32List(960 * 2);
      src.fill(buf, 480, 48000);
      src.freq = 5000; // 播放中热改
      src.fill(Float32List.sublistView(buf, 480 * 2), 480, 48000);
      final maxStep = 0.3 * 2 * math.pi * 5000 / 48000 + 0.01;
      for (var i = 1; i < 960; i++) {
        final d = (buf[i * 2] - buf[(i - 1) * 2]).abs();
        expect(d, lessThan(maxStep), reason: '帧 $i 跳变 $d');
      }
    });

    test('扫频：对数律 20→20k、20 秒回绕', () {
      final src = WaveSource(freq: 440, sweep: true);
      expect(src.instFreq, closeTo(20, 0.5));
      final chunk = Float32List(4800 * 2);
      for (var i = 0; i < 100; i++) {
        src.fill(chunk, 4800, 48000); // 共 10 秒
      }
      expect(src.instFreq, closeTo(20 * math.sqrt(1000), 30)); // 半程几何中点
      for (var i = 0; i < 100; i++) {
        src.fill(chunk, 4800, 48000); // 再 10 秒 → 回绕
      }
      expect(src.instFreq, lessThan(30));
    });
  });

  group('FileSource 传输面（第四十四轮 S4）', () {
    FileSource ramp() {
      final data = Float32List(1000 * 2);
      for (var i = 0; i < 1000; i++) {
        data[i * 2] = i / 1000;
        data[i * 2 + 1] = i / 1000;
      }
      return FileSource(data, 48000);
    }

    test('totalFrames/positionRatio/seekRatio', () {
      final fs = ramp();
      expect(fs.totalFrames, 1000);
      expect(fs.positionRatio, 0);
      fs.seekRatio(0.5);
      expect(fs.positionRatio, closeTo(0.5, 0.002));
      final buf = Float32List(4 * 2);
      fs.fill(buf, 4, 48000);
      expect(buf[0], closeTo(0.5, 0.01), reason: '定位后从中点续播');
    });

    test('seekRatio 钳制 0..1', () {
      final fs = ramp();
      fs.seekRatio(2);
      expect(fs.positionRatio, lessThanOrEqualTo(1));
      fs.seekRatio(-1);
      expect(fs.positionRatio, 0);
    });
  });
}
