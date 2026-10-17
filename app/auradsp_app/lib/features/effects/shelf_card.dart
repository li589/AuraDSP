// part of effects_page.dart —— 低频搁架卡（M5-b）。
// 引擎/回放/预设早已就绪，此前唯独没有 UI（P0 孤儿参数接线）。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- Shelf 低频搁架（bassmono 后 / vendor 链前；与 bass 卡的"模式"无关） ---- */
class _ShelfCard extends StatelessWidget {
  final AppModel model;
  const _ShelfCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);

    return SectionCard(
      index: kEffectCardIndex['shelf'],
      title: l.shelfTitle,
      collapsed: !model.shelfOn,
      latencyMs: model.componentLatency('shelf').ms,
      latencyMeasured: model.componentLatency('shelf').measured,
      latencyEstimated: model.componentLatency('shelf').estimated,
      latencyProbing: model.isProbingLatency('shelf'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('shelf')
          ? () => model.refreshComponentLatency('shelf')
          : null,
      latencyTick: model.getComponentLatencyTick('shelf'),
      trailing: ParamSwitch(
        param: ParamRegistry.shelfEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.shelfHint, style: captionOf(paletteOf(context))),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.shelfFreq,
            model: model,
            customLabel: l.shelfFreq,
            infoMessage: l.shelfFreqInfo,
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.shelfGain,
            model: model,
            customLabel: l.shelfGain,
            infoMessage: l.shelfGainInfo,
          ),
        ],
      ),
    );
  }
}
