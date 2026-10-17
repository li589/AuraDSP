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
      index: null, // 随空间卡搬入，去编号
      title: l.crossfeedTitle,
      titleTooltip: l.crossfeedDesc,
      collapsed: !isEnabled,
      latencyMs: m.componentLatency('crossfeed').ms,
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
              InfoBadge(message: '切换经典硬件耳机串扰模拟算法预设或自定义微调。消除耳机“头中效应”，还原自然音箱声场。'),
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
      helpTooltip: '自定义串扰低通截止频率与互馈衰减深度微调。',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ParamSlider(
            param: ParamRegistry.crossfeedFcut,
            model: m,
            customLabel: l.crossfeedCutoff,
            infoMessage: '串扰低通滤波器的截止频率 (300 ~ 2000 Hz)。频率越高，被互馈到对侧声道的频带范围越宽。',
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.crossfeedFeed,
            model: m,
            customLabel: l.crossfeedFeed,
            infoMessage: '低频串扰互馈衰减量 (1.0 ~ 15.0 dB)。数值越小互馈越多、声场越宽；数值越大串扰越轻微。',
          ),
        ],
      ),
    );
  }
}
