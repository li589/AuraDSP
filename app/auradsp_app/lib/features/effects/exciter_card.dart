// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 06C Exciter (激励器，最后一道音色工序) ----
 * HPF 取高频 + tanh 谐波混回。只暴露 amount/hifreq（drive 固定防刺耳）。
 * 文案禁用“杜比/母带级”等词。 */
class _ExciterCard extends StatelessWidget {
  final AppModel model;
  const _ExciterCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: kEffectCardIndex['exciter'],
      title: l.stExciter,
      collapsed: !model.exciterOn,
      latencyMs: model.componentLatency('exciter').ms,
      latencyMeasured: model.componentLatency('exciter').measured,
      latencyEstimated: model.componentLatency('exciter').estimated,
      latencyProbing: model.isProbingLatency('exciter'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('exciter')
          ? () => model.refreshComponentLatency('exciter')
          : null,
      latencyTick: model.getComponentLatencyTick('exciter'),
      trailing: ParamSwitch(
        param: ParamRegistry.exciterEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 激励器模式（当前仅 tanh 一种算法：纯文本展示，不用芯片——芯片意味着
          // 可点，单个永选中的死选项是假交互）
          Row(
            children: [
              Text(l.exciterMode, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.exciterModeTooltip),
              const Spacer(),
              HqOversampleBadge(
                active: model.exciterOversample,
                onChanged: model.setExciterOversample,
              ),
              const SizedBox(width: AuraSpace.sm),
              Text('tanh', style: monoOf(p, size: 12, color: p.textDim)),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // 谐波量
          ParamSlider(
            param: ParamRegistry.exciterAmount,
            model: model,
            customLabel: l.exciterAmount,
            infoMessage: l.exciterAmountInfo,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 取频点
          ParamSlider(
            param: ParamRegistry.exciterHifreq,
            model: model,
            customLabel: l.exciterHifreq,
            infoMessage: l.exciterHifreqInfo,
            customFormat: (v) => '${(v / 1000).toStringAsFixed(1)}k',
          ),
          ChannelRoutingSelector(
            model: model,
            paramKey: 'exciter.channels',
          ),
        ],
      ),
    );
  }
}
