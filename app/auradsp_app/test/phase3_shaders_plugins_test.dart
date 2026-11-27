import 'dart:io';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/plugins/milkdrop_preset.dart';
import 'package:auradsp_app/features/visualizer/plugins/projectm_bridge_contract.dart';
import 'package:auradsp_app/features/visualizer/plugins/projectm_native_bridge.dart';
import 'package:auradsp_app/features/visualizer/shaders/gpu_shader_service.dart';
import 'package:auradsp_app/features/visualizer/styles/style_gpu_shader.dart';
import 'package:auradsp_app/features/visualizer/styles/style_milkdrop.dart';
import 'package:auradsp_app/features/visualizer/styles/style_projectm.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_painter_dispatcher.dart';
import 'package:auradsp_app/features/visualizer/views/visualizer_hud.dart';
import 'package:auradsp_app/features/visualizer/views/visualizer_hud_buttons.dart';

void main() {
  const testPalette = VisualizerPalette(
    primary: Color(0xFF00E5FF),
    secondary: Color(0xFFFF007F),
    peak: Color(0xFFFFFFFF),
    grid: Color(0x1A00E5FF),
    glow: Color(0x8000E5FF),
    gradient: [Color(0xFF0055FF), Color(0xFF00E5FF)],
  );

  group('Phase 3 GPU Shaders Tests', () {
    test('GpuShaderType asset paths invariant', () {
      expect(GpuShaderType.aurora.assetPath, 'shaders/aurora_wave.frag');
      expect(GpuShaderType.tunnel.assetPath, 'shaders/neon_tunnel.frag');
      expect(GpuShaderType.tornado.assetPath, 'shaders/particle_tornado.frag');
      expect(GpuShaderType.nebula.assetPath, 'shaders/nebula_flow.frag');
      expect(
        GpuShaderType.harmonicWarp.assetPath,
        'shaders/harmonic_warp.frag',
      );
    });

    test('VisualizerStyle includes GPU shader modes and Harmonic Warp', () {
      expect(
        VisualizerStyle.values.contains(VisualizerStyle.auroraShader),
        isTrue,
      );
      expect(
        VisualizerStyle.values.contains(VisualizerStyle.tunnelShader),
        isTrue,
      );
      expect(
        VisualizerStyle.values.contains(VisualizerStyle.harmonicWarp),
        isTrue,
      );
      expect(VisualizerStyle.auroraShader.label, 'Aurora Ribbon');
      expect(VisualizerStyle.tunnelShader.label, 'Neon Tunnel');
      expect(VisualizerStyle.harmonicWarp.label, 'Harmonic Warp');
    });

    test('GpuShaderPainter draws fallback when shader is uncompiled', () {
      final painter = GpuShaderPainter(
        shaderType: GpuShaderType.aurora,
        bands: List.filled(32, 0.5),
        palette: testPalette,
        time: 1.0,
        sensitivity: 1.0,
      );

      final recorder = PictureRecorder();
      final canvas = Canvas(recorder);
      painter.paint(canvas, const Size(800, 600));
      final picture = recorder.endRecording();
      expect(picture, isNotNull);
    });
  });

  group('MilkDrop .milk Preset Parser & Scanner Tests', () {
    const sampleMilkContent = '''
[preset00]
author=Ryan Geiss
decay=0.965
zoom=1.045
wave_mode=2
per_frame_1=wave_r = 0.5 + 0.5*sin(time*1.2);
per_pixel_1=rot = rot + 0.02*sin(rad*3.14);
''';

    test('Parses key-value properties and equation detection', () {
      final preset = MilkdropPreset.parseString(
        'Geiss - Cosmic Warp',
        'C:/presets/cosmic.milk',
        sampleMilkContent,
      );

      expect(preset.name, 'Geiss - Cosmic Warp');
      expect(preset.author, 'Ryan Geiss');
      expect(preset.decay, closeTo(0.965, 0.001));
      expect(preset.zoom, closeTo(1.045, 0.001));
      expect(preset.waveMode, 2);
      expect(preset.hasCustomEquations, isTrue);
    });

    test('Handles empty or corrupt content gracefully', () {
      final preset = MilkdropPreset.parseString('Empty', '', '');
      expect(preset.author, 'Unknown');
      expect(preset.decay, 0.98);
      expect(preset.hasCustomEquations, isFalse);
    });

    test('Has built-in presets provided out-of-the-box', () {
      expect(MilkdropPreset.builtInPresets.length, greaterThanOrEqualTo(3));
      expect(MilkdropPreset.builtInPresets.first.name, isNotEmpty);
    });

    test('MilkdropPresetScanner discovers .milk files in directory', () {
      final tempDir = Directory.systemTemp.createTempSync('milkdrop_test_');
      try {
        final f1 = File('${tempDir.path}/alpha.milk');
        final f2 = File('${tempDir.path}/beta.milk');
        final f3 = File('${tempDir.path}/notes.txt');

        f1.writeAsStringSync('decay=0.95\nzoom=1.0\nwave_mode=0');
        f2.writeAsStringSync('decay=0.99\nzoom=1.1\nwave_mode=1');
        f3.writeAsStringSync('Ignore this');

        final discovered = MilkdropPresetScanner.scanDirectory(tempDir.path);
        expect(discovered.length, 2);
        final names = discovered.map((e) => e.name).toList();
        expect(names.contains('alpha'), isTrue);
        expect(names.contains('beta'), isTrue);
      } finally {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('MilkdropPainter renders procedural waveModes safely', () {
      for (var mode = 0; mode < 3; mode++) {
        final preset = MilkdropPreset(
          name: 'Mode $mode',
          filePath: '',
          waveMode: mode,
          decay: 0.98,
          zoom: 1.05,
        );
        final painter = MilkdropPainter(
          preset: preset,
          bands: List.filled(32, 0.6),
          palette: testPalette,
          time: 2.5,
          sensitivity: 1.2,
        );

        final recorder = PictureRecorder();
        final canvas = Canvas(recorder);
        painter.paint(canvas, const Size(1280, 720));
        expect(recorder.endRecording(), isNotNull);
      }
    });
  });

  group('ProjectM Bridge Contract Tests', () {
    test('factory returns a bridge that never claims acceleration '
        'before initialization', () async {
      // 工厂是生产侧唯一入口（2026-11-22 N2 统一后）：探针在
      // 无桥库环境回落 Mock，在有桥库环境返回原生桥——两种
      // 结果都必须满足：未 initialize 前 isAvailable=false，
      // 且状态文案不得宣称硬件加速已就绪。
      final bridge = ProjectMBridgeFactory.create();
      expect(bridge, isA<ProjectMBridge>());
      expect(bridge.isAvailable, isFalse);
      expect(bridge.statusDescription, isNot(contains('ready')));
      bridge.dispose();
    });

    test('native bridge initialize result matches availability', () async {
      // W3/W4 口径（2026-11-23）：桥自持 GL 上下文，宿主不再提供
      // 验证器。initialize 的成败只取决于本机是否存在桥库与其
      // GL 平台层——两种环境都必须满足：返回值与 isAvailable
      // 一致（成功即已创建原生实例，失败即保持不可用、不假报）。
      final bridge = ProjectMNativeBridge();
      final ok = await bridge.initialize();
      expect(ok, bridge.isAvailable);
      bridge.dispose();
    });

    test('Mock bridge lifecycle and preset binding', () async {
      final bridge = MockProjectMBridge();

      final initOk = await bridge.initialize(width: 1920, height: 1080);
      expect(initOk, isTrue);

      const preset = MilkdropPreset(
        name: 'Starfield',
        filePath: '/path/starfield.milk',
      );
      final loadOk = bridge.loadPreset(preset);
      expect(loadOk, isTrue);
      expect(bridge.isLoaded, isTrue);
      expect(bridge.currentPreset?.name, 'Starfield');

      expect(isValidProjectMPcm([0.0, 0.0]), isTrue);
      expect(isValidProjectMPcm([1.0, -1.0]), isTrue);
      expect(isValidProjectMPcm(List.filled(4096, 0.0)), isTrue);
      expect(
        isValidProjectMPcm(List.filled(4098, 0.0)),
        isFalse,
        reason: 'more than 2048 stereo frames',
      );
      expect(
        isValidProjectMPcm(List.filled(1025, 0.0)),
        isFalse,
        reason: 'odd interleaved sample count',
      );
      expect(isValidProjectMPcm(List.filled(513, 0.0), channels: 2), isFalse);
      expect(isValidProjectMPcm(List.filled(512, 0.0), channels: 3), isFalse);
      expect(isValidProjectMPcm([1.01, 0.0]), isFalse);
      expect(isValidProjectMPcm([double.nan, 0.0]), isFalse);
      expect(isValidProjectMPcm([double.infinity, 0.0]), isFalse);
      bridge.feedPcm([0.0, 0.0]);
      bridge.feedPcm([1.01, 0.0]);
      bridge.resize(2560, 1440);

      final painter = ProjectMPainter(
        bridge: bridge,
        fallbackPainter: MilkdropPainter(
          preset: MilkdropPreset.builtInPresets.first,
          bands: List.filled(32, 0.5),
          palette: testPalette,
          time: 0.0,
          sensitivity: 1.0,
        ),
      );
      final recorder = PictureRecorder();
      painter.paint(Canvas(recorder), const Size(400, 300));
      final picture = recorder.endRecording();
      final image = await picture.toImage(400, 300);
      final pixels = await image.toByteData();
      expect(pixels, isNotNull);
      expect(pixels!.getUint32(0), isNot(0));
      image.dispose();
      picture.dispose();

      bridge.dispose();
      expect(bridge.isLoaded, isFalse);
    });
  });

  group('VisualizerPainterDispatcher Routing Tests', () {
    test(
      'Routes all VisualizerStyle values to valid CustomPainter instances',
      () {
        final synth = WaveformSynthesizer();
        synth.update(
          List.filled(32, 0.5),
          levelLDbfs: -12.0,
          levelRDbfs: -12.0,
        );

        const config = VisualizerConfig();
        final rawBands = List.filled(32, 0.5);
        final peaks = List.filled(32, 0.6);

        for (final style in VisualizerStyle.values) {
          final painter = buildVisualizerPainter(
            style: style,
            config: config,
            palette: testPalette,
            rawBands: rawBands,
            peaks: peaks,
            waveformSynth: synth,
            time: 1.0,
          );
          expect(painter, isNotNull);

          final recorder = PictureRecorder();
          final canvas = Canvas(recorder);
          painter.paint(canvas, const Size(400, 300));
          expect(recorder.endRecording(), isNotNull);
        }
      },
    );
  });

  group('ProjectM Bridge Honesty & Categorized HUD Tests', () {
    test('ProjectMBridge contracts honestly declare native vs mock status', () {
      final mock = MockProjectMBridge();
      expect(mock.isNative, isFalse);
      expect(mock.isAvailable, isFalse);
      expect(mock.statusDescription, contains('Procedural simulation'));

      final native = ProjectMNativeBridge();
      expect(native.isNative, isTrue);
      expect(native.isAvailable, isFalse);
      // 未初始化不得自称硬件加速（诚实口径）：状态须明示未初始化，
      // 'libprojectM hardware accelerated' 只在 isAvailable 后出现。
      expect(native.statusDescription, contains('not initialized'));
      expect(native.statusDescription, isNot(contains('hardware accelerated')));
    });

    testWidgets(
      'VisualizerHud categorized tabs switch between Native and MilkDrop presets',
      (tester) async {
        tester.view.physicalSize = const Size(1280, 800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        VisualizerStyle currentStyle = VisualizerStyle.bars;
        MilkdropPreset? selectedPreset;

        await tester.pumpWidget(
          MaterialApp(
            theme: withAuraExtension(ThemeData.dark(), auraDark),
            locale: const Locale('zh'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: Stack(
                children: [
                  VisualizerHud(
                    config: VisualizerConfig(style: currentStyle),
                    displayMode: VisualizerDisplayMode.restore,
                    visible: true,
                    onStyleChanged: (s) => currentStyle = s,
                    onDisplayModeChanged: (_) {},
                    onToggleLyrics: () {},
                    onOpenDrawer: () {},
                    onResetPeaks: () {},
                    milkdropPresets: MilkdropPreset.builtInPresets,
                    onSelectMilkdropPreset: (p) => selectedPreset = p,
                    isProjectMNativeActive: false,
                  ),
                ],
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Tap HUD dropdown button to open menu
        await tester.tap(find.byType(VisualizerStyleDropdownButton));
        await tester.pumpAndSettle();

        // Check category tabs exist
        expect(find.byType(CategoryTabButton), findsNWidgets(2));
        expect(
          find.byType(VisualizerMenuItem),
          findsNWidgets(VisualizerStyle.values.length - 1),
        );

        // Switch to MilkDrop tab
        final milkdropTab = find.widgetWithText(
          CategoryTabButton,
          'MilkDrop 预设',
        );
        expect(milkdropTab, findsOneWidget);
        await tester.tap(milkdropTab);
        await tester.pumpAndSettle();

        // Honesty badge: indicates procedural simulation because isProjectMNativeActive is false
        expect(find.text('内置着色器拓扑模拟'), findsOneWidget);

        // Presets are listed
        expect(find.byType(MilkdropPresetMenuItem), findsWidgets);

        // Select preset
        final firstPreset = find.byType(MilkdropPresetMenuItem).first;
        await tester.tap(firstPreset);
        await tester.pumpAndSettle();

        expect(
          currentStyle,
          VisualizerStyle.bars,
          reason:
              'selection already writes style and path; no stale second write',
        );
        expect(selectedPreset, isNotNull);
      },
    );
  });
}
