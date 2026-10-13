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
      index: '12',
      title: l.stExciter,
      collapsed: !model.exciterOn,
      latencyMs: model.componentLatency('exciter').ms,
      latencyMeasured: model.componentLatency('exciter').measured,
      latencyProbing: model.isProbingLatency('exciter'),
      onRefreshLatency: () => model.refreshComponentLatency('exciter'),
      latencyTick: model.getComponentLatencyTick('exciter'),
      trailing: AuraSwitch(
        value: model.exciterOn,
        onChanged: model.setExciterEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 激励器模式
          Row(
            children: [
              Text(l.exciterMode, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.exciterModeTooltip),
              const Spacer(),
              AuraChip(
                'tanh',
                selected: true,
                onTap: null,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // 谐波量
          ValueSlider(
            label: l.exciterAmount,
            infoMessage: l.exciterAmountInfo,
            value: model.exciterAmount,
            defaultValue: ParamDefaults.exciterAmount,
            onResetToDefault: () =>
                model.setExciterAmount(ParamDefaults.exciterAmount),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.exciterOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setExciterAmount,
            onChangedEnd: model.setExciterAmount,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 取频点
          ValueSlider(
            label: l.exciterHifreq,
            infoMessage: '只取该频率以上成分做谐波。MP3 缺高频时往低调，齿音重时往高调。',
            value: model.exciterHifreq,
            defaultValue: ParamDefaults.exciterHifreq,
            onResetToDefault: () =>
                model.setExciterHifreq(ParamDefaults.exciterHifreq),
            min: 3000,
            max: 10000,
            unit: 'Hz',
            enabled: model.exciterOn,
            format: (v) => '${(v / 1000).toStringAsFixed(1)}k',
            onChanged: model.setExciterHifreq,
            onChangedEnd: model.setExciterHifreq,
          ),
        ],
      ),
    );
  }
}
