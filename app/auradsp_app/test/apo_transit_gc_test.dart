// apo_transit_gc_test.dart — ApoTransit.collectOrphans 判别：
// 引用集内的条目无论多老都保留；无引用且老于 minAge 的文件与
// bundle 目录被删；无引用但年轻的条目保留（安全垫）；根不存
// 在返回 0。全部在临时目录内完成，不触真实中转根。

import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:auradsp_app/engine/apo_transit.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';

typedef _AsyncWriteHandler = Future<void> Function(
  File file,
  List<int> bytes,
  FileMode mode,
  bool flush,
);
typedef _SyncWriteHandler = void Function(
  File file,
  List<int> bytes,
  FileMode mode,
  bool flush,
);
typedef _AsyncRenameHandler = Future<File> Function(File file, String newPath);
typedef _SyncRenameHandler = File Function(File file, String newPath);
typedef _DirectoryRenameHandler = Future<Directory> Function(
  Directory directory,
  String newPath,
);

/// Real filesystem operations with narrow hooks for deterministic interruption
/// and observation. No filesystem behavior is replaced by an in-memory fake.
final class _FileOverrides extends IOOverrides {
  _FileOverrides({
    this.onWrite,
    this.onWriteSync,
    this.onRename,
    this.onRenameSync,
    this.onDirectoryRename,
  });

  final _AsyncWriteHandler? onWrite;
  final _SyncWriteHandler? onWriteSync;
  final _AsyncRenameHandler? onRename;
  final _SyncRenameHandler? onRenameSync;
  final _DirectoryRenameHandler? onDirectoryRename;

  @override
  File createFile(String path) => _DelegatingFile(
    super.createFile(path),
    onWrite: onWrite,
    onWriteSync: onWriteSync,
    onRename: onRename,
    onRenameSync: onRenameSync,
  );

  @override
  Directory createDirectory(String path) => _DelegatingDirectory(
    super.createDirectory(path),
    onRename: onDirectoryRename,
  );
}

class _DelegatingFile implements File {
  _DelegatingFile(
    this._delegate, {
    this.onWrite,
    this.onWriteSync,
    this.onRename,
    this.onRenameSync,
  });

  final File _delegate;
  final _AsyncWriteHandler? onWrite;
  final _SyncWriteHandler? onWriteSync;
  final _AsyncRenameHandler? onRename;
  final _SyncRenameHandler? onRenameSync;

  @override
  String get path => _delegate.path;
  @override
  File get absolute => _delegate.absolute;
  @override
  Directory get parent => _delegate.parent;
  @override
  Uri get uri => _delegate.uri;
  @override
  Future<bool> exists() => _delegate.exists();
  @override
  bool existsSync() => _delegate.existsSync();
  @override
  Future<FileStat> stat() => _delegate.stat();
  @override
  FileStat statSync() => _delegate.statSync();
  @override
  Future<Uint8List> readAsBytes() => _delegate.readAsBytes();
  @override
  Uint8List readAsBytesSync() => _delegate.readAsBytesSync();
  @override
  Future<File> writeAsBytes(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) async {
    if (onWrite != null) {
      expect(flush, isTrue, reason: 'async staging writes must be flushed');
      await onWrite!(_delegate, bytes, mode, flush);
    } else {
      await _delegate.writeAsBytes(bytes, mode: mode, flush: flush);
    }
    return _delegate;
  }

  @override
  void writeAsBytesSync(
    List<int> bytes, {
    FileMode mode = FileMode.write,
    bool flush = false,
  }) {
    if (onWriteSync != null) {
      expect(flush, isTrue, reason: 'sync staging writes must be flushed');
      onWriteSync!(_delegate, bytes, mode, flush);
    } else {
      _delegate.writeAsBytesSync(bytes, mode: mode, flush: flush);
    }
  }

  @override
  Future<File> rename(String newPath) async => onRename != null
      ? onRename!(_delegate, newPath)
      : _delegate.rename(newPath);
  @override
  File renameSync(String newPath) => onRenameSync != null
      ? onRenameSync!(_delegate, newPath)
      : _delegate.renameSync(newPath);
  @override
  Future<File> delete({bool recursive = false}) async {
    await _delegate.delete(recursive: recursive);
    return _delegate;
  }

  @override
  void deleteSync({bool recursive = false}) =>
      _delegate.deleteSync(recursive: recursive);
  @override
  Future<RandomAccessFile> open({FileMode mode = FileMode.read}) =>
      _delegate.open(mode: mode);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DelegatingDirectory implements Directory {
  _DelegatingDirectory(this._delegate, {this.onRename});

  final Directory _delegate;
  final _DirectoryRenameHandler? onRename;

  @override
  String get path => _delegate.path;
  @override
  Directory get absolute => _delegate.absolute;
  @override
  Directory get parent => _delegate.parent;
  @override
  Uri get uri => _delegate.uri;
  @override
  Future<bool> exists() => _delegate.exists();
  @override
  bool existsSync() => _delegate.existsSync();
  @override
  Future<Directory> create({bool recursive = false}) async {
    await _delegate.create(recursive: recursive);
    return _delegate;
  }

  @override
  Directory createSync({bool recursive = false}) {
    _delegate.createSync(recursive: recursive);
    return _delegate;
  }

  @override
  Stream<FileSystemEntity> list({
    bool recursive = false,
    bool followLinks = true,
  }) => _delegate.list(recursive: recursive, followLinks: followLinks);
  @override
  List<FileSystemEntity> listSync({
    bool recursive = false,
    bool followLinks = true,
  }) => _delegate.listSync(recursive: recursive, followLinks: followLinks);
  @override
  Future<Directory> rename(String newPath) async => onRename != null
      ? onRename!(_delegate, newPath)
      : _delegate.rename(newPath);
  @override
  Future<Directory> delete({bool recursive = false}) async {
    await _delegate.delete(recursive: recursive);
    return _delegate;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

List<int> _patternBytes(int length) =>
    List<int>.generate(length, (index) => (index * 31 + 7) & 0xff);

String _sha256(List<int> bytes) => sha256.convert(bytes).toString();

void main() {
  group('ApoTransit.collectOrphans', () {
    late Directory tmp;
    // 逻辑时钟 = 真实时间 +31 天：dart:io 无目录 mtime 设置 API，
    // 故 bundle 目录用真实创建时间、靠 nowOverride 把它推入
    // 「老」区间；文件则可直接 setLastModifiedSync 到逻辑时刻。
    final now = DateTime.now().add(const Duration(days: 31));
    final old = now.subtract(const Duration(days: 30));
    final young = now.subtract(const Duration(days: 1));

    File makeFile(String name, DateTime mtime) {
      final f = File('${tmp.path}${Platform.pathSeparator}$name');
      f.writeAsStringSync('x');
      f.setLastModifiedSync(mtime);
      return f;
    }

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('apo_gc_test');
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('keeps referenced, deletes old unreferenced, spares young', () {
      final kept = makeFile('keep.wav', old);
      final stale = makeFile('stale.wav', old);
      final fresh = makeFile('fresh.wav', young);
      final bundle = Directory('${tmp.path}${Platform.pathSeparator}abc.vst3')
        ..createSync();
      File('${bundle.path}${Platform.pathSeparator}mod.vst3')
          .writeAsStringSync('y');

      final removed = ApoTransit.collectOrphans(
        {kept.path},
        rootOverride: tmp.path,
        nowOverride: now,
      );

      expect(removed, 2, reason: 'stale file + stale bundle dir');
      expect(kept.existsSync(), isTrue);
      expect(stale.existsSync(), isFalse);
      expect(
        fresh.existsSync(),
        isTrue,
        reason: 'young unreferenced entries are the safety margin',
      );
      expect(bundle.existsSync(), isFalse);
    });

    test('missing root is a no-op', () {
      expect(
        ApoTransit.collectOrphans(
          const {},
          rootOverride: '${tmp.path}${Platform.pathSeparator}does-not-exist',
          nowOverride: now,
        ),
        0,
      );
    });

    test('referenced matching is slash/case tolerant', () {
      final kept = makeFile('KeepCase.WAV', old);
      final removed = ApoTransit.collectOrphans(
        {kept.path.replaceAll(r'\', '/').toUpperCase()},
        rootOverride: tmp.path,
        nowOverride: now,
      );
      expect(removed, 0);
      expect(kept.existsSync(), isTrue);
    });
  });

  group('ApoTransit.atomic publication', () {
    late Directory tmp;
    late Directory root;
    late File source;
    late List<int> bytes;
    late File destination;
    late Directory bundle;
    late List<int> moduleBytes;
    late String moduleRelativePath;
    late Directory bundleDestination;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('apo_atomic_test');
      root = Directory('${tmp.path}${Platform.pathSeparator}transit')
        ..createSync();
      bytes = _patternBytes(256 * 1024);
      source = File('${tmp.path}${Platform.pathSeparator}source.wav')
        ..writeAsBytesSync(bytes);
      destination = File(
        '${root.path}${Platform.pathSeparator}${_sha256(bytes)}.wav',
      );
      moduleBytes = _patternBytes(4096);
      moduleRelativePath = Platform.isWindows
          ? 'Contents/x86_64-win/module.vst3'
          : Platform.isLinux
          ? 'Contents/x86_64-linux/module.so'
          : 'Contents/MacOS/module.dylib';
      bundle = Directory('${tmp.path}${Platform.pathSeparator}source.vst3');
      final module = File(
        '${bundle.path}${Platform.pathSeparator}'
        '${moduleRelativePath.replaceAll('/', Platform.pathSeparator)}',
      );
      module.parent.createSync(recursive: true);
      module.writeAsBytesSync(moduleBytes);
      File('${bundle.path}${Platform.pathSeparator}resource.bin')
          .writeAsBytesSync(_patternBytes(8192));
      bundleDestination = Directory(
        '${root.path}${Platform.pathSeparator}${_sha256(moduleBytes)}.vst3',
      );
    });

    tearDown(() {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    });

    test('failed temp write leaves no final hash file', () async {
      final result = await IOOverrides.runWithIOOverrides(
        () => ApoTransit.transitPathForAsync(
          source.path,
          rootOverride: root.path,
        ),
        _FileOverrides(
          onWrite: (file, pending, mode, flush) async {
            await file.writeAsBytes(
              pending.take(17).toList(),
              mode: mode,
              flush: flush,
            );
            throw const FileSystemException('injected temp write failure');
          },
        ),
      );

      expect(result, isNull);
      expect(destination.existsSync(), isFalse);
      expect(root.listSync(), isEmpty);
    });

    test(
      'identical existing destination is preserved without replacement',
      () async {
        final fixedMtime = DateTime(2001, 2, 3, 4, 5, 6);
        destination.writeAsBytesSync(bytes);
        destination.setLastModifiedSync(fixedMtime);
        var destinationWrites = 0;
        var destinationRenames = 0;

        final result = await IOOverrides.runWithIOOverrides(
          () => ApoTransit.transitPathForAsync(
            source.path,
            rootOverride: root.path,
          ),
          _FileOverrides(
            onWrite: (file, pending, mode, flush) async {
              if (file.path == destination.path) destinationWrites++;
              await file.writeAsBytes(pending, mode: mode, flush: flush);
            },
            onRename: (file, newPath) async {
              if (newPath == destination.path) destinationRenames++;
              return file.rename(newPath);
            },
          ),
        );

        expect(result, destination.path);
        expect(destination.readAsBytesSync(), bytes);
        expect(destination.statSync().modified, fixedMtime);
        expect(destinationWrites, 0);
        expect(destinationRenames, 0);
        expect(root.listSync().map((entity) => entity.path), [
          destination.path,
        ]);
      },
    );

    test('corrupt existing hash file is atomically replaced', () async {
      destination.writeAsBytesSync(_patternBytes(97));

      final result = await ApoTransit.transitPathForAsync(
        source.path,
        rootOverride: root.path,
      );

      expect(result, destination.path);
      expect(destination.readAsBytesSync(), bytes);
      expect(root.listSync().map((entity) => entity.path), [destination.path]);
    });

    test('file rename failure cleans temp and preserves destination', () async {
      destination.writeAsBytesSync(_patternBytes(101));
      final before = destination.readAsBytesSync();

      final result = await IOOverrides.runWithIOOverrides(
        () => ApoTransit.transitPathForAsync(
          source.path,
          rootOverride: root.path,
        ),
        _FileOverrides(
          onRename: (file, newPath) async {
            if (newPath == destination.path) {
              throw const FileSystemException('injected file rename failure');
            }
            return file.rename(newPath);
          },
        ),
      );

      expect(result, isNull);
      expect(destination.readAsBytesSync(), before);
      expect(root.listSync().map((entity) => entity.path), [destination.path]);
    });

    test('concurrent publishers share one complete commit', () async {
      var finalWrites = 0;
      var commits = 0;
      final results = await Future.wait([
        IOOverrides.runWithIOOverrides(
          () => ApoTransit.transitPathForAsync(
            source.path,
            rootOverride: root.path,
          ),
          _FileOverrides(
            onWrite: (file, pending, mode, flush) async {
              if (file.path == destination.path) finalWrites++;
              await file.writeAsBytes(pending, mode: mode, flush: flush);
            },
            onRename: (file, newPath) async {
              if (newPath == destination.path) commits++;
              return file.rename(newPath);
            },
          ),
        ),
        IOOverrides.runWithIOOverrides(
          () => ApoTransit.transitPathForAsync(
            source.path,
            rootOverride: root.path,
          ),
          _FileOverrides(
            onWrite: (file, pending, mode, flush) async {
              if (file.path == destination.path) finalWrites++;
              await file.writeAsBytes(pending, mode: mode, flush: flush);
            },
            onRename: (file, newPath) async {
              if (newPath == destination.path) commits++;
              return file.rename(newPath);
            },
          ),
        ),
      ]);

      expect(results, [destination.path, destination.path]);
      expect(destination.readAsBytesSync(), bytes);
      expect(
        finalWrites,
        0,
        reason: 'final hash path is never written directly',
      );
      expect(commits, 1, reason: 'same-hash publishers have one committer');
      expect(root.listSync().map((entity) => entity.path), [destination.path]);
    });

    test('sync publication rejects a pending async publication', () async {
      final renameStarted = Completer<void>();
      final releaseRename = Completer<void>();
      var commits = 0;
      final asyncPublication = IOOverrides.runWithIOOverrides(
        () => ApoTransit.transitPathForAsync(
          source.path,
          rootOverride: root.path,
        ),
        _FileOverrides(
          onRename: (file, newPath) async {
            if (newPath == destination.path) {
              commits++;
              if (!renameStarted.isCompleted) renameStarted.complete();
              await releaseRename.future;
            }
            return file.rename(newPath);
          },
        ),
      );

      await renameStarted.future.timeout(const Duration(seconds: 5));
      final syncResult = IOOverrides.runWithIOOverrides(
        () => ApoTransit.transitPathFor(source.path, rootOverride: root.path),
        _FileOverrides(
          onWriteSync: (file, pending, mode, flush) {
            file.writeAsBytesSync(pending, mode: mode, flush: flush);
          },
          onRenameSync: (file, newPath) {
            if (newPath == destination.path) commits++;
            return file.renameSync(newPath);
          },
        ),
      );
      releaseRename.complete();
      final asyncResult = await asyncPublication;

      expect(syncResult, isNull, reason: 'sync must not block on async work');
      expect(asyncResult, destination.path);
      expect(commits, 1, reason: 'mixed paths have at most one committer');
      expect(destination.readAsBytesSync(), bytes);
      expect(root.listSync().map((entity) => entity.path), [destination.path]);
    });

    test('interrupted bundle copy leaves no final directory', () async {
      final result = await IOOverrides.runWithIOOverrides(
        () => ApoTransit.transitBundlePathForAsync(
          bundle.path,
          rootOverride: root.path,
        ),
        _FileOverrides(
          onWrite: (file, pending, mode, flush) async {
            await file.writeAsBytes(
              pending.take(23).toList(),
              mode: mode,
              flush: flush,
            );
            throw const FileSystemException('injected bundle copy failure');
          },
        ),
      );

      expect(result, isNull);
      expect(bundleDestination.existsSync(), isFalse);
      expect(root.listSync(), isEmpty);
    });

    test('corrupt temp bytes are rejected before final publication', () async {
      final result = await IOOverrides.runWithIOOverrides(
        () => ApoTransit.transitPathForAsync(
          source.path,
          rootOverride: root.path,
        ),
        _FileOverrides(
          onWrite: (file, pending, mode, flush) async {
            await file.writeAsBytes(
              pending.take(31).toList(),
              mode: mode,
              flush: flush,
            );
          },
        ),
      );

      expect(result, isNull);
      expect(destination.existsSync(), isFalse);
      expect(root.listSync(), isEmpty);
    });

    test('synchronous transit also leaves no partial final file', () {
      final result = IOOverrides.runWithIOOverrides(
        () => ApoTransit.transitPathFor(source.path, rootOverride: root.path),
        _FileOverrides(
          onWriteSync: (file, pending, mode, flush) {
            file.writeAsBytesSync(
              pending.take(19).toList(),
              mode: mode,
              flush: flush,
            );
            throw const FileSystemException('injected sync write failure');
          },
        ),
      );

      expect(result, isNull);
      expect(destination.existsSync(), isFalse);
      expect(root.listSync(), isEmpty);
    });

    test('resource-only bundle is rejected without a main module', () async {
      File(
        '${bundle.path}${Platform.pathSeparator}'
        '${moduleRelativePath.replaceAll('/', Platform.pathSeparator)}',
      ).deleteSync();

      final result = await ApoTransit.transitBundlePathForAsync(
        bundle.path,
        rootOverride: root.path,
      );

      expect(result, isNull);
      expect(bundleDestination.existsSync(), isFalse);
      expect(root.listSync(), isEmpty);
    });

    test(
      'bundle publishes only after full-tree hash and count verification',
      () async {
        final result = await ApoTransit.transitBundlePathForAsync(
          bundle.path,
          rootOverride: root.path,
        );

        expect(result, bundleDestination.path);
        expect(
          File(
            '${bundleDestination.path}${Platform.pathSeparator}'
            '${moduleRelativePath.replaceAll('/', Platform.pathSeparator)}',
          ).readAsBytesSync(),
          moduleBytes,
        );
        expect(
          File('${bundleDestination.path}${Platform.pathSeparator}resource.bin')
              .readAsBytesSync(),
          _patternBytes(8192),
        );
        expect(root.listSync().map((entity) => entity.path), [
          bundleDestination.path,
        ]);
      },
    );

    test(
      'bundle full-tree corruption is rejected without final directory',
      () async {
        final result = await IOOverrides.runWithIOOverrides(
          () => ApoTransit.transitBundlePathForAsync(
            bundle.path,
            rootOverride: root.path,
          ),
          _FileOverrides(
            onWrite: (file, pending, mode, flush) async {
              if (file.path.endsWith('resource.bin')) {
                await file.writeAsBytes(
                  pending.take(37).toList(),
                  mode: mode,
                  flush: flush,
                );
              } else {
                await file.writeAsBytes(pending, mode: mode, flush: flush);
              }
            },
          ),
        );

        expect(result, isNull);
        expect(bundleDestination.existsSync(), isFalse);
        expect(root.listSync(), isEmpty);
      },
    );

    test('bundle file-count mismatch is rejected before publication', () async {
      final result = await IOOverrides.runWithIOOverrides(
        () => ApoTransit.transitBundlePathForAsync(
          bundle.path,
          rootOverride: root.path,
        ),
        _FileOverrides(
          onWrite: (file, pending, mode, flush) async {
            if (!file.path.endsWith('resource.bin')) {
              await file.writeAsBytes(pending, mode: mode, flush: flush);
            }
          },
        ),
      );

      expect(result, isNull);
      expect(bundleDestination.existsSync(), isFalse);
      expect(root.listSync(), isEmpty);
    });

    test(
      'identical existing bundle is preserved by manifest comparison',
      () async {
        expect(
          await ApoTransit.transitBundlePathForAsync(
            bundle.path,
            rootOverride: root.path,
          ),
          bundleDestination.path,
        );
        final module = File(
          '${bundleDestination.path}${Platform.pathSeparator}'
          '${moduleRelativePath.replaceAll('/', Platform.pathSeparator)}',
        );
        final before = module.statSync();
        var renames = 0;

        final result = await IOOverrides.runWithIOOverrides(
          () => ApoTransit.transitBundlePathForAsync(
            bundle.path,
            rootOverride: root.path,
          ),
          _FileOverrides(
            onDirectoryRename: (directory, newPath) async {
              if (newPath == bundleDestination.path) renames++;
              return directory.rename(newPath);
            },
          ),
        );

        expect(result, bundleDestination.path);
        expect(module.statSync().modified, before.modified);
        expect(renames, 0);
        expect(root.listSync().map((entity) => entity.path), [
          bundleDestination.path,
        ]);
      },
    );

    test(
      'bundle rename failure cleans temp and preserves destination',
      () async {
        final result = await IOOverrides.runWithIOOverrides(
          () => ApoTransit.transitBundlePathForAsync(
            bundle.path,
            rootOverride: root.path,
          ),
          _FileOverrides(
            onDirectoryRename: (directory, newPath) async {
              if (newPath == bundleDestination.path) {
                throw const FileSystemException(
                  'injected bundle rename failure',
                );
              }
              return directory.rename(newPath);
            },
          ),
        );

        expect(result, isNull);
        expect(bundleDestination.existsSync(), isFalse);
        expect(root.listSync(), isEmpty);
      },
    );

    test('different existing bundle manifest fails closed', () async {
      expect(
        await ApoTransit.transitBundlePathForAsync(
          bundle.path,
          rootOverride: root.path,
        ),
        bundleDestination.path,
      );
      final resource = File(
        '${bundleDestination.path}${Platform.pathSeparator}resource.bin',
      )..writeAsBytesSync(_patternBytes(9000));
      final before = resource.readAsBytesSync();

      final result = await ApoTransit.transitBundlePathForAsync(
        bundle.path,
        rootOverride: root.path,
      );

      expect(result, isNull);
      expect(resource.readAsBytesSync(), before);
      expect(root.listSync().map((entity) => entity.path), [
        bundleDestination.path,
      ]);
    });

    test('concurrent bundle publishers share one complete commit', () async {
      var commits = 0;
      final results = await Future.wait([
        IOOverrides.runWithIOOverrides(
          () => ApoTransit.transitBundlePathForAsync(
            bundle.path,
            rootOverride: root.path,
          ),
          _FileOverrides(
            onDirectoryRename: (directory, newPath) async {
              if (newPath == bundleDestination.path) commits++;
              return directory.rename(newPath);
            },
          ),
        ),
        IOOverrides.runWithIOOverrides(
          () => ApoTransit.transitBundlePathForAsync(
            bundle.path,
            rootOverride: root.path,
          ),
          _FileOverrides(
            onDirectoryRename: (directory, newPath) async {
              if (newPath == bundleDestination.path) commits++;
              return directory.rename(newPath);
            },
          ),
        ),
      ]);

      expect(results, [bundleDestination.path, bundleDestination.path]);
      expect(commits, 1);
      expect(
        File(
          '${bundleDestination.path}${Platform.pathSeparator}'
          '${moduleRelativePath.replaceAll('/', Platform.pathSeparator)}',
        ).readAsBytesSync(),
        moduleBytes,
      );
      expect(
        File('${bundleDestination.path}${Platform.pathSeparator}resource.bin')
            .readAsBytesSync(),
        _patternBytes(8192),
      );
      expect(root.listSync().map((entity) => entity.path), [
        bundleDestination.path,
      ]);
    });
  });

  group('ApoTransit.transitPluginPathForAsync', () {
    test(
      'rejects non-empty APO plugin paths instead of publishing them',
      () async {
        // Already-transit-shaped input takes the old fast path without any IO;
        // the new contract must reject it before that path can be published.
        final source =
            '${ApoTransit.root}${Platform.pathSeparator}'
            'task2-controlled-fixture.clap';
        final result = await ApoTransit.transitPluginPathForAsync(source);
        expect(result, isNotNull);
        expect(result.path, isNull);
        expect(result.errorMessage, contains('不支持'));
        expect(result.errorMessage, contains('系统 APO'));
      },
    );

    test('keeps empty path as an explicit unload', () async {
      final result = await ApoTransit.transitPluginPathForAsync('');
      expect(result, isNotNull);
      expect(result.path, '');
      expect(result.errorMessage, isNull);
    });
  });
}
