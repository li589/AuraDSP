/// 安装/卸载引擎编排（设计 §5）：步骤、警告降级、回滚、清单。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../args.dart';
import 'models.dart';
import 'payload.dart';
import 'win32.dart';

String env(String name) => Platform.environment[name] ?? '';

String defaultInstallDir(bool allUsers) => allUsers
    ? r'C:\Program Files\AuraDSP'
    : p.join(env('LOCALAPPDATA'), 'Programs', 'AuraDSP');

class InstallEngine {
  InstallEngine({required this.args, required this.wizard});
  final SetupArgs args;
  final WizardManifest wizard;

  // ---- 卸载表字段组装（纯逻辑，可单测；设计 §5.5） ----
  static Map<String, Object> uninstallValues({
    required String installDir,
    required String fullVersion,
    required int estimatedSizeKb,
  }) =>
      {
        'DisplayName': 'AuraDSP',
        'DisplayVersion': fullVersion,
        'Publisher': 'li589',
        'DisplayIcon': '$installDir\\auradsp_app.exe,0',
        'InstallLocation': installDir,
        'UninstallString': '"$installDir\\uninstall.exe"',
        'QuietUninstallString': '"$installDir\\uninstall.exe" /silent',
        'EstimatedSize': estimatedSizeKb,
        'NoModify': 1,
        'NoRepair': 1,
        'URLInfoAbout': 'https://github.com/li589/AuraDSP',
      };

  int get _hive => _allUsers ? kHkeyLocalMachine : kHkeyCurrentUser;
  bool _allUsers = false;

  Future<EngineResult> install(InstallOptions o, ProgressSink sink) async {
    _allUsers = o.allUsers;
    final warnings = <String>[];
    final createdFiles = <ManifestFile>[];
    final createdShortcuts = <String>[];
    final elevated = isElevated();

    try {
      // 1) 进程守卫
      sink(const ProgressEvent('guard', 'check'));
      if (o.closeRunningApps) {
        await closeGuardedProcesses();
      } else if ((await guardedPids()).isNotEmpty) {
        throw StateError('AuraDSP 正在运行，请先关闭后重试');
      }

      // 2) 载荷解压（关键步，失败回滚）
      if (!args.hasPayload) throw StateError('缺少载荷定位参数（应经 Setup 引导壳启动）');
      final session = args.sessionDir ?? Directory.systemTemp.path;
      final zipPath = p.join(session, 'payload.zip');
      sink(const ProgressEvent('extract', 'slice'));
      await slicePayloadToFile(args.setupExe!, args.payloadOff!, args.payloadLen!, zipPath);
      await Directory(o.installDir).create(recursive: true);
      final files = await extractPayload(
        zipPath,
        o.installDir,
        include: componentFilter(vaio: o.vaio, ddcPresets: o.ddcPresets),
        onFile: (rel, done, total) =>
            sink(ProgressEvent('extract', rel, total == 0 ? null : done / total)),
      );
      createdFiles.addAll(files);

      // 3) ASIO 注册（降级警告）
      if (o.asio) {
        sink(const ProgressEvent('asio', 'register'));
        final dll = p.join(o.installDir, 'AuraAsioDriver.dll');
        if (!File(dll).existsSync()) {
          warnings.add('未找到 AuraAsioDriver.dll，ASIO 注册跳过');
        } else {
          try {
            final hr = callDllRegisterServer(dll, register: true);
            if (hr != 0) {
              warnings.add('ASIO 注册返回 0x${hr.toUnsigned(32).toRadixString(16)}'
                  '${elevated ? '' : '（未提权时 DAW 可见性受限）'}');
            }
          } catch (e) {
            warnings.add('ASIO 注册失败: $e');
          }
        }
      }

      // 4) VAIO 驱动（需提权；失败警告不回滚）
      if (o.vaio) {
        sink(const ProgressEvent('driver', 'install'));
        final script = p.join(o.installDir, 'driver', 'install_driver.ps1');
        if (!elevated) {
          warnings.add('VAIO 驱动需要管理员权限，已跳过（可事后以管理员运行 driver\\install_driver.ps1）');
        } else if (!File(script).existsSync()) {
          warnings.add('载荷缺少 driver\\install_driver.ps1，驱动安装跳过');
        } else {
          final r = await Process.run(
            'powershell.exe',
            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script],
            workingDirectory: p.dirname(script),
          ).timeout(const Duration(minutes: 3), onTimeout: () {
            throw StateError('驱动安装超时');
          });
          if (r.exitCode != 0) {
            warnings.add('VAIO 驱动安装失败（退出码 ${r.exitCode}），应用本体不受影响');
          }
        }
      }

      // 5) 快捷方式 + 自启
      sink(const ProgressEvent('shortcuts', 'create'));
      final exe = p.join(o.installDir, 'auradsp_app.exe');
      if (o.desktopShortcut) {
        final lnk = p.join(env('USERPROFILE'), 'Desktop', 'AuraDSP.lnk');
        if (await _createShortcut(lnk, exe, o.installDir)) {
          createdShortcuts.add(lnk);
        } else {
          warnings.add('桌面快捷方式创建失败');
        }
      }
      if (o.startMenuShortcut) {
        final base = o.allUsers
            ? p.join(env('ProgramData'), r'Microsoft\Windows\Start Menu\Programs', 'AuraDSP')
            : p.join(env('APPDATA'), r'Microsoft\Windows\Start Menu\Programs', 'AuraDSP');
        await Directory(base).create(recursive: true);
        final lnk = p.join(base, 'AuraDSP.lnk');
        if (await _createShortcut(lnk, exe, o.installDir)) createdShortcuts.add(lnk);
      }
      if (o.autostart) {
        registryWriteValues(kHkeyCurrentUser,
            r'Software\Microsoft\Windows\CurrentVersion\Run', {'AuraDSP': '"$exe"'});
      }

      // 6) 卸载器 + 清单 + 注册表
      sink(const ProgressEvent('uninstaller', 'emit'));
      if (args.setupExe != null) {
        await File(args.setupExe!).copy(p.join(o.installDir, 'uninstall.exe'));
      }
      final manifest = InstallManifest(
        version: wizard.version,
        fullVersion: wizard.fullVersion,
        installDir: o.installDir,
        allUsers: o.allUsers,
        components: [
          'app',
          if (o.asio) 'asio',
          if (o.vaio) 'vaio',
          if (o.ddcPresets) 'ddc',
        ],
        files: createdFiles,
        shortcuts: createdShortcuts,
        installedAtIso: DateTime.now().toIso8601String(),
      );
      await File(p.join(o.installDir, 'install_manifest.json'))
          .writeAsString(manifest.encode());

      sink(const ProgressEvent('registry', 'write'));
      final regOk = registryWriteValues(
        _hive,
        r'Software\Microsoft\Windows\CurrentVersion\Uninstall\AuraDSP',
        uninstallValues(
          installDir: o.installDir,
          fullVersion: wizard.fullVersion,
          estimatedSizeKb: manifest.estimatedSizeKb,
        ),
      );
      registryWriteValues(_hive, r'Software\AuraDSP', {
        'InstallDir': o.installDir,
        'Version': wizard.fullVersion,
      });
      if (!regOk) warnings.add('卸载注册表项写入失败（不影响使用与文件卸载）');

      sink(const ProgressEvent('done', '', 1.0));
      return EngineResult(ok: true, warnings: warnings);
    } catch (e) {
      // 回滚：删已解压文件与已建快捷方式（注册表项在最后才写，一般未及）
      for (final f in createdFiles.reversed) {
        try {
          await File(p.join(o.installDir, f.path)).delete();
        } catch (_) {}
      }
      for (final s in createdShortcuts) {
        try {
          await File(s).delete();
        } catch (_) {}
      }
      return EngineResult(ok: false, error: '$e', warnings: warnings);
    }
  }

  Future<bool> _createShortcut(String lnk, String target, String workDir) async {
    const script = r'''
$w = New-Object -ComObject WScript.Shell
$s = $w.CreateShortcut($env:AURA_LNK)
$s.TargetPath = $env:AURA_TARGET
$s.WorkingDirectory = $env:AURA_WORKDIR
$s.IconLocation = $env:AURA_TARGET + ',0'
$s.Description = 'AuraDSP'
$s.Save()
''';
    final r = await Process.run(
      'powershell.exe',
      ['-NoProfile', '-Command', script],
      environment: {
        'AURA_LNK': lnk,
        'AURA_TARGET': target,
        'AURA_WORKDIR': workDir,
      },
    );
    return r.exitCode == 0 && File(lnk).existsSync();
  }

  // ------------------------------------------------------------------
  // 卸载流
  // ------------------------------------------------------------------

  Future<EngineResult> uninstall(
    InstallManifest manifest, {
    required bool keepData,
    required ProgressSink sink,
  }) async {
    final warnings = <String>[];
    try {
      sink(const ProgressEvent('guard', 'check'));
      await closeGuardedProcesses();

      if (manifest.components.contains('asio')) {
        sink(const ProgressEvent('asio', 'unregister'));
        final dll = p.join(manifest.installDir, 'AuraAsioDriver.dll');
        if (File(dll).existsSync()) {
          try {
            callDllRegisterServer(dll, register: false);
          } catch (e) {
            warnings.add('ASIO 反注册失败: $e');
          }
        }
      }

      sink(const ProgressEvent('cleanup', 'shortcuts'));
      for (final s in manifest.shortcuts) {
        try {
          await File(s).delete();
        } catch (_) {}
      }
      registryDeleteValue(kHkeyCurrentUser,
          r'Software\Microsoft\Windows\CurrentVersion\Run', 'AuraDSP');

      sink(const ProgressEvent('cleanup', 'files'));
      for (final f in manifest.files.reversed) {
        try {
          await File(p.join(manifest.installDir, f.path)).delete();
        } catch (_) {}
      }
      // 残余（driver/、uninstall.exe、清单自身）整目录回收，uninstall.exe
      // 是引导壳镜像、进程已退出，带重试删除。
      final dir = Directory(manifest.installDir);
      if (await dir.exists()) {
        for (var i = 0; i < 5; i++) {
          try {
            await dir.delete(recursive: true);
            break;
          } catch (_) {
            await Future<void>.delayed(const Duration(milliseconds: 400));
          }
        }
        if (await dir.exists()) {
          warnings.add('安装目录尚有文件未能删除，可手动清理: ${manifest.installDir}');
        }
      }

      sink(const ProgressEvent('registry', 'clean'));
      final hive = manifest.allUsers ? kHkeyLocalMachine : kHkeyCurrentUser;
      registryDeleteTree(
          hive, r'Software\Microsoft\Windows\CurrentVersion\Uninstall\AuraDSP');
      registryDeleteTree(hive, r'Software\AuraDSP');

      if (!keepData) {
        for (final d in [
          p.join(env('APPDATA'), 'AuraDSP'),
          p.join(env('LOCALAPPDATA'), 'AuraDSP'),
        ]) {
          try {
            await Directory(d).delete(recursive: true);
          } catch (_) {}
        }
      }
      sink(const ProgressEvent('done', '', 1.0));
      return EngineResult(ok: true, warnings: warnings);
    } catch (e) {
      return EngineResult(ok: false, error: '$e', warnings: warnings);
    }
  }
}
