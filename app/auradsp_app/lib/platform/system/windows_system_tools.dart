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
  Future<ApoRunResult> asioDriverScript(
    String scriptPath, {
    required bool register,
    required bool elevated,
    bool bundled = false,
  }) async {
    if (bundled) {
      // 随包 register_asio.ps1（pack.py 生成）：无参 = 注册，
      // -Unregister 开关 = 反注册；没有 -Action 参数。
      // -ResultFile 回传成败 JSON：提权进程输出跨不过 UAC
      // 边界，与 APO 结果通道同方案（真机报告 2026-11-10：
      // 便携形态注册失败只见 UAC 兜底文案，真因不可见）。
      final resultFile = _asioResultFile();
      _deleteQuietly(resultFile);
      if (elevated) {
        // ArgumentList 必须给单个预拼接字符串（2026-11-12 定罪）：
        // 数组形态下 Start-Process 拼接不保内嵌引号，子进程又
        // 是 powershell.exe（自有命令行解析）时，含空格路径的
        // -File 参数被拆断、碎片被当命令名执行 → 弹窗报脚本
        // 「无法识别为 cmdlet/函数/脚本文件」。开发机含空格路
        // 径实测：数组形态脚本根本不执行、单字符串形态参数完
        // 整到达。目标为 exe 的 apo_config 走 CommandLineToArgvW
        // 解析、不受影响，故 APO 侧数组形态不改。
        final argsLine = '-ExecutionPolicy Bypass -File "$scriptPath"'
            '${register ? '' : ' -Unregister'}'
            ' -ResultFile "${resultFile.path}"';
        final cmd =
            "Start-Process powershell -Verb RunAs -Wait -ArgumentList '$argsLine'";
        final res = await Process.run('powershell', ['-Command', cmd]);
        return _apoResultFromFile(res.exitCode, resultFile);
      }
      final res = await Process.run('powershell', [
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        scriptPath,
        if (!register) '-Unregister',
        '-ResultFile',
        resultFile.path,
      ]);
      final fromFile = _apoResultFromFile(res.exitCode, resultFile);
      return fromFile.toolOk != null
          ? fromFile
          : ApoRunResult(exitCode: res.exitCode);
    }
    final action = register ? 'register' : 'unregister';
    if (elevated) {
      // 同 bundled 分支：单字符串 ArgumentList（数组形态在子
      // powershell + 含空格路径下拆断 -File 参数，2026-11-12）。
      final argsLine =
          '-ExecutionPolicy Bypass -File "$scriptPath" -Action $action';
      final cmd =
          "Start-Process powershell -Verb RunAs -Wait -ArgumentList '$argsLine'";
      final res = await Process.run('powershell', ['-Command', cmd]);
      return ApoRunResult(exitCode: res.exitCode);
    }
    final res = await Process.run('powershell', [
      '-ExecutionPolicy',
      'Bypass',
      '-File',
      scriptPath,
      '-Action',
      action,
    ]);
    return ApoRunResult(exitCode: res.exitCode);
  }
  @override
  Future<ProcessResult> apoStatus(String exePath, double timeout) {
    // 进程级超时与 inspectAudioDevices 同口径（细审 R-C
    // M-4）：--timeout 只约束工具内心跳等待，工具被拦截/
    // 挂死时无进程级超时则 checkApoStatus 的 Future 永不
    // 完成、设置页刷新悬挂无错误呈现。
    // stdoutEncoding 必须显式 utf8（资源计划 Stage 0 / §8.3 定罪）：apo_config
    // 输出 UTF-8 JSON，Dart 默认按 systemEncoding（中文 Windows
    // = GBK）解码会把设备名解成乱码——面板「已附加（设备名）」
    // 与端点清单名都走此通道。inspectAudioDevices 早已显式，
    // 此处漏网。
    return Process.run(exePath, [
      'status',
      '--timeout',
      timeout.toString(),
      '--json',
    ], stdoutEncoding: utf8)
        .timeout(const Duration(seconds: 10));
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
    ], stdoutEncoding: utf8);
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
    ], stdoutEncoding: utf8);
    return _apoResultFromStdout(res);
  }

  // ---- APO 结果通道（--result-file）----

  File _apoResultFile() =>
      File('${Directory.systemTemp.path}\\auradsp_apo_result.json');

  File _asioResultFile() =>
      File('${Directory.systemTemp.path}\\auradsp_asio_result.json');

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
    // UTF-8 BOM 必须先剥（第六轮项 2 实证）：随包 ps1 以 PS 5.1
    // `Set-Content -Encoding UTF8` 写结果文件必带 BOM，Dart 的
    // trim 不去 U+FEFF，首行 '{' 过滤恒落空 ⇒ 脚本真实成败与
    // 原因（regsvr32 退出码等）被吞、UI 只剩 UAC 兜底文案。
    // apo_config.exe 写无 BOM 文件，此前未暴露。
    if (text.startsWith('\uFEFF')) text = text.substring(1);
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
