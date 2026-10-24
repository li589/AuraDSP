// backend_switch_test.dart — D4-a 门禁：后端互斥切换不允许静默双开。
//
// 缺陷（审查 D4-a）：三处后端切换（VB / ASIO / VAIO）都是
//     try { wasapi?.stop(); } catch (_) {}
//     source = null; <mode>Active = true;
// 「停不下来」与「停下来了」在控制流上完全等价 → 旧后端还在出声，新后端已起来
// → 两路同时出声（真实双声/梳状），而且日志里一个字都没有。
// 更底层：`WasapiOut.stop()` 丢弃 `IAudioClient::Stop` 的 HRESULT 并无条件把
// `started` 清零，连"其实还在跑"这个事实都没留下。
//
// 本测试两层：
//   [A] runHandover 的失败语义（纯逻辑）：停旧失败 → 必须回滚新后端 + 返回失败；
//       停旧成功 → 不得回滚。
//   [B] 源码不变式：三处切换点走 runHandover（不再有裸 catch 包 stop）、
//       WasapiOut.start/stop 检查 HRESULT、恢复 WASAPI 失败要上报。
import 'dart:io';

import 'package:auradsp_app/engine/backend_switch.dart';
import 'package:flutter_test/flutter_test.dart';

String _read(String relPath) {
  for (final base in const ['', '../', '../../']) {
    final f = File('$base$relPath');
    if (f.existsSync()) return f.readAsStringSync();
  }
  throw StateError('找不到 $relPath（cwd=${Directory.current.path}）');
}

void main() {
  group('Part A runHandover 失败语义', () {
    test('停旧成功：不回滚，结果为 ok', () {
      var halted = 0;
      var rolledBack = 0;
      final errs = <String>[];
      final r = runHandover(
        haltOld: () => halted++,
        rollbackNew: () => rolledBack++,
        onError: errs.add,
      );
      expect(r.ok, isTrue);
      expect(r.reason, isEmpty);
      expect(halted, 1);
      expect(rolledBack, 0, reason: '成功路径不得回滚新后端');
      expect(errs, isEmpty);
    });

    test('停旧失败：必须回滚新后端、返回失败并带原因', () {
      var rolledBack = 0;
      final errs = <String>[];
      final r = runHandover(
        haltOld: () => throw StateError('WASAPI Stop failed hr=0x80070005'),
        rollbackNew: () => rolledBack++,
        onError: errs.add,
      );
      expect(r.ok, isFalse);
      expect(r.reason, contains('WASAPI Stop failed'),
          reason: '原因要能写进 *status 事件的 note');
      expect(rolledBack, 1, reason: '停不下来必须把已起来的新后端拆掉');
      expect(errs.length, 1);
      expect(errs.single, contains('halt-old failed'));
    });

    test('回滚本身失败：结果仍是 failed（不得因为二次失败变成 ok）', () {
      final errs = <String>[];
      final r = runHandover(
        haltOld: () => throw StateError('stop-failed'),
        rollbackNew: () => throw StateError('rollback-failed'),
        onError: errs.add,
      );
      expect(r.ok, isFalse);
      expect(r.reason, contains('stop-failed'));
      expect(errs.length, 2);
      expect(errs.last, contains('rollback-new failed'));
    });

    test('onError 可省略（不崩）', () {
      final r = runHandover(
        haltOld: () => throw StateError('x'),
        rollbackNew: () {},
      );
      expect(r.ok, isFalse);
    });
  });

  group('Part B 源码不变式（切换路径不许静默）', () {
    final isolate = _read('lib/engine/audio_isolate.dart');
    final device = _read('lib/engine/audio_device.dart');
    final switchSrc = _read('lib/engine/backend_switch.dart');

    test('runHandover 实现含「停旧→回滚」两条路径', () {
      expect(switchSrc, contains('HandoverResult.ok()'));
      expect(switchSrc, contains('rollbackNew()'));
      expect(switchSrc, contains('rollback-new failed'));
    });

    test('三处切换点都走 runHandover（VB / ASIO / VAIO）', () {
      // 每个切换点后面紧跟自己的 Active 标志置位，用 it 定位段落再查 runHandover
      for (final marker in const [
        'vbActive = true;',
        'asioActive = true;',
        'vaioActive = true;',
      ]) {
        final at = isolate.indexOf(marker);
        expect(at, greaterThan(0), reason: '找不到 $marker');
        // 该切换点前面 1200 字符内必须有 runHandover（= 交接已成显式步骤）
        final head =
            isolate.substring(at - 1200 < 0 ? 0 : at - 1200, at);
        expect(head, contains('runHandover('),
            reason: '$marker 之前没有 runHandover —— 切换又变回裸 stop');
        expect(head, contains('if (!handover.ok)'),
            reason: '$marker 之前没有失败分支 —— 停不下来照样起新后端（双声）');
      }
    });

    test('不再有 try{wasapi?.stop()}catch(_){} 这种静默停机', () {
      final silent = RegExp(
          r'try\s*\{\s*wasapi\?\.stop\(\);\s*\}\s*catch\s*\(_\)\s*\{\s*\}');
      expect(silent.hasMatch(isolate), isFalse,
          reason: '三处切换点必须确认停旧结果，不能再吞异常');
    });

    test('WasapiOut.stop 检查 HRESULT 且失败时保持 started', () {
      expect(device, contains("_hr('Stop', hr)"),
          reason: 'Stop 的 HRESULT 被丢弃 → 停不下来也当已停');
      expect(device, contains('started = false;'));
      // AUDCLNT_E_DEVICE_INVALIDATED 白名单：端点已消失，不可能再出声
      expect(device, contains('_kAudclntEDeviceInvalidated = 0x88890004'));
      final body = device.substring(device.indexOf('void stop()'));
      final stopBody = body.substring(0, body.indexOf('\n  }'));
      expect(stopBody.indexOf("_hr('Stop'"), lessThan(stopBody.indexOf('started = false;')),
          reason: '必须先检查再清 started（顺序反了等于没检查）');
    });

    test('WasapiOut.start 检查 HRESULT', () {
      final i = device.indexOf('void start()');
      expect(i, greaterThan(0));
      final startBody = device.substring(i, i + 160);
      expect(startBody, contains("_hr('Start'"));
    });

    test('恢复 WASAPI 失败必须上报（不能静默失声）', () {
      expect(isolate, contains('String? resumeWasapi('));
      final n = 'wasapi-resume-failed'.allMatches(isolate).length;
      expect(n, 3, reason: '三条 stop*Bridge 各要一处上报，实际 $n');
      // 三条 stop*Bridge 都不该再有裸 catch 包 start
      final silent = RegExp(
          r'try\s*\{\s*wasapi\?\.start\(\);\s*\}\s*catch\s*\(_\)\s*\{\s*\}');
      expect(silent.hasMatch(isolate), isFalse);
    });

    test('初始化期 Start 失败走 wasapiError 降级（不静默、不升级 fatal）', () {
      expect(isolate, contains("wasapiError ??= 'wasapi-start: \$e'"));
    });
  });
}
