/*
 * ambient_background_setting_test.dart — 氛围背景开关（2026-11-03）
 *
 * 用户需求：背景频谱「主打氛围感」，并允许在设置里关掉。
 * 本组钉住三件事：
 *   1) AppConfig 默认开启、随 JSON 往返、旧配置缺键回落为开启；
 *   2) setAmbientOn 同步到 config（不落盘于 testing 模式）并通知 UI；
 *   3) 关闭后主页**不再构造** AmbientSpectrum —— 是整层消失，而不是画成全透明。
 *
 * 第 3 条是重点：若哪天有人把门控改成 opacity/Visibility，
 * AmbientSpectrum 仍会在树上持有 spectrum 订阅与 Timer，门禁必须能抓住。
 */
import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/home_page.dart';
import 'package:auradsp_app/features/shell.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/ui/chrome.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppConfig 氛围开关', () {
    test('默认开启、随 JSON 往返、旧配置缺键回落为开启', () {
      final cfg = AppConfig();
      expect(cfg.ambientSpectrum, isTrue);

      expect((cfg.toJson()['ui'] as Map)['ambientSpectrum'], isTrue);

      cfg.ambientSpectrum = false;
      expect(AppConfig.fromJson(cfg.toJson()).ambientSpectrum, isFalse);

      // 旧版本配置文件没有该键 → 保持历史行为（有氛围背景）
      final legacy = cfg.toJson();
      legacy['ui'] = <String, dynamic>{'locale': 'zh'};
      expect(AppConfig.fromJson(legacy).ambientSpectrum, isTrue);
    });

    test('setAmbientOn 同步 config 且幂等', () {
      final m = AppModel(testing: true);
      addTearDown(m.dispose);

      expect(m.ambientOn, isTrue);
      m.setAmbientOn(false);
      expect(m.ambientOn, isFalse);
      expect(m.config.ambientSpectrum, isFalse);

      // 重复设同值不得反复通知（幂等早退）
      var notified = 0;
      void onChange() => notified++;
      m.addListener(onChange);
      m.setAmbientOn(false);
      expect(notified, 0, reason: '同值重复设置应早退，不触发重建');
      m.setAmbientOn(true);
      expect(notified, 1);
      m.removeListener(onChange);
    });
  });

  group('外壳保活下即时生效（回归：用户报「开关没有用」）', () {
    testWidgets('首页被 IndexedStack 保活、设置是模态覆盖层：关闭必须立刻消失',
        (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      await tester.pumpWidget(MaterialApp(
        theme: withAuraExtension(
            buildAuraTheme(model.themeId), model.themeId.palette),
        locale: model.locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: AppShell(model: model),
      ));
      await tester.pump();
      expect(find.byType(AmbientSpectrum), findsOneWidget);

      // 等价于点设置里的开关：此时既没有切页（设置是模态覆盖层），
      // 也没有重建外壳（_pages 缓存 HomePage 实例）。
      // 旧实现只依赖 model.notifyListeners → 首页 build 根本不跑，背景不消失。
      model.setAmbientOn(false);
      await tester.pump();
      expect(find.byType(AmbientSpectrum), findsNothing,
          reason: '保活页必须收到专门的通知源，不能等切页才生效');

      model.setAmbientOn(true);
      await tester.pump();
      expect(find.byType(AmbientSpectrum), findsOneWidget);
    });
  });

  group('主页门控', () {
    testWidgets('关闭后主页不再构造 AmbientSpectrum', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      Future<void> pumpApp() async {
        await tester.pumpWidget(MaterialApp(
          theme: withAuraExtension(
              buildAuraTheme(model.themeId), model.themeId.palette),
          locale: model.locale,
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          home: HomePage(model: model),
        ));
        await tester.pump();
      }

      await pumpApp();
      expect(find.byType(AmbientSpectrum), findsOneWidget,
          reason: '默认开启时首页应带氛围层');

      model.setAmbientOn(false);
      await pumpApp();
      expect(find.byType(AmbientSpectrum), findsNothing,
          reason: '关闭后必须整层消失（零订阅/零绘制），而不是画成全透明');

      model.setAmbientOn(true);
      await pumpApp();
      expect(find.byType(AmbientSpectrum), findsOneWidget);
    });
  });
}
