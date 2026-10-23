// part of effects_page.dart —— 工业级迟滞噪声门与 Deesser 卡片
part of '../effects_page.dart';

/* ---- 00B Gate + Deesser（噪声门 + 齿音消除，链头第一道）----
 * 主卡 = 噪声门（阈值/迟滞/底线/保持/attack/release + 动态 GR 仪表与开门指示灯）；
 * 高级区 = Deesser（开关 + 频段 + 强度）+ 噪声门自动增益补偿开关。 */
class _GateCard extends StatelessWidget {
  final AppModel model;
  const _GateCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: kEffectCardIndex['gate'],
      title: l.stGate,
      titleTooltip: l.gateHint,
      collapsed: !model.gateOn,
      latencyMs: model.componentLatency('gate').ms,
      latencyEnabled: model.isSectionEnabled('gate'),
      latencyMeasured: model.componentLatency('gate').measured,
      latencyEstimated: model.componentLatency('gate').estimated,
      latencyProbing: model.isProbingLatency('gate'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('gate')
          ? () => model.refreshComponentLatency('gate')
          : null,
      latencyTick: model.getComponentLatencyTick('gate'),
      trailing: ParamSwitch(
        param: ParamRegistry.gateEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 阈值 (Threshold)
                    ParamSlider(
                      param: ParamRegistry.gateThreshold,
                      model: model,
                      customLabel: l.gateThreshold,
                      infoMessage: l.gateHintThreshold,
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 迟滞防抖 (Hysteresis)
                    ParamSlider(
                      param: ParamRegistry.gateHysteresis,
                      model: model,
                      customLabel: l.gateHysteresis,
                      infoMessage: l.gateHintHysteresis,
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 衰减底线 (Range)
                    ParamSlider(
                      param: ParamRegistry.gateRange,
                      model: model,
                      customLabel: l.gateRange,
                      infoMessage: l.gateHintRange,
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 保持时间 (Hold)
                    ParamSlider(
                      param: ParamRegistry.gateHoldMs,
                      model: model,
                      customLabel: l.gateHold,
                      infoMessage: l.gateHintHold,
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 开启时间 (Attack)
                    ParamSlider(
                      param: ParamRegistry.gateAttack,
                      model: model,
                      customLabel: l.gateAttack,
                      infoMessage: l.gateHintAttack,
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 释放时间 (Release)
                    ParamSlider(
                      param: ParamRegistry.gateRelease,
                      model: model,
                      customLabel: l.gateRelease,
                      infoMessage: l.gateHintRelease,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AuraSpace.md),
              // 垂直下坠式 Gate GR 衰减仪表
              GainReductionMeter(
                grListenable: model.grGate,
                label: 'GATE',
                height: 250.0,
                width: 36.0,
                maxDb: 60.0,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          // 高级区：Deesser（齿音消除）与输出级自动增益补偿
          AdvancedSection(
            summary: '${l.deesserTitle}: ${model.deesserOn ? "ON" : "OFF"} · AGC: ${model.gateAutoGain ? "ON" : "OFF"}',
            helpTooltip: l.gateHintSidechain,
            builder: (ctx) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(l.deesserTitle, style: labelOf(p, color: p.text)),
                    const SizedBox(width: 4),
                    InfoBadge(message: l.gateHintDeess),
                    const Spacer(),
                    ParamSwitch(
                      param: ParamRegistry.deesserEnable,
                      model: model,
                      enabled: model.gateOn,
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                ParamSlider(
                  param: ParamRegistry.deesserFreq,
                  model: model,
                  customLabel: l.deesserFreq,
                  infoMessage: l.gateHintDeessFreq,
                  enabled: model.gateOn && model.deesserOn,
                ),
                const SizedBox(height: AuraSpace.sm),
                ParamSlider(
                  param: ParamRegistry.deesserAmount,
                  model: model,
                  customLabel: l.deesserAmount,
                  infoMessage: l.gateHintDeessAmount,
                  enabled: model.gateOn && model.deesserOn,
                ),
                const SizedBox(height: AuraSpace.md),
                // 输出级外框（自动增益补偿）
                OutputGainFrame(
                  child: ParamAutoGainRow(
                    param: ParamRegistry.gateAutoGain,
                    model: model,
                    label: l.gateAutoGain,
                    tooltip: l.gateHintAutoGain,
                  ),
                ),
                const SizedBox(height: AuraSpace.sm),
                ChannelRoutingSelector(
                  model: model,
                  paramKey: 'gate.channels',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
