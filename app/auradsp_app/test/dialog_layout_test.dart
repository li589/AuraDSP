// dialog_layout_test.dart — 浮层统一约束回归（2026-11-20 窄屏 P2）
//
// 覆盖：
// - 360/700/1200 三档下，AuraDialogConstraints 的设计上限与视口取小；
// - 键盘 viewInsets 顶起时高度收缩，避免按钮被推出视口；
// - auraDialogInset 在 600 断点切换 12 / 40+24。
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/liveprog/eel_manual_panel.dart';
import 'package:auradsp_app/features/liveprog/library/liveprog_library_dialog.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/ui/aura_dialog.dart';
import 'package:auradsp_app/ui/path_picker_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _app({double maxWidth = 780, double maxHeight = 600}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: AuraDialogConstraints(
        maxWidth: maxWidth,
        maxHeight: maxHeight,
        child: const SizedBox(
          key: ValueKey<String>('dialog.content'),
          width: double.infinity,
          height: double.infinity,
        ),
      ),
    ),
  ),
);

Future<Size> _pumpAt(WidgetTester tester, double width) async {
  tester.view.physicalSize = Size(width, 800);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(_app());
  return tester.getSize(find.byKey(const ValueKey<String>('dialog.content')));
}

Widget _dialogHost() => MaterialApp(
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  locale: const Locale('zh'),
  theme: withAuraExtension(ThemeData.dark(), auraDark),
  home: Builder(
    builder: (ctx) => Scaffold(
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ElevatedButton(
              key: const ValueKey<String>('open.eel'),
              onPressed: () => EelManualDialog.show(ctx),
              child: const Text('eel'),
            ),
            ElevatedButton(
              key: const ValueKey<String>('open.path'),
              onPressed: () => AuraPathPickerDialog.show(
                ctx,
                title: '选择目录',
                mode: ResourcePickMode.directory,
              ),
              child: const Text('path'),
            ),
          ],
        ),
      ),
    ),
  ),
);

void main() {
  group('AuraDialogConstraints', () {
    testWidgets('360 收窄到 336×600，700 收到 620×600，1200 保持 780×600', (
      tester,
    ) async {
      expect(await _pumpAt(tester, 360), const Size(336, 600));
      expect(await _pumpAt(tester, 700), const Size(620, 600));
      expect(await _pumpAt(tester, 1200), const Size(780, 600));
    });

    testWidgets('键盘顶起时按 viewInsets 收缩高度', (tester) async {
      // 直接在 Scaffold body 里测会被 resizeToAvoidBottomInset 先行压到 500，
      // 测不到公式；这里用嵌套 MediaQuery 模拟浮层所在的全屏 Overlay 环境。
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 800),
              viewInsets: EdgeInsets.only(bottom: 300),
            ),
            child: Center(
              child: AuraDialogConstraints(
                maxWidth: 780,
                maxHeight: 700,
                child: const SizedBox(
                  key: ValueKey<String>('dialog.content'),
                  width: double.infinity,
                  height: double.infinity,
                ),
              ),
            ),
          ),
        ),
      );
      final size = tester.getSize(
        find.byKey(const ValueKey<String>('dialog.content')),
      );
      // 800 - 300 - 24(inset vertical) = 476
      expect(size.height, 476);
    });

    testWidgets('auraDialogInset 在 600 断点切换', (tester) async {
      tester.view.physicalSize = const Size(599, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      late EdgeInsets compact;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              compact = auraDialogInset(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(compact, const EdgeInsets.all(12));

      tester.view.physicalSize = const Size(600, 800);
      late EdgeInsets desktop;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (ctx) {
              desktop = auraDialogInset(ctx);
              return const SizedBox();
            },
          ),
        ),
      );
      expect(desktop, const EdgeInsets.symmetric(horizontal: 40, vertical: 24));
    });

    testWidgets('EEL 手册在 360 下不超视口且无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_dialogHost());
      await tester.tap(find.byKey(const ValueKey<String>('open.eel')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(EelManualPanel));
      expect(rect.width, lessThanOrEqualTo(360));
      expect(rect.height, lessThanOrEqualTo(800));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
    });

    testWidgets('路径选择在 360 下不超视口且无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_dialogHost());
      await tester.tap(find.byKey(const ValueKey<String>('open.path')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(AuraPathPickerDialog));
      expect(rect.width, lessThanOrEqualTo(360));
      expect(rect.height, lessThanOrEqualTo(800));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
    });

    testWidgets('脚本库在 360 下不超视口且无溢出', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          theme: withAuraExtension(ThemeData.dark(), auraDark),
          home: Builder(
            builder: (ctx) => Scaffold(
              body: Center(
                child: ElevatedButton(
                  key: const ValueKey<String>('open.lib'),
                  onPressed: () => LiveprogLibraryDialog.show(
                    ctx,
                    model: model,
                    currentCode: '',
                    isCodeDirty: false,
                    onSelectScript: (_, _) {},
                  ),
                  child: const Text('lib'),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(const ValueKey<String>('open.lib')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));

      expect(tester.takeException(), isNull);
      final rect = tester.getRect(find.byType(LiveprogLibraryDialog));
      expect(rect.width, lessThanOrEqualTo(360));
      expect(rect.height, lessThanOrEqualTo(800));
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
    });
  });
}
