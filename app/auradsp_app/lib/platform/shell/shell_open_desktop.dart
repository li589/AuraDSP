// shell_open_desktop.dart — 桌面平台（Windows/macOS/Linux）文件管理器打开。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §4。
// 原 core/file_shell.dart 迁移至此：平台判定只经 PlatformProfile。
import 'dart:io';

import '../../core/error_sink.dart';
import '../platform_profile.dart';
import '../port/shell_open.dart';

final class DesktopShellOpen implements ShellOpenPort {
  const DesktopShellOpen();

  @override
  Future<bool> openPath(String path) async {
    try {
      switch (PlatformProfile.os) {
        case 'windows':
          // explorer 成功时也可能返回非 0，进程能拉起即视为成功。
          await Process.run('explorer.exe', [path]);
          return true;
        case 'macos':
          final res = await Process.run('open', [path]);
          return res.exitCode == 0;
        case 'linux':
          final res = await Process.run('xdg-open', [path]);
          return res.exitCode == 0;
        default:
          return false;
      }
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  @override
  Future<bool> openUrl(String url) async {
    try {
      switch (PlatformProfile.os) {
        case 'windows':
          // explorer 拉起进程即视为成功（同 openPath 口径）；URL 交由
          // 系统默认浏览器接管。
          await Process.run('explorer.exe', [url]);
          return true;
        case 'macos':
          final res = await Process.run('open', [url]);
          return res.exitCode == 0;
        case 'linux':
          final res = await Process.run('xdg-open', [url]);
          return res.exitCode == 0;
        default:
          return false;
      }
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }
}
