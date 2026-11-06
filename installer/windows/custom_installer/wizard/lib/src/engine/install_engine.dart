/// 安装/卸载引擎编排（设计 §5）：步骤、警告降级、回滚、清单。
/// 2026-11-06 优化：覆盖升级（备份/回滚 + 用户数据保护）、已装实例探测、
/// 驱动改调随包自包含脚本、测试签名风险告知。
library;

import 'dart:io';

import 'package:path/path.dart' as p;

import '../args.dart';
import 'driver_notice.dart';
import 'models.dart';
import 'payload.dart';
import 'update_policy.dart';
import 'win32.dart';

String env(String name) => Platform.environment[name] ?? '';

String defaultInstallDir(bool allUsers) => normalizeInstallDir(
      allUsers
          ? r'C:\Program Files'
          : p.join(env('LOCALAPPDATA'), 'Programs'),
      r'C:\AuraDSP',
    );

/// ASIO 驱动 DLL 在安装目录中的路径。规范名 auraasio_driver.dll
/// （ADR-008：CMake 目标名即文件名，pack.py 按此名投放）；
/// AuraAsioDriver.dll 为早期打包口径的别名，兼容识别。
String asioDllPath(String dir) {
  final canonical = p.join(dir, 'auraasio_driver.dll');
  if (File(canonical).existsSync()) return canonical;
  final alias = p.join(dir, 'AuraAsioDriver.dll');
  if (File(alias).existsSync()) return alias;
  return canonical;
}

/// 最近一次读取安装清单的错误（诊断用；清单损坏不阻断安装）。
String? lastManifestError;

/// 探测已安装实例：先读 HKCU / HKLM 的 Software\AuraDSP，再补清单。
/// 注册表是「是否已装 + 版本 + 目录」的真相源，清单提供文件/组件台账。
Future<InstalledInfo?> readInstalledInfo() async {
  for (final hive in const [kHkeyCurrentUser, kHkeyLocalMachine]) {
    final v = await registryReadValues(hive, r'Software\AuraDSP');
    final dir = v['InstallDir'];
    final ver = v['Version'];
    if (dir == null || dir.isEmpty || ver == null || ver.isEmpty) continue;
    InstallManifest? manifest;
    try {
      final f = File(p.join(dir, 'install_manifest.json'));
      if (await f.exists()) manifest = InstallManifest.decode(await f.readAsString());
    } catch (e) {
      // 清单损坏：按「无清单」处理，升级走保守路径（不主动删旧文件）。
      lastManifestError = '$e';
    }
    return InstalledInfo(
      fullVersion: ver,
      installDir: dir,
      allUsers: hive == kHkeyLocalMachine,
      manifest: manifest,
    );
  }
  return null;
}

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

  Future<EngineResult> install(
    InstallOptions o,
    ProgressSink sink, {
    UpdatePlan? plan,
  }) async {
    _allUsers = o.allUsers;
    final warnings = <String>[];
    final createdFiles = <ManifestFile>[];
    final createdShortcuts = <String>[];
    final elevated = isElevated();
    final overwrite = plan?.isOverwrite ?? false;
    final hasOldManifest = plan?.previous?.hasManifest ?? false;
    String? backupDir;

    try {
      // 1) 进程守卫
      sink(const ProgressEvent('guard', 'check', 0.02));
      if (o.closeRunningApps) {
        await closeGuardedProcesses();
      } else if ((await guardedPids()).isNotEmpty) {
        throw StateError('AuraDSP 正在运行，请先关闭后重试');
      }

      if (!args.hasPayload) throw StateError('缺少载荷定位参数（应经 Setup 引导壳启动）');
      final session = args.sessionDir ?? Directory.systemTemp.path;
      final zipPath = p.join(session, 'payload.zip');

      // 2) 覆盖升级前备份将被替换的旧程序文件（用户数据不备份、不覆盖）
      if (overwrite) {
        sink(const ProgressEvent('backup', 'snapshot', 0.04));
        backupDir = p.join(session, 'update-backup-${DateTime.now().millisecondsSinceEpoch}');
        for (final f in plan!.previous?.manifest?.files ?? <ManifestFile>[]) {
          if (isUserPath(f.path)) continue;
          final src = File(p.join(o.installDir, f.path));
          if (!await src.exists()) continue;
          final dst = File(p.join(backupDir, f.path));
          await dst.parent.create(recursive: true);
          await src.copy(dst.path);
        }
      }

      // 3) 载荷解压（关键步，失败回滚）
      sink(const ProgressEvent('extract', 'slice', 0.05));
      await slicePayloadToFile(args.setupExe!, args.payloadOff!, args.payloadLen!, zipPath);
      await Directory(o.installDir).create(recursive: true);
      final files = await extractPayload(
        zipPath,
        o.installDir,
        include: componentFilter(ddcPresets: o.ddcPresets),
        onFile: (rel, done, total) => sink(ProgressEvent('extract', rel,
            total == 0 ? null : 0.05 + 0.70 * done / total)),
      );
      createdFiles.addAll(files);

      // 4) ASIO 注册（用户态 COM，不受内核驱动签名限制；降级警告）
      if (o.asio) {
        sink(const ProgressEvent('asio', 'register', 0.80));
        final dll = asioDllPath(o.installDir);
        if (!File(dll).existsSync()) {
          warnings.add('未找到 auraasio_driver.dll，ASIO 注册跳过');
        } else {
          try {
            final rc = await registerAsioDll(dll, register: true);
            if (rc != 0) {
              warnings.add('ASIO 注册失败（regsvr32 退出码 $rc）'
                  '${elevated ? '' : '；未提权时 DAW 可见性受限'}');
            }
          } catch (e) {
            warnings.add('ASIO 注册失败: $e');
          }
        }
      }

      // 5) VAIO 内核驱动：调随包自包含脚本并显式传 -Action install。
      //    旧口径直接执行 install_driver.ps1（默认 -Action status，等于不安装）
      //    且该脚本按源码树找包、依赖 WDK signtool，随包环境不可用。
      if (o.vaio) {
        sink(const ProgressEvent('driver', 'install', 0.86));
        final script = p.join(o.installDir, kDriverManualDirRel, 'install_vaio.ps1');
        if (!elevated) {
          warnings.add('VAIO 驱动需要管理员权限，已跳过（可事后以管理员运行 '
              '$kDriverManualDirRel\\install_vaio.ps1 -Action install）');
        } else if (!File(script).existsSync()) {
          warnings.add('载荷缺少 $kDriverManualDirRel\\install_vaio.ps1，驱动安装跳过');
          warnings.add(kDriverSigningNotice);
        } else {
          final r = await Process.run(
            'powershell.exe',
            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script,
             '-Action', 'install'],
            workingDirectory: p.dirname(script),
          ).timeout(const Duration(minutes: 5), onTimeout: () {
            throw StateError('驱动安装超时');
          });
          if (r.exitCode == kDriverSigningRequired) {
            warnings.add(kDriverSigningNotice);
          } else {
            if (r.exitCode != 0) {
              warnings.add('VAIO 驱动安装失败（退出码 ${r.exitCode}），应用本体不受影响；'
                  '可查看 %TEMP%\\auradsp-vaio-install.log 后手动重试');
            }
            warnings.add(kDriverSigningShort);
          }
        }
      }

      // 6) 快捷方式 + 自启
      sink(const ProgressEvent('shortcuts', 'create', 0.90));
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

      // 7) 卸载器 + 清单 + 注册表
      sink(const ProgressEvent('uninstaller', 'emit', 0.94));
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
        previousFullVersion: plan?.previous?.fullVersion,
        updateMode: plan?.mode.name ?? 'fresh',
      );
      await File(p.join(o.installDir, 'install_manifest.json'))
          .writeAsString(manifest.encode());

      sink(const ProgressEvent('registry', 'write', 0.97));
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
        if (plan?.previous != null) 'PreviousVersion': plan!.previous!.fullVersion,
        'UpdateMode': manifest.updateMode,
      });
      if (!regOk) warnings.add('卸载注册表项写入失败（不影响使用与文件卸载）');

      // 8) 升级成功：清理旧版遗留（旧清单有、新清单没有的随包文件），
      //    再删备份快照。这些旧文件都在备份里，若此步抛错仍可回滚恢复。
      if (overwrite && hasOldManifest) {
        final stale = staleUpgradePaths(plan!.previous!.manifest, createdFiles);
        for (final rel in stale) {
          final f = File(p.join(o.installDir, rel));
          if (await f.exists()) await f.delete();
        }
      }
      if (backupDir != null) await _deleteBackup(backupDir);
      sink(const ProgressEvent('done', '', 1.0));
      return EngineResult(ok: true, warnings: warnings);
    } catch (e) {
      // 回滚：覆盖升级先恢复旧程序文件，再删本次新增文件；用户数据一律不动。
      if (overwrite && hasOldManifest && backupDir != null) {
        sink(const ProgressEvent('restore', 'rollback'));
        for (final f in createdFiles.reversed) {
          if (isUserPath(f.path)) continue;
          try {
            await File(p.join(o.installDir, f.path)).delete();
          } catch (_) {}
        }
        await _restoreBackup(backupDir, o.installDir);
        await _deleteBackup(backupDir);
      } else if (overwrite) {
        // 无旧清单：无法判断哪些是旧文件，保守保留现状，避免删掉用户安装。
        warnings.add('升级失败但缺少旧安装清单，已保留现有文件，请检查安装目录后重试');
      } else {
        for (final f in createdFiles.reversed) {
          try {
            await File(p.join(o.installDir, f.path)).delete();
          } catch (_) {}
        }
      }
      for (final s in createdShortcuts) {
        try {
          await File(s).delete();
        } catch (_) {}
      }
      return EngineResult(ok: false, error: '$e', warnings: warnings);
    }
  }

  Future<void> _restoreBackup(String backupDir, String installDir) async {
    final dir = Directory(backupDir);
    if (!await dir.exists()) return;
    await for (final e in dir.list(recursive: true, followLinks: false)) {
      if (e is! File) continue;
      final rel = p.relative(e.path, from: backupDir);
      final dst = File(p.join(installDir, rel));
      await dst.parent.create(recursive: true);
      await e.copy(dst.path);
    }
  }

  Future<void> _deleteBackup(String backupDir) async {
    try {
      final d = Directory(backupDir);
      if (await d.exists()) await d.delete(recursive: true);
    } catch (_) {}
  }

  /// 完成页「创建桌面快捷方式」：安装结束后仍可补建或取消（幂等）。
  Future<bool> setDesktopShortcut(String installDir, {required bool create}) async {
    final lnk = p.join(env('USERPROFILE'), 'Desktop', 'AuraDSP.lnk');
    if (create) {
      return _createShortcut(
          lnk, p.join(installDir, 'auradsp_app.exe'), installDir);
    }
    try {
      final f = File(lnk);
      if (await f.exists()) await f.delete();
    } catch (_) {
      return false;
    }
    return true;
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
    final keptPaths = <String>[];
    final failed = <String>[];
    final leftovers = <String>[];
    try {
      sink(const ProgressEvent('guard', 'check', 0.02));
      await closeGuardedProcesses();
      final elevated = isElevated();

      // 1) ASIO：只要 DLL 在就反注册（含用户事后手动注册的情况），幂等。
      sink(const ProgressEvent('asio', 'unregister', 0.20));
      final dll = asioDllPath(manifest.installDir);
      if (await File(dll).exists()) {
        try {
          final rc = await registerAsioDll(dll, register: false);
          if (rc != 0) {
            warnings.add('ASIO 反注册返回 $rc（可手动运行 driver\\register_asio.ps1 -Unregister）');
          }
        } catch (e) {
          warnings.add('ASIO 反注册失败: $e');
        }
      }

      // 2) VAIO：卸设备节点 + DriverStore 包 + 测试证书；先于删文件，
      //    否则已加载的 .sys 会占用导致删除失败。
      final driverDir = p.join(manifest.installDir, kDriverManualDirRel);
      final script = p.join(driverDir, 'install_vaio.ps1');
      if (await File(script).exists()) {
        sink(const ProgressEvent('driver', 'uninstall', 0.32));
        if (!elevated) {
          warnings.add('未以管理员运行：VAIO 驱动、设备节点与测试证书未清理。'
              '请手动以管理员执行 driver\\install_vaio.ps1 -Action uninstall -RemoveTestCert');
        } else {
          final r = await Process.run(
            'powershell.exe',
            ['-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', script,
             '-Action', 'uninstall', '-RemoveTestCert'],
            workingDirectory: driverDir,
          ).timeout(const Duration(minutes: 3), onTimeout: () {
            throw StateError('驱动卸载超时');
          });
          if (r.exitCode != 0) {
            warnings.add('VAIO 驱动卸载返回 ${r.exitCode}，'
                '详见 %TEMP%\\auradsp-vaio-install.log');
          }
        }
      }

      // 3) 快捷方式：清单 + 常见落点幂等补删，再回收空程序组目录。
      sink(const ProgressEvent('cleanup', 'shortcuts', 0.45));
      final linkDirs = <String>[];
      for (final key in const ['USERPROFILE', 'ProgramData', 'APPDATA']) {
        final v = env(key);
        if (v.isNotEmpty) linkDirs.add(v);
      }
      final links = <String>{...manifest.shortcuts};
      final groupBases = <String>[];
      for (final v in linkDirs) {
        links.add(p.join(v, 'Desktop', 'AuraDSP.lnk'));
        final g = p.join(v, r'Microsoft\Windows\Start Menu\Programs', 'AuraDSP');
        groupBases.add(g);
        links.add(p.join(g, 'AuraDSP.lnk'));
      }
      for (final s in links) {
        try {
          final f = File(s);
          if (await f.exists()) await f.delete();
        } catch (_) {}
      }
      for (final g in groupBases) {
        try {
          final d = Directory(g);
          if (await d.exists()) await d.delete();
        } catch (_) {}
      }

      // 4) 注册表：两个 hive 都清（避免 allUsers 判定漂移），Run 自启两处都删。
      sink(const ProgressEvent('registry', 'clean', 0.55));
      for (final hive in const [kHkeyCurrentUser, kHkeyLocalMachine]) {
        registryDeleteTree(
            hive, r'Software\Microsoft\Windows\CurrentVersion\Uninstall\AuraDSP');
        registryDeleteTree(hive, r'Software\AuraDSP');
        registryDeleteValue(
            hive, r'Software\Microsoft\Windows\CurrentVersion\Run', 'AuraDSP');
      }
      if (manifest.allUsers && !elevated) {
        warnings.add('未提权：HKLM 下的卸载注册表项可能未清除，'
            '建议以管理员重新运行卸载');
      }

      // 5) 文件：按清单分类逐文件删除，不再整目录 delete(recursive)。
      //    清单内 = 随包程序文件（删）；清单外 = 用户数据（keepData 时保留）。
      sink(const ProgressEvent('cleanup', 'files', 0.65));
      // 删文件前再清一次守卫进程：安装后扫描插件可能拉起 plugin_host_x64，
      // 且在首轮守卫之后仍可能被重新拉起；按镜像名强杀兜底。
      await closeGuardedProcesses();
      final programPaths = manifest.files.map((f) => f.path).toSet();
      final dir = Directory(manifest.installDir);
      if (await dir.exists()) {
        final allFiles = <File>[];
        try {
          await for (final e in dir.list(recursive: true, followLinks: false)) {
            if (e is File) allFiles.add(e);
          }
        } catch (_) {}
        for (final e in allFiles) {
          final rel = p.relative(e.path, from: manifest.installDir)
              .replaceAll(r'\', '/');
          final action = classifyUninstallPath(rel, programPaths, keepData);
          if (action == UninstallAction.keepUserData) continue;
          var deleted = false;
          for (var attempt = 0; attempt < 4 && !deleted; attempt++) {
            try {
              await e.delete();
              deleted = true;
            } catch (_) {
              await Future<void>.delayed(const Duration(milliseconds: 350));
            }
          }
          if (!deleted) {
            failed.add(rel);
            leftovers.add(e.path); // 退出后由隐藏清理脚本重试
          }
        }
        await _pruneEmptyDirs(manifest.installDir);
      }
      if (keepData && await dir.exists()) keptPaths.add(manifest.installDir);

      // 6) 用户数据根（%APPDATA%\AuraDSP / %LOCALAPPDATA%\AuraDSP）。
      final dataRoots = <String>{};
      for (final key in const ['APPDATA', 'LOCALAPPDATA']) {
        final v = env(key);
        if (v.isNotEmpty) dataRoots.add(p.join(v, 'AuraDSP'));
      }
      if (!keepData) {
        for (final d in dataRoots) {
          try {
            final target = Directory(d);
            if (await target.exists()) await target.delete(recursive: true);
          } catch (_) {
            failed.add(d);
            leftovers.add(d);
          }
        }
      } else {
        for (final d in dataRoots) {
          if (await Directory(d).exists()) keptPaths.add(d);
        }
      }

      // 7) 临时日志
      try {
        final t = env('TEMP');
        if (t.isNotEmpty) {
          final log = File(p.join(t, 'auradsp-vaio-install.log'));
          if (await log.exists()) await log.delete();
        }
      } catch (_) {}

      if (failed.isNotEmpty) {
        warnings.add('有 ${failed.length} 个文件被其他进程占用，'
            '已安排在向导退出后自动清理：'
            '${failed.take(3).join('、')}${failed.length > 3 ? ' …' : ''}');
      }
      sink(const ProgressEvent('done', '', 1.0));
      return EngineResult(ok: true, warnings: warnings,
          keptPaths: keptPaths, leftoverPaths: leftovers);
    } catch (e) {
      return EngineResult(ok: false, error: '$e', warnings: warnings,
          keptPaths: keptPaths, leftoverPaths: leftovers);
    }
  }

  /// 自底向上回收空目录；仍有用户数据的目录删除会失败并被忽略（保留）。
  Future<void> _pruneEmptyDirs(String root) async {
    final dirs = <Directory>[];
    try {
      await for (final e in Directory(root).list(recursive: true, followLinks: false)) {
        if (e is Directory) dirs.add(e);
      }
    } catch (_) {
      return;
    }
    dirs.sort((a, b) => b.path.length.compareTo(a.path.length));
    for (final d in dirs) {
      try {
        await d.delete();
      } catch (_) {}
    }
    try {
      await Directory(root).delete();
    } catch (_) {}
  }
}
