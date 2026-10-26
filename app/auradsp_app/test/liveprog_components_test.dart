/*
 * liveprog_components_test.dart — Liveprog IDE 核心交互组件与弹窗 UI 测试
 */

import 'package:auradsp_app/core/design.dart';
import 'package:auradsp_app/core/eel_slider_parser.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/liveprog/code_outline_panel.dart';
import 'package:auradsp_app/features/liveprog/eel_manual_panel.dart';
import 'package:auradsp_app/features/liveprog/equalizer_apo_dialog.dart';
import 'package:auradsp_app/features/liveprog/find_replace_bar.dart';
import 'package:auradsp_app/features/liveprog/new_script_wizard_dialog.dart';
import 'package:auradsp_app/features/liveprog/sliders/liveprog_sliders_panel.dart';
import 'package:auradsp_app/features/liveprog/toolbar/liveprog_ide_toolbar.dart';
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

    testWidgets('LiveprogIdeToolbar 7大按钮渲染与编译互锁验证', (tester) async {
      tester.view.physicalSize = const Size(1200, 600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      var toggleApplyCalled = false;
      var compileCalled = false;
      LiveprogFileAction? fileAction;
      LiveprogEditAction? editAction;

      // 1. 测试 isCodeDirty 为 true 时，应用按钮置灰禁用
      await tester.pumpWidget(_wrap(LiveprogIdeToolbar(
        isApplied: false,
        isCompiling: false,
        isCodeDirty: true,
        isConsoleOpen: false,
        isOutlineOpen: false,
        isFindReplaceOpen: false,
        isEditorExpanded: false,
        onToggleApply: () => toggleApplyCalled = true,
        onCompile: () => compileCalled = true,
        onFileAction: (act) => fileAction = act,
        onOpenLibrary: () {},
        onEditAction: (act) => editAction = act,
        onOpenManual: () {},
        onToggleConsole: () {},
        onToggleEditorExpand: () {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Unapplied'), findsOneWidget);
      expect(find.text('Compile'), findsOneWidget);
      expect(find.text('File'), findsOneWidget);
      expect(find.text('Script Library'), findsOneWidget);
      expect(find.text('Edit'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
      expect(find.text('Console'), findsOneWidget);

      // 点击处于禁用态的应用按钮，不应触发回调
      await tester.tap(find.text('Unapplied'), warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(toggleApplyCalled, isFalse);

      // 点击编译按钮，应触发回调
      await tester.tap(find.text('Compile'));
      await tester.pumpAndSettle();
      expect(compileCalled, isTrue);

      // 2. 测试 isCodeDirty 为 false 且已应用
      await tester.pumpWidget(_wrap(LiveprogIdeToolbar(
        isApplied: true,
        isCompiling: false,
        isCodeDirty: false,
        isConsoleOpen: false,
        isOutlineOpen: false,
        isFindReplaceOpen: false,
        isEditorExpanded: false,
        onToggleApply: () => toggleApplyCalled = true,
        onCompile: () {},
        onFileAction: (act) => fileAction = act,
        onOpenLibrary: () {},
        onEditAction: (act) => editAction = act,
        onOpenManual: () {},
        onToggleConsole: () {},
        onToggleEditorExpand: () {},
      )));
      await tester.pumpAndSettle();

      expect(find.text('Applied'), findsOneWidget);
      await tester.tap(find.text('Applied'));
      await tester.pumpAndSettle();
      expect(toggleApplyCalled, isTrue);

      // 3. 测试文件下拉菜单
      await tester.tap(find.text('File'));
      await tester.pumpAndSettle();

      expect(find.text('New Blank Script'), findsOneWidget);
      expect(find.text('New from Template...'), findsOneWidget);
      expect(find.text('Import APO Preset...'), findsOneWidget);
      expect(find.text('Import EEL Script...'), findsOneWidget);
      expect(find.text('Save As...'), findsOneWidget);

      await tester.tap(find.text('New Blank Script'));
      await tester.pumpAndSettle();
      expect(fileAction, equals(LiveprogFileAction.newBlank));

      // 4. 测试编辑下拉菜单
      await tester.tap(find.text('Edit'));
      await tester.pumpAndSettle();

      expect(find.text('Find & Replace'), findsOneWidget);
      expect(find.text('Code Outline'), findsOneWidget);
      expect(find.text('Format Code'), findsOneWidget);
      expect(find.text('Scroll to Top'), findsOneWidget);

      await tester.tap(find.text('Scroll to Top'));
      await tester.pumpAndSettle();
      expect(editAction, equals(LiveprogEditAction.scrollToTop));
    });

    testWidgets('LiveprogSlidersPanel 三类切换（脚本参数/输入通道/输出通道）与变量展示验证', (tester) async {
      tester.view.physicalSize = const Size(1000, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final model = AppModel(testing: true);
      final activeSliders = <int, EelSliderMeta>{
        1: const EelSliderMeta(
          index: 1,
          rawName: 'slider1',
          displayName: 'Octaves Down',
          defaultVal: 1.0,
          minVal: 0.0,
          maxVal: 6.0,
          step: 1.0,
          isHostSlider: true,
        ),
        101: const EelSliderMeta(
          index: 101,
          rawName: 'dBassGain',
          displayName: 'Bass strength (%)',
          defaultVal: 100.0,
          minVal: 0.0,
          maxVal: 100.0,
          step: 1.0,
          isHostSlider: false,
        ),
      };

      await tester.pumpWidget(_wrap(LiveprogSlidersPanel(
        model: model,
        activeSliders: activeSliders,
      )));
      await tester.pumpAndSettle();

      // 1. 验证 Tab 0: 脚本参数
      expect(find.text('Script Sliders'), findsOneWidget);
      expect(find.text('Input Channels (8)'), findsOneWidget);
      expect(find.text('Output Channels (8)'), findsOneWidget);

      expect(find.text('Octaves Down'), findsOneWidget);
      expect(find.text('slider1'), findsOneWidget);
      expect(find.text('Bass strength (%)'), findsOneWidget);
      expect(find.text('dBassGain = 100.0 (0.0 ~ 100.0)'), findsOneWidget);
      expect(find.text('Script Var'), findsAtLeastNWidgets(1));

      // 2. 切换到 Tab 1: 输入通道 (8)
      await tester.tap(find.text('Input Channels (8)'));
      await tester.pumpAndSettle();

      expect(find.text('Master Input Gain'), findsOneWidget);
      expect(find.text('FL'), findsOneWidget);
      expect(find.text('FR'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(find.text('LFE'), findsOneWidget);
      expect(find.text('SL'), findsOneWidget);
      expect(find.text('SR'), findsOneWidget);
      expect(find.text('BL'), findsOneWidget);
      expect(find.text('BR'), findsOneWidget);

      // 3. 切换到 Tab 2: 输出通道 (8)
      await tester.tap(find.text('Output Channels (8)'));
      await tester.pumpAndSettle();

      expect(find.text('Master Output Gain'), findsOneWidget);
      expect(find.text('FL'), findsOneWidget);
      expect(find.text('FR'), findsOneWidget);
      expect(find.text('C'), findsOneWidget);
      expect(find.text('LFE'), findsOneWidget);
      expect(find.text('SL'), findsOneWidget);
      expect(find.text('SR'), findsOneWidget);
      expect(find.text('BL'), findsOneWidget);
      expect(find.text('BR'), findsOneWidget);

      // 4. 收起面板与展开面板
      final collapseBtn = find.byTooltip('Collapse Panel');
      expect(collapseBtn, findsOneWidget);
      await tester.tap(collapseBtn);
      await tester.pumpAndSettle();

      expect(find.text('Master Output Gain'), findsNothing);

      final expandBtn = find.byTooltip('Expand Panel');
      expect(expandBtn, findsOneWidget);
      await tester.tap(expandBtn);
      await tester.pumpAndSettle();

      expect(find.text('Master Output Gain'), findsOneWidget);
    });
  });
}

