// xdg_paths_test.dart — S5b XDG 目录拆分的单元断言。
//
// PlatformProfile 的 getter 读进程环境，本测试按「启动时环境」自适应：
// CI/默认环境下断言不变量（绝对路径、auradsp 结尾、HOME 派生）；
// 以 XDG_CONFIG_HOME / XDG_DATA_HOME 启动时额外断言精确落点。
// LinuxAutoStart 同理在 XDG_CONFIG_HOME 指向临时目录时实测 .desktop
// 文件的写入/查询/删除（默认环境下跳过文件断言，避免触碰真实目录）。
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/platform/autostart/autostart_linux.dart';
import 'package:auradsp_app/platform/platform_profile.dart';

void main() {
  group('PlatformProfile XDG dirs', () {
    test('configDir/dataDir are absolute auradsp roots', () {
      for (final dir in [PlatformProfile.configDir, PlatformProfile.dataDir]) {
        expect(dir, startsWith('/'), reason: dir);
        expect(dir.split(Platform.pathSeparator).last, 'auradsp');
        expect(dir, isNot(startsWith('.')));
      }
    });

    test('XDG env vars are honored when set', () {
      final xdgConfig = Platform.environment['XDG_CONFIG_HOME'];
      final xdgData = Platform.environment['XDG_DATA_HOME'];
      if (xdgConfig != null && xdgConfig.startsWith('/')) {
        expect(PlatformProfile.configDir, '$xdgConfig/auradsp');
        expect(PlatformProfile.xdgConfigHome, xdgConfig);
      }
      if (xdgData != null && xdgData.startsWith('/')) {
        expect(PlatformProfile.dataDir, '$xdgData/auradsp');
      }
    });

    test('test sandbox keeps dataDir == baseDir', () {
      // 单测沙箱下两根同指临时目录：存量断言（按 baseDir 定位数据文件）
      // 不因 XDG 拆分而失效；真实运行才分开。
      expect(ConfigManager.dataDir, ConfigManager.baseDir);
    });
  });

  group('LinuxAutoStart (XDG autostart)', () {
    test('writes, reports and removes the .desktop entry', () {
      if (!Platform.isLinux) return;
      final xdgConfig = Platform.environment['XDG_CONFIG_HOME'];
      // 只在 XDG_CONFIG_HOME 被重定向（测试沙箱）时做文件断言。
      if (xdgConfig == null || !xdgConfig.startsWith('/tmp')) return;
      final port = LinuxAutoStart();
      expect(port.available, isTrue);
      expect(port.setEnabled(true), isTrue);
      final file = File('$xdgConfig/autostart/auradsp.desktop');
      expect(file.existsSync(), isTrue);
      final content = file.readAsStringSync();
      expect(content, contains('[Desktop Entry]'));
      expect(content, contains('Exec='));
      expect(port.enabled, isTrue);
      expect(port.setEnabled(false), isTrue);
      expect(file.existsSync(), isFalse);
      expect(port.enabled, isFalse);
    });
  });
}
