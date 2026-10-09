import 'package:auradsp_app/features/eel_editor_support.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('EelLinter', () {
    test('模板代码（正确）→ 0 问题', () {
      const src = '@init\ndbg = 0;\n\n@sample\nspl0 *= slider1;\n';
      expect(EelLinter.lint(src), isEmpty);
    });

    test('未闭合的 ( → 报告起始行', () {
      const src = '@sample\nspl0 *= (slider1;\n';
      final issues = EelLinter.lint(src);
      expect(issues, isNotEmpty);
      expect(issues.first.line, 2);
      expect(issues.first.message, contains('未闭合'));
    });

    test('多余的 ) → 报告所在行', () {
      const src = '@sample\nspl0 = 1);\n';
      final issues = EelLinter.lint(src);
      expect(issues, isNotEmpty);
      expect(issues.first.line, 2);
      expect(issues.first.message, contains('多余的'));
    });

    test('嵌套括号跨行：闭合 → 通过', () {
      const src = '@init\nif (a > 0) {\n  b = (c + d) * 2;\n}\n';
      expect(EelLinter.lint(src), isEmpty);
    });

    test('嵌套括号：} 错配 ) → 报告', () {
      const src = '@init\nif (a) {\n  b = 1)\n';
      final issues = EelLinter.lint(src);
      expect(issues, isNotEmpty);
    });

    test('字符串里的括号不参与配对', () {
      const src = '@sample\ntitle = "(unclosed {\n';
      // 字符串跨行 → 报"字符串未闭合"而不是括号问题
      final issues = EelLinter.lint(src);
      expect(issues, isNotEmpty);
      expect(issues.first.message, contains('字符串'));
    });

    test('字符串内闭合括号 → 不误报', () {
      const src = '@sample\ns = "( { [";\nspl0 = 1;\n';
      expect(EelLinter.lint(src), isEmpty);
    });

    test('注释里的括号不参与配对', () {
      const src = '@init\n// ( { [ 未闭合注释\n/* ) } ] */\nx = 1;\n';
      expect(EelLinter.lint(src), isEmpty);
    });

    test('块注释未闭合 → 报告', () {
      const src = '@init\n/* 未闭合\n';
      final issues = EelLinter.lint(src);
      expect(issues, isNotEmpty);
      expect(issues.first.message, contains('块注释'));
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
      expect(EelLinter.lint(''), isEmpty);
    });
  });
}
