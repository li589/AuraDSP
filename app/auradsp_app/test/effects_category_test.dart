// effects_category_test.dart — 效果页分类过滤回归（无"全部"，4 类按页展示）：
// 默认 front（5 卡 + 预设 = 6）；spatial 为空间卡 + 5 子卡 + 预设（7）；
// core 7 卡 + 预设（8）；late 3 卡 + 预设（4）。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/effects_page.dart';
import 'package:auradsp_app/features/widgets.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(AppModel model) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: EffectsPage(model: model)),
    );

Future<void> _pumpPage(WidgetTester tester, AppModel model) async {
  tester.view.physicalSize = const Size(1280, 2400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app(model));
  await tester.pumpAndSettle();
}

int _sectionCards(WidgetTester tester) =>
    tester.widgetList(find.byType(SectionCard)).length;

void main() {
  testWidgets('no all, per-category card counts, spacing present',
      (tester) async {
    final model = AppModel(testing: true);
    await _pumpPage(tester, model);

    // 默认 front：4 卡 (input, gate, filter, bass_shaping) + 预设卡 = 5
    expect(model.effectsCategory, 'front');
    expect(_sectionCards(tester), 5);
    // 无"全部"下拉项
    expect(find.text('All'), findsNothing);

    // 空间类：空间卡 + 5 子卡 + 预设卡；空间卡不编号
    model.setEffectsCategory('spatial');
    await tester.pumpAndSettle();
    expect(_sectionCards(tester), 7);
    expect(find.text('Spatial Reverb'), findsOneWidget);

    // 核心处理：7 卡 + 预设卡
    model.setEffectsCategory('core');
    await tester.pumpAndSettle();
    expect(_sectionCards(tester), 8);

    // 激励与输出：3 卡 + 预设卡
    model.setEffectsCategory('late');
    await tester.pumpAndSettle();
    expect(_sectionCards(tester), 4);
  });

  test('per-category numbering is 1-based within each category', () {
    // front 类 5 张：1..5；core 类 7 张：1..7；late 3 张：1..3；空间 null。
    for (var i = 0; i < kEffectCategories['front']!.length; i++) {
      final id = kEffectCategories['front']![i];
      expect(kEffectCardIndex[id], '${i + 1}', reason: id);
    }
    for (var i = 0; i < kEffectCategories['core']!.length; i++) {
      final id = kEffectCategories['core']![i];
      expect(kEffectCardIndex[id], '${i + 1}', reason: id);
    }
    for (var i = 0; i < kEffectCategories['late']!.length; i++) {
      final id = kEffectCategories['late']![i];
      expect(kEffectCardIndex[id], '${i + 1}', reason: id);
    }
    // 空间类去编号
    expect(kEffectCardIndex['spatial'], isNull);
    // 每张卡恰好属于一个类
    final seen = <String, String>{};
    for (final e in kEffectCategories.entries) {
      for (final id in e.value) {
        expect(seen.containsKey(id), isFalse, reason: '$id double-grouped');
        seen[id] = e.key;
      }
    }
  });
}
