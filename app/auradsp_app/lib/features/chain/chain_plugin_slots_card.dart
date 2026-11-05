/*
 * chain_plugin_slots_card.dart — 第三方插件挂载顺序卡片组件
 * 1. 卡片命名：「第三方插件挂载顺序」（去过度修饰）
 * 2. 四槽位独立管理：挂载插件名称、格式徽标、延迟状态、独立旁路/激活切换
 * 3. 灵活阶段插入：可在 Pre-DSP / Pre-Vendor / Post-Vendor / Post-Reverb / Post-Limiter 精确调整
 * 4. 插件原生 GUI 窗口唤起与槽位 PDC 自动延迟补偿开关
 */

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/plugins/plugin_manager.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../ui/chrome.dart';
import '../../ui/widgets.dart';

/// 第三方插件挂载顺序管理卡片
class ChainPluginSlotsCard extends StatelessWidget {
  final AppModel model;
  const ChainPluginSlotsCard({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);

    return SectionCard(
      title: l.chainVstTitle, // 「第三方插件挂载顺序」
      hint: l.chainVstHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 4 槽位独立控制卡片列表（插入阶段由卡片内下拉菜单精确调整）
          for (var s = 0; s < PluginManager.kMaxSlots; s++) ...[
            _PluginSlotChainCard(
              model: model,
              slot: s,
            ),
            if (s < PluginManager.kMaxSlots - 1)
              const SizedBox(height: AuraSpace.sm),
          ],
          const SizedBox(height: AuraSpace.sm),
          _PdcToggleRow(model: model),
        ],
      ),
    );
  }
}

/// 单插槽独立处理链调整卡片
class _PluginSlotChainCard extends StatelessWidget {
  final AppModel model;
  final int slot;

  const _PluginSlotChainCard({
    required this.model,
    required this.slot,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final manager = model.pluginManager;
    final isActive = manager.isSlotActive(slot);
    final active = manager.getSlotPlugin(slot);
    final isBypassed = manager.isSlotBypassed(slot);
    final remoteFailed = manager.getSlotStatus(slot).remoteFailed;
    final currentStage = manager.getSlotStage(slot);

    return Container(
      padding: const EdgeInsets.all(AuraSpace.md),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: isActive
              ? (isBypassed
                  ? p.warning.withValues(alpha: 0.4)
                  : p.accent.withValues(alpha: 0.4))
              : p.hairline,
        ),
      ),
      child: Row(
        children: [
          // 插槽徽章
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isActive
                  ? p.accent.withValues(alpha: 0.15)
                  : p.panelRaised,
              shape: BoxShape.circle,
              border: Border.all(color: isActive ? p.accent : p.hairline),
            ),
            alignment: Alignment.center,
            child: Text(
              '${slot + 1}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: isActive ? p.accent : p.textDim,
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
                      isActive
                          ? l10nOf(context).chainSlotActive(
                              slot + 1, active!.name, active.format.label)
                          : l10nOf(context).chainSlotEmpty(slot + 1),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: p.text,
                      ),
                    ),
                    if (isActive && active != null) ...[
                      const SizedBox(width: AuraSpace.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: p.hairline,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          active.format.label,
                          style: monoOf(p, size: 9.5, color: p.textDim),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  isActive
                      ? l10nOf(context).chainSlotStatusLine(
                          isBypassed
                              ? (remoteFailed
                                  ? l10nOf(context).chainSlotRemoteFailed
                                  : l10nOf(context).chainSlotBypassed)
                              : l10nOf(context).chainSlotProcessing,
                          manager.getSlotLatency(slot))
                      : l10nOf(context).chainSlotHint,
                  style: captionOf(p, color: p.textDim),
                ),
              ],
            ),
          ),

          // 插入阶段选择器
          if (isActive) ...[
            AuraDropdown<int>(
              value: currentStage,
              isExpanded: false,
              items: PluginInsertStage.values.map<DropdownMenuItem<int>>((stg) {
                return DropdownMenuItem<int>(
                  value: stg,
                  child: Text(
                    PluginInsertStage.labelOf(stg),
                    style: TextStyle(
                      fontSize: 12,
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
            const SizedBox(width: AuraSpace.sm),
            // GUI 打开按钮
            IconButton(
              tooltip: l10nOf(context).chainOpenGui,
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              onPressed: () => manager.showEditor(
                slot: slot,
                title: active != null
                    ? l10nOf(context).plugEditorTitleNamed(slot + 1, active.name)
                    : null,
              ),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: AuraSpace.xs),
            // 旁路开关
            AuraChip(
              isBypassed
                  ? l10nOf(context).chainBypassed
                  : l10nOf(context).chainActive,
              selected: !isBypassed,
              danger: isBypassed,
              busy: manager.isSlotBypassPending(slot),
              onTap: manager.isSlotBypassPending(slot)
                  ? null
                  : () => manager.toggleBypass(slot: slot),
            ),
          ],
        ],
      ),
    );
  }
}

/// PDC 延迟补偿总开关
class _PdcToggleRow extends StatelessWidget {
  final AppModel model;

  const _PdcToggleRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final manager = model.pluginManager;
    return Row(
      children: [
        Icon(Icons.timeline_rounded, size: 16, color: p.accent),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            l10nOf(context).chainPdcLabel,
            style: captionOf(p),
          ),
        ),
        AuraSwitch(
          value: manager.pdcEnabled,
          onChanged: (v) => manager.setPdc(v),
        ),
      ],
    );
  }
}
