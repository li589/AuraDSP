/*
 * liveprog_ide_integration_test.dart — Liveprog IDE 整体集成与桌面交互端到端测试
 *
 * 验证（V2 规范）：
 * 1. LiveprogPage 完整 IDE 界面呈现（眉题、EEL2编辑器标题、7大核心操作区工具栏、底部内嵌滑块面板）
 * 2. 查找替换 (Find & Replace) 下拉菜单与交互
 * 3. 代码大纲 (Code Outline) 侧边面板切换与符号提取
 * 4. 控制台诊断面板呼出、VM 状态与滑块绑定呈现
 * 5. 新建向导模板从 File 下拉菜单挑选并一键替换编辑器
 * 6. EqualizerAPO 预设从 File 下拉菜单导入并转换写入编辑器
 * 7. EEL2 函数参考手册弹窗模糊搜索并一键插入光标代码
 * 8. IDE 快捷键与编辑器尺寸切换与控制台清屏与未保存防丢
 * 9. 编译与应用状态互锁机制（代码未编译强制禁止应用）
 * 10. 独立脚本库弹窗打开与关闭交互
 * 11. 编辑菜单跳回开头交互
 */

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/liveprog/code_outline_panel.dart';
import 'package:auradsp_app/features/liveprog/eel_manual_panel.dart';
import 'package:auradsp_app/features/liveprog/equalizer_apo_dialog.dart';
import 'package:auradsp_app/features/liveprog/find_replace_bar.dart';
import 'package:auradsp_app/features/liveprog/library/liveprog_library_dialog.dart';
import 'package:auradsp_app/features/liveprog/new_script_wizard_dialog.dart';
import 'package:auradsp_app/features/liveprog_page.dart';
import 'package:auradsp_app/features/chrome.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    testWidgets('LiveprogPage 工具栏与视角布局渲染全部专业 IDE 交互组件', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 验证页面顶部标题与眉题（V2 规范：可编程DSP替换实时编程，主标题更名 EEL2 编辑器）
      expect(find.text('Programmable DSP'), findsOneWidget);
      expect(find.text('EEL2 Editor'), findsOneWidget);

      // 验证工具栏 7 大核心操作区按钮存在
      expect(find.text('Unapplied'), findsOneWidget);
      expect(find.text('Compile'), findsOneWidget);
      expect(find.text('File'), findsOneWidget);
      expect(find.text('Script Library'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
      expect(find.text('Console'), findsOneWidget);
      expect(find.text('Expand'), findsOneWidget);

      // 验证编辑器底部内嵌的参数滑块面板
      expect(find.text('Script Sliders'), findsOneWidget);

      // 验证初始状态：大纲、查找替换与控制台未展开
      expect(find.byType(FindReplaceBar), findsNothing);
      expect(find.byType(CodeOutlinePanel), findsNothing);
    });

    testWidgets('查找替换 (Find & Replace) 下拉菜单与交互', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 从 Edit 菜单中点击 Find & Replace
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Find & Replace'));
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

      // 从 Edit 菜单中点击 Code Outline
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Code Outline'));
      await tester.pumpAndSettle();

      // 验证 CodeOutlinePanel 展开并在分栏中渲染
      expect(find.byType(CodeOutlinePanel), findsOneWidget);
      expect(find.text('@init'), findsOneWidget);
      expect(find.text('@sample'), findsOneWidget);

      // 再次从 Edit 菜单中点击 Code Outline 关闭
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Code Outline').last);
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

      // 点击控制台按钮
      final consoleBtn = find.widgetWithText(AuraChip, 'Console');
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

    testWidgets('新建向导 (Script Wizard) 从文件菜单打开并填入模板代码', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 从 File 下拉菜单中点击 New from Template...
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('New from Template...'));
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

      // 从 File 下拉菜单中点击 Import APO Preset...
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Import APO Preset...'));
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
      await tester.tap(find.widgetWithText(AuraChip, 'Manual'));
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

    testWidgets('IDE 快捷键与编辑器尺寸切换与控制台清屏与未保存防丢', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 1. 切换编辑器尺寸
      expect(find.text('Expand'), findsOneWidget);
      await tester.tap(find.text('Expand'));
      await tester.pumpAndSettle();
      expect(find.text('Collapse'), findsOneWidget);
      await tester.tap(find.text('Collapse'));
      await tester.pumpAndSettle();
      expect(find.text('Expand'), findsOneWidget);

      // 2. 聚焦编辑器并按 Ctrl+F 快捷键打开查找替换工具条
      final editor = find.byType(TextField).first;
      await tester.tap(editor);
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyF);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(find.byType(FindReplaceBar), findsOneWidget);

      // 3. 在查找框中按 Escape 键关闭查找替换工具条
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(FindReplaceBar), findsNothing);

      // 4. 打开控制台并测试清屏
      await tester.tap(find.widgetWithText(AuraChip, 'Console'));
      await tester.pumpAndSettle();
      expect(find.textContaining('VM: EEL2/NSEEL'), findsOneWidget);

      final clearBtn = find.byTooltip('Clear Output');
      expect(clearBtn, findsOneWidget);
      await tester.tap(clearBtn);
      await tester.pumpAndSettle();
      expect(find.text('> Output cleared.'), findsOneWidget);

      // 5. 修改代码后触发向导，验证未保存防丢弹窗
      await tester.enterText(editor, 'slider1:1<0,1>CustomMod\n@init\nx=1;\n@sample\n');
      await tester.pumpAndSettle();

      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New from Template...'));
      await tester.pumpAndSettle();

      // 弹出防丢弹窗
      expect(find.text('Discard Changes?'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);

      // 取消放弃，向导不打开
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('Discard Changes?'), findsNothing);
      expect(find.byType(NewScriptWizardDialog), findsNothing);

      // 再次点击向导并选择“Discard & Load”
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('New from Template...'));
      await tester.pumpAndSettle();

      expect(find.text('Discard & Load'), findsOneWidget);
      await tester.tap(find.text('Discard & Load'));
      await tester.pumpAndSettle();

      // 向导弹窗成功打开
      expect(find.byType(NewScriptWizardDialog), findsOneWidget);
    });

    testWidgets('编译与应用状态互锁机制 (Compile & Apply Interlock)', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 初始未编译时：应用按钮显示 Unapplied 且置灰禁用
      expect(find.text('Unapplied'), findsOneWidget);
      expect(model.lpEnabled, isFalse);

      // 点击未编译的应用按钮，因 IgnorePointer 事件被拦截，不改变状态
      await tester.tap(find.text('Unapplied'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(model.lpEnabled, isFalse);

      // 点击编译按钮
      await tester.tap(find.text('Compile'));
      await tester.pump();
      // 模拟引擎编译完成
      model.lpStatus = 1;
      model.notifyListeners();
      await tester.pumpAndSettle();

      // 编译成功后，应用按钮解锁，点击可切换为 Applied
      await tester.tap(find.text('Unapplied'));
      await tester.pumpAndSettle();
      expect(model.lpEnabled, isTrue);
      expect(find.text('Applied'), findsOneWidget);

      // 用户再次编辑代码
      final editor = find.byType(TextField).first;
      await tester.enterText(editor, '// Modified after compile\nspl0 = spl0;\n');
      await tester.pumpAndSettle();

      // 代码已脏，但如果当前已处于应用状态，允许点击关闭（unapply）
      await tester.tap(find.text('Applied'));
      await tester.pumpAndSettle();
      expect(model.lpEnabled, isFalse);
      expect(find.text('Unapplied'), findsOneWidget);
    });

    testWidgets('脚本库 (Script Library) 独立弹窗打开与关闭交互', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 点击 Script Library 按钮
      await tester.tap(find.widgetWithText(AuraChip, 'Script Library'));
      await tester.pumpAndSettle();

      // 验证脚本库弹窗打开
      expect(find.byType(LiveprogLibraryDialog), findsOneWidget);
      expect(find.text('EEL2 Script Library & Directory Manager'), findsOneWidget);

      // 点击右上角关闭按钮
      final closeBtn = find.descendant(
        of: find.byType(LiveprogLibraryDialog),
        matching: find.byIcon(Icons.close_rounded),
      );
      await tester.tap(closeBtn);
      await tester.pumpAndSettle();

      // 验证弹窗关闭
      expect(find.byType(LiveprogLibraryDialog), findsNothing);
    });

    testWidgets('编辑菜单：跳回开头 (Scroll to Top) 交互', (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      await tester.pumpWidget(_wrap(LiveprogPage(model: model)));
      await tester.pumpAndSettle();

      // 输入多行代码
      final editor = find.byType(TextField).first;
      await tester.enterText(editor, 'Line 1\nLine 2\nLine 3\nLine 4\nLine 5\n');
      await tester.pumpAndSettle();

      // 点击 Edit -> Scroll to Top
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Scroll to Top'));
      await tester.pumpAndSettle();

      // 验证光标移动至开头 (offset 0)
      final editableText = tester.widget<EditableText>(find.byType(EditableText).first);
      expect(editableText.controller.selection.baseOffset, equals(0));
    });
  });
}
