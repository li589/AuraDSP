/*
 * error_sink.dart — D4-b：静默异常的单一出口
 *
 * 为什么需要这个文件
 * ------------------
 * 改造前全仓 97 处 catch 既不留痕也不绑定异常（`catch (_) {}`）。问题不是
 * 「吞掉异常」这个动作本身——清理路径吞掉是正确语义——而是**没有任何机制
 * 区分「可预期的失败」和「编程错误」**。
 *
 * 最典型的是隔离区泵循环：整个迭代体包在 `catch (_) {}` + `continue` 里。
 * 一次类型错误（比如桥返回的 Map 少了一个键）就能让可视化永远冻结，日志
 * 里一个字都没有。用户看到的是「频谱不动了」，排障只能靠猜。
 *
 * 两种出口
 * --------
 *   swallow(e, st)                 冷路径：失败进日志
 *   swallowThrottled(e, st, tag)   热路径：同上，但按 tag 限流
 *
 * 热路径为什么必须限流：桥的 vizRead/status 每 33ms 一轮，桥未就绪时每次都
 * 失败。dbgLog 虽有 200ms 的 flush 节流，但字符串构造 + 写缓冲仍然跑在
 * **音频 isolate 的泵线程**上，无条件记录等于给泵加固定开销。ThrottledLog
 * 前 20 次全记、之后每 500 次记 1 次——既保住「第一次失败」这个关键信号，
 * 又不会在有持续故障时把日志刷爆。
 *
 * 纪律（由 tools/dart_swallow_scan.py 强制）
 * ------------------------------------------
 *   R1  空 catch 块必须留痕（调用本文件）或标记 `// swallow: <理由>`
 *   R2  循环体包壳（catch 后紧跟 continue）必须是 swallowThrottled(
 *   R3  不得用 `catch (_)` 丢弃异常——绑定 e，或标记
 *   R4  标记理由不得敷衍（≥8 字，禁止 ok/todo/n/a）
 *
 * 关于 R3：绑定 `e` 之后，哪怕不记录，一个断点也能拿到全貌。`catch (_)`
 * 连这点可能性都没有——它是「我拒绝观测」的语法。已在别处上报的（SnackBar、
 * onError 回调、lastErr 字段）用 `// swallow:` 标记说明去向即可，不强制重复记录。
 */
import '../engine/debug_log.dart';

/// 冷路径：把被吞掉的异常写进调试日志（%TEMP%\auradsp_debug.log）。
///
/// 调用点应当是「失败即异常、且不是每帧都会发生」的地方：预设读写、
/// 配置解析、设备停止、isolate 收尾等。热路径请用 [swallowThrottled]。
void swallow(Object error, StackTrace stack) {
  dbgLog('[swallow] $error  @ ${_site(stack)}');
}

/// 限流表。按 tag 各记一份计数，因此第一次失败必定能看见。
final Map<String, ThrottledLog> _throttles = <String, ThrottledLog>{};

/// 热路径：同上，但按 [tag] 限流（前 20 次全记，之后每 500 次记 1 次）。
///
/// [tag] 要能一眼看出是哪个泵/哪座桥，例如 `pump-vaio` / `vb-ffi`。
void swallowThrottled(Object error, StackTrace stack, String tag) {
  final log = _throttles.putIfAbsent(
    tag,
    () => ThrottledLog('swallow/$tag', head: 20, every: 500),
  );
  // 先判后建：未过限流阈值时不做栈格式化，热路径几乎零成本。
  if (!log.shouldLog) return;
  dbgLog('[swallow/$tag#${log.count}] $error  @ ${_site(stack)}');
}

/// 取栈里第一条「不在本文件内」的帧，只保留它的位置串。
///
/// 不整行输出：`#0 main.<anonymous closure>.<anonymous closure> (file:///D:/...`
/// 这种帧前缀很长，整行截断会把真正有用的文件名切掉（测试直接抓出过）。
/// 因此提取括号内的 `path:line:col`，并去掉仓库无关的绝对路径前缀——
/// 日志里只需要「哪个文件哪一行调用了 swallow」。
String _site(StackTrace stack) {
  for (final line in stack.toString().split('\n')) {
    final t = line.trim();
    if (t.isEmpty || t.contains('error_sink.dart')) continue;
    var loc = t;
    final open = t.lastIndexOf('(');
    if (open >= 0 && t.endsWith(')')) {
      loc = t.substring(open + 1, t.length - 1);
    }
    final root = loc.indexOf('auradsp_app/');
    if (root >= 0) loc = loc.substring(root);
    return loc.length > 160 ? '${loc.substring(0, 160)}…' : loc;
  }
  return '<无栈>';
}

/// 清空限流计数。仅供测试使用——生产路径没有重置的理由。
void resetSwallowThrottlesForTest() => _throttles.clear();

/// 当前已登记的限流标签数（测试断言用）。
int get swallowThrottleTagsForTest => _throttles.length;
