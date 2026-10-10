/*
 * eel_editor_support.dart — Liveprog（EEL2）编辑器支持
 *
 * 1) EelSyntaxTextEditingController：
 *    EEL2 词法高亮控制器（段指令、控制流关键字、内置变量、系统函数、数字、字符串、注释）
 * 2) EelFormatter：
 *    高级格式化（花括号层级缩进、操作符规范化空格、分号规整、连续赋值等号美化对齐）
 * 3) EelLinter：
 *    轻量即时词法检查（括号/引号匹配状态机与错误定位）
 * 4) EelSliderParser：
 *    自适应滑块参数解析器（解析 sliderN:default<min,max,step>name 声明与代码实际变量引用）
 */

import 'package:flutter/material.dart';

/// 一条 lint 问题（行号 1-based）
class EelLintIssue {
  final int line;
  final int col; // 1-based，0 = 未知
  final String message;
  const EelLintIssue(this.line, this.col, this.message);
}

/// 自适应滑块参数元数据
class EelSliderMeta {
  final int index; // 1..8
  final String rawName;
  final String displayName;
  final double defaultVal;
  final double minVal;
  final double maxVal;
  final double step;
  final bool isReferenced;

  const EelSliderMeta({
    required this.index,
    required this.rawName,
    required this.displayName,
    this.defaultVal = 0.0,
    this.minVal = 0.0,
    this.maxVal = 1.0,
    this.step = 0.01,
    this.isReferenced = true,
  });
}

/// 自适应滑块解析器
abstract final class EelSliderParser {
  static final RegExp _declRegex = RegExp(
    r'slider(?<num>[1-8])\s*:\s*(?<def>-?[\d.]+)(\s*<\s*(?<min>-?[\d.]+)\s*,\s*(?<max>-?[\d.]+)(\s*,\s*(?<step>-?[\d.]+))?\s*>)?\s*(?<name>[^\r\n;]*)',
  );

  /// 解析代码文本中声明或引用的滑块参数
  static Map<int, EelSliderMeta> parse(String code) {
    final result = <int, EelSliderMeta>{};

    // 1. 扫描显式声明指令
    for (final m in _declRegex.allMatches(code)) {
      final numStr = m.namedGroup('num');
      if (numStr == null) continue;
      final idx = int.tryParse(numStr);
      if (idx == null) continue;

      final defVal = double.tryParse(m.namedGroup('def') ?? '') ?? 0.0;
      final minVal = double.tryParse(m.namedGroup('min') ?? '') ?? 0.0;
      final maxVal = double.tryParse(m.namedGroup('max') ?? '') ?? 1.0;
      final step = double.tryParse(m.namedGroup('step') ?? '') ?? 0.01;
      var name = (m.namedGroup('name') ?? '').trim();
      if (name.isEmpty) name = 'slider$idx';

      result[idx] = EelSliderMeta(
        index: idx,
        rawName: 'slider$idx',
        displayName: name,
        defaultVal: defVal,
        minVal: minVal,
        maxVal: maxVal,
        step: step,
        isReferenced: true,
      );
    }

    // 2. 扫描代码全局引用的 slider1..8
    for (var i = 1; i <= 8; i++) {
      final refPattern = RegExp('\\bslider$i\\b');
      if (refPattern.hasMatch(code)) {
        if (!result.containsKey(i)) {
          result[i] = EelSliderMeta(
            index: i,
            rawName: 'slider$i',
            displayName: '参数 $i (slider$i)',
            defaultVal: 0.0,
            minVal: 0.0,
            maxVal: 1.0,
            step: 0.01,
            isReferenced: true,
          );
        }
      }
    }

    return result;
  }
}

/// EEL2 语法高亮文本控制器
class EelSyntaxTextEditingController extends TextEditingController {
  EelSyntaxTextEditingController({super.text});

  static final RegExp _syntaxRegex = RegExp(
    r'(?<comment>/\*[\s\S]*?\*/|//[^\n]*)'
    r'|(?<string>"(\\.|[^"\\])*")'
    r'|(?<directive>@(init|sample|slider|block)\b)'
    r'|(?<keyword>\b(if|else|while|loop|function|local|global|instance)\b)'
    r'|(?<variable>\b(spl[01]|slider[1-8]|srate|num_ch|tempo|play_state)\b)'
    r'|(?<func>\b(sin|cos|tan|asin|acos|atan|atan2|sinh|cosh|tanh|sqrt|log|log10|exp|abs|min|max|floor|ceil|sign|rand|freembuf|memcpy|memset)\b)'
    r'|(?<number>\b\d+(\.\d+)?([eE][+-]?\d+)?\b|0x[0-9a-fA-F]+|\$[0-9a-fA-F]+)',
    multiLine: true,
  );

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final textVal = text;
    if (textVal.isEmpty) {
      return TextSpan(style: style, text: '');
    }

    final spans = <TextSpan>[];
    var lastIndex = 0;

    // 语法色彩方案（现代深色编程高对比质感）
    const commentStyle = TextStyle(
      color: Color(0xFF8B949E),
      fontStyle: FontStyle.italic,
    );
    const stringStyle = TextStyle(
      color: Color(0xFFA5D6FF),
    );
    const directiveStyle = TextStyle(
      color: Color(0xFFFF7B72),
      fontWeight: FontWeight.bold,
    );
    const keywordStyle = TextStyle(
      color: Color(0xFFD2A8FF),
      fontWeight: FontWeight.bold,
    );
    const variableStyle = TextStyle(
      color: Color(0xFF7EE787),
      fontWeight: FontWeight.w600,
    );
    const funcStyle = TextStyle(
      color: Color(0xFF79C0FF),
    );
    const numberStyle = TextStyle(
      color: Color(0xFFFFA657),
    );

    for (final match in _syntaxRegex.allMatches(textVal)) {
      if (match.start > lastIndex) {
        spans.add(TextSpan(
          text: textVal.substring(lastIndex, match.start),
          style: style,
        ));
      }

      TextStyle? matchedStyle;
      if (match.namedGroup('comment') != null) {
        matchedStyle = commentStyle;
      } else if (match.namedGroup('string') != null) {
        matchedStyle = stringStyle;
      } else if (match.namedGroup('directive') != null) {
        matchedStyle = directiveStyle;
      } else if (match.namedGroup('keyword') != null) {
        matchedStyle = keywordStyle;
      } else if (match.namedGroup('variable') != null) {
        matchedStyle = variableStyle;
      } else if (match.namedGroup('func') != null) {
        matchedStyle = funcStyle;
      } else if (match.namedGroup('number') != null) {
        matchedStyle = numberStyle;
      }

      spans.add(TextSpan(
        text: match.group(0),
        style: style?.merge(matchedStyle) ?? matchedStyle,
      ));

      lastIndex = match.end;
    }

    if (lastIndex < textVal.length) {
      spans.add(TextSpan(
        text: textVal.substring(lastIndex),
        style: style,
      ));
    }

    return TextSpan(children: spans);
  }
}

/// 进阶代码格式化器
abstract final class EelFormatter {
  /// 格式化：层级缩进、操作符规范化、分号规整与赋值对齐
  static String format(String src) {
    if (src.isEmpty) return src;
    final lines = src.replaceAll('\r\n', '\n').split('\n');
    final processedLines = <String>[];
    var depth = 0;

    for (var raw in lines) {
      var l = raw.replaceFirst(RegExp(r'^[\t ]+'), '');
      l = l.replaceFirst(RegExp(r'[\t ]+$'), '');

      // 清理分号前多余空格: a = 1 ; -> a = 1;
      l = l.replaceAll(RegExp(r'\s+;'), ';');

      final isSection = l.startsWith('@');
      final isCommentOnly = l.startsWith('//') || l.startsWith('/*');

      // 非纯注释行规整常用赋值与双目操作符周围的空格
      if (!isCommentOnly && !isSection && l.isNotEmpty) {
        l = _formatOperatorsInLine(l);
      }

      final opens = '{'.allMatches(l).length;
      final closes = '}'.allMatches(l).length;

      var printDepth = depth;
      var nextDepth = depth;
      if (l.startsWith('}')) printDepth = (depth - 1).clamp(0, 64);
      if (isSection) {
        printDepth = 0;
        nextDepth = 0;
      }

      processedLines.add(l.isEmpty ? '' : '\t' * printDepth + l);

      final net = opens - closes;
      if (net != 0) nextDepth = (nextDepth + net).clamp(0, 64);
      depth = nextDepth;
    }

    return _alignAssignments(processedLines).join('\n');
  }

  /// 单行操作符周围规范化空格
  static String _formatOperatorsInLine(String line) {
    // 保护字符串和行内注释
    final commentIdx = line.indexOf('//');
    String codePart = commentIdx >= 0 ? line.substring(0, commentIdx) : line;
    final commentPart = commentIdx >= 0 ? line.substring(commentIdx) : '';

    // 复合运算符与常见运算符空格规整
    // 先暂存 ==, !=, <=, >=, +=, -=, *=, /=
    codePart = codePart
        .replaceAll(RegExp(r'\s*([+\-*/%]=)\s*'), ' \$1 ')
        .replaceAll(RegExp(r'\s*(==|!=|<=|>=)\s*'), ' \$1 ')
        .replaceAll(RegExp(r'(?<![=!<>+\-*/%])\s*=\s*(?![=])'), ' = ')
        .replaceAll(RegExp(r'\s*,\s*'), ', ');

    return commentPart.isNotEmpty ? '$codePart $commentPart' : codePart;
  }

  /// 连续简单赋值语句等号对齐美化
  static List<String> _alignAssignments(List<String> lines) {
    final result = <String>[];
    var i = 0;

    while (i < lines.length) {
      final current = lines[i];
      // 检查当前行是否为普通单等号赋值且不含括号/花括号
      if (_isAlignableAssignment(current)) {
        final block = <String>[current];
        var j = i + 1;
        while (j < lines.length && _isAlignableAssignment(lines[j])) {
          block.add(lines[j]);
          j++;
        }

        if (block.length >= 2) {
          // 找出当前 block 中等号前的最大宽度
          var maxEqPos = 0;
          for (final b in block) {
            final eqIdx = b.indexOf('=');
            final prefix = b.substring(0, eqIdx).trimRight();
            if (prefix.length > maxEqPos) maxEqPos = prefix.length;
          }

          for (final b in block) {
            final eqIdx = b.indexOf('=');
            final prefix = b.substring(0, eqIdx).trimRight();
            final suffix = b.substring(eqIdx + 1).trimLeft();
            final padding = ' ' * (maxEqPos - prefix.length);
            result.add('$prefix$padding = $suffix');
          }
          i = j;
          continue;
        }
      }

      result.add(current);
      i++;
    }

    return result;
  }

  static bool _isAlignableAssignment(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || trimmed.startsWith('//') || trimmed.startsWith('@')) {
      return false;
    }
    if (trimmed.contains('{') || trimmed.contains('}') || trimmed.contains('if ') || trimmed.contains('while ')) {
      return false;
    }
    final eqCount = '='.allMatches(trimmed).length;
    return eqCount == 1 && !trimmed.contains('==') && !trimmed.contains('!=') && !trimmed.contains('<=') && !trimmed.contains('>=');
  }
}

/// 轻量即时语法检查器
abstract final class EelLinter {
  /// 括号配对、字符串闭合、注释闭合检查
  static List<EelLintIssue> lint(String src) {
    final issues = <EelLintIssue>[];
    var line = 1, col = 1;
    var inString = false, inLineComment = false, inBlockComment = false;
    final stack = <(String, int, int)>[];

    var i = 0;
    while (i < src.length) {
      final ch = src[i];
      if (ch == '\n') {
        if (inString) {
          issues.add(EelLintIssue(line, col, '字符串未闭合（跨行）'));
        }
        inLineComment = false;
        inString = false;
        line++;
        col = 1;
        i++;
        continue;
      }

      if (inLineComment) {
        i++;
        col++;
        continue;
      }
      if (inBlockComment) {
        if (ch == '*' && i + 1 < src.length && src[i + 1] == '/') {
          inBlockComment = false;
          i += 2;
          col += 2;
          continue;
        }
        i++;
        col++;
        continue;
      }
      if (inString) {
        if (ch == '\\') {
          i += 2;
          col += 2;
          continue;
        }
        if (ch == '"') inString = false;
        i++;
        col++;
        continue;
      }

      // 普通代码态
      if (ch == '/' && i + 1 < src.length && src[i + 1] == '/') {
        inLineComment = true;
        i += 2;
        col += 2;
        continue;
      }
      if (ch == '/' && i + 1 < src.length && src[i + 1] == '*') {
        inBlockComment = true;
        i += 2;
        col += 2;
        continue;
      }
      if (ch == '"') {
        inString = true;
        i++;
        col++;
        continue;
      }
      if (ch == '{' || ch == '(' || ch == '[') {
        stack.add((ch, line, col));
        i++;
        col++;
        continue;
      }
      if (ch == '}' || ch == ')' || ch == ']') {
        final want = ch == '}'
            ? '{'
            : (ch == ')' ? '(' : '[');
        if (stack.isEmpty || stack.last.$1 != want) {
          issues.add(EelLintIssue(line, col, '多余的 "$ch"（无匹配的开括号）'));
        } else {
          stack.removeLast();
        }
        i++;
        col++;
        continue;
      }
      i++;
      col++;
    }

    if (inBlockComment) {
      issues.add(const EelLintIssue(0, 0, '块注释未闭合（/* 缺少对应的 */）'));
    }
    for (final (ch, l, c) in stack.reversed) {
      issues.add(EelLintIssue(l, c, '"$ch" 未闭合（始于第 $l 行第 $c 列）'));
    }
    issues.sort((a, b) => a.line.compareTo(b.line));
    return issues;
  }
}
