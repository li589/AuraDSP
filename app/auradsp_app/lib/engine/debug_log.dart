/*
 * debug_log.dart — 跨 isolate 文件调试日志（%TEMP%\auradsp_debug.log）
 *
 * 用途：GUI release 无控制台，原生崩溃前的最后一条日志即崩溃点定位。
 * 追加写、写失败静默（不影响音频路径）。排障完成后可整段移除。
 */
import 'dart:io';

RandomAccessFile? _dbgF;

void dbgLog(String msg) {
  try {
    if (_dbgF == null) {
      final path =
          '${Platform.environment['TEMP'] ?? Directory.systemTemp.path}'
          r'\auradsp_debug.log';
      final f = File(path);
      if (!f.existsSync()) f.createSync(recursive: true);
      _dbgF = f.openSync(mode: FileMode.append);
      _dbgF!.writeStringSync('==== session ${DateTime.now()} ====\n');
    }
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _dbgF!.writeStringSync('$ts $msg\n');
    _dbgF!.flushSync();
  } catch (_) {
    // 日志失败绝不影响运行
  }
}
