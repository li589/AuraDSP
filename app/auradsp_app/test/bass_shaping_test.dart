import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/effects_page.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, AppModel model, {AuraThemeId themeId = AuraThemeId.auraDark, Locale locale = const Locale('zh')}) =>
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      theme: withAuraExtension(buildAuraTheme(themeId), themeId.palette),
      home: Scaffold(body: child),
    );

double _luminance(Color c) {
  double channel(double v) => v <= 0.03928 ? v / 12.92 : math.pow((v + 0.055) / 1.055, 2.4).toDouble();
  return 0.2126 * channel(c.r) + 0.7152 * channel(c.g) + 0.0722 * channel(c.b);
}

double _contrastRatio(Color c1, Color c2) {
  final l1 = _luminance(c1);
  final l2 = _luminance(c2);
  final lighter = math.max(l1, l2);
  final darker = math.min(l1, l2);
  return (lighter + 0.05) / (darker + 0.05);
}

void main() {
  group('Bass Shaping 状态恢复与总开关模型', () {
    test('初始为关，总开关与两模块解耦', () {
      final model = AppModel(testing: true);
      expect(model.bassShapingOn, isFalse);
      expect(model.shelfOn, isFalse);
      expect(model.bassmonoOn, isFalse);
    });

    test('总开关开启恢复两模块（默认都开）', () {
      final model = AppModel(testing: true);
      model.setBassShapingEnabled(true);
      expect(model.bassShapingOn, isTrue);
      expect(model.shelfOn, isTrue);
      expect(model.bassmonoOn, isTrue);
    });

    test('恢复上次组合：只开 shelf 时关再开只恢复 shelf', () {
      final model = AppModel(testing: true);
      model.setBassShapingEnabled(true);
      model.setBassmonoEnabled(false);
      expect(model.shelfOn, isTrue);
      expect(model.bassmonoOn, isFalse);
      expect(model.bassShapingOn, isTrue);

      // 关闭总开关
      model.setBassShapingEnabled(false);
      expect(model.shelfOn, isFalse);
      expect(model.bassmonoOn, isFalse);
      expect(model.bassShapingOn, isFalse);

      // 再次打开总开关：恢复上次记忆（仅 shelf）
      model.setBassShapingEnabled(true);
      expect(model.shelfOn, isTrue);
      expect(model.bassmonoOn, isFalse);
      expect(model.bassShapingOn, isTrue);
    });

    test('恢复上次组合：只开 bassmono 时关再开只恢复 bassmono', () {
      final model = AppModel(testing: true);
      model.setBassShapingEnabled(true);
      model.setShelfEnabled(false);
      expect(model.shelfOn, isFalse);
      expect(model.bassmonoOn, isTrue);
      expect(model.bassShapingOn, isTrue);

      // 关闭总开关
      model.setBassShapingEnabled(false);
      expect(model.shelfOn, isFalse);
      expect(model.bassmonoOn, isFalse);
      expect(model.bassShapingOn, isFalse);

      // 再次打开总开关：恢复上次记忆（仅 bassmono）
      model.setBassShapingEnabled(true);
      expect(model.shelfOn, isFalse);
      expect(model.bassmonoOn, isTrue);
      expect(model.bassShapingOn, isTrue);
    });

    test('两个模块都手动关时总开关自动显示 off，打开时恢复两个都开', () {
      final model = AppModel(testing: true);
      model.setBassShapingEnabled(true);
      model.setShelfEnabled(false);
      model.setBassmonoEnabled(false);
      expect(model.bassShapingOn, isFalse);

      // 打开总开关：由于两个都被手动关掉，兜底恢复全开
      model.setBassShapingEnabled(true);
      expect(model.shelfOn, isTrue);
      expect(model.bassmonoOn, isTrue);
      expect(model.bassShapingOn, isTrue);
    });
  });

  group('Bass Shaping 处理节与链路阶段映射', () {
    test('isSectionEnabled 严格映射各模块与 OR 关系', () {
      final model = AppModel(testing: true);
      expect(model.isSectionEnabled('shelf'), isFalse);
      expect(model.isSectionEnabled('bassmono'), isFalse);
      expect(model.isSectionEnabled('bass_shaping'), isFalse);

      model.setShelfEnabled(true);
      expect(model.isSectionEnabled('shelf'), isTrue);
      expect(model.isSectionEnabled('bassmono'), isFalse);
      expect(model.isSectionEnabled('bass_shaping'), isTrue);

      model.setShelfEnabled(false);
      model.setBassmonoEnabled(true);
      expect(model.isSectionEnabled('shelf'), isFalse);
      expect(model.isSectionEnabled('bassmono'), isTrue);
      expect(model.isSectionEnabled('bass_shaping'), isTrue);
    });

    test('isStageEnabled 严格分离 shelf 与 bassmono（链页判定）', () {
      final model = AppModel(testing: true);
      expect(model.isStageEnabled('shelf'), isFalse);
      expect(model.isStageEnabled('bassmono'), isFalse);
      expect(model.isStageEnabled('bass_shaping'), isFalse);

      model.setShelfEnabled(true);
      expect(model.isStageEnabled('shelf'), isTrue);
      expect(model.isStageEnabled('bassmono'), isFalse);
      expect(model.isStageEnabled('bass_shaping'), isTrue);

      model.setShelfEnabled(false);
      model.setBassmonoEnabled(true);
      expect(model.isStageEnabled('shelf'), isFalse);
      expect(model.isStageEnabled('bassmono'), isTrue);
      expect(model.isStageEnabled('bass_shaping'), isTrue);
    });

    test('toggleStage 分别控制 shelf 与 bassmono', () {
      final model = AppModel(testing: true);
      model.toggleStage('shelf');
      expect(model.shelfOn, isTrue);
      expect(model.bassmonoOn, isFalse);

      model.toggleStage('bassmono');
      expect(model.shelfOn, isTrue);
      expect(model.bassmonoOn, isTrue);

      model.toggleStage('shelf');
      expect(model.shelfOn, isFalse);
      expect(model.bassmonoOn, isTrue);
    });
  });

  group('参数范围与 Clamp 校验', () {
    test('低频搁架与单声道化参数 clamp 边界', () {
      final model = AppModel(testing: true);

      // shelfFreq (40~400Hz)
      model.setShelfFreq(150.0);
      expect(model.shelfFreq, 150.0);
      model.setShelfFreq(30.0);
      expect(model.shelfFreq, 40.0);
      model.setShelfFreq(500.0);
      expect(model.shelfFreq, 400.0);

      // shelfGain (-15~+15dB)
      model.setShelfGain(6.5);
      expect(model.shelfGain, 6.5);
      model.setShelfGain(-20.0);
      expect(model.shelfGain, -15.0);
      model.setShelfGain(20.0);
      expect(model.shelfGain, 15.0);

      // bassmonoFreq (20~300Hz)
      model.setBassmonoFreq(90.0);
      expect(model.bassmonoFreq, 90.0);
      model.setBassmonoFreq(10.0);
      expect(model.bassmonoFreq, 20.0);
      model.setBassmonoFreq(350.0);
      expect(model.bassmonoFreq, 300.0);

      // bassmonoPairs (0..15)
      model.setBassmonoPairs(5);
      expect(model.bassmonoPairs, 5);
      model.setBassmonoPairs(-1);
      expect(model.bassmonoPairs, 0);
      model.setBassmonoPairs(16);
      expect(model.bassmonoPairs, 15);

      // bassmonoMerge (0..1)
      model.setBassmonoMerge(1);
      expect(model.bassmonoMerge, 1);
      model.setBassmonoMerge(-1);
      expect(model.bassmonoMerge, 0);
      model.setBassmonoMerge(2);
      expect(model.bassmonoMerge, 1);
    });
  });

  group('UI 组件结构与交互验证', () {
    testWidgets('渲染两个独立模块：低频搁架与低频单声道化', (tester) async {
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      model.setBassShapingEnabled(true);

      await tester.pumpWidget(_wrap(EffectsPage(model: model), model));
      await tester.pumpAndSettle();

      expect(find.text('低音塑形'), findsOneWidget);
      expect(find.text('低频搁架'), findsOneWidget);
      expect(find.text('低频单声道化'), findsOneWidget);

      // 4 个声道对 Chip 存在
      expect(find.text('FL/FR'), findsOneWidget);
      expect(find.text('C/LFE'), findsOneWidget);
      expect(find.text('SL/SR'), findsOneWidget);
      expect(find.text('BL/BR'), findsOneWidget);
    });

    testWidgets('警告横幅诚实性：pairs=0 与 C/LFE 选中警告', (tester) async {
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      model.setBassShapingEnabled(true);
      model.vizChannelCount.value = 8;
      model.channelsMode = 1;

      // 1. pairs = 0 警告
      model.setBassmonoPairs(0);
      await tester.pumpWidget(_wrap(EffectsPage(model: model), model));
      await tester.pumpAndSettle();
      expect(find.text('未选择声道对 · 当前不处理'), findsOneWidget);

      // 2. 选中 C/LFE (bit 1) 触发分离减弱警告
      model.setBassmonoPairs(0x03); // FL/FR + C/LFE
      await tester.pumpWidget(_wrap(EffectsPage(model: model), model));
      await tester.pumpAndSettle();
      expect(find.textContaining('C/LFE 取平均会削弱中置与超低音的分离'), findsOneWidget);

      // 3. 取消 C/LFE 选中后警告消失
      model.setBassmonoPairs(0x01); // 仅 FL/FR
      await tester.pumpWidget(_wrap(EffectsPage(model: model), model));
      await tester.pumpAndSettle();
      expect(find.textContaining('C/LFE 取平均会削弱中置与超低音的分离'), findsNothing);
    });

    testWidgets('4ch Quad 布局：C/LFE 和 SL/SR 禁用不可点击，BL/BR 映射可用', (tester) async {
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      model.setBassShapingEnabled(true);
      model.vizChannelCount.value = 4;
      model.channelsMode = 1;
      model.setBassmonoPairs(0x01); // 仅 FL/FR

      await tester.pumpWidget(_wrap(EffectsPage(model: model), model));
      await tester.pumpAndSettle();

      // 点击不可用的 C/LFE chip，不改变掩码
      final clfeChip = find.text('C/LFE');
      await tester.tap(clfeChip);
      await tester.pumpAndSettle();
      expect(model.bassmonoPairs, 0x01); // 仍为 0x01，无修改

      // 点击可用的 BL/BR chip，成功置位 bit 3
      final blbrChip = find.text('BL/BR');
      await tester.tap(blbrChip);
      await tester.pumpAndSettle();
      expect(model.bassmonoPairs, 0x09); // 0x01 | 0x08 = 0x09
    });

    testWidgets('响应式无溢出断言：360, 480, 720 宽度', (tester) async {
      for (final width in [360.0, 480.0, 720.0]) {
        tester.view.physicalSize = Size(width, 1600.0);
        tester.view.devicePixelRatio = 1.0;

        final model = AppModel(testing: true);
        model.setBassShapingEnabled(true);
        model.vizChannelCount.value = 8;
        model.channelsMode = 1;

        await tester.pumpWidget(_wrap(BassShapingCard(model: model), model));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: 'Width $width caused an exception or overflow');
      }
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    testWidgets('三主题视觉渲染与对比度断言', (tester) async {
      tester.view.physicalSize = const Size(1280, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      for (final themeId in AuraThemeId.values) {
        final model = AppModel(testing: true);
        model.setBassShapingEnabled(true);
        model.vizChannelCount.value = 8;
        model.channelsMode = 1;

        await tester.pumpWidget(_wrap(EffectsPage(model: model), model, themeId: themeId));
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull, reason: '${themeId.name} failed to render cleanly');

        final p = themeId.palette;
        // 验证浅色主题或高对比主题下选中色及文字对比度
        final chipBg = Color.alphaBlend(p.accent.withValues(alpha: 0.16), p.panelRaised);
        final ratio = _contrastRatio(p.text, chipBg);
        expect(ratio >= 3.0, isTrue, reason: '${themeId.name} contrast ratio $ratio < 3.0');
      }
    });
  });

  group('l10n 完整性与多语言测试', () {
    test('§3.9.8 全部 21 个 l10n 键在 zh, en, ja 中齐全', () {
      final keys = [
        'bassShapingMasterHint',
        'bassShelfModule',
        'bassMonoModule',
        'bassMonoDesc',
        'bassMonoPairs',
        'bassMonoPairCount',
        'bassMonoPairFront',
        'bassMonoPairCenterLfe',
        'bassMonoPairSide',
        'bassMonoPairBack',
        'bassMonoPairAll',
        'bassMonoPairFrontOnly',
        'bassMonoPairUnavailable',
        'bassMonoMerge',
        'bassMonoMergePerPair',
        'bassMonoMergeGlobal',
        'bassMonoMergeSinglePairHint',
        'bassMonoNoneSelected',
        'bassMonoIgnoredPairs',
        'bassMonoLfeWarning',
        'bassMonoStereoPathHint',
      ];

      for (final lang in ['zh', 'en', 'ja']) {
        final file = File('lib/l10n/app_$lang.arb');
        expect(file.existsSync(), isTrue, reason: 'File lib/l10n/app_$lang.arb missing');
        final json = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;

        for (final k in keys) {
          expect(json.containsKey(k), isTrue, reason: 'Key $k missing in app_$lang.arb');
        }

        // 验证 placeholder count: int
        expect(json.containsKey('@bassMonoPairCount'), isTrue);
        expect(json.containsKey('@bassMonoIgnoredPairs'), isTrue);
      }
    });
  });
}
