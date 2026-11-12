// settings_vaio_test.dart — 设置页 AuraVAIO 面板 widget 回归
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/settings_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/ui/chrome.dart';
import 'package:auradsp_app/platform/platform_profile.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      locale: model.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(body: SettingsPage(model: model)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('settings_vaio', () {
    testWidgets('non-vaio mode does not render the VAIO panel', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_app(model));
      await tester.pumpAndSettle();
      expect(find.text('物理输出'), findsNothing);
    });

    testWidgets('vaio mode renders physical output dropdown and refresh',
        (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_app(model));
      await tester.pumpAndSettle();
      model.setAudioMode('vaio');
      // 2026-11-09 起 pipelineOutputForMode 明确不改写用户输出选择：
      // 切到 vaio 模式仍保留当前管线输出，需显式选 VAIO 才渲染物理
      // 输出子面板（旧断言假设模式会自动改写，已过时）。
      model.setPipelineOutput('vaio');
      await tester.pumpAndSettle();
      expect(find.text('物理输出'), findsOneWidget);
      expect(find.text('自动选择（非VAIO扬声器）'), findsOneWidget);
    });

    testWidgets('vaio output selection persists', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_app(model));
      await tester.pumpAndSettle();
      model.setAudioMode('vaio');
      await tester.pumpAndSettle();
      model.setVaioOutputEndpoint('Realtek High Definition Audio');
      await tester.pumpAndSettle();
      expect(model.config.vaioOutputEndpoint, 'Realtek High Definition Audio');
    });

    // 第二十一轮：断路器跳过态必须在设备页 VAIO 块有常驻横幅
    // 与一键「仍然启动」；跳过态在进入 VAIO 之后置位（手动进入
    // 本身会清除它，故以字段直注复现 ready 跳过的会话内状态）。
    testWidgets('guard tripped in vaio mode shows banner; start-anyway clears',
        (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_app(model));
      await tester.pumpAndSettle();
      model.setAudioMode('vaio');
      model.setPipelineInput('vaio');
      model.vaioBootGuardTripped = true;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(model.vaioGuardBlocksCurrentMode, isTrue);
      // 点 chip 本体（内层 Text 的中心点落在壳层 Stack 的命中
      // 链外，首跑实证 tap 落空）：先滚入视口再点。
      final chip = find.byWidgetPredicate(
          (w) => w is AuraChip && w.label == '仍然启动');
      expect(chip, findsOneWidget);
      await tester.ensureVisible(chip);
      await tester.pumpAndSettle();
      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(model.vaioBootGuardTripped, isFalse);
      expect(find.text('仍然启动'), findsNothing);
    });

    testWidgets('guard tripped without vaio chain shows no banner',
        (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_app(model));
      await tester.pumpAndSettle();
      model.setPipelineInput('wasapi');
      model.setPipelineOutput('wasapi');
      model.vaioBootGuardTripped = true;
      model.notifyListeners();
      await tester.pumpAndSettle();
      expect(model.vaioGuardBlocksCurrentMode, isFalse);
      expect(find.text('仍然启动'), findsNothing);
    });
  }, skip: !PlatformProfile.isWindows ? 'VAIO settings panel is Windows only' : null);
}
