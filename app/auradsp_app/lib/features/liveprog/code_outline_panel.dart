/*
 * code_outline_panel.dart — Liveprog IDE 代码大纲与符号导航面板
 *
 * 功能：
 * - 实时提取当前代码中的段指令（@init, @sample, @slider, @block）
 * - 提取自定义函数（function fnName(...)）
 * - 提取滑块参数声明（sliderN:...）
 * - 点击项快速跳转至编辑器指定行
 */

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../ui/wheel_scroll.dart';
import '../../core/theme.dart';
import '../../core/ui_helpers.dart';

enum OutlineKind {
  section,
  function,
  slider,
}

class OutlineItem {
  final OutlineKind kind;
  final String label;
  final String? signature;
  final int line; // 1-based

  const OutlineItem({
    required this.kind,
    required this.label,
    this.signature,
    required this.line,
  });
}

class CodeOutlinePanel extends StatefulWidget {
  final String code;
  final int activeLine;
  final ValueChanged<int> onSelectLine;

  const CodeOutlinePanel({
    super.key,
    required this.code,
    required this.activeLine,
    required this.onSelectLine,
  });

  static List<OutlineItem> extractOutline(String source) {
    if (source.isEmpty) return const [];
    final items = <OutlineItem>[];
    final lines = source.replaceAll('\r\n', '\n').split('\n');

    final sectionRe = RegExp(r'^@(init|sample|slider|block)\b');
    final funcRe = RegExp(r'\bfunction\s+([a-zA-Z0-9_]+)\s*\(([^)]*)\)');
    final sliderRe = RegExp(r'^(slider[1-8]):([^\n]+)');

    for (var i = 0; i < lines.length; i++) {
      final lineNum = i + 1;
      final raw = lines[i].trim();
      if (raw.isEmpty || raw.startsWith('//') || raw.startsWith('/*')) continue;

      // Section
      final secMatch = sectionRe.firstMatch(raw);
      if (secMatch != null) {
        items.add(OutlineItem(
          kind: OutlineKind.section,
          label: '@${secMatch.group(1)}',
          line: lineNum,
        ));
        continue;
      }

      // Slider
      final slMatch = sliderRe.firstMatch(raw);
      if (slMatch != null) {
        final sliderId = slMatch.group(1) ?? '';
        final desc = slMatch.group(2) ?? '';
        items.add(OutlineItem(
          kind: OutlineKind.slider,
          label: sliderId,
          signature: desc.length > 28 ? '${desc.substring(0, 25)}...' : desc,
          line: lineNum,
        ));
        continue;
      }

      // Function
      final fnMatch = funcRe.firstMatch(raw);
      if (fnMatch != null) {
        final fnName = fnMatch.group(1) ?? '';
        final args = fnMatch.group(2) ?? '';
        items.add(OutlineItem(
          kind: OutlineKind.function,
          label: fnName,
          signature: '($args)',
          line: lineNum,
        ));
      }
    }

    return items;
  }

  @override
  State<CodeOutlinePanel> createState() => _CodeOutlinePanelState();
}

class _CodeOutlinePanelState extends State<CodeOutlinePanel> {
  /// 大纲列表滚动控制器（2026-10-28：滚轮不带动整页）。
  final ScrollController _outlineScrollCtrl = ScrollController();

  late List<OutlineItem> _items;
  Timer? _debounceTimer;

  @override
  void initState() {
    super.initState();
    _items = CodeOutlinePanel.extractOutline(widget.code);
  }

  @override
  void didUpdateWidget(covariant CodeOutlinePanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.code != widget.code) {
      _debounceTimer?.cancel();
      if (widget.code.length < 500) {
        _items = CodeOutlinePanel.extractOutline(widget.code);
      } else {
        _debounceTimer = Timer(const Duration(milliseconds: 150), () {
          if (mounted) {
            setState(() {
              _items = CodeOutlinePanel.extractOutline(widget.code);
            });
          }
        });
      }
    }
  }

  @override
  void dispose() {
    _outlineScrollCtrl.dispose();
    _debounceTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final items = _items;

    return Container(
      decoration: BoxDecoration(
        color: p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: AuraSpace.xs + 2),
            decoration: BoxDecoration(
              color: p.panel,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(AuraRadius.sm)),
              border: Border(bottom: BorderSide(color: p.hairline)),
            ),
            child: Row(
              children: [
                Icon(Icons.list_alt_rounded, size: 14, color: p.accent),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    l.lpOutline,
                    style: labelOf(p),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  '${items.length}',
                  style: monoOf(p, size: 10, color: p.textDim),
                ),
              ],
            ),
          ),

          // Content list
          Expanded(
            child: items.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AuraSpace.md),
                      child: Text(
                        l.lpOutlineEmpty,
                        textAlign: TextAlign.center,
                        style: captionOf(p),
                      ),
                    ),
                  )
                : Scrollbar(
                    controller: _outlineScrollCtrl,
                    thumbVisibility: true,
                    child: ListView.builder(
                    controller: _outlineScrollCtrl,
                    physics: const AuraListScrollPhysics(),
                    itemCount: items.length,
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemBuilder: (ctx, idx) {
                      final item = items[idx];
                      final isSelected = widget.activeLine == item.line;

                      final (icon, iconColor) = switch (item.kind) {
                        OutlineKind.section => (Icons.tag_rounded, p.accent),
                        OutlineKind.function => (Icons.functions_rounded, const Color(0xFF79C0FF)),
                        OutlineKind.slider => (Icons.tune_rounded, const Color(0xFF7EE787)),
                      };

                      return InkWell(
                        onTap: () => widget.onSelectLine(item.line),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: 5),
                          color: isSelected ? p.accent.withValues(alpha: 0.12) : Colors.transparent,
                          child: Row(
                            children: [
                              Icon(icon, size: 13, color: iconColor),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text.rich(
                                  TextSpan(
                                    text: item.label,
                                    style: monoOf(
                                      p,
                                      size: 11,
                                      color: isSelected ? p.accent : p.text,
                                    ).copyWith(
                                      fontWeight: item.kind == OutlineKind.section
                                          ? FontWeight.bold
                                          : FontWeight.normal,
                                    ),
                                    children: [
                                      if (item.signature != null && item.signature!.isNotEmpty)
                                        TextSpan(
                                          text: ' ${item.signature}',
                                          style: monoOf(p, size: 10, color: p.textDim),
                                        ),
                                    ],
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                              Text(
                                '${item.line}',
                                style: monoOf(p, size: 9.5, color: p.textDim),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}
