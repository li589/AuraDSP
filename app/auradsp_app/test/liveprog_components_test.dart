/*
 * liveprog_components_test.dart — Liveprog IDE 核心交互组件与弹窗 UI 测试
 */

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/liveprog/code_outline_panel.dart';
import 'package:auradsp_app/features/liveprog/eel_manual_panel.dart';
import 'package:auradsp_app/features/liveprog/equalizer_apo_dialog.dart';
import 'package:auradsp_app/features/liveprog/find_replace_bar.dart';
import 'package:auradsp_app/features/liveprog/new_script_wizard_dialog.dart';
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
  group('Liveprog IDE Components UI Tests', () {
    testWidgets('FindReplaceBar 查找、导航与单处/全部替换功能验证', (tester) async {
      tester.view.physicalSize = const Size(1000, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final ctrl = TextEditingController(text: 'gain = 1.0; spl0 *= gain; spl1 *= gain;');
      var modifiedCount = 0;

      await tester.pumpWidget(_wrap(FindReplaceBar(
        codeController: ctrl,
        onTextModified: () => modifiedCount++,
      )));
      await tester.pumpAndSettle();

      // 输入查找关键字 'gain'
      final findInput = find.byType(TextField).first;
      await tester.enterText(findInput, 'gain');
      await tester.pumpAndSettle();

      // 验证匹配数量 (3 of 3)
      expect(find.text('1 of 3'), findsOneWidget);

      // 查找下一个与上一个
      final nextBtn = find.byIcon(Icons.keyboard_arrow_down_rounded);
      await tester.tap(nextBtn);
      await tester.pumpAndSettle();
      expect(find.text('2 of 3'), findsOneWidget);

      final prevBtn = find.byIcon(Icons.keyboard_arrow_up_rounded);
      await tester.tap(prevBtn);
      await tester.pumpAndSettle();
      expect(find.text('1 of 3'), findsOneWidget);

      // 替换第一处为 'volume'
      final replaceInput = find.byType(TextField).at(1);
      await tester.enterText(replaceInput, 'volume');
      await tester.pumpAndSettle();

      final replaceBtn = find.widgetWithText(TextButton, 'Replace');
      await tester.tap(replaceBtn);
      await tester.pumpAndSettle();

      expect(ctrl.text, startsWith('volume = 1.0;'));
      expect(modifiedCount, 1);
      expect(find.text('1 of 2'), findsOneWidget);

      // 全部替换剩余的 'gain' 为 'volume'
      final replaceAllBtn = find.widgetWithText(TextButton, 'Replace All');
      await tester.tap(replaceAllBtn);
      await tester.pumpAndSettle();

      expect(ctrl.text, 'volume = 1.0; spl0 *= volume; spl1 *= volume;');
      expect(modifiedCount, 2);
    });

    test('CodeOutlinePanel 符号提取与行号解析', () {
      const code = '''slider1:1.0<0,2,0.01>Master Volume
slider2:1000<20,20000,10>Cutoff Hz

@init
function process_gain(x) instance(gain) (
  x * gain;
);
gain = slider1;

@sample
spl0 = process_gain(spl0);
spl1 = process_gain(spl1);
''';

      final outline = CodeOutlinePanel.extractOutline(code);
      expect(outline.length, 5);

      expect(outline[0].kind, OutlineKind.slider);
      expect(outline[0].label, 'slider1');
      expect(outline[0].line, 1);

      expect(outline[1].kind, OutlineKind.slider);
      expect(outline[1].label, 'slider2');
      expect(outline[1].line, 2);

      expect(outline[2].kind, OutlineKind.section);
      expect(outline[2].label, '@init');
      expect(outline[2].line, 4);

      expect(outline[3].kind, OutlineKind.function);
      expect(outline[3].label, 'process_gain');
      expect(outline[3].line, 5);

      expect(outline[4].kind, OutlineKind.section);
      expect(outline[4].label, '@sample');
      expect(outline[4].line, 10);
    });

    testWidgets('CodeOutlinePanel 列表项渲染与点击交互', (tester) async {
      tester.view.physicalSize = const Size(300, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var jumpedLine = 0;
      const code = '''@init
srate = 48000;
@sample
spl0 = spl0;
''';

      await tester.pumpWidget(_wrap(CodeOutlinePanel(
        code: code,
        activeLine: 3,
        onSelectLine: (ln) => jumpedLine = ln,
      )));
      await tester.pumpAndSettle();

      expect(find.text('@init'), findsOneWidget);
      expect(find.text('@sample'), findsOneWidget);

      await tester.tap(find.text('@init'));
      await tester.pumpAndSettle();
      expect(jumpedLine, 1);
    });

    testWidgets('EqualizerApoDialog 预设解析与即时双栏预览', (tester) async {
      tester.view.physicalSize = const Size(1000, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(const EqualizerApoDialog()));
      await tester.pumpAndSettle();

      // 验证标题与默认滤波器数量
      expect(find.text('Import EqualizerAPO Preset (.txt)'), findsOneWidget);
      expect(find.text('Detected 4 filters'), findsOneWidget);
      expect(find.text('Preamp: -4.5 dB'), findsOneWidget);

      // 验证声道互换与极性反转开关存在
      expect(find.text('Swap Channels (L ↔ R)'), findsOneWidget);
      expect(find.text('Invert Polarity (Phase 180°)'), findsOneWidget);

      // 勾选极性反转
      await tester.tap(find.text('Invert Polarity (Phase 180°)'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // 预览区域渲染了 EEL2 脚本
      expect(find.textContaining('process_biquad'), findsWidgets);
    });

    testWidgets('EelManualPanel 80+ 函数浏览、搜索过滤与展开卡片', (tester) async {
      tester.view.physicalSize = const Size(900, 700);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      String? insertedSnippet;
      await tester.pumpWidget(_wrap(SizedBox(
        width: 900,
        height: 700,
        child: EelManualPanel(
          onInsertSnippet: (snippet) => insertedSnippet = snippet,
        ),
      )));
      await tester.pumpAndSettle();

      // 检查手册总数
      expect(find.textContaining(' / '), findsWidgets);

      // 搜索 'FIRProcess'
      final searchInput = find.byType(TextField);
      await tester.enterText(searchInput, 'FIRProcess');
      await tester.pumpAndSettle();

      expect(find.text('FIRInit / FIRProcess'), findsOneWidget);

      // 点击展开卡片
      await tester.tap(find.text('FIRInit / FIRProcess'));
      await tester.pumpAndSettle();

      // 检查参数与代码插入按钮
      expect(find.text('Parameters'), findsOneWidget);
      expect(find.text('Insert into Editor'), findsOneWidget);

      await tester.tap(find.text('Insert into Editor'));
      await tester.pumpAndSettle();

      expect(insertedSnippet, isNotNull);
      expect(insertedSnippet, contains('FIRProcess'));
    });

    testWidgets('NewScriptWizardDialog 模板选择与预览切换', (tester) async {
      tester.view.physicalSize = const Size(900, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(_wrap(const NewScriptWizardDialog()));
      await tester.pumpAndSettle();

      expect(find.text('Script Templates'), findsOneWidget);
      expect(find.text('Basic Passthrough & Gain Trim'), findsWidgets);
      expect(find.text('Mid/Side Stereo Widener'), findsWidgets);

      // 切换到立体声模板
      await tester.tap(find.text('Mid/Side Stereo Widener').first);
      await tester.pumpAndSettle();

      // 预览包含 M/S 编码代码
      expect(find.textContaining('mid = (spl0 + spl1) * INV_SQRT2'), findsOneWidget);
    });
  });
}
