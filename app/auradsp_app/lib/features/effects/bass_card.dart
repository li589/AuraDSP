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
      index: '02',
      title: l.bassBoost,
      collapsed: !model.bassOn,
      latencyMs: model.componentLatency('bass').ms,
              latencyMeasured: model.componentLatency('bass').measured,
              latencyProbing: model.isProbingLatency('bass'),
      onRefreshLatency: () => model.refreshComponentLatency('bass'),
      latencyTick: model.getComponentLatencyTick('bass'),
      trailing: AuraSwitch(
        value: model.bassOn,
        onChanged: (v) => model.setInt('bass.enable', v ? 1 : 0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 主驱动：低音增强强度 (Bass Intensity)
          ValueSlider(
            label: l.bassIntensity,
            infoMessage: '增强低音量感与冲击力。越高低频下潜越震撼，建议适度提升防轰头。',
            value: model.bassIntensity,
            defaultValue: ParamDefaults.bassIntensity,
            onResetToDefault: () =>
                model.setBassIntensity(ParamDefaults.bassIntensity),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.bassOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setBassIntensity,
            onChangedEnd: model.setBassIntensity,
          ),
          const SizedBox(height: AuraSpace.md),
          // 低音增强模式 — 标签与选项同行，选项右对齐
          Row(
            children: [
              Text(l.bassMode, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.bassModeTooltip),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  AuraChoiceChip(
                    label: l.bassModeDynamic,
                    selected: model.bassMode == 0,
                    onTap: () => model.setBassMode(0),
                  ),
                  AuraChoiceChip(
                    label: l.bassModeShelf,
                    selected: model.bassMode == 1,
                    onTap: () => model.setBassMode(1),
                  ),
                  AuraChoiceChip(
                    label: l.bassModeHarmonic,
                    selected: model.bassMode == 2,
                    onTap: () => model.setBassMode(2),
                  ),
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
              ValueSlider(
                label: l.bassCutoff,
                infoMessage: '低音增强作用的最高频率。低于该频率的声音将被加厚，一般建议 60~120Hz。',
                value: m.bassCutoff,
                defaultValue: ParamDefaults.bassCutoff,
                min: 30,
                max: 300,
                unit: 'Hz',
                enabled: m.bassOn,
                format: (v) => v.toStringAsFixed(0),
                onChanged: m.setBassCutoff,
                onChangedEnd: m.setBassCutoff,
                onResetToDefault: () => m.setBassCutoff(ParamDefaults.bassCutoff),
              ),
              ValueSlider(
                label: l.bassHarmonics,
                value: m.bassHarmonics,
                defaultValue: ParamDefaults.bassHarmonics,
                min: 0,
                max: 1,
                unit: '%',
                enabled: m.bassOn,
                format: (v) => (v * 100).toStringAsFixed(0),
                onChanged: m.setBassHarmonics,
                onChangedEnd: m.setBassHarmonics,
                onResetToDefault: () => m.setBassHarmonics(ParamDefaults.bassHarmonics),
              ),
              ValueSlider(
                label: l.bassBlend,
                value: m.bassHarmonicBlend,
                defaultValue: ParamDefaults.bassHarmonicBlend,
                min: 0,
                max: 1,
                unit: '%',
                enabled: m.bassOn,
                format: (v) => (v * 100).toStringAsFixed(0),
                onChanged: m.setBassHarmonicBlend,
                onChangedEnd: m.setBassHarmonicBlend,
                onResetToDefault: () =>
                    m.setBassHarmonicBlend(ParamDefaults.bassHarmonicBlend),
              ),
              ValueSlider(
                label: l.bassSubFloor,
                value: m.bassSubFloor,
                defaultValue: ParamDefaults.bassSubFloor,
                min: 10,
                max: 40,
                unit: 'Hz',
                enabled: m.bassOn,
                format: (v) => v.toStringAsFixed(0),
                onChanged: m.setBassSubFloor,
                onChangedEnd: m.setBassSubFloor,
                onResetToDefault: () => m.setBassSubFloor(ParamDefaults.bassSubFloor),
              ),
              const SizedBox(height: AuraSpace.md),
              OutputGainFrame(
                child: Column(
                  children: [
                    _AutoGainRow(
                      label: l.autoGainCompensation,
                      tooltip: l.autoGainCompensationTooltip,
                      value: m.bassAutoGain,
                      enabled: m.bassOn,
                      onChanged: m.setBassAutoGain,
                    ),
                    const SizedBox(height: AuraSpace.xs),
                    ValueSlider(
                      label: l.outputGainGate,
                      infoMessage: l.outputGainGateTooltip,
                      value: m.bassOutputGain,
                      defaultValue: ParamDefaults.bassOutputGain,
                      onResetToDefault: () =>
                          m.setBassOutputGain(ParamDefaults.bassOutputGain),
                      min: -12.0,
                      max: 6.0,
                      unit: 'dB',
                      enabled: m.bassOn,
                      format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                      onChanged: m.setBassOutputGain,
                      onChangedEnd: m.setBassOutputGain,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
