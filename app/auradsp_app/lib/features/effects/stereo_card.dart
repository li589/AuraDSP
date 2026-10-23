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
      index: kEffectCardIndex['stereo'],
      title: l.stereoWiden,
      collapsed: !model.stereoOn,
      latencyMs: model.componentLatency('stereo').ms,
      latencyEnabled: model.isSectionEnabled('stereo'),
              latencyMeasured: model.componentLatency('stereo').measured,
              latencyEstimated: model.componentLatency('stereo').estimated,
              latencyProbing: model.isProbingLatency('stereo'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('stereo')
          ? () => model.refreshComponentLatency('stereo')
          : null,
      latencyTick: model.getComponentLatencyTick('stereo'),
      trailing: ParamSwitch(
        param: ParamRegistry.stereoEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ParamSlider(
            param: ParamRegistry.stereoWide,
            model: model,
            customLabel: l.stereoWiden,
            infoMessage: l.stereoHintWidth,
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
    final labels = [
      l10nOf(context).stBand0,
      l10nOf(context).stBand1,
      l10nOf(context).stBand2,
      l10nOf(context).stBand3,
      l10nOf(context).stBand4,
    ];
    return AdvancedSection(
      summary: '${(m.stereoMix * 100).toStringAsFixed(0)}%',
      helpTooltip: l10nOf(context).stBandHint,
      builder: (context) {
        return Column(
          children: [
            for (var i = 0; i < 5; i++)
              ParamSlider(
                param: ParamRegistry.stereoBands[i],
                model: m,
                customLabel: labels[i],
              ),
          ],
        );
      },
    );
  }
}
