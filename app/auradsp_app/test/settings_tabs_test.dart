// settings_tabs_test.dart — 四大分类标签页独立性与卡片归位验证
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

  testWidgets('设置页四页切换、卡片归位与去偏好小字验证', (tester) async {
    tester.view.physicalSize = const Size(1280, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final model = AppModel(testing: true);
    addTearDown(model.dispose);

    await tester.pumpWidget(_app(model));
    await tester.pumpAndSettle();

    // 1. 验证去“偏好”小字，仅显示页面主标题“设置”
    expect(find.text('偏好'), findsNothing);
    expect(find.text('设置'), findsOneWidget);

    // 2. 默认在“音频”页 (tab 1)
    expect(find.text('处理范式'), findsOneWidget);
    expect(find.text('设备'), findsOneWidget);
    expect(find.text('采样率'), findsOneWidget);
    expect(find.text('声道数量'), findsOneWidget);
    expect(find.text('声道模式'), findsOneWidget);

    // 3. 切换到“外观”页 (tab 0)
    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();

    expect(find.text('配色方案'), findsOneWidget);
    expect(find.text('语言'), findsOneWidget);
    expect(find.text('采样率'), findsNothing);
    expect(find.text('测试音频源'), findsNothing);

    // 4. 切换到“系统”页 (tab 2)
    await tester.tap(find.text('系统'));
    await tester.pumpAndSettle();

    expect(find.text('引擎'), findsOneWidget);
    expect(find.text('持久化记忆与配置外置'), findsOneWidget);
    expect(find.text('采样率'), findsNothing);
    expect(find.text('测试音频源'), findsNothing);

    // 5. 切换到“测试”页 (tab 3)
    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();

    // 测试音频源框完好无损地呈现在测试页
    expect(find.text('测试音频源'), findsOneWidget);
    expect(find.text('测试音 440Hz'), findsOneWidget);
    expect(find.text('粉噪'), findsOneWidget);
    // 引擎信息不在测试页
    expect(find.text('引擎'), findsNothing);
  });
}
