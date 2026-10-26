// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 05 Equalizer (多段图形均衡器) ---- */

class _EqualizerCard extends StatelessWidget {
  final AppModel model;
  const _EqualizerCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: kEffectCardIndex['eq'],
      title: l.eqMultiBand,
      collapsed: !model.eqOn,
      latencyMs: model.componentLatency('eq').ms,
      latencyEnabled: model.isSectionEnabled('eq'),
              latencyMeasured: model.componentLatency('eq').measured,
              latencyEstimated: model.componentLatency('eq').estimated,
              latencyProbing: model.isProbingLatency('eq'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('eq')
          ? () => model.refreshComponentLatency('eq')
          : null,
      latencyTick: model.getComponentLatencyTick('eq'),
      trailing: AuraSwitch(
        value: model.eqOn,
        onChanged: (v) => model.setInt('eq.enable', v ? 1 : 0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InteractiveSpectrumEQPanel(model: model),
          const SizedBox(height: AuraSpace.sm),
          _EqualizerAdvanced(model: model),
        ],
      ),
    );
  }
}

class _EqualizerAdvanced extends StatelessWidget {
  final AppModel model;
  const _EqualizerAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = model;
    final filterStr = m.eqFilter == 0
        ? (m.eqInterp == 1 ? 'FIR · Makima' : 'FIR · PCHIP')
        : (m.eqFilter == 1 ? 'IIR6' : 'IIR12');
    final agcStr = 'AGC: ${m.eqAutoGain ? "ON" : "OFF"}';
    final trimStr =
        '${(m.eqOutputGain >= 0 ? "+" : "")}${m.eqOutputGain.toStringAsFixed(1)} dB';

    return AdvancedSection(
      summary: '$filterStr · $agcStr · $trimStr',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 滤波器架构
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(l.eqFilterType, style: labelOf(p, color: p.text)),
              const SizedBox(width: AuraSpace.md),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: AuraSpace.sm,
                    runSpacing: AuraSpace.xs,
                    alignment: WrapAlignment.end,
                    children: [
                      AuraChoiceChip(
                        label: l.eqFilterMinphase,
                        selected: m.eqFilter == 0,
                        onTap: () => m.setEqFilter(0),
                      ),
                      AuraChoiceChip(
                        label: l.eqFilterIir6,
                        selected: m.eqFilter == 1,
                        onTap: () => m.setEqFilter(1),
                      ),
                      AuraChoiceChip(
                        label: l.eqFilterIir12,
                        selected: m.eqFilter == 2,
                        onTap: () => m.setEqFilter(2),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),

          // 2. 插值算法（FIR 模式下生效）
          Opacity(
            opacity: m.eqFilter == 0 ? 1.0 : 0.45,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(l.eqInterpolation, style: labelOf(p, color: p.text)),
                const SizedBox(width: AuraSpace.md),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: AuraSpace.sm,
                      runSpacing: AuraSpace.xs,
                      alignment: WrapAlignment.end,
                      children: [
                        AuraChoiceChip(
                          label: l.eqInterpMakima,
                          selected: m.eqInterp == 1,
                          onTap: m.eqFilter == 0 ? () => m.setEqInterp(1) : null,
                        ),
                        AuraChoiceChip(
                          label: l.eqInterpPchip,
                          selected: m.eqInterp == 0,
                          onTap: m.eqFilter == 0 ? () => m.setEqInterp(0) : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AuraSpace.md),

          // 3. 输出级外框（自动增益补偿与输出增益门）
          OutputGainFrame(
            child: Column(
              children: [
                _AutoGainRow(
                  label: l.autoGainCompensation,
                  tooltip: l.autoGainCompensationTooltip,
                  value: m.eqAutoGain,
                  enabled: m.eqOn,
                  onChanged: m.setEqAutoGain,
                ),
                const SizedBox(height: AuraSpace.xs),
                ValueSlider(
                  label: l.outputGainGate,
                  infoMessage: l.outputGainGateTooltip,
                  value: m.eqOutputGain,
                  defaultValue: ParamDefaults.eqOutputGain,
                  onResetToDefault: () =>
                      m.setEqOutputGain(ParamDefaults.eqOutputGain),
                  min: -12.0,
                  max: 6.0,
                  unit: 'dB',
                  enabled: m.eqOn,
                  format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                  onChanged: m.setEqOutputGain,
                  onChangedEnd: m.setEqOutputGain,
                ),
              ],
            ),
          ),
          const SizedBox(height: AuraSpace.sm),
          ChannelRoutingSelector(
            model: model,
            paramKey: 'eq.channels',
          ),
        ],
      ),
    );
  }
}
