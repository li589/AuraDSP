import 'dart:async';

import 'package:auradsp_app/core/audio_modes.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/platform/port/system_monitor.dart';
import 'package:auradsp_app/platform/system/windows_system_monitor.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _scan(String defaultRender) => <String, dynamic>{
  'defaultRender': defaultRender,
  'defaultCapture': 'mic-a',
  'endpoints': const <Map<String, dynamic>>[],
};

AppModel _vizModel() {
  final model = AppModel(testing: true);
  model.setAudioMode('vaio');
  model.setPipelineInput(AudioModes.inputWasapi);
  model.setPipelineOutput(AudioModes.outputWasapi);
  return model;
}

void main() {
  group('WindowsSystemMonitor lifecycle', () {
    test('stop during scan await suppresses late event and tick', () async {
      final entered = Completer<void>();
      final release = Completer<Map<String, dynamic>>();
      var events = 0;
      var ticks = 0;
      final monitor = WindowsSystemMonitor(
        scanProbe: () {
          entered.complete();
          return release.future;
        },
        onEvent: (_) => events++,
        onTick: (_) => ticks++,
        interval: const Duration(days: 1),
      );
      monitor.noteExternalScan(_scan('current'));
      monitor.start();
      final pending = monitor.tick();
      await entered.future;

      monitor.stop();
      release.complete(_scan('stale'));
      await pending;

      expect(events, 0);
      expect(ticks, 0);
    });

    test('restart invalidates a scan awaiting in the old generation', () async {
      final entered = Completer<void>();
      final release = Completer<Map<String, dynamic>>();
      var events = 0;
      var ticks = 0;
      final monitor = WindowsSystemMonitor(
        scanProbe: () {
          entered.complete();
          return release.future;
        },
        onEvent: (_) => events++,
        onTick: (_) => ticks++,
        interval: const Duration(days: 1),
      );
      addTearDown(monitor.stop);
      monitor.noteExternalScan(_scan('current'));
      monitor.start();
      final pending = monitor.tick();
      await entered.future;

      monitor.stop();
      monitor.start();
      release.complete(_scan('stale'));
      await pending;

      expect(events, 0);
      expect(ticks, 0);
    });

    test('stop during APO await suppresses late topology event', () async {
      final apoEntered = Completer<void>();
      final releaseApo = Completer<Set<String>>();
      var apoCalls = 0;
      final events = <SysMonEvent>[];
      final monitor = WindowsSystemMonitor(
        scanProbe: () async => _scan('current'),
        apoProbe: () {
          apoCalls++;
          if (apoCalls == 1) return Future<Set<String>>.value({'ep-a'});
          apoEntered.complete();
          return releaseApo.future;
        },
        apoEveryTicks: 1,
        onEvent: events.add,
        interval: const Duration(days: 1),
      );
      await monitor.tick();
      monitor.start();
      final pending = monitor.tick();
      await apoEntered.future;

      monitor.stop();
      releaseApo.complete({'ep-b'});
      await pending;

      expect(
        events.where((e) => e.kind == SysMonEventKind.apoTopologyChanged),
        isEmpty,
      );
    });

    test(
      'stopping inside onEvent suppresses the remaining callbacks',
      () async {
        var events = 0;
        var ticks = 0;
        late final WindowsSystemMonitor monitor;
        monitor = WindowsSystemMonitor(
          scanProbe: () async => _scan('stale'),
          onEvent: (_) {
            events++;
            monitor.stop();
          },
          onTick: (_) => ticks++,
          interval: const Duration(days: 1),
        );
        monitor.noteExternalScan(_scan('current'));
        monitor.start();

        await monitor.tick();

        expect(events, 1);
        expect(ticks, 0);
      },
    );
  });

  group('AppModel visualizer lifecycle', () {
    test('vizWatchdogTick is a no-op after dispose', () {
      final model = _vizModel();
      model.handleMessageForTesting(<String, dynamic>{
        'evt': 'viz',
        'spectrum': List<double>.filled(32, 0.5),
        'l': -10.0,
        'r': -10.0,
      });
      expect(model.levelL.value, -10.0);
      model.dispose();

      expect(
        () => model.vizWatchdogTick(
          DateTime.now().add(const Duration(seconds: 30)),
        ),
        returnsNormally,
      );
    });

    test('dispose releases all multichannel visualizer notifiers', () {
      final model = AppModel(testing: true);
      model.dispose();

      expect(() => model.vizChannelCount.value = 1, throwsAssertionError);
      expect(
        () => model.vizChannelLevels.value = <double>[],
        throwsAssertionError,
      );
      expect(
        () => model.vizStageChLevels.value = <double>[],
        throwsAssertionError,
      );
    });
  });
}
