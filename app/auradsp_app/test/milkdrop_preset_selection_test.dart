import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/nav.dart';
import 'package:auradsp_app/core/ports/null_ports.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/visualizer/lyrics/services/media_sync_service.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/plugins/milkdrop_preset.dart';
import 'package:auradsp_app/features/visualizer/plugins/projectm_bridge_contract.dart';
import 'package:auradsp_app/features/visualizer/plugins/projectm_native_bridge.dart';
import 'package:auradsp_app/features/visualizer/styles/style_milkdrop.dart';
import 'package:auradsp_app/features/visualizer/styles/style_projectm.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_painter_dispatcher.dart';
import 'package:auradsp_app/features/visualizer/views/visualizer_hud.dart';
import 'package:auradsp_app/features/visualizer/views/visualizer_hud_buttons.dart';
import 'package:auradsp_app/features/visualizer_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _a = 'C:/presets/A.milk';
const _b = 'C:/presets/B.milk';
const _c = 'C:/presets/C.milk';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'preset tap does not overwrite selection with stale style config',
    (tester) async {
      VisualizerStyle? styleWrite;
      MilkdropPreset? selected;
      await tester.pumpWidget(
        _app(
          VisualizerHud(
            config: const VisualizerConfig(),
            visible: true,
            onStyleChanged: (style) => styleWrite = style,
            onDisplayModeChanged: (_) {},
            onToggleLyrics: () {},
            onOpenDrawer: () {},
            onResetPeaks: () {},
            milkdropPresets: const [
              MilkdropPreset(name: 'A', filePath: _a),
              MilkdropPreset(name: 'B', filePath: _b),
            ],
            onSelectMilkdropPreset: (preset) => selected = preset,
          ),
        ),
      );
      await tester.tap(find.byType(VisualizerStyleDropdownButton));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(CategoryTabButton, 'MilkDrop 预设'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MilkdropPresetMenuItem).last);
      await tester.pumpAndSettle();

      expect(selected?.filePath, _b);
      expect(styleWrite, isNull);
    },
  );

  test('factory preserves an explicitly injected Mock', () {
    final injected = MockProjectMBridge(statusDescription: 'injected fake');
    ProjectMBridgeFactory.instance = injected;
    addTearDown(() => ProjectMBridgeFactory.instance = MockProjectMBridge());

    expect(ProjectMBridgeFactory.instance, same(injected));
    expect(ProjectMBridgeFactory.instance, same(injected));
  });

  test('factory re-probes instead of permanently caching a failed Mock', () {
    final failed = MockProjectMBridge(
      statusDescription: 'first probe failed',
      reprobeOnAccess: true,
    );
    ProjectMBridgeFactory.instance = failed;
    addTearDown(() => ProjectMBridgeFactory.instance = MockProjectMBridge());

    final reprobed = ProjectMBridgeFactory.instance;

    expect(identical(reprobed, failed), isFalse);
    if (reprobed is MockProjectMBridge) {
      expect(identical(ProjectMBridgeFactory.instance, reprobed), isFalse);
    }
  });

  group('preset attempt lifecycle', () {
    testWidgets(
      'clear cancels the active timeout and ignores late completion',
      (tester) async {
        final bridge = _FakeProjectMBridge(autoComplete: false);
        final controller = ProjectMPresetSelectionController(bridge);
        addTearDown(controller.dispose);
        addTearDown(bridge.dispose);
        controller.select(const MilkdropPreset(name: 'B', filePath: _b));

        controller.clear();
        bridge.complete(_b);
        await tester.pump();

        expect(controller.selection.value.status, PresetSelectionStatus.idle);
        expect(controller.selection.value.requestedPath, isNull);
        expect(controller.confirmedPath, isNull);
        await tester.pump(const Duration(seconds: 10));
        expect(bridge.attemptsFor(_b), 1);
      },
    );

    testWidgets(
      'reset cancels the active timeout and invalidates confirmation',
      (tester) async {
        final bridge = _FakeProjectMBridge(autoComplete: false);
        bridge.autoCompletePaths.add(_a);
        final controller = ProjectMPresetSelectionController(bridge);
        addTearDown(controller.dispose);
        addTearDown(bridge.dispose);
        controller.select(const MilkdropPreset(name: 'A', filePath: _a));
        await tester.pump();
        expect(controller.confirmedPath, _a);

        controller.select(const MilkdropPreset(name: 'B', filePath: _b));
        controller.reset();
        bridge.complete(_b);
        await tester.pump();

        expect(controller.selection.value.status, PresetSelectionStatus.idle);
        expect(controller.selection.value.currentPath, isNull);
        expect(controller.confirmedPath, isNull);
        await tester.pump(const Duration(seconds: 10));
        expect(bridge.attemptsFor(_b), 1);
      },
    );

    testWidgets('a new generation immediately supersedes the Dart attempt', (
      tester,
    ) async {
      final bridge = _FakeProjectMBridge(autoComplete: false);
      final controller = ProjectMPresetSelectionController(bridge);
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);
      controller.select(const MilkdropPreset(name: 'B', filePath: _b));
      controller.select(const MilkdropPreset(name: 'C', filePath: _c));

      expect(bridge.requestedPaths, [_b, _c]);
      bridge.complete(_c);
      await tester.pump();
      expect(controller.confirmedPath, _c);

      bridge.complete(_b);
      await tester.pump();
      expect(controller.confirmedPath, _c);
      expect(bridge.currentPreset?.filePath, _c);
    });

    testWidgets('a mismatched result generation cannot confirm or time out', (
      tester,
    ) async {
      for (final status in [
        PresetSelectionStatus.ready,
        PresetSelectionStatus.timedOut,
      ]) {
        final bridge = _FakeProjectMBridge(autoComplete: false);
        final controller = ProjectMPresetSelectionController(bridge);
        addTearDown(controller.dispose);
        addTearDown(bridge.dispose);
        controller.select(const MilkdropPreset(name: 'B', filePath: _b));

        bridge.complete(_b, generation: 999, status: status);
        await tester.pump();

        expect(controller.selection.value.status, PresetSelectionStatus.failed);
        expect(controller.confirmedPath, isNull);
        controller.clear();
      }
    });

    testWidgets('a mismatched requested path cannot confirm a load', (
      tester,
    ) async {
      final bridge = _FakeProjectMBridge(autoComplete: false);
      final controller = ProjectMPresetSelectionController(bridge);
      addTearDown(controller.dispose);
      addTearDown(bridge.dispose);
      controller.select(const MilkdropPreset(name: 'B', filePath: _b));

      bridge.complete(_b, requestedPath: _c);
      await tester.pump();

      expect(controller.selection.value.status, PresetSelectionStatus.failed);
      expect(controller.confirmedPath, isNull);
      controller.clear();
    });
  });

  group('preset selection transaction', () {
    test('pending selection keeps the last confirmed native frame', () {
      final bridge = _FakeProjectMBridge();
      addTearDown(bridge.dispose);
      bridge.loadPreset(const MilkdropPreset(name: 'A', filePath: _a));
      final palette = VisualizerPalette.resolve(
        VisualizerColorTheme.neonCyber,
        auraDark,
      );

      final painter = buildVisualizerPainter(
        style: VisualizerStyle.projectM,
        config: const VisualizerConfig(
          style: VisualizerStyle.projectM,
          milkdropPresetPath: _b,
        ),
        palette: palette,
        rawBands: List.filled(32, 0.5),
        peaks: List.filled(32, 0.5),
        waveformSynth: WaveformSynthesizer(),
        time: 0,
        projectMBridge: bridge,
      );

      expect(painter, isA<ProjectMPainter>());
      final nativePainter = painter as ProjectMPainter;
      expect(nativePainter.bridge.currentPreset?.filePath, _a);
      expect(nativePainter.fallbackPainter.preset.filePath, _a);
    });

    test('native fallback does not synchronously parse preset metadata', () {
      final dir = Directory.systemTemp.createTempSync('pm_painter_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final presetFile = File('${dir.path}${Platform.pathSeparator}B.milk')
        ..writeAsStringSync('fDecay=0.5\nper_frame_1=zoom=1.0;\n');
      final bridge = _FakeProjectMBridge();
      addTearDown(bridge.dispose);
      final palette = VisualizerPalette.resolve(
        VisualizerColorTheme.neonCyber,
        auraDark,
      );

      final painter = buildVisualizerPainter(
        style: VisualizerStyle.projectM,
        config: VisualizerConfig(
          style: VisualizerStyle.projectM,
          milkdropPresetPath: presetFile.path,
        ),
        palette: palette,
        rawBands: List.filled(32, 0.5),
        peaks: List.filled(32, 0.5),
        waveformSynth: WaveformSynthesizer(),
        time: 0,
        projectMBridge: bridge,
      );

      expect(painter, isA<MilkdropPainter>());
      expect((painter as MilkdropPainter).preset.hasCustomEquations, isFalse);
    });

    test('clearing the path returns to the procedural built-in fallback', () {
      final bridge = _FakeProjectMBridge();
      addTearDown(bridge.dispose);
      bridge.loadPreset(const MilkdropPreset(name: 'A', filePath: _a));
      final palette = VisualizerPalette.resolve(
        VisualizerColorTheme.neonCyber,
        auraDark,
      );

      final painter = buildVisualizerPainter(
        style: VisualizerStyle.projectM,
        config: const VisualizerConfig(style: VisualizerStyle.projectM),
        palette: palette,
        rawBands: List.filled(32, 0.5),
        peaks: List.filled(32, 0.5),
        waveformSynth: WaveformSynthesizer(),
        time: 0,
        projectMBridge: bridge,
      );

      expect(painter, isA<MilkdropPainter>());
      expect(
        (painter as MilkdropPainter).preset.filePath,
        MilkdropPreset.builtInPresets.first.filePath,
      );
    });

    testWidgets('selection does not synchronously parse the preset on the UI', (
      tester,
    ) async {
      final dir = Directory.systemTemp.createTempSync('pm_selection_');
      addTearDown(() => dir.deleteSync(recursive: true));
      final presetFile = File('${dir.path}${Platform.pathSeparator}B.milk')
        ..writeAsStringSync('fDecay=0.5\nper_frame_1=zoom=1.0;\n');
      final fixture = await _pumpPage(tester);
      fixture.model.visualizerConfig.value = VisualizerConfig(
        style: VisualizerStyle.projectM,
        milkdropPresetPath: presetFile.path,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 33));

      // The native parser owns file parsing. The Dart request carries only the
      // path reference, not metadata synchronously read from the file.
      expect(fixture.bridge.attemptsFor(presetFile.path), 1);
      expect(fixture.bridge.attempts.last.preset.hasCustomEquations, isFalse);
      presetFile.deleteSync();
      fixture.bridge.complete(presetFile.path);
      await tester.pump();
      expect(fixture.bridge.currentPreset?.filePath, presetFile.path);
    });

    testWidgets('A to B to C confirms each requested preset', (tester) async {
      final fixture = await _pumpPage(tester);
      await fixture.select(_b);
      expect(fixture.model.visualizerConfig.value.milkdropPresetPath, _b);
      expect(fixture.bridge.currentPreset?.filePath, _b);
      await fixture.select(_c);
      expect(fixture.model.visualizerConfig.value.milkdropPresetPath, _c);
      expect(fixture.bridge.currentPreset?.filePath, _c);
    });

    testWidgets('corrupt B preserves A and does not retry every frame', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester);
      fixture.bridge.rejectPaths.add(_b);
      await fixture.select(_b);

      expect(fixture.model.visualizerConfig.value.milkdropPresetPath, _b);
      expect(fixture.bridge.currentPreset?.filePath, _a);
      expect(fixture.bridge.attemptsFor(_b), 1);
      expect(_nativePainter(tester), isNotNull);
      expect(
        find.textContaining('fake native preset parse failure'),
        findsOneWidget,
      );
      for (var i = 0; i < 8; i++) {
        await tester.pump(const Duration(milliseconds: 33));
      }
      expect(fixture.bridge.attemptsFor(_b), 1);
    });

    testWidgets('returning to confirmed A supersedes pending B immediately', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester, autoComplete: false);
      await fixture.select(_b, settle: false);
      expect(fixture.bridge.currentPreset?.filePath, _a);

      await fixture.select(_a, settle: false);

      expect(fixture.bridge.requestedPaths, [_a, _b, _a]);
      fixture.bridge.complete(_b);
      await tester.pump();
      expect(fixture.model.visualizerConfig.value.milkdropPresetPath, _a);
      expect(fixture.bridge.currentPreset?.filePath, _a);
      expect(_nativePainter(tester), isNotNull);
      await tester.pump(const Duration(milliseconds: 33));
      expect(fixture.bridge.attemptsFor(_a), 2);
    });

    testWidgets('returning to confirmed A cancels failed B retry cooldown', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester);
      fixture.bridge.rejectPaths.add(_b);
      await fixture.select(_b);
      expect(fixture.bridge.currentPreset?.filePath, _a);
      expect(fixture.bridge.attemptsFor(_b), 1);

      await fixture.select(_a, settle: false);
      expect(fixture.bridge.requestedPaths, [_a, _b, _a]);
      await tester.pump(const Duration(seconds: 10));

      expect(fixture.bridge.attemptsFor(_b), 1);
      expect(fixture.bridge.currentPreset?.filePath, _a);
    });

    testWidgets('rapid B then C immediately supersedes B natively', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester, autoComplete: false);
      await fixture.select(_b, settle: false);
      await fixture.select(_c, settle: false);

      expect(fixture.bridge.requestedPaths, [_a, _b, _c]);
      expect(fixture.bridge.currentPreset?.filePath, _a);
      fixture.bridge.complete(_c);
      await tester.pump();
      expect(fixture.model.visualizerConfig.value.milkdropPresetPath, _c);
      expect(fixture.bridge.currentPreset?.filePath, _c);

      fixture.bridge.complete(_b);
      await tester.pump();
      expect(fixture.bridge.currentPreset?.filePath, _c);
    });

    testWidgets('stale B completion cannot replace current C', (tester) async {
      final fixture = await _pumpPage(tester, autoComplete: false);
      await fixture.select(_b, settle: false);
      await fixture.select(_c, settle: false);
      expect(fixture.bridge.requestedPaths, [_a, _b, _c]);

      fixture.bridge.complete(_c);
      fixture.bridge.complete(_b);
      await tester.pump();

      expect(fixture.model.visualizerConfig.value.milkdropPresetPath, _c);
      expect(fixture.bridge.currentPreset?.filePath, _c);
    });

    testWidgets('unconfirmed load times out then retries after cooldown', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester, autoComplete: false);
      await fixture.select(_b, settle: false);
      expect(fixture.bridge.attemptsFor(_b), 1);

      await tester.pump(const Duration(seconds: 5));
      expect(fixture.bridge.attemptsFor(_b), 1);
      await tester.pump(const Duration(seconds: 5));

      expect(fixture.bridge.currentPreset?.filePath, _a);
      expect(fixture.bridge.attemptsFor(_b), greaterThan(1));
    });

    testWidgets(
      'clearing the path cancels pending selection and permits retry',
      (tester) async {
        final fixture = await _pumpPage(tester, autoComplete: false);
        await fixture.select(_b, settle: false);
        expect(fixture.bridge.attemptsFor(_b), 1);

        fixture.model.visualizerConfig.value = const VisualizerConfig(
          style: VisualizerStyle.projectM,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 33));
        fixture.bridge.complete(_b);
        await tester.pump();

        fixture.model.visualizerConfig.value = const VisualizerConfig(
          style: VisualizerStyle.projectM,
          milkdropPresetPath: _b,
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 33));
        expect(fixture.bridge.attemptsFor(_b), 2);
        fixture.bridge.complete(_b);
        await tester.pump();
        expect(fixture.bridge.currentPreset?.filePath, _b);
      },
    );

    testWidgets('offscreen selection stops retries and resumes on return', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester, autoComplete: false);
      await fixture.select(_b, settle: false);

      fixture.model.visiblePage.value = AppPage.home;
      await tester.pump();
      await tester.pump(const Duration(seconds: 10));
      expect(fixture.bridge.attemptsFor(_b), 1);

      fixture.model.visiblePage.value = AppPage.visualizer;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 33));
      expect(fixture.bridge.attemptsFor(_b), 2);
      fixture.bridge.complete(_b);
      await tester.pump();
      expect(fixture.bridge.currentPreset?.filePath, _b);
    });

    testWidgets('offscreen disposal invalidates the confirmed path', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester, autoComplete: false);
      await fixture.select(_b, settle: false);

      fixture.model.visiblePage.value = AppPage.home;
      await tester.pump();
      fixture.bridge.complete(_b);
      fixture.model.visualizerConfig.value = const VisualizerConfig(
        style: VisualizerStyle.projectM,
        milkdropPresetPath: _a,
      );
      fixture.model.visiblePage.value = AppPage.visualizer;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 33));

      expect(fixture.bridge.requestedPaths, [_a, _b, _a]);
      expect(fixture.bridge.currentPreset?.filePath, _a);
    });

    testWidgets('style disposal invalidates the confirmed path', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester, autoComplete: false);
      await fixture.select(_b, settle: false);

      fixture.model.visualizerConfig.value = const VisualizerConfig(
        style: VisualizerStyle.bars,
        milkdropPresetPath: _a,
      );
      await tester.pump();
      fixture.bridge.complete(_b);
      fixture.model.visualizerConfig.value = const VisualizerConfig(
        style: VisualizerStyle.projectM,
        milkdropPresetPath: _a,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 33));

      expect(fixture.bridge.requestedPaths, [_a, _b, _a]);
      expect(fixture.bridge.currentPreset?.filePath, _a);
    });

    testWidgets('initialization finishing offscreen does not start a load', (
      tester,
    ) async {
      final initialization = Completer<bool>();
      final bridge = _FakeProjectMBridge(
        autoComplete: false,
        initiallyAvailable: false,
        initializeCompleter: initialization,
      )..autoCompletePaths.add(_a);
      final fixture = await _pumpPage(tester, bridge: bridge);
      expect(bridge.initializeCalls, 1);

      fixture.model.visiblePage.value = AppPage.home;
      await tester.pump();
      initialization.complete(true);
      await tester.pump();
      expect(bridge.attemptsFor(_a), 0);

      fixture.model.visiblePage.value = AppPage.visualizer;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 33));
      expect(bridge.attemptsFor(_a), 1);
    });

    testWidgets(
      'confirmation replaces a pending fallback without spectrum data',
      (tester) async {
        final fixture = await _pumpPage(
          tester,
          autoComplete: false,
          initialPath: null,
        );
        expect(_nativePainter(tester), isNull);

        await fixture.select(_b, settle: false);
        expect(_nativePainter(tester), isNull);
        fixture.bridge.complete(_b);
        await tester.pump();
        await tester.pump();

        expect(_nativePainter(tester), isNotNull);
        expect(fixture.bridge.currentPreset?.filePath, _b);
      },
    );

    testWidgets('restart reloads persisted path and restores native current', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester);
      await fixture.select(_b);
      expect(fixture.model.visualizerConfig.value.milkdropPresetPath, _b);
      expect(fixture.bridge.currentPreset?.filePath, _b);

      await tester.pumpWidget(const SizedBox.shrink());
      final restarted = _FakeProjectMBridge();
      addTearDown(restarted.dispose);
      final restartedMediaSync = MediaSyncService(
        provider: MockMediaSessionProvider(),
        hasSystemMediaSession: false,
      );
      ProjectMBridgeFactory.instance = restarted;
      await tester.pumpWidget(
        _app(
          VisualizerPage(model: fixture.model, mediaSync: restartedMediaSync),
        ),
      );
      await tester.pump(const Duration(milliseconds: 33));
      await tester.pump();

      expect(fixture.model.visualizerConfig.value.milkdropPresetPath, _b);
      expect(restarted.currentPreset?.filePath, _b);
    });

    testWidgets('failed preset becomes eligible again only after cooldown', (
      tester,
    ) async {
      final fixture = await _pumpPage(tester);
      fixture.bridge.rejectPaths.add(_b);
      await fixture.select(_b);
      expect(fixture.bridge.attemptsFor(_b), 1);

      await tester.pump(const Duration(seconds: 5));

      expect(fixture.bridge.attemptsFor(_b), 2);
    });
  });
}

ProjectMPainter? _nativePainter(WidgetTester tester) {
  for (final widget in tester.widgetList<CustomPaint>(
    find.byType(CustomPaint),
  )) {
    final painter = widget.painter;
    if (painter is ProjectMPainter) return painter;
    if (painter == null) continue;
    try {
      final mainPainter = (painter as dynamic).mainPainter;
      if (mainPainter is ProjectMPainter) return mainPainter;
    } on NoSuchMethodError {
      // Static-layer painters do not wrap a main painter.
    }
  }
  return null;
}

MaterialApp _app(Widget child) => MaterialApp(
  theme: withAuraExtension(ThemeData.dark(), auraDark),
  locale: const Locale('zh'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Future<_Fixture> _pumpPage(
  WidgetTester tester, {
  bool autoComplete = true,
  String? initialPath = _a,
  _FakeProjectMBridge? bridge,
}) async {
  final model = _TestAppModel(window: NullWindowPort())
    ..playing = true
    ..visiblePage.value = AppPage.visualizer
    ..visualizerConfig.value = VisualizerConfig(
      style: VisualizerStyle.projectM,
      milkdropPresetPath: initialPath,
    );
  final fixtureBridge =
      bridge ?? _FakeProjectMBridge(autoComplete: autoComplete);
  if (!autoComplete) {
    fixtureBridge.autoCompletePaths.add(_a);
  }
  final mediaSync = MediaSyncService(
    provider: MockMediaSessionProvider(),
    hasSystemMediaSession: false,
  );
  ProjectMBridgeFactory.instance = fixtureBridge;
  addTearDown(model.dispose);
  addTearDown(() {
    ProjectMBridgeFactory.instance = MockProjectMBridge();
    fixtureBridge.dispose();
  });
  tester.view.physicalSize = const Size(1280, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    _app(VisualizerPage(model: model, mediaSync: mediaSync)),
  );
  await tester.pump(const Duration(milliseconds: 33));
  await tester.pump();
  return _Fixture(tester, model, fixtureBridge, mediaSync);
}

final class _Fixture {
  final WidgetTester tester;
  final _TestAppModel model;
  final _FakeProjectMBridge bridge;
  final MediaSyncService mediaSync;

  const _Fixture(this.tester, this.model, this.bridge, this.mediaSync);

  Future<void> select(String path, {bool settle = true}) async {
    final config = model.visualizerConfig.value;
    model.visualizerConfig.value = config.copyWith(milkdropPresetPath: path);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 33));
    if (settle) await tester.pump();
  }
}

final class _TestAppModel extends AppModel {
  _TestAppModel({required super.window}) : super(testing: true);
}

final class _Attempt {
  final MilkdropPreset preset;
  int generation = 0;
  Completer<PresetSelection>? completer;

  _Attempt(this.preset);
}

final class _FakeProjectMBridge
    implements ProjectMBridge, ProjectMAsyncPresetBridge {
  _FakeProjectMBridge({
    bool autoComplete = true,
    this.initiallyAvailable = true,
    this.initializeCompleter,
  }) : _available = initiallyAvailable {
    if (autoComplete) autoCompletePaths.addAll([_a, _b, _c]);
  }

  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);
  final Set<String> autoCompletePaths = {};
  final Set<String> rejectPaths = {};
  final List<_Attempt> attempts = [];
  final bool initiallyAvailable;
  final Completer<bool>? initializeCompleter;
  MilkdropPreset? _preset;
  _Attempt? _latestAttempt;
  bool _available;
  bool _disposed = false;
  int initializeCalls = 0;

  List<String> get requestedPaths => [
    for (final a in attempts) a.preset.filePath,
  ];
  int attemptsFor(String path) => requestedPaths.where((p) => p == path).length;
  bool hasPending(String path) =>
      attempts.any((a) => a.preset.filePath == path && a.completer != null);

  @override
  bool get isNative => true;
  @override
  bool get isAvailable => _available && !_disposed;
  @override
  bool get isLoaded => _preset != null && isAvailable;
  @override
  String get statusDescription => 'fake projectM bridge';
  @override
  MilkdropPreset? get currentPreset => _preset;
  @override
  ui.Image? get currentFrame => _frame.value;
  @override
  ValueListenable<ui.Image?> get frameListenable => _frame;

  @override
  Future<bool> initialize({
    int width = 1280,
    int height = 720,
    double fps = 60.0,
  }) {
    initializeCalls++;
    final completer = initializeCompleter;
    if (completer == null) {
      _available = !_disposed;
      return Future<bool>.value(_available);
    }
    return completer.future.then((ok) {
      _available = ok && !_disposed;
      return _available;
    });
  }

  @override
  void resize(int width, int height) {}

  @override
  bool loadPreset(MilkdropPreset preset) {
    if (!isAvailable) return false;
    attempts.add(_Attempt(preset));
    if (rejectPaths.contains(preset.filePath)) return false;
    if (autoCompletePaths.contains(preset.filePath)) _preset = preset;
    return true;
  }

  @override
  Future<PresetSelection> requestPresetLoad(
    MilkdropPreset preset, {
    required int generation,
  }) {
    final attempt = _Attempt(preset)..generation = generation;
    attempts.add(attempt);
    _latestAttempt = attempt;
    if (!isAvailable || rejectPaths.contains(preset.filePath)) {
      return Future<PresetSelection>.value(
        PresetSelection(
          requestedPath: preset.filePath,
          generation: generation,
          status: PresetSelectionStatus.failed,
          currentPath: _preset?.filePath,
          error: 'fake native preset parse failure',
        ),
      );
    }
    if (autoCompletePaths.contains(preset.filePath)) {
      _preset = preset;
      return Future<PresetSelection>.value(
        PresetSelection(
          requestedPath: preset.filePath,
          generation: generation,
          status: PresetSelectionStatus.ready,
          currentPath: preset.filePath,
        ),
      );
    }
    attempt.completer = Completer<PresetSelection>();
    return attempt.completer!.future;
  }

  void complete(
    String path, {
    int? generation,
    String? requestedPath,
    PresetSelectionStatus status = PresetSelectionStatus.ready,
  }) {
    final attempt = attempts.lastWhere(
      (a) => a.preset.filePath == path && a.completer != null,
    );
    final completer = attempt.completer;
    attempt.completer = null;
    final isLatest = identical(_latestAttempt, attempt);
    if (isLatest && status == PresetSelectionStatus.ready) {
      _preset = attempt.preset;
    }
    completer?.complete(
      PresetSelection(
        requestedPath: requestedPath ?? path,
        generation: generation ?? attempt.generation,
        status: isLatest ? status : PresetSelectionStatus.failed,
        currentPath: _preset?.filePath,
        error: isLatest ? null : 'fake native request was superseded',
      ),
    );
  }

  @override
  void feedPcm(List<double> pcmFrames, {int channels = 2}) {}
  @override
  int renderFrame() => isAvailable ? 0 : -2;
  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _available = false;
    _preset = null;
    _frame.dispose();
  }
}
