// autostart_linux.dart — AutoStartPort 的 Linux 实现（XDG autostart）。
//
// freedesktop Autostart 规范：把 .desktop 文件放进
// $XDG_CONFIG_HOME/autostart/（未设时 ~/.config/autostart/），桌面环境
// 登录时按 Exec 启动；删除文件即关闭。enabled 以文件存在为准。
// Exec 指向当前可执行文件（Platform.resolvedExecutable），开发态
// 与打包 bundle 都是真实二进制路径，无需安装期登记。
import 'dart:io';

import '../../core/error_sink.dart';
import '../platform_profile.dart';
import '../port/autostart.dart';

final class LinuxAutoStart implements AutoStartPort {
  @override
  bool get available => PlatformProfile.os == 'linux';

  /// autostart 目录：$XDG_CONFIG_HOME/autostart（经
  /// PlatformProfile.xdgConfigHome 与 configDir 同源派生，规则不漂移）。
  static String get _autostartDir =>
      '${PlatformProfile.xdgConfigHome}${Platform.pathSeparator}autostart';

  static String get _desktopPath =>
      '$_autostartDir${Platform.pathSeparator}auradsp.desktop';

  @override
  bool? get enabled {
    if (!available) return null;
    try {
      return File(_desktopPath).existsSync();
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  @override
  bool setEnabled(bool on) {
    if (!available) return false;
    try {
      final file = File(_desktopPath);
      if (!on) {
        if (file.existsSync()) file.deleteSync();
        return true;
      }
      file.parent.createSync(recursive: true);
      final exec = Platform.resolvedExecutable;
      file.writeAsStringSync(
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=AuraDSP\n'
        'Exec="$exec"\n'
        'Icon=auradsp\n'
        'Terminal=false\n'
        'X-GNOME-Autostart-enabled=true\n',
      );
      return file.existsSync();
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }
}
