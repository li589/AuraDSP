/*
 * eel_manual_panel.dart — Liveprog IDE EEL2 官方规范全功能参考手册面板与弹窗
 *
 * 功能：
 * - 涵盖 9 大类 80+ 个内置函数与语言特性
 * - 模糊搜索（函数名、签名、中文/英文摘要、说明与关键词）
 * - 分类过滤 Chip 栏
 * - 展开卡片：签名、参数表、返回值、音频原理说明、完整示例
 * - 一键插入代码片段到编辑器
 */

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/liveprog/eel_manual_registry.dart';
import '../../core/theme.dart';
import '../../core/ui_helpers.dart';
import '../chrome.dart';
import '../widgets.dart';

class EelManualPanel extends StatefulWidget {
  final ValueChanged<String>? onInsertSnippet;
  final VoidCallback? onClose;

  const EelManualPanel({
    super.key,
    this.onInsertSnippet,
    this.onClose,
  });

  @override
  State<EelManualPanel> createState() => _EelManualPanelState();
}

class _EelManualPanelState extends State<EelManualPanel> {
  final _searchCtrl = TextEditingController();
  EelManualCategory? _selectedCategory;
  List<EelManualEntry> _filteredEntries = const [];
  final Set<String> _expandedKeys = {};

  @override
  void initState() {
    super.initState();
    _filteredEntries = EelManualRegistry.entries;
    _searchCtrl.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _searchCtrl.removeListener(_onSearchChanged);
    _searchCtrl.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchCtrl.text;
    setState(() {
      _filteredEntries = EelManualRegistry.search(
        query: query,
        category: _selectedCategory,
      );
    });
  }

  void _selectCategory(EelManualCategory? cat) {
    setState(() => _selectedCategory = cat);
    _onSearchChanged();
  }

  void _toggleExpanded(String name) {
    setState(() {
      if (_expandedKeys.contains(name)) {
        _expandedKeys.remove(name);
      } else {
        _expandedKeys.add(name);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final isZh = Localizations.localeOf(context).languageCode.toLowerCase().startsWith('zh');

    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.md),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Top search & control header
          Container(
            padding: const EdgeInsets.fromLTRB(AuraSpace.md, AuraSpace.sm, AuraSpace.md, AuraSpace.xs),
            decoration: BoxDecoration(
              color: p.panelRaised,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(AuraRadius.md)),
              border: Border(bottom: BorderSide(color: p.hairline)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.menu_book_rounded, size: 18, color: p.accent),
                    const SizedBox(width: AuraSpace.xs),
                    Text(l.lpManual, style: sectionOf(p)),
                    const Spacer(),
                    Text(
                      '${_filteredEntries.length} / ${EelManualRegistry.entries.length}',
                      style: monoOf(p, size: 11, color: p.textDim),
                    ),
                    if (widget.onClose != null) ...[
                      const SizedBox(width: AuraSpace.xs),
                      IconButton(
                        tooltip: l.dlgClose,
                        visualDensity: VisualDensity.compact,
                        iconSize: 16,
                        color: p.textDim,
                        icon: const Icon(Icons.close_rounded),
                        onPressed: widget.onClose,
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: AuraSpace.xs),
                // Search field
                TextField(
                  controller: _searchCtrl,
                  style: monoOf(p, size: 12),
                  decoration: InputDecoration(
                    hintText: l.lpManualSearchHint,
                    hintStyle: captionOf(p).copyWith(color: p.textDim.withValues(alpha: 0.5)),
                    filled: true,
                    fillColor: p.panel,
                    prefixIcon: Icon(Icons.search_rounded, size: 16, color: p.textDim),
                    suffixIcon: _searchCtrl.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.clear_rounded, size: 14),
                            onPressed: () => _searchCtrl.clear(),
                          )
                        : null,
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      borderSide: BorderSide(color: p.hairline),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  ),
                ),
                const SizedBox(height: AuraSpace.xs),
                // Categories row
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      AuraChip(
                        l.lpAllCategories,
                        selected: _selectedCategory == null,
                        onTap: () => _selectCategory(null),
                      ),
                      const SizedBox(width: 4),
                      for (final cat in EelManualCategory.values) ...[
                        AuraChip(
                          isZh ? cat.labelZh : cat.labelEn,
                          selected: _selectedCategory == cat,
                          onTap: () => _selectCategory(cat),
                        ),
                        const SizedBox(width: 4),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),

          // Entries list
          Expanded(
            child: _filteredEntries.isEmpty
                ? Center(
                    child: Text(
                      l.lpNoMatches,
                      style: captionOf(p),
                    ),
                  )
                : ListView.builder(
                    itemCount: _filteredEntries.length,
                    padding: const EdgeInsets.all(AuraSpace.sm),
                    itemBuilder: (ctx, idx) {
                      final entry = _filteredEntries[idx];
                      final isExpanded = _expandedKeys.contains(entry.name);
                      final summary = isZh ? entry.summaryZh : entry.summaryEn;
                      final desc = isZh ? entry.descZh : entry.descEn;
                      final catName = isZh ? entry.category.labelZh : entry.category.labelEn;

                      return Container(
                        margin: const EdgeInsets.only(bottom: AuraSpace.xs),
                        decoration: BoxDecoration(
                          color: p.panelRaised,
                          borderRadius: BorderRadius.circular(AuraRadius.sm),
                          border: Border.all(
                            color: isExpanded ? p.accent.withValues(alpha: 0.5) : p.hairline,
                          ),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Header row
                            InkWell(
                              onTap: () => _toggleExpanded(entry.name),
                              borderRadius: BorderRadius.circular(AuraRadius.sm),
                              child: Padding(
                                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                                child: Row(
                                  children: [
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Row(
                                            children: [
                                              Text(
                                                entry.name,
                                                style: monoOf(p, size: 12.5, color: p.accent).copyWith(fontWeight: FontWeight.bold),
                                              ),
                                              const SizedBox(width: 8),
                                              Container(
                                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                                                decoration: BoxDecoration(
                                                  color: p.accent.withValues(alpha: 0.12),
                                                  borderRadius: BorderRadius.circular(3),
                                                ),
                                                child: Text(
                                                  catName,
                                                  style: captionOf(p, color: p.accent).copyWith(fontSize: 10),
                                                ),
                                              ),
                                            ],
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            summary,
                                            style: captionOf(p).copyWith(fontSize: 11),
                                            maxLines: isExpanded ? null : 1,
                                            overflow: isExpanded ? null : TextOverflow.ellipsis,
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      isExpanded ? Icons.expand_less_rounded : Icons.expand_more_rounded,
                                      size: 16,
                                      color: p.textDim,
                                    ),
                                  ],
                                ),
                              ),
                            ),

                            // Expanded details
                            if (isExpanded) ...[
                              Divider(height: 1, color: p.hairline),
                              Padding(
                                padding: const EdgeInsets.all(10),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    // Signature
                                    Container(
                                      width: double.infinity,
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
                                      decoration: BoxDecoration(
                                        color: p.panel,
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(color: p.hairline),
                                      ),
                                      child: SelectableText(
                                        entry.signature,
                                        style: monoOf(p, size: 11.5, color: const Color(0xFF79C0FF)),
                                      ),
                                    ),
                                    const SizedBox(height: 8),

                                    // Detailed explanation
                                    if (desc.isNotEmpty) ...[
                                      Text(desc, style: captionOf(p).copyWith(fontSize: 11.5)),
                                      const SizedBox(height: 8),
                                    ],

                                    // Parameters
                                    if (entry.params.isNotEmpty) ...[
                                      Text(l.lpManualParamTitle, style: labelOf(p).copyWith(fontSize: 11)),
                                      const SizedBox(height: 4),
                                      for (final param in entry.params)
                                        Padding(
                                          padding: const EdgeInsets.only(left: 8, bottom: 2),
                                          child: Row(
                                            crossAxisAlignment: CrossAxisAlignment.start,
                                            children: [
                                              Text(
                                                '${param.name} (${param.type}): ',
                                                style: monoOf(p, size: 11, color: const Color(0xFFFFA657)),
                                              ),
                                              Expanded(
                                                child: Text(
                                                  param.desc,
                                                  style: captionOf(p).copyWith(fontSize: 11),
                                                ),
                                              ),
                                            ],
                                          ),
                                        ),
                                      const SizedBox(height: 8),
                                    ],

                                    // Return value
                                    if (entry.returnDesc.isNotEmpty) ...[
                                      Text(l.lpManualReturnTitle, style: labelOf(p).copyWith(fontSize: 11)),
                                      const SizedBox(height: 2),
                                      Padding(
                                        padding: const EdgeInsets.only(left: 8),
                                        child: Text(
                                          entry.returnDesc,
                                          style: captionOf(p).copyWith(fontSize: 11),
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                    ],

                                    // Code snippet and insert button
                                    if (entry.snippet.isNotEmpty) ...[
                                      Row(
                                        children: [
                                          Text(l.lpManualExampleTitle, style: labelOf(p).copyWith(fontSize: 11)),
                                          const Spacer(),
                                          if (widget.onInsertSnippet != null)
                                            ElevatedButton.icon(
                                              icon: const Icon(Icons.add_circle_outline_rounded, size: 12),
                                              label: Text(l.lpManualInsert),
                                              style: ElevatedButton.styleFrom(
                                                backgroundColor: p.accent,
                                                foregroundColor: p.accentContrast,
                                                visualDensity: VisualDensity.compact,
                                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                              ),
                                              onPressed: () => widget.onInsertSnippet!(entry.snippet),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Container(
                                        width: double.infinity,
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: p.panel,
                                          borderRadius: BorderRadius.circular(4),
                                          border: Border.all(color: p.hairline),
                                        ),
                                        child: SelectableText(
                                          entry.snippet,
                                          style: monoOf(p, size: 11, color: const Color(0xFF7EE787)),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                            ],
                          ],
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// 弹出全功能手册对话框辅助方法
class EelManualDialog {
  static void show(
    BuildContext context, {
    ValueChanged<String>? onInsertSnippet,
  }) {
    showDialog(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        child: SizedBox(
          width: 780,
          height: 600,
          child: EelManualPanel(
            onInsertSnippet: (snippet) {
              Navigator.of(ctx).pop();
              onInsertSnippet?.call(snippet);
            },
            onClose: () => Navigator.of(ctx).pop(),
          ),
        ),
      ),
    );
  }
}
