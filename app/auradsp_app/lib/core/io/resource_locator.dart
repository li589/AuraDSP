// resource_locator.dart — 安装/配置/资源目录的统一候选顺序。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §5.3。
// 原 PathMemory.fallbackDir 的探测逻辑迁至此，避免各功能各自拼 exe 旁路径。
import 'dart:io';

import '../../platform/platform_profile.dart';
import '../config.dart';
import '../error_sink.dart';

abstract final class ResourceLocator {
  /// `resources/{subFolder}` 的候选目录（按优先级）：
  /// exe 旁 resources → exe 旁 assets → 配置中心 resources → 配置中心子目录
  /// → 工程 assets → 仓库 assets。
  static List<String> candidateDirs(String subFolder) {
    if (subFolder.isEmpty) return const [];
    final sep = Platform.pathSeparator;
    final exeDir = PlatformProfile.executableDir;
    final resources = ['resources', subFolder].join(sep);
    final assets = ['assets', subFolder].join(sep);
    return [
      '$exeDir$sep$resources',
      '$exeDir$sep$assets',
      ConfigManager.path(resources),
      ConfigManager.path(subFolder),
      assets,
      ['..', '..', 'assets', subFolder].join(sep),
    ];
  }

  /// 第一个真实存在的目录；都不存在返回 null。
  static String? firstExistingDirectory(Iterable<String> candidates) {
    for (final p in candidates) {
      try {
        final d = Directory(p);
        if (d.existsSync()) return d.path;
      } catch (e, st) {
        swallow(e, st);
      }
    }
    return null;
  }
}
