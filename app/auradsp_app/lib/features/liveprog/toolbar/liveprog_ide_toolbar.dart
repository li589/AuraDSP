/*
 * liveprog_ide_toolbar.dart — EEL2 IDE 统一顶栏工具行（7大核心操作区）
 *
 * 布局组织：
 * 1. 应用：未应用 / 已应用 状态切换；代码修改未编译时强制置灰禁用。
 * 2. 编译：代码编译（隔离异常）。
 * 3. 文件下拉：新建空白、从模板新建、导入 APO、导入 EEL、另存为。
 * 4. 脚本库：打开独立脚本库管理弹窗。
 * 5. 编辑下拉：查找替换、代码大纲、格式化、跳回开头。
 * 6. 手册：EEL2 规范参考手册。
 * 7. 控制台：切换控制台诊断面板展示。
 */
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../chrome.dart';

enum LiveprogFileAction {
  newBlank,
  newFromTemplate,
  importApo,
  importEel,
  saveAs,
}

enum LiveprogEditAction {
  findReplace,
  toggleOutline,
  format,
  scrollToTop,
}

class LiveprogIdeToolbar extends StatelessWidget {
  final bool isApplied;
  final bool isCompiling;
  final bool isCodeDirty;
  final bool isConsoleOpen;
  final bool isOutlineOpen;
  final bool isFindReplaceOpen;
  final bool isEditorExpanded;

  final VoidCallback onToggleApply;
  final VoidCallback onCompile;
  final void Function(LiveprogFileAction action) onFileAction;
  final VoidCallback onOpenLibrary;
  final void Function(LiveprogEditAction action) onEditAction;
  final VoidCallback onOpenManual;
  final VoidCallback onToggleConsole;
  final VoidCallback onToggleEditorExpand;

  const LiveprogIdeToolbar({
    super.key,
    required this.isApplied,
    required this.isCompiling,
    required this.isCodeDirty,
    required this.isConsoleOpen,
    required this.isOutlineOpen,
    required this.isFindReplaceOpen,
    required this.isEditorExpanded,
    required this.onToggleApply,
    required this.onCompile,
    required this.onFileAction,
    required this.onOpenLibrary,
    required this.onEditAction,
    required this.onOpenManual,
    required this.onToggleConsole,
    required this.onToggleEditorExpand,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = AppLocalizations.of(context)!;

    final canApply = !isCodeDirty && !isCompiling;

    return Wrap(
      spacing: AuraSpace.sm,
      runSpacing: AuraSpace.sm,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        // 1. 应用按钮（在未应用和已应用中切换显示；若代码修改后未编译则禁用）
        Tooltip(
          message: canApply
              ? ''
              : (isCompiling ? l.lpCompiling : l.lpTooltipCompileFirst),
          child: IgnorePointer(
            ignoring: !canApply,
            child: Opacity(
              opacity: canApply ? 1.0 : 0.4,
              child: AuraChip(
                isApplied ? l.lpBtnApplied : l.lpBtnUnapplied,
                icon: isApplied ? Icons.power_settings_new_rounded : Icons.play_arrow_rounded,
                selected: isApplied,
                onTap: onToggleApply,
              ),
            ),
          ),
        ),

        // 2. 编译按钮（防崩溃异常文本安全隔离）
        AuraChip(
          l.lpBtnCompile,
          icon: isCompiling ? Icons.sync_rounded : Icons.build_circle_outlined,
          busy: isCompiling,
          onTap: isCompiling ? null : onCompile,
        ),

        // 3. 文件下拉菜单
        _buildDropdownChip<LiveprogFileAction>(
          context: context,
          label: l.lpMenuFile,
          icon: Icons.folder_open_rounded,
          items: [
            PopupMenuItem(
              value: LiveprogFileAction.newBlank,
              child: _buildMenuItem(
                p,
                Icons.note_add_outlined,
                l.lpFileNewBlank,
              ),
            ),
            PopupMenuItem(
              value: LiveprogFileAction.newFromTemplate,
              child: _buildMenuItem(
                p,
                Icons.auto_stories_rounded,
                l.lpFileNewFromTemplate,
              ),
            ),
            const PopupMenuDivider(height: 1),
            PopupMenuItem(
              value: LiveprogFileAction.importApo,
              child: _buildMenuItem(
                p,
                Icons.transform_rounded,
                l.lpFileImportApo,
              ),
            ),
            PopupMenuItem(
              value: LiveprogFileAction.importEel,
              child: _buildMenuItem(
                p,
                Icons.file_open_outlined,
                l.lpFileImportEel,
              ),
            ),
            const PopupMenuDivider(height: 1),
            PopupMenuItem(
              value: LiveprogFileAction.saveAs,
              child: _buildMenuItem(
                p,
                Icons.save_as_outlined,
                l.lpFileSaveAs,
              ),
            ),
          ],
          onSelected: onFileAction,
        ),

        // 4. 脚本库按钮
        AuraChip(
          l.lpBtnLibrary,
          icon: Icons.library_books_rounded,
          onTap: onOpenLibrary,
        ),

        // 5. 编辑下拉菜单
        _buildDropdownChip<LiveprogEditAction>(
          context: context,
          label: l.lpMenuEdit,
          icon: Icons.edit_note_rounded,
          items: [
            PopupMenuItem(
              value: LiveprogEditAction.findReplace,
              child: _buildMenuItem(
                p,
                Icons.search_rounded,
                l.lpEditFindReplace,
                checked: isFindReplaceOpen,
              ),
            ),
            PopupMenuItem(
              value: LiveprogEditAction.toggleOutline,
              child: _buildMenuItem(
                p,
                Icons.account_tree_outlined,
                l.lpEditToggleOutline,
                checked: isOutlineOpen,
              ),
            ),
            const PopupMenuDivider(height: 1),
            PopupMenuItem(
              value: LiveprogEditAction.format,
              child: _buildMenuItem(
                p,
                Icons.format_align_left_rounded,
                l.lpEditFormat,
              ),
            ),
            PopupMenuItem(
              value: LiveprogEditAction.scrollToTop,
              child: _buildMenuItem(
                p,
                Icons.vertical_align_top_rounded,
                l.lpEditScrollToTop,
              ),
            ),
          ],
          onSelected: onEditAction,
        ),

        // 6. 手册按钮
        AuraChip(
          l.lpManual,
          icon: Icons.menu_book_rounded,
          onTap: onOpenManual,
        ),

        // 7. 控制台按钮
        AuraChip(
          l.lpConsole,
          icon: Icons.terminal_rounded,
          selected: isConsoleOpen,
          onTap: onToggleConsole,
        ),

        // 辅助：编辑器高度展开/收起
        AuraChip(
          isEditorExpanded ? l.lpCollapseEditor : l.lpExpandEditor,
          icon: isEditorExpanded
              ? Icons.unfold_less_rounded
              : Icons.unfold_more_rounded,
          onTap: onToggleEditorExpand,
        ),
      ],
    );
  }

  Widget _buildDropdownChip<T>({
    required BuildContext context,
    required String label,
    required IconData icon,
    required List<PopupMenuEntry<T>> items,
    required void Function(T value) onSelected,
  }) {
    final p = paletteOf(context);
    return Theme(
      data: Theme.of(context).copyWith(
        popupMenuTheme: PopupMenuThemeData(
          color: p.panelRaised,
          surfaceTintColor: Colors.transparent,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            side: BorderSide(color: p.hairline),
          ),
          elevation: 6,
        ),
      ),
      child: PopupMenuButton<T>(
        tooltip: '',
        offset: const Offset(0, 36),
        itemBuilder: (context) => items,
        onSelected: onSelected,
        child: AuraChip(
          label,
          icon: icon,
        ),
      ),
    );
  }

  Widget _buildMenuItem(
    AuraPalette p,
    IconData icon,
    String text, {
    bool? checked,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: p.textDim),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            style: labelOf(p, size: 12.5),
          ),
        ),
        if (checked != null) ...[
          const SizedBox(width: 8),
          Icon(
            checked ? Icons.check_rounded : Icons.check_box_outline_blank_rounded,
            size: 14,
            color: checked ? p.accent : p.textDim.withValues(alpha: 0.3),
          ),
        ],
      ],
    );
  }
}
