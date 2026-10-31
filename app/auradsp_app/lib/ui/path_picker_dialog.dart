/*
 * path_picker_dialog.dart — 统一外部文件/路径选择对话框
 *
 * 统一所有外部文件（VDC、IR脉冲、AutoEq曲线、预设、脚本、插件目录）的输入与选择入口：
 * 1. 支持手动键入/粘贴绝对路径；
 * 2. 左下角提供标准文件夹/文件图标按钮，调用原生系统文件/文件夹管理器；
 * 3. 集成存在性检测、扩展名校验与 PathMemory 自动记忆；
 * 4. 统一 UI 样式，遵循 AuraDSP 设计系统。
 */
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/path_memory.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';
import '../platform/platform_profile.dart';

enum AuraPathPickerMode {
  file,
  directory,
}

class AuraPathPickerDialog extends StatefulWidget {
  final String title;
  final String? prompt;
  final String? initialPath;
  final AuraPathPickerMode mode;
  final List<String>? allowedExtensions;
  final String? memorySlot;
  final String? confirmLabel;

  const AuraPathPickerDialog({
    super.key,
    required this.title,
    this.prompt,
    this.initialPath,
    this.mode = AuraPathPickerMode.file,
    this.allowedExtensions,
    this.memorySlot,
    this.confirmLabel,
  });

  /// 静态辅助方法：显示弹窗并返回有效路径（用户取消或关闭返回 null）
  static Future<String?> show(
    BuildContext context, {
    required String title,
    String? prompt,
    String? initialPath,
    AuraPathPickerMode mode = AuraPathPickerMode.file,
    List<String>? allowedExtensions,
    String? memorySlot,
    String? confirmLabel,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => AuraPathPickerDialog(
        title: title,
        prompt: prompt,
        initialPath: initialPath,
        mode: mode,
        allowedExtensions: allowedExtensions,
        memorySlot: memorySlot,
        confirmLabel: confirmLabel,
      ),
    );
  }

  @override
  State<AuraPathPickerDialog> createState() => _AuraPathPickerDialogState();
}

class _AuraPathPickerDialogState extends State<AuraPathPickerDialog> {
  late final TextEditingController _controller;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final init = widget.initialPath ??
        (widget.memorySlot != null ? PathMemory.dirFor(widget.memorySlot!) : null) ??
        '';
    _controller = TextEditingController(text: init);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _openNativePicker() async {
    final l = l10nOf(context);
    final initialDir = PathMemory.dirFor(widget.memorySlot ?? '') ??
        (widget.memorySlot != null ? PathMemory.fallbackDir(widget.memorySlot!) : null);

    if (widget.mode == AuraPathPickerMode.directory) {
      final dir = await getDirectoryPath(
        initialDirectory: initialDir,
        confirmButtonText: l.pathPickerSelectDir,
      );
      if (dir != null) {
        _controller.text = dir;
        if (mounted) {
          setState(() => _errorText = null);
        }
      }
    } else {
      final typeGroup = widget.allowedExtensions != null && widget.allowedExtensions!.isNotEmpty
          ? [XTypeGroup(label: widget.title, extensions: widget.allowedExtensions)]
          : null;
      final file = await openFile(
        acceptedTypeGroups: typeGroup ?? const [],
        initialDirectory: initialDir,
      );
      if (file != null) {
        _controller.text = file.path;
        if (mounted) {
          setState(() => _errorText = null);
        }
      }
    }
  }

  void _submit() {
    final l = l10nOf(context);
    final path = _controller.text.trim();
    if (path.isEmpty) {
      setState(() => _errorText = l.pathPickerErrEmpty);
      return;
    }

    if (widget.mode == AuraPathPickerMode.directory) {
      final dir = Directory(path);
      if (!dir.existsSync()) {
        setState(() => _errorText = l.pathPickerErrDirNotExist);
        return;
      }
    } else {
      final file = File(path);
      if (!file.existsSync()) {
        setState(() => _errorText = l.pathPickerErrFileNotExist);
        return;
      }
      if (widget.allowedExtensions != null && widget.allowedExtensions!.isNotEmpty) {
        final ext = path.contains('.') ? path.split('.').last.toLowerCase() : '';
        final allowed = widget.allowedExtensions!.map((e) => e.toLowerCase()).toList();
        if (!allowed.contains(ext)) {
          setState(() => _errorText = l.pathPickerErrFormat(widget.allowedExtensions!.join(', ')));
          return;
        }
      }
    }

    if (widget.memorySlot != null) {
      if (widget.mode == AuraPathPickerMode.directory) {
        PathMemory.setDir(widget.memorySlot!, path);
      } else {
        PathMemory.recordPick(widget.memorySlot!, path);
      }
    }

    Navigator.of(context).pop(path);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    final String defaultHint = widget.mode == AuraPathPickerMode.directory
        ? PlatformProfile.pathPlaceholder(directory: true)
        : PlatformProfile.pathPlaceholder(
            directory: false,
            extension: widget.allowedExtensions?.first,
          );

    return AlertDialog(
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AuraRadius.md),
        side: BorderSide(color: p.hairline),
      ),
      titlePadding: const EdgeInsets.fromLTRB(AuraSpace.md, AuraSpace.md, AuraSpace.md, AuraSpace.sm),
      contentPadding: const EdgeInsets.symmetric(horizontal: AuraSpace.md),
      actionsPadding: const EdgeInsets.fromLTRB(AuraSpace.md, AuraSpace.sm, AuraSpace.md, AuraSpace.md),
      title: Row(
        children: [
          Icon(
            widget.mode == AuraPathPickerMode.directory
                ? Icons.folder_rounded
                : Icons.insert_drive_file_rounded,
            size: 18,
            color: p.accent,
          ),
          const SizedBox(width: AuraSpace.xs),
          Expanded(
            child: Text(
              widget.title,
              style: sectionOf(p).copyWith(fontSize: 15),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.prompt != null) ...[
              Text(widget.prompt!, style: captionOf(p).copyWith(fontSize: 12)),
              const SizedBox(height: AuraSpace.sm),
            ],
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (context, value, _) {
                return TextField(
                  controller: _controller,
                  style: monoOf(p, size: 12),
                  onChanged: (_) {
                    if (_errorText != null) {
                      setState(() => _errorText = null);
                    }
                  },
                  onSubmitted: (_) => _submit(),
                  decoration: InputDecoration(
                    hintText: defaultHint,
                    hintStyle: captionOf(p).copyWith(color: p.textDim.withValues(alpha: 0.5)),
                    filled: true,
                    fillColor: p.panelRaised,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      borderSide: BorderSide(color: p.hairline),
                    ),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      borderSide: BorderSide(color: p.hairline),
                    ),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      borderSide: BorderSide(color: p.accent, width: 1.2),
                    ),
                    contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
                    suffixIcon: value.text.isNotEmpty
                        ? IconButton(
                            icon: const Icon(Icons.close_rounded, size: 15),
                            tooltip: l.pathPickerClear,
                            onPressed: () {
                              _controller.clear();
                              if (_errorText != null) {
                                setState(() => _errorText = null);
                              }
                            },
                          )
                        : null,
                  ),
                );
              },
            ),
            if (widget.allowedExtensions != null && widget.allowedExtensions!.isNotEmpty) ...[
              const SizedBox(height: AuraSpace.xxs),
              Text(
                l.pathPickerSupported(widget.allowedExtensions!.map((e) => '*.$e').join(', ')),
                style: captionOf(p).copyWith(fontSize: 10.5, color: p.textDim),
              ),
            ],
            if (_errorText != null) ...[
              const SizedBox(height: AuraSpace.xs),
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Icon(Icons.error_outline_rounded, size: 13, color: p.warning),
                  const SizedBox(width: AuraSpace.xxs),
                  Expanded(
                    child: Text(
                      _errorText!,
                      style: captionOf(p, color: p.warning).copyWith(fontSize: 11),
                    ),
                  ),
                ],
              ),
            ],
          ],
        ),
      ),
      actions: [
        Row(
          children: [
            // 左下角：系统文件/文件夹选择按钮
            OutlinedButton.icon(
              icon: Icon(
                widget.mode == AuraPathPickerMode.directory
                    ? Icons.folder_open_rounded
                    : Icons.file_open_rounded,
                size: 15,
              ),
              label: Text(l.pathPickerBrowse),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.accent,
                side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: AuraSpace.xs),
              ),
              onPressed: _openNativePicker,
            ),
            const Spacer(),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l.dlgCancel, style: labelOf(p)),
            ),
            const SizedBox(width: AuraSpace.xs),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.accentContrast,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: AuraSpace.md, vertical: AuraSpace.xs),
              ),
              onPressed: _submit,
              child: Text(widget.confirmLabel ?? l.pathPickerConfirm),
            ),
          ],
        ),
      ],
    );
  }
}
