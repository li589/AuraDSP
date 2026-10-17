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
      index: kEffectCardIndex['filter'],
      title: l.stFilter,
      collapsed: !model.filterOn,
      latencyMs: model.componentLatency('filter').ms,
      latencyMeasured: model.componentLatency('filter').measured,
      latencyEstimated: model.componentLatency('filter').estimated,
      latencyProbing: model.isProbingLatency('filter'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('filter')
          ? () => model.refreshComponentLatency('filter')
          : null,
      latencyTick: model.getComponentLatencyTick('filter'),
      trailing: ParamSwitch(
        param: ParamRegistry.filterEnable,
        model: model,
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
              ParamChoiceChips(
                param: ParamRegistry.filterType,
                model: model,
                labels: [l.filterHP, l.filterLP, l.filterBP],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // 频率
          ParamSlider(
            param: ParamRegistry.filterFreq,
            model: model,
            customLabel: l.filterFreq,
            infoMessage: 'HP 低于该频率衰减，LP 高于该频率衰减，BP 以该频率为中心通过。',
            customFormat: (v) => v >= 1000
                ? '${(v / 1000).toStringAsFixed(1)}k'
                : v.toStringAsFixed(0),
          ),
          const SizedBox(height: AuraSpace.sm),
          // Q
          ParamSlider(
            param: ParamRegistry.filterQ,
            model: model,
            customLabel: l.filterQ,
            infoMessage: '谐振强度。BP 的带宽全靠它；HP/LP 只在转折处有峰。',
          ),
        ],
      ),
    );
  }
}
