// autostart_windows.dart — AutoStartPort 的 Windows 实现（HKCU Run，带 --tray 静默托盘参数）。
//
// 使用 WindowsRegistry 操作注册表 HKCU\Software\Microsoft\Windows\CurrentVersion\Run：
// 启动命令形如 "\"C:\...\auradsp_app.exe\" --tray"，使开机自启静默运行为托盘图标。
import 'dart:io';

import 'package:flutter/foundation.dart' show ValueListenable, ValueNotifier;

import '../../core/error_sink.dart';
import '../platform_profile.dart';
import '../port/autostart.dart';
import '../port/registry.dart';

final class WindowsAutoStart implements AutoStartPort {
  WindowsAutoStart(this._registry) {
    _enabledNotifier = ValueNotifier<bool>(enabled ?? false);
  }

  final RegistryPort _registry;
  late final ValueNotifier<bool> _enabledNotifier;

  static const String _runKey =
      r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run';
  static const String _valueName = 'AuraDSP';
  static const String _legacyValueName = 'com.auradsp.app';

  @override
  bool get available => PlatformProfile.os == 'windows';

  @override
  ValueListenable<bool> get enabledListenable => _enabledNotifier;

  @override
  bool? get enabled {
    if (!available) return null;
    try {
      final val = _registry.readString(_runKey, _valueName) ??
          _registry.readString(_runKey, _legacyValueName);
      return val != null && val.isNotEmpty;
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  @override
  bool setEnabled(bool on) {
    if (!available) return false;
    try {
      if (!on) {
        _registry.deleteValue(_runKey, _valueName);
        _registry.deleteValue(_runKey, _legacyValueName);
        _enabledNotifier.value = false;
        return true;
      }
      final exec = Platform.resolvedExecutable;
      // 写入带双引号且追加 --tray 的命令行
      final cmd = '"$exec" --tray';
      final ok = _registry.writeString(_runKey, _valueName, cmd);
      // 清理无参数的旧版注册表项
      _registry.deleteValue(_runKey, _legacyValueName);
      if (ok) {
        _enabledNotifier.value = true;
      }
      return ok;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }
}
