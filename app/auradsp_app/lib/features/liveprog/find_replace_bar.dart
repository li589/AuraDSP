/*
 * find_replace_bar.dart — Liveprog IDE 查找与替换工具条
 *
 * 支持：
 * - 查找文本与替换文本输入
 * - 区分大小写开关
 * - 实时匹配统计（第 N 项，共 M 项）
 * - 上一个 / 下一个快捷跳转
 * - 单处替换与全部替换
 * - 快捷键：Enter（下一个）、Shift+Enter（上一个）、Esc（关闭）
 */

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/design.dart';
import '../../core/theme.dart';
import '../../core/ui_helpers.dart';

class FindReplaceBar extends StatefulWidget {
  final TextEditingController codeController;
  final VoidCallback? onTextModified;
  final VoidCallback? onClose;

  const FindReplaceBar({
    super.key,
    required this.codeController,
    this.onTextModified,
    this.onClose,
  });

  @override
  State<FindReplaceBar> createState() => FindReplaceBarState();
}

class FindReplaceBarState extends State<FindReplaceBar> {
  final _findFocus = FocusNode();
  final _replaceFocus = FocusNode();
  final _findCtrl = TextEditingController();
  final _replaceCtrl = TextEditingController();

  bool _matchCase = false;
  bool _showReplace = true;
  List<(int, int)> _matches = const [];
  int _currentIndex = -1;

  @override
  void initState() {
    super.initState();
    _findCtrl.addListener(_performSearch);
    widget.codeController.addListener(_onCodeChangedExternally);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _findFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _findCtrl.removeListener(_performSearch);
    widget.codeController.removeListener(_onCodeChangedExternally);
    _findFocus.dispose();
    _replaceFocus.dispose();
    _findCtrl.dispose();
    _replaceCtrl.dispose();
    super.dispose();
  }

  void _onCodeChangedExternally() {
    if (_findCtrl.text.isNotEmpty) {
      _performSearch();
    }
  }

  void _performSearch() {
    final query = _findCtrl.text;
    final text = widget.codeController.text;
    if (query.isEmpty || text.isEmpty) {
      setState(() {
        _matches = const [];
        _currentIndex = -1;
      });
      return;
    }

    final newMatches = <(int, int)>[];
    var start = 0;
    while (start < text.length) {
      final idx = _matchCase
          ? text.indexOf(query, start)
          : text.toLowerCase().indexOf(query.toLowerCase(), start);
      if (idx < 0) break;
      newMatches.add((idx, idx + query.length));
      start = idx + query.length;
    }

    // Determine current index based on current selection
    final sel = widget.codeController.selection;
    var foundIdx = -1;
    if (newMatches.isNotEmpty) {
      if (sel.isValid) {
        for (var i = 0; i < newMatches.length; i++) {
          if (newMatches[i].$1 >= sel.start) {
            foundIdx = i;
            break;
          }
        }
      }
      if (foundIdx < 0) foundIdx = 0;
    }

    setState(() {
      _matches = newMatches;
      _currentIndex = foundIdx;
    });

    if (foundIdx >= 0 && foundIdx < newMatches.length) {
      _highlightMatch(foundIdx);
    }
  }

  void _highlightMatch(int index) {
    if (index < 0 || index >= _matches.length) return;
    final m = _matches[index];
    widget.codeController.selection = TextSelection(
      baseOffset: m.$1,
      extentOffset: m.$2,
    );
  }

  void nextMatch() {
    if (_matches.isEmpty) return;
    final next = (_currentIndex + 1) % _matches.length;
    setState(() => _currentIndex = next);
    _highlightMatch(next);
  }

  void previousMatch() {
    if (_matches.isEmpty) return;
    final prev = (_currentIndex - 1 + _matches.length) % _matches.length;
    setState(() => _currentIndex = prev);
    _highlightMatch(prev);
  }

  void replaceCurrent() {
    if (_matches.isEmpty || _currentIndex < 0 || _currentIndex >= _matches.length) {
      return;
    }
    final target = _matches[_currentIndex];
    final fullText = widget.codeController.text;
    final replacement = _replaceCtrl.text;

    final updated = fullText.substring(0, target.$1) +
        replacement +
        fullText.substring(target.$2);

    widget.codeController.value = TextEditingValue(
      text: updated,
      selection: TextSelection.collapsed(offset: target.$1 + replacement.length),
    );
    widget.onTextModified?.call();
    _performSearch();
  }

  void replaceAll() {
    final query = _findCtrl.text;
    if (query.isEmpty || _matches.isEmpty) return;

    final fullText = widget.codeController.text;
    final replacement = _replaceCtrl.text;

    final String updated;
    if (_matchCase) {
      updated = fullText.replaceAll(query, replacement);
    } else {
      updated = fullText.replaceAll(RegExp(RegExp.escape(query), caseSensitive: false), replacement);
    }

    widget.codeController.value = TextEditingValue(
      text: updated,
      selection: const TextSelection.collapsed(offset: 0),
    );
    widget.onTextModified?.call();
    _performSearch();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.escape): () => widget.onClose?.call(),
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: AuraSpace.xs),
        padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: AuraSpace.xs + 2),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(color: p.hairline),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 8,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Row 1: Find row
            Row(
              children: [
                Icon(Icons.search_rounded, size: 16, color: p.textDim),
                const SizedBox(width: AuraSpace.xs),
                Expanded(
                  child: SizedBox(
                    height: 28,
                    child: TextField(
                      controller: _findCtrl,
                      focusNode: _findFocus,
                      style: monoOf(p, size: 12),
                      decoration: InputDecoration(
                        hintText: l.lpFind,
                        hintStyle: monoOf(p, size: 12, color: p.textDim),
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 6),
                      ),
                      onSubmitted: (_) {
                        if (HardwareKeyboard.instance.isShiftPressed) {
                          previousMatch();
                        } else {
                          nextMatch();
                        }
                        _findFocus.requestFocus();
                      },
                    ),
                  ),
                ),
                // Match counter
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  child: Text(
                    _findCtrl.text.isEmpty
                        ? ''
                        : (_matches.isEmpty
                            ? l.lpNoMatches
                            : l.lpMatchCount(_currentIndex + 1, _matches.length)),
                    style: monoOf(p, size: 11, color: _matches.isEmpty ? p.error : p.textDim),
                  ),
                ),
                // Match case toggle
                IconButton(
                  tooltip: l.lpMatchCase,
                  visualDensity: VisualDensity.compact,
                  iconSize: 15,
                  color: _matchCase ? p.accent : p.textDim,
                  icon: const Text('Aa', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 12)),
                  onPressed: () {
                    setState(() => _matchCase = !_matchCase);
                    _performSearch();
                  },
                ),
                // Prev button
                IconButton(
                  tooltip: l.lpFindPrev,
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: _matches.isEmpty ? p.textDim.withValues(alpha: 0.3) : p.text,
                  icon: const Icon(Icons.keyboard_arrow_up_rounded),
                  onPressed: _matches.isEmpty ? null : previousMatch,
                ),
                // Next button
                IconButton(
                  tooltip: l.lpFindNext,
                  visualDensity: VisualDensity.compact,
                  iconSize: 16,
                  color: _matches.isEmpty ? p.textDim.withValues(alpha: 0.3) : p.text,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  onPressed: _matches.isEmpty ? null : nextMatch,
                ),
                // Toggle replace row button
                IconButton(
                  tooltip: l.lpReplace,
                  visualDensity: VisualDensity.compact,
                  iconSize: 15,
                  color: _showReplace ? p.accent : p.textDim,
                  icon: const Icon(Icons.find_replace_rounded),
                  onPressed: () => setState(() => _showReplace = !_showReplace),
                ),
                // Close button
                IconButton(
                  tooltip: l.dlgClose,
                  visualDensity: VisualDensity.compact,
                  iconSize: 15,
                  color: p.textDim,
                  icon: const Icon(Icons.close_rounded),
                  onPressed: widget.onClose,
                ),
              ],
            ),

            // Row 2: Replace row (collapsible)
            if (_showReplace) ...[
              const SizedBox(height: 2),
              Divider(height: 1, color: p.hairline.withValues(alpha: 0.5)),
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(Icons.edit_note_rounded, size: 16, color: p.textDim),
                  const SizedBox(width: AuraSpace.xs),
                  Expanded(
                    child: SizedBox(
                      height: 28,
                      child: TextField(
                        controller: _replaceCtrl,
                        focusNode: _replaceFocus,
                        style: monoOf(p, size: 12),
                        decoration: InputDecoration(
                          hintText: l.lpReplace,
                          hintStyle: monoOf(p, size: 12, color: p.textDim),
                          isDense: true,
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.symmetric(vertical: 6),
                        ),
                        onSubmitted: (_) => replaceCurrent(),
                      ),
                    ),
                  ),
                  // Replace button
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: p.text,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: _matches.isEmpty ? null : replaceCurrent,
                    child: Text(l.lpReplace, style: captionOf(p)),
                  ),
                  // Replace All button
                  TextButton(
                    style: TextButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      foregroundColor: p.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                    ),
                    onPressed: _matches.isEmpty ? null : replaceAll,
                    child: Text(l.lpReplaceAll, style: captionOf(p, color: p.accent)),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
