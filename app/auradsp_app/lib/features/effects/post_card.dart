// part of effects_page.dart —— 后级总输出增益与 Modern Lookahead Limiter 卡片
part of '../effects_page.dart';

class _PostCard extends StatelessWidget {
  final AppModel model;
  const _PostCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: kEffectCardIndex['post'],
      title: l.postGain,
      latencyMs: model.limiterOn ? model.componentLatency('post').ms : 0.0,
      latencyEnabled: model.limiterOn,
      latencyMeasured: model.componentLatency('post').measured,
      latencyEstimated: model.componentLatency('post').estimated,
      latencyProbing: model.isProbingLatency('post'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('post')
          ? () => model.refreshComponentLatency('post')
          : null,
      latencyTick: model.getComponentLatencyTick('post'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ParamSlider(
            param: ParamRegistry.postGain,
            model: model,
            customLabel: l.postGain,
            infoMessage: l.postHintGain,
          ),
          const SizedBox(height: AuraSpace.xs),
          _PostChannelTrimSection(model: model),
          const SizedBox(height: AuraSpace.md),
          Container(height: 1, color: p.hairline),
          const SizedBox(height: AuraSpace.md),
          SectionTitle(
            l.limiter,
            trailing: ParamSwitch(
              param: ParamRegistry.postLimiterEnable,
              model: model,
            ),
          ),
          const SizedBox(height: AuraSpace.sm),

          // 核心限幅区：左侧控制参数，右侧下坠式 GR 仪表
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 阈值 (Threshold)
                    ParamSlider(
                      param: ParamRegistry.limiterThreshold,
                      model: model,
                      customLabel: l.postCeiling,
                      infoMessage: l.postHintCeiling,
                      enabled: model.limiterOn,
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 释放时间 (Release)
                    ParamSlider(
                      param: ParamRegistry.limiterRelease,
                      model: model,
                      customLabel: l.postRelease,
                      infoMessage: l.postHintRelease,
                      enabled: model.limiterOn,
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 开关行：1.5ms 前瞻 + 立体声联动
                    Row(
                      children: [
                        Text(l.postLookahead, style: labelOf(p, color: p.text)),
                        const SizedBox(width: 4),
                        InfoBadge(message: l.postHintLookahead),
                        const Spacer(),
                        ParamSwitch(
                          param: ParamRegistry.limiterLookahead,
                          model: model,
                          enabled: model.limiterOn,
                        ),
                      ],
                    ),
                    const SizedBox(height: AuraSpace.xs),
                    Row(
                      children: [
                        Text(l.postStereoLink, style: labelOf(p, color: p.text)),
                        const SizedBox(width: 4),
                        InfoBadge(message: l.postHintStereoLink),
                        const Spacer(),
                        ParamSwitch(
                          param: ParamRegistry.limiterLink,
                          model: model,
                          enabled: model.limiterOn,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AuraSpace.md),
              // 垂直下坠式 GR 仪表
              GainReductionMeter(
                grListenable: model.grLimiter,
                label: 'LIMIT',
                height: 156.0,
                width: 36.0,
                maxDb: 24.0,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          ChannelRoutingSelector(
            model: model,
            paramKey: 'limiter.channels',
          ),
        ],
      ),
    );
  }
}

class _PostChannelTrimSection extends StatelessWidget {
  final AppModel model;
  const _PostChannelTrimSection({required this.model});

  static List<String> _labelsFor(int ch) {
    if (ch == 4) return const ['FL', 'FR', 'BL', 'BR'];
    if (ch == 6) return const ['FL', 'FR', 'C', 'LFE', 'SL', 'SR'];
    if (ch == 8) return const ['FL', 'FR', 'C', 'LFE', 'SL', 'SR', 'BL', 'BR'];
    return const ['FL', 'FR'];
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return ValueListenableBuilder<int>(
      valueListenable: model.vizChannelCount,
      builder: (context, rawCount, _) {
        var chCount = rawCount;
        if (chCount <= 0) chCount = model.effectiveChannelCount;
        if (chCount > 8) chCount = 8;
        if (chCount % 2 != 0) chCount += 1;

        final labels = _labelsFor(chCount);
        final trims = List<double>.generate(
          chCount,
          (c) => model.mirrorFloat('post.gain.c$c', 0.0),
        );
        final nonZeroIndices = [
          for (var i = 0; i < chCount; i++)
            if ((trims[i] - 0.0).abs() > 0.001) i
        ];
        final nonZeroCount = nonZeroIndices.length;

        final summary = nonZeroCount == 0
            ? '0.0 dB'
            : (nonZeroCount == 1
                ? '${labels[nonZeroIndices[0]]}: ${trims[nonZeroIndices[0]] > 0 ? "+" : ""}${trims[nonZeroIndices[0]].toStringAsFixed(1)} dB'
                : '$nonZeroCount ch');

        return AdvancedSection(
          summary: summary,
          helpTooltip: l.postPerChannelTrimHint,
          builder: (ctx) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      l.postPerChannelTrim,
                      style: labelOf(p, color: p.text, size: 12).copyWith(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(width: 4),
                    InfoBadge(message: l.postPerChannelTrimHint),
                    const Spacer(),
                    if (nonZeroCount > 0)
                      TextButton.icon(
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                        icon: const Icon(Icons.refresh_rounded, size: 13),
                        label: Text(l.postResetAllTrim, style: const TextStyle(fontSize: 11)),
                        onPressed: () {
                          for (var c = 0; c < 8; c++) {
                            model.setFloat('post.gain.c$c', 0.0);
                          }
                        },
                      ),
                  ],
                ),
                const SizedBox(height: AuraSpace.xs),
                for (var c = 0; c < chCount; c++)
                  ValueSlider(
                    label: labels[c],
                    value: trims[c],
                    defaultValue: 0.0,
                    min: -15.0,
                    max: 15.0,
                    unit: 'dB',
                    format: (v) => (v > 0 ? '+${v.toStringAsFixed(1)}' : v.toStringAsFixed(1)),
                    onChanged: (v) => model.setFloat('post.gain.c$c', v),
                    onResetToDefault: () => model.setFloat('post.gain.c$c', 0.0),
                  ),
              ],
            );
          },
        );
      },
    );
  }
}

