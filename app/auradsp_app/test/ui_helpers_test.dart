// ui_helpers_test.dart — P0 基础设施回归：断点 / InfoBadge / AuraChoiceChip
import 'dart:ui' show PointerDeviceKind;

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/core/ui_helpers.dart';
import 'package:auradsp_app/features/widgets.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app(Widget child) => MaterialApp(
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: Center(child: child)),
    );

Future<AuraBreakpoint> _breakpointOf(
    WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late AuraBreakpoint got;
  await tester.pumpWidget(_app(Builder(builder: (ctx) {
    got = ctx.auraBreakpoint;
    return const SizedBox();
  })));
  return got;
}

void main() {
  group('AuraBreakpoint', () {
    testWidgets('500 -> mobile / 700 -> tablet / 1200 -> desktop',
        (tester) async {
      expect(await _breakpointOf(tester, 500), AuraBreakpoint.mobile);
      expect(await _breakpointOf(tester, 700), AuraBreakpoint.tablet);
      expect(await _breakpointOf(tester, 1200), AuraBreakpoint.desktop);
    });

    testWidgets('pageX 按档位 16 / 24 / 32', (tester) async {
      tester.view.physicalSize = const Size(500, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late double px;
      await tester.pumpWidget(_app(Builder(builder: (ctx) {
        px = ctx.responsivePageX;
        return const SizedBox();
      })));
      expect(px, AuraSpace.lg);
    });
  });

  group('InfoBadge', () {
    testWidgets('渲染问号徽标（默认不弹气泡）', (tester) async {
      await tester.pumpWidget(_app(const InfoBadge(message: '混响说明')));
      expect(find.byIcon(Icons.question_mark_rounded), findsOneWidget);
      expect(find.text('混响说明'), findsNothing);
    });

    testWidgets('桌面 hover 300ms 弹出、移出关闭', (tester) async {
      await tester.pumpWidget(_app(const InfoBadge(message: '混响说明')));
      final center = tester.getCenter(find.byType(InfoBadge));
      final gesture =
          await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: center);
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('混响说明'), findsOneWidget);
      await gesture.moveTo(Offset.zero);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('混响说明'), findsNothing);
      await gesture.removePointer();
    });

    testWidgets('长按弹出、点徽标关闭', (tester) async {
      await tester.pumpWidget(_app(const InfoBadge(message: '混响说明')));
      await tester.longPress(find.byType(InfoBadge));
      await tester.pump();
      expect(find.text('混响说明'), findsOneWidget);
      await tester.tap(find.byType(InfoBadge));
      await tester.pump();
      expect(find.text('混响说明'), findsNothing);
    });

    testWidgets('气泡锚定在徽标上（不叠加 follower 偏移）', (tester) async {
      // 回归：曾把屏幕全局坐标直接喂给 CompositedTransformFollower 的
      // Positioned，而 follower 本身已平移一个 target 偏移 → 定位值叠加两遍，
      // 气泡被下推/右移整整一个徽标坐标。此处钉住「贴着徽标」这一契约。
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_app(const InfoBadge(message: '混响说明')));
      await tester.longPress(find.byType(InfoBadge));
      await tester.pump();

      final badge = tester.getRect(find.byType(InfoBadge));
      final text = tester.getRect(find.text('混响说明'));

      // 纵向：紧贴徽标下方（箭头 7 + 内边距 7），不许跑到半个屏幕以下。
      expect(text.top, greaterThan(badge.bottom - 2));
      expect(text.top, lessThan(badge.bottom + 40));
      // 横向：以徽标中心对齐（箭头指向徽标），不许右移一个 origin.dx。
      expect((text.center.dx - badge.center.dx).abs(), lessThan(24));
    });

    testWidgets('空间不足时翻转到徽标上方且锚定正确', (tester) async {
      tester.view.physicalSize = const Size(1000, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: withAuraExtension(ThemeData.dark(), auraDark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: const InfoBadge(message: '混响说明'),
          ),
        ),
      ));
      await tester.longPress(find.byType(InfoBadge));
      await tester.pump();

      final badge = tester.getRect(find.byType(InfoBadge));
      final text = tester.getRect(find.text('混响说明'));
      expect(text.bottom, lessThan(badge.top + 2));
      expect(text.bottom, greaterThan(badge.top - 60));
    });

    testWidgets('贴底边时气泡不闪动（hover 稳定后持续可见）', (tester) async {
      // 回归：OverlayEntry 内的 Material + 全屏 SizedBox 覆盖在徽标之上，
      // 插入那一帧抢走徽标命中 → onExit → _hide → 指针回到徽标 → onEnter
      // → 300ms 后再弹出。徽标贴底边（气泡翻转到上方）时最明显。
      // 实测闪动序列 ENTER→SHOW→EXIT→HIDE 循环，周期约 360ms。
      tester.view.physicalSize = const Size(1000, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: withAuraExtension(ThemeData.dark(), auraDark),
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: const InfoBadge(message: '混响说明'),
          ),
        ),
      ));

      final badge = tester.getRect(find.byType(InfoBadge));
      final g = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await g.addPointer(location: Offset(badge.center.dx, 5));
      await tester.pump(const Duration(milliseconds: 16));
      // 从上方逼近徽标中心。
      for (int i = 1; i <= 12; i++) {
        await g.moveTo(Offset.lerp(
            Offset(badge.center.dx, 5), badge.center, i / 12)!);
        await tester.pump(const Duration(milliseconds: 40));
      }

      // 先等气泡出现（hover 延迟 300ms）。
      var appeared = false;
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        if (find.text('混响说明').evaluate().isNotEmpty) {
          appeared = true;
          break;
        }
      }
      expect(appeared, isTrue, reason: 'hover 后气泡始终未出现');

      // 指针保持不动：气泡一旦出现就必须持续存在，不能反复消失再出现。
      for (int i = 0; i < 30; i++) {
        await tester.pump(const Duration(milliseconds: 40));
        expect(find.text('混响说明'), findsOneWidget,
            reason: '气泡在出现后第 $i 步消失了（闪动）');
      }
      await g.removePointer();
    });

    testWidgets('翻上与翻下到徽标的间距对称且不压住徽标', (tester) async {
      // 回归：翻上的气泡曾直接压住问号。根因有二——
      // ① 几何不对称：翻下尖端距徽标 11px，翻上只有 4px；
      // ② 预估高度与真实渲染不一致（TextPainter 复刻不出实际布局），
      //    而翻上是「减去」高度，估小即把气泡推到徽标上。
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: withAuraExtension(ThemeData.dark(), auraDark),
        home: Scaffold(
          body: Column(
            children: [
              SizedBox(
                height: 380,
                child: Row(children: const [InfoBadge(message: 'GAP-A-混响预听说明')]),
              ),
              const Spacer(),
              Row(
                  children: const [InfoBadge(message: 'GAP-B-混响预听说明')]),
            ],
          ),
        ),
      ));

      await tester.longPress(find.byType(InfoBadge).at(0));
      await tester.pump();
      // 等待首帧后的真实尺寸回正生效。
      await tester.pump();
      await tester.longPress(find.byType(InfoBadge).at(1));
      await tester.pump();
      await tester.pump();

      double gapOf(String msg, int badgeIndex) {
        final badge = tester.getRect(find.byType(InfoBadge).at(badgeIndex));
        final bubble = tester.getRect(find
            .ancestor(of: find.text(msg), matching: find.byType(Container))
            .first);
        return bubble.top > badge.center.dy
            ? bubble.top - badge.bottom
            : badge.top - bubble.bottom;
      }

      final below = gapOf('GAP-A-混响预听说明', 0); // 视口中部 → 向下展开
      final above = gapOf('GAP-B-混响预听说明', 1); // 贴近底边 → 向上翻转
      expect(above, closeTo(below, 0.01), reason: '翻上/翻下间距不对称');
      // 旧实现翻上时箭头尖端距徽标仅 4px，看上去就是「没有偏移、直接压住问号」。
      expect(below, greaterThanOrEqualTo(14.0), reason: '气泡与徽标间距过小');
      expect(above, greaterThan(0.0), reason: '气泡压住徽标');
    });
  });

  group('AuraChoiceChip', () {
    testWidgets('点击触发 onTap，文案可见', (tester) async {
      var tapped = 0;
      await tester.pumpWidget(_app(AuraChoiceChip(
        label: '动态',
        selected: false,
        onTap: () => tapped++,
      )));
      expect(find.text('动态'), findsOneWidget);
      await tester.tap(find.text('动态'));
      expect(tapped, 1);
    });

    testWidgets('onTap 为空不断言、不崩', (tester) async {
      await tester.pumpWidget(_app(const AuraChoiceChip(
        label: '静态',
        selected: true,
        onTap: null,
      )));
      expect(find.text('静态'), findsOneWidget);
      await tester.tap(find.text('静态'));
      await tester.pump();
    });
  });

  group('HelpVisibilityScope & Mobile Scroll Auto-Fade', () {
    testWidgets('桌面端（宽屏）InfoBadge 持续常驻显示', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = HelpVisibilityController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_app(HelpVisibilityScope(
        controller: controller,
        child: const InfoBadge(message: '桌面提示测试'),
      )));

      final opacityFinder = find.byType(AnimatedOpacity);
      expect(opacityFinder, findsOneWidget);
      final opacityWidget = tester.widget<AnimatedOpacity>(opacityFinder);
      expect(opacityWidget.opacity, 1.0);
    });

    testWidgets('移动端未滑动时保持隐藏，滑动时唤醒显示，停止后延迟隐藏', (tester) async {
      tester.view.physicalSize = const Size(400, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final controller = HelpVisibilityController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_app(HelpVisibilityScope(
        controller: controller,
        child: const InfoBadge(message: '移动端提示测试'),
      )));

      // 1. 移动端初始不滑动状态：透明度为 0.0
      var opacityWidget = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(opacityWidget.opacity, 0.0);

      // 2. 模拟滑动触发 recordScroll()
      controller.recordScroll();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      opacityWidget = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(opacityWidget.opacity, 1.0);

      // 3. 停止滑动 2600ms 后自动淡出
      await tester.pump(const Duration(milliseconds: 2700));
      await tester.pump(const Duration(milliseconds: 250));

      opacityWidget = tester.widget<AnimatedOpacity>(find.byType(AnimatedOpacity));
      expect(opacityWidget.opacity, 0.0);
    });

    testWidgets('InfoBadge 点击可切换展开并再次点击收起', (tester) async {
      final controller = HelpVisibilityController();
      addTearDown(controller.dispose);

      await tester.pumpWidget(_app(HelpVisibilityScope(
        controller: controller,
        child: const InfoBadge(message: '点击切换气泡测试'),
      )));

      final badgeFinder = find.byType(InfoBadge);
      expect(badgeFinder, findsOneWidget);

      // 点击展开
      await tester.tap(badgeFinder);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.text('点击切换气泡测试'), findsOneWidget);

      // 再次点击收起
      await tester.tap(badgeFinder);
      await tester.pump();
      expect(find.text('点击切换气泡测试'), findsNothing);
    });
  });
}
