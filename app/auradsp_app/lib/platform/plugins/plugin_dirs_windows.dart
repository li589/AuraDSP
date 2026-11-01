// plugin_dirs_windows.dart — Windows 插件扫描目录发现。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §6。
// 原 core/plugins/plugin_scan_dirs.dart 的 Windows 分支 + 注册表探测迁至此。
import 'dart:io';

import '../../core/plugins/plugin_scan_dirs.dart';
import '../platform_profile.dart';
import '../port/plugin_dirs.dart';
import '../port/registry.dart';

final class WindowsPluginDirs implements PluginDirsPort {
  final RegistryPort registry;

  const WindowsPluginDirs(this.registry);

  @override
  List<String> discover({Map<String, String>? env}) {
    if (PlatformProfile.os != 'windows') return const [];

    final e = env ?? Platform.environment;
    final candidates = <String>[];
    final sep = Platform.pathSeparator;

    void add(String? base, String leaf) {
      if (base == null || base.isEmpty) return;
      candidates.add('$base$sep$leaf');
    }

    // 兜底不写死盘符（系统盘可能不是 C:）：一律由 SystemDrive/SystemRoot
    // 派生。两者都拿不到就给 null，add() 跳过。
    final drive = _systemDrive(e);
    String? underDrive(String leaf) => drive == null ? null : '$drive\\$leaf';
    final common = e['CommonProgramFiles'] ??
        underDrive(r'Program Files\Common Files');
    final programFiles = e['ProgramFiles'] ?? underDrive('Program Files');
    final programFilesX86 =
        e['ProgramFiles(x86)'] ?? underDrive('Program Files (x86)');
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

    // 注册表（HKLM/HKCU\SOFTWARE\VST 的 VSTPluginsPath 值）——Best-effort。
    candidates.addAll(registry.readStringValues(
      r'HKLM\SOFTWARE\VST',
      valueName: 'VSTPluginsPath',
    ));
    candidates.addAll(registry.readStringValues(
      r'HKCU\SOFTWARE\VST',
      valueName: 'VSTPluginsPath',
    ));

    return PluginScanDirs.discoverFrom(candidates);
  }

  /// 系统盘根（形如 `C:`）。优先 `SystemDrive`，其次从 `SystemRoot`
  /// （`C:\Windows`）截取；两者都缺失返回 null——不猜盘符。
  static String? _systemDrive(Map<String, String> env) {
    var sd = (env['SystemDrive'] ?? '').trim();
    while (sd.endsWith('\\') || sd.endsWith('/')) {
      sd = sd.substring(0, sd.length - 1);
    }
    if (RegExp(r'^[A-Za-z]:$').hasMatch(sd)) return sd.toUpperCase();
    final sr = (env['SystemRoot'] ?? '').trim();
    final m = RegExp(r'^([A-Za-z]:)\\').firstMatch(sr);
    return m?.group(1)?.toUpperCase();
  }

  /// 只读壳，供单元测试钉住「不写死盘符」这条不变量。
  static String? systemDriveForTest(Map<String, String> env) =>
      _systemDrive(env);
}
