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
        ChannelRoutingSelector(
          model: model,
          paramKey: 'shelf.channels',
          label: (Localizations.localeOf(context).languageCode == 'zh')
              ? l.bassShelfRouting
              : 'Low-shelf Channel Routing',
        ),
      ],
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
            const SizedBox(height: AuraSpace.xs),
            Text(
              l.bassMonoDesc,
              style: captionOf(p, color: p.textDim).copyWith(fontSize: 11),
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
              if (!canMerge && model.bassmonoOn) ...[
                const SizedBox(height: AuraSpace.xs),
                Text(
                  l.bassMonoMergeSinglePairHint,
                  style: captionOf(p, color: p.textDim).copyWith(fontSize: 10),
                ),
              ],
            ],

            // 摘要与诚实性提示行
            const SizedBox(height: AuraSpace.sm),
            _buildBassmonoSummary(p, l, stereoPath, activePairs, ignoredPairs, centerLfeSelected),
          ],
        );
      },
    );
  }

  Widget _buildBassmonoSummary(
    AuraPalette p,
    AppLocalizations l,
    bool stereoPath,
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

    if (stereoPath) {
      items.add(
        Padding(
          padding: const EdgeInsets.only(top: AuraSpace.xs),
          child: Row(
            children: [
              Icon(Icons.info_outline_rounded, size: 13, color: p.textDim),
              const SizedBox(width: AuraSpace.xs),
              Expanded(
                child: Text(
                  l.bassMonoStereoPathHint,
                  style: captionOf(p, color: p.textDim).copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      );
    }

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
