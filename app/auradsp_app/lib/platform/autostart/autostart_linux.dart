// autostart_linux.dart — AutoStartPort 的 Linux 实现（XDG autostart）。
//
// freedesktop Autostart 规范：把 .desktop 文件放进
// $XDG_CONFIG_HOME/autostart/（未设时 ~/.config/autostart/），桌面环境
// 登录时按 Exec 启动；删除文件即关闭。enabled 以文件存在为准。
// Exec 指向当前可执行文件（Platform.resolvedExecutable），追加 --tray 参数以托盘静默启动。
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

import '../../core/error_sink.dart';
import '../platform_profile.dart';
import '../port/autostart.dart';

/// Exec 参数的 desktop-entry 转义（纯函数，边界审查 2026-11-02）：
/// 可执行路径被双引号包裹时，路径内的反斜杠、双引号、反引号、$
/// 必须反斜杠转义，否则路径含这些字符会破坏条目、或被登录会话
/// 的解析器当作变量展开。常规安装路径不含这些字符，此为防御性
/// 收敛。
String desktopExecArg(String executablePath) {
  final escaped = executablePath
      .replaceAll(r'\', r'\\')
      .replaceAll('"', r'\"')
      .replaceAll('`', r'\`')
      .replaceAll(r'$', r'\$');
  return '"$escaped"';
}

final class LinuxAutoStart implements AutoStartPort {
  LinuxAutoStart() {
    _enabledNotifier = ValueNotifier<bool>(enabled ?? false);
  }

  late final ValueNotifier<bool> _enabledNotifier;

  @override
  bool get available => PlatformProfile.os == 'linux';

  @override
  ValueListenable<bool> get enabledListenable => _enabledNotifier;

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
        _enabledNotifier.value = false;
        return true;
      }
      file.parent.createSync(recursive: true);
      final exec = Platform.resolvedExecutable;
      file.writeAsStringSync(
        '[Desktop Entry]\n'
        'Type=Application\n'
        'Name=AuraDSP\n'
        'Exec=${desktopExecArg(exec)} --tray\n'
        'Icon=auradsp\n'
        'Terminal=false\n'
        'X-GNOME-Autostart-enabled=true\n',
      );
      final ok = file.existsSync();
      _enabledNotifier.value = ok;
      return ok;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }
}
