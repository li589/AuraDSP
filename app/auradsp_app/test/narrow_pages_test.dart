// narrow_pages_test.dart — 窄屏页内布局回归（2026-11-20 窄屏立项 P3）
//
// 覆盖：Q2 最小支持宽度 360 下，六个主页逐页装载不产生 RenderFlex/裁切异常。
// 断点基础设施（P0）与外壳/浮层（P1/P2）已在各自测试覆盖，本文件只看页内。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/nav.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/shell.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _pageNames = <String>[
  'home',
  'effects',
  'liveprog',
  'plugins',
  'chain',
  'visualizer',
];

Future<AppModel> _pumpAt(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final model = AppModel(testing: true);
  // 每个用例一个模型：用完必须释放，否则 7 个用例累计的定时器会拖垮测试
  // isolate（表现为整文件 did-not-complete，与 B13 同型的基建抖动）。
  addTearDown(model.dispose);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: AppShell(model: model),
    ),
  );
  // 视效页含持续动画，禁用 pumpAndSettle。
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
  return model;
}

/// 收尾：切回首页让视效页转入离屏（TickerMode 关停动画）。
/// 直接卸载整树会更慢且偶发挂起，切页最贴近真实使用路径。
Future<void> _parkOnHome(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey<String>('shell.nav.0')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 200));
}

void main() {
  group('窄屏页内布局', () {
    for (var i = 0; i < _pageNames.length; i++) {
      testWidgets('360x800 ${_pageNames[i]} 页无布局异常', (tester) async {
        final model = await _pumpAt(tester, const Size(360, 800));
        await tester.tap(find.byKey(ValueKey<String>('shell.nav.$i')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));

        expect(model.visiblePage.value, AppPage.values[i]);
        expect(
          tester.takeException(),
          isNull,
          reason: '360x800 下 ${_pageNames[i]} 页出现布局异常',
        );
        await _parkOnHome(tester);
      });
    }

    testWidgets('480x900 六页巡回无布局异常', (tester) async {
      final model = await _pumpAt(tester, const Size(480, 900));
      for (var i = 0; i < _pageNames.length; i++) {
        await tester.tap(find.byKey(ValueKey<String>('shell.nav.$i')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(model.visiblePage.value, AppPage.values[i]);
        expect(
          tester.takeException(),
          isNull,
          reason: '480x900 下 ${_pageNames[i]} 页出现布局异常',
        );
      }
      await _parkOnHome(tester);
    });

    // P4：桌面结构回归（非像素基线）。页内降级都按宽度分支，必须验证
    // ≥900 仍走宽布局且不因新分支产生溢出。
    testWidgets('1200x900 六页巡回无布局异常（桌面结构回归）', (tester) async {
      final model = await _pumpAt(tester, const Size(1200, 900));
      for (var i = 0; i < _pageNames.length; i++) {
        await tester.tap(find.byKey(ValueKey<String>('shell.railNav.$i')));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(model.visiblePage.value, AppPage.values[i]);
        expect(
          tester.takeException(),
          isNull,
          reason: '1200x900 下 ${_pageNames[i]} 页出现布局异常',
        );
      }
      await tester.tap(find.byKey(const ValueKey<String>('shell.railNav.0')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
    });
  });
}
