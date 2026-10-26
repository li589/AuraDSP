// part of effects_page.dart —— EqualizerAPO 风格 8 声道独立路由选择器 (Phase 3)
part of '../effects_page.dart';

/* =========================================================================
 * EqualizerAPO 风格 8 声道独立声道路由器 (ChannelRoutingSelector)
 * ========================================================================= */

/// 可复用的 8 声道位掩码独立路由器
/// 允许用户在高级面板中针对特定声道（FL/FR/C/LFE/SL/SR/BL/BR）精确启闭效果器
class ChannelRoutingSelector extends StatefulWidget {
  final AppModel model;
  final String paramKey;
  final String? label;

  const ChannelRoutingSelector({
    super.key,
    required this.model,
    required this.paramKey,
    this.label,
  });

  /// 根据声道数返回存在的声道集合（与 engine layout_for(ch) 严格对齐）：
  /// 2ch: FL(0), FR(1)
  /// 4ch: FL(0), FR(1), BL(2), BR(3)
  /// 6ch: FL(0), FR(1), C(2), LFE(3), SL(4), SR(5)
  /// 8ch: FL(0), FR(1), C(2), LFE(3), SL(4), SR(5), BL(6), BR(7)
  static List<({int bit, String code})> channelsFor(int ch) =>
      _ChannelRoutingSelectorState.channelsFor(ch);

  static int fullMaskFor(int ch) =>
      _ChannelRoutingSelectorState.fullMaskFor(ch);

  @override
  State<ChannelRoutingSelector> createState() => _ChannelRoutingSelectorState();
}

class _ChannelRoutingSelectorState extends State<ChannelRoutingSelector> {
  bool _expanded = false;

  /// 根据声道数返回存在的声道集合（与 engine layout_for(ch) 严格对齐）：
  /// 2ch: FL(0), FR(1)
  /// 4ch: FL(0), FR(1), BL(2), BR(3)
  /// 6ch: FL(0), FR(1), C(2), LFE(3), SL(4), SR(5)
  /// 8ch: FL(0), FR(1), C(2), LFE(3), SL(4), SR(5), BL(6), BR(7)
  static List<({int bit, String code})> channelsFor(int ch) {
    if (ch == 4) {
      return const [
        (bit: 0, code: 'FL'),
        (bit: 1, code: 'FR'),
        (bit: 2, code: 'BL'),
        (bit: 3, code: 'BR'),
      ];
    }
    if (ch == 6) {
      return const [
        (bit: 0, code: 'FL'),
        (bit: 1, code: 'FR'),
        (bit: 2, code: 'C'),
        (bit: 3, code: 'LFE'),
        (bit: 4, code: 'SL'),
        (bit: 5, code: 'SR'),
      ];
    }
    if (ch >= 8) {
      return const [
        (bit: 0, code: 'FL'),
        (bit: 1, code: 'FR'),
        (bit: 2, code: 'C'),
        (bit: 3, code: 'LFE'),
        (bit: 4, code: 'SL'),
        (bit: 5, code: 'SR'),
        (bit: 6, code: 'BL'),
        (bit: 7, code: 'BR'),
      ];
    }
    return const [
      (bit: 0, code: 'FL'),
      (bit: 1, code: 'FR'),
    ];
  }

  /// X-6（2026-10-26 已修复）：dyneq/exciter 的 no-LFE 默认掩码由引擎随
  /// channels.count 按布局平移（4ch→0x0F、6ch→0x37），BR 不再被默认跳过；
  /// 用户自定义掩码保留（引擎仅当仍为旧布局默认值时才平移）。
  static int fullMaskFor(int ch) {
    if (ch == 4) return 0x0F; // 1 + 2 + 4 + 8
    if (ch == 6) return 0x3F; // 1 + 2 + 4 + 8 + 16 + 32
    if (ch >= 8) return 0xFF;
    return 0x03; // 1 + 2
  }

  int get _mask {
    final v = widget.model.getParamById(widget.paramKey);
    if (v is int) return v;
    if (v is double) return v.toInt();
    return 0xFF; // 默认全开
  }

  void _updateMask(int newMask) {
    // B-3（B1）：改走 setParamById 经 spec 链（setter→setInt+镜像），
    // 否则 spec getter（mirrorInt）读不到新值，UI 回显陈旧。
    widget.model.setParamById(widget.paramKey, newMask & 0xFF);
  }

  int _toggleBit(int mask, int bit) {
    return mask ^ (1 << bit);
  }

  /// 声道名走 l10n（此前手写 zh/en 双语，ja 无翻译）。
  String _channelName(AppLocalizations l, String code) {
    switch (code) {
      case 'FL':
        return l.routingChFl;
      case 'FR':
        return l.routingChFr;
      case 'C':
        return l.routingChC;
      case 'LFE':
        return l.routingChLfe;
      case 'SL':
        return l.routingChSl;
      case 'SR':
        return l.routingChSr;
      case 'BL':
        return l.routingChBl;
      case 'BR':
        return l.routingChBr;
    }
    return code;
  }

  String _getSummaryText(
    AppLocalizations l,
    int mask,
    int ch,
    bool isStereoPath,
  ) {
    if (isStereoPath) {
      return l.routingStereoPathSummary;
    }
    final activeChannels = channelsFor(ch);
    int selected = 0;
    for (final c in activeChannels) {
      if ((mask & (1 << c.bit)) != 0) selected++;
    }
    return l.routingSelectedCount(selected, activeChannels.length);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) {
        final p = paletteOf(context);
        final l = l10nOf(context);
        final ch = widget.model.effectiveChannelCount;
        final isStereo = widget.model.isStereoPath;
        final mask = _mask;
        final summary = _getSummaryText(l, mask, ch, isStereo);
        final activeChannels = channelsFor(ch);
        int selected = 0;
        for (final c in activeChannels) {
          if ((mask & (1 << c.bit)) != 0) selected++;
        }
        final isFull = selected == activeChannels.length;

        return Container(
          margin: const EdgeInsets.only(top: AuraSpace.sm),
          decoration: BoxDecoration(
            color: p.panelRaised.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(
              color: _expanded
                  ? p.accent.withValues(alpha: 0.3)
                  : p.hairline.withValues(alpha: 0.5),
              width: 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // 标题与展开折叠栏
              InkWell(
                borderRadius: BorderRadius.circular(AuraRadius.sm),
                onTap: () => setState(() => _expanded = !_expanded),
                child: Padding(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        _expanded
                            ? Icons.keyboard_arrow_down_rounded
                            : Icons.keyboard_arrow_right_rounded,
                        size: 18,
                        color: p.textDim,
                      ),
                      const SizedBox(width: 4),
                      Icon(Icons.alt_route_rounded, size: 15, color: p.accent),
                      const SizedBox(width: 6),
                      Text(
                        widget.label ?? l.channelRouting,
                        style: captionOf(p, color: p.text).copyWith(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: (isStereo || isFull)
                              ? p.panelRaised
                              : p.accent.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: (isStereo || isFull)
                                ? p.hairline
                                : p.accent.withValues(alpha: 0.4),
                          ),
                        ),
                        child: Text(
                          summary,
                          style: captionOf(p,
                                  color: (isStereo || isFull)
                                      ? p.textDim
                                      : p.accent)
                              .copyWith(
                            fontWeight: FontWeight.bold,
                            fontSize: 10,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // 展开面板内容
              if (_expanded)
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Divider(height: 1, thickness: 0.5, color: p.hairline),
                      const SizedBox(height: 8),

                      // U-6: 立体声/矩阵路径诚实提示
                      if (isStereo) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 6),
                          margin: const EdgeInsets.only(bottom: 8),
                          decoration: BoxDecoration(
                            color: p.panelRaised.withValues(alpha: 0.5),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(color: p.hairline),
                          ),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Icon(Icons.info_outline_rounded,
                                  size: 14, color: p.textDim),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(
                                  l.routingStereoPathHint,
                                  style: captionOf(p, color: p.textDim)
                                      .copyWith(fontSize: 11),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],

                      // U-7: 仅渲染当前布局实际存在的声道 Chips
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final chDef in activeChannels)
                            _buildChannelChip(context, p, chDef, mask),
                        ],
                      ),
                      const SizedBox(height: 10),

                      // 快速预设按钮行（根据工作声道自适应）
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [
                          Text(
                            l.routingPresets,
                            style: captionOf(p, color: p.textDim)
                                .copyWith(fontSize: 11),
                          ),
                          _buildPresetChip(
                              p, l.routingPresetAll, fullMaskFor(ch), mask),
                          if (ch == 4) ...[
                            _buildPresetChip(
                                p, l.routingPresetFront, 0x03, mask),
                            _buildPresetChip(
                                p, l.routingPresetBack, 0x0C, mask),
                          ] else ...[
                            _buildPresetChip(
                                p, l.routingPresetStereo, 0x03, mask),
                            if (ch >= 6)
                              _buildPresetChip(p, l.routingPresetNoLfe,
                                  fullMaskFor(ch) & ~0x08, mask),
                            if (ch == 6)
                              _buildPresetChip(
                                  p, l.routingPresetSurround, 0x30, mask),
                            if (ch >= 8)
                              _buildPresetChip(
                                  p, l.routingPresetSurround, 0xF0, mask),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildChannelChip(
    BuildContext context,
    AuraPalette p,
    ({int bit, String code}) ch,
    int mask,
  ) {
    final isSelected = (mask & (1 << ch.bit)) != 0;
    final name = _channelName(l10nOf(context), ch.code);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(6),
        onTap: () => _updateMask(_toggleBit(mask, ch.bit)),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
          decoration: BoxDecoration(
            color: isSelected
                ? p.accent.withValues(alpha: 0.18)
                : p.panelRaised.withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: isSelected ? p.accent : p.hairline,
              width: isSelected ? 1.2 : 1.0,
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                isSelected ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                size: 13,
                color: isSelected ? p.accent : p.textDim,
              ),
              const SizedBox(width: 5),
              Text(
                ch.code,
                style: monoOf(p).copyWith(
                  color: isSelected ? p.text : p.textDim,
                  fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                  fontSize: 11,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                name,
                style: captionOf(p, color: isSelected ? p.text : p.textDim).copyWith(
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPresetChip(AuraPalette p, String label, int targetMask, int currentMask) {
    final isCurrent = currentMask == targetMask;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () => _updateMask(targetMask),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: isCurrent ? p.accent.withValues(alpha: 0.12) : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: isCurrent ? p.accent.withValues(alpha: 0.4) : p.hairline.withValues(alpha: 0.6),
          ),
        ),
        child: Text(
          label,
          style: captionOf(p, color: isCurrent ? p.accent : p.textDim).copyWith(
            fontSize: 10,
            fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}
