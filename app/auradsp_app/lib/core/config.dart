/*
 * config.dart — AuraDSP 全局外置配置中心
 *
 * 职责：接管原本散落在代码各处的硬编码参数（采样率、缓冲区、安全阈值、界面偏好等）。
 * 存储路径：%APPDATA%/AuraDSP/config.json。
 * 启动时自动加载，缺失时自动生成标准模板，支持热更新与重置。
 */

import 'dart:convert';
import 'dart:io';

class AppConfig {
  // 音频引擎参数
  int sampleRate;
  int maxBlockFrames;
  int vizFps;
  int vizFftSize;
  double stereoWidenMax;
  int defaultLatencyMode;

  // 界面与记忆参数
  String locale;
  String themeId;
  bool autoRestoreSession;
  int autoSaveDebounceMs;

  // 安全与资源参数
  double maxIrDurationSeconds;
  double maxFileSizeMb;

  // 自定义检索与外部预设目录
  List<String> customPluginDirs;
  List<String> customScriptDirs;

  AppConfig({
    this.sampleRate = 48000,
    this.maxBlockFrames = 1024,
    this.vizFps = 30,
    this.vizFftSize = 4096,
    this.stereoWidenMax = 0.75,
    this.defaultLatencyMode = 2,
    this.locale = 'zh',
    this.themeId = 'auraDark',
    this.autoRestoreSession = true,
    this.autoSaveDebounceMs = 500,
    this.maxIrDurationSeconds = 30.0,
    this.maxFileSizeMb = 64.0,
    List<String>? customPluginDirs,
    List<String>? customScriptDirs,
  })  : customPluginDirs = customPluginDirs ?? [],
        customScriptDirs = customScriptDirs ?? [];

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final audio = (json['audio'] as Map<String, dynamic>?) ?? {};
    final ui = (json['ui'] as Map<String, dynamic>?) ?? {};
    final safety = (json['safety'] as Map<String, dynamic>?) ?? {};
    final paths = (json['paths'] as Map<String, dynamic>?) ?? {};

    return AppConfig(
      sampleRate: (audio['sampleRate'] as num?)?.toInt() ?? 48000,
      maxBlockFrames: (audio['maxBlockFrames'] as num?)?.toInt() ?? 1024,
      vizFps: (audio['vizFps'] as num?)?.toInt() ?? 30,
      vizFftSize: (audio['vizFftSize'] as num?)?.toInt() ?? 4096,
      stereoWidenMax: (audio['stereoWidenMax'] as num?)?.toDouble() ?? 0.75,
      defaultLatencyMode: (audio['defaultLatencyMode'] as num?)?.toInt() ?? 2,
      locale: (ui['locale'] as String?) ?? 'zh',
      themeId: (ui['themeId'] as String?) ?? 'auraDark',
      autoRestoreSession: (ui['autoRestoreSession'] as bool?) ?? true,
      autoSaveDebounceMs: (ui['autoSaveDebounceMs'] as num?)?.toInt() ?? 500,
      maxIrDurationSeconds: (safety['maxIrDurationSeconds'] as num?)?.toDouble() ?? 30.0,
      maxFileSizeMb: (safety['maxFileSizeMb'] as num?)?.toDouble() ?? 64.0,
      customPluginDirs: (paths['customPluginDirs'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      customScriptDirs: (paths['customScriptDirs'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
    );
  }

  Map<String, dynamic> toJson() => {
        'version': 2,
        'audio': {
          'sampleRate': sampleRate,
          'maxBlockFrames': maxBlockFrames,
          'vizFps': vizFps,
          'vizFftSize': vizFftSize,
          'stereoWidenMax': stereoWidenMax,
          'defaultLatencyMode': defaultLatencyMode,
        },
        'ui': {
          'locale': locale,
          'themeId': themeId,
          'autoRestoreSession': autoRestoreSession,
          'autoSaveDebounceMs': autoSaveDebounceMs,
        },
        'safety': {
          'maxIrDurationSeconds': maxIrDurationSeconds,
          'maxFileSizeMb': maxFileSizeMb,
        },
        'paths': {
          'customPluginDirs': customPluginDirs,
          'customScriptDirs': customScriptDirs,
        },
      };
}

abstract final class ConfigManager {
  static String? _baseDir;

  static String get baseDir {
    if (_baseDir != null) return _baseDir!;
    if (Platform.isWindows) {
      final appData = Platform.environment['APPDATA'];
      _baseDir = appData != null
          ? '$appData${Platform.pathSeparator}AuraDSP'
          : 'AuraDSP';
    } else {
      final home = Platform.environment['HOME'] ?? '.';
      _baseDir = '$home${Platform.pathSeparator}.config${Platform.pathSeparator}auradsp';
    }
    return _baseDir!;
  }

  static String get configPath =>
      '$baseDir${Platform.pathSeparator}config.json';

  static AppConfig load() {
    try {
      final file = File(configPath);
      if (file.existsSync()) {
        final content = file.readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;
        return AppConfig.fromJson(json);
      }
    } catch (_) {}
    // 首次运行或解析失败，生成并写入默认配置
    final cfg = AppConfig();
    save(cfg);
    return cfg;
  }

  static bool save(AppConfig config) {
    try {
      final dir = Directory(baseDir);
      if (!dir.existsSync()) dir.createSync(recursive: true);
      final jsonStr = const JsonEncoder.withIndent('  ').convert(config.toJson());
      File(configPath).writeAsStringSync(jsonStr);
      return true;
    } catch (_) {
      return false;
    }
  }

  static AppConfig resetToDefaults() {
    final cfg = AppConfig();
    save(cfg);
    return cfg;
  }
}
