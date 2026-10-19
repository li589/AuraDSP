// part of effects_page.dart —— 低音塑形卡片 (Bass Shaping).
// 融合低频搁架滤波 (Low-shelf) 与低频单声道化 (Bass Mono)，规范为单一低频控制效果器。
// 共享 import 见父文件。
part of '../effects_page.dart';

class _BassShapingCard extends StatelessWidget {
  final AppModel model;
  const _BassShapingCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);

    return SectionCard(
      index: kEffectCardIndex['bass_shaping'],
      title: l.bassShapingTitle,
      titleTooltip: l.bassShapingHint,
      collapsed: !model.bassShapingOn,
      latencyMs: model.componentLatency('bass_shaping').ms,
      latencyMeasured: model.componentLatency('bass_shaping').measured,
      latencyEstimated: model.componentLatency('bass_shaping').estimated,
      latencyProbing: model.isProbingLatency('bass_shaping'),
      onRefreshLatency: AppModel.hasLatencyRefresh('bass_shaping')
          ? () => model.refreshComponentLatency('bass_shaping')
          : null,
      latencyTick: model.getComponentLatencyTick('bass_shaping'),
      trailing: ParamSwitch(
        param: ParamRegistry.bassShapingEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ParamSlider(
            param: ParamRegistry.shelfFreq,
            model: model,
            customLabel: l.shelfFreq,
            infoMessage: l.shelfFreqTooltip,
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.shelfGain,
            model: model,
            customLabel: l.shelfGain,
            infoMessage: l.shelfGainTooltip,
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.bassmonoFreq,
            model: model,
            customLabel: l.bassmonoFreq,
            infoMessage: l.bassmonoFreqTooltip,
          ),
          ChannelRoutingSelector(
            model: model,
            paramKey: 'shelf.channels',
            label: (Localizations.localeOf(context).languageCode == 'zh')
                ? '低频搁架声道路由'
                : 'Low-shelf Channel Routing',
          ),
        ],
      ),
    );
  }
}
