// registry_windows.dart — RegistryPort 的 Windows 实现（reg.exe 唯一落点）。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §7。
// 约束：整个 APP 只允许本文件出现 `reg.exe`；业务层不得拼命令。
//
// 语义：全部 best-effort，任何失败（无 reg.exe / 无权限 / 无该项）返回
// false/空表，绝不抛异常。VST 目录发现与 ASIO 状态查询都依赖这一点。
import 'dart:io';

import '../../core/error_sink.dart';
import '../platform_profile.dart';
import '../port/registry.dart';

final class WindowsRegistry implements RegistryPort {
  const WindowsRegistry();

  static const String _reg = 'reg.exe';

  @override
  bool get available => PlatformProfile.os == 'windows';

  ProcessResult? _run(List<String> args) {
    if (!available) return null;
    try {
      return Process.runSync(_reg, args, runInShell: false);
    } catch (e, st) {
      // 注册表探测是尽力而为，不参与任何错误上报。
      swallow(e, st);
      return null;
    }
  }

  @override
  bool keyExists(String keyPath) {
    final res = _run(['query', keyPath]);
    return res != null && res.exitCode == 0;
  }

  @override
  String? readString(String keyPath, String valueName) {
    final values = readStringValues(
      keyPath,
      valueName: valueName,
      recursive: false,
    );
    return values.isEmpty ? null : values.first;
  }

  @override
  List<String> readStringValues(
    String keyPath, {
    String? valueName,
    bool recursive = true,
  }) {
    final args = <String>['query', keyPath];
    if (recursive) args.add('/s');
    if (valueName != null && valueName.isNotEmpty) {
      args
        ..add('/v')
        ..add(valueName);
    }
    final res = _run(args);
    if (res == null || res.exitCode != 0) return const [];

    final out = <String>[];
    final text = res.stdout.toString();
    for (final line in text.split(RegExp(r'\r?\n'))) {
      final value = _parseStringValue(line);
      if (value != null && value.isNotEmpty) out.add(value);
    }
    return out;
  }

  /// 解析 `    Name    REG_SZ    Value` / `REG_EXPAND_SZ` / `REG_MULTI_SZ`。
  static String? _parseStringValue(String line) {
    final m = RegExp(r'\s(REG_(?:SZ|EXPAND_SZ|MULTI_SZ))\s+(.*)$').firstMatch(line);
    if (m == null) return null;
    return m.group(2)?.trim();
  }

  @override
  bool writeString(String keyPath, String valueName, String value) {
    final res = _run([
      'add',
      keyPath,
      '/v',
      valueName,
      '/t',
      'REG_SZ',
      '/d',
      value,
      '/f',
    ]);
    return res != null && res.exitCode == 0;
  }

  @override
  bool deleteValue(String keyPath, String valueName) {
    final res = _run(['delete', keyPath, '/v', valueName, '/f']);
    return res != null && res.exitCode == 0;
  }
}
