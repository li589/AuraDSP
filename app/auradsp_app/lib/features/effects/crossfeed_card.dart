// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 09 Crossfeed (串扰消除 / 交叉馈送) ---- */

class _CrossfeedCard extends StatelessWidget {
  final AppModel model;
  const _CrossfeedCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = model;
    final isEnabled = m.xfeedOn;

    return SectionCard(
      index: kEffectCardIndex['crossfeed'],
      title: l.crossfeedTitle,
      titleTooltip: l.crossfeedDesc,
      collapsed: !isEnabled,
      latencyMs: m.componentLatency('crossfeed').ms,
      latencyEnabled: m.isSectionEnabled('crossfeed'),
      latencyMeasured: m.componentLatency('crossfeed').measured,
      latencyEstimated: m.componentLatency('crossfeed').estimated,
      latencyProbing: m.isProbingLatency('crossfeed'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('crossfeed')
          ? () => m.refreshComponentLatency('crossfeed')
          : null,
      latencyTick: m.getComponentLatencyTick('crossfeed'),
      trailing: ParamSwitch(
        param: ParamRegistry.crossfeedEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 模式切换行：模式标签 + 问号帮助气泡 + AuraChoiceChip 芯片组
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(l.crossfeedMode, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.xfHintPreset),
              const Spacer(),
              ParamChoiceChips(
                param: ParamRegistry.crossfeedMode,
                model: m,
                labels: [
                  l.crossfeedModeDefault,
                  l.crossfeedModeChuMoy,
                  l.crossfeedModeJanMeier,
                  l.crossfeedModeCustom,
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _CrossfeedAdvanced(model: m),
        ],
      ),
    );
  }
}

class _CrossfeedAdvanced extends StatelessWidget {
  final AppModel model;
  const _CrossfeedAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;

    final modeLabels = <int, String>{
      0: l.crossfeedModeDefault,
      1: l.crossfeedModeChuMoy,
      2: l.crossfeedModeJanMeier,
      3: l.crossfeedModeCustom,
    };
    final curModeLabel = modeLabels[m.xfeedMode] ?? l.crossfeedModeDefault;

    return AdvancedSection(
      summary: '${m.xfeedFcut.toStringAsFixed(0)} Hz · ${m.xfeedFeed.toStringAsFixed(1)} dB · $curModeLabel',
      helpTooltip: l.xfHintCustom,
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ParamSlider(
            param: ParamRegistry.crossfeedFcut,
            model: m,
            customLabel: l.crossfeedCutoff,
            infoMessage: l.xfHintCutoff,
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.crossfeedFeed,
            model: m,
            customLabel: l.crossfeedFeed,
            infoMessage: l.xfHintFeed,
          ),
        ],
      ),
    );
  }
}
