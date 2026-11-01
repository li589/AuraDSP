// resource_gate.dart — 所有「打开/加载」的唯一读闸门。
//
// 方案：docs/10-架构/APP-目录重组与平台适配层方案-2026-11-01.md §5.1。
// 职责：
//   1. 存在性/类型判定（文件 / 目录）；
//   2. 大小上限（先 lengthSync 再读，避免把超大文件载入内存）；
//   3. UTF-8 严格解码（malformed 判 unreadable，坏文件隔离）；
//   4. 扩展名白名单；
//   5. JSON 解析（非 Map 判 badJson）。
//
// 约束：配置/预设/会话/脚本/歌词/缓存读取一律经本闸门；音频/IR 等二进制
// 素材由引擎侧读取，不经过这里。所有失败只记录（swallow），不抛异常。
import 'dart:convert';
import 'dart:io';

import '../error_sink.dart';

enum ResourceIssue {
  ok,
  missing,
  notFile,
  notDirectory,
  tooLarge,
  unreadable,
  badJson,
  badExtension,
}

class ResourceRead {
  final String? text;
  final int bytes;
  final ResourceIssue issue;

  const ResourceRead._(this.text, this.bytes, this.issue);

  bool get ok => issue == ResourceIssue.ok && text != null;
}

class JsonRead {
  final Map<String, dynamic>? data;
  final ResourceIssue issue;

  const JsonRead._(this.data, this.issue);

  bool get ok => issue == ResourceIssue.ok && data != null;
}

abstract final class ResourceGate {
  /// 通用文本上限（脚本另有 1 MiB 专用上限）。
  static const int maxTextBytes = 8 * 1024 * 1024;

  /// JSON 文档上限（config/presets/session/path/cache）。
  static const int maxJsonBytes = 4 * 1024 * 1024;

  static const ResourceRead _missing =
      ResourceRead._(null, 0, ResourceIssue.missing);
  static const ResourceRead _unreadable =
      ResourceRead._(null, 0, ResourceIssue.unreadable);
  static const JsonRead _badJson = JsonRead._(null, ResourceIssue.badJson);

  static bool fileExists(String path) {
    try {
      return FileSystemEntity.typeSync(path) == FileSystemEntityType.file;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  static bool directoryExists(String path) {
    try {
      return FileSystemEntity.typeSync(path) == FileSystemEntityType.directory;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 路径类型检查。file 模式只接受普通文件，directory 模式只接受目录。
  static ResourceIssue checkPath(String path, {required bool directory}) {
    try {
      final type = FileSystemEntity.typeSync(path);
      if (type == FileSystemEntityType.notFound) return ResourceIssue.missing;
      if (directory) {
        return type == FileSystemEntityType.directory
            ? ResourceIssue.ok
            : ResourceIssue.notDirectory;
      }
      return type == FileSystemEntityType.file
          ? ResourceIssue.ok
          : ResourceIssue.notFile;
    } catch (e, st) {
      swallow(e, st);
      return ResourceIssue.unreadable;
    }
  }

  /// 扩展名白名单（大小写不敏感，不含点）。空表 = 不限制。
  static ResourceIssue checkExtension(String path, List<String> allowed) {
    if (allowed.isEmpty) return ResourceIssue.ok;
    final dot = path.lastIndexOf('.');
    if (dot < 0 || dot == path.length - 1) return ResourceIssue.badExtension;
    final ext = path.substring(dot + 1).toLowerCase();
    for (final a in allowed) {
      if (a.toLowerCase() == ext) return ResourceIssue.ok;
    }
    return ResourceIssue.badExtension;
  }

  static ResourceRead readText(
    String path, {
    int maxBytes = maxTextBytes,
  }) {
    try {
      final file = File(path);
      if (!file.existsSync()) return _missing;
      final length = file.lengthSync();
      if (length > maxBytes) {
        return ResourceRead._(null, length, ResourceIssue.tooLarge);
      }
      final text = file.readAsStringSync(encoding: utf8);
      return ResourceRead._(text, length, ResourceIssue.ok);
    } catch (e, st) {
      swallow(e, st);
      return _unreadable;
    }
  }

  static JsonRead readJson(
    String path, {
    int maxBytes = maxJsonBytes,
  }) {
    final read = readText(path, maxBytes: maxBytes);
    if (!read.ok) return JsonRead._(null, read.issue);
    try {
      final decoded = jsonDecode(read.text!);
      if (decoded is Map<String, dynamic>) {
        return JsonRead._(decoded, ResourceIssue.ok);
      }
      return _badJson;
    } catch (e, st) {
      swallow(e, st);
      return _badJson;
    }
  }
}
