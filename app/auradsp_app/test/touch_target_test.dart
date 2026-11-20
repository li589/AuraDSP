// touch_target_test.dart — R7 触控目标回归（2026-11-20 窄屏立项 R7）
//
// 规范：孤立图标 48×48（Material）；行内控件 44（Apple HIG）。指针环境保持
// 设计尺寸不变。覆盖：InfoBadge、顶栏图标、底部导航、chip/分段/开关/下拉。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/nav.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/core/ui_helpers.dart';
import 'package:auradsp_app/features/shell.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/ui/chrome.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 行内控件同屏：chip / 分段 / 开关 / 下拉，一次测量四种命中盒。
Widget _inlineControlsApp() => MaterialApp(
  theme: withAuraExtension(ThemeData.dark(), auraDark),
  home: AuraInputScope(
    child: Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AuraChip('旁路', selected: true, onTap: () {}),
            AuraSegmented<int>(
              segments: const [AuraSegment(0, 'A'), AuraSegment(1, 'B')],
              selected: 0,
              onChanged: (_) {},
            ),
            AuraSwitch(value: true, onChanged: (_) {}),
            AuraDropdown<int>(
              value: 0,
              items: const [
                DropdownMenuItem(value: 0, child: Text('0')),
                DropdownMenuItem(value: 1, child: Text('1')),
              ],
              onChanged: (_) {},
            ),
          ],
        ),
      ),
    ),
  ),
);

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
  // 控件的尺寸切换可能是 AnimatedContainer 过渡：等它走完再测量。
  await tester.pump(const Duration(milliseconds: 300));
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

    testWidgets('行内控件：指针保持设计尺寸，触屏抬到 44', (tester) async {
      await tester.pumpWidget(_inlineControlsApp());
      await tester.pump();

      final targets = <({String name, Finder finder, double pointerH})>[
        (
          name: 'AuraChip',
          finder: find.byType(AuraChip),
          pointerH: AuraSize.chipH,
        ),
        (
          name: 'AuraSegmented',
          finder: find.byType(AuraSegmented<int>),
          pointerH: 38,
        ),
        (name: 'AuraSwitch', finder: find.byType(AuraSwitch), pointerH: 40),
        (
          name: 'AuraDropdown',
          finder: find.byType(AuraDropdown<int>),
          pointerH: 32,
        ),
      ];

      // 先切到指针语义（测试默认平台是 android，首帧即触屏）。
      await _probeWith(
        tester,
        tester.getCenter(find.byType(AuraChip)),
        PointerDeviceKind.mouse,
      );
      for (final t in targets) {
        expect(
          tester.getSize(t.finder).height,
          closeTo(t.pointerH, 0.01),
          reason: '${t.name} 指针环境应保持设计高度',
        );
      }

      await _probeWith(
        tester,
        tester.getCenter(find.byType(AuraChip)),
        PointerDeviceKind.touch,
      );
      for (final t in targets) {
        expect(
          tester.getSize(t.finder).height,
          greaterThanOrEqualTo(AuraTouchTargets.min),
          reason: '${t.name} 触屏命中高度应 ≥44',
        );
      }
    });
  });
}
