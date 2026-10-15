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
      index: '13',
      title: l.tubeTitle,
      collapsed: !model.tubeOn,
      latencyMs: model.componentLatency('tube').ms,
              latencyMeasured: model.componentLatency('tube').measured,
              latencyProbing: model.isProbingLatency('tube'),
      onRefreshLatency: () => model.refreshComponentLatency('tube'),
      latencyTick: model.getComponentLatencyTick('tube'),
      trailing: AuraSwitch(
        value: model.tubeOn,
        onChanged: model.setTubeEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 饱和驱动度 (Drive / Saturation)
          ValueSlider(
            label: l.tubeDrive,
            infoMessage: '模拟经典电子管偶次谐波失真。带来醇厚耐听的模拟胶片暖色调，消除数码干冷感。',
            value: model.tubeGain,
            defaultValue: ParamDefaults.tubeGain,
            onResetToDefault: () => model.setTubeGain(ParamDefaults.tubeGain),
            min: -3,
            max: 12,
            unit: 'dB',
            enabled: model.tubeOn,
            format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
            onChanged: model.setTubeGain,
            onChangedEnd: model.setTubeGain,
          ),
          const SizedBox(height: AuraSpace.md),
          // 电子管音色风格
          // 电子管音色风格 — 标签与选项同行，选项右对齐
          Row(
            children: [
              Text(l.tubeStyle, style: labelOf(p, color: p.text)),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  AuraChoiceChip(
                    label: l.tubeStyleTriode,
                    selected: model.tubeStyle == 0,
                    onTap: () => model.setTubeStyle(0),
                  ),
                  AuraChoiceChip(
                    label: l.tubeStylePentode,
                    selected: model.tubeStyle == 1,
                    onTap: () => model.setTubeStyle(1),
                  ),
                  AuraChoiceChip(
                    label: l.tubeStyleTape,
                    selected: model.tubeStyle == 2,
                    onTap: () => model.setTubeStyle(2),
                  ),
                ],
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
            // P-011：过采样由 vendor 按采样率自动选择（30k+→2x/20-30k→3x/14-20k→4x/14k-→5x），
            // 无手动档（僵尸字段已删）。
            ValueSlider(
              label: l.tubeMix,
              value: m.tubeMix,
              defaultValue: ParamDefaults.tubeMix,
              onResetToDefault: () => m.setTubeMix(ParamDefaults.tubeMix),
              min: 0,
              max: 1,
              unit: '%',
              enabled: m.tubeOn,
              format: (v) => (v * 100).toStringAsFixed(0),
              onChanged: m.setTubeMix,
              onChangedEnd: m.setTubeMix,
            ),
            const SizedBox(height: AuraSpace.sm),
            ValueSlider(
              label: l.tubeCompensation,
              infoMessage: '电子管染色后的手动电平微调，只作用于湿信号（干声不动）。切换音色风格导致响度变化时用它找平。',
              value: m.tubeCompensation,
              defaultValue: ParamDefaults.tubeCompensation,
              onResetToDefault: () =>
                  m.setTubeCompensation(ParamDefaults.tubeCompensation),
              min: -12.0,
              max: 12.0,
              unit: 'dB',
              enabled: m.tubeOn,
              format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
              onChanged: m.setTubeCompensation,
              onChangedEnd: m.setTubeCompensation,
            ),
            const SizedBox(height: AuraSpace.md),
            // 输出级外框（自动增益补偿与输出增益门）
            OutputGainFrame(
              child: Column(
                children: [
                  _AutoGainRow(
                    label: l.autoGainCompensation,
                    tooltip: l.autoGainCompensationTooltip,
                    value: m.tubeAutoGain,
                    enabled: m.tubeOn,
                    onChanged: m.setTubeAutoGain,
                  ),
                  const SizedBox(height: AuraSpace.xs),
                  ValueSlider(
                    label: l.outputGainGate,
                    infoMessage: l.outputGainGateTooltip,
                    value: m.tubeOutputGain,
                    defaultValue: ParamDefaults.tubeOutputGain,
                    onResetToDefault: () =>
                        m.setTubeOutputGain(ParamDefaults.tubeOutputGain),
                    min: -12.0,
                    max: 6.0,
                    unit: 'dB',
                    enabled: m.tubeOn,
                    format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                    onChanged: m.setTubeOutputGain,
                    onChangedEnd: m.setTubeOutputGain,
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
