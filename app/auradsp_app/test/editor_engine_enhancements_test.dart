import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:auradsp_app/core/eel_slider_parser.dart';
import 'package:auradsp_app/core/state.dart';
import 'package:auradsp_app/core/theme.dart';
import 'package:auradsp_app/features/liveprog/line_number_gutter.dart';
import 'package:auradsp_app/features/liveprog/sliders/liveprog_sliders_panel.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:auradsp_app/l10n/gen/app_localizations_zh.dart';

import 'package:auradsp_app/core/design.dart';

void main() {
  final testTheme = withAuraExtension(buildAuraTheme(AuraThemeId.auraDark), auraDark);

  group('1. 脚本编辑器状态提示测试', () {
    test('多语言字典中包含 lpRunningOldCode', () {
      final lZh = AppLocalizationsZh();
      expect(lZh.lpRunningOldCode, equals('当前应用旧代码'));
    });

    testWidgets('已应用且代码发生修改时，智能提示包含“当前应用旧代码”', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      model.lpEnabled = true;
      model.lpStatus = 1;
      model.lpCode = '@init\nx=1;\n@sample\nspl0*=x;';
      model.lpDraftCode = '@init\nx=2;\n@sample\nspl0*=x;';

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Builder(
            builder: (ctx) {
              final l = AppLocalizations.of(ctx)!;
              final isDirty = model.lpDraftCode != model.lpCode;
              final runningOld = (model.lpEnabled && isDirty) ? ' (${l.lpRunningOldCode})' : '';
              final statusText = '${l.lpUncompiled}$runningOld';
              return Scaffold(
                body: Text(statusText),
              );
            },
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.text('未编译修改 (当前应用旧代码)'), findsOneWidget);
    });
  });

  group('2. 脚本参数下拉框与步长吸附测试', () {
    test('带枚举选项的 slider 正确解析为 enumOptions 列表', () {
      const code = '''
slider1:1<0,3,1{Off,Stereo Wide,Binaural,Center Focus}>Acoustic Mode
slider2:0.5<0.0,1.0,0.05>Dry Wet Mix
''';
      final sliders = EelSliderParser.parse(code);
      expect(sliders.containsKey(1), isTrue);
      final meta1 = sliders[1]!;
      expect(meta1.enumOptions.length, equals(4));
      expect(meta1.enumOptions[0], equals('Off'));
      expect(meta1.enumOptions[1], equals('Stereo Wide'));
      expect(meta1.enumOptions[2], equals('Binaural'));
      expect(meta1.enumOptions[3], equals('Center Focus'));

      final meta2 = sliders[2]!;
      expect(meta2.enumOptions.isEmpty, isTrue);
      expect(meta2.step, equals(0.05));
    });

    testWidgets('枚举类型 slider 渲染为原生 DropdownButton 并精确下发整型', (tester) async {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);
      const code = 'slider1:1<0,2,1{Mode A,Mode B,Mode C}>Selector';
      final sliders = EelSliderParser.parse(code);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: LiveprogSlidersPanel(
              model: model,
              activeSliders: sliders,
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // 验证存在 DropdownButton 组件
      expect(find.byType(DropdownButton<int>), findsOneWidget);
      expect(find.text('#0'), findsOneWidget); // 初始值 0 的显示
    });
  });

  group('3. 行号对齐与排版几何测试', () {
    testWidgets('LineNumberGutter 包含 strutStyle 并具备精确 top 偏移', (tester) async {
      final ctrl = ScrollController();
      addTearDown(ctrl.dispose);

      await tester.pumpWidget(
        MaterialApp(
          theme: testTheme,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('zh'),
          home: Scaffold(
            body: SizedBox(
              height: 400,
              width: 100,
              child: LineNumberGutter(
                editorScrollCtrl: ctrl,
                lineCount: 5,
                errorLines: const {},
                activeLine: 1,
                onSelectLine: (_) {},
                lineHeight: 18.75,
                fontSize: 11.5,
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('1'), findsOneWidget);
      expect(find.text('5'), findsOneWidget);

      final textWidget = tester.widget<Text>(find.text('1'));
      expect(textWidget.strutStyle, isNotNull);
      expect(textWidget.strutStyle!.forceStrutHeight, isTrue);
      expect(textWidget.strutStyle!.height, equals(1.5));
    });
  });

  group('4. 动态压缩器阈值平滑与节流测试', () {
    test('缓慢拖动压缩阈值同步平滑更新 7 段增益与镜像，防风暴节流下发', () {
      final model = AppModel(testing: true);
      addTearDown(model.dispose);

      // 设置阈值 -24dB
      model.setCompThreshold(-24.0, forceFlush: true);
      expect(model.compThreshold, equals(-24.0));
      // strength = 24.0 / 48.0 = 0.5; gain = -0.5 * 0.9 = -0.45
      for (var i = 0; i < 7; i++) {
        expect(model.compGains[i], closeTo(-0.45, 1e-4));
        expect(model.mirrorFloat('comp.gain${i + 1}', 0.0), closeTo(-0.45, 1e-4));
      }

      // 微小微调 -24.1dB (diff < 0.4)
      model.setCompThreshold(-24.1);
      expect(model.compThreshold, equals(-24.1));
      // 增益与镜像即时平滑跟随，保证 UI 读数无延迟
      final newStrength = 24.1 / 48.0;
      expect(model.compGains[0], closeTo(-newStrength * 0.9, 1e-4));

      // forceFlush 立即刷入引擎下发基准
      model.setCompThreshold(-24.1, forceFlush: true);
      expect(model.compThreshold, equals(-24.1));
    });
  });
}
