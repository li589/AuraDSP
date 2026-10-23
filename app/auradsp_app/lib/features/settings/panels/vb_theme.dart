part of '../../settings_page.dart';
// part of '../settings_page.dart' —— P1-1（2026-10-23）机械拆分，零逻辑改动。


class _EngineInfo extends StatelessWidget {
  final AppModel model;
  const _EngineInfo({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final info = model.info;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (info != null) ...[
          _InfoRow('ABI', 'v${info.abi} · ${info.version}'),
        ],
        _InfoRow('Latency', '${model.latencyMs.toStringAsFixed(1)} ms'),
        const SizedBox(height: AuraSpace.md),
        Container(height: 1, color: p.hairline),
        const SizedBox(height: AuraSpace.md),
        Text(l.about, style: sectionOf(p)),
        const SizedBox(height: AuraSpace.sm),
        Text(l.aboutBody, style: captionOf(p)),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String k, v;
  const _InfoRow(this.k, this.v);

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AuraSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(k, style: labelOf(p, size: 12, color: p.textDim)),
          ),
          Expanded(child: Text(v, style: monoOf(p, size: 12))),
        ],
      ),
    );
  }
}

/* ---- VB 总线：版型→总线名 + 每总线电平 + 处理开关 ----
 * SDK BUFFER_OUT 布局：每条总线 8 通道 = 泵的 1 组（g0 起）。
 * 版型→总线名共享版见 widgets.dart vbBusNames()。
 * 开关 = vb_set_bus_mask 对应 bit；关=该总线直通（电平表照常计量）。
 * 复选框 = vb_plugin_group_enable 对应 bit（按路插件处理，2026-10-22）；
 * 勾选 = 挂载的插件处理该路；厂商 DSP 不受影响。
 * 电平来自 vbstatus 心跳的 peakGrp（约 1/s，桥内半衰期约 1s）。 */

class _VbBuses extends StatelessWidget {
  final AppModel model;
  const _VbBuses({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final info = model.vbInfo;
    final edition = (info['edition'] as num?)?.toInt() ?? 0;
    final groups = (info['groups'] as num?)?.toInt() ?? 0;
    final names = vbBusNames(edition);
    final peaks = (info['peakGrp'] as List?)
            ?.map((e) => (e as num?)?.toDouble() ?? 0.0)
            .toList() ??
        const <double>[];
    final live = (info['grpLive'] as num?)?.toInt() ?? 0;
    final n = groups.clamp(0, names.length);
    if (n <= 0) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: AuraSpace.sm),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.vbBuses, style: labelOf(p, size: 12, color: p.textDim)),
          const SizedBox(height: AuraSpace.xs),
          _VbProtectRow(model: model),
          const SizedBox(height: AuraSpace.xs),
          for (var g = 0; g < n; g++)
            _VbBusRow(
              name: names[g],
              peak: g < peaks.length ? peaks[g] : 0.0,
              live: (live & (1 << g)) != 0,
              on: (model.vbBusMask & (1 << g)) != 0,
              onToggle: (v) => model.setVbBus(g, v),
              pluginOn: (model.vbPluginGroupMask & (1 << g)) != 0,
              onPluginToggle: (v) => model.setVbPluginGroup(g, v),
            ),
        ],
      ),
    );
  }
}

/* ---- Z12 超预算自动保护（2026-10-23）：开关 + 预算占用/激活态 ----
 * 数据来自 vbstatus 心跳的 protect/cbEmaUs/budgetUs（约 1s 一拍）。
 * 激活 = 非监听总线插件直通——用户听感变化必须可见可解，故 warning 醒目提示；
 * budgetUs<=0（桥未运行/旧桥 DLL）时只显示开关。 */
class _VbProtectRow extends StatelessWidget {
  final AppModel model;
  const _VbProtectRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final info = model.vbInfo;
    final prot = (info['protect'] as num?)?.toInt() ?? 0;
    final emaUs = (info['cbEmaUs'] as num?)?.toInt() ?? 0;
    final budgetUs = (info['budgetUs'] as num?)?.toInt() ?? 0;
    final active = prot == 1;
    final detail = active
        ? l.vbProtectActive
        : (budgetUs > 0
            ? '${l.vbProtectHint}  ·  EMA ${(emaUs / 1000).toStringAsFixed(1)}ms / '
                '${(budgetUs / 1000).toStringAsFixed(1)}ms'
            : l.vbProtectHint);
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AuraSpace.sm, vertical: 4),
      decoration: BoxDecoration(
        color: active ? p.warning.withValues(alpha: 0.10) : p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: active ? p.warning : p.hairline, width: 1),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.vbAutoProtect,
                    style: labelOf(p, size: 12,
                        color: active ? p.warning : p.text)),
                Text(detail,
                    style: labelOf(p, size: 11,
                        color: active ? p.warning : p.textDim)),
              ],
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          _MiniToggle(
              on: model.vbAutoProtect,
              onToggle: (v) => model.setVbAutoProtect(v)),
        ],
      ),
    );
  }
}

/* ---- VB 总线行：名 + LED 灯段表 + 紧凑开关 ----
 * 灯段 12 格，dB 刻度（-54..0，每格 4.5dB；0dB 以上并入顶格）：
 * 低 9 格 success、上 2 格 warning、顶格 error——颜色全取自 palette，
 * 换主题自动跟；熄灭格用 hairline 做"暗槽"，复古调音台味。
 * 心跳约 1/s，灯段天然低刷新；行内另做 100ms 淡入淡出防闪烁即可。 */

class _VbBusRow extends StatelessWidget {
  final String name;
  final double peak;
  final bool live;
  final bool on;
  final ValueChanged<bool> onToggle;
  /// 按路插件处理（2026-10-22）：复选框位于 DSP 开关左侧，
  /// hover 气泡说明语义；勾选 = 挂载的插件处理该路。
  final bool pluginOn;
  final ValueChanged<bool> onPluginToggle;
  const _VbBusRow(
      {required this.name,
      required this.peak,
      required this.live,
      required this.on,
      required this.onToggle,
      required this.pluginOn,
      required this.onPluginToggle});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final row = Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(name,
                style: monoOf(p, size: 12,
                    color: live ? p.text : p.textDim)),
          ),
          Expanded(child: _LedMeter(peak: live ? peak : 0.0, on: on)),
          const SizedBox(width: AuraSpace.sm),
          // 按路插件处理复选框（DSP 开关左侧）：视觉密度与 _MiniToggle 对齐。
          // 通道处理开关（右侧）关闭时整组直通、插件不跑——复选框灰显但
          // **保留勾选状态**（插件实例常驻，重开开关立即恢复，无重新加载）。
          Tooltip(
            message: on ? l.vbPluginTooltip : l.vbPluginLockedHint,
            triggerMode: TooltipTriggerMode.tap,
            showDuration: const Duration(seconds: 4),
            child: SizedBox(
              width: 30,
              height: 28,
              child: Checkbox(
                value: pluginOn,
                onChanged: on ? (v) => onPluginToggle(v ?? false) : null,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
          ),
          const SizedBox(width: AuraSpace.xs),
          _MiniToggle(on: on, onToggle: onToggle),
        ],
      ),
    );
    // VB 没给这条总线 buffer（未路由/未分配）：整行置灰，开关照常可用
    // （VB 一旦送数，处理立刻生效）。
    if (!live) return Opacity(opacity: 0.45, child: row);
    return row;
  }
}

class _LedMeter extends StatelessWidget {
  final double peak;
  final bool on;
  const _LedMeter({required this.peak, required this.on});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    // 线性峰值→dB；底噪以下钳 -60。
    final db = peak <= 0
        ? -60.0
        : (20 * (math.log(peak) / math.ln10)).clamp(-60.0, 3.0);
    // -54dB 起亮，每格 4.5dB，12 格到 0dB。
    final lit = ((db + 54) / 4.5).floor().clamp(0, 12);
    // P0-3：12 格灯段每秒随心跳重绘，隔离重绘区。
    return RepaintBoundary(
      child: SizedBox(
        height: 8,
        child: Row(
          children: [
            for (var i = 0; i < 12; i++)
              Expanded(
                child: Padding(
                  padding: EdgeInsets.only(right: i == 11 ? 0 : 3),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 100),
                    curve: Curves.easeOut,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(1.5),
                      color: i < lit
                          ? (i < 9
                              ? p.success
                              : i < 11
                                  ? p.warning
                                  : p.error)
                          : p.hairline,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/* 紧凑开关 30×18：胶囊底 + 滑块点，120ms 位移动画；关=直通。 */

class _MiniToggle extends StatelessWidget {
  final bool on;
  final ValueChanged<bool> onToggle;
  const _MiniToggle({required this.on, required this.onToggle});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return GestureDetector(
      onTap: () => onToggle(!on),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        width: 30,
        height: 18,
        padding: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          color: on ? p.accent : p.panelRaised,
          border: Border.all(
              color: on ? p.accent : p.hairline, width: 1),
        ),
        alignment: on ? Alignment.centerRight : Alignment.centerLeft,
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: on ? p.accentContrast : p.textDim,
          ),
        ),
      ),
    );
  }
}



class _ThemeCard extends StatefulWidget {
  final String name;
  final bool selected;
  final List<Color> swatch;
  final VoidCallback onTap;
  const _ThemeCard({
    required this.name,
    required this.selected,
    required this.swatch,
    required this.onTap,
  });

  @override
  State<_ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<_ThemeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final border = widget.selected
        ? p.accent
        : (_hover ? p.textDim.withValues(alpha: 0.5) : p.hairline);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AuraDur.base,
          curve: AuraCurve.standard,
          padding: const EdgeInsets.all(AuraSpace.sm),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.accent.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: border, width: widget.selected ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AuraRadius.xs),
                child: SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      for (final c in widget.swatch)
                        Expanded(child: Container(color: c)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AuraSpace.sm),
              AnimatedDefaultTextStyle(
                duration: AuraDur.fast,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w400,
                  color: widget.selected ? p.text : p.textDim,
                ),
                child: Text(widget.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

