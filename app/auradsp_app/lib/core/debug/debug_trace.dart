/*
 * debug_trace.dart — 调试追踪总线（UI 动作 → 引擎接收 → 回执）
 *
 * 目标：所有调试打印/控件动作都汇总到同一条结构化事件流，默认关闭；
 * 命令行 `--debug` / `--debug-log=<path>` 打开。发布构建零开销（所有入口
 * 先判 enabled 再格式化）。
 *
 * 事件类别：
 *   ui     用户点击/拖动（控件类型、参数 id、值）
 *   param  发往音频 isolate 的参数命令（setParam/setParamStr）
 *   engine 引擎回执 paramResult（已接收值、rc、耗时、拒绝原因）
 *   command 非参数命令（bypass/getParams/音频模式/播放等）
 *   lifecycle/debug  启动、会话、异常
 *
 * 输出：JSONL（默认 %TEMP%\auradsp_debug_trace.jsonl），每行一个事件；
 * 200ms 批量落盘，避免拖动滑块时 60Hz 同步 IO 阻塞 UI。
 * 音频 isolate 不直接调用本类（其 RT 约束更严）；它已有的 paramResult
 * 事件由主 isolate 的 state_events 统一记录。
 */
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

class DebugEvent {
  DebugEvent(this.seq, this.ts, this.cat, this.action, this.data);

  final int seq;
  final String ts;
  final String cat;
  final String action;
  final Map<String, Object?>? data;

  /// 单行摘要。
  ///
  /// engine 回执里的 `rc` 是往返结果而不是被设置的值，必须写成 `rc=0`；
  /// 旧写法把它当 value 打印（`eq.enable = 0`），看起来像参数被设成了 0。
  String get oneLine {
    final id = data?['id'];
    final suffix = id == null ? '' : ' $id';
    if (cat == 'engine') {
      final rc = data?['rc'];
      final value = data?['value'];
      final tookMs = data?['tookMs'];
      final msg = data?['msg'];
      // val= 是音频 isolate 回显的“已接收值”，与 [param] send 的 = 值对照；
      // 耗时写成 took=…ms，避免被误读成回传的数值。
      final v = value == null ? '' : ' val=$value';
      final ms = (tookMs is int && tookMs >= 0) ? ' took=${tookMs}ms' : '';
      final m = (msg is String && msg.isNotEmpty) ? ' · $msg' : '';
      return '#$seq [$cat] $action$suffix$v rc=$rc$ms$m';
    }
    final value = data?['value'] ?? data?['cmd'];
    final v = value == null ? '' : ' = $value';
    return '#$seq [$cat] $action$suffix$v';
  }
}

class DebugTrace {
  DebugTrace._();

  static final DebugTrace instance = DebugTrace._();

  bool enabled = false;
  bool console = false;
  String logPath = '';

  final List<DebugEvent> _last = <DebugEvent>[];
  final Set<String> _controls = <String>{};
  final Set<String> _acked = <String>{};

  final StringBuffer _pending = StringBuffer();
  RandomAccessFile? _file;
  Timer? _flushTimer;
  int _seq = 0;
  String _session = '';
  bool _initialized = false;
  bool _flushWarned = false;

  List<DebugEvent> get lastEvents => List<DebugEvent>.unmodifiable(_last);
  int get controlCount => _controls.length;
  int get ackCount => _acked.length;
  Set<String> get controls => Set<String>.unmodifiable(_controls);

  /// 命令行入口；无 --debug 时完全不产生文件/定时器。
  void initFromArgs(List<String> args) {
    if (_initialized) return;
    _initialized = true;
    var want = args.contains('--debug');
    var path = '';
    for (var i = 0; i < args.length; i++) {
      final a = args[i];
      if (a == '--debug-log' && i + 1 < args.length) {
        path = args[i + 1];
        want = true;
      } else if (a.startsWith('--debug-log=')) {
        path = a.substring('--debug-log='.length);
        want = true;
      } else if (a == '--debug-console') {
        console = true;
      }
    }
    if (!want) return;
    enabled = true;
    logPath = path.isNotEmpty
        ? path
        : '${Directory.systemTemp.path}\\auradsp_debug_trace.jsonl';
    _session = DateTime.now().toIso8601String();
    try {
      final f = File(logPath);
      f.parent.createSync(recursive: true);
      _file = f.openSync(mode: FileMode.append);
      _flushTimer = Timer.periodic(const Duration(milliseconds: 200), (_) => flush());
      event('debug', 'session.start', data: {
        'session': _session,
        'pid': pid,
        'args': args,
        'log': logPath,
      });
      debugPrint('[DebugTrace] enabled -> $logPath');
    } catch (e) {
      enabled = false;
      debugPrint('[DebugTrace] open failed: $e');
    }
  }

  /// 测试用：重置单例状态，避免多个用例互相污染。
  @visibleForTesting
  void resetForTesting() {
    _flushTimer?.cancel();
    _flushTimer = null;
    flush();
    try {
      _file?.closeSync();
    } catch (e) {
      // 关闭失败不阻塞退出；调试总线自身不能反过来抛错。
      debugPrint('[DebugTrace] close failed: $e');
    }
    _file = null;
    enabled = false;
    console = false;
    logPath = '';
    _pending.clear();
    _last.clear();
    _controls.clear();
    _acked.clear();
    _seq = 0;
    _initialized = false;
  }

  void event(String cat, String action, {Map<String, Object?>? data}) {
    if (!enabled) return;
    final ts = DateTime.now().toIso8601String();
    final e = DebugEvent(++_seq, ts, cat, action, _sanitize(data));
    _last.add(e);
    if (_last.length > 48) _last.removeAt(0);
    try {
      final row = <String, Object?>{
        'ts': ts,
        'seq': e.seq,
        'session': _session,
        'cat': cat,
        'action': action,
        if (e.data != null) 'data': e.data,
      };
      final line = jsonEncode(row, toEncodable: (o) => o.toString());
      _pending.write(line);
      _pending.write('\n');
      if (console) stdout.writeln(line);
    } catch (err) {
      // 事件序列化失败不能反过来影响业务；只记一条最小行。
      _pending.write('{"ts":"$ts","seq":${e.seq},"cat":"debug","action":"encode_error","data":"$err"}\n');
    }
  }

  /// UI 控件登记：首次出现记一条 register，供覆盖率面板统计。
  void registerControl(String id, {String kind = 'param'}) {
    if (!enabled || id.isEmpty || _controls.contains(id)) return;
    _controls.add(id);
    event('ui', 'control.register', data: {'id': id, 'kind': kind});
  }

  /// 用户实际操作：滑块拖动、开关切换、chip 点击等。
  void uiControl(String id, Object? value, {String widget = 'param', String? section}) {
    if (!enabled) return;
    registerControl(id, kind: widget);
    event('ui', 'control', data: {
      'id': id,
      'widget': widget,
      'value': value,
      'section': ?section,
    });
  }

  void tap(String widget, String label) {
    if (!enabled) return;
    event('ui', 'tap', data: {'widget': widget, 'label': label});
  }

  /// 根级指针兜底：即使某个自定义控件没有语义标签，也能看到“点了哪里”。
  void pointer(double x, double y) {
    if (!enabled) return;
    event('ui', 'pointer', data: {
      'x': x.toStringAsFixed(1),
      'y': y.toStringAsFixed(1),
    });
  }

  void command(String cmd, Map<String, dynamic> payload) {
    if (!enabled) return;
    final data = <String, Object?>{'cmd': cmd};
    for (final e in payload.entries) {
      if (e.key == 'cmd') continue;
      data[e.key] = e.value;
    }
    event('command', 'send', data: data);
  }

  void paramSent(String id, Object? value, {String kind = 'param'}) {
    if (!enabled) return;
    event('param', 'send', data: {'id': id, 'value': value, 'kind': kind});
  }

  void paramAck(String id, int rc, int tookMs, {Object? value, String? msg}) {
    if (!enabled) return;
    if (rc == 0) _acked.add(id);
    event('engine', 'ack', data: {
      'id': id,
      'value': ?value,
      'rc': rc,
      'tookMs': tookMs,
      if (msg != null && msg.isNotEmpty) 'msg': msg,
    });
  }

  void log(String cat, String message) {
    if (!enabled) return;
    event(cat, 'log', data: {'message': message});
  }

  void flush() {
    if (_pending.isEmpty || _file == null) return;
    try {
      _file!.writeStringSync(_pending.toString());
      _pending.clear();
      _file!.flushSync();
    } catch (e) {
      _pending.clear();
      if (!_flushWarned) {
        _flushWarned = true;
        debugPrint('[DebugTrace] flush failed: $e');
      }
    }
  }

  Map<String, Object?>? _sanitize(Map<String, Object?>? data) {
    if (data == null) return null;
    final out = <String, Object?>{};
    for (final e in data.entries) {
      final v = e.value;
      if (v is String && v.length > 240) {
        out[e.key] = '${v.substring(0, 240)}…(${v.length} chars)';
      } else {
        out[e.key] = v;
      }
    }
    return out;
  }
}
