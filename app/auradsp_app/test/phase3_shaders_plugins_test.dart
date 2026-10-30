import 'dart:io';
import 'dart:ui';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/features/visualizer/controllers/waveform_synthesizer.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_themes.dart';
import 'package:auradsp_app/features/visualizer/models/visualizer_types.dart';
import 'package:auradsp_app/features/visualizer/plugins/milkdrop_preset.dart';
import 'package:auradsp_app/features/visualizer/plugins/projectm_bridge_contract.dart';
import 'package:auradsp_app/features/visualizer/shaders/gpu_shader_service.dart';
import 'package:auradsp_app/features/visualizer/styles/style_gpu_shader.dart';
import 'package:auradsp_app/features/visualizer/styles/style_milkdrop.dart';
import 'package:auradsp_app/features/visualizer/styles/visualizer_painter_dispatcher.dart';

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
    });

    test('VisualizerStyle includes GPU shader modes and MilkDrop', () {
      expect(VisualizerStyle.values.contains(VisualizerStyle.auroraShader), isTrue);
      expect(VisualizerStyle.values.contains(VisualizerStyle.tunnelShader), isTrue);
      expect(VisualizerStyle.values.contains(VisualizerStyle.milkDrop), isTrue);
      expect(VisualizerStyle.auroraShader.label, 'Aurora Ribbon');
      expect(VisualizerStyle.tunnelShader.label, 'Neon Tunnel');
      expect(VisualizerStyle.milkDrop.label, 'MilkDrop');
    });

    test('GpuShaderPainter draws fallback when program is uncompiled', () {
      final painter = GpuShaderPainter(
        program: null,
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
    test('Mock bridge lifecycle and preset binding', () async {
      final bridge = MockProjectMBridge();

      final initOk = await bridge.initialize(width: 1920, height: 1080);
      expect(initOk, isTrue);

      const preset = MilkdropPreset(name: 'Starfield', filePath: '/path/starfield.milk');
      final loadOk = bridge.loadPreset(preset);
      expect(loadOk, isTrue);
      expect(bridge.isLoaded, isTrue);
      expect(bridge.currentPreset?.name, 'Starfield');

      bridge.feedPcm(List.filled(512, 0.0));
      bridge.resize(2560, 1440);
      bridge.dispose();
      expect(bridge.isLoaded, isFalse);
    });
  });

  group('VisualizerPainterDispatcher Routing Tests', () {
    test('Routes all VisualizerStyle values to valid CustomPainter instances', () {
      final synth = WaveformSynthesizer();
      synth.update(List.filled(32, 0.5), levelLDbfs: -12.0, levelRDbfs: -12.0);

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
    });
  });
}
