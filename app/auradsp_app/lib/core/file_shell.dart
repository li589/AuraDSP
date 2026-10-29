// file_shell.dart —— 系统文件管理器打开路径（跨平台，失败静默）。
//
// M4：原 plugins/plugin_scan_dirs.dart 与 liveprog 库对话框各有一份平台分支实现，
// 收敛到 core 单一实现；平台判定只经 PlatformProfile，业务文件不再出现 Platform.is*。
import 'dart:io';

import '../platform/platform_profile.dart';
import 'error_sink.dart';

Future<void> openInFileManager(String path) async {
  try {
    switch (PlatformProfile.os) {
      case 'windows':
        await Process.run('explorer.exe', [path]);
      case 'macos':
        await Process.run('open', [path]);
      default:
        await Process.run('xdg-open', [path]);
    }
  } catch (e, st) {
    swallow(e, st);
  }
}
