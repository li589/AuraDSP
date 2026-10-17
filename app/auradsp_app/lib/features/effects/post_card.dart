// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
class _PostCard extends StatelessWidget {
  final AppModel model;
  const _PostCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
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
          Container(height: 1, color: paletteOf(context).hairline),
          const SizedBox(height: AuraSpace.md),
          SectionTitle(
            l.limiter,
            trailing: ParamSwitch(
              param: ParamRegistry.postLimiterEnable,
              model: model,
            ),
          ),
        ],
      ),
    );
  }
}
