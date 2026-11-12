/// ZIP-P 载荷处理（设计 §2/§5）：从 Setup exe 切出载荷段落盘，
/// 再按组件过滤流式解压到安装目录，逐文件算 SHA256 生成清单条目。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'models.dart';

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

/// 把 setupExe 中 [off, off+len) 的字节段写到 destFile（分块拷贝）。
Future<void> slicePayloadToFile(
    String setupExe, int off, int len, String destFile) async {
  final src = await File(setupExe).open();
  final sink = File(destFile).openWrite();
  try {
    await src.setPosition(off);
    var left = len;
    while (left > 0) {
      final want = left > (1 << 20) ? (1 << 20) : left;
      final chunk = await src.read(want);
      if (chunk.isEmpty) throw StateError('载荷段读取不完整');
      sink.add(chunk);
      left -= chunk.length;
    }
  } finally {
    await sink.close();
    await src.close();
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

/// 解压载荷 zip 到 destDir（含 payload/ 前缀剥离与路径穿越防护）。
/// onFile 每完成一个文件回调一次（进度与日志）。
Future<List<ManifestFile>> extractPayload(
  String zipPath,
  String destDir, {
  required bool Function(String rel) include,
  void Function(String rel, int done, int total)? onFile,
  void Function(String warning)? onWarning,
}) async {
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
      var rel = entry.name.replaceAll('\\', '/');
      if (rel.startsWith('payload/')) rel = rel.substring('payload/'.length);
      if (rel.isEmpty || !include(rel)) {
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
      await target.parent.create(recursive: true);
      await writeEntryResilient(
        entry,
        target,
        onAside: (asidePath) => onWarning?.call(
            '$rel 仍被其他进程占用，已将旧文件改名让位'
            '（${p.basename(asidePath)}），新版已写入；'
            '让位文件将在下次安装/卸载时清理'),
      );
      // 流式算 SHA + 长度（2026-11-12 内存治理）：旧实现把每个
      // 落盘文件整份 readAsBytes 回内存只为算哈希，大文件（数十
      // MB 级 DLL/资源）逐个制造同等大小的内存峰值；改 1MB 分块
      // 流式摘要后峰值与文件大小脱钩。
      final digest = await sha256.bind(target.openRead()).single;
      written.add(ManifestFile(
        path: rel,
        size: await target.length(),
        sha256: digest.toString(),
      ));
      done++;
      onFile?.call(rel, done, total);
    }
  } finally {
    await input.close();
  }
  return written;
}
