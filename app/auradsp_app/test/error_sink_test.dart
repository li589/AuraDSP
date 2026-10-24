/*
 * error_sink_test.dart — D4-b 运行时验证
 *
 * 源码里有 `swallow(e, st);` 这行不代表日志里真的有痕迹。这组测试回答三件事：
 *
 *   1) 限流策略对不对：600 次失败到底记几次？（结论：21 次 = 前 20 全记 + 第
 *      500 次 1 条。记太多会把日志刷爆、绑架泵线程；记太少会丢掉「第一次失败」
 *      这个唯一有用的信号。）
 *   2) 接线对不对：同一个 tag 只登记一份计数器，reset 能归零。
 *   3) 端到端对不对：日志文件里真的能按 tag 捞到行——这是排障时唯一的行为。
 *
 * 第 3 条必须用唯一 tag（带时间戳后缀），否则历史运行的行会被算进来。
 */
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:auradsp_app/core/error_sink.dart';
import 'package:auradsp_app/engine/debug_log.dart';

/// 等一次 flush 窗口（dbgLog 的 flush 间隔是 200ms），再补一条日志触发落盘。
///
/// 不能只 sleep：flush 只在「距上次 flush >= 200ms 的下一次写入」时发生，
/// 没有后续写入时缓冲区里的尾巴会一直留着。
Future<void> _pumpLog() async {
  await Future<void>.delayed(const Duration(milliseconds: 260));
  dbgLog('d4b-flush');
}

String _logPath() {
  final tmp = Platform.environment['TEMP'] ?? Directory.systemTemp.path;
  return '$tmp${Platform.pathSeparator}auradsp_debug.log';
}

/// 读日志行。**必须容错解码**：这个文件是多个进程追加写的，历史内容里
/// 混着引擎侧写入的非 UTF-8 字节，严格解码会直接抛 FileSystemException。
List<String> _readLogLines() {
  final f = File(_logPath());
  if (!f.existsSync()) return const <String>[];
  return utf8.decode(f.readAsBytesSync(), allowMalformed: true).split('\n');
}

int _countTag(String tag) {
  final needle = 'swallow/$tag#';
  return _readLogLines().where((l) => l.contains(needle)).length;
}

void main() {
  group('ThrottledLog 策略', () {
    test('前 head 次全记，之后按 every 采样', () {
      final log = ThrottledLog('t', head: 20, every: 500);
      var admitted = 0;
      final hitAt = <int>[];
      for (var i = 1; i <= 600; i++) {
        if (log.shouldLog) {
          admitted++;
          hitAt.add(i);
        }
      }
      // 1..20 全记，500 记一次 → 21 条
      expect(admitted, 21);
      expect(hitAt.take(20), List<int>.generate(20, (i) => i + 1));
      expect(hitAt.last, 500);
      expect(log.count, 600);
    });

    test('每 500 次一分界，不因四舍五入漂移', () {
      final log = ThrottledLog('t2', head: 2, every: 100);
      final hitAt = <int>[];
      for (var i = 1; i <= 350; i++) {
        if (log.shouldLog) hitAt.add(i);
      }
      expect(hitAt, <int>[1, 2, 100, 200, 300]);
    });
  });

  group('swallow 接线', () {
    setUp(resetSwallowThrottlesForTest);

    test('swallow 不抛（日志失败也不能影响调用方）', () {
      expect(() => swallow(StateError('boom'), StackTrace.current), returnsNormally);
      expect(() => swallow('not-an-error', StackTrace.empty), returnsNormally);
    });

    test('同一 tag 只登记一份计数器', () {
      for (var i = 0; i < 10; i++) {
        swallowThrottled(StateError('x$i'), StackTrace.current, 'same');
      }
      expect(swallowThrottleTagsForTest, 1);
      swallowThrottled(StateError('y'), StackTrace.current, 'other');
      expect(swallowThrottleTagsForTest, 2);
    });

    test('reset 后重新从第 1 次开始计数', () {
      swallowThrottled(StateError('a'), StackTrace.current, 'r');
      expect(swallowThrottleTagsForTest, 1);
      resetSwallowThrottlesForTest();
      expect(swallowThrottleTagsForTest, 0);
    });

    test('限流计数跨调用累积（不会每次都当成第一次）', () {
      // 超过 head 之后必须真的被挡掉，否则泵循环会每次失败都写一行
      for (var i = 0; i < 40; i++) {
        swallowThrottled(StateError('n$i'), StackTrace.current, 'acc');
      }
      // 无法直接读 ThrottledLog，改用日志行数间接验证（见下一组）
      expect(swallowThrottleTagsForTest, 1);
    });
  });

  group('日志端到端', () {
    test('600 次热路径失败只落 21 行，且带 tag 与来源', () async {
      final tag = 'e2e-${DateTime.now().microsecondsSinceEpoch}';
      for (var i = 0; i < 600; i++) {
        swallowThrottled(StateError('flood $i'), StackTrace.current, tag);
      }
      await _pumpLog();

      expect(_countTag(tag), 21,
          reason: '前 20 次 + 第 500 次，共 21 行；多记会绑架泵线程，'
              '少记会丢掉「第一次失败」这个信号');

      final lines = _readLogLines()
          .where((l) => l.contains('swallow/$tag#'))
          .toList();
      expect(lines.first, contains('flood 0'), reason: '第一次失败必须留得住');
      expect(lines.first, contains('error_sink_test.dart'),
          reason: '_site 要定位到调用点，而不是 error_sink 自身');
      expect(lines.last, contains('#500]'), reason: '第 500 次是采样点');
    });

    test('不同 tag 各自计数，互不干扰', () async {
      final base = DateTime.now().microsecondsSinceEpoch;
      final t1 = 'iso-a-$base';
      final t2 = 'iso-b-$base';
      for (var i = 0; i < 30; i++) {
        swallowThrottled(StateError('a'), StackTrace.current, t1);
        swallowThrottled(StateError('b'), StackTrace.current, t2);
      }
      await _pumpLog();
      expect(_countTag(t1), 20, reason: 'head=20 且未到 500，故 20 行');
      expect(_countTag(t2), 20);
    });

    test('冷路径 swallow 每次都记（不限流）', () async {
      final marker = 'cold-${DateTime.now().microsecondsSinceEpoch}';
      for (var i = 0; i < 5; i++) {
        swallow(StateError('$marker $i'), StackTrace.current);
      }
      await _pumpLog();
      final n = _readLogLines().where((l) => l.contains(marker)).length;
      expect(n, 5);
    });
  });
}
