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
    final p = paletteOf(context);

    return SectionCard(
      index: '06',
      title: l.stLoudness,
      collapsed: !model.loudnessOn,
      latencyMs: model.componentLatency('loudness').ms,
      latencyMeasured: model.componentLatency('loudness').measured,
      latencyProbing: model.isProbingLatency('loudness'),
      onRefreshLatency: () => model.refreshComponentLatency('loudness'),
      latencyTick: model.getComponentLatencyTick('loudness'),
      trailing: AuraSwitch(
        value: model.loudnessOn,
        onChanged: model.setLoudnessEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.loudnessHint, style: captionOf(p)),
          const SizedBox(height: AuraSpace.sm),
          ValueSlider(
            label: l.loudnessAmount,
            infoMessage: '补偿强度。小音量夜听开高，大音量开低或关（响亮时自动直通）。',
            value: model.loudnessAmount,
            defaultValue: ParamDefaults.loudnessAmount,
            onResetToDefault: () =>
                model.setLoudnessAmount(ParamDefaults.loudnessAmount),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.loudnessOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setLoudnessAmount,
            onChangedEnd: model.setLoudnessAmount,
          ),
        ],
      ),
    );
  }
}
