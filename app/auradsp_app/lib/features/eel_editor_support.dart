/*
 * eel_editor_support.dart — Liveprog（EEL2）编辑器支持
 *
 * 1) EelFormatter：保守格式化（只动空白：行首缩进按花括号深度、去行尾空白；
 *    不增删行、不改代码内容，字符串字面量里的括号不影响深度容错）。
 * 2) EelLinter：轻量词法检查（注释/字符串状态机），报告括号不匹配、
 *    未闭合、字符串未闭合等问题（行号 1-based）。引擎编译仍是最终判据，
 *    这里做"保存前就能看见"的即时反馈。
 *
 * 取舍说明：TextField 不支持按行着色，"飘红"落地为问题列表 + 点击跳转光标。
 */

/// 一条 lint 问题（行号 1-based）
class EelLintIssue {
  final int line;
  final int col; // 1-based，0 = 未知
  final String message;
  const EelLintIssue(this.line, this.col, this.message);
}

abstract final class EelFormatter {
  /// 保守格式化：Tab 缩进（与编辑器 Tab 键一致）、行尾空白清理。
  /// 不改变行数与代码内容，替换后可按原光标 offset 恢复。
  static String format(String src) {
    if (src.isEmpty) return src;
    final lines = src.replaceAll('\r\n', '\n').split('\n');
    final out = <String>[];
    var depth = 0;
    for (var raw in lines) {
      var l = raw.replaceFirst(RegExp(r'^[\t ]+'), '');
      l = l.replaceFirst(RegExp(r'[\t ]+$'), '');
      final isSection = l.startsWith('@');
      final opens = '{'.allMatches(l).length;
      final closes = '}'.allMatches(l).length;
      // 本行缩进与下一行深度分离计算：行首 } 的闭合只影响"下一行"深度，
      // 本行缩进用 depth-1（} else { 形态由 net=0 自然保持层级）
      var printDepth = depth;
      var nextDepth = depth;
      if (l.startsWith('}')) printDepth = (depth - 1).clamp(0, 64);
      if (isSection) {
        printDepth = 0;
        nextDepth = 0;
      }
      out.add(l.isEmpty ? '' : '\t' * printDepth + l);
      final net = opens - closes;
      if (net != 0) nextDepth = (nextDepth + net).clamp(0, 64);
      depth = nextDepth;
    }
    return out.join('\n');
  }
}

abstract final class EelLinter {
  /// 轻量检查：括号配对（跳过注释与字符串字面量）、字符串未闭合。
  static List<EelLintIssue> lint(String src) {
    final issues = <EelLintIssue>[];
    var line = 1, col = 1;
    var inString = false, inLineComment = false, inBlockComment = false;
    // 栈元素：字符 + 行 + 列
    final stack = <(String, int, int)>[];
    String? pendingStringStart;

    var i = 0;
    while (i < src.length) {
      final ch = src[i];
      if (ch == '\n') {
        if (inString && pendingStringStart == null) {
          pendingStringStart = null;
          issues.add(EelLintIssue(line, col, '字符串未闭合（跨行）'));
        }
        inLineComment = false;
        inString = false; // EEL 字符串不跨行
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

      // 普通态
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
    // 行号排序，定位更自然
    issues.sort((a, b) => a.line.compareTo(b.line));
    return issues;
  }
}
