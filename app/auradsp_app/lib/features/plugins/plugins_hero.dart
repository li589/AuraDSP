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
                    child: Icon(
                      Icons.info_outline_rounded,
                      size: 13,
                      color: p.textDim,
                    ),
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
          border: Border.all(color: selected ? p.accent : p.hairline),
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

/// 安全弹菜单（v3.3）：showMenu 必须显式传 position（Flutter 3.47 断言
/// 二选一，null position release 下白屏——2026-10-22 实测教训）。窗口
/// 0 尺寸/树重建中时回退中心；异常不冒泡。
void _safeShowMenu<T>(
  BuildContext context,
  List<PopupMenuEntry<T>> items,
  void Function(T?) onSelected,
) {
  RelativeRect position = const RelativeRect.fromLTRB(0, 0, 0, 0);
  try {
    final box = context.findRenderObject() as RenderBox?;
    final screen = MediaQuery.of(context).size;
    if (box != null && box.hasSize && screen.width > 0 && screen.height > 0) {
      position =
          RelativeRect.fromRect(box.localToGlobal(Offset.zero) & box.size,
              Offset.zero & screen);
    } else {
      position = RelativeRect.fromLTRB(screen.width / 2, screen.height / 2,
          screen.width / 2, screen.height / 2);
    }
  } catch (e, st) { swallow(e, st); }
  showMenu<T>(context: context, position: position, items: items)
      .then(onSelected)
      .catchError((_) {});
}

/// v3.3 A/B 预设条：[A] [B] [复原]。
/// - 非 VB：点 A/B 直接切换（自动记录）。
/// - VB：点 A/B 弹下拉「自动保存 / 继承自 X-A…」（排除自身槽；继承 =
///   一次性复制，调参即归自定义）。
/// - 复原：清激活槽预设（继承的源预设不动）。
/// - [locked]（编辑器打开）时全部禁用。
class _AbPresetBar extends StatelessWidget {
  final PluginManager manager;
  final int slot;
  final int group;
  final bool isVb;
  final bool locked;
  final List<String> routeNames;

  const _AbPresetBar({
    required this.manager,
    required this.slot,
    required this.group,
    required this.isVb,
    required this.locked,
    required this.routeNames,
  });

  String _routeLabel(int route) =>
      route < 0 ? 'Main' : (route < routeNames.length ? routeNames[route] : 'R$route');

  void _onTapAb(BuildContext context, String ab) {
    if (locked) return;
    if (!isVb) {
      manager.selectAb(slot, group: group, ab: ab);
      return;
    }
    final l = l10nOf(context);
    final items = <PopupMenuEntry<String>>[
      PopupMenuItem<String>(
        value: 'auto',
        child: Text(l.abAutoSave),
      ),
      // 继承项：全部 route×AB 除自身槽（复制语义无循环，排除自身即防呆）。
      for (var r = 0; r < routeNames.length && r < 8; r++)
        for (final srcAb in ['A', 'B'])
          if (!(r == group && srcAb == ab))
            PopupMenuItem<String>(
              value: 'r$r:$srcAb',
              child: Text(l.abInheritFrom('${_routeLabel(r)}-$srcAb')),
            ),
    ];
    _safeShowMenu<String>(context, items, (v) {
      if (v == null) return;
      if (v == 'auto') {
        manager.selectAb(slot, group: group, ab: ab);
      } else {
        manager.selectAb(slot, group: group, ab: ab, inheritFrom: v);
      }
    });
  }

  Widget _abButton(BuildContext context, String ab) {
    final p = paletteOf(context);
    final active = manager.abActive(slot, group: group) == ab;
    final meta = manager.abMeta(slot, group: group, ab: ab);
    final hasState = meta['hasState'] == true;
    final color = locked
        ? p.textDim.withValues(alpha: 0.4)
        : active
            ? p.accent
            : hasState
                ? p.text
                : p.textDim;
    return Tooltip(
      message: ab == 'A' ? l10nOf(context).abSlotA : l10nOf(context).abSlotB,
      child: InkWell(
        onTap: locked ? null : () => _onTapAb(context, ab),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        child: Container(
          width: 26,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active && !locked
                ? p.accent.withValues(alpha: 0.18)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(
              color: active && !locked ? p.accent : p.hairline,
            ),
          ),
          child: Text(
            ab, // 用户定案：按钮始终显示 A / B
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final active = manager.abActive(slot, group: group);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _abButton(context, 'A'),
        const SizedBox(width: 4),
        _abButton(context, 'B'),
        const SizedBox(width: AuraSpace.xs),
        Tooltip(
          message: l10nOf(context).abReset,
          // IconButton 自带 32×32 触达区域（此前 20px InkWell 太小点不中）；
          // 清槽后 SnackBar 轻反馈（此前无可见变化被读成「点不动」）。
          child: IconButton(
            onPressed: locked
                ? null
                : () {
                    manager.resetAb(slot, group: group, ab: active);
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(l10nOf(context).abResetDone),
                        duration: const Duration(seconds: 1),
                        behavior: SnackBarBehavior.floating,
                      ),
                    );
                  },
            icon: Icon(
              Icons.restart_alt_rounded,
              size: 16,
              color: locked ? p.textDim.withValues(alpha: 0.4) : p.textDim,
            ),
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: l10nOf(context).abReset,
          ),
        ),
      ],
    );
  }
}

/// 活跃插件 Hero 卡片
class _ActivePluginHero extends StatelessWidget {
  final AppModel model;
  final PluginManager manager;
  final int slot;

  const _ActivePluginHero({
    required this.model,
    required this.manager,
    required this.slot,
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
            border: Border.all(color: p.hairline, style: BorderStyle.solid),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.developer_board_rounded,
                size: 40,
                color: p.textDim.withValues(alpha: 0.6),
              ),
              const SizedBox(height: AuraSpace.sm),
              Text(
                l10nOf(context).plugMountEmpty(slot + 1),
                style: sectionOf(p),
              ),
              const SizedBox(height: AuraSpace.xs),
              Text(l10nOf(context).plugMountEmptyHint, style: captionOf(p)),
            ],
          ),
        ),
      );
    }

    final isVst3 = active.format == PluginFormat.vst3;

    // v3.3 按路插件 + A/B 预设：下拉选路 = 打开该路引擎的编辑器 + 该路的
    // A/B 预设视图。选项源 = vbEffectiveRouteMask（通道开且插件勾）。
    // 「全部」选项已撤除（统一调音用「预设继承」表达）。
    final isVb = model.audioMode == 'vbcallback';
    final routeMask = model.vbEffectiveRouteMask;
    final editorGroup = model.vbPluginEditorGroup;
    final routeNames = vbBusNames(
      (model.vbInfo['edition'] as num?)?.toInt() ?? 0,
    );
    final routeCount = routeNames.length;
    // 打开界面的目标组（非 VB 单引擎 -1；VB = 当前选中路）。
    final openGroup = isVb ? editorGroup : -1;
    // A5（2026-10-22 审查）：VB 无有效路（通道全关/插件全不勾）时下拉
    // 已禁并显示旁路提示，但 A/B 条与 Ch strip 若继续以 group=-1 存活，
    // VB 下会落到 eng[0] 单组——与「无可操作路」的展示自相矛盾。无路态
    // 统一按锁定处理（按钮全禁、Ch 全灰）。
    final noRoute = isVb && openGroup < 0;
    // 路由锁定（编辑器打开时禁切换/禁 A/B/禁 Ch——用户定案）。
    final locked = manager.isSlotEditorOpen(slot) || noRoute;
    // Ch strip 可交互位：VB 非双耳仅 L/R 进插件链（泵层 procCh=2）；
    // 编辑器打开/无有效路时整体禁用（「禁止声道选择」）。
    final chInteractive = (locked || isBusy)
        ? 0x0
        : ((isVb && !model.spatialBinaural) ? 0x3 : 0xFF);

    final latencySamples = manager.getSlotLatency(slot);
    final status = manager.getSlotStatus(slot);
    // 插件延迟是「样本数」，必须按设备实际采样率换算，不是固定 48k。
    final latencyMs = (latencySamples / model.deviceRate * 1000.0)
        .toStringAsFixed(1);
    // Z15 诚实化：VB 模式下若当前编辑器目标路被 Z12 超预算保护旁路
    // （该路不进插件链、仅 vizStick 热组存活），「生效中」按钮如实
    // 显示「部分旁路」警示态。点击逻辑不变：点本按钮 → 全旁路；
    // 再点 → 按超预算开关回到保护旁路/正常激活。
    final partialBypass =
        isVb && !isBypassed && model.vbSelectedRouteProtectBypassed;

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
            Text(
              manager.slotBusyAction(slot) == 'unload'
                  ? l10nOf(context).plugUnloading
                  : l10nOf(context).plugLoading,
              style: labelOf(p, size: 11, color: p.textDim),
            ),
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
                horizontal: AuraSpace.md,
                vertical: AuraSpace.xs,
              ),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          // v2：预设按钮位改「总线下拉」——仅 VB 模式显示（其余模式单引擎
          // 无多路维度）。选项 = 有效路（通道开且插件勾）+「全部」置顶；
          // 无有效路时禁用并显示旁路提示。选中值 = vbPluginEditorGroup。
          if (isVb) ...[
            // 固定宽度：disabledHint（「界面已打开…」）比选中值长，不定宽会
            // 随禁用态撑宽框体（2026-10-22 用户报告尺寸抖动）。
            SizedBox(
              width: 108,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 2,
                ),
                decoration: BoxDecoration(
                  color: p.panel,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    isExpanded: true,
                    value: editorGroup >= 0 && editorGroup < routeCount
                        ? editorGroup
                        : null,
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
                    onChanged:
                        (routeMask == 0 || locked)
                        ? null // 路由锁定：仅编辑器打开时禁切换（busy 中可切看各路）
                        : (val) {
                            if (val == null) return;
                            // P2 自动记录：离开当前路由前落盘 A/B 激活槽。
                            manager.autoSaveAb(slot, group: editorGroup);
                            model.setVbPluginEditorGroup(val);
                          },
                  ),
                ),
              ),
            ),
            const SizedBox(width: AuraSpace.sm),
          ],
          // 旁路开关按钮（切换在途：spinner 替代文字 + 禁点，防连点/防卸载竞态）
          // 三态：已旁路（danger）/ 部分旁路（warning，Z15 保护旁路的当前路）
          // / 生效中（selected）。语义与数据源见上方 partialBypass 注释。
          AuraChip(
            isBypassed
                ? l10nOf(context).chainBypassed
                : (partialBypass
                    ? l10nOf(context).plugPartialBypass
                    : l10nOf(context).chainActive),
            selected: !isBypassed && !partialBypass,
            danger: isBypassed,
            warning: partialBypass,
            busy: manager.isSlotBypassPending(slot),
            onTap: (isBusy || manager.isSlotBypassPending(slot))
                ? null
                : () => manager.toggleBypass(slot: slot),
          ),
          const SizedBox(width: AuraSpace.sm),
          // 卸载按钮（旁路切换在途时同样禁点，避免重挂竞态）
          OutlinedButton.icon(
            onPressed: (isBusy || manager.isSlotBypassPending(slot))
                ? null
                : () => manager.unloadPlugin(slot: slot),
            icon: const Icon(Icons.eject_rounded, size: 15),
            label: Text(l10nOf(context).dlgUnload),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.error,
              side: BorderSide(color: p.error.withValues(alpha: 0.4)),
              padding: const EdgeInsets.symmetric(
                horizontal: AuraSpace.md,
                vertical: AuraSpace.xs,
              ),
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
              color: (isBypassed ? p.warning : p.accent).withValues(
                alpha: 0.08,
              ),
              blurRadius: 16,
              spreadRadius: 2,
            ),
          ],
        ),
        child: Column(
          children: [
            // 槽级加载/卸载动画（2026-10-22 用户需求）：进度条 + 动作文案，
            // per-slot busy 驱动——切到别的槽不受影响。大插件 5-6s 加载
            // 期间全按钮禁用（过分操作防护），音频侧旧插件已卸/新插件
            // 未就绪时链路直通不断音。
            // 卸载不显示此大动画（用户：多余）——trailing 小标已够。
            if (isBusy && manager.slotBusyAction(slot) == 'load') ...[
              ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  minHeight: 3,
                  color: p.accent,
                  backgroundColor: p.hairline,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  SizedBox(
                    width: 12,
                    height: 12,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: p.accent,
                    ),
                  ),
                  const SizedBox(width: AuraSpace.xs),
                  Text(
                    manager.slotBusyAction(slot) == 'unload'
                        ? l10nOf(context).plugUnloading
                        : l10nOf(context).plugLoading,
                    style: labelOf(p, size: 11, color: p.textDim),
                  ),
                ],
              ),
              const SizedBox(height: AuraSpace.sm),
            ],
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
                          Text(active.name, style: sectionOf(p)),
                          const SizedBox(width: AuraSpace.sm),
                          if (active.version.isNotEmpty)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
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
                            : (active.category.isNotEmpty
                                  ? active.category
                                  : "Fx"),
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
                    horizontal: AuraSpace.md,
                    vertical: AuraSpace.sm,
                  ),
                  decoration: BoxDecoration(
                    color: p.panel,
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    border: Border.all(color: p.hairline),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        l10nOf(context).plugLatencyLabel,
                        style: captionOf(p, color: p.textDim),
                      ),
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
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: p.panel,
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    border: Border.all(color: p.hairline),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<int>(
                    isExpanded: true,
                      value: currentStage,
                      isDense: true,
                      dropdownColor: p.panelRaised,
                      style: labelOf(p),
                      icon: Icon(
                        Icons.arrow_drop_down_rounded,
                        color: p.accent,
                      ),
                      items:
                          [
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
                                  color: stg == currentStage
                                      ? p.accent
                                      : p.text,
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
                // v3.3 A/B 预设条（所有驱动模式显示；VB 点击展开继承下拉）。
                _AbPresetBar(
                  manager: manager,
                  slot: slot,
                  group: isVb ? editorGroup : -1,
                  isVb: isVb,
                  locked: locked || isBusy,
                  routeNames: routeNames,
                ),
              ],
            ),
            const SizedBox(height: AuraSpace.sm),
            _PluginChannelStrip(
              // P1-4：Ch 按当前路由记忆取值/下发（「全部」= 第 9 套记忆）。
              mask: manager.getSlotChannels(
                slot,
                group: isVb ? editorGroup : -1,
              ),
              interactiveMask: chInteractive,
              onChanged: (m) => manager.setSlotChannels(
                m,
                slot: slot,
                group: isVb ? editorGroup : -1,
              ),
            ),
            const SizedBox(height: AuraSpace.xs),
            Row(
              children: [
                Icon(Icons.monitor_heart_rounded, size: 14, color: p.textDim),
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
