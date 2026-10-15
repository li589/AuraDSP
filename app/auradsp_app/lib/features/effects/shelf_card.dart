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
      index: '02',
      title: l.shelfTitle,
      collapsed: !model.shelfOn,
      latencyMs: model.componentLatency('shelf').ms,
      latencyMeasured: model.componentLatency('shelf').measured,
      latencyProbing: model.isProbingLatency('shelf'),
      onRefreshLatency: () => model.refreshComponentLatency('shelf'),
      latencyTick: model.getComponentLatencyTick('shelf'),
      trailing: AuraSwitch(
        value: model.shelfOn,
        onChanged: model.setShelfEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.shelfHint, style: captionOf(paletteOf(context))),
          const SizedBox(height: AuraSpace.sm),
          ValueSlider(
            label: l.shelfFreq,
            infoMessage: l.shelfFreqInfo,
            value: model.shelfFreq,
            defaultValue: ParamDefaults.shelfFreq,
            onResetToDefault: () =>
                model.setShelfFreq(ParamDefaults.shelfFreq),
            min: 40,
            max: 400,
            unit: 'Hz',
            enabled: model.shelfOn,
            format: (v) => v.toStringAsFixed(0),
            onChanged: model.setShelfFreq,
            onChangedEnd: model.setShelfFreq,
          ),
          const SizedBox(height: AuraSpace.sm),
          ValueSlider(
            label: l.shelfGain,
            infoMessage: l.shelfGainInfo,
            value: model.shelfGain,
            defaultValue: ParamDefaults.shelfGain,
            onResetToDefault: () =>
                model.setShelfGain(ParamDefaults.shelfGain),
            min: -15,
            max: 15,
            unit: 'dB',
            enabled: model.shelfOn,
            format: (v) =>
                '${v >= 0 ? "+" : ""}${v.toStringAsFixed(1)}',
            onChanged: model.setShelfGain,
            onChangedEnd: model.setShelfGain,
          ),
        ],
      ),
    );
  }
}
