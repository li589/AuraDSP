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
  String? findInstalledFile(List<String> relativeCandidates) {
    if (!available) return null;
    try {
      final dir = File(Platform.resolvedExecutable).parent;
      for (final rel in relativeCandidates) {
        final f = File('${dir.path}/$rel');
        if (f.existsSync()) return f.path;
      }
    } catch (e, st) {
      swallow(e, st);
    }
    return null;
  }

  @override
  Future<ProcessResult> inspectAudioDevices(String exePath) {
    // 端点枚举是快工具；无超时时一旦挂死会拖住整个刷新链（V-02 卡住
    // 现象的候选路径之一）。10 秒超时后异常上抛，由调用方置错误提示。
    return Process.run(exePath, [], stdoutEncoding: utf8)
        .timeout(const Duration(seconds: 10));
  }

  @override
  Future<ProcessResult> vaioDriver(
    String scriptPath, {
    required bool install,
    required bool elevated,
    bool bundled = false,
  }) {
    if (elevated) {
      final action = install ? 'install' : 'uninstall';
      // 随包 install_vaio.ps1 没有 -Config 参数（传了会参数绑定失败）；
      // -RemoveTestCert 两脚本都接受，卸载尾巴一致。
      final tail = install
          ? (bundled ? '' : ", '-Config', 'Release'")
          : ", '-RemoveTestCert'";
      final cmd =
          'Start-Process powershell -Verb RunAs -Wait -ArgumentList '
          '\'-ExecutionPolicy\', \'Bypass\', \'-File\', \'"$scriptPath"\', '
          '\'-Action\', \'$action\'$tail';
      return Process.run('powershell', ['-Command', cmd]);
    }
    return Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      '-Action',
      install ? 'install' : 'uninstall',
      if (install)
        ...[if (!bundled) ...['-Config', 'Release']]
      else
        '-RemoveTestCert',
    ]);
  }

  @override
  Future<ProcessResult> asioDriverScript(
    String scriptPath, {
    required bool register,
    required bool elevated,
    bool bundled = false,
  }) {
    if (bundled) {
      // 随包 register_asio.ps1（pack.py 生成）：无参 = 注册，
      // -Unregister 开关 = 反注册；没有 -Action 参数。
      if (elevated) {
        final tail = register ? '' : ", '-Unregister'";
        final cmd =
            'Start-Process powershell -Verb RunAs -Wait -ArgumentList '
            '\'-ExecutionPolicy\', \'Bypass\', \'-File\', \'"$scriptPath"\'$tail';
        return Process.run('powershell', ['-Command', cmd]);
      }
      return Process.run('powershell', [
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptPath,
        if (!register) '-Unregister',
      ]);
    }
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
  Future<ProcessResult> apoStatus(String exePath, double timeout) {
    return Process.run(exePath, [
      'status',
      '--timeout',
      timeout.toString(),
      '--json',
    ]);
  }

  @override
  Future<ApoRunResult> apoInstall(
    String exePath, {
    required String target,
    required bool composite,
    required bool elevated,
  }) async {
    if (elevated) {
      final resultFile = _apoResultFile();
      _deleteQuietly(resultFile);
      final modeArg = composite ? ", '--composite'" : '';
      final cmd =
          "Start-Process \"$exePath\" -Verb RunAs -Wait -ArgumentList "
          "'install', '\"$target\"', '--yes', '--force', "
          "'--result-file', '\"${resultFile.path}\"'$modeArg";
      final res = await Process.run('powershell', ['-Command', cmd]);
      return _apoResultFromFile(res.exitCode, resultFile);
    }
    final res = await Process.run(exePath, [
      'install',
      target,
      '--yes',
      '--force',
      if (composite) '--composite',
      '--json',
    ]);
    return _apoResultFromStdout(res);
  }

  @override
  Future<ApoRunResult> apoUninstall(
    String exePath, {
    required String target,
    required bool elevated,
  }) async {
    if (elevated) {
      final resultFile = _apoResultFile();
      _deleteQuietly(resultFile);
      final targetArg = target.isNotEmpty ? ", '\"$target\"'" : '';
      final cmd =
          "Start-Process \"$exePath\" -Verb RunAs -Wait -ArgumentList "
          "'uninstall'$targetArg, '--yes', "
          "'--result-file', '\"${resultFile.path}\"'";
      final res = await Process.run('powershell', ['-Command', cmd]);
      return _apoResultFromFile(res.exitCode, resultFile);
    }
    final res = await Process.run(exePath, [
      'uninstall',
      if (target.isNotEmpty) target,
      '--yes',
      '--json',
    ]);
    return _apoResultFromStdout(res);
  }

  // ---- APO 结果通道（--result-file）----

  File _apoResultFile() =>
      File('${Directory.systemTemp.path}\\auradsp_apo_result.json');

  void _deleteQuietly(File f) {
    try {
      if (f.existsSync()) f.deleteSync();
    } catch (e, st) {
      swallow(e, st);
    }
  }

  ApoRunResult _apoResultFromFile(int exitCode, File resultFile) {
    try {
      if (resultFile.existsSync()) {
        final parsed = _parseApoJson(resultFile.readAsStringSync());
        if (parsed != null) {
          return ApoRunResult(
            exitCode: exitCode,
            toolOk: parsed['ok'] as bool?,
            toolError: parsed['error']?.toString(),
            toolMessage: parsed['message']?.toString(),
          );
        }
      }
    } catch (e, st) {
      swallow(e, st);
    }
    return ApoRunResult(exitCode: exitCode);
  }

  ApoRunResult _apoResultFromStdout(ProcessResult res) {
    final parsed = _parseApoJson(res.stdout.toString());
    if (parsed == null) return ApoRunResult(exitCode: res.exitCode);
    return ApoRunResult(
      exitCode: res.exitCode,
      toolOk: parsed['ok'] as bool?,
      toolError: parsed['error']?.toString(),
      toolMessage: parsed['message']?.toString(),
    );
  }

  /// 从工具输出中取最后一行 JSON 对象（结果 JSON 恒为单行）。
  Map<String, dynamic>? _parseApoJson(String text) {
    final lines = text
        .split(RegExp(r'\r?\n'))
        .where((l) => l.trim().startsWith('{'))
        .toList();
    if (lines.isEmpty) return null;
    try {
      final decoded = jsonDecode(lines.last);
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }
}
