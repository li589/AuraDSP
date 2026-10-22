// part of plugins_page.dart —— P1 按区拆分，纯搬运零改行。
part of '../plugins_page.dart';
class _PluginChannelStrip extends StatelessWidget {
  final int mask;
  final ValueChanged<int> onChanged;

  /// 可交互位（bit=1 可点）：VB 非双耳时泵层每组仅 L/R 进引擎
  /// （VmPumpCore.h procCh=2），C/LFE/… 位是死控件 → 灰显禁点并提示。
  final int interactiveMask;

  const _PluginChannelStrip({
    required this.mask,
    required this.onChanged,
    this.interactiveMask = 0xFF,
  });

  static const _labels = ['L', 'R', 'C', 'LFE', 'Ls', 'Rs', 'Lr', 'Rr'];

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final stereoOnly = interactiveMask != 0xFF;
    return Row(
      children: [
        Icon(Icons.multitrack_audio_rounded, size: 16, color: p.accent),
        const SizedBox(width: AuraSpace.xs),
        Text('Ch', style: labelOf(p)),
        const SizedBox(width: AuraSpace.sm),
        Expanded(
          child: Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (var ch = 0; ch < 8; ++ch)
                _ChannelChip(
                  label: _labels[ch],
                  selected: (mask & (1 << ch)) != 0,
                  enabled: (interactiveMask & (1 << ch)) != 0,
                  onTap: () {
                    onChanged(mask ^ (1 << ch));
                  },
                ),
              if (stereoOnly)
                Tooltip(
                  message: l10nOf(context).plugChStereoOnly,
                  triggerMode: TooltipTriggerMode.tap,
                  showDuration: const Duration(seconds: 4),
                  child: Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: Icon(Icons.info_outline_rounded,
                        size: 13, color: p.textDim),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _ChannelChip extends StatelessWidget {
  final String label;
  final bool selected;
  final bool enabled;
  final VoidCallback onTap;

  const _ChannelChip({
    required this.label,
    required this.selected,
    required this.onTap,
    this.enabled = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    if (!enabled) {
      // 死控件：该通道不进插件链（VB 非双耳），灰显不可点。
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(color: p.hairline.withValues(alpha: 0.5)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            color: p.textDim.withValues(alpha: 0.4),
          ),
        ),
      );
    }
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? p.accent : p.panel,
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(
            color: selected ? p.accent : p.hairline,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.bold,
            color: selected ? p.accentContrast : p.textDim,
          ),
        ),
      ),
    );
  }
}

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

/// 「全部」路由选择菜单（P1-5）：继承自 {lastEditedRoute} / 使用自有状态。
/// 确认后写入「全部」记忆（第 9 套）并统一下发全部组，再落到「全部」路由。
void _showAllRouteMenu(
  BuildContext context,
  AppModel model,
  PluginManager manager,
  int slot,
  List<String> routeNames,
) {
  final l = l10nOf(context);
  final src = manager.lastEditedRoute;
  final srcName = (src >= 0 && src < routeNames.length) ? routeNames[src] : '';
  final canInherit = src >= 0;
  final canOwn = manager.hasAllMemory(slot);
  showMenu<int>(
    context: context,
    items: [
      PopupMenuItem<int>(
        value: 1,
        enabled: canInherit,
        child: Text(canInherit
            ? l.plugAllInheritFrom(srcName)
            : l.plugAllInheritNone),
      ),
      PopupMenuItem<int>(
        value: 2,
        enabled: canOwn,
        child: Text(l.plugAllUseOwn),
      ),
    ],
  ).then((v) {
    if (v == 1 && canInherit) {
      manager.inheritAllFrom(src, slot: slot);
      model.setVbPluginEditorGroup(kVbRouteAll);
    } else if (v == 2 && canOwn) {
      manager.applyAllMemory(slot: slot);
      model.setVbPluginEditorGroup(kVbRouteAll);
    }
  });
}

/// 「全部」记忆来源标注（P1-2，替换原 plugRtNote 位）：三态 + 重继承。
class _AllInheritBadge extends StatelessWidget {
  final AppModel model;
  final PluginManager manager;
  final int slot;
  final List<String> routeNames;
  const _AllInheritBadge({
    required this.model,
    required this.manager,
    required this.slot,
    required this.routeNames,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final from = manager.allInheritFrom(slot);
    if (from == -2) return const SizedBox.shrink();
    final label = from >= 0 && from < routeNames.length
        ? l.plugInheritedFrom(routeNames[from])
        : l.plugAllOwnState;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          from >= 0 ? Icons.download_done_rounded : Icons.settings_backup_restore_rounded,
          size: 13,
          color: p.textDim,
        ),
        const SizedBox(width: 4),
        Text(label, style: captionOf(p, color: p.textDim)),
        if (from >= 0 && manager.lastEditedRoute >= 0) ...[
          const SizedBox(width: AuraSpace.xs),
          Tooltip(
            message: l.plugReInherit,
            child: InkWell(
              onTap: () => manager.inheritAllFrom(manager.lastEditedRoute,
                  slot: slot),
              borderRadius: BorderRadius.circular(AuraRadius.sm),
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.refresh_rounded, size: 13, color: p.accent),
              ),
            ),
          ),
        ],
      ],
    );
  }
}

/// 活跃插件 Hero 卡片
class _ActivePluginHero extends StatelessWidget {
  final AppModel model;
  final PluginManager manager;
  final int slot;
  final VoidCallback onScanTap;

  const _ActivePluginHero({
    required this.model,
    required this.manager,
    required this.slot,
    required this.onScanTap,
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

    // v2 按路插件（2026-10-22）：VB 多总线下，插件实际挂在每一路的独立引擎
    // 上（OUTPUT INSERT，每 8 声道一引擎）。「打开界面」跟随总线下拉选中的
    // 路打开该路引擎上的编辑器；「全部」= 主实例（有效路内最低组）。
    // 下拉选项源 = vbEffectiveRouteMask（通道开着 且 插件勾选——busMask 关的
    // 整组直通不进引擎，调参不上流）。全不选时无可打开的路（旁路态）。
    // 其余模式（VAIO/ASIO/WASAPI）单引擎，无此维度，group=-1。
    final isVb = model.audioMode == 'vbcallback';
    final routeMask = model.vbEffectiveRouteMask;
    final editorGroup = model.vbPluginEditorGroup;
    final routeNames = vbBusNames(
        (model.vbInfo['edition'] as num?)?.toInt() ?? 0);
    final routeCount = routeNames.length;
    // 「全部」路由解析：打开有效路内最低组的实例（P1 起该模式下参数
    // 广播到全部组；P0 骨架仅路由，调参仍只作用主实例）。
    final primaryGroup = routeMask == 0
        ? -1
        : (routeMask & -routeMask).bitLength - 1; // 最低置位 bit
    final openGroup = !isVb
        ? -1
        : (editorGroup == kVbRouteAll
            ? primaryGroup
            : editorGroup);
    // Ch strip 可交互位（P0-B）：VB 非双耳时泵层每组仅 L/R 进引擎
    // （VmPumpCore.h procCh=2），C/LFE/… chip 是死控件 → 灰显禁点。
    final chInteractive = (isVb && !model.spatialBinaural) ? 0x3 : 0xFF;

    final latencySamples = manager.getSlotLatency(slot);
    final status = manager.getSlotStatus(slot);
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
          // 2026-10-20：大插件（如 Ozone 12）加载可达数秒，补文字提示避免
          // 误以为加载失败。
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
            const SizedBox(width: AuraSpace.xs),
            Text(l10nOf(context).plugLoading,
                style: labelOf(p, size: 11, color: p.textDim)),
            const SizedBox(width: AuraSpace.sm),
          ],
          // 原生 GUI 打开按钮（v2：VB 模式跟随总线下拉选中的路；
          // 「全部」= 打开主实例界面）
          ElevatedButton.icon(
            // C1：同一插件可挂多槽，标题必须带槽位号区分两个编辑器窗口。
            // VB 无有效路（通道全关/插件全不勾）时禁用——没有路可打开。
            onPressed: isBusy || (isVb && openGroup < 0)
                ? null
                : () => manager.showEditor(
                      slot: slot,
                      title: l10nOf(context)
                          .plugEditorTitleNamed(slot + 1, active.name),
                      group: openGroup,
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
          // v2：预设按钮位改「总线下拉」——仅 VB 模式显示（其余模式单引擎
          // 无多路维度）。选项 = 有效路（通道开且插件勾）+「全部」置顶；
          // 无有效路时禁用并显示旁路提示。选中值 = vbPluginEditorGroup。
          if (isVb) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              decoration: BoxDecoration(
                color: p.panel,
                borderRadius: BorderRadius.circular(AuraRadius.sm),
                border: Border.all(color: p.hairline),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: editorGroup == kVbRouteAll
                      ? kVbRouteAll
                      : (editorGroup >= 0 && editorGroup < routeCount
                          ? editorGroup
                          : null),
                  isDense: true,
                  dropdownColor: p.panelRaised,
                  style: labelOf(p),
                  hint: Text(
                    l10nOf(context).plugRouteBypassed,
                    style: labelOf(p, size: 12, color: p.textDim),
                  ),
                  disabledHint: Text(
                    manager.isSlotEditorOpen(slot)
                        ? l10nOf(context).plugRouteLocked
                        : l10nOf(context).plugRouteBypassed,
                    style: labelOf(p, size: 12, color: p.textDim),
                  ),
                  icon: Icon(Icons.arrow_drop_down_rounded, color: p.accent),
                  items: [
                    DropdownMenuItem<int>(
                      value: kVbRouteAll,
                      child: Text(
                        l10nOf(context).plugRouteAll,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: editorGroup == kVbRouteAll
                              ? p.accent
                              : p.text,
                          fontWeight: editorGroup == kVbRouteAll
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                    for (var g = 0; g < routeCount; g++)
                      if ((routeMask & (1 << g)) != 0)
                        DropdownMenuItem<int>(
                          value: g,
                          child: Text(
                            routeNames[g],
                            style: TextStyle(
                              fontSize: 12.5,
                              color: g == editorGroup ? p.accent : p.text,
                              fontWeight: g == editorGroup
                                  ? FontWeight.bold
                                  : FontWeight.normal,
                            ),
                          ),
                        ),
                  ],
                  onChanged: (isBusy ||
                          routeMask == 0 ||
                          manager.isSlotEditorOpen(slot))
                      ? null // P1-1 路由锁定：编辑器打开时禁切换
                      : (val) {
                          if (val == null) return;
                          if (val == kVbRouteAll) {
                            // P1-5：切「全部」弹继承/不继承菜单
                            _showAllRouteMenu(
                                context, model, manager, slot, routeNames);
                          } else {
                            model.setVbPluginEditorGroup(val);
                          }
                        },
                ),
              ),
            ),
            const SizedBox(width: AuraSpace.sm),
          ],
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

            // 2026-10-22：槽位遥测诊断行（「插件有输入但听不到效果」投诉的
            // 一锤定音判别）。口径 = 引擎 getStatusJsonSlot 的 F-8a 抽取遥测：
            //   maxDiff ≈ 0 且 outRms ≈ inRms → 槽位实际在直通（旁路/判死/
            //   传输失败），效果根本没上流；
            //   maxDiff > 0 → 效果已应用，问题在下游监听路由。
            // processCalls 停涨 = 插件从未被音频线程调用（挂载没进链）。
            // remoteMode 标记当前引擎是否走进程外宿主（二进制陈旧排查）。
            Row(
              children: [
                Icon(Icons.monitor_heart_rounded, size: 14, color: p.textDim),
                const SizedBox(width: AuraSpace.xs),
                Expanded(
                  child: Text(
                    'in ${status.inRms.toStringAsFixed(4)}'
                    ' · out ${status.outRms.toStringAsFixed(4)}'
                    ' · Δmax ${status.maxDiff.toStringAsFixed(4)}'
                    ' · calls ${status.processCalls}'
                    '${status.remoteMode ? (status.remoteFailed ? " · remote✗" : " · remote✓") : ""}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: monoOf(p, size: 10.5, color: p.textDim),
                  ),
                ),
              ],
            ),
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
                // P1-2：原「实时动态串联…」文案删除（用户：完全不需要）。
                // 「全部」路由下显示第 9 套记忆的来源标注（继承自 X / 自有）。
                if (isVb && editorGroup == kVbRouteAll)
                  _AllInheritBadge(
                    model: model,
                    manager: manager,
                    slot: slot,
                    routeNames: routeNames,
                  )
                else
                  const SizedBox.shrink(),
              ],
            ),
            const SizedBox(height: AuraSpace.sm),
            _PluginChannelStrip(
              // P1-4：Ch 按当前路由记忆取值/下发（「全部」= 第 9 套记忆）。
              mask: manager.getSlotChannels(slot,
                  group: isVb ? editorGroup : -1),
              interactiveMask: chInteractive,
              onChanged: (m) => manager.setSlotChannels(m,
                  slot: slot, group: isVb ? editorGroup : -1),
            ),
            const SizedBox(height: AuraSpace.xs),
            Row(
              children: [
                Icon(Icons.monitor_heart_rounded,
                    size: 14, color: p.textDim),
                const SizedBox(width: AuraSpace.xs),
                Text(
                  'proc ${status.processCalls}  '
                  'in ${status.inRms.toStringAsFixed(4)}  '
                  'out ${status.outRms.toStringAsFixed(4)}  '
                  'Δ ${status.maxDiff.toStringAsFixed(4)}',
                  style: monoOf(p, size: 10, color: p.textDim),
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
