// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 06B Haas 差分环绕 (右声道延迟 + 干湿混合) ----
 * stereo 后 / reverb 前；左声道恒直通保单声道兼容。
 * 延迟滑块到 0 只归零延迟，不关开关（stereo 解耦教训）。 */
class _HaasCard extends StatelessWidget {
  final AppModel model;
  const _HaasCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: kEffectCardIndex['haas'],
      title: l.stHaas,
      collapsed: !model.haasOn,
      latencyMs: model.componentLatency('haas').ms,
      latencyEnabled: model.isSectionEnabled('haas'),
      latencyMeasured: model.componentLatency('haas').measured,
      latencyEstimated: model.componentLatency('haas').estimated,
      latencyProbing: model.isProbingLatency('haas'),
      onRefreshLatency: AppModel.hasLatencyRefresh('haas')
          ? () => model.refreshComponentLatency('haas')
          : null,
      latencyTick: model.getComponentLatencyTick('haas'),
      trailing: ParamSwitch(
        param: ParamRegistry.haasEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 延迟侧切换（差分环绕的声道偏好）
          Row(
            children: [
              Text(l.haasSide, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.haasSideTooltip),
              const Spacer(),
              ParamChoiceChips(
                param: ParamRegistry.haasSide,
                model: model,
                labels: [l.haasSideRight, l.haasSideLeft],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // 延迟量
          ParamSlider(
            param: ParamRegistry.haasDelay,
            model: model,
            customLabel: l.haasDelay,
            infoMessage: l.haasHintDelay,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 干湿混合
          ParamSlider(
            param: ParamRegistry.haasMix,
            model: model,
            customLabel: l.haasMix,
            infoMessage: l.haasHintWet,
          ),
          // [P-031] 诚实标注：本卡效果器在引擎侧只作用于前置 FL/FR 对
          // （engine_chain.cpp:895-903 在 mx_stereo 上处理），多声道离散
          // 模式下环绕/LFE 不经过它。此前 UI 无任何说明，用户会以为
          // "多声道独立处理"覆盖到本卡。
          const SizedBox(height: AuraSpace.sm),
          Text(
            l.flfrOnlyHint,
            style: captionOf(p, color: p.textDim).copyWith(fontSize: 10),
          ),
        ],
      ),
    );
  }
}
