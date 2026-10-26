import 'package:auradsp_app/features/liveprog/eel_editor_support.dart';
import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';

final AppLocalizations _zh = lookupAppLocalizations(const Locale('zh'));

void main() {
  group('EelLinter', () {
    test('模板代码（正确）→ 0 问题', () {
      const src = '@init\ndbg = 0;\n\n@sample\nspl0 *= slider1;\n';
      expect(EelLinter.lint(_zh, src), isEmpty);
    });

    test('未闭合的 ( → 报告起始行', () {
      const src = '@init\nx = 1;\n@sample\nspl0 *= (slider1;\n';
      final issues = EelLinter.lint(_zh, src);
      expect(issues, isNotEmpty);
      final unclosed =
          issues.where((e) => e.message.contains('未闭合')).toList();
      expect(unclosed, isNotEmpty);
      expect(unclosed.first.line, 4);
    });

    test('多余的 ) → 报告所在行', () {
      const src = '@init\nx = 1;\n@sample\nspl0 = 1);\n';
      final issues = EelLinter.lint(_zh, src);
      expect(issues, isNotEmpty);
      expect(issues.any((e) => e.message.contains('多余的') && e.line == 4),
          isTrue);
    });

    test('嵌套括号跨行：闭合 → 通过', () {
      const src = '@init\nif (a > 0) {\n  b = (c + d) * 2;\n}\n@sample\nspl0 = 1;\n';
      expect(EelLinter.lint(_zh, src), isEmpty);
    });

    test('嵌套括号：} 错配 ) → 报告', () {
      const src = '@init\nif (a) {\n  b = 1)\n@sample\nspl0 = 1;\n';
      final issues = EelLinter.lint(_zh, src);
      expect(issues, isNotEmpty);
    });

    test('字符串里的括号不参与配对', () {
      const src = '@init\nx = 1;\n@sample\ntitle = "(unclosed {\n';
      // 字符串跨行 → 报"字符串未闭合"而不是括号问题
      final issues = EelLinter.lint(_zh, src);
      expect(issues, isNotEmpty);
      expect(issues.any((e) => e.message.contains('字符串')), isTrue);
    });

    test('字符串内闭合括号 → 不误报', () {
      const src = '@init\nx = 1;\n@sample\ns = "( { [";\nspl0 = 1;\n';
      expect(EelLinter.lint(_zh, src), isEmpty);
    });

    test('注释里的括号不参与配对', () {
      const src = '@init\n// ( { [ 未闭合注释\n/* ) } ] */\nx = 1;\n@sample\nspl0 = 1;\n';
      expect(EelLinter.lint(_zh, src), isEmpty);
    });

    test('块注释未闭合 → 报告', () {
      const src = '@init\nx = 1;\n/* 未闭合\n';
      final issues = EelLinter.lint(_zh, src);
      expect(issues, isNotEmpty);
      expect(issues.any((e) => e.message.contains('块注释')), isTrue);
    });
  });

  group('EelLinter 结构预检（v1.2）', () {
    test('缺 @init → blocking', () {
      const src = '@sample\nspl0 = 1;\n';
      final issues = EelLinter.lint(_zh, src);
      final hit =
          issues.where((e) => e.message.contains('@init')).toList();
      expect(hit, isNotEmpty);
      expect(hit.every((e) => e.blocking), isTrue);
    });

    test('缺 @sample → blocking', () {
      const src = '@init\nx = 1;\n';
      final issues = EelLinter.lint(_zh, src);
      expect(
          issues.any(
              (e) => e.blocking && e.message.contains('@sample')),
          isTrue);
    });

    test('空 @init → blocking 且定位到行', () {
      const src = '@init\n@sample\nspl0 = 1;\n';
      final issues = EelLinter.lint(_zh, src);
      final hit =
          issues.where((e) => e.message.contains('空 @init')).toList();
      expect(hit.length, 1);
      expect(hit.first.blocking, isTrue);
      expect(hit.first.line, 1);
    });

    test('空 @sample → 仅警告（非 blocking）', () {
      const src = '@init\nx = 1;\n@sample\n';
      final issues = EelLinter.lint(_zh, src);
      final hit =
          issues.where((e) => e.message.contains('@sample')).toList();
      expect(hit, isNotEmpty);
      expect(hit.every((e) => !e.blocking), isTrue);
    });

    test('slider9 → 越界警告且定位到行', () {
      const src = '@init\nx = 1;\n@sample\nspl0 *= slider9;\n';
      final issues = EelLinter.lint(_zh, src);
      final hit =
          issues.where((e) => e.message.contains('slider9')).toList();
      expect(hit.length, 1);
      expect(hit.first.line, 4);
      expect(hit.first.blocking, isFalse);
    });

    test('srate 赋值 → 只读警告；== 比较不误报', () {
      const bad = '@init\nsrate = 48000;\n@sample\nspl0 = 1;\n';
      final badIssues = EelLinter.lint(_zh, bad);
      expect(
          badIssues.any((e) => e.message.contains('srate') && e.line == 2),
          isTrue);
      const ok = '@init\nx = (srate == 48000);\n@sample\nspl0 = 1;\n';
      expect(
          EelLinter.lint(_zh, ok).where((e) => e.message.contains('srate')),
          isEmpty);
    });

    test('注释/字符串里的 @init、slider9、srate 不误报', () {
      const src = '@init\nx = 1;\n// @init slider9 srate = 1\n'
          '/* slider12 srate = 2 */\n@sample\ns = "slider9";\nspl0 = 1;\n';
      expect(EelLinter.lint(_zh, src), isEmpty);
    });
  });

  group('EelFormatter', () {
    test('缩进按花括号深度（Tab）', () {
      final out = EelFormatter.format('@init\nif (a) {\nb = 1;\n}\n');
      expect(out, '@init\nif (a) {\n\tb = 1;\n}\n');
    });

    test('} else { 形态保持同级', () {
      final out = EelFormatter.format('@init\nif (a) {\nb = 1;\n} else {\nc = 2;\n}\n');
      expect(out, '@init\nif (a) {\n\tb = 1;\n} else {\n\tc = 2;\n}\n');
    });

    test('@section 重置深度', () {
      final out = EelFormatter.format('@init\nif (a) {\nb = 1;\n}\n@sample\nspl0 = 1;\n');
      expect(out.contains('\n@sample'), isTrue);
      // @sample 后不应有缩进残留
      final lines = out.split('\n');
      final i = lines.indexOf('@sample');
      expect(lines[i + 1], 'spl0 = 1;');
    });

    test('行尾空白与既有缩进被规范化（@init 后深度 0）', () {
      final out = EelFormatter.format('@init\n    \tspl0 = 1;   \n');
      expect(out, '@init\nspl0 = 1;\n');
    });

    test('不改变行数（可安全恢复光标 offset）', () {
      const src = '@init\nif (a) {\n  b = (1 + 2) * 3;\n}\n';
      expect(EelFormatter.format(src).split('\n').length,
          src.split('\n').length);
    });

    test('空输入不崩', () {
      expect(EelFormatter.format(''), '');
      // 空文本缺两段 → 2 条 blocking 结构问题
      final issues = EelLinter.lint(_zh, '');
      expect(issues.length, 2);
      expect(issues.every((e) => e.blocking), isTrue);
    });
  });

  group('EelSliderParser Tests', () {
    test('解析头部显式声明 slider', () {
      const src = '''
slider1:1.0<0,2,0.01>总音量 (Volume)
slider3:500<20,20000,10>截止频率 (Cutoff)
@init
x = 0;
@sample
spl0 *= slider1;
''';
      final sliders = EelSliderParser.parse(src);
      expect(sliders.containsKey(1), isTrue);
      expect(sliders[1]!.displayName, '总音量 (Volume)');
      expect(sliders[1]!.defaultVal, 1.0);
      expect(sliders[1]!.minVal, 0.0);
      expect(sliders[1]!.maxVal, 2.0);
      expect(sliders[1]!.step, 0.01);

      expect(sliders.containsKey(3), isTrue);
      expect(sliders[3]!.displayName, '截止频率 (Cutoff)');
      expect(sliders[3]!.defaultVal, 500.0);
      expect(sliders[3]!.minVal, 20.0);
      expect(sliders[3]!.maxVal, 20000.0);

      expect(sliders.containsKey(2), isFalse);
    });

    test('解析代码中隐式引用的 slider', () {
      const src = '''
@init
c = 1;
@sample
spl0 = spl0 * slider2 + slider4;
''';
      final sliders = EelSliderParser.parse(src);
      expect(sliders.containsKey(2), isTrue);
      expect(sliders.containsKey(4), isTrue);
      expect(sliders.containsKey(1), isFalse);
      expect(sliders.containsKey(3), isFalse);
    });

    test('解析带注释前缀的 slider、枚举选项与自定义变量声明', () {
      const src = '''
desc: Dynamic Bass Mangler
author: remaincalm.org
//slider1:1<0,6,1>Octaves Down
slider15:1<0,3,1{No,Murky,Confused,Unpleasant}>Attitude
dBassGain:100<0,100,1>Bass strength (%)
freqSplit1:400<1,24000,1>Split 1 (Hz)
@init
x = 0;
@sample
spl0 = spl0;
''';
      final sliders = EelSliderParser.parse(src);
      // slider1 (带 // 前缀)
      expect(sliders.containsKey(1), isTrue);
      expect(sliders[1]!.rawName, 'slider1');
      expect(sliders[1]!.displayName, 'Octaves Down');
      expect(sliders[1]!.defaultVal, 1.0);
      expect(sliders[1]!.isHostSlider, isTrue);

      // slider15 (带枚举)
      expect(sliders.containsKey(15), isTrue);
      expect(sliders[15]!.rawName, 'slider15');
      expect(sliders[15]!.displayName, 'Attitude');
      expect(sliders[15]!.enumOptions, ['No', 'Murky', 'Confused', 'Unpleasant']);
      expect(sliders[15]!.isHostSlider, isFalse);

      // 自定义变量
      final customMetas = sliders.values.where((m) => !m.rawName.startsWith('slider')).toList();
      expect(customMetas.length, 2);
      expect(customMetas.any((m) => m.rawName == 'dBassGain' && m.defaultVal == 100.0), isTrue);
      expect(customMetas.any((m) => m.rawName == 'freqSplit1' && m.minVal == 1.0), isTrue);
    });
  });
}
