// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 02 Bass (低音增强重构) ---- */

class _BassCard extends StatelessWidget {
  final AppModel model;
  const _BassCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return SectionCard(
      index: kEffectCardIndex['bass'],
      title: l.bassBoost,
      collapsed: !model.bassOn,
      latencyMs: model.componentLatency('bass').ms,
      latencyEnabled: model.isSectionEnabled('bass'),
              latencyMeasured: model.componentLatency('bass').measured,
              latencyEstimated: model.componentLatency('bass').estimated,
              latencyProbing: model.isProbingLatency('bass'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('bass')
          ? () => model.refreshComponentLatency('bass')
          : null,
      latencyTick: model.getComponentLatencyTick('bass'),
      trailing: ParamSwitch(
        param: ParamRegistry.bassEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 主驱动：低音增强强度 (Bass Intensity)
          ParamSlider(
            param: ParamRegistry.bassIntensity,
            model: model,
            customLabel: l.bassIntensity,
            infoMessage: l.bassHintIntensity,
          ),
          const SizedBox(height: AuraSpace.md),
          // 低音增强模式 — 标签与选项同行，选项右对齐
          Row(
            children: [
              Text(l.bassMode, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.bassModeTooltip),
              const Spacer(),
              ParamChoiceChips(
                param: ParamRegistry.bassMode,
                model: model,
                labels: [
                  l.bassModeDynamic,
                  l.bassModeShelf,
                  l.bassModeHarmonic,
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _BassAdvanced(model: model),
        ],
      ),
    );
  }
}

class _BassAdvanced extends StatelessWidget {
  final AppModel model;
  const _BassAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    return AdvancedSection(
      summary: '${m.bassCutoff.toStringAsFixed(0)} Hz · AGC: ${m.bassAutoGain ? "ON" : "OFF"} · ${(m.bassOutputGain >= 0 ? "+" : "")}${m.bassOutputGain.toStringAsFixed(1)} dB',
      builder: (context) => Column(
        children: [
          ParamSlider(
            param: ParamRegistry.bassCutoff,
            model: m,
            customLabel: l.bassCutoff,
            infoMessage: l.bassHintFrequency,
          ),
          ParamSlider(
            param: ParamRegistry.bassHarmonics,
            model: m,
            customLabel: l.bassHarmonics,
          ),
          ParamSlider(
            param: ParamRegistry.bassHarmonicBlend,
            model: m,
            customLabel: l.bassBlend,
          ),
          ParamSlider(
            param: ParamRegistry.bassSubFloor,
            model: m,
            customLabel: l.bassSubFloor,
          ),
          const SizedBox(height: AuraSpace.md),
          OutputGainFrame(
            child: Column(
              children: [
                ParamAutoGainRow(
                  param: ParamRegistry.bassAutoGain,
                  model: m,
                  label: l.autoGainCompensation,
                  tooltip: l.autoGainCompensationTooltip,
                ),
                const SizedBox(height: AuraSpace.xs),
                ParamOutputGainSlider(
                  param: ParamRegistry.bassOutputGain,
                  model: m,
                  label: l.outputGainGate,
                  infoMessage: l.outputGainGateTooltip,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
