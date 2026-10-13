// part of plugins_page.dart —— P1 按区拆分，纯搬运零改行。
part of '../plugins_page.dart';
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
    // C3：挂载/卸载进行中（异步任务）。此期间禁用所有会触碰该槽实例的按钮，
    // 避免用户在 unload 还没跑完时就点"打开界面"——那样会去取一个正在销毁
    // 的实例。引擎侧也会拒绝，这里先让 UI 表达出来。
    final isBusy = manager.isSlotBusy(slot);

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
          // C3：挂载/卸载进行中（异步任务）。所有会触碰该槽实例的按钮已禁用，
          // 这里给出一个可见的忙态，让用户知道"正在处理，不是卡死了"。
          if (isBusy) ...[
            SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: p.accent,
                backgroundColor: p.hairline,
              ),
            ),
            const SizedBox(width: AuraSpace.sm),
          ],
          // 原生 GUI 打开按钮
          ElevatedButton.icon(
            // C1：同一插件可挂多槽，标题必须带槽位号区分两个编辑器窗口。
            onPressed: isBusy ? null : () => manager.showEditor(
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
            onPressed: isBusy ? null : () => onShowPresets(active),
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
            onTap: isBusy ? null : () => manager.toggleBypass(slot: slot),
          ),
          const SizedBox(width: AuraSpace.sm),
          // 卸载按钮
          OutlinedButton.icon(
            onPressed: isBusy ? null : () => manager.unloadPlugin(slot: slot),
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
