/*
 * line_number_gutter.dart — Liveprog IDE 编辑器行号栏
 *
 * 架构重构（单一直驱虚拟化视口）：
 * 1. 彻底移除 Scrollable/ListView，根绝系统在行号列自动生成二次死滑动条；
 * 2. 由 editorScrollCtrl 单一直驱，仅渲染视口内可见行（startIdx..endIdx）；
 * 3. 几何坐标与 TextField 排版管线 100% 严密对齐（AuraSpace.md + i * lineHeight - scrollOffset）；
 * 4. 完整保留 InkWell、Icon 与 Text 原生交互，支持错误行标红与点击跳转。
 */

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/theme.dart';

class LineNumberGutter extends StatelessWidget {
  final ScrollController editorScrollCtrl;
  final int lineCount;
  final Set<int> errorLines;
  final int activeLine;
  final ValueChanged<int> onSelectLine;
  final double lineHeight;
  final double fontSize;

  const LineNumberGutter({
    super.key,
    required this.editorScrollCtrl,
    required this.lineCount,
    required this.errorLines,
    required this.activeLine,
    required this.onSelectLine,
    required this.lineHeight,
    this.fontSize = 11.5,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final count = lineCount < 1 ? 1 : lineCount;

    // 自适应行号宽度：随字号与行数位数动态调整
    final digits = count.toString().length;
    final gutterWidth =
        (digits * (fontSize * 0.72) + 26.0).clamp(38.0, 90.0);

    return Container(
      width: gutterWidth,
      decoration: BoxDecoration(
        color: p.panel.withValues(alpha: 0.65),
        border: Border(right: BorderSide(color: p.hairline)),
      ),
      child: ClipRect(
        child: AnimatedBuilder(
          animation: editorScrollCtrl,
          builder: (context, _) {
            final scrollOffset =
                editorScrollCtrl.hasClients ? editorScrollCtrl.offset : 0.0;

            return LayoutBuilder(
              builder: (context, constraints) {
                final height = constraints.maxHeight;
                if (lineHeight <= 0 || height <= 0) {
                  return const SizedBox.shrink();
                }

                // 仅计算视口内的可见行范围 (0-based)
                final startIdx = ((scrollOffset - AuraSpace.md) / lineHeight)
                    .floor()
                    .clamp(0, count - 1);
                final endIdx =
                    ((scrollOffset + height - AuraSpace.md) / lineHeight)
                        .ceil()
                        .clamp(0, count - 1);

                final children = <Widget>[];
                for (int i = startIdx; i <= endIdx; i++) {
                  final lineNum = i + 1;
                  final top = AuraSpace.md + i * lineHeight - scrollOffset - 1.5;
                  final isError = errorLines.contains(lineNum);
                  final isActive = lineNum == activeLine;

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

                  children.add(
                    Positioned(
                      top: top,
                      left: 0,
                      right: 0,
                      height: lineHeight,
                      child: InkWell(
                        onTap: () => onSelectLine(lineNum),
                        child: Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.end,
                            crossAxisAlignment: CrossAxisAlignment.center,
                            children: [
                              if (isError) ...[
                                Icon(
                                  Icons.error_outline_rounded,
                                  size: (fontSize * 0.85).clamp(8.0, 13.0),
                                  color: p.error,
                                ),
                                const SizedBox(width: 2),
                              ],
                              Text(
                                '$lineNum',
                                strutStyle: StrutStyle(
                                  fontSize: fontSize,
                                  height: 1.5,
                                  forceStrutHeight: true,
                                ),
                                style: monoOf(p,
                                        size: fontSize, color: numColor)
                                    .copyWith(
                                  fontWeight: weight,
                                  height: 1.5,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }

                return Stack(
                  clipBehavior: Clip.hardEdge,
                  children: children,
                );
              },
            );
          },
        ),
      ),
    );
  }
}

