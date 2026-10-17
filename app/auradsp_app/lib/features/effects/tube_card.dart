// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 07 Tube Simulator (电子管模拟器) ---- */

class _TubeCard extends StatelessWidget {
  final AppModel model;
  const _TubeCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return SectionCard(
      index: kEffectCardIndex['tube'],
      title: l.tubeTitle,
      collapsed: !model.tubeOn,
      latencyMs: model.componentLatency('tube').ms,
              latencyMeasured: model.componentLatency('tube').measured,
              latencyEstimated: model.componentLatency('tube').estimated,
              latencyProbing: model.isProbingLatency('tube'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('tube')
          ? () => model.refreshComponentLatency('tube')
          : null,
      latencyTick: model.getComponentLatencyTick('tube'),
      trailing: ParamSwitch(
        param: ParamRegistry.tubeEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 饱和驱动度 (Drive / Saturation)
          ParamSlider(
            param: ParamRegistry.tubeGain,
            model: model,
            customLabel: l.tubeDrive,
            infoMessage: '模拟经典电子管偶次谐波失真。带来醇厚耐听的模拟胶片暖色调，消除数码干冷感。',
          ),
          const SizedBox(height: AuraSpace.md),
          // 电子管音色风格 — 标签与选项同行，选项右对齐
          Row(
            children: [
              Text(l.tubeStyle, style: labelOf(p, color: p.text)),
              const Spacer(),
              ParamChoiceChips(
                param: ParamRegistry.tubeStyle,
                model: model,
                labels: [l.tubeStyleTriode, l.tubeStylePentode, l.tubeStyleTape],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _TubeAdvanced(model: model),
        ],
      ),
    );
  }
}

class _TubeAdvanced extends StatelessWidget {
  final AppModel model;
  const _TubeAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    return AdvancedSection(
      summary:
          'Mix ${(m.tubeMix * 100).toStringAsFixed(0)}% · Comp ${(m.tubeCompensation >= 0 ? "+" : "")}${m.tubeCompensation.toStringAsFixed(1)} dB · AGC: ${m.tubeAutoGain ? "ON" : "OFF"} · ${(m.tubeOutputGain >= 0 ? "+" : "")}${m.tubeOutputGain.toStringAsFixed(1)} dB',
      builder: (context) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            ParamSlider(
              param: ParamRegistry.tubeMix,
              model: m,
              customLabel: l.tubeMix,
            ),
            const SizedBox(height: AuraSpace.sm),
            ParamSlider(
              param: ParamRegistry.tubeCompensation,
              model: m,
              customLabel: l.tubeCompensation,
              infoMessage: '电子管染色后的手动电平微调，只作用于湿信号（干声不动）。切换音色风格导致响度变化时用它找平。',
            ),
            const SizedBox(height: AuraSpace.md),
            // 输出级外框（自动增益补偿与输出增益门）
            OutputGainFrame(
              child: Column(
                children: [
                  ParamAutoGainRow(
                    param: ParamRegistry.tubeAutoGain,
                    model: m,
                    label: l.autoGainCompensation,
                    tooltip: l.autoGainCompensationTooltip,
                  ),
                  const SizedBox(height: AuraSpace.xs),
                  ParamSlider(
                    param: ParamRegistry.tubeOutputGain,
                    model: m,
                    customLabel: l.outputGainGate,
                    infoMessage: l.outputGainGateTooltip,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}
