// part of plugins_page.dart —— P1 按区拆分，纯搬运零改行。
part of '../plugins_page.dart';
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
                    if (mountState != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: (mountState == 'bypassed'
                                  ? const Color(0xFFE6A23C)
                                  : const Color(0xFF67C23A))
                              .withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              mountState == 'bypassed'
                                  ? Icons.pause_circle_rounded
                                  : Icons.play_circle_rounded,
                              size: 10,
                              color: mountState == 'bypassed'
                                  ? const Color(0xFFE6A23C)
                                  : const Color(0xFF67C23A),
                            ),
                            const SizedBox(width: 3),
                            Text(
                              mountState == 'bypassed'
                                  ? l10nOf(context).plugStateBypassed
                                  : l10nOf(context).plugStateActive,
                              style: TextStyle(
                                fontSize: 10,
                                color: mountState == 'bypassed'
                                    ? const Color(0xFFE6A23C)
                                    : const Color(0xFF67C23A),
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
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
