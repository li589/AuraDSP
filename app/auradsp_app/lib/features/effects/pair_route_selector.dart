// part of effects_page.dart —— BassMono 多声道声道对选择器 (WP4 / D11).
part of '../effects_page.dart';

/* =========================================================================
 * BassMono 声道对选择器 (PairRouteSelector)
 * ========================================================================= */

class PairRouteSelector extends StatefulWidget {
  final AppModel model;
  final String paramKey;
  final int channelCount;
  final bool stereoPath;
  final bool enabled;

  const PairRouteSelector({
    super.key,
    required this.model,
    this.paramKey = 'bassmono.pairs',
    required this.channelCount,
    required this.stereoPath,
    this.enabled = true,
  });

  @override
  State<PairRouteSelector> createState() => _PairRouteSelectorState();
}

class _PairRouteSelectorState extends State<PairRouteSelector> {
  static const _pairs = [
    (bit: 0, a: 'FL', b: 'FR', nameKey: 'bassMonoPairFront'),
    (bit: 1, a: 'C', b: 'LFE', nameKey: 'bassMonoPairCenterLfe'),
    (bit: 2, a: 'SL', b: 'SR', nameKey: 'bassMonoPairSide'),
    (bit: 3, a: 'BL', b: 'BR', nameKey: 'bassMonoPairBack'),
  ];

  int get _mask {
    final v = widget.model.getParamById(widget.paramKey);
    if (v is int) return v & 0x0F;
    if (v is double) return v.toInt() & 0x0F;
    return 0x01;
  }

  bool _isAvailable(int bit) {
    if (widget.stereoPath) {
      return bit == 0;
    }
    return switch (bit) {
      0 => true,
      1 || 2 => widget.channelCount >= 6,
      3 => widget.channelCount == 4 || widget.channelCount >= 8,
      _ => false,
    };
  }

  void _updateMask(int newMask) {
    if (!widget.enabled) return;
    widget.model.setParamById(widget.paramKey, newMask & 0x0F);
  }

  String _pairName(AppLocalizations l, String nameKey) => switch (nameKey) {
        'bassMonoPairFront' => l.bassMonoPairFront,
        'bassMonoPairCenterLfe' => l.bassMonoPairCenterLfe,
        'bassMonoPairSide' => l.bassMonoPairSide,
        'bassMonoPairBack' => l.bassMonoPairBack,
        _ => '',
      };

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final mask = _mask;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              l.bassMonoPairs,
              style: labelOf(p, size: 12).copyWith(
                fontWeight: FontWeight.w600,
                color: widget.enabled ? p.text : p.textDim,
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            InfoBadge(message: l.bassMonoPairsTooltip),
          ],
        ),
        const SizedBox(width: AuraSpace.xs),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < _pairs.length; i++) ...[
                    if (i > 0) const SizedBox(width: AuraSpace.xs),
                    _buildPairChip(context, p, l, _pairs[i], mask),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }


  Widget _buildPairChip(
    BuildContext context,
    AuraPalette p,
    AppLocalizations l,
    ({int bit, String a, String b, String nameKey}) pair,
    int mask,
  ) {
    final isAvail = _isAvailable(pair.bit);
    final isSelected = (mask & (1 << pair.bit)) != 0;
    final isCenterLfe = pair.bit == 1;
    final name = _pairName(l, pair.nameKey);
    final code = '${pair.a}/${pair.b}';

    Color bgColor;
    Color borderColor;
    Color textColor;
    Color iconColor;
    IconData icon;
    double borderWidth = 1.0;

    if (!isAvail) {
      bgColor = p.panelRaised.withValues(alpha: 0.40);
      borderColor = p.hairline.withValues(alpha: 0.5);
      textColor = p.textDim;
      iconColor = p.textDim;
      icon = Icons.radio_button_unchecked_rounded;
    } else if (isSelected) {
      if (isCenterLfe) {
        bgColor = p.warning.withValues(alpha: 0.14);
        borderColor = p.warning;
        borderWidth = 1.2;
        textColor = p.text;
        iconColor = p.warning;
        icon = Icons.warning_amber_rounded;
      } else {
        bgColor = p.accent.withValues(alpha: 0.16);
        borderColor = p.accent;
        borderWidth = 1.2;
        textColor = p.text;
        iconColor = p.accent;
        icon = Icons.check_circle_rounded;
      }
    } else {
      bgColor = p.panelRaised.withValues(alpha: 0.40);
      borderColor = p.hairline;
      textColor = p.textDim;
      iconColor = p.textDim;
      icon = Icons.radio_button_unchecked_rounded;
    }

    Widget content = AnimatedContainer(
      duration: AuraDur.fast,
      curve: AuraCurve.standard,
      height: AuraSize.chipH,
      padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: borderColor, width: borderWidth),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: iconColor),
          const SizedBox(width: AuraSpace.xs),
          Text(
            code,
            style: monoOf(p, size: 11, color: textColor).copyWith(
              fontWeight: isSelected && isAvail ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
          const SizedBox(width: AuraSpace.xs),
          Text(
            name,
            style: captionOf(p, color: textColor).copyWith(
              fontSize: 10,
              fontWeight: isSelected && isAvail ? FontWeight.w600 : FontWeight.w400,
            ),
          ),
        ],
      ),
    );

    if (!isAvail || !widget.enabled) {
      content = Opacity(
        opacity: 0.45,
        child: content,
      );
    }

    final tooltip = isAvail
        ? (isCenterLfe && isSelected ? l.bassMonoLfeWarning : '')
        : l.bassMonoPairUnavailable;

    if (tooltip.isNotEmpty) {
      content = Tooltip(
        message: tooltip,
        child: content,
      );
    }

    final unavailSuffix = isAvail ? '' : ' (${l.bassMonoPairUnavailable})';
    final selSuffix = isSelected ? ' (Selected)' : '';
    final semanticLabel = '$code $name$unavailSuffix$selSuffix';

    return Semantics(
      button: true,
      selected: isSelected,
      enabled: isAvail && widget.enabled,
      label: semanticLabel,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          mouseCursor: isAvail && widget.enabled
              ? SystemMouseCursors.click
              : SystemMouseCursors.basic,
          onTap: isAvail && widget.enabled
              ? () => _updateMask(mask ^ (1 << pair.bit))
              : null,
          child: content,
        ),
      ),
    );
  }
}
