// windows_system_tools.dart — Windows 系统工具端口实现（driver / APO / 端点）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §4。
// 命令字符串逐字保留自 core/state/state_audio_modes.dart，避免行为漂移。
import 'dart:convert';
import 'dart:io';

import '../../core/error_sink.dart';
import '../platform_profile.dart';
import '../port/windows_system.dart';

final class WindowsSystemTools implements WindowsSystemPort {
  const WindowsSystemTools();

  @override
  bool get available => PlatformProfile.os == 'windows';

  @override
  String? findRepoFile(List<String> relativeCandidates) {
    if (!available) return null;
    try {
      var dir = Directory.current;
      for (var i = 0; i < 4; i++) {
        for (final rel in relativeCandidates) {
          final f = File('${dir.path}/$rel');
          if (f.existsSync()) return f.path;
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    } catch (e, st) {
      swallow(e, st);
    }
    return null;
  }

  @override
  Future<ProcessResult> inspectAudioDevices(String exePath) {
    return Process.run(exePath, [], stdoutEncoding: utf8);
  }

  @override
  Future<ProcessResult> vaioDriver(
    String scriptPath, {
    required bool install,
    required bool elevated,
  }) {
    if (elevated) {
      final action = install ? 'install' : 'uninstall';
      final tail = install ? "'-Config', 'Release'" : "'-RemoveTestCert'";
      final cmd =
          'Start-Process powershell -Verb RunAs -Wait -ArgumentList '
          '\'-ExecutionPolicy\', \'Bypass\', \'-File\', \'"$scriptPath"\', '
          '\'-Action\', \'$action\', $tail';
      return Process.run('powershell', ['-Command', cmd]);
    }
    return Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      '-Action',
      install ? 'install' : 'uninstall',
      if (install) ...['-Config', 'Release'] else '-RemoveTestCert',
    ]);
  }

  @override
  Future<ProcessResult> asioDriverScript(
    String scriptPath, {
    required bool register,
    required bool elevated,
  }) {
    final action = register ? 'register' : 'unregister';
    if (elevated) {
      final cmd =
          'Start-Process powershell -Verb RunAs -Wait -ArgumentList '
          '\'-ExecutionPolicy\', \'Bypass\', \'-File\', \'"$scriptPath"\', '
          '\'-Action\', \'$action\'';
      return Process.run('powershell', ['-Command', cmd]);
    }
    return Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      '-Action',
      action,
    ]);
  }

  @override
  Future<ProcessResult> apoStatus(String scriptPath, double timeout) {
    return Process.run('python', [
      scriptPath,
      'status',
      '--timeout',
      timeout.toString(),
      '--json',
    ]);
  }

  @override
  Future<ProcessResult> apoInstall(
    String scriptPath, {
    required String target,
    required bool composite,
    required bool elevated,
  }) {
    if (elevated) {
      final modeArg = composite ? ", '--composite'" : '';
      final cmd =
          "Start-Process python -Verb RunAs -Wait -ArgumentList "
          "'\"$scriptPath\"', 'install', '\"$target\"', '--yes', '--force'$modeArg";
      return Process.run('powershell', ['-Command', cmd]);
    }
    return Process.run('python', [
      scriptPath,
      'install',
      target,
      '--yes',
      '--force',
      if (composite) '--composite',
      '--json',
    ]);
  }

  @override
  Future<ProcessResult> apoUninstall(
    String scriptPath, {
    required String target,
    required bool elevated,
  }) {
    if (elevated) {
      final targetArg = target.isNotEmpty ? ", '\"$target\"'" : '';
      final cmd =
          "Start-Process python -Verb RunAs -Wait -ArgumentList "
          "'\"$scriptPath\"', 'uninstall'$targetArg, '--yes'";
      return Process.run('powershell', ['-Command', cmd]);
    }
    return Process.run('python', [
      scriptPath,
      'uninstall',
      if (target.isNotEmpty) target,
      '--yes',
      '--json',
    ]);
  }
}
