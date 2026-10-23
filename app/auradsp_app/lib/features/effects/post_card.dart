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
      latencyMs: model.componentLatency('post').ms,
      latencyEnabled: model.isSectionEnabled('post'),
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
