/// ZIP-P 载荷处理（设计 §2/§5）：从 Setup exe 切出载荷段落盘，
/// 再按组件过滤流式解压到安装目录，逐文件算 SHA256 生成清单条目。
library;

import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';

import 'models.dart';

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
bool Function(String rel) componentFilter({
  required bool vaio,
  required bool ddcPresets,
}) {
  return (rel) {
    if (rel.startsWith('driver/') && !vaio) return false;
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
  final total = entries.length;
  final written = <ManifestFile>[];
  final destRoot = Directory(destDir).absolute;
  var done = 0;
  try {
    for (final entry in entries) {
      var rel = entry.name.replaceAll('\\', '/');
      if (rel.startsWith('payload/')) rel = rel.substring('payload/'.length);
      if (rel.isEmpty || !include(rel)) {
        done++;
        continue;
      }
      final target = File('${destRoot.path}/$rel');
      if (!target.absolute.path.startsWith(destRoot.path)) {
        throw StateError('载荷含越界路径: ${entry.name}');
      }
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
