// shell_lazy_pages_test.dart — IndexedStack 惰性页实例化回归：
// 启动只构建 Home；其余页在首次访问时才 mount，之后照旧保活。
// 目的：守住启动峰值内存/CPU（6 页全量 initState 曾是最主要来源之一）。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/nav.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/chain_page.dart';
import 'package:auradsp_app/features/effects_page.dart';
import 'package:auradsp_app/features/home_page.dart';
import 'package:auradsp_app/features/liveprog_page.dart';
import 'package:auradsp_app/features/plugins_page.dart';
import 'package:auradsp_app/features/shell.dart';
import 'package:auradsp_app/features/visualizer_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: AppShell(model: model),
    );

void main() {
  testWidgets('启动只实例化 Home，首次访问才构建其他页', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final model = AppModel(testing: true);
    await tester.pumpWidget(_app(model));
    await tester.pump();

    expect(find.byType(HomePage), findsOneWidget);
    expect(find.byType(EffectsPage), findsNothing);
    expect(find.byType(LiveprogPage), findsNothing);
    expect(find.byType(PluginsPage), findsNothing);
    expect(find.byType(ChainPage), findsNothing);
    expect(find.byType(VisualizerPage), findsNothing);

    // 首次访问 Effects：同一帧内实例化（无占位闪烁）
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pump();
    expect(model.visiblePage.value, AppPage.effects);
    expect(find.byType(EffectsPage), findsOneWidget);
    expect(find.byType(VisualizerPage), findsNothing);

    // 回首页再切回：仍复用同一实例（保活语义不因惰性化而丢失）
    await tester.tap(find.byIcon(Icons.home_outlined));
    await tester.pump();
    final effectsWidget =
        tester.widget(find.byType(EffectsPage, skipOffstage: false));
    await tester.tap(find.byIcon(Icons.tune_outlined));
    await tester.pump();
    expect(
      identical(
          tester.widget(find.byType(EffectsPage, skipOffstage: false)),
          effectsWidget),
      isTrue,
      reason: '切页必须复用既有页面实例，不得重建',
    );
    // 未访问页始终没有实例
    expect(find.byType(VisualizerPage, skipOffstage: false), findsNothing);
  });

  testWidgets('ShellGate 只随连接态计数切换 fatal / shell', (tester) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final model = AppModel(testing: true);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: ShellGate(model: model),
    ));
    await tester.pump();
    expect(find.byType(AppShell), findsOneWidget);

    // 连接态计数是 ShellGate 的唯一触发源（根层不再监听整份 AppModel）。
    model.setConn(EngineConn.fatal);
    await tester.pump();
    expect(find.byType(AppShell), findsNothing);

    model.setConn(EngineConn.connecting);
    await tester.pump();
    expect(find.byType(AppShell), findsOneWidget);
  });
}
