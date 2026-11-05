import 'package:auradsp_setup/src/args.dart';
import 'package:auradsp_setup/src/engine/install_engine.dart';
import 'package:auradsp_setup/src/engine/models.dart';
import 'package:auradsp_setup/src/engine/payload.dart';
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
    test('VAIO/DDC 组件门控', () {
      final f = componentFilter(vaio: false, ddcPresets: false);
      expect(f('auradsp_app.exe'), isTrue);
      expect(f('driver/AuraVaio.sys'), isFalse);
      expect(f('resources/ddc/a.vdc'), isFalse);
      expect(f('resources/liveprog/a.eel'), isTrue);
      final g = componentFilter(vaio: true, ddcPresets: true);
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
  });
}
