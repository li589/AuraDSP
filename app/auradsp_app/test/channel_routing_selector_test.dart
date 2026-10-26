// channel_routing_selector_test.dart — WP9 (U-6, U-7): 声道路由器拓扑感知与诚实性测试
import 'dart:io';

import 'package:auradsp_app/core/config.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/effects_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, AppModel model) => MaterialApp(
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      locale: model.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: child,
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Directory? tempDir;
  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('routing_test_');
    ConfigManager.baseDirOverride = tempDir!.path;
  });

  tearDown(() {
    ConfigManager.baseDirOverride = null;
    try {
      tempDir?.deleteSync(recursive: true);
    } catch (_) {}
  });

  group('WP9 U-7: layout_for(ch) 声道拓扑与全开掩码映射', () {
    test('channelsFor 与 fullMaskFor 对齐 2/4/6/8 声道布局', () {
      // 2ch: FL, FR
      final ch2 = ChannelRoutingSelector.channelsFor(2);
      expect(ch2.map((c) => c.code).toList(), ['FL', 'FR']);
      expect(ch2.map((c) => c.bit).toList(), [0, 1]);
      expect(ChannelRoutingSelector.fullMaskFor(2), 0x03);

      // 4ch (Quad): FL=0, FR=1, BL=2, BR=3（engine layout_for(4) 同源）
      final ch4 = ChannelRoutingSelector.channelsFor(4);
      expect(ch4.map((c) => c.code).toList(), ['FL', 'FR', 'BL', 'BR']);
      expect(ch4.map((c) => c.bit).toList(), [0, 1, 2, 3]);
      expect(ChannelRoutingSelector.fullMaskFor(4), 0x0F);

      // 6ch (5.1): FL, FR, C, LFE, SL, SR
      final ch6 = ChannelRoutingSelector.channelsFor(6);
      expect(ch6.map((c) => c.code).toList(), ['FL', 'FR', 'C', 'LFE', 'SL', 'SR']);
      expect(ch6.map((c) => c.bit).toList(), [0, 1, 2, 3, 4, 5]);
      expect(ChannelRoutingSelector.fullMaskFor(6), 0x3F);

      // 8ch (7.1): FL, FR, C, LFE, SL, SR, BL, BR
      final ch8 = ChannelRoutingSelector.channelsFor(8);
      expect(ch8.map((c) => c.code).toList(),
          ['FL', 'FR', 'C', 'LFE', 'SL', 'SR', 'BL', 'BR']);
      expect(ch8.map((c) => c.bit).toList(), [0, 1, 2, 3, 4, 5, 6, 7]);
      expect(ChannelRoutingSelector.fullMaskFor(8), 0xFF);
    });
  });

  group('WP9 U-7: 掩码选择器按实际布局渲染 Chips 与自适应预设', () {
    testWidgets('4 声道模式仅渲染 FL/FR/BL/BR (4 个 chip) 与仅前置/后置预设', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      model.setInt('channels.mode', 1); // 离散模式
      model.setChannelsCountMode(1);
      model.setChannelsCount(4);

      await tester.pumpWidget(_wrap(
        ChannelRoutingSelector(model: model, paramKey: 'eq.channels'),
        model,
      ));
      await tester.pumpAndSettle();

      // 展开路由器
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      // 验证仅渲染 4 个 chip
      expect(find.text('FL'), findsOneWidget);
      expect(find.text('FR'), findsOneWidget);
      expect(find.text('BL'), findsOneWidget);
      expect(find.text('BR'), findsOneWidget);
      expect(find.text('C'), findsNothing);
      expect(find.text('LFE'), findsNothing);
      expect(find.text('SL'), findsNothing);
      expect(find.text('SR'), findsNothing);

      // 验证自适应预设
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('仅前置'), findsOneWidget);
      expect(find.text('仅后置'), findsOneWidget);

      // 点选仅后置 (BL/BR: bit2/3 = 0x0C，与 engine layout_for(4) 对齐)
      await tester.tap(find.text('仅后置'));
      await tester.pumpAndSettle();

      expect(model.mirrorInt('eq.channels', 0), 0x0C);
      expect(find.text('2/4 声道已选'), findsOneWidget);

      // 点选全选 (0x0F)：四个声道全部处理（旧 0xC3 只覆盖 FL/FR）
      await tester.tap(find.text('全选'));
      await tester.pumpAndSettle();

      expect(model.mirrorInt('eq.channels', 0), 0x0F);
      expect(find.text('4/4 声道已选'), findsOneWidget);

      // 单 chip 切换：FL 关 → 0x0E；再开 → 0x0F
      await tester.tap(find.text('FL'));
      await tester.pumpAndSettle();
      expect(model.mirrorInt('eq.channels', 0), 0x0E);
      expect(find.text('3/4 声道已选'), findsOneWidget);

      await tester.tap(find.text('FL'));
      await tester.pumpAndSettle();
      expect(model.mirrorInt('eq.channels', 0), 0x0F);
      expect(find.text('4/4 声道已选'), findsOneWidget);
    });

    testWidgets('6 声道模式仅渲染 6 个 chip 与无超低/仅环绕预设', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      model.setInt('channels.mode', 1); // 离散模式
      model.setChannelsCountMode(1);
      model.setChannelsCount(6);

      await tester.pumpWidget(_wrap(
        ChannelRoutingSelector(model: model, paramKey: 'comp.channels'),
        model,
      ));
      await tester.pumpAndSettle();

      // 展开路由器
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(find.text('FL'), findsOneWidget);
      expect(find.text('FR'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(find.text('LFE'), findsOneWidget);
      expect(find.text('SL'), findsOneWidget);
      expect(find.text('SR'), findsOneWidget);
      expect(find.text('BL'), findsNothing);
      expect(find.text('BR'), findsNothing);

      // 验证自适应预设
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('立体声'), findsOneWidget);
      expect(find.text('无超低'), findsOneWidget);
      expect(find.text('仅环绕'), findsOneWidget);

      // 点选仅环绕 (SL/SR: 0x30)
      await tester.tap(find.text('仅环绕'));
      await tester.pumpAndSettle();

      expect(model.mirrorInt('comp.channels', 0), 0x30);
      expect(find.text('2/6 声道已选'), findsOneWidget);

      // 点选无超低 (0x3F & ~0x08 = 0x37)
      await tester.tap(find.text('无超低'));
      await tester.pumpAndSettle();

      expect(model.mirrorInt('comp.channels', 0), 0x37);
      expect(find.text('5/6 声道已选'), findsOneWidget);
    });
  });

  group('WP9 U-6: 立体声与矩阵下混路径诚实性', () {
    testWidgets('立体声路径 (2ch) 显示直通提示与摘要，禁止虚假计数', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      model.setChannelsCountMode(1);
      model.setChannelsCount(2);

      await tester.pumpWidget(_wrap(
        ChannelRoutingSelector(model: model, paramKey: 'limiter.channels'),
        model,
      ));
      await tester.pumpAndSettle();

      // 摘要徽标诚实显示直通
      expect(find.text('直通 (立体声/矩阵路径)'), findsOneWidget);
      expect(find.textContaining('声道已选'), findsNothing);

      // 展开后显示直通提示卡
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(find.text('当前处于立体声或矩阵下混路径，所有声道统一处理，独立声道掩码不生效。'), findsOneWidget);
    });

    testWidgets('矩阵下混路径 (channelsMode=0 且 6ch) 显示直通提示与摘要', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      model.setInt('channels.mode', 0); // 矩阵模式
      model.setChannelsCountMode(1);
      model.setChannelsCount(6);

      expect(model.isStereoPath, isTrue);

      await tester.pumpWidget(_wrap(
        ChannelRoutingSelector(model: model, paramKey: 'gate.channels'),
        model,
      ));
      await tester.pumpAndSettle();

      expect(find.text('直通 (立体声/矩阵路径)'), findsOneWidget);
      expect(find.textContaining('声道已选'), findsNothing);

      // 展开后显示直通提示卡
      await tester.tap(find.byType(InkWell).first);
      await tester.pumpAndSettle();

      expect(find.text('当前处于立体声或矩阵下混路径，所有声道统一处理，独立声道掩码不生效。'), findsOneWidget);
    });

    testWidgets('双耳渲染路径 (spatialBinaural + 6ch) 同样诚实显示直通', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      model.setInt('channels.mode', 1); // 离散模式
      model.setChannelsCountMode(1);
      model.setChannelsCount(6);
      model.setSpatialEnabled(true);
      model.setSpatialBinaural(true);

      expect(model.isStereoPath, isTrue);

      await tester.pumpWidget(_wrap(
        ChannelRoutingSelector(model: model, paramKey: 'tube.channels'),
        model,
      ));
      await tester.pumpAndSettle();

      expect(find.text('直通 (立体声/矩阵路径)'), findsOneWidget);
      expect(find.textContaining('声道已选'), findsNothing);
    });
  });
}
