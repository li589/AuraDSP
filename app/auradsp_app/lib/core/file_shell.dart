// file_shell.dart —— 系统文件管理器打开路径（跨平台，失败静默）。
//
// M4：原 plugins/plugin_scan_dirs.dart 与 liveprog 库对话框各有一份平台分支实现，
// 收敛到 core 单一实现；平台判定只经 PlatformProfile，业务文件不再出现 Platform.is*。
import 'dart:io';

import '../platform/platform_profile.dart';
import 'error_sink.dart';

Future<void> openInFileManager(String path) async {
  try {
    // R5（M6 审查遗留）：default 收窄为仅 linux——旧实现对 os == 'other'
    // 也执行 xdg-open（Linux 专用命令），在未知桌面平台必然失败；
    // 其余未知平台直接返回失败（不发进程）。
    switch (PlatformProfile.os) {
      case 'windows':
        await Process.run('explorer.exe', [path]);
      case 'macos':
        await Process.run('open', [path]);
      case 'linux':
        await Process.run('xdg-open', [path]);
      default:
        throw UnsupportedError(
          'openInFileManager: unsupported os "${PlatformProfile.os}"',
        );
    }
  } catch (e, st) {
    swallow(e, st);
  }
}
