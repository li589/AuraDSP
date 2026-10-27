// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 06D Loudness (响度补偿，最后一道音色工序) ----
 * 信号自适应等响度：慢速电平跟随估计回放响度，越静补得越多
 * （低频 +10dB / 高频 +6dB 上限，再乘 amount）。响亮信号直通。 */
class _LoudnessCard extends StatelessWidget {
  final AppModel model;
  const _LoudnessCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);

    return SectionCard(
      index: kEffectCardIndex['loudness'],
      title: l.stLoudness,
      collapsed: !model.loudnessOn,
      latencyMs: model.componentLatency('loudness').ms,
      latencyEnabled: model.isSectionEnabled('loudness'),
      latencyMeasured: model.componentLatency('loudness').measured,
      latencyEstimated: model.componentLatency('loudness').estimated,
      latencyProbing: model.isProbingLatency('loudness'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('loudness')
          ? () => model.refreshComponentLatency('loudness')
          : null,
      latencyTick: model.getComponentLatencyTick('loudness'),
      trailing: ParamSwitch(
        param: ParamRegistry.loudnessEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // [P-032] 移除卡片顶部的重复说明行：同样的文案已经挂在
          // 「补偿强度」滑块右侧的气泡（infoMessage: l.loudnessHint）上，
          // 两处并排展示属于同一句话重复。
          ParamSlider(
            param: ParamRegistry.loudnessAmount,
            model: model,
            customLabel: l.loudnessAmount,
            infoMessage: l.loudnessHint,
          ),
          ChannelRoutingSelector(
            model: model,
            paramKey: 'loudness.channels',
          ),
        ],
      ),
    );
  }
}
