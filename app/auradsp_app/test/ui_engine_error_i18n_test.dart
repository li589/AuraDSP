import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/engine_error_map.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/shell.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// B-2（计划 D2 §4.3）：引擎错误展示层本地化 + 脱敏验收。
/// - token 命中 → 三语词条；detail（含 gate.maxFileMb 等内部名）整体丢弃；
/// - token 未命中 → scrub 兜底（内部名/盘符抹除），EEL 原文透传；
/// - EventBanner 横幅显示本地化文案而非英文原文。

Map<String, dynamic> _guardMsg(String id, String msg) =>
    {'evt': 'paramResult', 'id': id, 'rc': -1, 'msg': msg};

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: child),
    );

Future<AppLocalizations> _zh() =>
    AppLocalizations.delegate.load(const Locale('zh'));

Future<AppLocalizations> _en() =>
    AppLocalizations.delegate.load(const Locale('en'));

void main() {
  group('engine_error_map 本地化与脱敏', () {
    test('token 命中：detail 丢弃 + 中文词条（内部配置名不泄露）', () async {
      final l = await _zh();
      final out = localizeEngineError(
          'convolver.ir: file too large (exceeds configured gate.maxFileMb)', l);
      expect(out, 'convolver.ir: 文件大小超出限制');
      expect(out.contains('gate.maxFileMb'), isFalse);
      expect(out.contains('exceeds'), isFalse);
    });

    test('全部 14 token 在 zh/en 均被翻译（非原文、非空）', () async {
      final zh = await _zh();
      final en = await _en();
      for (final tok in kEngineReasonTokens) {
        final raw = 'eq.curve: $tok (detail)';
        final z = localizeEngineError(raw, zh);
        final e = localizeEngineError(raw, en);
        expect(z, isNot(equals(raw)), reason: '$tok 在 zh 未翻译');
        expect(e, isNot(equals(raw)), reason: '$tok 在 en 未翻译');
        expect(z.length, greaterThan(3));
        expect(e.length, greaterThan(3));
      }
    });

    test('token 未命中：EEL 原文透传 / 内部名脱敏 / 空串保空', () async {
      final l = await _zh();
      expect(localizeEngineError('Syntax error at @init section', l),
          'Syntax error at @init section');
      expect(localizeEngineError('', l), '');
      final scrubbed = localizeEngineError(
          'convolver.ir: future reason (see C:\\data\\gate.maxFileMb file)', l);
      expect(scrubbed.contains('gate.maxFileMb'), isFalse);
      expect(scrubbed.contains(r'C:\data'), isFalse);
      expect(scrubbed.isNotEmpty, isTrue);
    });
  });

  group('EventBanner 横幅本地化', () {
    testWidgets('guard 拒绝显示中文词条而非英文原文', (tester) async {
      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(EventBanner(model: model)));
      model.handleMessageForTesting(_guardMsg('convolver.ir',
          'convolver.ir: file too large (exceeds configured gate.maxFileMb)'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('convolver.ir: 文件大小超出限制'), findsOneWidget);
      expect(find.textContaining('gate.maxFileMb'), findsNothing);
      expect(find.textContaining('file too large'), findsNothing);
    });

    testWidgets('error 事件同样本地化', (tester) async {
      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(EventBanner(model: model)));
      model.handleMessageForTesting({
        'evt': 'error',
        'msg': 'viz.fftSize: out of range (power of two within [1024, 8192])',
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('viz.fftSize: 数值超出允许范围'), findsOneWidget);
      expect(find.textContaining('power of two'), findsNothing);
    });
  });
}
