import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/config.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('windows offers exactly the four documented backends', () {
    expect(AudioModes.optionsFor('windows'),
        ['vaio', 'vbcallback', 'sysapo', 'asio']);
  });

  test('android offers root/rootless', () {
    expect(AudioModes.optionsFor('android'), ['root', 'rootless']);
  });

  test('linux/macos offer the tentative trio', () {
    for (final os in ['linux', 'macos']) {
      expect(AudioModes.optionsFor(os), ['system', 'virtual', 'driver']);
    }
  });

  test('unknown platform falls back to auto', () {
    expect(AudioModes.optionsFor('other'), ['auto']);
    expect(AudioModes.defaultFor('other'), 'auto');
  });

  test('normalize keeps valid ids and repairs unknown ones', () {
    expect(AudioModes.normalize('sysapo', 'windows'), 'sysapo');
    expect(AudioModes.normalize('nope', 'windows'),
        AudioModes.defaultFor('windows'));
    expect(AudioModes.normalize(null, 'android'),
        AudioModes.defaultFor('android'));
  });

  test('defaults are safe per platform', () {
    expect(AudioModes.defaultFor('windows'), 'sysapo');
    expect(AudioModes.defaultFor('android'), 'rootless');
    expect(AudioModes.defaultFor('linux'), 'system');
    expect(AudioModes.defaultFor('macos'), 'system');
  });

  test('asio mode is among windows options and normalizes safely', () {
    expect(AudioModes.optionsFor('windows'), contains('asio'));
    expect(AudioModes.normalize('asio', 'windows'), 'asio');
    // 非法值回退平台默认（asio 不会凭空出现）。
    expect(AudioModes.normalize('asio', 'android'),
        AudioModes.defaultFor('android'));
  });

  test('asio bridge config fields default to zero-config start', () {
    final cfg = AppConfig();
    expect(cfg.asioDriver, ''); // '' = 未选择（isolate 内部取清单第一个）
    expect(cfg.asioBufSize, 0); // 0 = 驱动 preferredSize
    expect(cfg.asioOutPair, 0); // ch1/2
  });

  test('asio bridge config fields roundtrip through json', () {
    final cfg = AppConfig(
        asioDriver: 'FL Studio ASIO', asioBufSize: 512, asioOutPair: 1);
    final back = AppConfig.fromJson(cfg.toJson());
    expect(back.asioDriver, 'FL Studio ASIO');
    expect(back.asioBufSize, 512);
    expect(back.asioOutPair, 1);
  });

  test('asio bridge config tolerates legacy json without the new keys', () {
    final back = AppConfig.fromJson({
      'audio': {'sampleRate': 48000, 'audioMode': 'asio'},
    });
    expect(back.audioMode, 'asio');
    expect(back.asioDriver, '');
    expect(back.asioBufSize, 0);
    expect(back.asioOutPair, 0);
  });
}
