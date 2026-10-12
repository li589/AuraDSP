// ir_sample_rate_test.dart — IR 采样率权威回归。
//
// IR 文件在引擎侧被离线重采样到协商后的实际设备采样率，因此：
// - 是否显示“已重采样”，必须比较原始采样率与实际设备采样率；
// - 重采样后的帧数换算时长/延迟，也必须使用实际设备采样率。
import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 构造与真实用户目录隔离的 AppModel：构造会读写配置与会话，
/// 测试结果不能依赖本机残留文件。
AppModel _isolatedModel(Directory dir) {
  ConfigManager.baseDirOverride = dir.path;
  return AppModel();
}

void _withIsolatedModel(void Function(AppModel m) body) {
  final dir = Directory.systemTemp.createTempSync('auradsp_state_test');
  final m = _isolatedModel(dir);
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

void main() {
  group('IR 采样率权威', () {
    test('是否显示重采样提示只比较原始采样率与实际设备采样率', () {
      expect(
          AppModel.irWasResampled(srcRate: 44100, deviceRate: 48000), isTrue);
      expect(
          AppModel.irWasResampled(srcRate: 44100, deviceRate: 44100), isFalse);
      expect(AppModel.irWasResampled(srcRate: 0, deviceRate: 48000), isFalse);
    });

    test('延迟兜底使用重采样后的帧数与实际设备采样率', () {
      _withIsolatedModel((m) {
        m.info = EngineInfo(1, 'test', 44100, 2, 1024);
        expect(m.engineRate, 44100);
        m.convEnabled = true;
        m.convReady = true;
        m.convFrames = 44100;
        m.convSrcRate = 48000;

        final latency = m.componentLatency('convolver');

        expect(latency.measured, isFalse);
        expect(latency.ms, closeTo(1000.0, 1e-9));
      });
    });

    test('EQ 是否生效同时要求全局开关与非旁路', () {
      _withIsolatedModel((m) {
        m.eqOn = true;
        m.eqBypass = false;
        expect(m.isEqActive, isTrue);

        m.eqBypass = true;
        expect(m.isEqActive, isFalse);

        m.eqOn = false;
        m.eqBypass = false;
        expect(m.isEqActive, isFalse);
      });
    });
  });
}
