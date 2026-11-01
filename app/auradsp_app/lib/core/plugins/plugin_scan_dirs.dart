// plugin_scan_dirs.dart —— 插件扫描目录模型 + 平台预置目录发现。
//
// 产品口径（2026-10-28，用户定案）：
// - 不再存在「隐式默认目录」：所有被扫描的目录都是列表里的显式条目，
//   用户可见、可勾选/取消、可移除（内置目录除外）。
// - 平台预置目录在首次进入时按当前设备实况发现（目录必须真实存在），
//   作为普通条目加入列表（enabled=true）。
// - 随应用分发的插件目录（未来自带开源/自研插件）由 AppModel 创建并作为
//   builtin 条目加入，UI 禁止移除。
//
// 本文件只依赖 dart:io 与 Dart 标准库，不 import config.dart（避免循环），
// 内置目录路径由调用方传入（ConfigManager 计算）。
import 'dart:io';

import '../error_sink.dart';
import '../../platform/platform_profile.dart';

/// 一条扫描目录。`enabled` = 参与扫描；`builtin` = 应用自带、不可移除。
class PluginScanDirEntry {
  final String path;
  final bool enabled;
  final bool builtin;

  const PluginScanDirEntry({
    required this.path,
    this.enabled = true,
    this.builtin = false,
  });

  PluginScanDirEntry copyWith({bool? enabled, bool? builtin}) =>
      PluginScanDirEntry(
        path: path,
        enabled: enabled ?? this.enabled,
        builtin: builtin ?? this.builtin,
      );

  Map<String, dynamic> toJson() => {
        'path': path,
        'enabled': enabled,
        'builtin': builtin,
      };

  factory PluginScanDirEntry.fromJson(Map<String, dynamic> json) {
    return PluginScanDirEntry(
      path: (json['path'] as String?) ?? '',
      enabled: (json['enabled'] as bool?) ?? true,
      builtin: (json['builtin'] as bool?) ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PluginScanDirEntry &&
      other.path == path &&
      other.enabled == enabled &&
      other.builtin == builtin;

  @override
  int get hashCode => Object.hash(path, enabled, builtin);
}

/// 插件扫描目录模型与通用过滤。
///
/// 平台预置目录发现已迁至 `lib/platform/plugins/plugin_dirs_*.dart`
/// （方案：APP-目录重组与平台适配层方案-2026-11-01 §6）；本文件只保留
/// 平台无关的条目模型、存在性过滤、规范化与去重。
abstract final class PluginScanDirs {
  /// 存在性过滤 + 规范化 + 去重（保留发现顺序）。
  static List<String> discoverFrom(Iterable<String> candidates) {
    final out = <String>[];
    final seen = <String>{};
    for (final c in candidates) {
      final normalized = _normalize(c);
      if (normalized.isEmpty) continue;
      if (!seen.add(_dedupeKey(normalized))) continue;
      final ok = _isDirectory(normalized);
      if (!ok) continue;
      out.add(normalized);
    }
    return out;
  }

  static String _normalize(String path) => path.trim().replaceAll('/', Platform.pathSeparator).replaceAll(RegExp(r'[\\/]+$'), '');

  /// Windows 路径大小写不敏感；其余平台敏感（只折叠分隔符差异）。
  static String _dedupeKey(String path) => PlatformProfile.pathKey(path);

  static bool _isDirectory(String path) {
    try {
      return Directory(path).existsSync();
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }
}
