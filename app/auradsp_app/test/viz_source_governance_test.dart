// viz_source_governance_test.dart — 第二十三轮：频谱按数据来源治理
//
// user 实测（2026-11-13）：切换到无声的其它驱动选项时频谱有时
// 残留。治理口径（状态层按来源）：
// - 每种模式有唯一的预期 viz 来源（expectedVizBackend），非预期
//   来源的帧（切换后旧源的迟到帧/断流补帧）一律丢弃；
// - 预期来源变化即清零显示面（_syncVizSourceOnSwitch），新源
//   无帧时旧谱不得残留。
// 平台注记：sysapo/vb/asio/vaio 是 Windows 域模式，Linux 上不存在
// （CI J6 首跑实证），涉 Windows 模式的三例标 testOn: windows；
// capture/local 一例与平台无关，两边都跑。
import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _viz({
  String? backend,
  double fill = 0.5,
  int chCount = 2,
}) =>
    {
      'evt': 'viz',
      'backend': ?backend,
      'spectrum': List<double>.filled(32, fill),
      'eqIn': List<double>.filled(32, fill),
      'l': -6.0,
      'r': -6.0,
      'chCount': chCount,
      'chLevels': List<double>.filled(chCount, -6.0),
      'stageCh': List<double>.filled(21 * chCount, -6.0),
    };

bool _spectrumHot(AppModel m) => m.spectrum.value.any((e) => e != 0.0);
bool _spectrumZero(AppModel m) => m.spectrum.value.every((e) => e == 0.0);

void main() {
  group('viz source governance (round 23)', () {
    test('expected backend follows mode and pipeline chain', () {
      final model = AppModel(testing: true);
      // 起始模式显式设定：同文件内前序测试的落盘会污染后续构造
      // 的配置默认值，不依赖机器存量配置。
      model.setAudioMode('sysapo');
      expect(model.expectedVizBackend, 'sysapo');
      model.setAudioMode('vbcallback');
      expect(model.expectedVizBackend, 'vb');
      model.setAudioMode('asio');
      expect(model.expectedVizBackend, 'asio');
      model.setAudioMode('vaio');
      model.setPipelineInput(AudioModes.inputVaio);
      expect(model.expectedVizBackend, 'vaio');
      // 管线内改选捕获链（wasapi 进 + wasapi 出）：喂数者是进程内
      // 泵而非 VAIO 桥——合成链优先于 audioMode 直判。
      model.setPipelineInput(AudioModes.inputWasapi);
      model.setPipelineOutput(AudioModes.outputWasapi);
      expect(model.pipelineChain, PipelineChain.capture);
      expect(model.expectedVizBackend, 'local');
    }, testOn: 'windows');

    test('frames from a non-expected source are dropped', () {
      final model = AppModel(testing: true);
      model.setAudioMode('sysapo');
      expect(model.expectedVizBackend, 'sysapo');
      model.handleMessageForTesting(_viz(backend: 'vaio'));
      expect(_spectrumZero(model), isTrue, reason: 'foreign frame dropped');
      expect(model.vizSource, isNull);
      model.handleMessageForTesting(_viz(backend: 'sysapo'));
      expect(_spectrumHot(model), isTrue);
      expect(model.vizSource, 'sysapo');
    }, testOn: 'windows');

    test('switching mode clears the display immediately', () {
      final model = AppModel(testing: true);
      model.setAudioMode('sysapo');
      model.handleMessageForTesting(_viz(backend: 'sysapo', chCount: 8));
      expect(_spectrumHot(model), isTrue);
      expect(model.vizChannelCount.value, 8);
      // 切到 VAIO 链（模式 + 管线输入，与面板操作同路径）。
      model.setAudioMode('vaio');
      model.setPipelineInput(AudioModes.inputVaio);
      expect(model.expectedVizBackend, 'vaio');
      expect(_spectrumZero(model), isTrue, reason: 'switch clears spectrum');
      expect(model.levelL.value, -90.0);
      expect(model.vizSource, isNull);
      expect(model.vizChannelCount.value, 0,
          reason: 'channel expansion falls back with the clear');
      // 旧源迟到帧不得把显示面涂回；新源帧正常收。
      model.handleMessageForTesting(_viz(backend: 'sysapo'));
      expect(_spectrumZero(model), isTrue, reason: 'stale source dropped');
      model.handleMessageForTesting(_viz(backend: 'vaio'));
      expect(_spectrumHot(model), isTrue);
      expect(model.vizSource, 'vaio');
    }, testOn: 'windows');

    test('capture chain accepts untagged (local) frames only', () {
      final model = AppModel(testing: true);
      model.setAudioMode('vaio');
      model.setPipelineInput(AudioModes.inputWasapi);
      model.setPipelineOutput(AudioModes.outputWasapi);
      expect(model.expectedVizBackend, 'local');
      model.handleMessageForTesting(_viz(backend: 'vaio'));
      expect(_spectrumZero(model), isTrue);
      model.handleMessageForTesting(_viz()); // 无 backend 键 = local
      expect(_spectrumHot(model), isTrue);
      expect(model.vizSource, 'local');
    });
  });
}
