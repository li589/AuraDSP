// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 00B Gate + Deesser（噪声门 + 齿音消除，链头第一道）----
 * 主卡 = 噪声门（阈值/attack/release）；
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
          // 阈值
          ParamSlider(
            param: ParamRegistry.gateThreshold,
            model: model,
            customLabel: l.gateThreshold,
            infoMessage: '低于该电平的背景噪声被压掉。太高会吃掉弱音尾音，太低门几乎不动作。',
          ),
          const SizedBox(height: AuraSpace.sm),
          // 开启时间
          ParamSlider(
            param: ParamRegistry.gateAttack,
            model: model,
            customLabel: l.gateAttack,
            infoMessage: '信号越过阈值后门打开的速度。太慢会吃掉起音，太快可能"咔"。',
          ),
          const SizedBox(height: AuraSpace.sm),
          // 释放时间
          ParamSlider(
            param: ParamRegistry.gateRelease,
            model: model,
            customLabel: l.gateRelease,
            infoMessage: '信号跌回阈值以下后门关闭的速度。太短会截断衰减尾音，太长噪声拖尾。',
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
                    InfoBadge(message: '针对高频咝咝声、齿音（s/sh/ch）进行动态衰减，保留低频自然丰满度。'),
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
