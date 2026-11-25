/// ZIP-P 载荷处理（设计 §2/§5）：从 Setup exe 切出载荷段落盘，
/// 再按组件过滤流式解压到安装目录，逐文件算 SHA256 生成清单条目。
library;

import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

import 'models.dart';
import 'update_policy.dart';

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// 解压上限（2026-11-08 审计 F4）：条目数与解压总量设顶，防高膨胀
/// 比载荷写满安装盘（引导壳侧对段长有硬顶，向导侧此前无对应约束）。
const _kMaxPayloadEntries = 100000;
const _kMaxPayloadBytes = 4 * 1024 * 1024 * 1024; // 4 GiB

/// 是否为「文件被其他进程占用」类错误（ERROR_SHARING_VIOLATION
/// = 32 / ERROR_LOCK_VIOLATION = 33）：audiodg 把 AuraApo.dll
/// 映射为镜像时，任何写打开都以 32 拒绝。
bool isLockError(Object e) =>
    e is FileSystemException &&
    (e.osError?.errorCode == 32 || e.osError?.errorCode == 33);

/// 探针：目标文件当前是否可写。append 打开不截断、不改内容，
/// 只验证写打开能否成功；被镜像映射的文件会以 errno 32 被
/// 拒。文件不存在视为可写（写路径会创建它）。
Future<bool> probeFileWritable(String path) async {
  final f = File(path);
  if (!await f.exists()) return true;
  RandomAccessFile? raf;
  try {
    raf = await f.open(mode: FileMode.append);
    return true;
  } on FileSystemException {
    return false;
  } finally {
    await raf?.close();
  }
}

/// 写一个载荷条目到目标文件，对被占用文件做「短重试 → 改名
/// 让位 → 再写」（2026-11-12 业主实测：覆盖安装时 AuraApo.dll
/// 仍被 audiodg 占用，裸写抛 PathAccessException 致整单失败
/// 回滚）。镜像映射的文件可改名、不可覆盖——改名让位是不依
/// 赖对方进程退出的唯一解。让位文件以 `.aside-<毫秒>` 后缀
/// 留在原地，经 [onAside] 报告；安装启动时由向导扫除。
Future<void> writeEntryResilient(
  ArchiveFile entry,
  File target, {
  void Function(String asidePath)? onAside,
  Future<void> Function(Duration)? sleep,
  Future<void> Function()? writeAttempt,
}) async {
  final doSleep = sleep ?? Future.delayed;
  Future<void> attempt() async {
    if (writeAttempt != null) return writeAttempt();
    final out = OutputFileStream(target.path);
    entry.writeContent(out);
    await out.close();
  }

  for (var i = 0; i < 3; i++) {
    try {
      await attempt();
      return;
    } on FileSystemException catch (e) {
      if (!isLockError(e)) rethrow;
      if (i < 2) await doSleep(const Duration(milliseconds: 400));
    }
  }
  final asidePath =
      '${target.path}.aside-${DateTime.now().millisecondsSinceEpoch}';
  await target.rename(asidePath);
  onAside?.call(asidePath);
  await attempt();
}

/// 在同一 FILE_SHARE_READ 句柄内完成摘要与切片，杜绝验后替换/修改。
Future<void> verifyAndSlicePayload(
  String setupExe,
  int off,
  int len,
  String? expected,
  String destFile,
) async {
  if (expected == null || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(expected)) {
    throw StateError('missing trusted payload SHA256');
  }
  if (off < 0 || len < 0) throw StateError('invalid payload range');
  final nativePath = p.canonicalize(p.absolute(setupExe)).toNativeUtf16();
  final handle = CreateFile(
    nativePath,
    GENERIC_READ,
    FILE_SHARE_READ,
    nullptr,
    OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL,
    0,
  );
  free(nativePath);
  if (handle == INVALID_HANDLE_VALUE) {
    throw StateError('cannot open setup payload: ${GetLastError()}');
  }

  final buffer = calloc<Uint8>(1 << 20);
  final read = calloc<DWORD>();
  final digestOutput = _DigestSink();
  final digestInput = sha256.startChunkedConversion(digestOutput);
  final sink = File(destFile).openWrite();
  var sinkClosed = false;
  try {
    if (SetFilePointerEx(handle, off, nullptr, 0) == 0) {
      throw StateError('cannot seek setup payload: ${GetLastError()}');
    }
    var left = len;
    while (left > 0) {
      final want = left > (1 << 20) ? (1 << 20) : left;
      if (ReadFile(handle, buffer, want, read, nullptr) == 0) {
        throw StateError('cannot read setup payload: ${GetLastError()}');
      }
      if (read.value == 0 || read.value > left) {
        throw StateError('载荷段读取不完整');
      }
      final chunk = Uint8List.fromList(buffer.asTypedList(read.value));
      digestInput.add(chunk);
      sink.add(chunk);
      left -= read.value;
    }
    digestInput.close();
    await sink.close();
    sinkClosed = true;
    if (digestOutput.value.toString() != expected.toLowerCase()) {
      throw StateError('elevated payload SHA256 mismatch');
    }
  } finally {
    if (!sinkClosed) await sink.close();
    CloseHandle(handle);
    calloc.free(buffer);
    calloc.free(read);
  }
}

/// 从提权 bootstrapper 固定在 protected session 的完整 Setup 映像生成
/// 卸载器。复制源包含 bootstrapper、ZIP-W、ZIP-P 与 footer，因而可独立
/// 启动；原 Setup 路径在载荷切片后可能已被替换，不再作为卸载器来源。
Future<void> copyProtectedSetupUninstaller(
  String setupImage,
  String destFile,
) async {
  final nativePath = p.canonicalize(p.absolute(setupImage)).toNativeUtf16();
  final handle = CreateFile(
    nativePath,
    GENERIC_READ,
    FILE_SHARE_READ,
    nullptr,
    OPEN_EXISTING,
    FILE_ATTRIBUTE_NORMAL,
    0,
  );
  free(nativePath);
  if (handle == INVALID_HANDLE_VALUE) {
    throw StateError('cannot open protected setup image: ${GetLastError()}');
  }

  final buffer = calloc<Uint8>(1 << 20);
  final read = calloc<DWORD>();
  final sink = File(destFile).openWrite();
  var sinkClosed = false;
  try {
    while (true) {
      if (ReadFile(handle, buffer, 1 << 20, read, nullptr) == 0) {
        throw StateError('cannot read protected setup image: ${GetLastError()}');
      }
      if (read.value == 0) break;
      sink.add(Uint8List.fromList(buffer.asTypedList(read.value)));
    }
    await sink.close();
    sinkClosed = true;
  } finally {
    if (!sinkClosed) await sink.close();
    CloseHandle(handle);
    calloc.free(buffer);
    calloc.free(read);
  }
}

/// 组件过滤：返回该相对路径（payload/ 前缀已剥离）是否应解压。
///
/// driver/ 恒保留——「不勾选驱动」只表示不执行安装/注册，驱动文件与
/// 手动安装脚本仍必须落在安装目录，供用户事后以管理员身份补装。
bool Function(String rel) componentFilter({required bool ddcPresets}) {
  return (rel) {
    if (rel.startsWith('resources/ddc/') && !ddcPresets) return false;
    return true;
  };
}

String _payloadRelativePath(String name) {
  var rel = name.replaceAll('\\', '/');
  if (!rel.startsWith('payload/')) {
    throw StateError('载荷条目缺少 payload/ 前缀: $name');
  }
  rel = rel.substring('payload/'.length);
  final normalized = p.posix.normalize(rel);
  if (rel.isEmpty ||
      normalized != rel ||
      normalized == '.' ||
      normalized.startsWith('../') ||
      p.posix.isAbsolute(normalized) ||
      RegExp(r'^[A-Za-z]:').hasMatch(normalized)) {
    throw StateError('载荷含非法路径: $name');
  }
  return normalized;
}

Map<String, ManifestFile> _trustedPayloadFiles(List<ManifestFile> files) {
  final trusted = <String, ManifestFile>{};
  for (final file in files) {
    final path = _payloadRelativePath('payload/${file.path}');
    final key = path.toLowerCase();
    if (trusted.containsKey(key)) {
      throw StateError('可信载荷清单含重复路径: $path');
    }
    if (file.size < 0 || !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(file.sha256)) {
      throw StateError('可信载荷清单条目无效: $path');
    }
    trusted[key] = ManifestFile(
      path: path,
      size: file.size,
      sha256: file.sha256.toLowerCase(),
    );
  }
  return trusted;
}

/// 独立解码一遍做全量预检，避免把全部解压内容留在内存中。
Future<void> _preflightPayload(
  String zipPath,
  List<ManifestFile> trustedFiles,
) async {
  final trusted = _trustedPayloadFiles(trustedFiles);
  final actual = <String>{};
  final input = InputFileStream(zipPath);
  try {
    final decoder = ZipDecoder();
    final archive = decoder.decodeStream(input);
    final rawFiles = decoder.directory.fileHeaders.where((header) {
      final entryMode = header.externalFileAttributes >> 16;
      return !header.filename.endsWith('/') &&
          !header.filename.endsWith('\\') &&
          (entryMode & 0xF000) != 0x4000;
    }).toList();
    if (rawFiles.length > _kMaxPayloadEntries ||
        rawFiles.length != trusted.length) {
      throw StateError('载荷文件集合与可信清单不一致');
    }
    for (final header in rawFiles) {
      final path = _payloadRelativePath(header.filename);
      final key = path.toLowerCase();
      if (!trusted.containsKey(key)) {
        throw StateError('载荷含可信清单外条目: $path');
      }
      if (!actual.add(key)) {
        throw StateError('载荷含重复条目: $path');
      }
    }
    final entries = archive.files.where((file) => file.isFile).toList();
    if (entries.length != rawFiles.length) {
      throw StateError('载荷中央目录与文件集合不一致');
    }
    for (final entry in entries) {
      final path = _payloadRelativePath(entry.name);
      final expected = trusted[path.toLowerCase()]!;
      final bytes = entry.readBytes();
      if (bytes == null ||
          bytes.length != entry.size ||
          entry.size != expected.size) {
        throw StateError('载荷条目大小与可信清单不一致: $path');
      }
      if (sha256.convert(bytes).toString() != expected.sha256) {
        throw StateError('载荷条目摘要与可信清单不一致: $path');
      }
      await entry.close();
    }
    if (actual.length != trusted.length) {
      throw StateError('载荷缺少可信清单条目');
    }
  } finally {
    await input.close();
  }
}

/// 解压载荷 zip 到 destDir（含 payload/ 前缀剥离与路径穿越防护）。
/// onFile 每完成一个文件回调一次（进度与日志）。
///
/// [onFileError] 是单文件写入失败时的决策回调（重试 / 跳过 /
/// 取消，仿 Windows Installer）：未提供（静默模式）时失败直接
/// 抛出、整单终止。被跳过的文件进 [skippedSink]、不进返回清单；
/// 改名让位产生的文件进 [asideSink]，由调用方收尾清理。
Future<List<ManifestFile>> extractPayload(
  String zipPath,
  String destDir, {
  required bool Function(String rel) include,
  required List<ManifestFile> trustedFiles,
  void Function(String rel, int done, int total)? onFile,
  void Function(String warning)? onWarning,
  FileErrorHandler? onFileError,
  List<String>? skippedSink,
  List<String>? asideSink,
}) async {
  await _preflightPayload(zipPath, trustedFiles);
  await Directory(destDir).create(recursive: true);
  final input = InputFileStream(zipPath);
  final archive = ZipDecoder().decodeStream(input);
  final entries = archive.files.where((f) => f.isFile).toList();
  if (entries.length > _kMaxPayloadEntries) {
    throw StateError('载荷条目数超上限: ${entries.length}');
  }
  final total = entries.length;
  final written = <ManifestFile>[];
  final destRoot = Directory(destDir).absolute;
  var done = 0;
  var totalBytes = 0;
  try {
    for (final entry in entries) {
      final rel = _payloadRelativePath(entry.name);
      if (!include(rel)) {
        done++;
        continue;
      }
      totalBytes += entry.size;
      if (totalBytes > _kMaxPayloadBytes) {
        throw StateError('载荷解压总量超上限: $totalBytes');
      }
      // 路径穿越防护（2026-11-08 审计 F1）：旧实现是裸字符串前缀
      // 匹配，`../AuraDSP2/evil.dll` 能借同前缀兄弟目录绕过。改用
      // package:path 的词法归一 + isWithin（分隔符感知）判定。
      final targetPath = p.normalize(p.join(destRoot.path, rel));
      if (!p.isWithin(destRoot.path, targetPath)) {
        throw StateError('载荷含越界路径: ${entry.name}');
      }
      final target = File(targetPath);
      String? asidePath;
      var skippedFile = false;
      // 单文件的「写 + 校验」是一段可重试的活：硬失败（非占用、
      // 或让位也救不了）时把现场交给 onFileError 决策。重试就
      // 整段重来（写是截断式重写，部分写无残留问题）；跳过时
      // 若让位已发生而目标缺失，尽力把旧文件改名恢复，使覆盖
      // 安装的「跳过 = 保留旧版」成立。
      while (true) {
        try {
          await target.parent.create(recursive: true);
          await writeEntryResilient(
            entry,
            target,
            onAside: (ap) {
              asidePath = ap;
              asideSink?.add(ap);
              onWarning?.call(
                '$rel 仍被其他进程占用，已将旧文件改名让位'
                '（${p.basename(ap)}），新版已写入；'
                '让位文件将在下次安装/卸载时清理',
              );
            },
          );
          // 流式算 SHA + 长度（2026-11-12 内存治理）：旧实现把每个
          // 落盘文件整份 readAsBytes 回内存只为算哈希，大文件（数十
          // MB 级 DLL/资源）逐个制造同等大小的内存峰值；改 1MB 分块
          // 流式摘要后峰值与文件大小脱钩。
          final digest = await sha256.bind(target.openRead()).single;
          written.add(
            ManifestFile(
              path: rel,
              size: await target.length(),
              sha256: digest.toString(),
            ),
          );
          break;
        } catch (e) {
          if (onFileError == null || e is InstallCancelled) rethrow;
          final decision = await onFileError(
            FileErrorPrompt(
              step: 'extract',
              relPath: rel,
              errorText: '$e',
              critical: isCriticalPayloadPath(rel),
            ),
          );
          if (decision == FileErrorDecision.retry) continue;
          if (decision == FileErrorDecision.cancel) {
            throw const InstallCancelled();
          }
          if (asidePath != null && !await target.exists()) {
            try {
              await File(asidePath!).rename(target.path);
            } catch (_) {}
          }
          skippedSink?.add(rel);
          skippedFile = true;
          break;
        }
      }
      if (skippedFile) {
        // 跳过的条目也算已处理（进度分母含它），只是不进清单。
        done++;
        onFile?.call(rel, done, total);
        continue;
      }
      done++;
      onFile?.call(rel, done, total);
    }
  } finally {
    await input.close();
  }
  return written;
}
