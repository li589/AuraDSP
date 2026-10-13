// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 01 Compressor (动态压限器) ---- */

class _CompressorCard extends StatelessWidget {
  final AppModel model;
  const _CompressorCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: '01',
      title: l.compTitle,
      collapsed: !model.compOn,
      latencyMs: model.componentLatency('comp').ms,
      latencyMeasured: model.componentLatency('comp').measured,
      latencyProbing: model.isProbingLatency('comp'),
      onRefreshLatency: () => model.refreshComponentLatency('comp'),
      latencyTick: model.getComponentLatencyTick('comp'),
      trailing: AuraSwitch(
        value: model.compOn,
        onChanged: model.setCompEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 响应时常数（Time Constant）主滑块
          ValueSlider(
            label: l.compTimeconstant,
            infoMessage: '控制动态压缩与包络跟踪的释放响应时间。较小时瞬态冲击更明显，较大时动态压缩更平顺通透。',
            value: model.compTimeconstant,
            defaultValue: 0.14,
            min: 0.02,
            max: 1.0,
            unit: 'ms',
            enabled: model.compOn,
            format: (v) => (v * 1000).toStringAsFixed(0),
            onChanged: model.setCompTimeconstant,
            onChangedEnd: model.setCompTimeconstant,
            onResetToDefault: () => model.setCompTimeconstant(0.14),
          ),
          const SizedBox(height: AuraSpace.sm),
          AdvancedSection(
            summary: '${model.compGranularity == 0 ? l.compGranularityCoarse : (model.compGranularity == 1 ? l.compGranularityNormal : l.compGranularityFine)} · AGC: ${model.compAutoGain ? "ON" : "OFF"} · ${(model.compOutputGain >= 0 ? "+" : "")}${model.compOutputGain.toStringAsFixed(1)} dB',
            builder: (ctx) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 分析颗粒度模式 (Granularity)
                Row(
                  children: [
                    Text(l.compGranularity, style: labelOf(p, color: p.text)),
                    const Spacer(),
                    Wrap(
                      spacing: AuraSpace.sm,
                      children: [
                        AuraChoiceChip(
                          label: l.compGranularityCoarse,
                          selected: model.compGranularity == 0,
                          onTap: model.compOn ? () => model.setCompGranularity(0) : null,
                        ),
                        AuraChoiceChip(
                          label: l.compGranularityNormal,
                          selected: model.compGranularity == 1,
                          onTap: model.compOn ? () => model.setCompGranularity(1) : null,
                        ),
                        AuraChoiceChip(
                          label: l.compGranularityFine,
                          selected: model.compGranularity == 2,
                          onTap: model.compOn ? () => model.setCompGranularity(2) : null,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                // 2. 时频分辨率 (Time-Frequency Resolution)
                Row(
                  children: [
                    Text(l.compTfresolution, style: labelOf(p, color: p.text)),
                    const Spacer(),
                    Wrap(
                      spacing: AuraSpace.sm,
                      children: [
                        AuraChoiceChip(
                          label: l.compTfresTransient,
                          selected: model.compTfresolution == 0,
                          onTap: model.compOn ? () => model.setCompTfresolution(0) : null,
                        ),
                        AuraChoiceChip(
                          label: l.compTfresBalanced,
                          selected: model.compTfresolution == 1,
                          onTap: model.compOn ? () => model.setCompTfresolution(1) : null,
                        ),
                        AuraChoiceChip(
                          label: l.compTfresFine,
                          selected: model.compTfresolution == 2,
                          onTap: model.compOn ? () => model.setCompTfresolution(2) : null,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.md),
                // 3. 输出级外框（自动增益补偿与输出增益门）
                OutputGainFrame(
                  child: Column(
                    children: [
                      _AutoGainRow(
                        label: l.autoGainCompensation,
                        tooltip: l.autoGainCompensationTooltip,
                        value: model.compAutoGain,
                        enabled: model.compOn,
                        onChanged: model.setCompAutoGain,
                      ),
                      const SizedBox(height: AuraSpace.xs),
                      ValueSlider(
                        label: l.outputGainGate,
                        infoMessage: l.outputGainGateTooltip,
                        value: model.compOutputGain,
                        defaultValue: ParamDefaults.compOutputGain,
                        onResetToDefault: () =>
                            model.setCompOutputGain(ParamDefaults.compOutputGain),
                        min: -12.0,
                        max: 6.0,
                        unit: 'dB',
                        enabled: model.compOn,
                        format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                        onChanged: model.setCompOutputGain,
                        onChangedEnd: model.setCompOutputGain,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
