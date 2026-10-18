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

  static const List<({int bit, String code, String nameZh, String nameEn})> _channels = [
    (bit: 0, code: 'FL',  nameZh: '左前',  nameEn: 'Front Left'),
    (bit: 1, code: 'FR',  nameZh: '右前',  nameEn: 'Front Right'),
    (bit: 2, code: 'C',   nameZh: '中置',  nameEn: 'Center'),
    (bit: 3, code: 'LFE', nameZh: '超低',  nameEn: 'Subwoofer'),
    (bit: 4, code: 'SL',  nameZh: '左环',  nameEn: 'Surround L'),
    (bit: 5, code: 'SR',  nameZh: '右环',  nameEn: 'Surround R'),
    (bit: 6, code: 'BL',  nameZh: '左后',  nameEn: 'Back L'),
    (bit: 7, code: 'BR',  nameZh: '右后',  nameEn: 'Back R'),
  ];

  int get _mask {
    final v = widget.model.getParamById(widget.paramKey);
    if (v is int) return v;
    if (v is double) return v.toInt();
    return 0xFF; // 默认全开
  }

  void _updateMask(int newMask) {
    widget.model.setInt(widget.paramKey, newMask & 0xFF);
  }

  String _getSummaryText(int mask, bool isZh) {
    if (mask == 0xFF) return isZh ? '全声道 (8/8)' : 'All Channels (8/8)';
    if (mask == 0x03) return isZh ? '立体声 (FL/FR)' : 'Stereo (FL/FR)';
    if (mask == 0xF7) return isZh ? '无超低 (7/8)' : 'No Sub (7/8)';
    if (mask == 0x00) return isZh ? '全旁路 (0/8)' : 'All Bypassed (0/8)';
    if (mask == 0xF0) return isZh ? '仅环绕 (4/8)' : 'Surround Only (4/8)';

    int count = 0;
    for (int i = 0; i < 8; i++) {
      if ((mask & (1 << i)) != 0) count++;
    }
    return isZh ? '$count/8 声道已选' : '$count/8 Selected';
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isZh = Localizations.localeOf(context).languageCode == 'zh';
    final mask = _mask;
    final summary = _getSummaryText(mask, isZh);

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
                    widget.label ?? (isZh ? '高级声道路由' : 'Channel Routing'),
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
                        _buildChannelChip(context, p, ch, mask, isZh),
                    ],
                  ),
                  const SizedBox(height: 10),

                  // 快速预设按钮行
                  Row(
                    children: [
                      Text(
                        isZh ? '快速选择:' : 'Presets:',
                        style: captionOf(p, color: p.textDim).copyWith(fontSize: 11),
                      ),
                      const SizedBox(width: 8),
                      _buildPresetChip(p, isZh ? '全选' : 'All', 0xFF, mask),
                      const SizedBox(width: 6),
                      _buildPresetChip(p, isZh ? '立体声' : 'Stereo', 0x03, mask),
                      const SizedBox(width: 6),
                      _buildPresetChip(p, isZh ? '无超低' : 'No LFE', 0xF7, mask),
                      const SizedBox(width: 6),
                      _buildPresetChip(p, isZh ? '仅环绕' : 'Surround', 0xF0, mask),
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
    ({int bit, String code, String nameZh, String nameEn}) ch,
    int mask,
    bool isZh,
  ) {
    final isSelected = (mask & (1 << ch.bit)) != 0;
    final name = isZh ? ch.nameZh : ch.nameEn;

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
