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
      index: '00',
      title: l.stGate,
      titleTooltip: l.gateHint,
      collapsed: !model.gateOn,
      latencyMs: model.componentLatency('gate').ms,
      latencyMeasured: model.componentLatency('gate').measured,
      latencyProbing: model.isProbingLatency('gate'),
      onRefreshLatency: () => model.refreshComponentLatency('gate'),
      latencyTick: model.getComponentLatencyTick('gate'),
      trailing: AuraSwitch(
        value: model.gateOn,
        onChanged: model.setGateEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 阈值
          ValueSlider(
            label: l.gateThreshold,
            infoMessage: '低于该电平的背景噪声被压掉。太高会吃掉弱音尾音，太低门几乎不动作。',
            value: model.gateThreshold,
            defaultValue: ParamDefaults.gateThreshold,
            onResetToDefault: () =>
                model.setGateThreshold(ParamDefaults.gateThreshold),
            min: -60,
            max: 0,
            unit: 'dB',
            enabled: model.gateOn,
            format: (v) => v.toStringAsFixed(0),
            onChanged: model.setGateThreshold,
            onChangedEnd: model.setGateThreshold,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 开启时间
          ValueSlider(
            label: l.gateAttack,
            infoMessage: '信号越过阈值后门打开的速度。太慢会吃掉起音，太快可能"咔"。',
            value: model.gateAttackMs,
            defaultValue: ParamDefaults.gateAttack,
            onResetToDefault: () =>
                model.setGateAttack(ParamDefaults.gateAttack),
            min: 1,
            max: 100,
            unit: 'ms',
            enabled: model.gateOn,
            format: (v) => v.toStringAsFixed(0),
            onChanged: model.setGateAttack,
            onChangedEnd: model.setGateAttack,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 释放时间
          ValueSlider(
            label: l.gateRelease,
            infoMessage: '信号跌回阈值以下后门关闭的速度。太短会截断衰减尾音，太长噪声拖尾。',
            value: model.gateReleaseMs,
            defaultValue: ParamDefaults.gateRelease,
            onResetToDefault: () =>
                model.setGateRelease(ParamDefaults.gateRelease),
            min: 10,
            max: 500,
            unit: 'ms',
            enabled: model.gateOn,
            format: (v) => v.toStringAsFixed(0),
            onChanged: model.setGateRelease,
            onChangedEnd: model.setGateRelease,
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
                    AuraSwitch(
                      value: model.deesserOn,
                      onChanged: model.gateOn ? model.setDeesserEnabled : null,
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                ValueSlider(
                  label: l.deesserFreq,
                  infoMessage: '检测齿音（s/sh 音）的侧链频段。齿音重往低调，太闷往高调。',
                  value: model.deesserFreq,
                  defaultValue: ParamDefaults.deesserFreq,
                  onResetToDefault: () =>
                      model.setDeesserFreq(ParamDefaults.deesserFreq),
                  min: 2000,
                  max: 10000,
                  unit: 'Hz',
                  enabled: model.gateOn && model.deesserOn,
                  format: (v) => '${(v / 1000).toStringAsFixed(1)}k',
                  onChanged: model.setDeesserFreq,
                  onChangedEnd: model.setDeesserFreq,
                ),
                const SizedBox(height: AuraSpace.sm),
                ValueSlider(
                  label: l.deesserAmount,
                  infoMessage: '齿音压制强度。只衰减高频成分，低频人声不动。',
                  value: model.deesserAmount,
                  defaultValue: ParamDefaults.deesserAmount,
                  onResetToDefault: () =>
                      model.setDeesserAmount(ParamDefaults.deesserAmount),
                  min: 0,
                  max: 1,
                  unit: '%',
                  enabled: model.gateOn && model.deesserOn,
                  format: (v) => (v * 100).toStringAsFixed(0),
                  onChanged: model.setDeesserAmount,
                  onChangedEnd: model.setDeesserAmount,
                ),
                const SizedBox(height: AuraSpace.md),
                // 输出级外框（自动增益补偿）
                OutputGainFrame(
                  child: _AutoGainRow(
                    label: l.gateAutoGain,
                    tooltip: '实时补偿噪声门造成的整体电平下降，保持响度不塌。',
                    value: model.gateAutoGain,
                    enabled: model.gateOn,
                    onChanged: model.setGateAutoGain,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
