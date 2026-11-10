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

  group('linuxModeHintId (polish phase 2)', () {
    String hint({
      String mode = 'system',
      String note = '',
      bool driverLoaded = false,
      bool captureActive = false,
      bool virtualSinkPresent = false,
      bool defaultIsVirtual = false,
    }) =>
        linuxModeHintId(
          mode: mode,
          note: note,
          driverLoaded: driverLoaded,
          captureActive: captureActive,
          virtualSinkPresent: virtualSinkPresent,
          defaultIsVirtual: defaultIsVirtual,
        );

    test('specific isolate notes win over derived hints', () {
      expect(hint(mode: 'virtual', note: 'virtual-sink-unavailable'),
          'note:virtual-sink-unavailable');
      expect(hint(mode: 'driver', note: 'alsa-capture-unavailable',
          driverLoaded: true), 'note:alsa-capture-unavailable');
      expect(hint(mode: 'virtual', note: 'capture-lost',
          captureActive: false), 'note:capture-lost');
      // 具体 note 优先于反馈告警（先处理失败原因）。
      expect(hint(mode: 'virtual', note: 'pulse-unavailable',
          defaultIsVirtual: true), 'note:pulse-unavailable');
    });

    test('snd-aloop note and missing module map to driver-missing', () {
      expect(hint(mode: 'driver', note: 'snd-aloop-not-loaded'),
          'driver-missing');
      expect(hint(mode: 'driver'), 'driver-missing');
    });

    test('unknown notes fall through to derived hints', () {
      expect(hint(mode: 'virtual', note: 'some-future-note',
          captureActive: true, virtualSinkPresent: true), 'virtual-ready');
    });

    test('feedback warning beats ready, inactive beats ready', () {
      // 默认输出=虚拟 sink：反馈告警优先于就绪指引。
      expect(hint(mode: 'virtual', captureActive: true,
          virtualSinkPresent: true, defaultIsVirtual: true),
          'feedback-warning');
      // sink 在位但采集未建立：报未建立，不报就绪（二期顺序修正）。
      expect(hint(mode: 'virtual', virtualSinkPresent: true),
          'capture-inactive');
    });

    test('output-to-virtual is a soft notice outside virtual mode', () {
      expect(hint(mode: 'system', defaultIsVirtual: true),
          'output-to-virtual');
      expect(hint(mode: 'driver', driverLoaded: true, captureActive: true,
          defaultIsVirtual: true), 'output-to-virtual');
    });

    test('quiet states produce no hint', () {
      expect(hint(mode: 'system'), '');
      expect(hint(mode: 'driver', driverLoaded: true, captureActive: true),
          '');
      expect(hint(mode: 'virtual', captureActive: true,
          virtualSinkPresent: true), 'virtual-ready');
    });
  });
  group('ModeCaps（Part I Q0-7 定版）', () {
    test('sysapo: apo processing + shadow editors + no file/mc', () {
      final c = AudioModes.capsFor('sysapo');
      expect(c.pluginProcessing, PluginProcessing.apo);
      expect(c.pluginEditors, PluginEditors.shadowInstance);
      expect(c.pluginLiveMeters, isFalse);
      expect(c.routeSelector, isFalse);
      expect(c.fileEffects, isFalse);
      expect(c.mcScript, isFalse);
      expect(c.chainVizLive, isTrue);
    });

    test('vbcallback: local + route selector on（VB 下拉唯一来源）', () {
      final c = AudioModes.capsFor('vbcallback');
      expect(c.pluginProcessing, PluginProcessing.local);
      expect(c.pluginEditors, PluginEditors.liveInstance);
      expect(c.routeSelector, isTrue);
      expect(c.fileEffects, isTrue);
      expect(c.mcScript, isTrue);
      // 存量别名与归一化 id 同表。
      expect(AudioModes.capsFor('voicemeeter_api').routeSelector, isTrue);
    });

    test('vaio/asio/linux trio: local default, no route selector', () {
      for (final m in ['vaio', 'asio', 'system', 'virtual', 'driver']) {
        final c = AudioModes.capsFor(m);
        expect(c.pluginProcessing, PluginProcessing.local, reason: m);
        expect(c.pluginEditors, PluginEditors.liveInstance, reason: m);
        expect(c.pluginLiveMeters, isTrue, reason: m);
        expect(c.routeSelector, isFalse, reason: m);
        expect(c.fileEffects, isTrue, reason: m);
        expect(c.mcScript, isTrue, reason: m);
        expect(c.chainVizLive, isTrue, reason: m);
      }
    });

    test('sysapo 下路线选择器恒关（VB 下拉不出现——钉死）', () {
      // plugins_hero 与频谱仪的 VB 区块都只看 routeSelector；
      // sysapo 为 false 即结构性不渲染，与模式字符串无关。
      expect(AudioModes.capsFor('sysapo').routeSelector, isFalse);
    });

    test('unknown mode falls back to local default', () {
      final c = AudioModes.capsFor('nope');
      expect(c.pluginProcessing, PluginProcessing.local);
      expect(c.fileEffects, isTrue);
    });
  });
}
