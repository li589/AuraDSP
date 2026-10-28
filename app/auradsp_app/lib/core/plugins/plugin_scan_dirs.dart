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

/// 平台预置目录发现。只返回**当前设备真实存在**的目录（规范化、去重）。
///
/// Windows：VST3/CLAP 标准共享目录 + 用户级目录 + VST2 常见目录（为未来
/// 32 位/VST2 支持预留，注册表 HKLM/HKCU\SOFTWARE\VST 的 VSTPluginsPath
/// 一并探测——读不到就跳过，绝不让发现流程抛错）。
/// Linux：/usr/lib、/usr/local/lib、~\\.{vst3,clap,lv2,vst} 等。
/// macOS：/Library/Audio/Plug-Ins 与 ~/Library/Audio/Plug-Ins 下的
/// VST3/CLAP/VST/Components（AU，预留）。
abstract final class PluginScanDirs {
  /// 平台预置候选（按平台特性枚举；存在性过滤在 [discover] 内做）。
  static List<String> discover({Map<String, String>? env}) {
    final e = env ?? Platform.environment;
    final candidates = <String>[];
    final sep = Platform.pathSeparator;

    void add(String? base, String leaf) {
      if (base == null || base.isEmpty) return;
      candidates.add('$base$sep$leaf');
    }

    if (Platform.isWindows) {
      final common = e['CommonProgramFiles'] ??
          r'C:\Program Files\Common Files';
      final programFiles = e['ProgramFiles'] ?? r'C:\Program Files';
      final programFilesX86 = e['ProgramFiles(x86)'] ??
          r'C:\Program Files (x86)';
      final localApp = e['LOCALAPPDATA'];
      final appData = e['APPDATA'];

      // VST3 / CLAP：共享 + 用户级（插件安装器的事实标准位置）。
      add(common, 'VST3');
      add(common, 'CLAP');
      if (localApp != null) {
        candidates.add('$localApp\\Programs\\Common\\VST3');
        candidates.add('$localApp\\Programs\\Common\\CLAP');
        candidates.add('$localApp\\Programs\\Common\\VST2');
      }
      // 旧式 VST2 目录（未来格式，先入列表便于用户统一管理）。
      add(programFiles, 'VstPlugins');
      add(programFiles, 'Steinberg${sep}VSTPlugins');
      add(programFilesX86, 'VstPlugins');
      add(programFilesX86, 'Steinberg${sep}VSTPlugins');
      if (appData != null) candidates.add('$appData\\VST3');
      // 注册表（HKLM/HKCU\SOFTWARE\VST 的 VSTPluginsPath 值）——Best-effort：
      // reg.exe 查询失败（无权限/无该项）静默跳过。
      candidates.addAll(_registryVstPluginDirs());
    } else if (Platform.isMacOS) {
      const sys = '/Library/Audio/Plug-Ins';
      final home = e['HOME'];
      for (final leaf in const ['VST3', 'CLAP', 'VST', 'Components']) {
        add(sys, leaf);
        if (home != null && home.isNotEmpty) {
          candidates.add('$home/Library/Audio/Plug-Ins/$leaf');
        }
      }
    } else {
      // Linux 及其它类 Unix。
      const sysDirs = [
        '/usr/lib/vst3',
        '/usr/local/lib/vst3',
        '/usr/lib/clap',
        '/usr/local/lib/clap',
        '/usr/lib/lv2',
        '/usr/local/lib/lv2',
        '/usr/lib/vst',
        '/usr/local/lib/vst',
      ];
      candidates.addAll(sysDirs);
      final home = e['HOME'];
      if (home != null && home.isNotEmpty) {
        for (final leaf in const ['vst3', 'clap', 'lv2', 'vst']) {
          candidates.add('$home/.$leaf');
        }
      }
    }

    return discoverFrom(candidates);
  }

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
  static String _dedupeKey(String path) =>
      Platform.isWindows ? path.toLowerCase() : path;

  static bool _isDirectory(String path) {
    try {
      return Directory(path).existsSync();
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 读 HKLM/HKCU\SOFTWARE\VST 下各子键的 VSTPluginsPath（VST2 安装器惯例）。
  /// 完全 best-effort：任何失败（无 reg.exe / 无权限 / 无该项）返回空表。
  static List<String> _registryVstPluginDirs() {
    if (!Platform.isWindows) return const [];
    final out = <String>[];
    for (final root in const ['HKLM', 'HKCU']) {
      try {
        final r = Process.runSync('reg', [
          'query',
          '$root\\SOFTWARE\\VST',
          '/s',
          '/v',
          'VSTPluginsPath',
        ], runInShell: false);
        if (r.exitCode != 0) continue;
        final text = r.stdout.toString();
        // 输出形如 `    VSTPluginsPath    REG_SZ    D:\VST\Plugins`
        for (final line in text.split(RegExp(r'\r?\n'))) {
          final idx = line.indexOf('REG_SZ');
          if (idx < 0) continue;
          final value = line.substring(idx + 'REG_SZ'.length).trim();
          if (value.isNotEmpty) out.add(value);
        }
      } catch (e, st) {
        // 注册表探测是尽力而为，不参与任何错误上报。
        swallow(e, st);
      }
    }
    return out;
  }
}
