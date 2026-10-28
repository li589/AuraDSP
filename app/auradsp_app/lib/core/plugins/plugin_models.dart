// plugin_models.dart — 插件领域模型（2026-10-28 从 plugin_manager.dart 拆出）。
//
// 纯数据：无 IO、无状态、无 Flutter 依赖，任何层（UI/测试/工具）都可直接引用。
// 由 plugin_manager.dart re-export，调用方仍可从插件管理器入口取到这些类型。

enum PluginFormat {
  vst3,
  clap,

  /// 以下三种为 2026-10-28 预留（扫描/挂载驱动尚未实现，UI 分类按钮先占位）：
  /// VST2（Windows dll / macOS vst / Linux so）、AU（macOS 独占）、
  /// LV2（Linux 开源标准）。引擎产出这些格式时列表角标/筛选即刻可用。
  vst2,
  au,
  lv2,
  unknown;

  static PluginFormat fromString(String val) {
    final s = val.toLowerCase().trim();
    if (s.contains('vst3')) return PluginFormat.vst3;
    if (s.contains('clap')) return PluginFormat.clap;
    if (s.contains('vst2') || s == 'vst') return PluginFormat.vst2;
    if (s == 'au' || s.contains('audiounit')) return PluginFormat.au;
    if (s.contains('lv2')) return PluginFormat.lv2;
    return PluginFormat.unknown;
  }

  String get label {
    switch (this) {
      case PluginFormat.vst3:
        return 'VST3';
      case PluginFormat.clap:
        return 'CLAP';
      case PluginFormat.vst2:
        return 'VST2';
      case PluginFormat.au:
        return 'AU';
      case PluginFormat.lv2:
        return 'LV2';
      case PluginFormat.unknown:
        return 'OTHER';
    }
  }
}

/// 插件元数据模型
class PluginMetadata {
  final String id;
  final String name;

  /// 插件自报名（CLAP descriptor / VST3 factory）。
  final String vendor;
  final String version;

  /// 真实分类：CLAP features 级联 / VST3 subCategories。
  /// 注意历史上曾被误填为 descriptor 的 description 自由文本（B1 已修）。
  final String category;

  /// Bundle/文件名 stem —— 用户在列表里实际选中的那一个。
  /// CLAP 的自报名与文件名可能不同（如自报名 "Element FX"、文件 KV-Element-FX）。
  final String bundleName;

  /// 自由文本描述，仅展示用，不参与分类判断。
  final String description;
  final PluginFormat format;
  final String path;
  final bool isCompatible;
  final String errorMessage;

  const PluginMetadata({
    required this.id,
    required this.name,
    this.vendor = '',
    this.version = '',
    this.category = '',
    this.bundleName = '',
    this.description = '',
    required this.format,
    required this.path,
    this.isCompatible = true,
    this.errorMessage = '',
  });

  factory PluginMetadata.fromJson(Map<String, dynamic> json) {
    return PluginMetadata(
      id: json['id'] as String? ?? '',
      name: json['name'] as String? ?? 'Unknown Plugin',
      vendor: json['vendor'] as String? ?? '',
      version: json['version'] as String? ?? '',
      category: json['category'] as String? ?? '',
      bundleName: json['bundleName'] as String? ?? '',
      description: json['description'] as String? ?? '',
      format: PluginFormat.fromString(json['format'] as String? ?? ''),
      path: json['path'] as String? ?? '',
      isCompatible: json['isCompatible'] as bool? ?? true,
      errorMessage: json['errorMessage'] as String? ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'vendor': vendor,
    'version': version,
    'category': category,
    'bundleName': bundleName,
    'description': description,
    'format': format.label,
    'path': path,
    'isCompatible': isCompatible,
    'errorMessage': errorMessage,
  };

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PluginMetadata &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          id == other.id;

  @override
  int get hashCode => path.hashCode ^ id.hashCode;

  /// 复制并覆盖部分字段（厂商表填充 vendor 用）。
  PluginMetadata copyWith({String? vendor}) => PluginMetadata(
    id: id,
    name: name,
    vendor: vendor ?? this.vendor,
    version: version,
    category: category,
    bundleName: bundleName,
    description: description,
    format: format,
    path: path,
    isCompatible: isCompatible,
    errorMessage: errorMessage,
  );
}

/// 宿主当前激活状态
class PluginHostStatus {
  final bool hasActive;
  final bool bypassed;
  final int latency;
  final int processCalls;
  final double inRms;
  final double outRms;
  final double maxDiff;
  final int lastFrames;
  final PluginMetadata? plugin;
  final bool remoteMode;
  final bool remoteFailed;
  final int transportLatency;
  final int inputOverflows;
  final int outputOverflows;
  final int channels;
  final int mainInChannels;
  final int mainOutChannels;

  const PluginHostStatus({
    this.hasActive = false,
    this.bypassed = false,
    this.latency = 0,
    this.processCalls = 0,
    this.inRms = 0,
    this.outRms = 0,
    this.maxDiff = 0,
    this.lastFrames = 0,
    this.plugin,
    this.remoteMode = false,
    this.remoteFailed = false,
    this.transportLatency = 0,
    this.inputOverflows = 0,
    this.outputOverflows = 0,
    this.channels = 0xFF,
    this.mainInChannels = 2,
    this.mainOutChannels = 2,
  });

  static const empty = PluginHostStatus();

  factory PluginHostStatus.fromJson(Map<String, dynamic> json) {
    PluginMetadata? meta;
    if (json['plugin'] != null && json['plugin'] is Map) {
      meta = PluginMetadata.fromJson(
        Map<String, dynamic>.from(json['plugin'] as Map),
      );
    }
    final busInfo = json['busInfo'] as Map?;
    return PluginHostStatus(
      hasActive: json['hasActive'] as bool? ?? false,
      bypassed: json['bypassed'] as bool? ?? false,
      latency: (json['latency'] as num?)?.toInt() ?? 0,
      processCalls: (json['processCalls'] as num?)?.toInt() ?? 0,
      inRms: (json['inRms'] as num?)?.toDouble() ?? 0,
      outRms: (json['outRms'] as num?)?.toDouble() ?? 0,
      maxDiff: (json['maxDiff'] as num?)?.toDouble() ?? 0,
      lastFrames: (json['lastFrames'] as num?)?.toInt() ?? 0,
      plugin: meta,
      remoteMode: json['remoteMode'] as bool? ?? false,
      remoteFailed: json['remoteFailed'] as bool? ?? false,
      transportLatency: (json['transportLatency'] as num?)?.toInt() ?? 0,
      inputOverflows: (json['inputOverflows'] as num?)?.toInt() ?? 0,
      outputOverflows: (json['outputOverflows'] as num?)?.toInt() ?? 0,
      channels: (json['channels'] as num?)?.toInt() ?? 0xFF,
      mainInChannels: (busInfo?['mainInChannels'] as num?)?.toInt() ?? 2,
      mainOutChannels: (busInfo?['mainOutChannels'] as num?)?.toInt() ?? 2,
    );
  }

  Map<String, dynamic> toJson() => {
    'hasActive': hasActive,
    'bypassed': bypassed,
    'latency': latency,
    'processCalls': processCalls,
    'inRms': inRms,
    'outRms': outRms,
    'maxDiff': maxDiff,
    'lastFrames': lastFrames,
    'plugin': plugin?.toJson(),
    'remoteMode': remoteMode,
    'remoteFailed': remoteFailed,
    'transportLatency': transportLatency,
    'inputOverflows': inputOverflows,
    'outputOverflows': outputOverflows,
    'channels': channels,
    'mainInChannels': mainInChannels,
    'mainOutChannels': mainOutChannels,
  };
}

/// 插入阶段定义与友好描述
abstract final class PluginInsertStage {
  static const preDsp = 0;
  static const preVendor = 1;
  static const postVendor = 2;
  static const postReverb = 3;
  static const postLimiter = 4;

  static const defaultStage = postReverb;

  static String labelOf(int stage) {
    switch (stage) {
      case preDsp:
        return '输入前置 (Pre-DSP)';
      case preVendor:
        return '音效前置 (Pre-Vendor)';
      case postVendor:
        return '音效后置 (Post-Vendor)';
      case postReverb:
        return '混响后置 (Post-Reverb)';
      case postLimiter:
        return '总输出级 (Post-Limiter)';
      default:
        return '阶段 $stage';
    }
  }

  static String shortLabelOf(int stage) {
    switch (stage) {
      case preDsp:
        return 'Pre-DSP';
      case preVendor:
        return 'Pre-Vendor';
      case postVendor:
        return 'Post-Vendor';
      case postReverb:
        return 'Post-Reverb';
      case postLimiter:
        return 'Post-Limit';
      default:
        return 'Stage $stage';
    }
  }
}

/// 插件指令派发回调函数类型
