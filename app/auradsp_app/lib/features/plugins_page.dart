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
          title: Text('添加插件检索目录', style: sectionOf(p)),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('请输入或粘贴包含 64 位 VST3 / CLAP 效果器的完整文件夹路径：',
                  style: captionOf(p)),
              const SizedBox(height: AuraSpace.sm),
              TextField(
                controller: _customDirCtrl,
                style: monoOf(p, size: 12),
                decoration: InputDecoration(
                  hintText: r'例：D:\AudioPlugins\VST3',
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
              child: Text('取消', style: labelOf(p)),
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
              child: const Text('添加并扫描'),
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
                  Text('插件预设管理 — ${plugin.name}', style: sectionOf(p)),
                ],
              ),
              content: SizedBox(
                width: 440,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('保存当前参数状态', style: labelOf(p)),
                    const SizedBox(height: AuraSpace.xs),
                    Row(
                      children: [
                        Expanded(
                          child: TextField(
                            controller: presetNameCtrl,
                            style: labelOf(p),
                            decoration: InputDecoration(
                              hintText: '输入新预设名称...',
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
                          label: const Text('保存'),
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
                    Text('已有预设列表 (${presets.length})', style: labelOf(p)),
                    const SizedBox(height: AuraSpace.xs),
                    if (presets.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: AuraSpace.md),
                        child: Center(
                          child: Text('暂无已保存预设，可通过上方输入框保存。',
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
                                label: const Text('载入'),
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
                  child: Text('关闭', style: labelOf(p)),
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
        title: '插件中心',
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
            title: '第三方效果器库',
            hint: '系统标准 VST3 / CLAP 64 位插件目录与自定义目录扫描与管理。'
                '支持零延迟与前瞻延迟补偿，双声道平面 RT-Safe 运行。',
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
                    Text('深度遍历', style: captionOf(p)),
                  ],
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
                  label: Text(manager.isScanning ? '正在扫描...' : '聚合扫描插件'),
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
                  tooltip: '打开 VST3 标准目录',
                  icon: const Icon(Icons.folder_open_rounded, size: 18),
                  onPressed: _openPluginFolder,
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
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
                                  hintText: '搜索插件名称、厂商或路径...',
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
            title: 'M1 插件宿主引擎规范',
            hint: '多格式进程内宿主已支持 64 位 VST3 与 CLAP 架构。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: AuraSpace.md,
                  runSpacing: AuraSpace.sm,
                  children: [
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: '双挂载槽位 (Slot 1 / Slot 2) 独立管理与并发',
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: '全音效链阶段插入 (Pre-DSP ~ Post-Limiter)',
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: '原生 Win32 GUI 弹窗独立消息循环',
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: '二进制流预设保存与即时载入恢复',
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: '可自定义插件目录检索与本地状态快照',
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: '平面双声道 RT-Safe 预分配零锁保障',
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
              const SizedBox(width: AuraSpace.md),
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
                        '插槽 ${slotIdx + 1} (Slot ${slotIdx + 1})',
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
                            isBypassed ? '旁路' : '生效',
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
                        ? '${plugin!.name} • [${PluginInsertStage.shortLabelOf(stage)}]'
                        : '未挂载效果器',
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
      title: '自定义插件检索目录',
      hint: '添加其他硬盘分区或 DAW 的 VST3/CLAP 路径，扫描时将自动合并遍历。',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton.icon(
            onPressed: onAddDir,
            icon: const Icon(Icons.create_new_folder_rounded, size: 15),
            label: const Text('添加目录'),
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
                '暂未添加自定义目录。除系统默认路径（C:\\Program Files\\Common Files\\VST3 等）外，可点击右上角添加。',
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
        title: '挂载状态 (插槽 ${slot + 1})',
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
                '插槽 ${slot + 1} 暂未挂载第三方插件',
                style: sectionOf(p),
              ),
              const SizedBox(height: AuraSpace.xs),
              Text(
                '请在下方效果器库列表中选择已安装的 VST3 / CLAP 插件进行加载',
                style: captionOf(p),
              ),
              if (manager.plugins.isEmpty && !manager.isScanning) ...[
                const SizedBox(height: AuraSpace.md),
                OutlinedButton.icon(
                  onPressed: onScanTap,
                  icon: const Icon(Icons.search_rounded, size: 16),
                  label: const Text('立即扫描本机已安装插件'),
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
    final badgeGradient = isVst3
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

    final latencySamples = manager.getSlotLatency(slot);
    // 插件延迟是「样本数」，必须按设备实际采样率换算，不是固定 48k。
    final latencyMs =
        (latencySamples / model.deviceRate * 1000.0).toStringAsFixed(1);

    return SectionCard(
      title: '当前挂载插件 (插槽 ${slot + 1})',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 原生 GUI 打开按钮
          ElevatedButton.icon(
            onPressed: () => manager.showEditor(slot: slot),
            icon: const Icon(Icons.open_in_new_rounded, size: 15),
            label: const Text('打开界面 (GUI)'),
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
            label: const Text('预设'),
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
            isBypassed ? '已旁路' : '生效中',
            selected: !isBypassed,
            danger: isBypassed,
            onTap: () => manager.toggleBypass(slot: slot),
          ),
          const SizedBox(width: AuraSpace.sm),
          // 卸载按钮
          OutlinedButton.icon(
            onPressed: () => manager.unloadPlugin(slot: slot),
            icon: const Icon(Icons.eject_rounded, size: 15),
            label: const Text('卸载'),
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
                // 格式大徽章
                Container(
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    gradient: badgeGradient,
                    borderRadius: BorderRadius.circular(AuraRadius.md),
                    boxShadow: [
                      BoxShadow(
                        color: (isVst3
                                ? const Color(0xFF0072FF)
                                : const Color(0xFFE94057))
                            .withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: Text(
                      active.format.label,
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w900,
                        fontSize: 15,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ),
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
                      Text(
                        '${active.vendor.isNotEmpty ? active.vendor : "未知厂商"} • ${active.category.isNotEmpty ? active.category : "Fx"}',
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
                      Text('实测音频延迟', style: captionOf(p, color: p.textDim)),
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
                Text('信号处理链插入阶段：', style: labelOf(p)),
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
                  '实时动态串联 • 保持 RT-Safe 契约',
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
        pill('all', '全部', countAll),
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
            Text('未检测到已安装的第三方插件', style: sectionOf(p)),
            const SizedBox(height: AuraSpace.xs),
            Text(
              '请确认插件已放置在系统 VST3 / CLAP 路径，或在上方添加自定义插件目录后重新扫描',
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
        child: Text('未找到符合当前搜索和过滤条件的插件', style: captionOf(p)),
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
    final badgeColor = isVst3 ? const Color(0xFF0072FF) : const Color(0xFFE94057);

    return Container(
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
                          '插槽 ${slot + 1} 活跃中',
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
                          '插槽 ${loadedInOtherSlot! + 1} 已载入',
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
                  '${plugin.vendor.isNotEmpty ? plugin.vendor : "第三方插件"} • ${plugin.path}',
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
              label: const Text('从当前槽卸载'),
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
              label: Text('载入至插槽 ${slot + 1}'),
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.accentContrast,
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
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
