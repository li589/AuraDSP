// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 06 Stereo (立体声声场展宽) ---- */

class _StereoCard extends StatelessWidget {
  final AppModel model;
  const _StereoCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '10',
      title: l.stereoWiden,
      collapsed: !model.stereoOn,
      latencyMs: model.componentLatency('stereo').ms,
              latencyMeasured: model.componentLatency('stereo').measured,
              latencyProbing: model.isProbingLatency('stereo'),
      onRefreshLatency: () => model.refreshComponentLatency('stereo'),
      latencyTick: model.getComponentLatencyTick('stereo'),
      trailing: AuraSwitch(
        value: model.stereoOn,
        onChanged: (v) => model.setStereoEnabled(v),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.stereoWiden,
            infoMessage: '拉伸左右耳声像边界。适度拉伸让耳机如大音箱脱箱，拉太大可能削弱中央人声聚焦。',
            value: model.stereoMix,
            defaultValue: ParamDefaults.stereoMix,
            onResetToDefault: model.resetStereoWiden,
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.stereoOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => model.setStereoMix(v),
            onChangedEnd: (v) => model.setStereoMix(v),
          ),
          const SizedBox(height: AuraSpace.md),
          _StereoAdvanced(model: model),
        ],
      ),
    );
  }
}

/// 声场分带细化（默认折叠）：5 个子带独立 mix
class _StereoAdvanced extends StatelessWidget {
  final AppModel model;
  const _StereoAdvanced({required this.model});


  @override
  Widget build(BuildContext context) {
    final m = model;
    return AdvancedSection(
      summary: '${(m.stereoMix * 100).toStringAsFixed(0)}%',
      helpTooltip: l10nOf(context).stBandHint,
      builder: (context) {
        return Column(
          children: [
            for (var i = 0; i < 5; i++)
              _BandSlider(
                model: m,
                index: i,
                label: [l10nOf(context).stBand0, l10nOf(context).stBand1, l10nOf(context).stBand2, l10nOf(context).stBand3, l10nOf(context).stBand4][i],
              ),
          ],
        );
      },
    );
  }
}

class _BandSlider extends StatelessWidget {
  final AppModel model;
  final int index;
  final String label;

  const _BandSlider({
    required this.model,
    required this.index,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final m = model;
    return ListenableBuilder(
      listenable: m,
      builder: (_, _) {
        final v = m.stereoBands[index];
        return ValueSlider(
          label: label,
          value: v,
          defaultValue: ParamDefaults.stereoBand,
          min: 0,
          max: 1,
          unit: '%',
          enabled: m.stereoOn,
          format: (val) => (val * 100).toStringAsFixed(0),
          onChanged: (val) => m.setStereoBand(index, val),
          onChangedEnd: (val) => m.setStereoBand(index, val),
          onResetToDefault: () => m.resetStereoBand(index),
        );
      },
    );
  }
}
