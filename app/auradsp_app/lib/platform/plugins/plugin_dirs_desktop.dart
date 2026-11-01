// plugin_dirs_desktop.dart — macOS / Linux 插件扫描目录发现。
import 'dart:io';

import '../../core/plugins/plugin_scan_dirs.dart';
import '../platform_profile.dart';
import '../port/plugin_dirs.dart';

final class DesktopPluginDirs implements PluginDirsPort {
  const DesktopPluginDirs();

  @override
  List<String> discover({Map<String, String>? env}) {
    final os = PlatformProfile.os;
    if (os != 'macos' && os != 'linux') return const [];

    final e = env ?? Platform.environment;
    final candidates = <String>[];
    final sep = Platform.pathSeparator;

    void add(String? base, String leaf) {
      if (base == null || base.isEmpty) return;
      candidates.add('$base$sep$leaf');
    }

    if (os == 'macos') {
      const sys = '/Library/Audio/Plug-Ins';
      final home = e['HOME'];
      for (final leaf in const ['VST3', 'CLAP', 'VST', 'Components']) {
        add(sys, leaf);
        if (home != null && home.isNotEmpty) {
          candidates.add('$home/Library/Audio/Plug-Ins/$leaf');
        }
      }
    } else {
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

    return PluginScanDirs.discoverFrom(candidates);
  }
}
