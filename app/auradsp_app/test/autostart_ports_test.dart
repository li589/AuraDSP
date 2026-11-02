import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/ports/null_ports.dart';
import 'package:auradsp_app/platform/autostart/autostart_linux.dart';
import 'package:auradsp_app/platform/autostart/autostart_windows.dart';
import 'package:auradsp_app/platform/platform_profile.dart';
import 'package:auradsp_app/platform/port/registry.dart';

class _MockRegistry implements RegistryPort {
  final Map<String, String> values = {};

  @override
  bool get available => true;

  @override
  bool keyExists(String keyPath) => true;

  @override
  String? readString(String keyPath, String valueName) =>
      values['$keyPath\\$valueName'];

  @override
  List<String> readStringValues(String keyPath,
      {String? valueName, bool recursive = true}) {
    final v = readString(keyPath, valueName ?? '');
    return v != null ? [v] : [];
  }

  @override
  bool writeString(String keyPath, String valueName, String value) {
    values['$keyPath\\$valueName'] = value;
    return true;
  }

  @override
  bool deleteValue(String keyPath, String valueName) {
    values.remove('$keyPath\\$valueName');
    return true;
  }
}

void main() {
  group('AutoStart Ports Tests', () {
    test('NullAutoStart invariants', () {
      const nullStart = NullAutoStart();
      expect(nullStart.available, isFalse);
      expect(nullStart.enabled, isNull);
      expect(nullStart.enabledListenable.value, isFalse);
      expect(nullStart.setEnabled(true), isFalse);
    });

    test('desktopExecArg escaping', () {
      expect(desktopExecArg(r'/usr/bin/auradsp'), equals(r'"/usr/bin/auradsp"'));
      expect(desktopExecArg(r'/opt/app"name"/bin'),
          equals(r'"/opt/app\"name\"/bin"'));
      expect(desktopExecArg(r'/opt/$var/bin'), equals(r'"/opt/\$var/bin"'));
    });

    test('WindowsAutoStart writes --tray argument to registry and notifies listener', () {
      final reg = _MockRegistry();
      final autostart = WindowsAutoStart(reg);

      if (PlatformProfile.os == 'windows') {
        expect(autostart.available, isTrue);
        expect(autostart.enabled, isFalse);
        expect(autostart.enabledListenable.value, isFalse);

        // 模拟旧版注册表项存在时可读取
        reg.writeString(
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
            'com.auradsp.app',
            'legacy_path.exe');
        expect(autostart.enabled, isTrue);

        // 开启自启：写入新 AuraDSP 且带 --tray，同时清理旧条目
        expect(autostart.setEnabled(true), isTrue);
        expect(autostart.enabled, isTrue);
        expect(autostart.enabledListenable.value, isTrue);
        final runCmd = reg.readString(
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run', 'AuraDSP');
        expect(runCmd, isNotNull);
        expect(runCmd, contains('--tray'));
        expect(reg.readString(
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run',
            'com.auradsp.app'), isNull);

        // 关闭自启
        expect(autostart.setEnabled(false), isTrue);
        expect(autostart.enabled, isFalse);
        expect(autostart.enabledListenable.value, isFalse);
        expect(reg.readString(
            r'HKCU\Software\Microsoft\Windows\CurrentVersion\Run', 'AuraDSP'),
            isNull);
      }
    });
  });
}

