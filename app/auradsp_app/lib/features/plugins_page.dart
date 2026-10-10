/*
 * plugins_page.dart — AuraDSP M1 第三方插件中心（VST3 / CLAP 64位宿主）
 *
 * 规范对齐：docs/APP-插件与信号图扩展规划.md §2 与 §9.1
 * 交付功能：
 * 1. 活跃插件 Hero 卡片（格式徽章、实时延迟测量、Bypass 热切换、一键卸载）
 * 2. 系统插件扫描器（快扫/深扫、扫描进度反馈、本地磁盘缓存）
 * 3. 插件过滤与搜索（全部 / VST3 / CLAP 快速切换药丸）
 * 4. 插件库列表与一键加载、错误告警与目录快捷打开
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
  bool _deepScan = false;

  @override
  void initState() {
    super.initState();
    _searchCtrl.text = widget.model.pluginManager.searchQuery;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
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

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final manager = widget.model.pluginManager;

    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) => PageScaffold(
        title: '插件中心',
        children: [
          // 1. 当前挂载插件 Hero 卡片
          _ActivePluginHero(
            model: widget.model,
            manager: manager,
            onScanTap: () => manager.scan(deep: _deepScan),
          ),

          // 2. 插件库与扫描控制中心
          SectionCard(
            title: '第三方效果器库',
            hint: '系统标准 VST3 / CLAP 64 位插件目录扫描与管理。'
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
                  label: Text(manager.isScanning ? '正在扫描...' : '扫描系统插件'),
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

                // 插件列表内容
                _PluginListView(
                  manager: manager,
                  onLoad: (plugin) => manager.loadPlugin(plugin),
                  onUnload: () => manager.unloadPlugin(),
                ),
              ],
            ),
          ),

          // 3. 宿主架构与规范说明
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
                      label: 'Steinberg VST3 (GPLv3) SDK 官方整合',
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: 'CLAP (MIT) 纯 C 接口无锁并发',
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: '平面双声道 RT-Safe 预分配无阻塞',
                      color: p.success,
                    ),
                    _FeatureBadge(
                      icon: Icons.check_circle_rounded,
                      label: 'SEH 异常捕获与无锁自动直通降级',
                      color: p.success,
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                Text(
                  '说明：当前为 M1 单插件宿主形态，插件挂载于 AuraDSP 总输出级之前；'
                  '启动时自动通过会话记忆系统恢复上次加载的插件与旁路状态。',
                  style: captionOf(p),
                ),
              ],
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
  final VoidCallback onScanTap;

  const _ActivePluginHero({
    required this.model,
    required this.manager,
    required this.onScanTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final active = manager.activePlugin;
    final hasActive = manager.hasActivePlugin && active != null;

    if (!hasActive) {
      // 空插槽展示
      return SectionCard(
        title: '当前挂载插件',
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(
              vertical: AuraSpace.lg, horizontal: AuraSpace.md),
          decoration: BoxDecoration(
            color: p.panelRaised.withValues(alpha: 0.5),
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
                '暂未挂载第三方插件',
                style: sectionOf(p),
              ),
              const SizedBox(height: AuraSpace.xs),
              Text(
                '请在下方列表中选择已安装的 VST3 / CLAP 效果器进行实时加载',
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

    // 已挂载插件卡片
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

    final latencySamples = manager.currentLatency;
    final latencyMs = (latencySamples / 48000.0 * 1000.0).toStringAsFixed(1);

    return SectionCard(
      title: '当前挂载插件',
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 旁路开关按钮
          AuraChip(
            manager.isBypassed ? '已旁路' : '生效中',
            selected: !manager.isBypassed,
            danger: manager.isBypassed,
            onTap: () => manager.toggleBypass(),
          ),
          const SizedBox(width: AuraSpace.sm),
          // 卸载按钮
          OutlinedButton.icon(
            onPressed: () => manager.unloadPlugin(),
            icon: const Icon(Icons.eject_rounded, size: 16),
            label: const Text('卸载插件'),
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
            color: manager.isBypassed
                ? p.warning.withValues(alpha: 0.4)
                : p.accent.withValues(alpha: 0.4),
          ),
          boxShadow: [
            BoxShadow(
              color: (manager.isBypassed ? p.warning : p.accent)
                  .withValues(alpha: 0.08),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // 格式大徽章
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                gradient: badgeGradient,
                borderRadius: BorderRadius.circular(AuraRadius.md),
                boxShadow: [
                  BoxShadow(
                    color: (isVst3 ? const Color(0xFF0072FF) : const Color(0xFFE94057))
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
                    fontSize: 16,
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
                  fontWeight: isSel ? FontWeight.bold : FontWeight.normal,
                  color: isSel ? p.accent : p.textDim,
                ),
              ),
              const SizedBox(width: 4),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: isSel
                      ? p.accent.withValues(alpha: 0.25)
                      : p.hairline,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: isSel ? p.accent : p.textDim,
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
  final ValueChanged<PluginMetadata> onLoad;
  final VoidCallback onUnload;

  const _PluginListView({
    required this.manager,
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
            Icon(Icons.inventory_2_outlined, size: 36, color: p.textDim),
            const SizedBox(height: AuraSpace.sm),
            Text('未发现插件或尚未扫描', style: captionOf(p)),
            const SizedBox(height: AuraSpace.xs),
            Text('点击右上角“扫描系统插件”按钮即可快速发现本机已安装插件',
                style: captionOf(p, color: p.textDim)),
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
          final isActive = manager.hasActivePlugin &&
              manager.activePlugin?.path == plugin.path;

          return _PluginListItem(
            plugin: plugin,
            isActive: isActive,
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
  final bool isActive;
  final VoidCallback onLoad;
  final VoidCallback onUnload;

  const _PluginListItem({
    required this.plugin,
    required this.isActive,
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
        color: isActive ? p.accent.withValues(alpha: 0.08) : p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: isActive ? p.accent : p.hairline,
          width: isActive ? 1.5 : 1.0,
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
                        fontWeight: isActive ? FontWeight.bold : FontWeight.w500,
                        color: isActive ? p.accent : p.text,
                      ),
                    ),
                    if (isActive) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: p.success.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '当前运行中',
                          style: TextStyle(
                            fontSize: 10,
                            color: p.success,
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
          if (isActive)
            ElevatedButton.icon(
              onPressed: onUnload,
              icon: const Icon(Icons.eject_rounded, size: 14),
              label: const Text('卸载'),
              style: ElevatedButton.styleFrom(
                backgroundColor: p.error.withValues(alpha: 0.15),
                foregroundColor: p.error,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                    horizontal: AuraSpace.md, vertical: 4),
                visualDensity: VisualDensity.compact,
              ),
            )
          else
            ElevatedButton.icon(
              onPressed: onLoad,
              icon: const Icon(Icons.power_rounded, size: 14),
              label: const Text('挂载'),
              style: ElevatedButton.styleFrom(
                backgroundColor: p.accent,
                foregroundColor: p.accentContrast,
                padding: const EdgeInsets.symmetric(
                    horizontal: AuraSpace.md, vertical: 4),
                visualDensity: VisualDensity.compact,
              ),
            ),
        ],
      ),
    );
  }
}

/// 特性标签
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
        Text(label, style: labelOf(p, color: p.textDim)),
      ],
    );
  }
}
