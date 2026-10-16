// settings_vaio_test.dart — 设置页 AuraVAIO 面板 widget 回归
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/settings_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
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
}
