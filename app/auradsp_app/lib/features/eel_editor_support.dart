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

import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/material.dart';

// P1：EelSliderMeta/EelSliderParser 已下沉到 core/eel_slider_parser.dart
// （解 core→features 倒挂）；此处转 export，老调用方 import 不变。
export '../core/eel_slider_parser.dart';

/// 一条 lint 问题（行号 1-based）
class EelLintIssue {
  final int line;
  final int col; // 1-based，0 = 未知
  final String message;

  /// 引擎必拒项（缺段/空 @init）：应用前本地拦截，不下发编译。
  /// 非 blocking 仅警告（引擎可编译但语义可疑，如 slider9+ 永远收不到滑块值）。
  final bool blocking;
  const EelLintIssue(this.line, this.col, this.message, {this.blocking = false});
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
  static List<EelLintIssue> lint(AppLocalizations t, String src) {
    final issues = <EelLintIssue>[];
    var line = 1, col = 1;
    var inString = false, inLineComment = false, inBlockComment = false;
    final stack = <(String, int, int)>[];

    var i = 0;
    while (i < src.length) {
      final ch = src[i];
      if (ch == '\n') {
        if (inString) {
          issues.add(EelLintIssue(line, col, t.eelUnclosedString));
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
          issues.add(EelLintIssue(line, col, t.eelUnmatchedClose(ch)));
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
      issues.add(EelLintIssue(0, 0, t.eelBlockCommentUnclosed));
    }
    for (final (ch, l, c) in stack.reversed) {
      issues.add(EelLintIssue(l, c, t.eelUnclosedQuote(ch, l, c)));
    }
    issues.addAll(_structuralChecks(t, src));
    issues.sort((a, b) => a.line.compareTo(b.line));
    return issues;
  }

  /// 把注释与字符串内容抹成空格（保留换行）：结构检查只看真实代码，
  /// 注释里的 "@init" 字样、字符串里的 "slider9" 不得误报。
  static String _stripNonCode(String src) {
    final buf = StringBuffer();
    var i = 0;
    var inString = false, inLine = false, inBlock = false;
    while (i < src.length) {
      final ch = src[i];
      if (ch == '\n') {
        buf.write('\n');
        inLine = false;
        inString = false;
        i++;
        continue;
      }
      if (inLine) {
        buf.write(' ');
        i++;
        continue;
      }
      if (inBlock) {
        if (ch == '*' && i + 1 < src.length && src[i + 1] == '/') {
          buf.write('  ');
          inBlock = false;
          i += 2;
          continue;
        }
        buf.write(' ');
        i++;
        continue;
      }
      if (inString) {
        if (ch == '\\' && i + 1 < src.length) {
          buf.write('  ');
          i += 2;
          continue;
        }
        if (ch == '"') inString = false;
        buf.write(' ');
        i++;
        continue;
      }
      if (ch == '/' && i + 1 < src.length && src[i + 1] == '/') {
        buf.write('  ');
        inLine = true;
        i += 2;
        continue;
      }
      if (ch == '/' && i + 1 < src.length && src[i + 1] == '*') {
        buf.write('  ');
        inBlock = true;
        i += 2;
        continue;
      }
      if (ch == '"') {
        buf.write(' ');
        inString = true;
        i++;
        continue;
      }
      buf.write(ch);
      i++;
    }
    return buf.toString();
  }

  /// 结构预检（应用前本地拦截，不下发即报错）：
  /// 段存在性 / 空 @init / slider 越界 / 只读变量赋值。
  static List<EelLintIssue> _structuralChecks(AppLocalizations t, String src) {
    final issues = <EelLintIssue>[];
    final code = _stripNonCode(src);
    int lineOf(int offset) =>
        '\n'.allMatches(code.substring(0, offset)).length + 1;

    final hasInit = RegExp(r'@init\b').hasMatch(code);
    final hasSample = RegExp(r'@sample\b').hasMatch(code);
    if (!hasInit) {
      issues.add(EelLintIssue(0, 0, t.eelMissingInit,
          blocking: true));
    }
    if (!hasSample) {
      issues.add(const EelLintIssue(0, 0, '缺少 @sample 段（引擎会拒绝编译）',
          blocking: true));
    }

    // 空段：@init 到下一个段指令（或文末）之间只有空白。
    final dirRe = RegExp(r'@(init|sample|slider|block)\b');
    final dirs = dirRe.allMatches(code).toList();
    for (var k = 0; k < dirs.length; k++) {
      final d = dirs[k];
      final name = code.substring(d.start, d.end);
      final end = (k + 1 < dirs.length) ? dirs[k + 1].start : code.length;
      if (code.substring(d.end, end).trim().isEmpty) {
        if (name == '@init') {
          issues.add(EelLintIssue(lineOf(d.start), 0,
              t.eelEmptyInit,
              blocking: true));
        } else if (name == '@sample') {
          issues.add(EelLintIssue(lineOf(d.start), 0,
              t.eelEmptySample));
        }
      }
    }

    // sliderN（N>8）：EEL 会放行编译，但宿主只有 slider1..8，值永远到不了。
    for (final m in RegExp(r'\bslider(\d+)\b').allMatches(code)) {
      final n = int.tryParse(m.group(1) ?? '');
      if (n != null && n > 8) {
        issues.add(EelLintIssue(
            lineOf(m.start), 0, t.eelSliderRange(n)));
      }
    }

    // 只读变量赋值：srate / num_ch 由宿主提供，赋值无效果。
    for (final m
        in RegExp(r'\b(srate|num_ch)\b\s*[-+*/%]?=(?!=)').allMatches(code)) {
      issues.add(EelLintIssue(
          lineOf(m.start), 0, t.eelReadonlyAssign(m.group(1) ?? '')));
    }
    return issues;
  }
}
