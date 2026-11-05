// chain_scifi_flow_panel_test.dart — 科幻信号流面板与实时插件物理拓扑测试
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/plugins/plugin_manager.dart';
import 'package:auradsp_app/core/plugins/plugin_models.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/chain/chain_scifi_flow_panel.dart';
import 'package:auradsp_app/features/chain_page.dart' show kDefaultCoreOrder;
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: SingleChildScrollView(child: child)),
    );

void main() {
  testWidgets('科幻信号流面板触发条正常渲染并支持展开与收起', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final model = AppModel(testing: true);
    await tester.pumpWidget(_wrap(ChainScifiFlowPanel(
      order: kDefaultCoreOrder,
      model: model,
    )));
    await tester.pumpAndSettle();

    // 1. 验证大号标题与副标题渲染
    expect(find.text('全局信号流顺序'), findsOneWidget);
    expect(find.text('全链路 24 节点拓扑 · 实时 Stage 0~4 插件注入映射 · 支持平移缩放'), findsOneWidget);
    expect(find.text('显示全景'), findsOneWidget);

    // 2. 点击“显示全景”按钮展开面板
    await tester.tap(find.text('显示全景'));
    await tester.pump(const Duration(milliseconds: 100));
    await tester.pump(const Duration(milliseconds: 300));

    // 展开后按钮文字变为“收起面板”
    expect(find.text('收起面板'), findsOneWidget);
    expect(find.text('SIGNAL ROUTING TOPOLOGY (PHYSICAL ORDER)'), findsOneWidget);
    expect(find.text('100% 复位'), findsOneWidget);

    // 3. 点击“100% 复位”
    await tester.tap(find.text('100% 复位'));
    await tester.pump();

    // 4. 点击“收起面板”收起
    await tester.tap(find.text('收起面板'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('显示全景'), findsOneWidget);
  });

  testWidgets('激活插件插槽在对应 Stage 准确渲染芯片节点', (tester) async {
    tester.view.physicalSize = const Size(1280, 1600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final model = AppModel(testing: true);
    // 模拟槽位 0 挂载 Pre-DSP 插件
    model.pluginManager.onPluginSlotStatus(0, {
      'hasActive': true,
      'status': 2,
      'latency': 64,
      'plugin': {
        'name': 'FabFilter Pro-Q 3',
        'vendor': 'FabFilter',
        'format': 'vst3',
        'category': 'EQ',
        'path': 'C:/vst/Pro-Q3.vst3',
      },
    }, PluginInsertStage.preDsp);

    await tester.pumpWidget(_wrap(ChainScifiFlowPanel(
      order: kDefaultCoreOrder,
      model: model,
    )));
    await tester.pump();

    // 展开面板
    await tester.tap(find.text('显示全景'));
    await tester.pump(const Duration(milliseconds: 400));

    // 验证插件节点渲染
    expect(find.text('SLOT 1'), findsOneWidget);
    expect(find.text('FabFilter Pro-Q 3'), findsOneWidget);
    expect(find.text('Pre-DSP'), findsOneWidget);
    expect(find.text('64 spl'), findsOneWidget);

    // 收起动画
    await tester.tap(find.text('收起面板'));
    await tester.pump(const Duration(milliseconds: 400));
  });
}
