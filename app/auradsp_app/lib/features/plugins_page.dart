/*
 * plugins_page.dart — AuraDSP 第三方插件中心（VST3 / CLAP 64位宿主）
 *
 * 升级功能：
 * 1. 双插槽独立架构（Slot 1 / Slot 2 并行挂载与管理）
 * 2. 原生 GUI 编辑器弹窗唤起（独立消息循环异步线程）
 * 3. 插件预设管理系统（快照保存与载入、文件管理）
 * 4. 可自定义插件检索目录（UI 配置、持久化 config.json、多目录聚合扫描）
 * 5. 全音效处理链插入阶段调整（Pre-DSP / Pre-Vendor / Post-Vendor / Post-Reverb / Post-Limiter）
 */

import 'dart:io';
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/plugin_manager.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
import 'widgets.dart';

class PluginsPage extends StatefulWidget {
  final AppModel model;
  const PluginsPage({super.key, required this.model});

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  final TextEditingController _searchCtrl = TextEditingController();
  final TextEditingController _customDirCtrl = TextEditingController();
  bool _deepScan = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.model.pluginManager.searchQuery;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    _customDirCtrl.dispose();
    super.dispose();
  }

  void _openPluginFolder() {
    try {
      const vst3Dir = r'C:\Program Files\Common Files\VST3';
      if (Platform.isWindows && Directory(vst3Dir).existsSync()) {
        Process.run('explorer.exe', [vst3Dir]);
      }
    } catch (_) {}
  }

  void _addCustomDirDialog(BuildContext context) {
    _customDirCtrl.clear();
    showDialog(
      context: context,
      builder: (ctx) {
        final p = paletteOf(ctx);
        return AlertDialog(
          backgroundColor: p.panel,
          title: Text(l10nOf(ctx).plugAddDirTitle, style: sectionOf(p)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10nOf(ctx).plugAddDirPrompt,
                  style: captionOf(p)),
              const SizedBox(height: AuraSpace.sm),
              TextField(
                controller: _customDirCtrl,
                style: monoOf(p, size: 12),
                decoration: InputDecoration(
                  hintText: l10nOf(ctx).plugAddDirExample,
                  hintStyle: captionOf(p),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    borderSide: BorderSide(color: p.hairline),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 8),
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text(l10nOf(ctx).dlgCancel, style: labelOf(p)),
            ),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.accentContrast,
              ),
              onPressed: () {
                final path = _customDirCtrl.text.trim();
                if (path.isNotEmpty) {
                  widget.model.addCustomPluginDir(path);
                  Navigator.of(ctx).pop();
                  widget.model.pluginManager.scan(deep: _deepScan);
                }
              },
              child: Text(l10nOf(ctx).plugAddScan),
            ),
          ],
        );
      },
    );
  }

  void _showPresetDialog(BuildContext context, int slot, PluginMetadata plugin) {
    final presetNameCtrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (context, setDlgState) {
            final p = paletteOf(ctx);
            final presets = widget.model.pluginManager.listPresets(plugin.name);

            return AlertDialog(
              backgroundColor: p.panel,
              title: Row(
                children: [
                  Icon(Icons.tune_rounded, size: 20, color: p.accent),
                  const SizedBox(width: AuraSpace.sm),
                  Text(l10nOf(ctx).plugPresetTitle(plugin.name), style: sectionOf(p)),
                ],
              ),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10nOf(ctx).plugPresetSaveLabel, style: labelOf(p)),
                    const SizedBox(height: AuraSpace.xs),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: presetNameCtrl,
                            style: labelOf(p),
                            decoration: InputDecoration(
                              hintText: l10nOf(ctx).plugPresetNameHint,
                              hintStyle: captionOf(p),
                              isDense: true,
                              border: OutlineInputBorder(
                                borderRadius:
                                    BorderRadius.circular(AuraRadius.sm),
                                borderSide: BorderSide(color: p.hairline),
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 8),
                            ),
                          ),
                        ),
                        const SizedBox(width: AuraSpace.sm),
                        ElevatedButton.icon(
                          onPressed: () {
                            final name = presetNameCtrl.text.trim();
                            if (name.isNotEmpty) {
                              widget.model.pluginManager
                                  .savePreset(name, slot: slot);
                              presetNameCtrl.clear();
                              setDlgState(() {});
                            }
                          },
                          icon: const Icon(Icons.save_rounded, size: 16),
                          label: Text(l10nOf(ctx).dlgSave),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: p.accent,
                            foregroundColor: p.accentContrast,
                            visualDensity: VisualDensity.compact,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: AuraSpace.md),
                    Divider(color: p.hairline, height: 1),
                    const SizedBox(height: AuraSpace.md),
                    Text(l10nOf(ctx).plugPresetList(presets.length), style: labelOf(p)),
                    const SizedBox(height: AuraSpace.xs),
                    if (presets.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: AuraSpace.md),
                        child: Center(
                          child: Text(l10nOf(ctx).plugPresetEmpty,
                              style: captionOf(p)),
                        ),
                      )
                    else
                      Container(
                        constraints: const BoxConstraints(maxHeight: 180),
                        decoration: BoxDecoration(
                          color: p.panelRaised,
                          borderRadius: BorderRadius.circular(AuraRadius.sm),
                          border: Border.all(color: p.hairline),
                        ),
                        child: ListView.separated(
                          shrinkWrap: true,
                          itemCount: presets.length,
                          separatorBuilder: (_, _) =>
                              Divider(color: p.hairline, height: 1),
                          itemBuilder: (c, idx) {
                            final name = presets[idx];
                            return ListTile(
                              dense: true,
                              title: Text(name, style: labelOf(p)),
                              trailing: ElevatedButton.icon(
                                onPressed: () {
                                  widget.model.pluginManager
                                      .loadPreset(name, slot: slot);
                                  Navigator.of(ctx).pop();
                                },
                                icon: const Icon(Icons.file_upload_rounded,
                                    size: 14),
                                label: Text(l10nOf(ctx).dlgLoad),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: p.accent.withValues(alpha: 0.2),
                                  foregroundColor: p.accent,
                                  visualDensity: VisualDensity.compact,
                                  elevation: 0,
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(l10nOf(ctx).dlgClose, style: labelOf(p)),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final manager = widget.model.pluginManager;
    final currentSlot = manager.selectedSlot;

    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) => PageScaffold(
        title: l10nOf(context).plugTitle,
        children: [
          // 0. 插槽选择器（Slot 1 / Slot 2 并行管理）
          _SlotSelectorBar(
            manager: manager,
            onSelectSlot: (slot) => manager.selectSlot(slot),
          ),

          // 1. 当前选中挂载插槽 Hero 卡片
          _ActivePluginHero(
            model: widget.model,
            manager: manager,
            slot: currentSlot,
            onScanTap: () => manager.scan(deep: _deepScan),
            onShowPresets: (plugin) => _showPresetDialog(context, currentSlot, plugin),
          ),

          // 2. 自定义检索目录管理
          _CustomDirsSection(
            model: widget.model,
            onAddDir: () => _addCustomDirDialog(context),
            onRescan: () => manager.scan(deep: _deepScan),
          ),

          // 3. 插件库与扫描控制中心
          SectionCard(
            title: l10nOf(context).plugLibTitle,
            hint: l10nOf(context).plugLibHint,
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                // 深度扫描勾选
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Checkbox(
                      value: _deepScan,
                      onChanged: manager.isScanning
                          ? null
                          : (v) => setState(() => _deepScan = v ?? false),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    Text(l10nOf(context).plugDeepScan, style: captionOf(p)),
                  ],
                ),
                // C2：说明"快扫不打开插件"——FL Studio 那种扫描即验证的做法
                // 慢且无必要（深扫 3.6s vs 快扫 120ms / 76 个），本引擎在挂载
                // 时才验证插件，这里明确告知用户，避免误以为列表已验证可用。
                Tooltip(
                  message: l10nOf(context).plugScanNoVerify,
                  child: const Icon(Icons.info_outline_rounded, size: 14),
                ),
                const SizedBox(width: AuraSpace.sm),
                // 扫描按钮
                ElevatedButton.icon(
                  onPressed: manager.isScanning
                      ? null
                      : () => manager.scan(deep: _deepScan),
                  icon: manager.isScanning
                      ? const SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.refresh_rounded, size: 16),
                  label: Text(manager.isScanning ? l10nOf(context).plugScanning : l10nOf(context).plugScan),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: p.accent,
                    foregroundColor: p.accentContrast,
                    padding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.md, vertical: AuraSpace.xs),
                    visualDensity: VisualDensity.compact,
                  ),
                ),
                const SizedBox(width: AuraSpace.sm),
                // 打开目录
                IconButton(
                  tooltip: l10nOf(context).plugOpenFolder,
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  onPressed: _openPluginFolder,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // C2：扫描进行中 → Android 风格水平进度条 + 进度读数
                if (manager.isScanning) ...[
                  AuraScanProgress(
                    done: manager.scanDone,
                    total: manager.scanTotal,
                  ),
                  const SizedBox(height: AuraSpace.xs),
                  Text(
                    manager.scanTotal > 0
                        ? l10nOf(context).plugScanProgressCount(
                            manager.scanDone, manager.scanTotal, manager.scanFound)
                        : l10nOf(context).plugScanPreparing,
                    style: monoOf(p, size: 11, color: p.textDim),
                  ),
                  const SizedBox(height: AuraSpace.sm),
                ],
                // 搜索栏与分类药丸
                Row(
                  children: [
                    // 搜索输入框
                    Expanded(
                      child: Container(
                        height: 38,
                        decoration: BoxDecoration(
                          color: p.panelRaised,
                          borderRadius: BorderRadius.circular(AuraRadius.sm),
                          border: Border.all(color: p.hairline),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        child: Row(
                          children: [
                            Icon(Icons.search_rounded, size: 18, color: p.textDim),
                            const SizedBox(width: 8),
                            Expanded(
                              child: TextField(
                                controller: _searchCtrl,
                                style: labelOf(p),
                                decoration: InputDecoration(
                                  hintText: l10nOf(context).plugSearchHint,
                                  hintStyle: captionOf(p),
                                  border: InputBorder.none,
                                  isDense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                                onChanged: (val) => manager.setSearchQuery(val),
                              ),
                            ),
                            if (_searchCtrl.text.isNotEmpty)
                              GestureDetector(
                                onTap: () {
                                  _searchCtrl.clear();
                                  manager.setSearchQuery('');
                                },
                                child: Icon(Icons.clear_rounded,
                                    size: 16, color: p.textDim),
                              ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: AuraSpace.md),
                    // 格式药丸 Filter
                    _FilterPills(
                      selected: manager.filterFormat,
                      countAll: manager.countAll,
                      countVst3: manager.countVst3,
                      countClap: manager.countClap,
                      onSelect: (fmt) => manager.setFilterFormat(fmt),
                    ),
                  ],
                ),

                if (manager.lastError != null) ...[
                  const SizedBox(height: AuraSpace.sm),
                  Container(
                    padding: const EdgeInsets.all(AuraSpace.sm),
                    decoration: BoxDecoration(
                      color: p.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      border: Border.all(color: p.error.withValues(alpha: 0.3)),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.error_outline_rounded,
                            size: 16, color: p.error),
                        const SizedBox(width: AuraSpace.sm),
                        Expanded(
                          child: Text(manager.lastError!,
                              style: captionOf(p, color: p.error)),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: AuraSpace.md),

                // 插件列表内容（支持加载到当前选中插槽）
                _PluginListView(
                  manager: manager,
                  slot: currentSlot,
                  onLoad: (plugin) => manager.loadPlugin(plugin, slot: currentSlot),
                  onUnload: () => manager.unloadPlugin(slot: currentSlot),
                ),
              ],
            ),
          ),

          // 4. 宿主架构与规范说明
          SectionCard(
            title: l10nOf(context).plugM1Title,
            hint: l10nOf(context).plugM1Hint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AuraSpace.md,
                  runSpacing: AuraSpace.sm,
                  children: [
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatSlots,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatStages,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatGui,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatPreset,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatDirs,
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: l10nOf(context).plugFeatRt,
                      color: p.success,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 插槽切换栏
class _SlotSelectorBar extends StatelessWidget {
  final PluginManager manager;
  final ValueChanged<int> onSelectSlot;

  const _SlotSelectorBar({
    required this.manager,
    required this.onSelectSlot,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: AuraSpace.sm),
      child: Row(
        children: [
          for (var i = 0; i < PluginManager.kMaxSlots; i++) ...[
            Expanded(
              child: _SlotTab(
                slotIdx: i,
                isSelected: manager.selectedSlot == i,
                isActive: manager.isSlotActive(i),
                isBypassed: manager.isSlotBypassed(i),
                plugin: manager.getSlotPlugin(i),
                stage: manager.getSlotStage(i),
                onTap: () => onSelectSlot(i),
              ),
            ),
            if (i < PluginManager.kMaxSlots - 1)
              const SizedBox(width: AuraSpace.sm),
          ],
        ],
      ),
    );
  }
}

/// 插槽标签
class _SlotTab extends StatelessWidget {
  final int slotIdx;
  final bool isSelected;
  final bool isActive;
  final bool isBypassed;
  final PluginMetadata? plugin;
  final int stage;
  final VoidCallback onTap;

  const _SlotTab({
    required this.slotIdx,
    required this.isSelected,
    required this.isActive,
    required this.isBypassed,
    required this.plugin,
    required this.stage,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AuraRadius.md),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(
            horizontal: AuraSpace.md, vertical: AuraSpace.sm + 2),
        decoration: BoxDecoration(
          color: isSelected
              ? p.accent.withValues(alpha: 0.12)
              : p.panelRaised,
          borderRadius: BorderRadius.circular(AuraRadius.md),
          border: Border.all(
            color: isSelected ? p.accent : p.hairline,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: isSelected ? p.accent : p.hairline,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: Text(
                '${slotIdx + 1}',
                style: TextStyle(
                  color: isSelected ? p.accentContrast : p.textDim,
                  fontWeight: FontWeight.bold,
                  fontSize: 13,
                ),
              ),
            ),
            const SizedBox(width: AuraSpace.sm),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(
                        l10nOf(context).plugSlot(slotIdx + 1),
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight:
                              isSelected ? FontWeight.bold : FontWeight.w500,
                          color: isSelected ? p.accent : p.text,
                        ),
                      ),
                      const SizedBox(width: 6),
                      if (isActive)
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 5, vertical: 1),
                          decoration: BoxDecoration(
                            color: isBypassed
                                ? p.warning.withValues(alpha: 0.2)
                                : p.success.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            isBypassed ? l10nOf(context).plugBypassed : l10nOf(context).plugActive,
                            style: TextStyle(
                              fontSize: 9.5,
                              color: isBypassed ? p.warning : p.success,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    isActive
                        ? l10nOf(context).plugSlotPluginLine(plugin!.name, PluginInsertStage.shortLabelOf(stage))
                        : l10nOf(context).plugSlotNoFx,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: captionOf(p,
                        color: isActive ? p.textDim : p.textDim.withValues(alpha: 0.6)),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 自定义插件目录管理卡片
class _CustomDirsSection extends StatelessWidget {
  final AppModel model;
  final VoidCallback onAddDir;
  final VoidCallback onRescan;

  const _CustomDirsSection({
    required this.model,
    required this.onAddDir,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final customDirs = model.config.customPluginDirs;

    return SectionCard(
      title: l10nOf(context).plugCustomTitle,
      hint: l10nOf(context).plugCustomHint,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton.icon(
            onPressed: onAddDir,
            icon: const Icon(Icons.create_new_folder_rounded, size: 15),
            label: Text(l10nOf(context).plugCustomAdd),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.accent,
              side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      child: customDirs.isEmpty
          ? Container(
              padding: const EdgeInsets.symmetric(vertical: AuraSpace.sm),
              alignment: Alignment.centerLeft,
              child: Text(
                l10nOf(context).plugCustomEmpty,
                style: captionOf(p),
              ),
            )
          : Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              children: customDirs.map((dir) {
                return Chip(
                  avatar: const Icon(Icons.folder_rounded, size: 16),
                  label: Text(dir, style: monoOf(p, size: 11)),
                  backgroundColor: p.panelRaised,
                  side: BorderSide(color: p.hairline),
                  deleteIcon: const Icon(Icons.close_rounded, size: 14),
                  onDeleted: () {
                    model.removeCustomPluginDir(dir);
                    onRescan();
                  },
                );
              }).toList(),
            ),
    );
  }
}

/// D4d logo 三合一：AuraDSP 品牌渐变底 + 厂商首字母 monogram + 格式角标。
///
/// 为什么不做"提取真实图标"：VST3 无标准 logo 接口（只能在 bundle 的
/// Contents/Resources/ 找快照图，且 IPlugView::getSnapshot 需先建实例+建
/// 视图，代价高不稳定）；CLAP 根本没有 logo 概念。三合一是确定性、离线、
/// 对全部插件一致的默认方案（方案 §4.6-1）。
///
/// 空 vendor 时 monogram 降级取插件名首字母（方案 §4.6-2），不再显示
/// "未知厂商"——文本行同步只保留分类。
class _PluginTriLogo extends StatelessWidget {
  final String vendor;
  final String pluginName;
  final String formatLabel;
  final bool isVst3;

  const _PluginTriLogo({
    required this.vendor,
    required this.pluginName,
    required this.formatLabel,
    required this.isVst3,
  });

  /// monogram：厂商首字母优先，空则插件名首字母，再空则 '?'。
  /// 用 runes 取首码位，避免 surrogate pair 被切成半个代理对。
  String get _monogram {
    for (final s in [vendor, pluginName]) {
      final t = s.trim();
      if (t.isNotEmpty) {
        return String.fromCharCode(t.runes.first).toUpperCase();
      }
    }
    return '?';
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final formatGradient = isVst3
        ? const LinearGradient(
            colors: [Color(0xFF0072FF), Color(0xFF00C6FF)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          )
        : const LinearGradient(
            colors: [Color(0xFF8A2387), Color(0xFFE94057)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          );
    return SizedBox(
      width: 60,
      height: 60,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 品牌底：accent → accent2 渐变（三套主题的 accentContrast 均适配）
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [p.accent, p.accent2],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(AuraRadius.md),
              boxShadow: [
                BoxShadow(
                  color: p.accent.withValues(alpha: 0.3),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Center(
              child: Text(
                _monogram,
                style: TextStyle(
                  color: p.accentContrast,
                  fontWeight: FontWeight.w900,
                  fontSize: 26,
                  height: 1.0,
                ),
              ),
            ),
          ),
          // 格式角标（右下）：VST3 蓝 / CLAP 紫，沿用原渐变
          Positioned(
            right: -2,
            bottom: -2,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                gradient: formatGradient,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: p.panelRaised, width: 1),
              ),
              child: Text(
                formatLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 7,
                  letterSpacing: 0.4,
                  height: 1.1,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 活跃插件 Hero 卡片
class _ActivePluginHero extends StatelessWidget {
  final AppModel model;
  final PluginManager manager;
  final int slot;
  final VoidCallback onScanTap;
  final ValueChanged<PluginMetadata> onShowPresets;

  const _ActivePluginHero({
    required this.model,
    required this.manager,
    required this.slot,
    required this.onScanTap,
    required this.onShowPresets,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isActive = manager.isSlotActive(slot);
    final active = manager.getSlotPlugin(slot);
    final isBypassed = manager.isSlotBypassed(slot);
    final currentStage = manager.getSlotStage(slot);

    if (!isActive || active == null) {
      return SectionCard(
        title: l10nOf(context).plugMountTitle(slot + 1),
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(AuraSpace.xl),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(AuraRadius.md),
            border: Border.all(
              color: p.hairline,
              style: BorderStyle.solid,
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.developer_board_rounded,
                  size: 40, color: p.textDim.withValues(alpha: 0.6)),
              const SizedBox(height: AuraSpace.sm),
              Text(
                l10nOf(context).plugMountEmpty(slot + 1),
                style: sectionOf(p),
              ),
              const SizedBox(height: AuraSpace.xs),
              Text(
                l10nOf(context).plugMountEmptyHint,
                style: captionOf(p),
              ),
              if (manager.plugins.isEmpty && !manager.isScanning) ...[
                const SizedBox(height: AuraSpace.md),
                OutlinedButton.icon(
                  onPressed: onScanTap,
                  icon: const Icon(Icons.search_rounded, size: 16),
                  label: Text(l10nOf(context).plugScanNow),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: p.accent,
                    side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.md, vertical: AuraSpace.xs),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
    }

    final isVst3 = active.format == PluginFormat.vst3;

    final latencySamples = manager.getSlotLatency(slot);
    // 插件延迟是「样本数」，必须按设备实际采样率换算，不是固定 48k。
    final latencyMs =
        (latencySamples / model.deviceRate * 1000.0).toStringAsFixed(1);

    // 命名规则（D4d）：槽位卡标题显示**用户所选名**——用户在扫描列表
    // 点选那一项的 name，与编辑器窗口标题（'<name> - AuraDSP Host'，
    // B3 E1）同源；B1 已保证扫描值 == 加载值，三处展示不会各说各话。
    return SectionCard(
      title: l10nOf(context).plugMountedTitleNamed(slot + 1, active.name),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 原生 GUI 打开按钮
          ElevatedButton.icon(
            // C1：同一插件可挂多槽，标题必须带槽位号区分两个编辑器窗口。
            onPressed: () => manager.showEditor(
              slot: slot,
              title: l10nOf(context).plugEditorTitleNamed(slot + 1, active.name),
            ),
            icon: const Icon(Icons.open_in_new_rounded, size: 15),
            label: Text(l10nOf(context).plugOpenGuiBtn),
            style: ElevatedButton.styleFrom(
              backgroundColor: p.accent,
              foregroundColor: p.accentContrast,
              padding: const EdgeInsets.symmetric(
                  horizontal: AuraSpace.md, vertical: AuraSpace.xs),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          // 预设管理按钮
          OutlinedButton.icon(
            onPressed: () => onShowPresets(active),
            icon: const Icon(Icons.tune_rounded, size: 15),
            label: Text(l10nOf(context).dlgPreset),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.text,
              side: BorderSide(color: p.hairline),
              padding: const EdgeInsets.symmetric(
                  horizontal: AuraSpace.md, vertical: AuraSpace.xs),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          // 旁路开关按钮
          AuraChip(
            isBypassed ? l10nOf(context).chainBypassed : l10nOf(context).chainActive,
            selected: !isBypassed,
            danger: isBypassed,
            onTap: () => manager.toggleBypass(slot: slot),
          ),
          const SizedBox(width: AuraSpace.sm),
          // 卸载按钮
          OutlinedButton.icon(
            onPressed: () => manager.unloadPlugin(slot: slot),
            icon: const Icon(Icons.eject_rounded, size: 15),
            label: Text(l10nOf(context).dlgUnload),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.error,
              side: BorderSide(color: p.error.withValues(alpha: 0.4)),
              padding: const EdgeInsets.symmetric(
                  horizontal: AuraSpace.md, vertical: AuraSpace.xs),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      child: Container(
        padding: const EdgeInsets.all(AuraSpace.md),
        decoration: BoxDecoration(
          color: p.panelRaised,
          borderRadius: BorderRadius.circular(AuraRadius.md),
          border: Border.all(
            color: isBypassed
                ? p.warning.withValues(alpha: 0.4)
                : p.accent.withValues(alpha: 0.4),
          ),
          boxShadow: [
            BoxShadow(
              color: (isBypassed ? p.warning : p.accent)
                  .withValues(alpha: 0.08),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // logo 三合一（D4d）：AuraDSP 品牌底 + 厂商首字母 monogram
                // + 格式角标。VST3 无标准 logo 接口、CLAP 无 logo 概念
                // （方案 §4.6），故对全部插件用确定性、离线、一致的三合一。
                _PluginTriLogo(
                  vendor: active.vendor,
                  pluginName: active.name,
                  formatLabel: active.format.label,
                  isVst3: isVst3,
                ),
                const SizedBox(width: AuraSpace.md),

                // 插件详情
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            active.name,
                            style: sectionOf(p),
                          ),
                          const SizedBox(width: AuraSpace.sm),
                          if (active.version.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: p.hairline,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'v${active.version}',
                                style: monoOf(p, size: 10, color: p.textDim),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      // 空 vendor 不再显示空白/"未知厂商"（观感"读不出来"）：
                      // monogram 已降级取插件名首字母，文本行只保留分类。
                      Text(
                        active.vendor.isNotEmpty
                            ? '${active.vendor} • ${active.category.isNotEmpty ? active.category : "Fx"}'
                            : (active.category.isNotEmpty ? active.category : "Fx"),
                        style: captionOf(p, color: p.textDim),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        active.path,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: monoOf(p, size: 11, color: p.textDim),
                      ),
                    ],
                  ),
                ),

                // 实时延迟测定
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: AuraSpace.md, vertical: AuraSpace.sm),
                  decoration: BoxDecoration(
                    color: p.panel,
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    border: Border.all(color: p.hairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(l10nOf(context).plugLatencyLabel, style: captionOf(p, color: p.textDim)),
                      const SizedBox(height: 2),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.speed_rounded, size: 14, color: p.accent),
                          const SizedBox(width: 4),
                          Text(
                            '$latencySamples spl ($latencyMs ms)',
                            style: monoOf(p, size: 13, color: p.accent),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),

            const SizedBox(height: AuraSpace.md),
            Divider(color: p.hairline, height: 1),
            const SizedBox(height: AuraSpace.sm),

            // 处理链插入阶段选择栏
            Row(
              children: [
                Icon(Icons.alt_route_rounded, size: 16, color: p.accent),
                const SizedBox(width: AuraSpace.xs),
                Text(l10nOf(context).plugStageLabel, style: labelOf(p)),
                const SizedBox(width: AuraSpace.sm),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                  decoration: BoxDecoration(
                    color: p.panel,
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    border: Border.all(color: p.hairline),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                      value: currentStage,
                      isDense: true,
                      dropdownColor: p.panelRaised,
                      style: labelOf(p),
                      icon: Icon(Icons.arrow_drop_down_rounded, color: p.accent),
                      items: [
                        PluginInsertStage.preDsp,
                        PluginInsertStage.preVendor,
                        PluginInsertStage.postVendor,
                        PluginInsertStage.postReverb,
                        PluginInsertStage.postLimiter,
                      ].map((stg) {
                        return DropdownMenuItem<int>(
                          value: stg,
                          child: Text(
                            PluginInsertStage.labelOf(stg),
                            style: TextStyle(
                              fontSize: 12.5,
                              color: stg == currentStage ? p.accent : p.text,
                              fontWeight: stg == currentStage
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          manager.setInsertStage(val, slot: slot);
                        }
                      },
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  l10nOf(context).plugRtNote,
                  style: captionOf(p, color: p.textDim),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// 格式筛选药丸
class _FilterPills extends StatelessWidget {
  final String selected;
  final int countAll;
  final int countVst3;
  final int countClap;
  final ValueChanged<String> onSelect;

  const _FilterPills({
    required this.selected,
    required this.countAll,
    required this.countVst3,
    required this.countClap,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    Widget pill(String id, String label, int count) {
      final isSel = selected == id;
      return GestureDetector(
        onTap: () => onSelect(id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: isSel ? p.accent.withValues(alpha: 0.15) : p.panelRaised,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(
              color: isSel ? p.accent : p.hairline,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSel ? FontWeight.bold : FontWeight.w500,
                  color: isSel ? p.accent : p.text,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isSel ? p.accent : p.hairline,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isSel ? p.accentContrast : p.textDim,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        pill('all', l10nOf(context).plugFilterAll, countAll),
        const SizedBox(width: 6),
        pill('vst3', 'VST3', countVst3),
        const SizedBox(width: 6),
        pill('clap', 'CLAP', countClap),
      ],
    );
  }
}

/// 插件列表视图
class _PluginListView extends StatelessWidget {
  final PluginManager manager;
  final int slot;
  final ValueChanged<PluginMetadata> onLoad;
  final VoidCallback onUnload;

  const _PluginListView({
    required this.manager,
    required this.slot,
    required this.onLoad,
    required this.onUnload,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final list = manager.filteredPlugins;

    if (manager.plugins.isEmpty) {
      return Container(
        height: 180,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, size: 36, color: p.textDim),
            const SizedBox(height: AuraSpace.sm),
            Text(l10nOf(context).plugNoPlugins, style: sectionOf(p)),
            const SizedBox(height: AuraSpace.xs),
            Text(
              l10nOf(context).plugNoPluginsHint,
              style: captionOf(p),
            ),
          ],
        ),
      );
    }

    if (list.isEmpty) {
      return Container(
        height: 140,
        alignment: Alignment.center,
        child: Text(l10nOf(context).plugNoMatch, style: captionOf(p)),
      );
    }

    return Container(
      constraints: const BoxConstraints(maxHeight: 460),
      child: ListView.separated(
        shrinkWrap: true,
        itemCount: list.length,
        separatorBuilder: (_, _) => const SizedBox(height: 6),
        itemBuilder: (context, index) {
          final plugin = list[index];
          final isLoadedInThisSlot = manager.isSlotActive(slot) &&
              manager.getSlotPlugin(slot)?.path == plugin.path;

          int? loadedInOtherSlot;
          for (var s = 0; s < PluginManager.kMaxSlots; s++) {
            if (s != slot &&
                manager.isSlotActive(s) &&
                manager.getSlotPlugin(s)?.path == plugin.path) {
              loadedInOtherSlot = s;
              break;
            }
          }

          return _PluginListItem(
            plugin: plugin,
            slot: slot,
            isLoadedInThisSlot: isLoadedInThisSlot,
            loadedInOtherSlot: loadedInOtherSlot,
            onLoad: () => onLoad(plugin),
            onUnload: onUnload,
          );
        },
      ),
    );
  }
}

/// 单个插件列表项
class _PluginListItem extends StatelessWidget {
  final PluginMetadata plugin;
  final int slot;
  final bool isLoadedInThisSlot;
  final int? loadedInOtherSlot;
  final VoidCallback onLoad;
  final VoidCallback onUnload;

  const _PluginListItem({
    required this.plugin,
    required this.slot,
    required this.isLoadedInThisSlot,
    required this.loadedInOtherSlot,
    required this.onLoad,
    required this.onUnload,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isVst3 = plugin.format == PluginFormat.vst3;
    // D2：扫描期判定不兼容（当前唯一情形：32 位插件）——整项灰显 +
    // 名称后跟警示角标；点击"载入"由 PluginManager.loadPlugin 拦截并
    // 弹出精确原因（errorMessage），不会走到引擎。
    final isIncompatible = !plugin.isCompatible;
    final badgeColor = isVst3 ? const Color(0xFF0072FF) : const Color(0xFFE94057);

    return Opacity(
      opacity: isIncompatible ? 0.55 : 1.0,
      child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: isLoadedInThisSlot
            ? p.accent.withValues(alpha: 0.08)
            : p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: isLoadedInThisSlot ? p.accent : p.hairline,
          width: isLoadedInThisSlot ? 1.5 : 1.0,
        ),
      ),
      child: Row(
        children: [
          // 格式小胶囊
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
            decoration: BoxDecoration(
              color: badgeColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: badgeColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              plugin.format.label,
              style: TextStyle(
                color: badgeColor,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
          const SizedBox(width: AuraSpace.md),

          // 名称与元数据
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      plugin.name,
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: isLoadedInThisSlot
                            ? FontWeight.bold
                            : FontWeight.w500,
                        color: isLoadedInThisSlot ? p.accent : p.text,
                      ),
                    ),
                    if (isIncompatible) ...[
                      const SizedBox(width: 8),
                      Tooltip(
                        message: plugin.errorMessage.isNotEmpty
                            ? plugin.errorMessage
                            : l10nOf(context).plugIncompatibleHint,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: p.error.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.block_rounded,
                                  size: 10, color: p.error),
                              const SizedBox(width: 3),
                              Text(
                                l10nOf(context).plugIncompatibleBadge,
                                style: TextStyle(
                                  fontSize: 10,
                                  color: p.error,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                    if (isLoadedInThisSlot) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: p.success.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          l10nOf(context).plugSlotActive(slot + 1),
                          style: TextStyle(
                            fontSize: 10,
                            color: p.success,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ] else if (loadedInOtherSlot != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: p.accent.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          l10nOf(context).plugSlotLoaded(loadedInOtherSlot! + 1),
                          style: TextStyle(
                            fontSize: 10,
                            color: p.accent,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  '${plugin.vendor.isNotEmpty ? plugin.vendor : l10nOf(context).plugThirdParty} • ${plugin.path}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: captionOf(p, color: p.textDim),
                ),
              ],
            ),
          ),

          // 操作按钮
          if (isLoadedInThisSlot)
            ElevatedButton.icon(
              onPressed: onUnload,
              icon: const Icon(Icons.eject_rounded, size: 14),
              label: Text(l10nOf(context).plugUnloadFromSlot),
              style: ElevatedButton.styleFrom(
                backgroundColor: p.error.withValues(alpha: 0.15),
                foregroundColor: p.error,
                elevation: 0,
                visualDensity: VisualDensity.compact,
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: onLoad,
              icon: const Icon(Icons.arrow_upward_rounded, size: 14),
              label: Text(l10nOf(context).plugLoadToSlot(slot + 1)),
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.accentContrast,
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
      ),
    );
  }
}

/// 特性徽章
class _FeatureBadge extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _FeatureBadge({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 15, color: color),
        const SizedBox(width: 6),
        Text(label, style: captionOf(p, color: p.text)),
      ],
    );
  }
}
