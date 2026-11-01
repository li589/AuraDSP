// autostart_windows.dart — AutoStartPort 的 Windows 实现（HKCU Run）。
//
// 原 core/tray_service.dart 的 AutoStartService 迁移至此：
// nativeapi 的 LaunchAtLogin 内部即 HKCU\...\Run，注册表语义只在本文件内。
import 'package:nativeapi/nativeapi.dart' show LaunchAtLogin;

import '../../core/error_sink.dart';
import '../platform_profile.dart';
import '../port/autostart.dart';

final class WindowsAutoStart implements AutoStartPort {
  LaunchAtLogin? _handle;

  @override
  bool get available => PlatformProfile.os == 'windows';

  bool _ensure() {
    if (!available) return false;
    try {
      _handle ??= LaunchAtLogin.createWithIdAndDisplayName(
        'com.auradsp.app',
        'AuraDSP',
      );
      return _handle != null;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  @override
  bool? get enabled {
    if (!_ensure()) return null;
    try {
      return _handle!.isEnabled;
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  @override
  bool setEnabled(bool on) {
    if (!_ensure()) return false;
    try {
      return on ? _handle!.enable() : _handle!.disable();
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }
}
