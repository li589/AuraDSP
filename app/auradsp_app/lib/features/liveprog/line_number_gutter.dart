/*
 * line_number_gutter.dart — Liveprog IDE 编辑器行号栏
 *
 * 功能：
 * 1. 随编辑器文本纵向滚动同步联动；
 * 2. 标示当前光标激活行与错误行；
 * 3. 出错行行号醒目标红（p.error 加粗 + 错误圆点），直观提示代码问题；
 * 4. 支持点击行号快速跳转光标到指定行。
 */

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/theme.dart';

class LineNumberGutter extends StatefulWidget {
  final ScrollController editorScrollCtrl;
  final int lineCount;
  final Set<int> errorLines;
  final int activeLine;
  final ValueChanged<int> onSelectLine;
  final double lineHeight;

  const LineNumberGutter({
    super.key,
    required this.editorScrollCtrl,
    required this.lineCount,
    required this.errorLines,
    required this.activeLine,
    required this.onSelectLine,
    this.lineHeight = 18.75,
  });

  @override
  State<LineNumberGutter> createState() => _LineNumberGutterState();
}

class _LineNumberGutterState extends State<LineNumberGutter> {
  late final ScrollController _gutterScrollCtrl;

  @override
  void initState() {
    super.initState();
    _gutterScrollCtrl = ScrollController(
      initialScrollOffset: widget.editorScrollCtrl.hasClients
          ? widget.editorScrollCtrl.offset
          : 0.0,
    );
    widget.editorScrollCtrl.addListener(_onEditorScroll);
  }

  void _onEditorScroll() {
    if (!mounted || !_gutterScrollCtrl.hasClients || !widget.editorScrollCtrl.hasClients) {
      return;
    }
    final target = widget.editorScrollCtrl.offset.clamp(
      0.0,
      _gutterScrollCtrl.position.maxScrollExtent,
    );
    if ((_gutterScrollCtrl.offset - target).abs() > 0.5) {
      _gutterScrollCtrl.jumpTo(target);
    }
  }

  @override
  void dispose() {
    widget.editorScrollCtrl.removeListener(_onEditorScroll);
    _gutterScrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final count = widget.lineCount < 1 ? 1 : widget.lineCount;

    // 自适应行号宽度：2 位数 38px，3 位数 46px，4+ 位数 54px
    final digits = count.toString().length;
    final gutterWidth = (digits * 8.0 + 26.0).clamp(38.0, 60.0);

    return Container(
      width: gutterWidth,
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.65),
        border: Border(right: BorderSide(color: p.hairline)),
      ),
      child: NotificationListener<ScrollNotification>(
        onNotification: (_) => true, // 拦截手势，由编辑器单一驱动滚动
        child: ListView.builder(
          controller: _gutterScrollCtrl,
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(vertical: AuraSpace.md),
          itemCount: count,
          itemExtent: widget.lineHeight,
          itemBuilder: (context, idx) {
            final lineNum = idx + 1;
            final isError = widget.errorLines.contains(lineNum);
            final isActive = lineNum == widget.activeLine;

            Color numColor;
            FontWeight weight = FontWeight.normal;
            if (isError) {
              numColor = p.error;
              weight = FontWeight.bold;
            } else if (isActive) {
              numColor = p.text;
              weight = FontWeight.w600;
            } else {
              numColor = p.textDim;
            }

            return InkWell(
              onTap: () => widget.onSelectLine(lineNum),
              child: SizedBox(
                height: widget.lineHeight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (isError) ...[
                        Icon(Icons.error_outline_rounded, size: 10, color: p.error),
                        const SizedBox(width: 2),
                      ],
                      Text(
                        '$lineNum',
                        style: monoOf(p, size: 11.5, color: numColor).copyWith(
                          fontWeight: weight,
                          height: 1.0,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }
}
