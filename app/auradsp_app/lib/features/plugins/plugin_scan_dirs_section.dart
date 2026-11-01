// plugin_scan_dirs.dart —— 插件扫描目录管理区（2026-10-28 改版，P-042）。
//
// 独立文件（不再作为 plugins_page 的 part）：目录模型、平台发现、
// 勾选/全选/清除/打开/移除交互全部收敛在这里，plugins_page 只负责挂载。
//
// 布局（用户定案）：
//   [卡片头] 标题 + 说明 + 「添加目录」
//   [列表左上] 全选复选框（三态） + 清除图标按钮
//   [每行] 复选框 | 路径（内置条目带「内置」角标） | 打开文件夹 | 移除该条
// 内置目录不可移除（按钮禁用），但**可以取消勾选**（2026-10-28 修正：
// 只禁止删除，不禁止取消扫描，否则全选/清除无法表达真实全选语义）。
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/error_sink.dart';
import '../../core/plugins/plugin_scan_dirs.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../platform/adapters.dart';
import '../widgets.dart';

class PluginScanDirsSection extends StatelessWidget {
  final AppModel model;
  final VoidCallback onAddDir;
  final VoidCallback onRescan;

  const PluginScanDirsSection({
    super.key,
    required this.model,
    required this.onAddDir,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final entries = model.config.pluginScanDirs;

    final allOn = entries.isNotEmpty && entries.every((e) => e.enabled);
    final allOff = entries.every((e) => !e.enabled);

    return SectionCard(
      title: l.plugCustomTitle,
      hint: l.plugCustomHint,
      trailing: OutlinedButton.icon(
        onPressed: onAddDir,
        icon: const Icon(Icons.create_new_folder_rounded, size: 15),
        label: Text(l.plugCustomAdd),
        style: OutlinedButton.styleFrom(
          foregroundColor: p.accent,
          side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
          visualDensity: VisualDensity.compact,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 列表左上：全选（三态） + 清除
          Row(
            children: [
              SizedBox(
                width: 30,
                height: 30,
                child: Checkbox(
                  value: allOn ? true : (allOff ? false : null),
                  tristate: true,
                  onChanged: (v) {
                    model.setAllPluginScanDirsEnabled(v ?? false);
                    onRescan();
                  },
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
              Text(l.plugScanDirsSelectAll, style: captionOf(p)),
              const SizedBox(width: 4),
              IconButton(
                tooltip: l.plugScanDirsClear,
                onPressed: allOff
                    ? null
                    : () {
                        model.setAllPluginScanDirsEnabled(false);
                        onRescan();
                      },
                icon: const Icon(Icons.deselect_rounded, size: 16),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints:
                    const BoxConstraints(minWidth: 26, minHeight: 26),
              ),
              const Spacer(),
              Text(
                l.plugScanDirsEnabledCount(
                  entries.where((e) => e.enabled).length,
                  entries.length,
                ),
                style: captionOf(p, color: p.textDim),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.xs),
          if (entries.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: AuraSpace.sm),
              alignment: Alignment.centerLeft,
              child: Text(l.plugCustomEmpty, style: captionOf(p)),
            )
          else
            Container(
              constraints: const BoxConstraints(maxHeight: 220),
              decoration: BoxDecoration(
                color: p.panelRaised,
                borderRadius: BorderRadius.circular(AuraRadius.sm),
                border: Border.all(color: p.hairline),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 2),
                itemCount: entries.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  thickness: 1,
                  color: p.hairline.withValues(alpha: 0.6),
                ),
                itemBuilder: (context, index) {
                  final e = entries[index];
                  return _ScanDirRow(
                    entry: e,
                    onToggle: (v) {
                      model.setPluginScanDirEnabled(e.path, v);
                      onRescan();
                    },
                    onOpen: () =>
                        PlatformAdapters.instance.shell.openPath(e.path),
                    onRemove: e.builtin
                        ? null
                        : () {
                            model.removePluginScanDir(e.path);
                            onRescan();
                          },
                  );
                },
              ),
            ),
        ],
      ),
    );
  }
}

class _ScanDirRow extends StatelessWidget {
  final PluginScanDirEntry entry;
  final ValueChanged<bool> onToggle;
  final VoidCallback onOpen;
  final VoidCallback? onRemove;

  const _ScanDirRow({
    required this.entry,
    required this.onToggle,
    required this.onOpen,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final exists = _safeDirExists(entry.path);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 30,
            height: 30,
            child: Checkbox(
              value: entry.enabled,
              onChanged: (v) => onToggle(v ?? false),
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          Icon(
            exists ? Icons.folder_rounded : Icons.folder_off_rounded,
            size: 15,
            color: exists ? p.textDim : p.warning,
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: entry.path,
              waitDuration: const Duration(milliseconds: 600),
              child: Text(
                entry.path,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: monoOf(p, size: 11, color: exists ? p.text : p.textDim),
              ),
            ),
          ),
          if (entry.builtin) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: l.plugScanDirsBuiltinHint,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: p.accent.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  l.plugScanDirsBuiltin,
                  style: TextStyle(
                    fontSize: 9,
                    color: p.accent,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ],
          IconButton(
            tooltip: l.plugOpenFolder,
            onPressed: onOpen,
            icon: const Icon(Icons.folder_open_rounded, size: 15),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
          IconButton(
            tooltip: onRemove == null
                ? l.plugScanDirsBuiltinHint
                : l.plugScanDirsRemove,
            onPressed: onRemove,
            icon: const Icon(Icons.remove_circle_outline_rounded, size: 15),
            color: onRemove == null ? p.textDim.withValues(alpha: 0.35) : p.error,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
          ),
        ],
      ),
    );
  }

  static bool _safeDirExists(String path) {
    try {
      return Directory(path).existsSync();
    } catch (e, st) {
      swallow(e, st);
      return false;
    }
  }
}

