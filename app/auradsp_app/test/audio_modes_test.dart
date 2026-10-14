import 'package:auradsp_app/core/audio_modes.dart';
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
}
