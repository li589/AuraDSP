/*
 * theme_switch_regression_test.dart — 主题切换传播回归测试
 *
 * 背景（用户报告）：切换主题后主页电平显示等组件需切页再切回才应用新主题。
 * 根因：MeterPainter.shouldRepaint 只比较 value 不比较 track/fill——主题
 * 切换后父级以新 palette 重建出**新 painter 实例**（新颜色），但电平值
 * 不变，RenderCustomPaint 判定无需重绘，画布残留旧主题色，直到电平值
 * 变化（有音频时自愈）或元素重建（切页时 active 分支切换）。
 *
 * 两层证据分工：
 * 1) shouldRepaint 契约单测：直接证明「同 value + 变色」会判重绘
 *    （红→绿：把比较删掉本组立即红）。
 * 2) widget 级传播测试：证明切主题后新 painter 实例（新 palette 颜色）
 *    确实到达 CustomPaint 的 widget 字段——链路其余部分无拦截。
 *    注意：本组**观察不到画布**（widget 字段在新 painter 上本就是新的，
 *    回退修复也曾绿），画布更新由 RenderCustomPaint 调 shouldRepaint
 *    保证——框架职责，由第 1 组的契约钉死。
 *
 * 本测试不能证明：AnimatedTheme 200ms 动画中间帧的插值质量（只验终点）。
 *
 * 注：MaterialApp 内部为 AnimatedTheme（默认 200ms），pump() 不推进时间
 * 时 Theme.of 仍返回旧主题（Tween.transform(0) → begin）——切主题后必须
 * pump(>=250ms) 再断言，否则测到的是动画起点而非终点。
 */
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/home_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/ui/widgets.dart';

ThemeData _themeFor(AuraThemeId id) =>
    withAuraExtension(buildAuraTheme(id), id.palette);

void main() {
  group('MeterPainter.shouldRepaint 契约', () {
    // 电平值不变、仅主题色变化（主题切换的真实形态）也必须重绘，
    // 否则 RenderCustomPaint 跳过 markNeedsPaint，画布残留旧主题色。
    test('同 value + track/fill 变化必须判重绘', () {
      final a = MeterPainter(value: 0.5, track: const Color(0xFF111111), fill: const Color(0xFF222222));
      final b = MeterPainter(value: 0.5, track: const Color(0xFFEEEEEE), fill: const Color(0xFF222222));
      final c = MeterPainter(value: 0.5, track: const Color(0xFF111111), fill: const Color(0xFFEEEEEE));
      expect(b.shouldRepaint(a), isTrue, reason: 'track 变化未触发重绘');
      expect(c.shouldRepaint(a), isTrue, reason: 'fill 变化未触发重绘');
    });

    test('value 变化必须判重绘；全同不重绘', () {
      final a = MeterPainter(value: 0.5, track: const Color(0xFF111111), fill: const Color(0xFF222222));
      final moved = MeterPainter(value: 0.7, track: const Color(0xFF111111), fill: const Color(0xFF222222));
      final same = MeterPainter(value: 0.5, track: const Color(0xFF111111), fill: const Color(0xFF222222));
      expect(moved.shouldRepaint(a), isTrue);
      expect(same.shouldRepaint(a), isFalse);
    });
  });

  testWidgets('切换主题后 LevelMeter / label 应立即应用新 palette（无需切页）',
      (tester) async {
    final model = AppModel(testing: true);
    addTearDown(model.dispose);

    Future<void> pumpApp() async {
      await tester.pumpWidget(MaterialApp(
        theme: _themeFor(model.themeId),
        locale: model.locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        home: HomePage(model: model),
      ));
    }

    await pumpApp();
    await tester.pump();

    ({Color track, Color fill, Color label}) meterColors() {
      final meter = find.byType(LevelMeter).first;
      final cp = tester.widget<CustomPaint>(find.descendant(
        of: meter,
        matching: find.byType(CustomPaint),
      ));
      final painter = cp.painter as MeterPainter;
      final label = tester.widget<Text>(
          find.descendant(of: meter, matching: find.text('L')));
      return (
        track: painter.track,
        fill: painter.fill,
        label: label.style!.color!,
      );
    }

    // 初态：元素树与 model 主题一致（防止测试在错误的前提下通过）
    final before = meterColors();
    expect(before.track, model.themeId.palette.hairline);
    // levelL 初值 -90 → 未过载，fill 取 accent
    expect(before.fill, model.themeId.palette.accent);
    expect(before.label, model.themeId.palette.textDim);

    // 切主题：pumpWidget 后必须越过 AnimatedTheme 的 200ms 动画再断言
    model.setTheme(AuraThemeId
        .values[(model.themeId.index + 1) % AuraThemeId.values.length]);
    await pumpApp();
    await tester.pump(const Duration(milliseconds: 250));

    final after = meterColors();
    final p = model.themeId.palette;
    expect(after.track, p.hairline,
        reason: '电平表轨道色未跟随主题（应等于新 palette.hairline）');
    expect(after.fill, p.accent, reason: '电平表填充色未跟随主题');
    expect(after.label, p.textDim, reason: '电平表 label 文本色未跟随主题');

    // 反向再切一次（环绕回最初主题），防止单向通过
    model.setTheme(AuraThemeId
        .values[(model.themeId.index + 2) % AuraThemeId.values.length]);
    await pumpApp();
    await tester.pump(const Duration(milliseconds: 250));

    final back = meterColors();
    final q = model.themeId.palette;
    expect(back.track, q.hairline);
    expect(back.fill, q.accent);
    expect(back.label, q.textDim);
  });
}
