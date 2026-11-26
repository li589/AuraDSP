// viz_backend_matrix_test.dart — VM-05～VM-09：跨后端可视化矩阵。
//
// 所有后端复用既有 evt=viz 事件；backend 是来源标签，generation 是当前
// active pipeline 代际。测试只伪造传输事件，不伪造另一套生产链。
@TestOn('windows')
library;

import 'dart:async';
import 'dart:isolate';

import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/home_page.dart';
import 'package:auradsp_app/engine/auradsp_ffi.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/platform/adapters.dart';
import 'package:auradsp_app/platform/port/window.dart';
import 'package:auradsp_app/ui/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _BackendCase = ({String name, String source, String? asioFlavor});

class _IsoCommands {
  final ReceivePort _port = ReceivePort();
  final List<Map<String, dynamic>> sent = [];
  late final StreamSubscription<dynamic> _subscription;

  _IsoCommands(AppModel model) {
    _subscription = _port.listen((raw) {
      if (raw is Map) sent.add(Map<String, dynamic>.from(raw));
    });
    model.handleMessageForTesting({'evt': 'isoReady', 'port': _port.sendPort});
  }

  Future<void> flush() => Future<void>.delayed(Duration.zero);

  Future<void> close() async {
    await _subscription.cancel();
    _port.close();
  }
}

const _cases = <_BackendCase>[
  (name: 'local/WASAPI', source: 'local', asioFlavor: null),
  (name: 'VAIO', source: 'vaio', asioFlavor: null),
  (name: 'VB', source: 'vb', asioFlavor: null),
  (name: 'APO', source: 'sysapo', asioFlavor: null),
  (name: 'ASIO virtual', source: 'asio', asioFlavor: AudioModes.asioVirtual),
  (name: 'ASIO client', source: 'asio', asioFlavor: AudioModes.asioClient),
];

AppModel _model(_BackendCase c, {WindowPort? window}) {
  final m = AppModel(testing: true, window: window);
  switch (c.source) {
    case 'local':
      m.config.modeCategory = AudioModes.categoryPipeline;
      m.config.audioMode = 'vaio';
      m.config.pipelineInput = AudioModes.inputWasapi;
      m.config.pipelineOutput = AudioModes.outputWasapi;
      m.audioMode = 'vaio';
    case 'vaio':
      m.config.modeCategory = AudioModes.categoryPipeline;
      m.config.audioMode = 'vaio';
      m.config.pipelineInput = AudioModes.inputVaio;
      m.config.pipelineOutput = AudioModes.outputWasapi;
      m.audioMode = 'vaio';
    case 'vb':
      m.config.modeCategory = AudioModes.categoryAttachment;
      m.config.audioMode = 'vbcallback';
      m.audioMode = 'vbcallback';
    case 'sysapo':
      m.config.modeCategory = AudioModes.categoryAttachment;
      m.config.audioMode = 'sysapo';
      m.config.apoTargetEndpoint = '';
      m.audioMode = 'sysapo';
    case 'asio':
      m.config.modeCategory = AudioModes.categoryAsio;
      m.config.audioMode = 'asio';
      m.config.asioFlavor = c.asioFlavor!;
      m.config.pipelineInput = c.asioFlavor == AudioModes.asioVirtual
          ? AudioModes.inputAsioDriver
          : AudioModes.inputWasapi;
      m.config.pipelineOutput = c.asioFlavor == AudioModes.asioVirtual
          ? AudioModes.outputWasapi
          : AudioModes.outputAsioClient;
      m.audioMode = 'asio';
  }
  expect(m.expectedVizBackend, c.source);
  return m;
}

Map<String, dynamic> _frame(
  _BackendCase c, {
  required int generation,
  double fill = 0.45,
  double eqFill = 0.65,
  int? ts,
}) {
  final pcm = c.source == 'local' || c.source == 'asio'
      ? <double>[0.1, -0.1, 0.2, -0.2]
      : null;
  return {
    'evt': 'viz',
    'backend': c.source,
    'generation': generation,
    'ts': ?ts,
    if (c.source == 'sysapo') 'endpointId': '',
    'spectrum': List<double>.filled(32, fill),
    'eqIn': List<double>.filled(32, eqFill),
    'pcm': ?pcm,
    'pcmSource': switch (c.source) {
      'local' => 'source',
      'asio' => 'engine',
      _ => null,
    },
    'l': -6.0,
    'r': -7.0,
    'stageL': List<double>.filled(kEngineStageCount, -8.0),
    'stageR': List<double>.filled(kEngineStageCount, -9.0),
    'inputInL': -10.0,
    'inputInR': -11.0,
    'inputOutL': -12.0,
    'inputOutR': -13.0,
    'chCount': 2,
    'chLevels': <double>[-6.0, -7.0],
    'stageCh': List<double>.filled(kVizStageTelemetry * 2, -8.0),
  };
}

void _expectHot(AppModel m, _BackendCase c, {double fill = 0.45}) {
  expect(m.vizSource, c.source);
  expect(m.spectrum.value, List<double>.filled(32, fill));
  expect(m.eqInSpectrum.value, List<double>.filled(32, 0.65));
  expect(m.levelL.value, -6.0);
  expect(m.levelR.value, -7.0);
  expect(m.stageLevelsL.value.first, -8.0);
  expect(m.inputMeterInL.value, -10.0);
  expect(m.vizChannelLevels.value.take(2), <double>[-6.0, -7.0]);
  if (c.source == 'local' || c.source == 'asio') {
    expect(m.projectmPcmSnapshot.value, <double>[0.1, -0.1, 0.2, -0.2]);
  } else {
    expect(m.projectmPcmSnapshot.value, isEmpty);
  }
}

void _expectCleared(AppModel m) {
  expect(m.spectrum.value.every((v) => v == 0.0), isTrue);
  expect(m.eqInSpectrum.value.every((v) => v == 0.0), isTrue);
  expect(m.projectmPcmSnapshot.value, isEmpty);
  expect(m.levelL.value, -90.0);
  expect(m.levelR.value, -90.0);
  expect(m.vizChannelLevels.value.every((v) => v == -120.0), isTrue);
  expect(m.vizStageChLevels.value.every((v) => v == -120.0), isTrue);
}

Future<void> _expectDirectMutation(
  _BackendCase c, {
  required String command,
  required void Function(AppModel m) arrange,
  required void Function(AppModel m) mutate,
}) async {
  final m = _model(c);
  final iso = _IsoCommands(m);
  addTearDown(iso.close);
  addTearDown(m.dispose);
  await iso.flush();
  iso.sent.clear();
  arrange(m);
  m.handleMessageForTesting(_frame(c, generation: 0));
  _expectHot(m, c);

  mutate(m);
  _expectCleared(m);
  m.handleMessageForTesting(_frame(c, generation: 0, fill: 0.9));
  _expectCleared(m);

  await iso.flush();
  final mutations = iso.sent.where((m) => m['cmd'] == command).toList();
  expect(mutations, hasLength(1));
  expect(mutations.single['generation'], 1);
  expect(iso.sent.where((m) => m['cmd'] == 'setVizGeneration'), isEmpty);

  m.handleMessageForTesting(_frame(c, generation: 1, fill: 0.55));
  _expectHot(m, c, fill: 0.55);
}

void main() {
  group('VM-05～VM-09 backend matrix', () {
    for (final c in _cases) {
      test(
        '${c.name}: current generation updates; stale generation clears',
        () {
          final m = _model(c);
          addTearDown(m.dispose);

          m.handleMessageForTesting(_frame(c, generation: 0));
          _expectHot(m, c);

          // 实际源命令与代际更新必须同点生效；初始代际 0，停源后必须是 1。
          // 旧代际迟到帧不得把清屏后的显示面涂回。
          m.setSource('stop');
          _expectCleared(m);
          m.handleMessageForTesting(_frame(c, generation: 0, fill: 0.9));
          _expectCleared(m);

          m.handleMessageForTesting(_frame(c, generation: 1, fill: 0.55));
          _expectHot(m, c, fill: 0.55);
        },
      );
    }

    test('APO EQ background uses eqIn tap and composes the EQ response', () {
      final c = _cases[3];
      final m = _model(c);
      addTearDown(m.dispose);
      m.handleMessageForTesting(_frame(c, generation: 0));

      expect(m.eqInSpectrum.value.every((v) => v == 0.65), isTrue);
      final eqOut = m.eqOutputSpectrum();
      expect(eqOut, hasLength(32));
      expect(eqOut.every((v) => (v - 0.65).abs() < 1e-9), isTrue);
      expect(
        eqOut.every((v) => v != 0.45),
        isTrue,
        reason: '整链输出谱不得冒充 EQ 输入/输出背景谱',
      );
    });

    test(
      'stop invalidates the old generation and clears every display plane',
      () {
        final c = _cases[0];
        final m = _model(c);
        addTearDown(m.dispose);
        m.handleMessageForTesting(_frame(c, generation: 0));

        m.setSource('stop');
        _expectCleared(m);
        m.handleMessageForTesting(_frame(c, generation: 0, fill: 0.9));
        _expectCleared(m);
      },
    );

    test('dispose ignores late frames without touching disposed notifiers', () {
      final c = _cases[0];
      final m = _model(c);
      m.handleMessageForTesting(_frame(c, generation: 0));
      final spectrum = m.spectrum;
      m.dispose();

      expect(
        () => m.handleMessageForTesting(_frame(c, generation: 0, fill: 0.9)),
        returnsNormally,
      );
      expect(spectrum.value, List<double>.filled(32, 0.45));
    });

    test('hidden-window gate drops polled and telemetry frames uniformly', () {
      for (final c in _cases) {
        final m = _model(c);
        m.handleMessageForTesting(_frame(c, generation: 0));
        m.window.setVisible(false);
        m.setSource('stop');
        m.handleMessageForTesting(_frame(c, generation: 1, fill: 0.9));
        _expectCleared(m);
        m.window.setVisible(true);
        m.dispose();
      }
    });

    testWidgets('source switch clears _gatedSpectrum when activity is closed', (
      tester,
    ) async {
      final m = _model(_cases[0], window: PlatformAdapters.instance.window);
      m.playing = true;
      addTearDown(() => m.window.setVisible(true));
      addTearDown(m.dispose);
      await tester.pumpWidget(
        MaterialApp(
          theme: withAuraExtension(
            buildAuraTheme(m.themeId),
            m.themeId.palette,
          ),
          locale: m.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: HomePage(model: m),
        ),
      );
      await tester.pump();

      m.handleMessageForTesting(_frame(_cases[0], generation: 0));
      await tester.pump();
      List<double> gated() =>
          tester.widget<SpectrumView>(find.byType(SpectrumView)).spectrum.value;
      expect(gated().every((v) => v == 0.45), isTrue);
      final gatedNotifier = tester
          .widget<SpectrumView>(find.byType(SpectrumView))
          .spectrum;

      // 隐藏会先关闭活动门。随后 APO/VB 等来源切换虽清 model.spectrum，
      // 旧 _SpectrumCard 在 !_effective 分支直接 return，代理仍持有热帧。
      m.window.setVisible(false);
      m.levelL.value = -90.0;
      m.levelR.value = -90.0;
      await tester.pump();
      // 再恢复窗口可见：活动门仍关闭，直到下一帧有声数据才开；这样
      // 来源切换本身不会被 state 的 hidden-window 丢帧门掩盖。
      m.window.setVisible(true);
      await tester.pump();
      m.setAudioMode('vbcallback');
      await tester.pump();
      expect(gatedNotifier.value.every((v) => v == 0.0), isTrue);
    });
  });

  group('Task 17 fix round 1', () {
    test('current local and bridge generations accept native monotonic ts', () {
      for (final c in <_BackendCase>[_cases[0], _cases[1]]) {
        final m = _model(c);
        m.handleMessageForTesting(_frame(c, generation: 0));
        m.setSource('stop');
        _expectCleared(m);

        // Native viz timestamps are engine-relative, not Unix epoch time.
        m.handleMessageForTesting(_frame(c, generation: 1, ts: 17, fill: 0.55));
        _expectHot(m, c, fill: 0.55);
        m.dispose();
      }
    });

    test(
      'direct capture input restart invalidates the old generation',
      () async {
        await _expectDirectMutation(
          _cases[0],
          command: 'capturerestart',
          arrange: (m) {
            m.captureActive = true;
            m.config.pipelineInputDevice = 'capture-A';
            m.config.pipelineOutputDevice = 'render-A';
          },
          mutate: (m) => m.setPipelineInputDevice('capture-B'),
        );
      },
    );

    test(
      'direct capture output restart invalidates the old generation',
      () async {
        await _expectDirectMutation(
          _cases[0],
          command: 'capturerestart',
          arrange: (m) {
            m.captureActive = true;
            m.config.pipelineInputDevice = 'capture-A';
            m.config.pipelineOutputDevice = 'render-A';
          },
          mutate: (m) => m.setPipelineOutputDevice('render-B'),
        );
      },
    );

    test('direct APO target change invalidates the old generation', () async {
      await _expectDirectMutation(
        _cases[3],
        command: 'apotarget',
        arrange: (_) {},
        mutate: (m) => m.setApoTargetEndpoint('endpoint-B'),
      );
    });

    test(
      'direct VAIO endpoint restart invalidates the old generation',
      () async {
        await _expectDirectMutation(
          _cases[1],
          command: 'vaiorestart',
          arrange: (m) => m.vaioActive = true,
          mutate: (m) => m.setVaioOutputEndpoint('endpoint-B'),
        );
      },
    );

    for (final entry in <(String, void Function(AppModel))>[
      ('driver', (m) => m.setAsioDriver('driver-B')),
      ('buffer', (m) => m.setAsioBufSize(512)),
      ('output pair', (m) => m.setAsioOutPair(2)),
    ]) {
      test(
        'direct ASIO ${entry.$1} restart invalidates the old generation',
        () async {
          await _expectDirectMutation(
            _cases[5],
            command: 'asiorestart',
            arrange: (m) => m.asioActive = true,
            mutate: entry.$2,
          );
        },
      );
    }

    test(
      'producer timer cannot use a generation sent before source teardown',
      () async {
        final c = _cases[0];
        final m = _model(c);
        final port = ReceivePort();
        var isolateGeneration = 0;
        var oldProducerAlive = true;
        var armed = false;
        Map<String, dynamic>? sourceCommand;
        final subscription = port.listen((raw) {
          if (raw is! Map) return;
          final command = Map<String, dynamic>.from(raw);
          if (command['cmd'] == 'setVizGeneration') {
            isolateGeneration = (command['value'] as num).toInt();
            if (armed && oldProducerAlive) {
              // This is the old source's timer running before the next command.
              m.handleMessageForTesting(
                _frame(c, generation: isolateGeneration, fill: 0.9),
              );
            }
          } else if (command['cmd'] == 'source') {
            sourceCommand = command;
            isolateGeneration =
                (command['generation'] as num?)?.toInt() ?? isolateGeneration;
            oldProducerAlive = false;
          }
        });
        addTearDown(() async {
          await subscription.cancel();
          port.close();
          m.dispose();
        });
        m.handleMessageForTesting({'evt': 'isoReady', 'port': port.sendPort});
        await Future<void>.delayed(Duration.zero);
        armed = true;
        m.handleMessageForTesting(_frame(c, generation: 0));

        m.setSource('stop');
        await Future<void>.delayed(Duration.zero);

        _expectCleared(m);
        expect(sourceCommand?['generation'], 1);
      },
    );
  });
}
