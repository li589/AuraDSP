// touch_target_test.dart — R7 触控目标回归（2026-11-20 窄屏立项 R7）
//
// 规范：触屏命中区 ≥48×48（Material 最小触控目标）；指针保持紧凑视觉尺寸。
// 覆盖：InfoBadge（指针 23 / 触屏 48）、顶栏图标动作（指针 32 / 触屏 48）、
// 底部导航六项（每项 ≥48 宽）。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/nav.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/core/ui_helpers.dart';
import 'package:auradsp_app/features/shell.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _badgeApp() {
  final controller = HelpVisibilityController();
  return MaterialApp(
    theme: withAuraExtension(ThemeData.dark(), auraDark),
    home: AuraInputScope(
      child: HelpVisibilityScope(
        controller: controller,
        child: const Scaffold(
          body: Center(child: InfoBadge(message: '提示')),
        ),
      ),
    ),
  );
}

Widget _shellApp(AppModel model) => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('en'),
  theme: withAuraExtension(ThemeData.dark(), auraDark),
  // 生产环境 scope 装在 MaterialApp.builder；测试里包住 home 同样覆盖外壳。
  home: AuraInputScope(child: AppShell(model: model)),
);

/// 在 [at] 处按一次指定设备类型的指针并取消（只切换输入语义，不触发点击）。
/// 注意：widget 测试默认平台是 android，`AuraInputScope` 首帧即触屏语义，
/// 所以断言顺序固定为「先鼠标 → 再触屏」。
Future<void> _probeWith(
  WidgetTester tester,
  Offset at,
  PointerDeviceKind kind,
) async {
  final g = await tester.startGesture(at, kind: kind);
  await tester.pump();
  await g.cancel();
  await tester.pump();
}

void main() {
  group('R7 触控目标', () {
    testWidgets('InfoBadge：指针 23，触屏 48', (tester) async {
      await tester.pumpWidget(_badgeApp());
      await tester.pump();

      final center = tester.getCenter(find.byType(InfoBadge));
      await _probeWith(tester, center, PointerDeviceKind.mouse);

      expect(
        tester.getSize(find.byType(InfoBadge)).width,
        closeTo(23, 0.01),
        reason: '指针环境维持 15 + 4×2 的紧凑外衬',
      );

      await _probeWith(tester, center, PointerDeviceKind.touch);

      final size = tester.getSize(find.byType(InfoBadge));
      expect(size.width, closeTo(48, 0.01), reason: '触屏命中区应达 48');
      expect(size.height, closeTo(48, 0.01));
    });

    testWidgets('顶栏图标动作：指针 32，触屏 48', (tester) async {
      tester.view.physicalSize = const Size(1200, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_shellApp(model));
      await tester.pump();

      final settings = find.byKey(
        const ValueKey<String>('shell.topAction.settings'),
      );
      final center = tester.getCenter(settings);
      await _probeWith(tester, center, PointerDeviceKind.mouse);
      expect(tester.getSize(settings).width, closeTo(32, 0.01));

      await _probeWith(tester, center, PointerDeviceKind.touch);

      final size = tester.getSize(settings);
      expect(size.width, closeTo(48, 0.01), reason: '触屏命中区应达 48');
      expect(size.height, closeTo(48, 0.01));
    });

    testWidgets('底栏六项每项命中区 ≥48×48', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(_shellApp(model));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      for (var i = 0; i < AppPage.values.length; i++) {
        final size = tester.getSize(
          find.byKey(ValueKey<String>('shell.nav.$i')),
        );
        expect(size.width, greaterThanOrEqualTo(48), reason: '底栏第 $i 项过窄');
        expect(size.height, greaterThanOrEqualTo(48), reason: '底栏第 $i 项过矮');
      }
    });
  });
}
