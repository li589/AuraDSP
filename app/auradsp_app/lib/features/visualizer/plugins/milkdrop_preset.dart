import 'dart:io';

import '../../../core/error_sink.dart';
import '../../../core/io/resource_gate.dart';

/// Structured metadata for a Winamp MilkDrop 2 (.milk) preset
class MilkdropPreset {
  final String name;
  final String filePath;
  final String author;
  final double decay;
  final double zoom;
  final int waveMode;
  final bool hasCustomEquations;

  const MilkdropPreset({
    required this.name,
    required this.filePath,
    this.author = 'Unknown',
    this.decay = 0.98,
    this.zoom = 1.0,
    this.waveMode = 0,
    this.hasCustomEquations = false,
  });

  /// Built-in fallback presets shipped with AuraDSP
  static const List<MilkdropPreset> builtInPresets = [
    MilkdropPreset(
      name: 'Cosmic Warp',
      filePath: 'builtin:cosmic_warp',
      author: 'Ryan Geiss',
      decay: 0.97,
      zoom: 1.05,
      waveMode: 2,
      hasCustomEquations: true,
    ),
    MilkdropPreset(
      name: 'Bio Pulsar',
      filePath: 'builtin:bio_pulsar',
      author: 'Rovastar',
      decay: 0.95,
      zoom: 1.02,
      waveMode: 0,
      hasCustomEquations: true,
    ),
    MilkdropPreset(
      name: 'Neon Vortex',
      filePath: 'builtin:neon_vortex',
      author: 'Unchained',
      decay: 0.98,
      zoom: 1.08,
      waveMode: 1,
      hasCustomEquations: true,
    ),
  ];

  /// Parse a MilkDrop .milk file
  factory MilkdropPreset.parseFile(String path) {
    final file = File(path);
    final name = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last.replaceAll('.milk', '')
        : 'Unknown Preset';

    if (!file.existsSync()) {
      return MilkdropPreset(name: name, filePath: path);
    }

    final read = ResourceGate.readText(path);
    if (!read.ok) {
      // 损坏或不可读的预设文件：回退为默认参数
      return MilkdropPreset(name: name, filePath: path);
    }
    return parseString(name, path, read.text!);
  }

  /// Parse MilkDrop configuration text
  static MilkdropPreset parseString(String name, String path, String content) {
    var author = 'Unknown';
    var decay = 0.98;
    var zoom = 1.0;
    var waveMode = 0;
    var hasEquations = false;

    for (final line in content.split('\n')) {
      final trimmed = line.trim();
      if (trimmed.isEmpty || trimmed.startsWith('//')) continue;

      final eqIdx = trimmed.indexOf('=');
      if (eqIdx <= 0) continue;

      final key = trimmed.substring(0, eqIdx).trim().toLowerCase();
      final val = trimmed.substring(eqIdx + 1).trim();

      switch (key) {
        case 'author':
          author = val;
          break;
        case 'decay':
          decay = double.tryParse(val) ?? 0.98;
          break;
        case 'zoom':
          zoom = double.tryParse(val) ?? 1.0;
          break;
        case 'wave_mode':
          waveMode = int.tryParse(val) ?? 0;
          break;
        case 'per_frame_1':
        case 'per_pixel_1':
          hasEquations = true;
          break;
      }
    }

    return MilkdropPreset(
      name: name,
      filePath: path,
      author: author,
      decay: decay,
      zoom: zoom,
      waveMode: waveMode,
      hasCustomEquations: hasEquations,
    );
  }
}

/// Helper scanner for discovering .milk presets in a folder
abstract final class MilkdropPresetScanner {
  static List<MilkdropPreset> scanDirectory(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const [];

    final list = <MilkdropPreset>[];
    try {
      final entities = dir.listSync(recursive: false);
      for (final e in entities) {
        if (e is File && e.path.toLowerCase().endsWith('.milk')) {
          list.add(MilkdropPreset.parseFile(e.path));
        }
      }
    } catch (e, st) {
      // 目录枚举失败：留痕并返回已扫描到的部分结果
      swallow(e, st);
    }
    return list;
  }
}
