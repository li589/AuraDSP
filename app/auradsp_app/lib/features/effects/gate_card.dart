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
                      infoMessage: '低于该电平的背景底噪将被衰减。太高会吃掉弱音尾音，太低门几乎不动作。',
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 迟滞防抖 (Hysteresis)
                    ParamSlider(
                      param: ParamRegistry.gateHysteresis,
                      model: model,
                      customLabel: '迟滞防抖 (Hysteresis)',
                      infoMessage: '开门与关门之间的电平缓冲差。防止信号在阈值临界点反复振荡抽吸，确保人声起伏时门状态平稳自然。',
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 衰减底线 (Range)
                    ParamSlider(
                      param: ParamRegistry.gateRange,
                      model: model,
                      customLabel: '衰减底线 (Range)',
                      infoMessage: '门完全关闭时的最大衰减深度。设为 -60dB 为静音，设为 -12~-24dB 可保留自然背景底噪，避免数码窒息感。',
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 保持时间 (Hold)
                    ParamSlider(
                      param: ParamRegistry.gateHoldMs,
                      model: model,
                      customLabel: '保持时间 (Hold)',
                      infoMessage: '信号跌破关门阈值后，保持完全导通的毫秒数。防止语间停顿或鼓点泛音被过早斩断。',
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 开启时间 (Attack)
                    ParamSlider(
                      param: ParamRegistry.gateAttack,
                      model: model,
                      customLabel: l.gateAttack,
                      infoMessage: '信号越过开启阈值后门打开的速度。太慢会吃掉起音，太快可能引入瞬态爆音。',
                    ),
                    const SizedBox(height: AuraSpace.sm),
                    // 释放时间 (Release)
                    ParamSlider(
                      param: ParamRegistry.gateRelease,
                      model: model,
                      customLabel: l.gateRelease,
                      infoMessage: '保持时间结束后门平滑关闭到衰减底线所需时间。较长的时间让淡出更自然。',
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
            helpTooltip: '侧链动态去齿音与噪声门输出响度自动补偿。',
            builder: (ctx) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(l.deesserTitle, style: labelOf(p, color: p.text)),
                    const SizedBox(width: 4),
                    const InfoBadge(message: '针对高频咝咝声、齿音（s/sh/ch）进行动态衰减，保留低频自然丰满度。'),
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
                  infoMessage: '检测齿音（s/sh 音）的侧链频段。齿音重往低调，太闷往高调。',
                  enabled: model.gateOn && model.deesserOn,
                ),
                const SizedBox(height: AuraSpace.sm),
                ParamSlider(
                  param: ParamRegistry.deesserAmount,
                  model: model,
                  customLabel: l.deesserAmount,
                  infoMessage: '齿音压制强度。只衰减高频成分，低频人声不动。',
                  enabled: model.gateOn && model.deesserOn,
                ),
                const SizedBox(height: AuraSpace.md),
                // 输出级外框（自动增益补偿）
                OutputGainFrame(
                  child: ParamAutoGainRow(
                    param: ParamRegistry.gateAutoGain,
                    model: model,
                    label: l.gateAutoGain,
                    tooltip: '实时补偿噪声门造成的整体电平下降，保持响度不塌。',
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
