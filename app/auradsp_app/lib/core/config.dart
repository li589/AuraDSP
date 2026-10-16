/*
 * config.dart — AuraDSP 全局外置配置中心
 *
 * 职责：接管原本散落在代码各处的硬编码参数（采样率、缓冲区、安全阈值、界面偏好等）。
 * 存储路径：%APPDATA%/AuraDSP/config.json。
 * 启动时自动加载，缺失时自动生成标准模板，支持热更新与重置。
 */

import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;

class AppConfig {
  /// 可视化帧率默认值。核显上 30fps 的全窗口重绘会把 GPU 顶到 ~70%
  ///（L-15 / §13.4.27.3），默认降到 20。
  static const int defaultVizFps = 20;

  // 音频引擎参数
  int sampleRate;
  int maxBlockFrames;
  String audioMode;
  int vizFps;
  int vizFftSize;
  double stereoWidenMax;

  // ASIO 桥选择项（audioMode=='asio' 时生效；见 AsioBridge.h 契约）
  String asioDriver; // detect 的 name（UTF-8 显示名）；''=未选择
  int asioBufSize; // 0=驱动 preferredSize；其余为显式档位（帧）
  int asioOutPair; // 输出对起始声道（L=R+1 配对）
  int vbBusMask; // VB 总线处理掩码（bit g=第 g 条总线进 DSP，默认全开 0xFF）
  String vaioOutputEndpoint; // AuraVAIO 桥物理输出端点子串（'' = 自动探测物理扬声器）

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
    this.audioMode = 'auto',
    this.asioDriver = '',
    this.asioBufSize = 0,
    this.asioOutPair = 0,
    this.vbBusMask = 0xFF,
    this.vaioOutputEndpoint = '',
    this.vizFps = defaultVizFps,
    this.vizFftSize = 4096,
    this.stereoWidenMax = 0.75,
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
      audioMode: (audio['audioMode'] as String?) ?? 'auto',
      asioDriver: (audio['asioDriver'] as String?) ?? '',
      asioBufSize: (audio['asioBufSize'] as num?)?.toInt() ?? 0,
      asioOutPair: (audio['asioOutPair'] as num?)?.toInt() ?? 0,
      vbBusMask: (audio['vbBusMask'] as num?)?.toInt() ?? 0xFF,
      vaioOutputEndpoint: (audio['vaioOutputEndpoint'] as String?) ?? '',
      vizFps: (audio['vizFps'] as num?)?.toInt() ?? defaultVizFps,
      vizFftSize: (audio['vizFftSize'] as num?)?.toInt() ?? 4096,
      stereoWidenMax: (audio['stereoWidenMax'] as num?)?.toDouble() ?? 0.75,
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
        'version': 3,
        'audio': {
          'sampleRate': sampleRate,
          'maxBlockFrames': maxBlockFrames,
          'audioMode': audioMode,
          'asioDriver': asioDriver,
          'asioBufSize': asioBufSize,
          'asioOutPair': asioOutPair,
          'vbBusMask': vbBusMask,
          'vaioOutputEndpoint': vaioOutputEndpoint,
          'vizFps': vizFps,
          'vizFftSize': vizFftSize,
          'stereoWidenMax': stereoWidenMax,
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
    // 单测自动沙箱：flutter test 进程自带 FLUTTER_TEST=true，
    // 此时一律指向系统临时目录，永不触碰用户真实数据。
    // 根因史：plugin_cache 曾被假数据覆盖（事后补了 baseDirOverride）；
    // AppModel 构造回放真实 session 曾让 stereoBandUsed 断言失败（§13.4.26）。
    // 显式 baseDirOverride 仍优先（个别测试可自选目录）。
    if (Platform.environment['FLUTTER_TEST'] == 'true') {
      _baseDir = Directory.systemTemp.createTempSync('auradsp_test_').path;
      return _baseDir!;
    }
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

  /// 仅供单元测试注入临时根目录（优先于 FLUTTER_TEST 自动沙箱）。
  ///
  /// 自 §13.4.26 起，`flutter test` 下 `baseDir` 默认即沙箱（系统临时目录），
  /// 无需每个测试文件手动注入。本 setter 保留给需要固定目录的测试
  ///（如 plugin_manager_test 断言缓存回写位置），语义不变：非空即优先。
  @visibleForTesting
  static set baseDirOverride(String? dir) => _baseDir = dir;

  /// 统一的子目录/文件路径拼接（跨平台）。
  /// baseDir 是全应用唯一根目录（Windows: %APPDATA%/AuraDSP，
  /// 其它: ~/.config/auradsp）。此前 plugin_manager / liveprog_page
  /// 各自用 APPDATA 拼路径，在非 Windows 上会退化成相对路径 ./AuraDSP，
  /// 预设/缓存/脚本就散落到三个不同根目录。
  static String path(String relative) =>
      baseDir + Platform.pathSeparator + relative;

  static Directory subDir(String relative) {
    final d = Directory(path(relative));
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  /// 以两空格缩进把 [value] 写成 JSON 文件，自动建父目录。
  ///
  /// 此前 config / presets / session_memory 各自重复「mkdir + JsonEncoder +
  /// writeAsStringSync」三行样板（6 处），格式与错误处理容易各自漂移。
  /// 返回是否写成功——**绝不抛异常**，调用方多数在 try/catch 里做持久化，
  /// 一次磁盘错误不该把 UI 逻辑打断。
  static bool writeJsonFile(String filePath, Object? value) {
    try {
      final dir = Directory(filePath.substring(0, filePath.lastIndexOf(
          Platform.pathSeparator)));
      if (!dir.existsSync()) dir.createSync(recursive: true);
      File(filePath).writeAsStringSync(
          const JsonEncoder.withIndent('  ').convert(value));
      return true;
    } catch (_) {
      return false;
    }
  }

  static String get configPath =>
      '$baseDir${Platform.pathSeparator}config.json';

  static AppConfig load() {
    try {
      final file = File(configPath);
      if (file.existsSync()) {
        final content = file.readAsStringSync();
        final json = jsonDecode(content) as Map<String, dynamic>;
        final cfg = AppConfig.fromJson(json);
        // v2 -> v3 迁移：可视化帧率旧默认 30 在核显上把 GPU 顶到 ~70%
        //（30fps 全窗口重绘，见 §13.4.27.3）。旧配置里 vizFps 恒为旧默认
        //（无 UI 可改），故按版本号安全强制降到新默认并落盘新版本。
        final ver = (json['version'] as num?)?.toInt() ?? 0;
        if (ver < 3) {
          cfg.vizFps = AppConfig.defaultVizFps;
          save(cfg);
        }
        return cfg;
      }
    } catch (_) {}
    // 首次运行或解析失败，生成并写入默认配置
    final cfg = AppConfig();
    save(cfg);
    return cfg;
  }

  static bool save(AppConfig config) {
    try {
      return writeJsonFile(configPath, config.toJson());
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
