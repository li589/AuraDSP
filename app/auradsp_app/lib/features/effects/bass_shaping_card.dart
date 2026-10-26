// part of effects_page.dart —— 低音塑形卡片 (Bass Shaping, WP4 / D11).
// 包含低频搁架 (Low Shelf) 与低频单声道化 (Bass Mono) 两个独立模块。
// 共享 import 见父文件。
part of '../effects_page.dart';

class BassShapingCard extends StatelessWidget {
  final AppModel model;
  const BassShapingCard({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return SectionCard(
      index: kEffectCardIndex['bass_shaping'],
      title: l.bassShapingTitle,
      titleTooltip: l.bassShapingMasterHint,
      collapsed: !model.bassShapingOn,
      latencyMs: model.componentLatency('bass_shaping').ms,
      latencyEnabled: model.isSectionEnabled('bass_shaping'),
      latencyMeasured: model.componentLatency('bass_shaping').measured,
      latencyEstimated: model.componentLatency('bass_shaping').estimated,
      latencyProbing: model.isProbingLatency('bass_shaping'),
      onRefreshLatency: AppModel.hasLatencyRefresh('bass_shaping')
          ? () => model.refreshComponentLatency('bass_shaping')
          : null,
      latencyTick: model.getComponentLatencyTick('bass_shaping'),
      trailing: AuraSwitch(
        value: model.bassShapingOn,
        onChanged: (v) => model.setBassShapingEnabled(v),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 模块 1: 低频搁架 (Low Shelf)
          _buildShelfModule(context, p, l),

          const SizedBox(height: AuraSpace.md),
          Divider(height: 1, thickness: 0.5, color: p.hairline),
          const SizedBox(height: AuraSpace.md),

          // 模块 2: 低频单声道化 (Bass Mono)
          _buildBassmonoModule(context, p, l),
        ],
      ),
    );
  }

  Widget _buildShelfModule(BuildContext context, AuraPalette p, AppLocalizations l) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.tune_rounded, size: 16, color: p.accent),
            const SizedBox(width: AuraSpace.xs),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      l.bassShelfModule,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: labelOf(p, size: 13).copyWith(fontWeight: FontWeight.w600),
                    ),
                  ),
                  const SizedBox(width: AuraSpace.xs),
                  InfoBadge(message: l.shelfHint),
                ],
              ),
            ),
            AuraSwitch(
              value: model.shelfOn,
              onChanged: (v) => model.setShelfEnabled(v),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        ParamSlider(
          param: ParamRegistry.shelfFreq,
          model: model,
          customLabel: l.shelfFreq,
          infoMessage: l.shelfFreqTooltip,
          enabled: model.shelfOn,
        ),
        const SizedBox(height: AuraSpace.sm),
        ParamSlider(
          param: ParamRegistry.shelfGain,
          model: model,
          customLabel: l.shelfGain,
          infoMessage: l.shelfGainTooltip,
          enabled: model.shelfOn,
        ),
        const SizedBox(height: AuraSpace.sm),
        _buildShelfRoutingRow(context, p, l),
      ],
    );
  }

  Widget _buildShelfRoutingRow(BuildContext context, AuraPalette p, AppLocalizations l) {
    return ValueListenableBuilder<int>(
      valueListenable: model.vizChannelCount,
      builder: (context, rawCount, _) {
        var chCount = rawCount;
        if (chCount <= 0) chCount = model.effectiveChannelCount;
        if (chCount > 8) chCount = 8;
        if (chCount % 2 != 0) chCount += 1;

        final channels = ChannelRoutingSelector.channelsFor(chCount);
        final rawVal = model.getParamById('shelf.channels');
        final int currentMask = (rawVal is int)
            ? rawVal
            : (rawVal is double ? rawVal.toInt() : ChannelRoutingSelector.fullMaskFor(chCount));

        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  l.channelSelection,
                  style: labelOf(p, size: 12).copyWith(
                    fontWeight: FontWeight.w600,
                    color: model.shelfOn ? p.text : p.textDim,
                  ),
                ),
                const SizedBox(width: AuraSpace.xs),
                InfoBadge(message: l.bassShelfRoutingHint),
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
                      for (var i = 0; i < channels.length; i++) ...[
                        if (i > 0) const SizedBox(width: AuraSpace.xxs),
                        _buildShelfChannelChip(
                          p,
                          channels[i].bit,
                          channels[i].code,
                          (currentMask & (1 << channels[i].bit)) != 0,
                          model.shelfOn,
                          currentMask,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildShelfChannelChip(
    AuraPalette p,
    int bit,
    String code,
    bool isSelected,
    bool enabled,
    int currentMask,
  ) {
    final Color bgColor = isSelected && enabled
        ? p.accent.withValues(alpha: 0.16)
        : p.panelRaised.withValues(alpha: 0.40);
    final Color borderColor = isSelected && enabled ? p.accent : p.hairline;
    final Color textColor = !enabled
        ? p.textDim
        : (isSelected ? p.text : p.textDim);

    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          mouseCursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onTap: enabled
              ? () => model.setParamById('shelf.channels', currentMask ^ (1 << bit))
              : null,
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: bgColor,
              borderRadius: BorderRadius.circular(AuraRadius.xs),
              border: Border.all(color: borderColor, width: isSelected && enabled ? 1.2 : 1.0),
            ),
            child: Text(
              code,
              style: monoOf(p, size: 11, color: textColor).copyWith(
                fontWeight: isSelected && enabled ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBassmonoModule(BuildContext context, AuraPalette p, AppLocalizations l) {
    return ValueListenableBuilder<int>(
      valueListenable: model.vizChannelCount,
      builder: (context, vizCh, _) {
        final ch = vizCh > 0 ? vizCh : 2;
        final bool binaural = model.spatialBinaural && model.spatialOn && ch >= 4;
        final bool stereoPath = model.channelsMode == 0 || binaural || ch == 2;

        bool isAvail(int bit) {
          if (stereoPath) return bit == 0;
          return switch (bit) {
            0 => true,
            1 || 2 => ch >= 6,
            3 => ch == 4 || ch >= 8,
            _ => false,
          };
        }

        final rawMask = model.bassmonoPairs;
        var activePairs = 0;
        var ignoredPairs = 0;
        for (var b = 0; b < 4; b++) {
          final set = (rawMask & (1 << b)) != 0;
          if (set) {
            if (isAvail(b)) {
              activePairs++;
            } else {
              ignoredPairs++;
            }
          }
        }

        final bool centerLfeSelected = isAvail(1) && ((rawMask & (1 << 1)) != 0);
        final bool canMerge = activePairs >= 2;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(Icons.waves_rounded, size: 16, color: p.accent),
                const SizedBox(width: AuraSpace.xs),
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          l.bassMonoModule,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: labelOf(p, size: 13).copyWith(fontWeight: FontWeight.w600),
                        ),
                      ),
                      const SizedBox(width: AuraSpace.xs),
                      InfoBadge(message: l.bassMonoDesc),
                    ],
                  ),
                ),
                AuraSwitch(
                  value: model.bassmonoOn,
                  onChanged: (v) => model.setBassmonoEnabled(v),
                ),
              ],
            ),
            const SizedBox(height: AuraSpace.sm),
            ParamSlider(
              param: ParamRegistry.bassmonoFreq,
              model: model,
              customLabel: l.bassmonoFreq,
              infoMessage: l.bassmonoFreqTooltip,
              enabled: model.bassmonoOn,
            ),
            const SizedBox(height: AuraSpace.sm),
            PairRouteSelector(
              model: model,
              channelCount: ch,
              stereoPath: stereoPath,
              enabled: model.bassmonoOn,
            ),
            if (!stereoPath) ...[
              const SizedBox(height: AuraSpace.sm),
              LayoutBuilder(
                builder: (context, constraints) {
                  final isWide = constraints.maxWidth >= 420;
                  final segmented = AuraSegmented<int>(
                    segments: [
                      AuraSegment(0, l.bassMonoMergePerPair),
                      AuraSegment(1, l.bassMonoMergeGlobal),
                    ],
                    selected: model.bassmonoMerge,
                    onChanged: model.bassmonoOn && canMerge
                        ? (v) => model.setBassmonoMerge(v)
                        : null,
                  );

                  if (isWide) {
                    return Row(
                      children: [
                        SizedBox(
                          width: 140,
                          child: Row(
                            children: [
                              Text(
                                l.bassMonoMerge,
                                style: labelOf(p, size: 13).copyWith(
                                  color: model.bassmonoOn ? p.text : p.textDim,
                                ),
                              ),
                              const SizedBox(width: AuraSpace.xs),
                              InfoBadge(
                                message: '${l.bassMonoMergePerPair} / ${l.bassMonoMergeGlobal}',
                              ),
                            ],
                          ),
                        ),
                        Expanded(child: segmented),
                      ],
                    );
                  } else {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              l.bassMonoMerge,
                              style: labelOf(p, size: 13).copyWith(
                                color: model.bassmonoOn ? p.text : p.textDim,
                              ),
                            ),
                            const SizedBox(width: AuraSpace.xs),
                            InfoBadge(
                              message: '${l.bassMonoMergePerPair} / ${l.bassMonoMergeGlobal}',
                            ),
                          ],
                        ),
                        const SizedBox(height: AuraSpace.xs),
                        segmented,
                      ],
                    );
                  }
                },
              ),
            ],

            // 摘要与诚实性提示行
            const SizedBox(height: AuraSpace.sm),
            _buildBassmonoSummary(p, l, activePairs, ignoredPairs, centerLfeSelected),
          ],
        );
      },
    );
  }

  Widget _buildBassmonoSummary(
    AuraPalette p,
    AppLocalizations l,
    int activePairs,
    int ignoredPairs,
    bool centerLfeSelected,
  ) {
    if (!model.bassmonoOn) {
      return Text(
        '—',
        style: captionOf(p, color: p.textDim),
      );
    }

    final List<Widget> items = [];

    final modeLabel = model.bassmonoMerge == 0 ? l.bassMonoMergePerPair : l.bassMonoMergeGlobal;
    final summaryText =
        '${model.bassmonoFreq.toInt()} Hz · ${l.bassMonoPairCount(activePairs)} · $modeLabel';

    items.add(
      Text(
        summaryText,
        style: captionOf(p, color: p.textDim).copyWith(fontSize: 11),
      ),
    );

    if (activePairs == 0) {
      items.add(
        Padding(
          padding: const EdgeInsets.only(top: AuraSpace.xs),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: p.warning),
              const SizedBox(width: AuraSpace.xs),
              Expanded(
                child: Text(
                  l.bassMonoNoneSelected,
                  style: captionOf(p, color: p.warning).copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (ignoredPairs > 0) {
      items.add(
        Padding(
          padding: const EdgeInsets.only(top: AuraSpace.xs),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: p.warning),
              const SizedBox(width: AuraSpace.xs),
              Expanded(
                child: Text(
                  l.bassMonoIgnoredPairs(ignoredPairs),
                  style: captionOf(p, color: p.warning).copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (centerLfeSelected) {
      items.add(
        Padding(
          padding: const EdgeInsets.only(top: AuraSpace.xs),
          child: Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: p.warning),
              const SizedBox(width: AuraSpace.xs),
              Expanded(
                child: Text(
                  l.bassMonoLfeWarning,
                  style: captionOf(p, color: p.warning).copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items,
    );
  }
}

typedef _BassShapingCard = BassShapingCard;
