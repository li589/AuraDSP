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
 *
 * 跨 isolate 行完整性（2026-11-08 审计·调试低5）：每行恰经一次
 * writeStringSync 且文件以 append 模式打开——POSIX 的 O_APPEND
 * 语义下单次 write 原子追加，两 isolate 交错时最坏是整行交错、
 * 不会半行拼接；单条消息以 _kMaxLineChars 截断，保证不跨多次写。
 * 会话头带 pid 供归因。文件大小由 rotateLogFileIfOversized 钳住
 * （审计·调试低4：此前只追加无轮转，长期运行无界增长）。
 */
import 'dart:io';

RandomAccessFile? _dbgF;
String? _dbgPath;
int _sessionBytes = 0;
DateTime _lastFlush = DateTime.fromMillisecondsSinceEpoch(0);

/// flush 最小间隔。崩溃时会丢最多这一个窗口内的尾巴，
/// 换取音频泵不被同步落盘阻塞——这个取舍是刻意的。
const Duration _flushInterval = Duration(milliseconds: 200);

/// 日志轮转上限：dbgLog 与 DebugTrace 共用口径——单文件超过此值
/// 即改名 `.1` 备份（只留一份），总占用钳在约 2 倍上限。
const int kLogRotateCapBytes = 5 * 1024 * 1024;

/// 把 [path] 轮转（若其大小超过 [capBytes]）：当前文件改名为
/// `<path>.1`（覆盖旧备份）。本函数**不自带 catch**——D4-b 门禁钉死
/// 全 lib/ 只有 dbgLog 一处代码级 `catch (_)`（自引用），故调用方
/// 必须在自己的日志口径 try 内调用（dbgLog 的 catch 或 DebugTrace
/// 的具名 catch + 报告）。
void rotateLogFileIfOversized(String path, int capBytes) {
  final f = File(path);
  if (!f.existsSync()) return;
  if (f.lengthSync() <= capBytes) return;
  final bak = File('$path.1');
  if (bak.existsSync()) bak.deleteSync();
  f.renameSync(bak.path);
}

/// 单条消息长度上限（保证一行一次写完，见文件头）。
const int _kMaxLineChars = 4096;

void _writeDbgLine(String s) {
  _dbgF!.writeStringSync('$s\n');
  _sessionBytes += s.length + 1;
}

bool _openDbgFile() {
  // 路径分隔符必须走平台值：硬编码 '\\' 在 Windows 正确，但在
  // Linux 会拼出文件名带反斜杠的怪路径（S3 遗留，S4 由
  // error_sink_test 的端到端用例在 Linux 上抓到并在此修复）。
  var path =
      '${Platform.environment['TEMP'] ?? Directory.systemTemp.path}'
      '${Platform.pathSeparator}auradsp_debug.log';
  // 符号链接防护（安全审查 2026-11-02）：路径落在共享临时目录
  // 且文件名可预测，同机其他用户可预置 symlink 指向属主文件，
  // 追加打开会顺着链接把日志写进目标文件。发现目标本身是链接
  // 时改用带 pid 的文件名（正常环境与 CI 仍走固定名）。
  if (FileSystemEntity.isLinkSync(path)) {
    path = '$path.$pid.log';
    if (FileSystemEntity.isLinkSync(path)) return false;
  }
  rotateLogFileIfOversized(path, kLogRotateCapBytes);
  final f = File(path);
  if (!f.existsSync()) f.createSync(recursive: true);
  _dbgPath = path;
  _dbgF = f.openSync(mode: FileMode.append);
  _sessionBytes = 0;
  _writeDbgLine('==== session ${DateTime.now()} pid=$pid ====');
  _dbgF!.flushSync();
  _lastFlush = DateTime.now();
  return true;
}

/// 本会话写量超上限时轮转一次：关句柄 → 改名备份 → 重开新文件。
/// 只在 flush 点检查（节流路径），不给高频调用点加系统调用。
/// 不自带 catch：异常上抛到 dbgLog 的唯一 catch；_dbgF 先置空，
/// 即使 close 失败下一次调用也会重开自愈。
void _rotateIfSessionOversized() {
  if (_sessionBytes <= kLogRotateCapBytes) return;
  final path = _dbgPath;
  if (path == null) return;
  final old = _dbgF;
  _dbgF = null;
  old?.closeSync();
  rotateLogFileIfOversized(path, 0);
  _openDbgFile();
}

void dbgLog(String msg) {
  try {
    if (_dbgF == null) {
      _openDbgFile();
      return;
    }
    var line = msg;
    if (line.length > _kMaxLineChars) {
      line = '${line.substring(0, _kMaxLineChars)}…(truncated)';
    }
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    _writeDbgLine('$ts $line');
    // 节流 flush：绝大多数调用只进用户态缓冲，不产生系统调用
    final now = DateTime.now();
    if (now.difference(_lastFlush) >= _flushInterval) {
      _lastFlush = now;
      _dbgF!.flushSync();
      _rotateIfSessionOversized();
    }
  } catch (_) {
    // swallow: 日志写入本身失败无处可记——再调 swallow 会递归回这里
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

  /// 已调用次数。供调用方在「先判后建」的写法里判断是否真的命中，
  /// 避免为一个即将被丢弃的日志格式化字符串（见 core/error_sink.dart）。
  int get count => _n;

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