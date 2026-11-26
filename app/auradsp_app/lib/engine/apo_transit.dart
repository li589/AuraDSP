// apo_transit.dart — APO 文件中转（资源计划 Part C / P4；设计
// 骨架 = APO 计划书 Part III，2026-11-10 定稿、2026-11-12 业主
// 裁定沿用中转根）。
//
// 问题：audiodg 以 LocalService 身份运行，读不到用户任意选址
// 的 IR/VDC 文件（用户目录 ACL 无 LocalService 读权，第十轮已
// 实证）。解法：文件被引用时按内容哈希复制进中转根
// %ProgramData%\AuraDSP\apo-assets\（LocalService 可读），参数
// 通道只传中转路径；引擎侧（ApoEngineHost）围栏校验路径必须
// 在中转根下，防任意路径下发。UI 始终显示原始路径（业主 Q3
// 裁定：界面保留现状，内部处理走副本）。
//
// 本类只被 APO 参数发布者（audio_isolate_apo）使用：非 APO 模
// 式的引擎在 App 进程内、直接读原路径，永不经此。文件中转失败
// 吞错并留日志，发布者写空路径（引擎卸载该文件）；插件中转则返回
// 带原因的结构化失败，经现有槽位终态事件呈现，绝不假装可用。

import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';

import '../platform/platform_profile.dart';
import '../platform/port/windows_system.dart';
import 'debug_log.dart';

final class ApoFileTransitResult {
  const ApoFileTransitResult({this.path, this.errorMessage});

  final String? path;
  final String? errorMessage;
}

final class ApoPluginTransitResult {
  const ApoPluginTransitResult({this.path, this.errorMessage});

  final String? path;
  final String? errorMessage;
}

final class _BundleManifest {
  const _BundleManifest(this.files, this.directories);

  final Map<String, String> files;
  final Set<String> directories;

  int get fileCount => files.length;

  bool matches(_BundleManifest other) {
    if (fileCount != other.fileCount) return false;
    if (directories.length != other.directories.length) return false;
    if (!directories.containsAll(other.directories)) return false;
    for (final entry in files.entries) {
      if (other.files[entry.key] != entry.value) return false;
    }
    return true;
  }
}

abstract final class ApoTransit {
  static bool _rootReady = false;
  static final Set<String> _copied = {};
  static final Map<String, Future<void>> _publicationTails = {};
  static final Random _nonceRandom = Random.secure();
  static int _nonceCounter = 0;

  /// 中转根：%ProgramData%\AuraDSP\apo-assets（ProgramData 环境
  /// 变量缺失时回退到固定盘符口径）。
  static String get root {
    final pd = Platform.environment['ProgramData'] ?? r'C:\ProgramData';
    return '$pd${Platform.pathSeparator}AuraDSP'
        '${Platform.pathSeparator}apo-assets';
  }

  static bool isTransitPath(String path) {
    final norm = path.replaceAll('/', r'\').toLowerCase();
    // A ".." segment would resolve outside the root while passing
    // the prefix test; the host fence canonicalizes, this side
    // rejects outright so such a path is re-copied, not trusted.
    if (norm.split(r'\').contains('..')) return false;
    final r = root.replaceAll('/', r'\').toLowerCase();
    return norm == r || norm.startsWith('$r\\');
  }

  /// 确保中转根存在且 LocalService 可读：目录创建走当前用户
  /// 身份（ProgramData 下用户可建目录）；ACL 授予走平台层端口
  /// （WindowsSystemPort.grantDirReadToLocalService——icacls 按
  /// SID 授予，语言无关；第十八轮 CI 附带项：原先在此直连进程
  /// 调用触 F9/F10 平台隔离门，收回平台层。本类运行于音频隔
  /// 离体、无 AppModel 装配，经端口工厂 createWindowsSystemPort
  /// 取实现，与隔离体直调 createAudioOut 工厂同例。）每进程只做一次。
  static bool _ensureRoot(String? rootOverride) {
    if (rootOverride == null && _rootReady) return true;
    try {
      final target = rootOverride ?? root;
      final d = Directory(target);
      if (!d.existsSync()) d.createSync(recursive: true);
      if (rootOverride == null) {
        if (!createWindowsSystemPort().grantDirReadToLocalService(target)) {
          dbgLog('apo transit: LocalService read grant failed: $target');
          return false;
        }
        _rootReady = true;
      }
      // Isolated tests use rootOverride and must never grant a real ACL.
      return true;
    } catch (e) {
      if (rootOverride == null) _rootReady = false;
      dbgLog('apo transit: root prepare failed: $e');
      return false;
    }
  }

  static const String pluginUnsupportedMessage = '当前版本不支持在系统 APO 内加载第三方插件';

  /// APO 插件入口失败关闭：空路径仍用于显式卸载；任何非空插件路径
  /// 都返回带明确原因的失败结果，让现有槽位终态事件把“不支持”传给
  /// 状态消费方。不得复制后再返回路径，把生产宿主禁止的能力伪装成可用。
  static Future<ApoPluginTransitResult> transitPluginPathForAsync(
    String source,
  ) {
    if (source.isEmpty) {
      return Future.value(ApoPluginTransitResult(path: source));
    }
    dbgLog('apo transit: $pluginUnsupportedMessage: $source');
    return Future.value(
      const ApoPluginTransitResult(errorMessage: pluginUnsupportedMessage),
    );
  }

  static String _newNonce() {
    final random = List<int>.generate(
      16,
      (_) => _nonceRandom.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    return '${DateTime.now().microsecondsSinceEpoch}-'
        '${_nonceCounter++}-$random';
  }

  static String _uniqueSiblingPath(String destinationPath) {
    while (true) {
      final candidate = '$destinationPath.tmp-${_newNonce()}';
      if (!File(candidate).existsSync() && !Directory(candidate).existsSync()) {
        return candidate;
      }
    }
  }

  static String _publicationKey(String path) => PlatformProfile.os == 'windows'
      ? path.replaceAll('/', r'\').toLowerCase()
      : path;

  /// Serializes the check-and-commit section for one destination in this
  /// isolate. Temp writes remain independent and use unique sibling paths.
  static Future<void> _serializePublication(
    String destinationPath,
    Future<void> Function() publish,
  ) {
    final key = _publicationKey(destinationPath);
    final previous = _publicationTails[key] ?? Future<void>.value();
    final done = Completer<void>();
    _publicationTails[key] = done.future;
    return () async {
      try {
        await previous;
        await publish();
      } finally {
        done.complete();
        if (identical(_publicationTails[key], done.future)) {
          _publicationTails.remove(key);
        }
      }
    }();
  }

  static String _hashFromDestination(FileSystemEntity destination) {
    final name = destination.path.replaceAll('/', r'\').split(r'\').last;
    if (!RegExp(r'^[0-9a-f]{64}(?:\.|$)').hasMatch(name)) {
      throw ArgumentError.value(
        destination.path,
        'destination',
        'not a hash path',
      );
    }
    return name.substring(0, 64);
  }

  static Future<void> _deleteTempFile(File temp) async {
    try {
      if (await temp.exists()) await temp.delete();
    } catch (e) {
      dbgLog('apo transit: temp cleanup failed for ${temp.path}: $e');
    }
  }

  static Future<void> _deleteTempBundle(Directory temp) async {
    try {
      if (await temp.exists()) await temp.delete(recursive: true);
    } catch (e) {
      dbgLog('apo transit: temp bundle cleanup failed for ${temp.path}: $e');
    }
  }

  /// The temp file must already be flushed by the caller. The hash path is
  /// derived from [destination]; publication happens only after the temp bytes
  /// match it. File.rename provides replace-existing-file semantics on Windows
  /// and atomic same-volume rename on POSIX.
  static Future<void> _atomicWriteFile(File temp, File destination) {
    return _serializePublication(destination.path, () async {
      try {
        final expectedHash = _hashFromDestination(destination);
        final actualHash = sha256.convert(await temp.readAsBytes()).toString();
        if (actualHash != expectedHash) {
          throw StateError('APO transit temp hash mismatch: ${temp.path}');
        }
        if (await destination.exists()) {
          final existingHash = sha256
              .convert(await destination.readAsBytes())
              .toString();
          if (existingHash == expectedHash) {
            await _deleteTempFile(temp);
            return;
          }
        }
        await temp.rename(destination.path);
      } catch (e) {
        await _deleteTempFile(temp);
        rethrow;
      }
    });
  }

  static void _atomicWriteFileSync(File temp, File destination) {
    try {
      final key = _publicationKey(destination.path);
      if (_publicationTails.containsKey(key)) {
        throw StateError(
          'APO transit async publication pending for destination: '
          '${destination.path}',
        );
      }
      final expectedHash = _hashFromDestination(destination);
      final actualHash = sha256.convert(temp.readAsBytesSync()).toString();
      if (actualHash != expectedHash) {
        throw StateError('APO transit temp hash mismatch: ${temp.path}');
      }
      if (destination.existsSync()) {
        final existingHash = sha256
            .convert(destination.readAsBytesSync())
            .toString();
        if (existingHash == expectedHash) {
          _deleteTempFileSync(temp);
          return;
        }
      }
      temp.renameSync(destination.path);
    } catch (e) {
      _deleteTempFileSync(temp);
      rethrow;
    }
  }

  static void _deleteTempFileSync(File temp) {
    try {
      if (temp.existsSync()) temp.deleteSync();
    } catch (e) {
      dbgLog('apo transit: temp cleanup failed for ${temp.path}: $e');
    }
  }

  static String _relativeBundlePath(Directory root, FileSystemEntity entity) {
    final rootPath = root.absolute.path.replaceAll('/', r'\');
    final prefix = rootPath.endsWith(r'\') ? rootPath : rootPath + r'\';
    final entityPath = entity.absolute.path.replaceAll('/', r'\');
    if (!entityPath.startsWith(prefix)) {
      throw FileSystemException(
        'Bundle entry escaped source root',
        entity.path,
      );
    }
    final relative = entityPath.substring(prefix.length).replaceAll(r'\', '/');
    if (relative.isEmpty ||
        relative.split('/').any((part) => part.isEmpty || part == '..')) {
      throw FileSystemException('Invalid bundle relative path', entity.path);
    }
    return relative;
  }

  static String _bundlePath(Directory root, String relative) {
    final parts = relative.split('/');
    if (parts.any((part) => part.isEmpty || part == '.' || part == '..')) {
      throw ArgumentError.value(relative, 'relative', 'unsafe bundle path');
    }
    return '${root.path}${Platform.pathSeparator}'
        '${parts.join(Platform.pathSeparator)}';
  }

  static Future<_BundleManifest> _bundleManifest(Directory directory) async {
    final files = <String, String>{};
    final directories = <String>{};
    await for (final entity in directory.list(
      recursive: true,
      followLinks: false,
    )) {
      final relative = _relativeBundlePath(directory, entity);
      if (entity is File) {
        files[relative] = sha256.convert(await entity.readAsBytes()).toString();
      } else if (entity is Directory) {
        directories.add(relative);
      } else {
        throw FileSystemException('Unsupported bundle entry', entity.path);
      }
    }
    return _BundleManifest(files, directories);
  }

  static String? _findBundleModule(_BundleManifest manifest) {
    final String extension;
    final String preferredDirectory;
    final os = PlatformProfile.os;
    if (os == 'windows') {
      extension = '.vst3';
      preferredDirectory = 'contents/x86_64-win/';
    } else if (os == 'linux') {
      extension = '.so';
      preferredDirectory = 'contents/x86_64-linux/';
    } else if (os == 'macos') {
      extension = '.dylib';
      preferredDirectory = 'contents/macos/';
    } else {
      return null;
    }

    final paths = manifest.files.keys.toList()..sort();
    String? preferred;
    String? platformModule;
    for (final path in paths) {
      final lower = path.toLowerCase();
      if (!lower.endsWith(extension)) continue;
      platformModule ??= path;
      if (lower.startsWith(preferredDirectory) &&
          !lower.substring(preferredDirectory.length).contains('/')) {
        preferred ??= path;
      }
    }
    // Sorted fallback is deterministic, but an unrelated resource file is
    // never a substitute for a recognized platform module.
    return preferred ?? platformModule;
  }

  static Future<void> _copyBundleTree(
    Directory source,
    Directory temp,
    _BundleManifest manifest,
  ) async {
    final directories = manifest.directories.toList()
      ..sort((a, b) => a.split('/').length.compareTo(b.split('/').length));
    for (final relative in directories) {
      await Directory(_bundlePath(temp, relative)).create(recursive: true);
    }
    for (final entry in manifest.files.entries) {
      await File(_bundlePath(temp, entry.key)).writeAsBytes(
        await File(_bundlePath(source, entry.key)).readAsBytes(),
        flush: true,
      );
    }
  }

  static Future<void> _atomicPublishBundle(
    Directory temp,
    Directory destination,
  ) {
    return _serializePublication(destination.path, () async {
      try {
        final expectedHash = _hashFromDestination(destination);
        final manifest = await _bundleManifest(temp);
        final module = _findBundleModule(manifest);
        if (module == null) {
          throw StateError(
            'APO transit bundle has no main module: ${temp.path}',
          );
        }
        if (manifest.files[module] != expectedHash) {
          throw StateError(
            'APO transit bundle module hash mismatch: ${temp.path}',
          );
        }
        if (await destination.exists()) {
          final existing = await _bundleManifest(destination);
          if (!existing.matches(manifest)) {
            throw StateError(
              'APO transit bundle manifest mismatch: ${destination.path}',
            );
          }
          await _deleteTempBundle(temp);
          return;
        }
        await temp.rename(destination.path);
      } catch (e) {
        await _deleteTempBundle(temp);
        rethrow;
      }
    });
  }

  /// [transitPathFor] 的异步孪生（文件效果中转，与同步版共用同一份
  /// 已复制缓存）。[rootOverride] 仅供隔离测试，不授予真实根 ACL。
  static Future<String?> transitPathForAsync(
    String source, {
    String? rootOverride,
  }) async {
    try {
      if (source.isEmpty) return source;
      if (!_ensureRoot(rootOverride)) return null;
      if (isTransitPath(source)) return source;
      final f = File(source);
      if (!await f.exists()) {
        dbgLog('apo transit: source missing: $source');
        return null;
      }
      _ensureRoot(rootOverride);
      final bytes = await f.readAsBytes();
      final hash = sha256.convert(bytes).toString();
      final dot = source.lastIndexOf('.');
      final ext = dot >= 0 ? source.substring(dot).toLowerCase() : '';
      final dest =
          '${rootOverride ?? root}'
          '${Platform.pathSeparator}$hash$ext';
      if (_copied.contains(dest)) return dest;
      final df = File(dest);
      final temp = File(_uniqueSiblingPath(dest));
      try {
        await temp.writeAsBytes(bytes, flush: true);
        await _atomicWriteFile(temp, df);
      } catch (e, st) {
        await _deleteTempFile(temp);
        Error.throwWithStackTrace(e, st);
      }
      _copied.add(dest);
      dbgLog('apo transit: copied $source -> $dest (${bytes.length} B)');
      return dest;
    } catch (e) {
      dbgLog('apo transit: copy failed for $source: $e');
      return null;
    }
  }

  /// Generic VST3 bundle staging primitive. The production plugin entry remains
  /// fail-closed in [transitPluginPathForAsync]; this method does not publish a
  /// plugin path to the engine by itself.
  static Future<String?> transitBundlePathForAsync(
    String source, {
    String? rootOverride,
  }) async {
    try {
      final dir = Directory(source);
      if (!await dir.exists()) return null;
      _ensureRoot(rootOverride);
      final sourceManifest = await _bundleManifest(dir);
      final module = _findBundleModule(sourceManifest);
      if (module == null) {
        dbgLog('apo transit: plugin bundle empty: $source');
        return null;
      }
      final hash = sourceManifest.files[module]!;
      final dest =
          '${rootOverride ?? root}'
          '${Platform.pathSeparator}$hash.vst3';
      final destination = Directory(dest);
      final temp = Directory(_uniqueSiblingPath(dest));
      try {
        await temp.create(recursive: true);
        await _copyBundleTree(dir, temp, sourceManifest);
        final stagedManifest = await _bundleManifest(temp);
        if (stagedManifest.fileCount != sourceManifest.fileCount ||
            !stagedManifest.matches(sourceManifest)) {
          throw StateError(
            'APO transit bundle full-tree mismatch: ${temp.path}',
          );
        }
        if (stagedManifest.files[module] != hash) {
          throw StateError(
            'APO transit bundle module hash mismatch: ${temp.path}',
          );
        }
        await _atomicPublishBundle(temp, destination);
      } catch (e, st) {
        await _deleteTempBundle(temp);
        Error.throwWithStackTrace(e, st);
      }
      dbgLog('apo transit: bundle copied $source -> $dest');
      return dest;
    } catch (e) {
      dbgLog('apo transit: bundle copy failed for $source: $e');
      return null;
    }
  }

  /// Compatibility wrapper for isolated transit tests and callers that only
  /// need the path. The APO publisher uses [transitFileEffect] so a nullable
  /// path never erases the user-visible ACL/source/copy failure reason.
  static String? transitPathFor(String source, {String? rootOverride}) =>
      transitFileEffect(source, rootOverride: rootOverride).path;

  /// Returns either the staged path or a structured failure. An intentional
  /// empty source is a successful explicit unload and has no error message.
  static ApoFileTransitResult transitFileEffect(
    String source, {
    String? rootOverride,
  }) {
    try {
      if (source.isEmpty) return ApoFileTransitResult(path: source);
      if (!_ensureRoot(rootOverride)) {
        return const ApoFileTransitResult(
          errorMessage: 'transit root creation/LocalService ACL grant failed',
        );
      }
      if (isTransitPath(source)) return ApoFileTransitResult(path: source);
      final f = File(source);
      if (!f.existsSync()) {
        dbgLog('apo transit: source missing: $source');
        return const ApoFileTransitResult(
          errorMessage: 'source file is missing',
        );
      }
      final bytes = f.readAsBytesSync();
      final hash = sha256.convert(bytes).toString();
      final dot = source.lastIndexOf('.');
      final ext = dot >= 0 ? source.substring(dot).toLowerCase() : '';
      final dest =
          '${rootOverride ?? root}'
          '${Platform.pathSeparator}$hash$ext';
      if (_copied.contains(dest)) return ApoFileTransitResult(path: dest);
      final df = File(dest);
      final temp = File(_uniqueSiblingPath(dest));
      try {
        temp.writeAsBytesSync(bytes, flush: true);
        _atomicWriteFileSync(temp, df);
      } catch (e, st) {
        _deleteTempFileSync(temp);
        Error.throwWithStackTrace(e, st);
      }
      _copied.add(dest);
      dbgLog('apo transit: copied $source -> $dest (${bytes.length} B)');
      return ApoFileTransitResult(path: dest);
    } catch (e) {
      dbgLog('apo transit: copy failed for $source: $e');
      return ApoFileTransitResult(
        errorMessage: 'source read/transit copy failed: $e',
      );
    }
  }

  /// 中转孤儿回收（2026-11-23 后续小项轮）：中转根只进不出，
  /// 用户换 IR/DDC/插件后旧副本永久滞留。发布者把「当前参数
  /// 块与插件块实际引用的中转路径集合」交给本方法：不在集合
  /// 内、且最后修改时间早于 [minAge]（默认 7 天）的条目（文件
  /// 或 bundle 目录）删除。双条件是安全垫：audiodg 可能仍持
  /// 有旧参数块引用近期被替换的文件，刚复制尚未下发的副本
  /// mtime 即当前——只删「无引用且足够老」的。逐项失败吞掉
  /// 留日志（与本类既有口径一致），返回实际删除条数。
  /// [rootOverride]/[nowOverride] 仅供测试注入。
  static int collectOrphans(
    Set<String> referenced, {
    Duration minAge = const Duration(days: 7),
    String? rootOverride,
    DateTime? nowOverride,
  }) {
    final dir = Directory(rootOverride ?? root);
    List<FileSystemEntity> entries;
    try {
      if (!dir.existsSync()) return 0;
      entries = dir.listSync();
    } catch (e) {
      // An unguarded listing failure would abort the whole pass
      // and surface only as a generic isolate trace.
      dbgLog('apo transit GC: cannot list ${dir.path}: $e');
      return 0;
    }
    final now = nowOverride ?? DateTime.now();
    String norm(String p) => p.replaceAll('/', r'\').toLowerCase();
    final keep = referenced.map(norm).toSet();
    var removed = 0;
    for (final e in entries) {
      try {
        if (keep.contains(norm(e.path))) continue;
        if (now.difference(e.statSync().modified) < minAge) continue;
        if (e is Directory) {
          e.deleteSync(recursive: true);
        } else {
          e.deleteSync();
        }
        removed++;
        dbgLog('apo transit: orphan removed ${e.path}');
      } catch (err) {
        dbgLog('apo transit: orphan collect failed for ${e.path}: $err');
      }
    }
    if (removed > 0) {
      dbgLog('apo transit: orphan collect removed $removed entries');
    }
    return removed;
  }
}
