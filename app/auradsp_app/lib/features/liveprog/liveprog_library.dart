/*
 * liveprog_library.dart — Liveprog 脚本库（本地文件系统与外部文件夹聚合）
 */
import 'dart:convert';
import 'dart:io';

import '../../core/config.dart';
import '../../core/error_sink.dart';
import '../../platform/platform_profile.dart';

/// 脚本库条目
class LiveprogItem {
  final String name;
  final String path;
  final bool isExternal;
  final String folderName;

  const LiveprogItem({
    required this.name,
    required this.path,
    this.isExternal = false,
    this.folderName = '',
  });
}

abstract final class LiveprogLibrary {
  static String? _dir;

  /// 脚本入口 FileGate L1（v3 §3.5）：单文件 ≤1MB，超限/坏文件隔离计数，
  /// 不中断整批加载。
  static const maxScriptBytes = 1024 * 1024;

  /// 最近一次 listAll 跳过的文件数（超限或不可读），供页面提示。
  static int lastSkipped = 0;

  /// 门检：null = 放行，否则为原因码（'tooLarge' / 'unreadable'）。
  /// 纯函数，可单测。
  static String? gateCheck(File f) {
    try {
      if (f.lengthSync() > maxScriptBytes) return 'tooLarge';
      // 全文 UTF-8 试解码：malformed 抛 FormatException → 隔离。
      f.readAsStringSync(encoding: utf8);
      return null;
    } catch (e, st) {
      swallow(e, st);
      return 'unreadable';
    }
  }

  /// 统一走 ConfigManager.baseDir
  static String get dir => _dir ??= ConfigManager.path('liveprog');

  /// 聚合本地库与用户自定义外部目录
  static List<LiveprogItem> listAll(List<String> customDirs) {
    final items = <LiveprogItem>[];
    lastSkipped = 0;

    void collect(Directory d, {required bool external, required String folder}) {
      for (final f in d.listSync().whereType<File>()) {
        final p = f.path.toLowerCase();
        if (!(p.endsWith('.eel') || p.endsWith('.txt'))) continue;
        // 坏文件隔离——跳过并计数，不中断整批。
        if (gateCheck(f) != null) {
          lastSkipped++;
          continue;
        }
        items.add(LiveprogItem(
          name: f.uri.pathSegments.last,
          path: f.path,
          isExternal: external,
          folderName: folder,
        ));
      }
    }

    // 1. 本地默认目录
    try {
      final d = Directory(dir);
      if (d.existsSync()) collect(d, external: false, folder: 'Local');
    } catch (e, st) {
      swallow(e, st);
    }

    // 2. 外部预设目录
    for (final cDir in customDirs) {
      try {
        final d = Directory(cDir);
        if (!d.existsSync()) continue;
        final segments = d.uri.pathSegments.where((s) => s.isNotEmpty);
        final folderName = segments.isNotEmpty ? segments.last : cDir;
        for (final f in d.listSync(recursive: true).whereType<File>()) {
          final p = f.path.toLowerCase();
          if (!(p.endsWith('.eel') || p.endsWith('.txt'))) continue;
          if (gateCheck(f) != null) {
            lastSkipped++;
            continue;
          }
          items.add(LiveprogItem(
            name: f.uri.pathSegments.last,
            path: f.path,
            isExternal: true,
            folderName: folderName,
          ));
        }
      } catch (e, st) {
        swallow(e, st);
      }
    }

    items.sort((a, b) => a.name.compareTo(b.name));
    return items;
  }

  /// 异步读取指定目录中的脚本条目（支持坏文件隔离 FileGate L1）
  static Future<List<LiveprogItem>> listDirAsync(
    String dirPath, {
    required bool isExternal,
    required String folderName,
  }) async {
    return Future(() {
      final items = <LiveprogItem>[];
      lastSkipped = 0;
      try {
        final d = Directory(dirPath);
        if (!d.existsSync()) return items;

        final files = isExternal
            ? d.listSync(recursive: true).whereType<File>()
            : d.listSync().whereType<File>();

        for (final f in files) {
          final p = f.path.toLowerCase();
          if (!(p.endsWith('.eel') || p.endsWith('.txt'))) continue;
          if (gateCheck(f) != null) {
            lastSkipped++;
            continue;
          }
          items.add(LiveprogItem(
            name: f.uri.pathSegments.last,
            path: f.path,
            isExternal: isExternal,
            folderName: folderName,
          ));
        }
        items.sort((a, b) =>
            a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      } catch (e, st) {
        swallow(e, st);
      }
      return items;
    });
  }

  static Future<String?> loadFromPath(String filePath) async {
    try {
      final f = File(filePath);
      if (gateCheck(f) != null) return null;
      return await f.readAsString(encoding: utf8);
    } catch (e, st) {
      swallow(e, st);
      return null;
    }
  }

  /// 路径收敛：只允许操作本地库或已登记外部目录之下的文件
  static bool _isUnderLibrary(String filePath, List<String> customDirs) {
    final abs = PlatformProfile.pathKey(File(filePath).absolute.path);
    final roots = <String>[Directory(dir).absolute.path, ...customDirs];
    for (final r in roots) {
      final root = PlatformProfile.pathKey(Directory(r).absolute.path);
      if (abs == root) continue;
      if (abs.startsWith(root + Platform.pathSeparator)) return true;
    }
    return false;
  }

  /// 删除库内脚本
  static bool deletePath(String filePath, List<String> customDirs) {
    try {
      if (!_isUnderLibrary(filePath, customDirs)) return false;
      final f = File(filePath);
      if (!f.existsSync()) return true;
      f.deleteSync();
      return true;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 重命名库内脚本
  static bool renamePath(
      String oldPath, String newName, List<String> customDirs) {
    try {
      if (newName.contains(RegExp(r'[\\/:*?"<>|]')) || newName.contains('..')) {
        return false;
      }
      if (!_isUnderLibrary(oldPath, customDirs)) return false;
      final old = File(oldPath);
      if (!old.existsSync() || gateCheck(old) != null) return false;
      final sep = Platform.pathSeparator;
      final parent = old.parent.path;
      final target = File('$parent$sep$newName');
      if (target.existsSync()) return false;
      target.writeAsStringSync(old.readAsStringSync(encoding: utf8));
      old.deleteSync();
      return true;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  static bool save(String name, String text, [String? targetDir]) {
    try {
      if (name.contains(RegExp(r'[\\/:*?"<>|]')) || name.contains('..')) {
        return false;
      }
      if (utf8.encode(text).length > maxScriptBytes) return false;
      final outDir = (targetDir != null && Directory(targetDir).existsSync())
          ? targetDir
          : dir;
      final d = Directory(outDir);
      if (!d.existsSync()) d.createSync(recursive: true);
      File('$outDir${Platform.pathSeparator}$name').writeAsStringSync(text);
      return true;
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }

  /// 新建模板：@init 段必须含至少一条语句（vendor 解析器约束）
  static const template = '''/* AuraDSP Liveprog — EEL2 实时脚本
 * 寄存器：spl0/spl1 = 左右样本（读写）, srate = 采样率
 * slider1..8 = 页面滑块（实时生效）
 * 支持头部定义参数：slider1:1.0<0,2,0.01>总音量增益
 */
slider1:1.0<0,2,0.01>总音量增益

@init
dbg = 0;

@sample
spl0 *= slider1;
spl1 *= slider1;
''';
}
