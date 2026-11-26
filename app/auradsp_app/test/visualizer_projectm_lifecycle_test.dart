import 'dart:ui' as ui;

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/nav.dart';
import 'package:auradsp_app/core/ports/null_ports.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/visualizer/lyrics/services/media_sync_service.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/plugins/milkdrop_preset.dart';
import 'package:auradsp_app/features/visualizer/plugins/projectm_bridge_contract.dart';
import 'package:auradsp_app/features/visualizer/plugins/projectm_native_bridge.dart';
import 'package:auradsp_app/features/visualizer_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<_Fixture> pumpPage(WidgetTester tester) async {
    final window = NullWindowPort();
    final model = _TestAppModel(window: window)
      ..playing = true
      ..visiblePage.value = AppPage.visualizer
      ..visualizerConfig.value = const VisualizerConfig(
        style: VisualizerStyle.projectM,
      );
    final bridge = _FakeProjectMBridge();
    final mediaSync = MediaSyncService(
      provider: MockMediaSessionProvider(),
      hasSystemMediaSession: false,
    );
    ProjectMBridgeFactory.instance = bridge;
    addTearDown(model.dispose);
    addTearDown(() {
      ProjectMBridgeFactory.instance = MockProjectMBridge();
      bridge.dispose();
    });

    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        theme: withAuraExtension(ThemeData.dark(), auraDark),
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: VisualizerPage(model: model, mediaSync: mediaSync),
        ),
      ),
    );
    await tester.pump();
    return _Fixture(model: model, window: window, bridge: bridge);
  }

  testWidgets(
    'projectM stops while the visualizer page is offscreen and resumes on return',
    (tester) async {
      final fixture = await pumpPage(tester);
      await tester.pump(const Duration(milliseconds: 33));
      expect(fixture.bridge.renderCount, greaterThan(0));

      fixture.model.visiblePage.value = AppPage.home;
      await tester.pump();
      final stoppedAt = fixture.bridge.renderCount;
      await tester.pump(const Duration(milliseconds: 330));
      expect(fixture.bridge.renderCount, stoppedAt);

      fixture.model.visiblePage.value = AppPage.visualizer;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 33));
      expect(fixture.bridge.renderCount, greaterThan(stoppedAt));

      await tester.pumpWidget(const SizedBox.shrink());
      final disposedAt = fixture.bridge.renderCount;
      await tester.pump(const Duration(milliseconds: 330));
      expect(fixture.bridge.renderCount, disposedAt);
    },
  );

  testWidgets('projectM follows window visibility and playback pause policy', (
    tester,
  ) async {
    final fixture = await pumpPage(tester);
    await tester.pump(const Duration(milliseconds: 33));
    expect(fixture.bridge.renderCount, greaterThan(0));

    fixture.window.setVisible(false);
    await tester.pump();
    final hiddenAt = fixture.bridge.renderCount;
    await tester.pump(const Duration(milliseconds: 330));
    expect(fixture.bridge.renderCount, hiddenAt);

    fixture.window.setVisible(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 33));
    expect(fixture.bridge.renderCount, greaterThan(hiddenAt));

    fixture.model.setPlaying(false);
    await tester.pump();
    final pausedAt = fixture.bridge.renderCount;
    await tester.pump(const Duration(milliseconds: 330));
    expect(fixture.bridge.renderCount, pausedAt);

    fixture.model.setPlaying(true);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 33));
    expect(fixture.bridge.renderCount, greaterThan(pausedAt));

    await tester.pumpWidget(const SizedBox.shrink());
  });
}

final class _Fixture {
  final _TestAppModel model;
  final NullWindowPort window;
  final _FakeProjectMBridge bridge;

  const _Fixture({
    required this.model,
    required this.window,
    required this.bridge,
  });
}

final class _TestAppModel extends AppModel {
  _TestAppModel({required super.window}) : super(testing: true);

  void setPlaying(bool value) {
    if (playing == value) return;
    playing = value;
    notifyListeners();
  }
}

final class _FakeProjectMBridge implements ProjectMBridge {
  final ValueNotifier<ui.Image?> _frame = ValueNotifier<ui.Image?>(null);
  MilkdropPreset? _preset;
  bool _disposed = false;
  int renderCount = 0;

  @override
  bool get isNative => true;

  @override
  bool get isAvailable => !_disposed;

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
  }) async => isAvailable;

  @override
  void resize(int width, int height) {}

  @override
  bool loadPreset(MilkdropPreset preset) {
    if (!isAvailable) return false;
    _preset = preset;
    return true;
  }

  @override
  void feedPcm(List<double> pcmFrames, {int channels = 2}) {}

  @override
  int renderFrame() {
    if (!isAvailable) return -2;
    renderCount++;
    return 0;
  }

  @override
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _preset = null;
    _frame.dispose();
  }
}
