// document_store.dart — JSON 文档的统一下载/落盘入口。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §5.2。
// 读：经 ResourceGate（大小/编码/JSON 校验）；写：自动建父目录 + 2 空格缩进，
// 失败只返回 false，绝不抛异常（调用方多在 UI/持久化路径上）。
import 'dart:convert';
import 'dart:io';

import '../error_sink.dart';
import 'resource_gate.dart';

abstract final class DocumentStore {
  static JsonRead readJson(String path, {int maxBytes = ResourceGate.maxJsonBytes}) {
    return ResourceGate.readJson(path, maxBytes: maxBytes);
  }

  /// 读取 JSON 数组（如插件编辑器崩溃日志）。缺失/坏格式返回 null。
  static List<dynamic>? readJsonList(
    String path, {
    int maxBytes = ResourceGate.maxJsonBytes,
  }) {
    final read = ResourceGate.readText(path, maxBytes: maxBytes);
    if (!read.ok) return null;
    try {
      final decoded = jsonDecode(read.text!);
      return decoded is List ? decoded : null;
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  static bool writeJson(String path, Object? value) {
    try {
      return writeText(
        path,
        const JsonEncoder.withIndent('  ').convert(value),
      );
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  static bool writeText(String path, String text) {
    try {
      final file = File(path);
      final parent = file.parent;
      if (!parent.existsSync()) parent.createSync(recursive: true);
      file.writeAsStringSync(text);
      return true;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 列出目录下的 JSON 文件（目录不存在/不可读返回空表）。
  static List<File> listJsonFiles(String dir, {bool recursive = false}) {
    try {
      final d = Directory(dir);
      if (!d.existsSync()) return const [];
      return d
          .listSync(recursive: recursive)
          .whereType<File>()
          .where((f) => f.path.toLowerCase().endsWith('.json'))
          .toList();
    } catch (e, st) {
      swallow(e, st);
      return const [];
    }
  }

  static bool delete(String path) {
    try {
      final f = File(path);
      if (!f.existsSync()) return true;
      f.deleteSync();
      return true;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }
}
