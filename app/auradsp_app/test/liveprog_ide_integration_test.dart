/*
 * liveprog_ide_integration_test.dart — Liveprog IDE 整体集成与桌面交互端到端测试
 *
 * 验证：
 * 1. LiveprogPage 完整 IDE 工具栏渲染（向导、APO 预设导入、查找替换、代码大纲、参考手册、控制台）
 * 2. 查找替换浮条呼出、关键字匹配与关闭交互
 * 3. 代码大纲抽屉呼出、符号大纲提取与点击定位交互
 * 4. 控制台诊断面板呼出、VM 状态与滑块绑定呈现
 * 5. 新建向导模板挑选并一键替换编辑器
 * 6. EqualizerAPO 预设导入弹窗并转换写入编辑器
 * 7. 80+ EEL2 函数参考手册弹窗模糊搜索并一键插入光标代码
 */

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/liveprog/code_outline_panel.dart';
import 'package:auradsp_app/features/liveprog/eel_manual_panel.dart';
import 'package:auradsp_app/features/liveprog/equalizer_apo_dialog.dart';
import 'package:auradsp_app/features/liveprog/find_replace_bar.dart';
import 'package:auradsp_app/features/liveprog/new_script_wizard_dialog.dart';
import 'package:auradsp_app/features/liveprog_page.dart';
import 'package:auradsp_app/features/chrome.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: locale,
      theme: withAuraExtension(ThemeData.dark(), auraDark),
      home: Scaffold(body: child),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Liveprog IDE Integration UI Tests', () {
    testWidgets('LiveprogPage 工具栏渲染全部专业 IDE 交互组件按钮', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 验证工具栏全部 IDE 按钮存在
      expect(find.text('Apply & compile'), findsOneWidget);
      expect(find.text('Unload'), findsOneWidget);
      expect(find.text('Script Wizard'), findsOneWidget);
      expect(find.text('Import APO TXT'), findsOneWidget);
      expect(find.text('Find & Replace'), findsOneWidget);
      expect(find.text('Code Outline'), findsOneWidget);
      expect(find.text('Format'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
      expect(find.text('Console & Diagnostics'), findsOneWidget);

      // 验证初始状态：大纲、查找替换与控制台未展开
      expect(find.byType(FindReplaceBar), findsNothing);
      expect(find.byType(CodeOutlinePanel), findsNothing);
    });

    testWidgets('查找替换 (Find & Replace) 工具条切换与交互', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 点击查找替换按钮
      final findBtn = find.text('Find & Replace');
      await tester.tap(findBtn);
      await tester.pumpAndSettle();

      // 验证 FindReplaceBar 出现
      expect(find.byType(FindReplaceBar), findsOneWidget);

      // 关闭查找替换
      final closeBtn = find.descendant(
        of: find.byType(FindReplaceBar),
        matching: find.byIcon(Icons.close_rounded),
      );
      await tester.tap(closeBtn);
      await tester.pumpAndSettle();

      // 验证 FindReplaceBar 消失
      expect(find.byType(FindReplaceBar), findsNothing);
    });

    testWidgets('代码大纲 (Code Outline) 侧边面板切换与符号提取', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 点击代码大纲按钮（精准匹配工具栏 Chip）
      final outlineBtn = find.widgetWithText(AuraChip, 'Code Outline');
      await tester.tap(outlineBtn);
      await tester.pumpAndSettle();

      // 验证 CodeOutlinePanel 展开并在分栏中渲染
      expect(find.byType(CodeOutlinePanel), findsOneWidget);
      expect(find.text('@init'), findsOneWidget);
      expect(find.text('@sample'), findsOneWidget);

      // 再次点击代码大纲按钮关闭
      await tester.tap(outlineBtn);
      await tester.pumpAndSettle();
      expect(find.byType(CodeOutlinePanel), findsNothing);
    });

    testWidgets('控制台与诊断输出 (Console & Diagnostics) 面板切换与 VM 状态', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 点击控制台按钮（精准匹配工具栏 Chip）
      final consoleBtn = find.widgetWithText(AuraChip, 'Console & Diagnostics');
      await tester.tap(consoleBtn);
      await tester.pumpAndSettle();

      // 验证控制台展开并显示 VM 信息与就绪提示
      expect(find.textContaining('VM: EEL2/NSEEL'), findsOneWidget);
      expect(find.textContaining('Script compiled successfully'), findsOneWidget);

      // 再次点击关闭控制台
      await tester.tap(consoleBtn);
      await tester.pumpAndSettle();
      expect(find.textContaining('VM: EEL2/NSEEL'), findsNothing);
    });

    testWidgets('新建向导 (Script Wizard) 弹窗选择并填入模板代码', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 点击新建向导按钮
      await tester.tap(find.text('Script Wizard'));
      await tester.pumpAndSettle();

      // 验证向导弹窗打开
      expect(find.byType(NewScriptWizardDialog), findsOneWidget);
      expect(find.text('Basic Passthrough & Gain Trim'), findsWidgets);

      // 点击确定使用模板
      await tester.tap(find.text('Use Template'));
      await tester.pumpAndSettle();

      // 验证弹窗关闭且编辑器代码与自适应滑块均包含对应模板内容
      expect(find.byType(NewScriptWizardDialog), findsNothing);
      expect(find.textContaining('Master Trim (dB)'), findsWidgets);
    });

    testWidgets('EqualizerAPO 预设导入弹窗交互', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 点击导入 APO 预设按钮
      await tester.tap(find.text('Import APO TXT'));
      await tester.pumpAndSettle();

      // 验证对话框出现
      expect(find.byType(EqualizerApoDialog), findsOneWidget);
      expect(find.text('Import EqualizerAPO Preset (.txt)'), findsOneWidget);

      // 点击应用导入到编辑器
      await tester.tap(find.text('Load into Editor'));
      await tester.pumpAndSettle();

      // 对话框关闭，且编辑器包含 RBJ 转换生成的 EEL2 代码
      expect(find.byType(EqualizerApoDialog), findsNothing);
      expect(find.textContaining('Generated by AuraDSP EqualizerAPO Converter'), findsOneWidget);
    });

    testWidgets('参考手册 (Reference Manual) 弹窗搜索并一键插入代码片段', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 点击参考手册按钮
      await tester.tap(find.text('Manual'));
      await tester.pumpAndSettle();

      // 验证手册面板出现
      expect(find.byType(EelManualPanel), findsOneWidget);

      // 搜索 FIRProcess
      final searchInput = find.descendant(
        of: find.byType(EelManualPanel),
        matching: find.byType(TextField),
      );
      await tester.enterText(searchInput, 'FIRProcess');
      await tester.pumpAndSettle();

      // 点击展开卡片
      await tester.tap(find.text('FIRInit / FIRProcess'));
      await tester.pumpAndSettle();

      // 检查插入按钮并点击
      final insertBtn = find.text('Insert into Editor');
      expect(insertBtn, findsOneWidget);
      await tester.tap(insertBtn);
      await tester.pumpAndSettle();

      // 手册弹窗已关闭，代码中已包含 FIRProcess
      expect(find.byType(EelManualPanel), findsNothing);
      expect(find.textContaining('FIRProcess'), findsWidgets);
    });
  });
}
