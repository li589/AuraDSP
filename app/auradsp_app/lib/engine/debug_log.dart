/*
 * debug_log.dart — 跨 isolate 文件调试日志（%TEMP%\auradsp_debug.log）
 *
 * 用途：GUI release 无控制台，原生崩溃前的最后一条日志即崩溃点定位。
 * 追加写、写失败静默（不影响音频路径）。排障完成后可整段移除。
 *
 * RT 约束（重要）：本文件被**音频 isolate 线程**调用，而该线程同时负责
 * WASAPI 泵（每 5ms 一轮）。因此：
 *   1) flushSync() 强制落盘，单次可达毫秒级 → 必须节流；
 *   2) 高频调用点（每帧 setParam）必须采样，否则拖滑块时会产生
 *      上百次/秒的同步落盘，直接抬升音频泵抖动、诱发 underrun。
 * 故：写全部走缓冲，flush 按固定间隔节流；高频点用 dbgLogThrottled。
 */
import 'dart:io';

RandomAccessFile? _dbgF;
DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);

/// flush 最小间隔。崩溃时会丢最多这一个窗口内的尾巴，
/// 换取音频泵不被同步落盘阻塞——这个取舍是刻意的。
const Duration _flushInterval = Duration(milliseconds: 200);

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
      _dbgF!.flushSync();
      _lastFlush = DateTime.now();
      return;
    }
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _dbgF!.writeStringSync('$ts $msg\n');
    // 节流 flush：绝大多数调用只进用户态缓冲，不产生系统调用
    final now = DateTime.now();
    if (now.difference(_lastFlush) >= _flushInterval) {
      _lastFlush = now;
      _dbgF!.flushSync();
    }
  } catch (_) {
    // 日志失败绝不影响运行
  }
}

/// 按标签计数的采样日志器：前 [head] 次全记，之后每 [every] 次记 1 次。
/// 用于 setParam / viz 这类每帧都会触发的调用点。
class ThrottledLog {
  ThrottledLog(this.tag, {this.head = 20, this.every = 500});

  final String tag;
  final int head;
  final int every;
  int _n = 0;

  bool get shouldLog {
    _n++;
    return _n <= head || _n % every == 0;
  }

  /// 返回本次调用是否应记录（并已自动计数）。
  bool admit(String msg) {
    if (!shouldLog) return false;
    dbgLog('[$tag#$_n] $msg');
    return true;
  }
}