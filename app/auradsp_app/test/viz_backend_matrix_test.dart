// viz_backend_matrix_test.dart — VM-05～VM-09：跨后端可视化矩阵。
//
// 所有后端复用既有 evt=viz 事件；backend 是来源标签，generation 是当前
// active pipeline 代际。测试只伪造传输事件，不伪造另一套生产链。
@TestOn('windows')
library;

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
}) {
  final pcm = c.source == 'local' || c.source == 'asio'
      ? <double>[0.1, -0.1, 0.2, -0.2]
      : null;
  return {
    'evt': 'viz',
    'backend': c.source,
    'generation': generation,
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

          // applyPipelineChain 是所有来源/路由重组的既有汇合点；初始代际 0，
          // 重组后必须是 1。旧代际迟到帧不得把清屏后的显示面涂回。
          m.applyPipelineChain();
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
        m.applyPipelineChain();
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
      m.config.modeCategory = AudioModes.categoryAttachment;
      m.config.audioMode = 'vbcallback';
      m.audioMode = 'vbcallback';
      m.applyPipelineChain();
      await tester.pump();
      expect(gatedNotifier.value.every((v) => v == 0.0), isTrue);
    });
  });
}
