import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/controllers/peak_physics_engine.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/features/visualizer/plugins/milkdrop_preset.dart';
import 'package:auradsp_app/features/visualizer/styles/style_atmosphere.dart';
import 'package:auradsp_app/features/visualizer/styles/style_fluid.dart';
import 'package:auradsp_app/features/visualizer/styles/style_milkdrop.dart';
import 'package:auradsp_app/features/visualizer/styles/style_tornado.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_painter_dispatcher.dart';
import 'package:auradsp_app/features/visualizer/views/visualizer_drawer.dart';
import 'package:auradsp_app/features/visualizer/views/visualizer_hud.dart';
import 'package:auradsp_app/features/visualizer/views/visualizer_hud_buttons.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';

void main() {
  group('VisualizerConfig & Models', () {
    test('Default configuration invariants', () {
      const cfg = VisualizerConfig();
      expect(cfg.style, VisualizerStyle.bars);
      expect(cfg.colorTheme, VisualizerColorTheme.system);
      expect(cfg.sensitivity, 1.0);
      expect(cfg.decayRate, 0.6);
      expect(cfg.gravity, 1.8);
      expect(cfg.barCount, 32);
      expect(cfg.lineWidth, 1.5);
      expect(cfg.bloom, 0.5);
      expect(cfg.showGrid, isTrue);
      expect(cfg.showPeaks, isTrue);
      expect(cfg.showDbScale, isTrue);
    });

    test('copyWith updates fields immutably', () {
      const cfg = VisualizerConfig();
      final updated = cfg.copyWith(
        style: VisualizerStyle.oscilloscope,
        colorTheme: VisualizerColorTheme.neonCyber,
        sensitivity: 2.5,
        showLyrics: true,
      );

      expect(updated.style, VisualizerStyle.oscilloscope);
      expect(updated.colorTheme, VisualizerColorTheme.neonCyber);
      expect(updated.sensitivity, 2.5);
      expect(updated.showLyrics, isTrue);
      expect(updated.decayRate, 0.6); // unchanged
    });

    test('Display mode tiers and expansion semantics', () {
      expect(VisualizerDisplayMode.restore.isExpanded, isFalse);
      expect(VisualizerDisplayMode.stage.isExpanded, isTrue);
      expect(VisualizerDisplayMode.immersive.isExpanded, isTrue);
      expect(
        VisualizerDisplayMode.values.map((m) => m.id).toSet(),
        {'restore', 'stage', 'immersive'},
      );
    });

    test('Palette resolution across themes', () {
      final p = auraDark;
      for (final theme in VisualizerColorTheme.values) {
        final palette = VisualizerPalette.resolve(theme, p);
        expect(palette.gradient.length, greaterThanOrEqualTo(2));
        expect(palette.primary.a, greaterThan(0));
        expect(palette.grid.a, greaterThan(0));
        expect(palette.glow.a, greaterThan(0));
      }
    });
  });

  group('PeakPhysicsEngine', () {
    test('Updates peak values and respects hold/gravity', () {
      final engine = PeakPhysicsEngine();
      final input = List.filled(32, 0.8);

      final p1 = engine.update(input, targetBands: 32);
      expect(p1.length, 32);
      expect(p1[0], closeTo(0.8, 0.01));

      // Silent input: peaks should hold initially
      final silence = List.filled(32, 0.0);
      var pSilence = p1;
      for (var i = 0; i < 5; i++) {
        pSilence = engine.update(silence, targetBands: 32);
      }
      // Still in hold phase
      expect(pSilence[0], closeTo(0.8, 0.01));

      // After many frames, gravity should pull it down
      for (var i = 0; i < 40; i++) {
        pSilence = engine.update(silence, targetBands: 32);
      }
      expect(pSilence[0], lessThan(0.8));

      // Reset restores to zero
      engine.reset();
      final afterReset = engine.update(silence, targetBands: 32);
      expect(afterReset[0], 0.0);
    });

    test('Resampling between 32 and 64 bands', () {
      final engine = PeakPhysicsEngine();
      final input32 = List.generate(32, (i) => i / 31.0);

      final p64 = engine.update(input32, targetBands: 64);
      expect(p64.length, 64);
      expect(p64.first, 0.0);
      expect(p64.last, 1.0);
    });
  });

  group('WaveformSynthesizer', () {
    test('Synthesizes stereo waveform and Lissajous points', () {
      final synth = WaveformSynthesizer();
      final spectrum = List.generate(32, (i) => 0.5);

      synth.update(
        spectrum,
        levelLDbfs: -6.0,
        levelRDbfs: -6.0,
        sensitivity: 1.0,
      );

      expect(synth.waveL.length, WaveformSynthesizer.pointCount);
      expect(synth.waveR.length, WaveformSynthesizer.pointCount);
      expect(synth.lissajousPoints.length, WaveformSynthesizer.pointCount);

      // Verify bounds
      for (final val in synth.waveL) {
        expect(val, inInclusiveRange(-1.0, 1.0));
      }
      for (final pt in synth.lissajousPoints) {
        expect(pt.dx, inInclusiveRange(-1.5, 1.5));
        expect(pt.dy, inInclusiveRange(-1.5, 1.5));
      }
    });

    test('Zero output on silence', () {
      final synth = WaveformSynthesizer();
      synth.update(
        [],
        levelLDbfs: -120.0,
        levelRDbfs: -120.0,
      );

      expect(synth.waveL.every((v) => v == 0.0), isTrue);
      expect(synth.waveR.every((v) => v == 0.0), isTrue);
    });

    test('High dynamic rock music simulation prevents explosion and clipping distortion', () {
      final synth = WaveformSynthesizer();
      // Simulate extreme sudden peak transient (+6 dBFS, high treble and bass)
      final loudSpectrum = List.generate(32, (i) => 1.5);
      synth.update(loudSpectrum, levelLDbfs: 6.0, levelRDbfs: 6.0, sensitivity: 2.0);

      expect(synth.waveL.length, WaveformSynthesizer.pointCount);
      for (final val in synth.waveL) {
        expect(val.isFinite, isTrue);
        expect(val, inInclusiveRange(-1.0, 1.0));
      }
      for (final pt in synth.lissajousPoints) {
        expect(pt.dx.isFinite, isTrue);
        expect(pt.dy.isFinite, isTrue);
      }
    });
  });

  group('Canvas style painters', () {
    test('New fluid / tornado styles and atmosphere layer paint without errors', () {
      final synth = WaveformSynthesizer();
      synth.update(
        List.generate(32, (i) => 0.4 + 0.6 * (i % 5) / 4),
        levelLDbfs: -8.0,
        levelRDbfs: -12.0,
      );
      final bands = List<double>.generate(32, (i) => (i % 7) / 7.0);
      final peaks = List<double>.filled(32, 0.5);
      final palette = VisualizerPalette.resolve(VisualizerColorTheme.neonCyber, auraDark);

      for (final style in [
        VisualizerStyle.bars,
        VisualizerStyle.oscilloscope,
        VisualizerStyle.goniometer,
        VisualizerStyle.cyberGrid,
        VisualizerStyle.pulseOrb,
        VisualizerStyle.fluidDynamics,
        VisualizerStyle.tornado,
      ]) {
        final recorder = ui.PictureRecorder();
        final canvas = Canvas(recorder);
        buildVisualizerPainter(
          style: style,
          config: VisualizerConfig(style: style),
          palette: palette,
          rawBands: bands,
          peaks: peaks,
          waveformSynth: synth,
          time: 12.5,
        ).paint(canvas, const Size(800, 480));
        AtmospherePainter(
          bands: bands,
          palette: palette,
          animationTime: 9.2,
        ).paint(canvas, const Size(800, 480));
        recorder.endRecording();
      }
    });
  });

  group('VisualizerConfigDrawer', () {
    for (final locale in const [Locale('zh'), Locale('en'), Locale('ja')]) {
      testWidgets('renders localized drawer with centered footer on ${locale.languageCode}', (tester) async {
        tester.view.physicalSize = const Size(380, 720);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          MaterialApp(
            theme: withAuraExtension(ThemeData.dark(), auraDark),
            locale: locale,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Align(
                alignment: Alignment.centerRight,
                child: VisualizerConfigDrawer(
                  config: const VisualizerConfig(),
                  onConfigChanged: (_) {},
                  onClose: () {},
                  onResetToDefaults: () {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // 底栏复位按钮水平居中于抽屉
        final drawerRect = tester.getRect(find.byType(VisualizerConfigDrawer));
        final resetRect = tester.getRect(find.byType(OutlinedButton));
        expect(resetRect.center.dx, closeTo(drawerRect.center.dx, 1.0));

        // 新风格与主题词条均已本地化
        final l = AppLocalizations.of(
          tester.element(find.byType(VisualizerConfigDrawer)),
        )!;
        expect(find.text(l.visualizerDrawerTitle), findsOneWidget);
        expect(find.text(l.visualizerStyleFluid), findsNothing); // 风格菜单不在抽屉内
        expect(find.text(l.visualizerThemeAuroraGlow), findsOneWidget);
      });
    }
  });

  group('风格运动性（2026-10-31 重做回归）', () {
    const size = Size(420, 260);

    Future<Uint8List> rasterize(CustomPainter painter) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paint(canvas, size);
      final image = await recorder
          .endRecording()
          .toImage(size.width.toInt(), size.height.toInt());
      final data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
      image.dispose();
      return data!.buffer.asUint8List();
    }

    int changedPixels(Uint8List a, Uint8List b) {
      var changed = 0;
      for (var i = 0; i < a.length; i += 4) {
        final dr = (a[i] - b[i]).abs();
        final dg = (a[i + 1] - b[i + 1]).abs();
        final db = (a[i + 2] - b[i + 2]).abs();
        if (dr + dg + db > 12) changed++;
      }
      return changed;
    }

    List<double> bands() => List<double>.generate(32, (i) => 0.45 + 0.3 * (i % 5) / 4);

    test('FluidDynamics：整屏持续流动（两张相隔帧的像素明显不同）', () async {
      final palette = VisualizerPalette.resolve(VisualizerColorTheme.neonCyber, auraDark);
      var t = 1.0;
      final frames = <Uint8List>[];
      for (var round = 0; round < 2; round++) {
        for (var i = 0; i < 12; i++) {
          t += 0.016;
          FluidDynamicsPainter(
            bands: bands(),
            palette: palette,
            bloom: 0.5,
            animationTime: t,
          ).paint(Canvas(ui.PictureRecorder()), size);
        }
        frames.add(await rasterize(FluidDynamicsPainter(
          bands: bands(),
          palette: palette,
          bloom: 0.5,
          animationTime: t,
        )));
      }
      final changed = changedPixels(frames[0], frames[1]);
      expect(changed, greaterThan(500),
          reason: '流体背景必须整屏在动（当前变化像素=$changed）');
    });

    test('ParticleTornado：随时间旋转且画面有实质变化', () async {
      final palette = VisualizerPalette.resolve(VisualizerColorTheme.aurora, auraDark);
      final a = await rasterize(ParticleTornadoPainter(
        bands: bands(),
        palette: palette,
        bloom: 0.5,
        animationTime: 1.0,
        lineWidth: 1.5,
      ));
      final b = await rasterize(ParticleTornadoPainter(
        bands: bands(),
        palette: palette,
        bloom: 0.5,
        animationTime: 3.0,
        lineWidth: 1.5,
      ));
      expect(changedPixels(a, b), greaterThan(300),
          reason: '龙卷风必须持续旋转/上升');
    });

    test('MilkDrop：拓扑缓慢连续旋转（相隔 2 秒仍有明显位移）', () async {
      final palette = VisualizerPalette.resolve(VisualizerColorTheme.neonCyber, auraDark);
      final preset = MilkdropPreset.builtInPresets.first;
      final a = await rasterize(MilkdropPainter(
        preset: preset,
        bands: bands(),
        palette: palette,
        time: 1.0,
        sensitivity: 1.0,
        lineWidth: 1.5,
      ));
      final b = await rasterize(MilkdropPainter(
        preset: preset,
        bands: bands(),
        palette: palette,
        time: 3.0,
        sensitivity: 1.0,
        lineWidth: 1.5,
      ));
      expect(changedPixels(a, b), greaterThan(120),
          reason: 'MilkDrop 必须缓慢持续旋转，而不是静止/跳变');
    });
  });

  group('VisualizerHud Widget Tests', () {
    testWidgets('Toggles style menu, selects mode, and auto-hides menu when HUD is invisible', (tester) async {
      VisualizerStyle currentStyle = VisualizerStyle.bars;
      VisualizerDisplayMode currentMode = VisualizerDisplayMode.restore;
      bool hudVisible = true;

      Widget buildHud() {
        return MaterialApp(
          theme: withAuraExtension(ThemeData.dark(), auraDark),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: StatefulBuilder(
              builder: (context, setState) {
                return Stack(
                  children: [
                    Positioned(
                      bottom: 20,
                      left: 0,
                      right: 0,
                      child: VisualizerHud(
                        config: VisualizerConfig(style: currentStyle),
                        displayMode: currentMode,
                        visible: hudVisible,
                        onStyleChanged: (newStyle) {
                          setState(() => currentStyle = newStyle);
                        },
                        onDisplayModeChanged: (newMode) {
                          setState(() => currentMode = newMode);
                        },
                        onToggleLyrics: () {},
                        onOpenDrawer: () {},
                        onResetPeaks: () {},
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        );
      }

      await tester.pumpWidget(buildHud());
      await tester.pumpAndSettle();

      // Initially, dropdown button is displayed with bars style
      expect(find.byType(VisualizerStyleDropdownButton), findsOneWidget);
      expect(find.byType(VisualizerMenuItem), findsNothing);

      // Tap the dropdown button to open menu
      await tester.tap(find.byType(VisualizerStyleDropdownButton));
      await tester.pumpAndSettle();

      // Menu items are now visible
      expect(find.byType(VisualizerMenuItem), findsNWidgets(VisualizerStyle.values.length));

      // Tap Oscilloscope item
      final oscilloscopeItem = find.widgetWithText(VisualizerMenuItem, VisualizerStyle.oscilloscope.label);
      expect(oscilloscopeItem, findsOneWidget);
      await tester.tap(oscilloscopeItem);
      await tester.pumpAndSettle();

      expect(currentStyle, VisualizerStyle.oscilloscope);
      // Menu automatically closes after selection
      expect(find.byType(VisualizerMenuItem), findsNothing);

      // 三档全屏分段控件（还原 / 软件全屏 / 仅视效沉浸）
      expect(find.byType(VisualizerDisplayModeSwitcher), findsOneWidget);
      await tester.tap(find.byIcon(VisualizerDisplayMode.immersive.icon));
      await tester.pumpAndSettle();
      expect(currentMode, VisualizerDisplayMode.immersive);
      await tester.tap(find.byIcon(VisualizerDisplayMode.restore.icon));
      await tester.pumpAndSettle();
      expect(currentMode, VisualizerDisplayMode.restore);

      // Open menu again
      await tester.tap(find.byType(VisualizerStyleDropdownButton));
      await tester.pumpAndSettle();
      expect(find.byType(VisualizerMenuItem), findsNWidgets(VisualizerStyle.values.length));

      // Make HUD invisible -> menu should automatically close
      hudVisible = false;
      await tester.pumpWidget(buildHud());
      await tester.pumpAndSettle();
      expect(find.byType(VisualizerMenuItem), findsNothing);
    });
  });
}
