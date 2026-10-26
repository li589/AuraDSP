/*
 * liveprog_library_dialog.dart — Liveprog EEL2 脚本库与外部目录管理弹窗
 *
 * 核心功能：
 * 1. 聚合展示内置模板与外部目录中扫描到的脚本条目。
 * 2. 外部目录列表展示，每次打开异步检测目录有效性（红标提示已失效目录）。
 * 3. 支持使用系统文件管理器（Windows 资源管理器等）浏览外部目录。
 * 4. 统一使用 AuraPathPickerDialog 选取添加外部目录，并单独记忆路径。
 * 5. 支持将当前代码保存到库（重名提醒是否覆盖）。
 */
import 'dart:io';

import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/error_sink.dart';
import '../../../core/path_memory.dart';
import '../../../core/state.dart';
import '../../../core/theme.dart';
import '../../../core/ui_helpers.dart';
import '../../../ui/path_picker_dialog.dart';
import '../../chrome.dart';
import '../liveprog_library.dart';

class LiveprogLibraryDialog extends StatefulWidget {
  final AppModel model;
  final String currentCode;
  final bool isCodeDirty;
  final void Function(String scriptText, String scriptName) onSelectScript;

  const LiveprogLibraryDialog({
    super.key,
    required this.model,
    required this.currentCode,
    required this.isCodeDirty,
    required this.onSelectScript,
  });

  static Future<void> show(
    BuildContext context, {
    required AppModel model,
    required String currentCode,
    required bool isCodeDirty,
    required void Function(String scriptText, String scriptName) onSelectScript,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => LiveprogLibraryDialog(
        model: model,
        currentCode: currentCode,
        isCodeDirty: isCodeDirty,
        onSelectScript: onSelectScript,
      ),
    );
  }

  /// 统一的重名覆盖提醒对话框
  static Future<bool> confirmOverwrite(
    BuildContext context,
    String fileName,
  ) async {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: p.panel,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AuraRadius.md),
          side: BorderSide(color: p.hairline),
        ),
        title: Text(l.lpFileOverwriteConfirmTitle, style: sectionOf(p)),
        content: Text(
          l.lpFileOverwriteConfirmBody(fileName),
          style: labelOf(p),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(l.dlgCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(backgroundColor: p.warning),
            child: Text(l.lpFileOverwriteConfirmAction),
          ),
        ],
      ),
    );
    return result ?? false;
  }

  @override
  State<LiveprogLibraryDialog> createState() => _LiveprogLibraryDialogState();
}

class _LiveprogLibraryDialogState extends State<LiveprogLibraryDialog> {
  final TextEditingController _saveNameController =
      TextEditingController(text: 'my-script');
  List<LiveprogItem> _items = const [];
  int _skippedCount = 0;

  // 异步检测目录存在性缓存：dirPath -> exists
  Map<String, bool> _dirExistence = {};
  bool _checkingDirs = false;

  @override
  void initState() {
    super.initState();
    _refreshList();
    _checkDirsAsync();
  }

  @override
  void dispose() {
    _saveNameController.dispose();
    super.dispose();
  }

  void _refreshList() {
    final all = LiveprogLibrary.listAll(widget.model.config.customScriptDirs);
    setState(() {
      _items = all;
      _skippedCount = LiveprogLibrary.lastSkipped;
    });
  }

  /// 每次打开或变更后异步检测外部目录是否存在
  Future<void> _checkDirsAsync() async {
    setState(() => _checkingDirs = true);
    final dirs = widget.model.config.customScriptDirs;
    final results = <String, bool>{};

    for (final d in dirs) {
      try {
        final dir = Directory(d);
        results[d] = await dir.exists();
      } catch (e, st) {
        swallow(e, st);
        results[d] = false;
      }
    }

    if (mounted) {
      setState(() {
        _dirExistence = results;
        _checkingDirs = false;
      });
    }
  }

  /// 打开目标平台文件管理器
  Future<void> _browseInFileManager(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer.exe', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else if (Platform.isLinux) {
        await Process.run('xdg-open', [path]);
      }
    } catch (e, st) {
      swallow(e, st);
    }
  }

  /// 添加外部目录（统一选择 UI + 单独记忆）
  Future<void> _addDirectory() async {
    final l = l10nOf(context);
    final selectedDir = await AuraPathPickerDialog.show(
      context,
      title: l.lpAddDir,
      mode: AuraPathPickerMode.directory,
      memorySlot: PathMemory.slotLiveprogAddDir,
    );

    if (selectedDir != null && selectedDir.trim().isNotEmpty) {
      widget.model.addCustomScriptDir(selectedDir.trim());
      _refreshList();
      _checkDirsAsync();
    }
  }

  /// 保存当前脚本到库
  Future<void> _saveCurrentScript() async {
    final l = l10nOf(context);
    final rawName = _saveNameController.text.trim();
    if (rawName.isEmpty) return;

    final fileName = rawName.endsWith('.eel') || rawName.endsWith('.txt')
        ? rawName
        : '$rawName.eel';

    final destPath = '${LiveprogLibrary.dir}${Platform.pathSeparator}$fileName';
    final destFile = File(destPath);

    if (destFile.existsSync()) {
      final confirm = await LiveprogLibraryDialog.confirmOverwrite(
        context,
        fileName,
      );
      if (!confirm) return;
    }

    final ok = LiveprogLibrary.save(fileName, widget.currentCode);
    if (ok) {
      _refreshList();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.lpSave),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(l.errIoFailed),
            duration: const Duration(seconds: 2),
          ),
        );
      }
    }
  }

  /// 选中脚本加载
  Future<void> _onSelect(LiveprogItem item) async {
    final l = l10nOf(context);
    if (widget.isCodeDirty) {
      final discard = await showDialog<bool>(
        context: context,
        builder: (ctx) {
          final p = paletteOf(ctx);
          return AlertDialog(
            backgroundColor: p.panel,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(AuraRadius.md),
              side: BorderSide(color: p.hairline),
            ),
            title: Text(l.lpConfirmDiscardTitle, style: sectionOf(p)),
            content: Text(l.lpConfirmDiscardBody, style: labelOf(p)),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(l.dlgCancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                style: FilledButton.styleFrom(backgroundColor: p.warning),
                child: Text(l.lpConfirmDiscardAction),
              ),
            ],
          );
        },
      );
      if (discard != true) return;
    }

    final content = await LiveprogLibrary.loadFromPath(item.path);
    if (content != null && mounted) {
      widget.onSelectScript(content, item.name);
      Navigator.of(context).pop();
    }
  }

  Future<void> _renameItem(LiveprogItem item) async {
    final l = l10nOf(context);
    final controller = TextEditingController(text: item.name);
    final res = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final p = paletteOf(ctx);
        return AlertDialog(
          backgroundColor: p.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.md),
            side: BorderSide(color: p.hairline),
          ),
          title: Text(l.lpRenameTitle, style: sectionOf(p)),
          content: TextField(
            controller: controller,
            autofocus: true,
            style: monoOf(p, size: 12.5),
            decoration: InputDecoration(
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(AuraRadius.sm),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l.dlgCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
              child: Text(l.pathPickerConfirm),
            ),
          ],
        );
      },
    );

    if (res != null && res.isNotEmpty && res != item.name) {
      final ok = LiveprogLibrary.renamePath(
        item.path,
        res,
        widget.model.config.customScriptDirs,
      );
      if (ok) _refreshList();
    }
  }

  Future<void> _deleteItem(LiveprogItem item) async {
    final l = l10nOf(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final p = paletteOf(ctx);
        return AlertDialog(
          backgroundColor: p.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.md),
            side: BorderSide(color: p.hairline),
          ),
          title: Text(l.lpDeleteTitle, style: sectionOf(p)),
          content: Text('${item.name}\n${l.lpDeleteBody}', style: labelOf(p)),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text(l.dlgCancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              style: FilledButton.styleFrom(backgroundColor: p.error),
              child: Text(l.lpDeleteAction),
            ),
          ],
        );
      },
    );

    if (confirm == true) {
      final ok = LiveprogLibrary.deletePath(
        item.path,
        widget.model.config.customScriptDirs,
      );
      if (ok) _refreshList();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final customDirs = widget.model.config.customScriptDirs;

    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AuraRadius.md),
        side: BorderSide(color: p.hairline),
      ),
      titlePadding: const EdgeInsets.fromLTRB(
          AuraSpace.md, AuraSpace.md, AuraSpace.md, AuraSpace.xs),
      contentPadding: const EdgeInsets.symmetric(horizontal: AuraSpace.md),
      actionsPadding: const EdgeInsets.fromLTRB(
          AuraSpace.md, AuraSpace.xs, AuraSpace.md, AuraSpace.md),
      title: Row(
        children: [
          Icon(Icons.library_books_rounded, size: 20, color: p.accent),
          const SizedBox(width: AuraSpace.xs),
          Expanded(
            child: Text(
              l.lpLibDialogTitle,
              style: sectionOf(p),
            ),
          ),
          if (_checkingDirs) ...[
            const SizedBox(width: AuraSpace.xs),
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: p.accent,
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
          ],
          IconButton(
            icon: const Icon(Icons.close_rounded, size: 16),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            tooltip: l.dlgClose,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      content: SizedBox(
        width: 680,
        height: 520,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 外部目录管理行
            Row(
              children: [
                Icon(Icons.folder_shared_outlined, size: 16, color: p.accent),
                const SizedBox(width: AuraSpace.xs),
                Expanded(
                  child: Text(
                    l.lpLibCustomDirs,
                    style: monoOf(p, size: 12, color: p.text),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AuraSpace.xs),
                OutlinedButton.icon(
                  onPressed: _addDirectory,
                  icon: const Icon(Icons.create_new_folder_rounded, size: 14),
                  label: Text(l.lpAddDir),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.accent,
                    side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
              ],
            ),
            const SizedBox(height: AuraSpace.xs),

            // 外部目录列表（异步检测存在性 + 浏览按键）
            if (customDirs.isNotEmpty) ...[
              Container(
                constraints: const BoxConstraints(maxHeight: 120),
                decoration: BoxDecoration(
                  color: p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: customDirs.length,
                  separatorBuilder: (_, _) =>
                      Divider(color: p.hairline, height: 1),
                  itemBuilder: (ctx, idx) {
                    final d = customDirs[idx];
                    final exists = _dirExistence[d] ?? true;
                    return Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: AuraSpace.sm, vertical: 4),
                      child: Row(
                        children: [
                          Icon(
                            exists
                                ? Icons.folder_outlined
                                : Icons.folder_off_outlined,
                            size: 15,
                            color: exists ? p.accent : p.error,
                          ),
                          const SizedBox(width: AuraSpace.xs),
                          Expanded(
                            child: Text(
                              d,
                              style: monoOf(p,
                                  size: 11,
                                  color: exists ? p.text : p.error),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          if (!exists) ...[
                            const SizedBox(width: AuraSpace.xs),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 4, vertical: 1),
                              decoration: BoxDecoration(
                                color: p.error.withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: Text(
                                l.lpLibDirInvalid,
                                style: TextStyle(fontSize: 10, color: p.error),
                              ),
                            ),
                          ],
                          const SizedBox(width: AuraSpace.xs),
                          // 浏览：打开平台文件管理器
                          IconButton(
                            tooltip: l.lpLibOpenInExplorer,
                            icon: const Icon(Icons.open_in_new_rounded,
                                size: 14),
                            visualDensity: VisualDensity.compact,
                            color: p.textDim,
                            onPressed: () => _browseInFileManager(d),
                          ),
                          // 移除外部目录
                          IconButton(
                            tooltip: l.lpDeleteAction,
                            icon: const Icon(Icons.close_rounded, size: 14),
                            visualDensity: VisualDensity.compact,
                            color: p.textDim,
                            onPressed: () {
                              widget.model.removeCustomScriptDir(d);
                              _refreshList();
                              _checkDirsAsync();
                            },
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: AuraSpace.sm),
            ],

            // 脚本列表区
            Text(
              l.lpLibrary,
              style: monoOf(p, size: 12, color: p.text),
            ),
            const SizedBox(height: AuraSpace.xs),
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                child: _items.isEmpty
                    ? Center(
                        child: Text(l.lpLibraryEmpty, style: captionOf(p)),
                      )
                    : ListView.builder(
                        itemCount: _items.length,
                        itemBuilder: (ctx, idx) {
                          final item = _items[idx];
                          return ListTile(
                            dense: true,
                            leading: Icon(
                              item.isExternal
                                  ? Icons.folder_shared_rounded
                                  : Icons.description_outlined,
                              size: 16,
                              color: p.accent,
                            ),
                            title: Text(
                              item.isExternal
                                  ? '${item.name} [${item.folderName}]'
                                  : item.name,
                              style: monoOf(p, size: 12),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  tooltip: l.lpRenameTitle,
                                  visualDensity: VisualDensity.compact,
                                  iconSize: 14,
                                  color: p.textDim,
                                  icon: const Icon(
                                      Icons.drive_file_rename_outline_rounded),
                                  onPressed: () => _renameItem(item),
                                ),
                                IconButton(
                                  tooltip: l.lpDeleteTitle,
                                  visualDensity: VisualDensity.compact,
                                  iconSize: 14,
                                  color: p.textDim,
                                  icon: const Icon(Icons.delete_outline_rounded),
                                  onPressed: () => _deleteItem(item),
                                ),
                              ],
                            ),
                            onTap: () => _onSelect(item),
                          );
                        },
                      ),
              ),
            ),

            if (_skippedCount > 0) ...[
              const SizedBox(height: AuraSpace.xs),
              Row(
                children: [
                  Icon(Icons.shield_outlined, size: 12, color: p.warning),
                  const SizedBox(width: 4),
                  Text(
                    l.lpSkipped(_skippedCount),
                    style: captionOf(p, color: p.warning),
                  ),
                ],
              ),
            ],

            const SizedBox(height: AuraSpace.sm),
            Divider(color: p.hairline, height: 1),
            const SizedBox(height: AuraSpace.sm),

            // 保存当前代码到库
            Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _saveNameController,
                    style: monoOf(p, size: 12.5, color: p.text),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: 'my-script',
                      hintStyle: monoOf(p, size: 12.5, color: p.textDim),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.md,
                        vertical: AuraSpace.sm,
                      ),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(AuraRadius.sm),
                        borderSide: BorderSide(color: p.hairline),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: AuraSpace.sm),
                AuraChip(
                  l.lpLibSaveCurrent,
                  icon: Icons.save_outlined,
                  onTap: _saveCurrentScript,
                ),
              ],
            ),
          ],
        ),
      ),
      actions: [
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(l.dlgClose),
        ),
      ],
    );
  }
}
