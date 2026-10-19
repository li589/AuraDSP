// settings_asio_test.dart — 设置页 ASIO 面板 widget 回归（Phase 3）。
//
// 覆盖 Spec Phase 3 验收的"UI 自动化过选择器交互"：audioMode 切到 asio 后
// 设备卡出现驱动选择器/缓冲档/输出对三行 + 刷新入口；未选驱动时显示占位
// 而非崩溃；非 asio 模式不渲染 ASIO 面板。
// AppModel(testing: true) 不 spawn 音频 isolate——纯 UI 面测试。
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
      // DropdownButton 需要 Material 祖先（真机里由 ShellGate 的 Scaffold 提供）。
      home: Scaffold(body: SettingsPage(model: model)),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('non-asio mode does not render the ASIO panel', (tester) async {
    final model = AppModel(testing: true);
    addTearDown(model.dispose);
    await tester.pumpWidget(_app(model));
    await tester.pumpAndSettle();
    expect(find.text('缓冲档'), findsNothing);
  });

  testWidgets('asio mode renders driver/buffer/out-pair rows and refresh',
      (tester) async {
    final model = AppModel(testing: true);
    addTearDown(model.dispose);
    await tester.pumpWidget(_app(model));
    await tester.pumpAndSettle();
    // 切 asio（testing 模式无 isolate：asiodetect 无回执，面板照常渲染）。
    model.setAudioMode('asio');
    await tester.pumpAndSettle();
    expect(find.text('缓冲档'), findsOneWidget);
    expect(find.text('输出起始声道对'), findsOneWidget);
    expect(find.text('刷新驱动'), findsOneWidget);
    // 未选驱动（清单空）：占位 '—' 而非崩溃；输出对默认 ch 1/2；缓冲默认自动。
    expect(find.text('—'), findsOneWidget);
    expect(find.text('ch 1/2'), findsOneWidget);
    expect(find.text('自动（驱动首选）'), findsOneWidget);
  });

  testWidgets('driver selection persists and re-render highlights', (tester) async {
    final model = AppModel(testing: true);
    addTearDown(model.dispose);
    await tester.pumpWidget(_app(model));
    await tester.pumpAndSettle();
    model.setAudioMode('asio');
    await tester.pumpAndSettle();
    // 清单为空时无下拉可点：直接走 setter（桥未跑不触发 restart）。
    model.setAsioDriver('FL Studio ASIO');
    model.setAsioBufSize(512);
    model.setAsioOutPair(1);
    await tester.pumpAndSettle();
    expect(model.config.asioDriver, 'FL Studio ASIO');
    expect(model.config.asioBufSize, 512);
    expect(model.config.asioOutPair, 1);
    // 输出对切换后显示 ch 3/4。
    expect(find.text('ch 3/4'), findsOneWidget);
    expect(find.text('512 frames'), findsOneWidget);
  });
}
