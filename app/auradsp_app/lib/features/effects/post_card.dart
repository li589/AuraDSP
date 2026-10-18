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
            infoMessage: '全局总输出音量补偿。多重 DSP 处理后若音量偏小可适当微调。',
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
                      customLabel: '限幅阈值',
                      infoMessage: '母带级前瞻限幅门限。超过此门限的瞬态将被透明压制，彻底防止任何削波失真与真峰值 (ISP) 溢出。',
                      enabled: model.limiterOn,
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 释放时间 (Release)
                    ParamSlider(
                      param: ParamRegistry.limiterRelease,
                      model: model,
                      customLabel: '释放时间',
                      infoMessage: '限幅器包络释放衰减时间。时间较短瞬态紧实有力，时间较长音质顺滑无抽吸感。',
                      enabled: model.limiterOn,
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 开关行：1.5ms 前瞻 + 立体声联动
                    Row(
                      children: [
                        Text('1.5ms 前瞻', style: labelOf(p, color: p.text)),
                        const SizedBox(width: 4),
                        const InfoBadge(message: '1.5ms 自适应平滑前瞻。开启后提供广播母带级零失真削峰，关闭则进入零延迟电竞/监听模式。'),
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
                        Text('立体声联动', style: labelOf(p, color: p.text)),
                        const SizedBox(width: 4),
                        const InfoBadge(message: '开启后左右声道按能量最大侧联合限幅，防止大动态瞬态导致声像意外偏移。'),
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
