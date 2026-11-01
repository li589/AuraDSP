/*
 * config.dart — AuraDSP 全局外置配置中心
 *
 * 职责：接管原本散落在代码各处的硬编码参数（采样率、缓冲区、安全阈值、界面偏好等）。
 * 存储路径：%APPDATA%/AuraDSP/config.json。
 * 启动时自动加载，缺失时自动生成标准模板，支持热更新与重置。
 */

import 'dart:io';

import 'io/document_store.dart';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'audio_modes.dart';
import 'plugins/plugin_scan_dirs.dart';
import 'visualizer_types.dart';
import '../platform/platform_profile.dart';

import 'error_sink.dart';
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
  int channelsCountMode; // 0=auto, 1=manual
  int channelsCount; // 2, 4, 6, 8

  // ADR-009 两大交互范式扩展
  String modeCategory; // 'attachment' | 'pipeline'
  String attachmentMode; // 'sysapo' | 'voicemeeter_api'
  String pipelineInput; // 'asio_driver' | 'vaio' | 'wasapi'
  String pipelineOutput; // 'wasapi' | 'vaio' | 'asio_client'
  String pipelineInputDevice; // WASAPI 采集端点
  String pipelineOutputDevice; // WASAPI 渲染端点
  bool pipelineInputEnabled; // 输入端启用开关
  bool pipelineOutputEnabled; // 输出端启用开关
  String apoTargetEndpoint; // System APO 目标挂接端点
  bool monitorMirroring; // 虚拟端点本地耳机监听镜像

  // ASIO 桥选择项（audioMode=='asio' 时生效；见 AsioBridge.h 契约）
  String asioDriver; // detect 的 name（UTF-8 显示名）；''=未选择
  int asioBufSize; // 0=驱动 preferredSize；其余为显式档位（帧）
  int asioOutPair; // 输出对起始声道（L=R+1 配对）
  int vbBusMask; // VB 总线处理掩码（bit g=第 g 条总线进 DSP，默认全开 0xFF）
  int vbPluginGroupMask; // 按路插件处理掩码（bit g=组 g 总线吃插件链，默认全开 0xFF）
  bool vbAutoProtect; // Z12 超预算自动保护：回调持续超预算时收窄插件到监听总线
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
  /// 插件扫描目录（2026-10-28 改版）：显式条目 + 勾选态 + 内置标记。
  /// 旧版 `customPluginDirs`（纯路径表）在 [fromJson] 中自动迁移。
  List<PluginScanDirEntry> pluginScanDirs;

  /// 平台预置目录是否已做过一次性播种（用户清空列表后不再自动加回）。
  bool pluginScanDirsSeeded;
  List<String> customScriptDirs;

  /// 可视化配置（2026-10-31）：风格/配色/动态/歌词源等全部参数。
  /// 这里是跨重启的持久化副本；运行时真相源是 AppModel.visualizerConfig，
  /// 同一份数据另随会话记忆与预设系统保存/恢复。
  VisualizerConfig visualizerConfig;

  AppConfig({
    this.sampleRate = 48000,
    this.maxBlockFrames = 1024,
    this.audioMode = 'auto',
    this.channelsCountMode = 0,
    this.channelsCount = 2,
    String? modeCategory,
    String? attachmentMode,
    String? pipelineInput,
    String? pipelineOutput,
    this.pipelineInputDevice = '',
    this.pipelineOutputDevice = '',
    this.pipelineInputEnabled = true,
    this.pipelineOutputEnabled = true,
    this.apoTargetEndpoint = '',
    this.monitorMirroring = false,
    this.asioDriver = '',
    this.asioBufSize = 0,
    this.asioOutPair = 0,
    this.vbBusMask = 0xFF,
    this.vbPluginGroupMask = 0xFF,
    this.vbAutoProtect = true,
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
    List<PluginScanDirEntry>? pluginScanDirs,
    this.pluginScanDirsSeeded = false,
    List<String>? customScriptDirs,
    VisualizerConfig? visualizerConfig,
  })  : modeCategory = modeCategory ?? AudioModes.categoryForMode(audioMode),
        attachmentMode = attachmentMode ??
            ((audioMode == 'vbcallback' || audioMode == 'voicemeeter_api')
                ? AudioModes.attachVoicemeeterApi
                : AudioModes.attachSysApo),
        pipelineInput = pipelineInput ?? AudioModes.inputWasapi,
        pipelineOutput = pipelineOutput ??
            (audioMode == 'asio'
                ? AudioModes.outputAsioClient
                : (audioMode == 'vaio' ? AudioModes.outputVaio : AudioModes.outputWasapi)),
        pluginScanDirs = pluginScanDirs ?? [],
        customScriptDirs = customScriptDirs ?? [],
        visualizerConfig = visualizerConfig ?? const VisualizerConfig();

  factory AppConfig.fromJson(Map<String, dynamic> json) {
    final audio = (json['audio'] as Map<String, dynamic>?) ?? {};
    final ui = (json['ui'] as Map<String, dynamic>?) ?? {};
    final viz = (json['visualizer'] as Map<String, dynamic>?) ?? {};
    final safety = (json['safety'] as Map<String, dynamic>?) ?? {};
    final paths = (json['paths'] as Map<String, dynamic>?) ?? {};

    final rawMode = (audio['audioMode'] as String?) ?? 'auto';
    final rawCategory = audio['modeCategory'] as String?;
    final rawAttach = audio['attachmentMode'] as String?;
    final rawPipeIn = audio['pipelineInput'] as String?;
    final rawPipeOut = audio['pipelineOutput'] as String?;

    return AppConfig(
      sampleRate: (audio['sampleRate'] as num?)?.toInt() ?? 48000,
      maxBlockFrames: (audio['maxBlockFrames'] as num?)?.toInt() ?? 1024,
      audioMode: rawMode,
      modeCategory: rawCategory,
      attachmentMode: rawAttach,
      pipelineInput: rawPipeIn,
      pipelineOutput: rawPipeOut,
      pipelineInputDevice: (audio['pipelineInputDevice'] as String?) ?? '',
      pipelineOutputDevice: (audio['pipelineOutputDevice'] as String?) ?? '',
      pipelineInputEnabled: (audio['pipelineInputEnabled'] as bool?) ?? true,
      pipelineOutputEnabled: (audio['pipelineOutputEnabled'] as bool?) ?? true,
      apoTargetEndpoint: (audio['apoTargetEndpoint'] as String?) ?? '',
      monitorMirroring: (audio['monitorMirroring'] as bool?) ?? false,
      asioDriver: (audio['asioDriver'] as String?) ?? '',
      asioBufSize: (audio['asioBufSize'] as num?)?.toInt() ?? 0,
      asioOutPair: (audio['asioOutPair'] as num?)?.toInt() ?? 0,
      vbBusMask: (audio['vbBusMask'] as num?)?.toInt() ?? 0xFF,
      vbPluginGroupMask: (audio['vbPluginGroupMask'] as num?)?.toInt() ?? 0xFF,
      vbAutoProtect: (audio['vbAutoProtect'] as bool?) ?? true,
      vaioOutputEndpoint: (audio['vaioOutputEndpoint'] as String?) ?? '',
      vizFps: (audio['vizFps'] as num?)?.toInt() ?? defaultVizFps,
      vizFftSize: (audio['vizFftSize'] as num?)?.toInt() ?? 4096,
      stereoWidenMax: (audio['stereoWidenMax'] as num?)?.toDouble() ?? 0.75,
      channelsCountMode: (audio['channelsCountMode'] as num?)?.toInt() ?? 0,
      channelsCount: (audio['channelsCount'] as num?)?.toInt() ?? 2,
      locale: (ui['locale'] as String?) ?? 'zh',
      themeId: (ui['themeId'] as String?) ?? 'auraDark',
      autoRestoreSession: (ui['autoRestoreSession'] as bool?) ?? true,
      autoSaveDebounceMs: (ui['autoSaveDebounceMs'] as num?)?.toInt() ?? 500,
      maxIrDurationSeconds: (safety['maxIrDurationSeconds'] as num?)?.toDouble() ?? 30.0,
      maxFileSizeMb: (safety['maxFileSizeMb'] as num?)?.toDouble() ?? 64.0,
      // 2026-10-28 改版：pluginScanDirs 为显式条目；旧配置只有
      // customPluginDirs（路径字符串），读入时一律迁移为「启用、非内置」。
      pluginScanDirs: _readPluginScanDirs(paths),
      pluginScanDirsSeeded: (paths['pluginScanDirsSeeded'] as bool?) ?? false,
      customScriptDirs: (paths['customScriptDirs'] as List?)
              ?.map((e) => e.toString())
              .toList() ??
          [],
      visualizerConfig: VisualizerConfig.fromJson(viz),
    );
  }

  /// 扫描目录解析（含旧键迁移）。容错：坏条目跳过，不因单条脏数据丢全表。
  static List<PluginScanDirEntry> _readPluginScanDirs(Map<String, dynamic> paths) {
    final out = <PluginScanDirEntry>[];
    final raw = paths['pluginScanDirs'];
    if (raw is List) {
      for (final item in raw) {
        if (item is Map) {
          final entry = PluginScanDirEntry.fromJson(
            Map<String, dynamic>.from(item),
          );
          if (entry.path.trim().isNotEmpty) out.add(entry);
        } else if (item is String && item.trim().isNotEmpty) {
          out.add(PluginScanDirEntry(path: item));
        }
      }
      return out;
    }
    final legacy = paths['customPluginDirs'];
    if (legacy is List) {
      for (final item in legacy) {
        final p = item?.toString().trim() ?? '';
        if (p.isNotEmpty) out.add(PluginScanDirEntry(path: p));
      }
    }
    return out;
  }

  Map<String, dynamic> toJson() => {
        'version': 3,
        'audio': {
          'sampleRate': sampleRate,
          'maxBlockFrames': maxBlockFrames,
          'audioMode': audioMode,
          'channelsCountMode': channelsCountMode,
          'channelsCount': channelsCount,
          'modeCategory': modeCategory,
          'attachmentMode': attachmentMode,
          'pipelineInput': pipelineInput,
          'pipelineOutput': pipelineOutput,
          'pipelineInputDevice': pipelineInputDevice,
          'pipelineOutputDevice': pipelineOutputDevice,
          'pipelineInputEnabled': pipelineInputEnabled,
          'pipelineOutputEnabled': pipelineOutputEnabled,
          'apoTargetEndpoint': apoTargetEndpoint,
          'monitorMirroring': monitorMirroring,
          'asioDriver': asioDriver,
          'asioBufSize': asioBufSize,
          'asioOutPair': asioOutPair,
          'vbBusMask': vbBusMask,
          'vbPluginGroupMask': vbPluginGroupMask,
          'vbAutoProtect': vbAutoProtect,
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
          'pluginScanDirs': pluginScanDirs.map((e) => e.toJson()).toList(),
          'pluginScanDirsSeeded': pluginScanDirsSeeded,
          'customScriptDirs': customScriptDirs,
        },
        'visualizer': visualizerConfig.toJson(),
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
    if (PlatformProfile.isTestRun) {
      _baseDir = Directory.systemTemp.createTempSync('auradsp_test_').path;
      return _baseDir!;
    }
    _baseDir = PlatformProfile.configDir;
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
  /// 实现已收敛到 `core/io/document_store.dart`（统一落盘治理）；
  /// 本方法保留为兼容薄委托，旧调用零改动。
  static bool writeJsonFile(String filePath, Object? value) =>
      DocumentStore.writeJson(filePath, value);

  static String get configPath =>
      '$baseDir${Platform.pathSeparator}config.json';

  static AppConfig load() {
    final read = DocumentStore.readJson(configPath);
    if (read.ok) {
      final json = read.data!;
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
    // 首次运行或解析失败，生成并写入默认配置
    final cfg = AppConfig();
    save(cfg);
    return cfg;
  }

  static bool save(AppConfig config) {
    try {
      return writeJsonFile(configPath, config.toJson());
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  static AppConfig resetToDefaults() {
    final cfg = AppConfig();
    save(cfg);
    return cfg;
  }
}
