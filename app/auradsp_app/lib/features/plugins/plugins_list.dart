// part of plugins_page.dart —— P1 按区拆分，纯搬运零改行。
part of '../plugins_page.dart';
class _FilterPills extends StatelessWidget {
  final String selected;
  final int countAll;
  final int countVst3;
  final int countClap;
  final int countVst2;
  final int countAu;
  final int countLv2;
  final ValueChanged<String> onSelect;

  const _FilterPills({
    required this.selected,
    required this.countAll,
    required this.countVst3,
    required this.countClap,
    this.countVst2 = 0,
    this.countAu = 0,
    this.countLv2 = 0,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    Widget pill(String id, String label, int count, {bool comingSoon = false}) {
      final isSel = selected == id;
      final body = GestureDetector(
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
      if (!comingSoon) return body;
      // 预留格式（VST2/AU/LV2）：按钮可见、灰显、不可点——扫描/挂载驱动
      // 尚未实现（2026-10-28 用户定案先占位），悬停给出明确说明。
      return Tooltip(
        message: l10nOf(context).plugFormatSoon,
        child: Opacity(opacity: 0.45, child: IgnorePointer(child: body)),
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
        const SizedBox(width: 6),
        pill('vst2', 'VST2', countVst2, comingSoon: true),
        const SizedBox(width: 6),
        pill('au', 'AU', countAu, comingSoon: true),
        const SizedBox(width: 6),
        pill('lv2', 'LV2', countLv2, comingSoon: true),
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
    final groups = manager.pluginGroups;

    if (manager.plugins.isEmpty) {
      // 扫描中且尚无结果 → 动画占位（用户 2026-10-28 要求）；非扫描态才
      // 显示「没有插件」空态，避免扫到一半闪空文案。
      if (manager.isScanning) return const _ScanningPlaceholder();
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

    if (groups.isEmpty) {
      return Container(
        height: 140,
        alignment: Alignment.center,
        child: Text(l10nOf(context).plugNoMatch, style: captionOf(p)),
      );
    }

    // 打平为「厂商头 + 插件行」序列，保持 ListView 懒构建。
    final rows = <_PluginRow>[];
    groups.forEach((vendor, plugins) {
      rows.add(_PluginRow.header(vendor, plugins.length));
      rows.addAll(plugins.map(_PluginRow.item));
    });

    return Container(
      constraints: const BoxConstraints(maxHeight: 460),
      child: ListView.builder(
        shrinkWrap: true,
        itemCount: rows.length,
        itemBuilder: (context, index) {
          final row = rows[index];
          if (row.header) {
            return _VendorHeader(vendor: row.vendor, count: row.vendorCount);
          }
          final plugin = row.plugin!;
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

          // 诚实状态（2026-10-22）：已挂载时显示该槽实际生效/旁路态。
          String? mountState;
          if (isLoadedInThisSlot) {
            mountState = manager.isSlotBypassed(slot) ? 'bypassed' : 'active';
          } else if (loadedInOtherSlot != null) {
            mountState = manager.isSlotBypassed(loadedInOtherSlot)
                ? 'bypassed'
                : 'active';
          }
          return _PluginListItem(
            plugin: plugin,
            slot: slot,
            isLoadedInThisSlot: isLoadedInThisSlot,
            loadedInOtherSlot: loadedInOtherSlot,
            mountState: mountState,
            onLoad: () => onLoad(plugin),
            onUnload: onUnload,
            busy: manager.isSlotBusy(slot),
          );
        },
      ),
    );
  }
}

/// 列表行（厂商头 / 插件项）的中性载体。
class _PluginRow {
  final bool header;
  final String vendor;
  final int vendorCount;
  final PluginMetadata? plugin;

  const _PluginRow._({
    required this.header,
    this.vendor = '',
    this.vendorCount = 0,
    this.plugin,
  });

  factory _PluginRow.header(String vendor, int count) =>
      _PluginRow._(header: true, vendor: vendor, vendorCount: count);

  factory _PluginRow.item(PluginMetadata p) =>
      _PluginRow._(header: false, plugin: p);
}

/// 厂商分组头：字典序由 PluginManager.pluginGroups 保证；空厂商显示
/// 「未知厂商」（l10n），不抢占排头。
class _VendorHeader extends StatelessWidget {
  final String vendor;
  final int count;

  const _VendorHeader({required this.vendor, required this.count});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final label = vendor.isEmpty ? l10nOf(context).plugUnknownVendor : vendor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, AuraSpace.sm, 2, AuraSpace.xs),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 12,
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.7),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: p.textDim,
                letterSpacing: 0.3,
              ),
            ),
          ),
          Text('$count', style: monoOf(p, size: 10, color: p.textDim)),
        ],
      ),
    );
  }
}

/// 扫描中的动画占位（呼吸透明度 + 提示文案），替代「扫到一半空列表闪文案」。
class _ScanningPlaceholder extends StatefulWidget {
  const _ScanningPlaceholder();

  @override
  State<_ScanningPlaceholder> createState() => _ScanningPlaceholderState();
}

class _ScanningPlaceholderState extends State<_ScanningPlaceholder>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      height: 180,
      alignment: Alignment.center,
      child: FadeTransition(
        opacity: Tween<double>(begin: 0.35, end: 0.85).animate(_ctrl),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.manage_search_rounded, size: 32, color: p.accent),
            const SizedBox(height: AuraSpace.sm),
            Text(
              l10nOf(context).plugScanning,
              style: captionOf(p, color: p.textDim),
            ),
          ],
        ),
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

  /// 诚实状态：'active' 生效 / 'bypassed' 旁路 / null 未挂载。
  final String? mountState;
  final VoidCallback onLoad;
  final VoidCallback onUnload;
  /// C3：该槽挂载/卸载任务进行中（异步）。两个操作按钮据此禁用。
  final bool busy;

  const _PluginListItem({
    required this.plugin,
    required this.slot,
    required this.isLoadedInThisSlot,
    required this.loadedInOtherSlot,
    this.mountState,
    required this.onLoad,
    required this.onUnload,
    this.busy = false,
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
    // C3：该槽挂载/卸载进行中——两个操作按钮都要禁用，避免重复下发
    // （引擎侧也会拒绝，但提前禁用让 UI 不闪一下再失败）。
    final isBusy = busy;

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
                    // 诚实状态一个标（2026-10-22 用户定案）：
                    // 「插槽x活跃中」/「插槽x旁路」，不再并列「生效」字样。
                    if (isLoadedInThisSlot || loadedInOtherSlot != null) ...[
                      const SizedBox(width: 8),
                      Builder(builder: (ctx) {
                        final shownSlot =
                            isLoadedInThisSlot ? slot : loadedInOtherSlot!;
                        final bypassed = mountState == 'bypassed';
                        final color = bypassed
                            ? const Color(0xFFE6A23C)
                            : const Color(0xFF67C23A);
                        return Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 1),
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            bypassed
                                ? l10nOf(context)
                                    .plugSlotBypassed(shownSlot + 1)
                                : l10nOf(context)
                                    .plugSlotActive(shownSlot + 1),
                            style: TextStyle(
                              fontSize: 10,
                              color: color,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        );
                      }),
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
              onPressed: isBusy ? null : onUnload,
              icon: isBusy
                  ? const SizedBox(
                      width: 14, height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.eject_rounded, size: 14),
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
              onPressed: isBusy ? null : onLoad,
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
