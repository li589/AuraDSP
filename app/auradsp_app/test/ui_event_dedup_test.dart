import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/shell.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 2026-10-18 UI 排查回归：引擎事件同因抑制 + EventBanner 一次性触发。
///
/// 背景（用户上报「通知条出问题通知一两次就够了，结果经常持续不断重复弹出」）：
/// - paramResult rc!=0（guard 拒绝）与 error 事件在 AppModel 侧零去重，
///   预设全量 apply / session 回放 / EQ 曲线节流下发 / liveprog 编译重试
///   任一批量路径都会把 N 个拒绝排成一串 4s SnackBar；
/// - EventBanner 旧实现把 addPostFrameCallback 放在 build 里，首次事件后
///   eventSeq 永不为 0，父级每次重建都重复注册消费回调（帧间连发还会吞事件）。
Map<String, dynamic> _guardMsg(String id, String msg) => {
      'evt': 'paramResult',
      'id': id,
      'rc': -1,
      'msg': msg,
    };

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: child),
    );

void main() {
  group('AppModel 引擎事件同因抑制', () {
    test('同因 guard 拒绝 5s 窗口内只提示一次', () {
      final m = AppModel(testing: true);
      final base = m.eventSeq.value;

      m.handleMessageForTesting(_guardMsg('reverb.preset', 'out of range'));
      expect(m.eventSeq.value, base + 1);
      expect(m.lastGuard, isNotNull);
      expect(m.lastGuard!.message, 'out of range');
      m.clearLastGuard(); // 模拟 EventBanner 消费

      // 同一 (id, msg) 再次到达：抑制，不自增、不重设一次性字段
      m.handleMessageForTesting(_guardMsg('reverb.preset', 'out of range'));
      expect(m.eventSeq.value, base + 1);
      expect(m.lastGuard, isNull);
      expect(m.debugEventSuppressedCount, 1);

      // 连续第三次同样抑制
      m.handleMessageForTesting(_guardMsg('reverb.preset', 'out of range'));
      expect(m.eventSeq.value, base + 1);
      expect(m.debugEventSuppressedCount, 2);
    });

    test('不同成因立即放行（id 不同 / msg 不同各自计数）', () {
      final m = AppModel(testing: true);
      final base = m.eventSeq.value;

      m.handleMessageForTesting(_guardMsg('reverb.preset', 'out of range'));
      m.clearLastGuard();
      m.handleMessageForTesting(_guardMsg('freeverb.roomsize', 'out of range'));
      expect(m.eventSeq.value, base + 2);

      m.clearLastGuard();
      m.handleMessageForTesting(_guardMsg('reverb.preset', 'value rejected'));
      expect(m.eventSeq.value, base + 3);
      expect(m.lastGuard!.message, 'value rejected');
    });

    test('窗口过期后同因再现视为新事件', () {
      final m = AppModel(testing: true);
      final base = m.eventSeq.value;
      final t0 = 1000000;

      m.debugNowOverride = t0;
      m.handleMessageForTesting(_guardMsg('filter.q', 'too low'));
      m.clearLastGuard();
      m.handleMessageForTesting(_guardMsg('filter.q', 'too low'));
      expect(m.eventSeq.value, base + 1); // 窗口内抑制

      m.debugNowOverride = t0 + 5000; // 恰好越过 5s 窗口
      m.handleMessageForTesting(_guardMsg('filter.q', 'too low'));
      expect(m.eventSeq.value, base + 2);
      m.debugNowOverride = null;
    });

    test('error 事件与 guard 共用同因抑制', () {
      final m = AppModel(testing: true);
      final base = m.eventSeq.value;

      m.handleMessageForTesting({'evt': 'error', 'msg': 'pump failure'});
      expect(m.lastEngineError, 'pump failure');
      m.clearLastEngineError();

      m.handleMessageForTesting({'evt': 'error', 'msg': 'pump failure'});
      expect(m.eventSeq.value, base + 1); // 抑制
      expect(m.lastEngineError, isNull);

      m.handleMessageForTesting({'evt': 'error', 'msg': 'another failure'});
      expect(m.eventSeq.value, base + 2);
    });

    test('liveprog 编译失败仍写 lpError（内联标红不丢）', () {
      final m = AppModel(testing: true);
      m.handleMessageForTesting(
          _guardMsg('liveprog.code', 'syntax error at line 3'));
      expect(m.lpError, 'syntax error at line 3');
    });
  });

  group('EventBanner 一次性触发', () {
    testWidgets('一次事件一个 SnackBar；同因重复不再弹', (tester) async {
      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(EventBanner(model: model)));

      model.handleMessageForTesting(
          _guardMsg('eq.curve', 'first problem'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('first problem'), findsOneWidget);

      // 同因第二次：模型层已抑制（无 seq 自增 → 无回调），SnackBar 不新增
      model.handleMessageForTesting(
          _guardMsg('eq.curve', 'first problem'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(SnackBar), findsOneWidget);
      expect(find.text('first problem'), findsOneWidget);
    });

    testWidgets('不同成因顺序弹出（排队而不是吞掉）', (tester) async {
      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(EventBanner(model: model)));

      model.handleMessageForTesting(
          _guardMsg('eq.curve', 'first problem'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('first problem'), findsOneWidget);

      model.handleMessageForTesting(
          _guardMsg('arbmag.string', 'second problem'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // 第一个还在 4s 展示期内，第二个进入队列（不丢不吞）
      expect(find.byType(SnackBar), findsOneWidget);
      // 逐帧推进：第一个到期退场后，第二个接着显示
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 500));
      }
      expect(find.text('second problem'), findsOneWidget);
    });
  });
}
