/*
 * line_number_gutter.dart — Liveprog IDE 编辑器行号栏
 *
 * 架构重构（单一直驱虚拟化视口）：
 * 1. 彻底移除 Scrollable/ListView，根绝系统在行号列自动生成二次死滑动条；
 * 2. 由 editorScrollCtrl 单一直驱，仅渲染视口内可见行（startIdx..endIdx）；
 * 3. 几何坐标与 TextField 排版管线共用同一份 EditorLineMetrics（逐逻辑行实测），
 *    长行软换行后行号仍与对应逻辑行首行严格对齐，后续行号依次顺延；
 * 4. 行号文字的 strut 高度强制等于实测行高，消除“行号比正文略偏下”的累积漂移；
 * 5. 完整保留 InkWell、Icon 与 Text 原生交互，支持错误行标红与点击跳转。
 */

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/theme.dart';

/// 逻辑行排版几何：由与编辑器同款 TextPainter 预量，行号栏与编辑器共用一份
class EditorLineMetrics {
  const EditorLineMetrics({
    required this.tops,
    required this.heights,
    required this.lineAdvance,
  });

  /// 每个逻辑行在文本坐标系中的 y 起点（不含 contentPadding）
  final List<double> tops;

  /// 每个逻辑行的总高度（含软换行折出的可视行）
  final List<double> heights;

  /// 单个可视行的精确行高（strut 强制，全文本一致）
  final double lineAdvance;

  int get lineCount => tops.length;

  /// 与 TextField 完全同参量排版，逐逻辑行累计高度
  static EditorLineMetrics compute({
    required String text,
    required TextStyle style,
    required StrutStyle strutStyle,
    required double textWidth,
    required TextScaler textScaler,
    required double fallbackLineAdvance,
  }) {
    final lines = text.split('\n');
    final tops = <double>[];
    final heights = <double>[];
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      strutStyle: strutStyle,
      textScaler: textScaler,
    );

    var y = 0.0;
    var lineAdvance = 0.0;
    for (final line in lines) {
      // 空行也必须占一个可视行：用空格驱动排版，避免 0 高度
      painter.text = TextSpan(text: line.isEmpty ? ' ' : line, style: style);
      if (textWidth > 1) {
        painter.layout(maxWidth: textWidth);
      } else {
        painter.layout();
      }
      final lineMetrics = painter.computeLineMetrics();
      final advance =
          lineMetrics.isEmpty ? fallbackLineAdvance : lineMetrics.first.height;
      if (advance > 0) lineAdvance = advance;
      final visualCount = lineMetrics.isEmpty ? 1 : lineMetrics.length;
      final total = advance > 0 ? advance * visualCount : fallbackLineAdvance;

      tops.add(y);
      heights.add(total);
      y += total;
    }
    painter.dispose();

    return EditorLineMetrics(
      tops: tops,
      heights: heights,
      lineAdvance: lineAdvance > 0 ? lineAdvance : fallbackLineAdvance,
    );
  }

  /// 二分查找首个起点 ≥ [y] 的行索引（可能等于 lineCount，由调用方钳位）
  int indexAtOrAfter(double y) {
    var lo = 0;
    var hi = tops.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (tops[mid] < y) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}

class LineNumberGutter extends StatelessWidget {
  final ScrollController editorScrollCtrl;
  final EditorLineMetrics metrics;
  final Set<int> errorLines;
  final int activeLine;
  final ValueChanged<int> onSelectLine;
  final double fontSize;

  const LineNumberGutter({
    super.key,
    required this.editorScrollCtrl,
    required this.metrics,
    required this.errorLines,
    required this.activeLine,
    required this.onSelectLine,
    this.fontSize = 11.5,
  });

  /// 自适应行号宽度：随字号与行数位数动态调整（页面需提前用它算编辑区可用宽度）
  static double widthFor({required int lineCount, required double fontSize}) {
    final count = lineCount < 1 ? 1 : lineCount;
    final digits = count.toString().length;
    return (digits * (fontSize * 0.72) + 26.0).clamp(38.0, 90.0);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final count = metrics.lineCount < 1 ? 1 : metrics.lineCount;
    final gutterWidth = widthFor(lineCount: count, fontSize: fontSize);

    // 行号文字的行盒高度强制等于实测行高 → 与正文同一基线比例，无累积漂移
    final textHeight =
        metrics.lineAdvance > 0 ? metrics.lineAdvance / fontSize : 1.5;

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
                if (height <= 0 || metrics.lineCount == 0) {
                  return const SizedBox.shrink();
                }

                // 仅渲染视口内可见的逻辑行（0-based）；从视口上方最近一行开始，
                // 以覆盖“起于视口上方、仍向下折行进入视口”的长行。
                final startIdx =
                    (metrics.indexAtOrAfter(scrollOffset - AuraSpace.md) - 1)
                        .clamp(0, metrics.lineCount - 1);
                final endIdx = (metrics
                            .indexAtOrAfter(
                                scrollOffset + height - AuraSpace.md) -
                        1)
                    .clamp(startIdx, metrics.lineCount - 1);

                final children = <Widget>[];
                for (int i = startIdx; i <= endIdx; i++) {
                  final lineNum = i + 1;
                  final top = AuraSpace.md +
                      metrics.tops[i] -
                      scrollOffset;
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
                      height: metrics.heights[i],
                      child: InkWell(
                        onTap: () => onSelectLine(lineNum),
                        child: Align(
                          alignment: Alignment.topRight,
                          child: SizedBox(
                            // 行号只占逻辑行首行（换行折出的后续可视行留空）
                            height: metrics.lineAdvance,
                            child: Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
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
                                      fontFamily: monoOf(p, size: fontSize)
                                          .fontFamily,
                                      fontSize: fontSize,
                                      height: textHeight,
                                      forceStrutHeight: true,
                                    ),
                                    style: monoOf(p,
                                            size: fontSize, color: numColor)
                                        .copyWith(
                                      fontWeight: weight,
                                      height: textHeight,
                                    ),
                                  ),
                                ],
                              ),
                            ),
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
