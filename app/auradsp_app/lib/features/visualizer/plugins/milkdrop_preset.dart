import 'dart:io';
import 'dart:isolate';

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

  /// 落盘目录：内置 .milk 资产在启动时释放到用户数据目录
  /// （MilkdropBuiltinStaging 负责写入并回填此值）。原生桥只接
  /// 真实文件路径，'builtin:' 伪路径在任何文件用途前必须先经
  /// [resolveFilePath] 解析——r64 验收定罪：三只内置预设此前恒
  /// 被桥拒绝、且 parseFile 不认 builtin id 全塌成默认参数。
  static String? builtinDir;
  static final Map<String, MilkdropPreset> _metadataCache = {};

  static void remember(MilkdropPreset preset) {
    _metadataCache[preset.filePath] = preset;
    final resolved = resolveFilePath(preset.filePath);
    if (resolved != preset.filePath) _metadataCache[resolved] = preset;
  }

  static MilkdropPreset lightweight(String path) {
    final resolved = resolveFilePath(path);
    final cached = _metadataCache[path] ?? _metadataCache[resolved];
    if (cached != null) return cached;
    if (isBuiltinPath(path)) {
      for (final declared in builtInPresets) {
        if (declared.filePath == path) return declared;
      }
    }
    final segments = File(path).uri.pathSegments;
    final name = segments.isNotEmpty
        ? segments.last.replaceAll('.milk', '')
        : 'Unknown Preset';
    return MilkdropPreset(name: name, filePath: resolved);
  }

  static bool isBuiltinPath(String path) => path.startsWith('builtin:');

  /// `builtin:<id>` → 落盘真实路径；其它路径原样返回。尚未落盘
  /// （builtinDir 为空）时原样返回伪路径，调用方据此延后加载。
  static String resolveFilePath(String path) {
    if (!isBuiltinPath(path)) return path;
    final dir = builtinDir;
    if (dir == null) return path;
    final id = path.substring('builtin:'.length);
    return '$dir${Platform.pathSeparator}$id.milk';
  }

  /// Parse a MilkDrop .milk file
  factory MilkdropPreset.parseFile(String path) {
    if (isBuiltinPath(path)) {
      // 身份与参数以声明表为准；已落盘时再以真文件校准方程标记
      // 等解析量（名称/作者/标称参数不被文件名与文件头覆盖）。
      for (final declared in builtInPresets) {
        if (declared.filePath != path) continue;
        final resolved = resolveFilePath(path);
        if (resolved != path && File(resolved).existsSync()) {
          final read = ResourceGate.readText(resolved);
          if (read.ok) {
            final parsed = parseString(declared.name, path, read.text!);
            return MilkdropPreset(
              name: declared.name,
              filePath: path,
              author: declared.author,
              decay: declared.decay,
              zoom: declared.zoom,
              waveMode: declared.waveMode,
              hasCustomEquations: parsed.hasCustomEquations,
            );
          }
        }
        return declared;
      }
      return MilkdropPreset(name: 'Unknown Preset', filePath: path);
    }
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

  static Future<MilkdropPreset> parseFileAsync(String path) =>
      Isolate.run(() => MilkdropPreset.parseFile(path));

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
        case 'fdecay':
          decay = double.tryParse(val) ?? 0.98;
          break;
        case 'zoom':
          zoom = double.tryParse(val) ?? 1.0;
          break;
        case 'wave_mode':
        case 'nwavemode':
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
  static Future<List<MilkdropPreset>> scanDirectoryAsync(String dirPath) =>
      Isolate.run(() => scanDirectory(dirPath));

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
