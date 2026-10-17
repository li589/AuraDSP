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
      index: kEffectCardIndex['comp'],
      title: l.compTitle,
      collapsed: !model.compOn,
      latencyMs: model.componentLatency('comp').ms,
      latencyMeasured: model.componentLatency('comp').measured,
      latencyEstimated: model.componentLatency('comp').estimated,
      latencyProbing: model.isProbingLatency('comp'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('comp')
          ? () => model.refreshComponentLatency('comp')
          : null,
      latencyTick: model.getComponentLatencyTick('comp'),
      trailing: ParamSwitch(
        param: ParamRegistry.compEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 响应时常数（Time Constant）主滑块
          ParamSlider(
            param: ParamRegistry.compTimeconstant,
            model: model,
            customLabel: l.compTimeconstant,
            infoMessage: '控制动态压缩与包络跟踪的释放响应时间。较小时瞬态冲击更明显，较大时动态压缩更平顺通透。',
            customMin: 0.02,
            customUnit: 'ms',
            customFormat: (v) => (v * 1000).toStringAsFixed(0),
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
                    ParamChoiceChips(
                      param: ParamRegistry.compGranularity,
                      model: model,
                      labels: [
                        l.compGranularityCoarse,
                        l.compGranularityNormal,
                        l.compGranularityFine,
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
                    ParamChoiceChips(
                      param: ParamRegistry.compTfresolution,
                      model: model,
                      labels: [
                        l.compTfresTransient,
                        l.compTfresBalanced,
                        l.compTfresFine,
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.md),
                // 3. 输出级外框（自动增益补偿与输出增益门）
                OutputGainFrame(
                  child: Column(
                    children: [
                      ParamAutoGainRow(
                        param: ParamRegistry.compAutoGain,
                        model: model,
                        label: l.autoGainCompensation,
                        tooltip: l.autoGainCompensationTooltip,
                      ),
                      const SizedBox(height: AuraSpace.xs),
                      ParamOutputGainSlider(
                        param: ParamRegistry.compOutputGain,
                        model: model,
                        label: l.outputGainGate,
                        infoMessage: l.outputGainGateTooltip,
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
