import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/engine/audio_out/pulse_context.dart';
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

  test('ADR-009 two paradigms category inference and composing', () {
    expect(AudioModes.categoryForMode('sysapo'), AudioModes.categoryAttachment);
    expect(AudioModes.categoryForMode('vbcallback'), AudioModes.categoryAttachment);
    expect(AudioModes.categoryForMode('vaio'), AudioModes.categoryPipeline);
    expect(AudioModes.categoryForMode('asio'), AudioModes.categoryPipeline);

    expect(
        AudioModes.composeMode(
            category: AudioModes.categoryAttachment,
            attachmentMode: AudioModes.attachSysApo),
        'sysapo');
    expect(
        AudioModes.composeMode(
            category: AudioModes.categoryAttachment,
            attachmentMode: AudioModes.attachVoicemeeterApi),
        'vbcallback');
    expect(
        AudioModes.composeMode(
            category: AudioModes.categoryPipeline,
            pipelineOut: AudioModes.outputAsioClient),
        'asio');
    expect(
        AudioModes.composeMode(
            category: AudioModes.categoryPipeline,
            pipelineOut: AudioModes.outputWasapi),
        'vaio');
  });

  test('Linux three modes (ADR-012 D-5): options, normalize, compose', () {
    expect(AudioModes.optionsFor('linux'), ['system', 'virtual', 'driver']);
    expect(AudioModes.defaultFor('linux'), 'system');
    expect(AudioModes.normalize('virtual', 'linux'), 'virtual');
    expect(AudioModes.normalize('driver', 'linux'), 'driver');
    // Windows ids are not valid on Linux and fall back to the default.
    expect(AudioModes.normalize('vaio', 'linux'), 'system');
    expect(AudioModes.normalize(null, 'linux'), 'system');
    // composeMode with os=linux produces each of the three ids directly.
    for (final id in ['system', 'virtual', 'driver']) {
      expect(
          AudioModes.composeMode(
              category: AudioModes.categoryPipeline,
              pipelineOut: id,
              os: 'linux'),
          id);
      expect(
          AudioModes.composeMode(
              category: AudioModes.categoryAttachment,
              attachmentMode: id,
              os: 'linux'),
          id);
    }
    // Unknown candidates fall back to the Linux default.
    expect(
        AudioModes.composeMode(
            category: AudioModes.categoryPipeline,
            pipelineOut: 'vaio',
            os: 'linux'),
        'system');
  });

  test('loopback source selection prefers sink monitor (snd-aloop)', () {
    const mon = 'alsa_output.platform-snd_aloop.0.analog-stereo.monitor';
    const inp = 'alsa_input.platform-snd_aloop.0.analog-stereo';
    // 2026-11-02 实机：只有同名 sink 的 monitor 能采到回环信号；
    // 两种服务端枚举顺序下都必须稳定选 monitor。
    expect(pickLoopbackSource([mon, inp]), mon);
    expect(pickLoopbackSource([inp, mon]), mon);
    // 无 monitor 时回退到其它 loopback 源（兼容非标准命名）。
    expect(pickLoopbackSource([inp]), inp);
    expect(pickLoopbackSource(['auradsp_virtual.monitor', inp]), inp);
    expect(pickLoopbackSource(['auradsp_virtual.monitor']), isNull);
  });

  test('default sink follow retargets only on a real change', () {
    // 默认未变 → 不迁。
    expect(shouldRetargetSink(target: 'sink_a', current: 'sink_a'), isFalse);
    // 默认已变 → 迁。
    expect(shouldRetargetSink(target: 'sink_a', current: 'sink_b'), isTrue);
    // 打开时未能落名（target=null）→ 首次查到默认时显式重开落名。
    expect(shouldRetargetSink(target: null, current: 'sink_b'), isTrue);
    // 查不到默认（服务端异常）→ 保持现流。
    expect(shouldRetargetSink(target: 'sink_a', current: null), isFalse);
    expect(shouldRetargetSink(target: 'sink_a', current: ''), isFalse);
    // 新默认是自家虚拟 sink → 不迁（防输出回授进采集端）。
    expect(
        shouldRetargetSink(
            target: 'sink_a', current: PulseContextService.virtualSinkName),
        isFalse);
  });
}
