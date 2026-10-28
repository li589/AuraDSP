// part of plugins_page.dart —— P1 按区拆分，纯搬运零改行。
part of '../plugins_page.dart';
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
                busy: manager.isSlotBusy(i),
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
  final bool busy;
  final VoidCallback onTap;

  const _SlotTab({
    required this.slotIdx,
    required this.isSelected,
    required this.isActive,
    required this.isBypassed,
    required this.plugin,
    required this.stage,
    this.busy = false,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return LayoutBuilder(builder: (context, constraints) {
      // 2026-10-28：窄宽度下文字必然溢出插槽边界——退化为「大圈号居中」
      // 的紧凑形态（用户定案：圈 1 / 圈 2 那种序号标记）。
      final compact = constraints.maxWidth < 150;
      return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AuraRadius.md),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: EdgeInsets.symmetric(
            horizontal: compact ? AuraSpace.xs : AuraSpace.md,
            vertical: AuraSpace.sm + 2),
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
        child: compact
            ? Center(
                child: Container(
              width: compact ? 34 : 28,
              height: compact ? 34 : 28,
              decoration: BoxDecoration(
                color: isSelected ? p.accent : p.hairline,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              child: busy
                  ? SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isSelected ? p.accentContrast : p.accent,
                      ),
                    )
                  : Text(
                      '${slotIdx + 1}',
                      style: TextStyle(
                        color: isSelected ? p.accentContrast : p.textDim,
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                ),
              )
            : Row(
          children: [
            Container(
              width: compact ? 34 : 28,
              height: compact ? 34 : 28,
              decoration: BoxDecoration(
                color: isSelected ? p.accent : p.hairline,
                shape: BoxShape.circle,
              ),
              alignment: Alignment.center,
              // 忙态（加载/卸载中）：槽号位换加载动画——per-slot 独立，
              // 切换槽查看其它槽不受影响（2026-10-22 用户需求）。
              child: busy
                  ? SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: isSelected ? p.accentContrast : p.accent,
                      ),
                    )
                  : Text(
                      '${slotIdx + 1}',
                      style: TextStyle(
                        color: isSelected ? p.accentContrast : p.textDim,
                        fontWeight: FontWeight.bold,
                        fontSize: compact ? 16 : 13,
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
          // 右上角诚实状态（2026-10-22）：生效=绿点 / 旁路=橙点。
          if (isActive && !compact)
            Positioned(
              top: 6,
              right: 6,
              child: Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isBypassed
                      ? const Color(0xFFE6A23C)
                      : const Color(0xFF67C23A),
                ),
              ),
            ),
        ],
      ),
    );
      });
  }
}

/// 自定义插件目录管理卡片
