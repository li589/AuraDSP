import 'package:auradsp_setup/src/args.dart';
import 'package:auradsp_setup/src/engine/cleanup_policy.dart';
import 'package:auradsp_setup/src/engine/install_engine.dart';
import 'package:auradsp_setup/src/engine/models.dart';
import 'package:auradsp_setup/src/engine/payload.dart';
import 'package:auradsp_setup/src/engine/update_policy.dart';
import 'package:auradsp_setup/src/engine/win32.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('SetupArgs.parse', () {
    test('引导壳标准参数', () {
      final a = SetupArgs.parse([
        '--setup-exe', r'C:\dl\AuraDSP-Setup-x64-v0.1.0.exe',
        '--payload-off', '123456',
        '--payload-len', '7890',
        '--session-dir', r'C:\Temp\AuraDSP-Setup\ab12-34',
      ]);
      expect(a.mode, SetupMode.install);
      expect(a.hasPayload, isTrue);
      expect(a.payloadOff, 123456);
      expect(a.payloadLen, 7890);
      expect(a.silent, isFalse);
    });

    test('卸载模式与静默', () {
      final a = SetupArgs.parse(['--mode', 'uninstall', '/silent']);
      expect(a.mode, SetupMode.uninstall);
      expect(a.silent, isTrue);
      final b = SetupArgs.parse(['--uninstall']);
      expect(b.mode, SetupMode.uninstall);
    });

    test('缺参数不崩', () {
      final a = SetupArgs.parse([]);
      expect(a.hasPayload, isFalse);
    });
  });

  group('normalizeInstallDir（末段自动补 AuraDSP）', () {
    test('普通目录自动补、已有尾段保持不变', () {
      expect(normalizeInstallDir(r'D:\Games', r'C:\AuraDSP'),
          r'D:\Games\AuraDSP');
      expect(normalizeInstallDir(r'D:\Apps\AuraDSP', r'C:\AuraDSP'),
          r'D:\Apps\AuraDSP');
      expect(normalizeInstallDir(r'D:\Apps\auradsp', r'C:\AuraDSP'),
          r'D:\Apps\auradsp');
    });

    test('空串 / 盘符根 / 尾部斜杠 / 正斜杠 / UNC', () {
      expect(normalizeInstallDir('', r'C:\AuraDSP'), r'C:\AuraDSP');
      expect(normalizeInstallDir('   ', ''), r'C:\AuraDSP');
      expect(normalizeInstallDir('D:', r'C:\AuraDSP'), r'D:\AuraDSP');
      expect(normalizeInstallDir('D:\\', r'C:\AuraDSP'), r'D:\AuraDSP');
      expect(normalizeInstallDir(r'D:\Games\\\', r'C:\AuraDSP'),
          r'D:\Games\AuraDSP');
      expect(normalizeInstallDir('D:/Games/AuraDSP/', r'C:\AuraDSP'),
          r'D:\Games\AuraDSP');
      expect(normalizeInstallDir(r'\\server\share', r'C:\AuraDSP'),
          r'\\server\share\AuraDSP');
    });
  });

  group('compareVersion / planUpdate（更新语义）', () {
    test('4 段数字比较，缺段补零', () {
      expect(compareVersion('0.1.0.2', '0.1.0.1'), 1);
      expect(compareVersion('0.1.0.1', '0.1.0.1'), 0);
      expect(compareVersion('0.1.0', '0.1.0.1'), -1);
      expect(compareVersion('0.2.0.1', '0.10.0.1'), -1);
      expect(compareVersion('0.1.0+1', '0.1.0.1'), 0);
    });

    test('全新安装用用户目录并补尾段', () {
      final p = planUpdate(
          newFullVersion: '0.2.0.1',
          requestedDir: r'D:\Games',
          defaultDir: r'C:\AuraDSP');
      expect(p.mode, UpdateMode.fresh);
      expect(p.installDir, r'D:\Games\AuraDSP');
      expect(p.isOverwrite, isFalse);
    });

    test('升级沿用旧目录、拒绝借更新换位置', () {
      final p = planUpdate(
        newFullVersion: '0.2.0.1',
        requestedDir: r'Z:\Elsewhere',
        defaultDir: r'C:\AuraDSP',
        installed: InstalledInfo(
            fullVersion: '0.1.0.1', installDir: r'C:\Program Files\AuraDSP'),
      );
      expect(p.mode, UpdateMode.upgrade);
      expect(p.installDir, r'C:\Program Files\AuraDSP');
      expect(p.isOverwrite, isTrue);
      expect(p.previous?.fullVersion, '0.1.0.1');
    });

    test('同版本 = 修复，低版本 = 拦截', () {
      final repair = planUpdate(
          newFullVersion: '0.1.0.1',
          requestedDir: r'C:\AuraDSP',
          defaultDir: r'C:\AuraDSP',
          installed: const InstalledInfo(
              fullVersion: '0.1.0.1', installDir: r'C:\Apps\AuraDSP'));
      expect(repair.mode, UpdateMode.repair);
      expect(repair.isOverwrite, isTrue);
      final down = planUpdate(
          newFullVersion: '0.1.0.1',
          requestedDir: r'C:\AuraDSP',
          defaultDir: r'C:\AuraDSP',
          installed: const InstalledInfo(
              fullVersion: '0.9.0.1', installDir: r'C:\Apps\AuraDSP'));
      expect(down.mode, UpdateMode.downgradeBlocked);
      expect(down.isBlocked, isTrue);
    });
  });

  group('isUserPath（升级回滚保护）', () {
    test('用户数据不备份/不删除，程序文件可覆盖', () {
      expect(isUserPath('resources/user_data/my.vdc'), isTrue);
      expect(isUserPath('presets/jazz.aurapreset.json'), isTrue);
      expect(isUserPath('config.json'), isTrue);
      expect(isUserPath('install_manifest.json'), isTrue);
      expect(isUserPath('auradsp_app.exe'), isFalse);
      expect(isUserPath('driver/AuraVaioDriver.sys'), isFalse);
    });
  });

  group('parseRegQuery（已装实例探测）', () {
    test('解析含空格的路径与多种类型', () {
      const out = 'HKEY_CURRENT_USER\\Software\\AuraDSP\r\n'
          '    InstallDir    REG_SZ    C:\\Program Files\\AuraDSP\r\n'
          '    Version    REG_SZ    0.1.0.1\r\n'
          '    Flag    REG_DWORD    0x1\r\n';
      final v = parseRegQuery(out);
      expect(v['InstallDir'], r'C:\Program Files\AuraDSP');
      expect(v['Version'], '0.1.0.1');
      expect(v['Flag'], '0x1');
    });

    test('键不存在时为空表', () {
      expect(parseRegQuery('ERROR: The system was unable to find the specified registry key.'),
          isEmpty);
    });
  });

  group('InstallManifest', () {
    test('JSON 往返 + 体积估算', () {
      final m = InstallManifest(
        version: '0.1.0',
        fullVersion: '0.1.0.1',
        installDir: r'C:\Program Files\AuraDSP',
        allUsers: true,
        components: const ['app', 'asio'],
        files: const [
          ManifestFile(path: 'auradsp_app.exe', size: 2048, sha256: 'aa'),
          ManifestFile(path: 'data/x.bin', size: 1024, sha256: 'bb'),
        ],
        shortcuts: const [r'C:\Users\x\Desktop\AuraDSP.lnk'],
        installedAtIso: '2026-11-06T00:00:00',
      );
      final back = InstallManifest.decode(m.encode());
      expect(back.fullVersion, '0.1.0.1');
      expect(back.files.length, 2);
      expect(back.totalBytes, 3072);
      expect(back.estimatedSizeKb, 3);
      expect(back.components, ['app', 'asio']);
      expect(back.updateMode, 'fresh');
      expect(back.previousFullVersion, isNull);
    });

    test('升级字段写入与旧清单兼容', () {
      final upgraded = InstallManifest(
        version: '0.2.0',
        fullVersion: '0.2.0.1',
        installDir: r'C:\Program Files\AuraDSP',
        allUsers: true,
        components: const ['app'],
        files: const [],
        shortcuts: const [],
        installedAtIso: '2026-11-06T00:00:00',
        previousFullVersion: '0.1.0.1',
        updateMode: 'upgrade',
      );
      final back = InstallManifest.decode(upgraded.encode());
      expect(back.previousFullVersion, '0.1.0.1');
      expect(back.updateMode, 'upgrade');
      // 旧版清单没有新字段：按 fresh / null 兜底，不抛异常。
      final legacy = InstallManifest.decode(
          '{"version":"0.1.0","fullVersion":"0.1.0.1",'
          '"installDir":"C:\\\\Apps\\\\AuraDSP","allUsers":false,'
          '"components":["app"],"files":[],"shortcuts":[],"installedAt":"x"}');
      expect(legacy.updateMode, 'fresh');
      expect(legacy.previousFullVersion, isNull);
    });
  });

  group('uninstallValues（设计 §5.5）', () {
    test('字段齐备且口径正确', () {
      final v = InstallEngine.uninstallValues(
        installDir: r'C:\Program Files\AuraDSP',
        fullVersion: '0.1.0.1',
        estimatedSizeKb: 145000,
      );
      expect(v['DisplayName'], 'AuraDSP');
      expect(v['DisplayVersion'], '0.1.0.1');
      expect(v['UninstallString'], r'"C:\Program Files\AuraDSP\uninstall.exe"');
      expect(v['QuietUninstallString'],
          r'"C:\Program Files\AuraDSP\uninstall.exe" /silent');
      expect(v['URLInfoAbout'], 'https://github.com/li589/AuraDSP');
      expect(v['NoModify'], 1);
      expect(v['EstimatedSize'], 145000);
    });
  });

  group('componentFilter', () {
    test('driver/ 恒保留；DDC 仍按勾选门控', () {
      final f = componentFilter(ddcPresets: false);
      expect(f('auradsp_app.exe'), isTrue);
      expect(f('driver/AuraVaio.sys'), isTrue,
          reason: '不勾选 VAIO 也必须保留驱动与手动安装脚本');
      expect(f('driver/install_vaio.ps1'), isTrue);
      expect(f('resources/ddc/a.vdc'), isFalse);
      expect(f('resources/liveprog/a.eel'), isTrue);
      final g = componentFilter(ddcPresets: true);
      expect(g('driver/AuraVaio.sys'), isTrue);
      expect(g('resources/ddc/a.vdc'), isTrue);
    });
  });

  group('InstallOptions', () {
    test('JSON 往返（提权重启动协议）', () {
      final o = InstallOptions(installDir: r'D:\Apps\AuraDSP', allUsers: true, vaio: false);
      final back = InstallOptions.fromJson(o.toJson());
      expect(back.installDir, r'D:\Apps\AuraDSP');
      expect(back.allUsers, isTrue);
      expect(back.vaio, isFalse);
      expect(back.asio, isTrue);
    });

    test('升级沿用旧目录与旧组件选择', () {
      final o = InstallOptions(installDir: r'D:\Temp');
      o.applyFrom(InstallManifest(
        version: '0.1.0',
        fullVersion: '0.1.0.1',
        installDir: r'C:\Program Files\AuraDSP',
        allUsers: true,
        components: const ['app', 'asio'],
        files: const [],
        shortcuts: const [],
        installedAtIso: 'x',
      ));
      expect(o.installDir, r'C:\Program Files\AuraDSP');
      expect(o.allUsers, isTrue);
      expect(o.asio, isTrue);
      expect(o.vaio, isFalse);
      expect(o.ddcPresets, isFalse);
    });
  });

  group('卸载分类（保留用户数据 / 清理残留）', () {
    test('清单内程序文件删除，清单外用户文件按 keepData 决定', () {
      const program = <String>{
        'auradsp_app.exe',
        'resources/ddc/a.vdc',
        'driver/AuraVaioDriver.sys',
      };
      expect(classifyUninstallPath('auradsp_app.exe', program, true),
          UninstallAction.deleteProgram);
      expect(classifyUninstallPath('resources/ddc/a.vdc', program, true),
          UninstallAction.deleteProgram);
      expect(classifyUninstallPath('resources/ddc/my_own.vdc', program, true),
          UninstallAction.keepUserData);
      expect(classifyUninstallPath('resources/ddc/my_own.vdc', program, false),
          UninstallAction.deleteAllUserData);
      // 卸载器与清单自身必须总是删除，否则下次安装会误判「已安装」。
      expect(classifyUninstallPath('install_manifest.json', program, true),
          UninstallAction.deleteProgram);
      expect(classifyUninstallPath('uninstall.exe', program, true),
          UninstallAction.deleteProgram);
      expect(classifyUninstallPath(r'resources\ddc\my.vdc', program, true),
          UninstallAction.keepUserData);
    });

    test('升级遗留 = 旧清单有、新清单没有，且非用户数据/生成物', () {
      final old = InstallManifest(
        version: '0.1.0',
        fullVersion: '0.1.0.1',
        installDir: r'C:\Apps\AuraDSP',
        allUsers: false,
        components: const ['app'],
        files: const [
          ManifestFile(path: 'auradsp_app.exe', size: 1, sha256: 'a'),
          ManifestFile(path: 'legacy_plugin.dll', size: 1, sha256: 'b'),
          ManifestFile(path: 'config.json', size: 1, sha256: 'c'),
          ManifestFile(path: 'uninstall.exe', size: 1, sha256: 'd'),
        ],
        shortcuts: const [],
        installedAtIso: 'x',
      );
      final current = <ManifestFile>[
        const ManifestFile(path: 'auradsp_app.exe', size: 1, sha256: 'a'),
      ];
      final stale = staleUpgradePaths(old, current);
      expect(stale, contains('legacy_plugin.dll'));
      expect(stale, isNot(contains('auradsp_app.exe')));
      expect(stale, isNot(contains('config.json')));
      expect(stale, isNot(contains('uninstall.exe')));
      expect(staleUpgradePaths(null, current), isEmpty);
    });
  });

  group('提权协议参数（UAC 后自动继续）', () {
    test('auto-start / auto-uninstall / keep-data 解析', () {
      final a = SetupArgs.parse(
          ['--resume-options', 'x', '--elevated', '--auto-start']);
      expect(a.autoStart, isTrue);
      expect(a.autoUninstall, isFalse);
      expect(a.keepData, isNull);

      final b = SetupArgs.parse([
        '--auto-uninstall', '--keep-data',
        '--setup-exe', r'C:\Program Files\AuraDSP\uninstall.exe'
      ]);
      expect(b.mode, SetupMode.uninstall);
      expect(b.autoUninstall, isTrue);
      expect(b.keepData, isTrue);
      expect(b.setupExe, r'C:\Program Files\AuraDSP\uninstall.exe');

      final c = SetupArgs.parse(['--auto-uninstall', '--no-keep-data']);
      expect(c.keepData, isFalse);
      expect(SetupArgs.parse([]).autoStart, isFalse);
    });
  });

  group('退出后清理脚本（隐藏窗口）', () {
    test('含会话目录与残留文件，单引号正确转义', () {
      final s = buildCleanupScript(
        session: r'C:\Users\x\AppData\Local\Temp\AuraDSP-Setup\abc-123',
        leftovers: <String>[
          r'C:\Program Files\AuraDSP\plugin_host_x64.exe',
          r"D:\O'Brien\a.dll",
        ],
      );
      expect(s, contains('Start-Sleep -Seconds 2'));
      expect(s, contains(r'C:\Program Files\AuraDSP\plugin_host_x64.exe'));
      expect(s, contains("O''Brien"));
      expect(s, contains('Remove-Item -LiteralPath'));
      expect(s, contains(r'$PSCommandPath'));
      expect(s.contains('-WindowStyle Hidden'), isFalse,
          reason: '窗口隐藏由启动参数负责，脚本内不重复');
      // PowerShell 数组字面量不允许尾随逗号，曾导致「',' 后缺少表达式」。
      final targetLine =
          s.split('\n').firstWhere((l) => l.startsWith(r'$targets = @'));
      expect(targetLine.trim().endsWith(',)'), isFalse);
      expect(targetLine, contains("', '"));
    });

    test('空残留也生成有效脚本', () {
      final s = buildCleanupScript(session: r'C:\Temp\S', leftovers: const []);
      expect(s, contains(r'C:\Temp\S'));
      expect(s, contains(r'$targets = @('));
      expect(s, contains('Remove-Item -LiteralPath'));
    });
  });
}
