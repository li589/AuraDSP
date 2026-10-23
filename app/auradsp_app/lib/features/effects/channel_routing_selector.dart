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

  @override
  State<ChannelRoutingSelector> createState() => _ChannelRoutingSelectorState();
}

class _ChannelRoutingSelectorState extends State<ChannelRoutingSelector> {
  bool _expanded = false;

  static const List<({int bit, String code})> _channels = [
    (bit: 0, code: 'FL'),
    (bit: 1, code: 'FR'),
    (bit: 2, code: 'C'),
    (bit: 3, code: 'LFE'),
    (bit: 4, code: 'SL'),
    (bit: 5, code: 'SR'),
    (bit: 6, code: 'BL'),
    (bit: 7, code: 'BR'),
  ];

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

  String _getSummaryText(AppLocalizations l, int mask) {
    if (mask == 0xFF) return l.routingAllChannels;
    if (mask == 0x03) return l.routingStereo;
    if (mask == 0xF7) return l.routingNoSub;
    if (mask == 0x00) return l.routingAllBypassed;
    if (mask == 0xF0) return l.routingSurroundOnly;

    int count = 0;
    for (int i = 0; i < 8; i++) {
      if ((mask & (1 << i)) != 0) count++;
    }
    return l.routingSelectedCount(count);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final mask = _mask;
    final summary = _getSummaryText(l, mask);

    return Container(
      margin: const EdgeInsets.only(top: AuraSpace.sm),
      decoration: BoxDecoration(
        color: p.panelRaised.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: _expanded ? p.accent.withValues(alpha: 0.3) : p.hairline.withValues(alpha: 0.5),
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
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    _expanded ? Icons.keyboard_arrow_down_rounded : Icons.keyboard_arrow_right_rounded,
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
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: mask == 0xFF
                          ? p.panelRaised
                          : p.accent.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: mask == 0xFF
                            ? p.hairline
                            : p.accent.withValues(alpha: 0.4),
                      ),
                    ),
                    child: Text(
                      summary,
                      style: captionOf(p, color: mask == 0xFF ? p.textDim : p.accent).copyWith(
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

                  // 8 声道多选 Chips
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final ch in _channels)
                        _buildChannelChip(context, p, ch, mask),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // 快速预设按钮行
                  Row(
                    children: [
                      Text(
                        l.routingPresets,
                        style: captionOf(p, color: p.textDim).copyWith(fontSize: 11),
                      ),
                      const SizedBox(width: 8),
                      _buildPresetChip(p, l.routingPresetAll, 0xFF, mask),
                      const SizedBox(width: 6),
                      _buildPresetChip(p, l.routingPresetStereo, 0x03, mask),
                      const SizedBox(width: 6),
                      _buildPresetChip(p, l.routingPresetNoLfe, 0xF7, mask),
                      const SizedBox(width: 6),
                      _buildPresetChip(p, l.routingPresetSurround, 0xF0, mask),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
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
        onTap: () => _updateMask(mask ^ (1 << ch.bit)),
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
