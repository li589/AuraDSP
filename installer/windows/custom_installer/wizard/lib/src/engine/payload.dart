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
      final out = OutputFileStream(target.path);
      entry.writeContent(out);
      await out.close();
      final bytes = await target.readAsBytes();
      written.add(ManifestFile(
        path: rel,
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      ));
      done++;
      onFile?.call(rel, done, total);
    }
  } finally {
    await input.close();
  }
  return written;
}
