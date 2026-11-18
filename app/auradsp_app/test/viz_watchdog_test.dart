import 'package:auradsp_app/platform/platform_profile.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

/// 第四十九轮 S4：统一可视化清屏机制——切换即清屏（链路
/// 重组汇合点 applyPipelineChain）+ 看门狗断流/静默清屏。
Map<String, dynamic> _vizFrame({required double level, required double spec}) =>
    {
      'evt': 'viz',
      'spectrum': List<double>.filled(32, spec),
      'l': level,
      'r': level,
    };

void main() {
  group('可视化清屏（第四十九轮 S4）', () {
    test('断流 >3s 看门狗清屏；3s 内不清；清后不重复清', () {
      final m = AppModel(testing: true);
      final t0 = DateTime.now();
      m.handleMessageForTesting(_vizFrame(level: -10, spec: 0.5));
      expect(m.levelL.value, -10);
      expect(m.spectrum.value.first, 0.5);
      m.vizWatchdogTick(t0.add(const Duration(seconds: 2)));
      expect(m.levelL.value, -10, reason: '3s 内不断定断流');
      m.vizWatchdogTick(t0.add(const Duration(seconds: 4)));
      expect(m.levelL.value, -90, reason: '断流超 3s 清屏');
      expect(m.spectrum.value.every((v) => v == 0.0), isTrue);
      // 已清零态再拍：保持清零、不抛错。
      m.vizWatchdogTick(t0.add(const Duration(seconds: 30)));
      expect(m.levelL.value, -90);
    });

    test('持续静默帧 >3s 清屏（GR/峰值残留兜底）', () {
      final m = AppModel(testing: true);
      m.handleMessageForTesting(_vizFrame(level: -10, spec: 0.5));
      expect(m.levelL.value, -10);
      m.handleMessageForTesting(_vizFrame(level: -120, spec: 0.0));
      // 静默帧本身已把电平压平；看门狗在静默持续超 3s 后
      // 统一清屏（含频谱与逐级表回落）。
      m.vizWatchdogTick(DateTime.now().add(const Duration(seconds: 4)));
      expect(m.levelL.value, -90, reason: '清屏地板 -90（区别于帧内 -120）');
      expect(m.stageLevelsL.value.every((v) => v == -90.0), isTrue);
    });

    test('有声帧持续到达时看门狗不清屏', () {
      final m = AppModel(testing: true);
      m.handleMessageForTesting(_vizFrame(level: -10, spec: 0.5));
      m.vizWatchdogTick(DateTime.now().add(const Duration(seconds: 1)));
      expect(m.levelL.value, -10);
    });

    test('链路重组（applyPipelineChain）即清屏', () {
      if (!PlatformProfile.supportsBridges) return; // 非桥平台该入口空转
      final m = AppModel(testing: true);
      m.handleMessageForTesting(_vizFrame(level: -10, spec: 0.5));
      expect(m.levelL.value, -10);
      m.applyPipelineChain();
      expect(m.levelL.value, -90, reason: '切换即清屏，不等新源首帧');
      expect(m.spectrum.value.every((v) => v == 0.0), isTrue);
    });
  });
}
