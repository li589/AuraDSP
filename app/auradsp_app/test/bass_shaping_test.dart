import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/effects_page.dart';
import 'package:auradsp_app/features/widgets.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, AppModel model) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('zh'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: child),
    );

void main() {
  group('Bass Shaping 合并回归测试', () {
    test('状态与开关联动：setBassShapingEnabled 同时控制 shelf 与 bassmono', () {
      final model = AppModel(testing: true);

      // 初始为关
      expect(model.bassShapingOn, isFalse);
      expect(model.shelfOn, isFalse);
      expect(model.bassmonoOn, isFalse);
      expect(model.isSectionEnabled('bass_shaping'), isFalse);
      expect(model.isSectionEnabled('shelf'), isFalse);
      expect(model.isSectionEnabled('bassmono'), isFalse);

      // 开启总开关
      model.setBassShapingEnabled(true);
      expect(model.bassShapingOn, isTrue);
      expect(model.shelfOn, isTrue);
      expect(model.bassmonoOn, isTrue);
      expect(model.isSectionEnabled('bass_shaping'), isTrue);
      expect(model.isSectionEnabled('shelf'), isTrue);
      expect(model.isSectionEnabled('bassmono'), isTrue);

      // 关闭总开关
      model.setBassShapingEnabled(false);
      expect(model.bassShapingOn, isFalse);
      expect(model.shelfOn, isFalse);
      expect(model.bassmonoOn, isFalse);
      expect(model.isSectionEnabled('bass_shaping'), isFalse);
      expect(model.isSectionEnabled('shelf'), isFalse);
      expect(model.isSectionEnabled('bassmono'), isFalse);
    });

    test('参数范围与赋值：增益分频、增益、低音单声道分频', () {
      final model = AppModel(testing: true);

      // 增益分频 (40~400Hz)
      model.setShelfFreq(150.0);
      expect(model.shelfFreq, 150.0);
      model.setShelfFreq(30.0); // clamp 40
      expect(model.shelfFreq, 40.0);
      model.setShelfFreq(500.0); // clamp 400
      expect(model.shelfFreq, 400.0);

      // 增益 (-15~+15dB)
      model.setShelfGain(6.5);
      expect(model.shelfGain, 6.5);
      model.setShelfGain(-20.0); // clamp -15
      expect(model.shelfGain, -15.0);
      model.setShelfGain(20.0); // clamp 15
      expect(model.shelfGain, 15.0);

      // 低音单声道分频 (20~300Hz)
      model.setBassmonoFreq(90.0);
      expect(model.bassmonoFreq, 90.0);
      model.setBassmonoFreq(10.0); // clamp 20
      expect(model.bassmonoFreq, 20.0);
      model.setBassmonoFreq(350.0); // clamp 300
      expect(model.bassmonoFreq, 300.0);
    });

    testWidgets('UI 渲染结构：卡片序号为 4，纯 3 个滑块，无高级选项卡，无冗余说明文字', (tester) async {
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      model.setBassShapingEnabled(true);

      await tester.pumpWidget(_wrap(EffectsPage(model: model), model));
      await tester.pumpAndSettle();

      // 卡片存在且标题为「低音塑形」
      expect(find.text('低音塑形'), findsOneWidget);

      // 寻找对应的 SectionCard
      final sectionCards = tester.widgetList<SectionCard>(find.byType(SectionCard));
      final bassCard = sectionCards.firstWhere((c) => c.title == '低音塑形');
      expect(bassCard.index, '4');

      // 恰好 3 个调节滑块标签
      expect(find.text('增益分频'), findsOneWidget);
      expect(find.text('增益'), findsOneWidget);
      expect(find.text('低音单声道分频'), findsOneWidget);

      // 低音塑形卡片内部不应存在任何 AdvancedSection 折叠抽屉
      expect(
        find.descendant(
          of: find.widgetWithText(SectionCard, '低音塑形'),
          matching: find.byType(AdvancedSection),
        ),
        findsNothing,
      );

      // 也不存在旧的冗余提示文案
      expect(find.textContaining('分频点以下整体托起/压低'), findsNothing);
    });
  });
}
