// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 00C Filter (独立滤波器，gate 后 / bassmono 前) ----
 * RBJ HP/LP/BP。HP 去隆隆声防误开噪声门；Q 全类型有效（HP/LP 用同一 Q）。 */
class _FilterCard extends StatelessWidget {
  final AppModel model;
  const _FilterCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: '00',
      title: l.stFilter,
      collapsed: !model.filterOn,
      latencyMs: model.componentLatency('filter').ms,
      latencyMeasured: model.componentLatency('filter').measured,
      latencyProbing: model.isProbingLatency('filter'),
      onRefreshLatency: () => model.refreshComponentLatency('filter'),
      latencyTick: model.getComponentLatencyTick('filter'),
      trailing: AuraSwitch(
        value: model.filterOn,
        onChanged: model.setFilterEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.filterHint, style: captionOf(p)),
          const SizedBox(height: AuraSpace.sm),
          // 类型三选一
          Row(
            children: [
              Text(l.filterType, style: labelOf(p, color: p.text)),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  AuraChoiceChip(
                    label: l.filterHP,
                    selected: model.filterType == 0,
                    onTap: model.filterOn ? () => model.setFilterType(0) : null,
                  ),
                  AuraChoiceChip(
                    label: l.filterLP,
                    selected: model.filterType == 1,
                    onTap: model.filterOn ? () => model.setFilterType(1) : null,
                  ),
                  AuraChoiceChip(
                    label: l.filterBP,
                    selected: model.filterType == 2,
                    onTap: model.filterOn ? () => model.setFilterType(2) : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // 频率
          ValueSlider(
            label: l.filterFreq,
            infoMessage: 'HP 低于该频率衰减，LP 高于该频率衰减，BP 以该频率为中心通过。',
            value: model.filterFreq,
            defaultValue: ParamDefaults.filterFreq,
            onResetToDefault: () =>
                model.setFilterFreq(ParamDefaults.filterFreq),
            min: 20,
            max: 20000,
            unit: 'Hz',
            enabled: model.filterOn,
            format: (v) => v >= 1000
                ? '${(v / 1000).toStringAsFixed(1)}k'
                : v.toStringAsFixed(0),
            onChanged: model.setFilterFreq,
            onChangedEnd: model.setFilterFreq,
          ),
          const SizedBox(height: AuraSpace.sm),
          // Q
          ValueSlider(
            label: l.filterQ,
            infoMessage: '谐振强度。BP 的带宽全靠它；HP/LP 只在转折处有峰。',
            value: model.filterQ,
            defaultValue: ParamDefaults.filterQ,
            onResetToDefault: () =>
                model.setFilterQ(ParamDefaults.filterQ),
            min: 0.3,
            max: 10,
            unit: '',
            enabled: model.filterOn,
            format: (v) => v.toStringAsFixed(2),
            onChanged: model.setFilterQ,
            onChangedEnd: model.setFilterQ,
          ),
        ],
      ),
    );
  }
}
