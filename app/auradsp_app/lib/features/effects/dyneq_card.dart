// part of effects_page.dart —— 全参数动态EQ卡（pre-vendor 音色修整，shelf 之后）。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 00C Dynamic EQ（全参数动态均衡器）----
 * 主卡 = 总开关 + 包络时间（attack/release 全局共用）；
 * 三段（Low shelf / Mid bell / High shelf）各：开关 + 频率 + Q +
 * 静态增益 + 动态量 + 阈值。阈下只做静态整形，超阈后按 range 衰减该频段。 */
class _DyneCard extends StatelessWidget {
  final AppModel model;
  const _DyneCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    return SectionCard(
      index: '00',
      title: l.dyneqTitle,
      titleTooltip: l.dyneqHint,
      collapsed: !m.dyneqOn,
      latencyMs: m.componentLatency('dyneq').ms,
      latencyMeasured: m.componentLatency('dyneq').measured,
      latencyProbing: m.isProbingLatency('dyneq'),
      onRefreshLatency: () => m.refreshComponentLatency('dyneq'),
      latencyTick: m.getComponentLatencyTick('dyneq'),
      trailing: AuraSwitch(
        value: m.dyneqOn,
        onChanged: m.setDyneqEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 包络时间（全局共用）
          ValueSlider(
            label: l.dyneqAttack,
            infoMessage: '频段能量越过阈值后压下来的速度。太慢吃掉瞬态，太快可能有咔哒感。',
            value: m.dyneqAttackMs,
            defaultValue: ParamDefaults.dyneqAttack,
            onResetToDefault: () =>
                m.setDyneqAttack(ParamDefaults.dyneqAttack),
            min: 0.1,
            max: 100,
            unit: 'ms',
            enabled: m.dyneqOn,
            format: (v) => v.toStringAsFixed(1),
            onChanged: m.setDyneqAttack,
            onChangedEnd: m.setDyneqAttack,
          ),
          const SizedBox(height: AuraSpace.sm),
          ValueSlider(
            label: l.dyneqRelease,
            infoMessage: '能量跌回阈值以下后松开的速度。太短会有抽吸感，太长压住不放。',
            value: m.dyneqReleaseMs,
            defaultValue: ParamDefaults.dyneqRelease,
            onResetToDefault: () =>
                m.setDyneqRelease(ParamDefaults.dyneqRelease),
            min: 10,
            max: 1000,
            unit: 'ms',
            enabled: m.dyneqOn,
            format: (v) => v.toStringAsFixed(0),
            onChanged: m.setDyneqRelease,
            onChangedEnd: m.setDyneqRelease,
          ),
          const SizedBox(height: AuraSpace.md),
          _DyneBand(model: m, band: 0),
          const SizedBox(height: AuraSpace.md),
          _DyneBand(model: m, band: 1),
          const SizedBox(height: AuraSpace.md),
          _DyneBand(model: m, band: 2),
        ],
      ),
    );
  }
}

class _DyneBand extends StatelessWidget {
  final AppModel model;
  final int band; // 0=Low shelf / 1=Mid bell / 2=High shelf
  const _DyneBand({required this.model, required this.band});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = model;
    final String bandLabel =
        band == 0 ? l.dyneqBandLow : (band == 1 ? l.dyneqBandMid : l.dyneqBandHigh);
    final bool bandOn = band == 0 ? m.dyneqLowOn : (band == 1 ? m.dyneqMidOn : m.dyneqHighOn);
    final double freq = band == 0 ? m.dyneqLowFreq : (band == 1 ? m.dyneqMidFreq : m.dyneqHighFreq);
    final double q = band == 0 ? m.dyneqLowQ : (band == 1 ? m.dyneqMidQ : m.dyneqHighQ);
    final double gain = band == 0 ? m.dyneqLowGain : (band == 1 ? m.dyneqMidGain : m.dyneqHighGain);
    final double range = band == 0 ? m.dyneqLowRange : (band == 1 ? m.dyneqMidRange : m.dyneqHighRange);
    final double threshold = band == 0
        ? m.dyneqLowThreshold
        : (band == 1 ? m.dyneqMidThreshold : m.dyneqHighThreshold);
    void Function(bool) setBandOn = band == 0
        ? m.setDyneqLowEnabled
        : (band == 1 ? m.setDyneqMidEnabled : m.setDyneqHighEnabled);
    void Function(double) setFreq = band == 0
        ? m.setDyneqLowFreq
        : (band == 1 ? m.setDyneqMidFreq : m.setDyneqHighFreq);
    void Function(double) setQ = band == 0
        ? m.setDyneqLowQ
        : (band == 1 ? m.setDyneqMidQ : m.setDyneqHighQ);
    void Function(double) setGain = band == 0
        ? m.setDyneqLowGain
        : (band == 1 ? m.setDyneqMidGain : m.setDyneqHighGain);
    void Function(double) setRange = band == 0
        ? m.setDyneqLowRange
        : (band == 1 ? m.setDyneqMidRange : m.setDyneqHighRange);
    void Function(double) setThreshold = band == 0
        ? m.setDyneqLowThreshold
        : (band == 1 ? m.setDyneqMidThreshold : m.setDyneqHighThreshold);
    final double defFreq = band == 0
        ? ParamDefaults.dyneqLowFreq
        : (band == 1 ? ParamDefaults.dyneqMidFreq : ParamDefaults.dyneqHighFreq);
    final double defQ = band == 0
        ? ParamDefaults.dyneqLowQ
        : (band == 1 ? ParamDefaults.dyneqMidQ : ParamDefaults.dyneqHighQ);
    final double defGain = band == 0
        ? ParamDefaults.dyneqLowGain
        : (band == 1 ? ParamDefaults.dyneqMidGain : ParamDefaults.dyneqHighGain);
    final double defRange = band == 0
        ? ParamDefaults.dyneqLowRange
        : (band == 1 ? ParamDefaults.dyneqMidRange : ParamDefaults.dyneqHighRange);
    final double defThreshold = band == 0
        ? ParamDefaults.dyneqLowThreshold
        : (band == 1 ? ParamDefaults.dyneqMidThreshold : ParamDefaults.dyneqHighThreshold);
    final double freqMin = band == 0 ? 20 : (band == 1 ? 200 : 2000);
    final double freqMax = band == 0 ? 500 : (band == 1 ? 8000 : 20000);
    final double qMin = band == 1 ? 0.3 : 0.5;
    final double qMax = band == 1 ? 10 : 2;
    final bool en = m.dyneqOn && bandOn;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(bandLabel, style: labelOf(p, color: p.text)),
            const Spacer(),
            AuraSwitch(
              value: bandOn,
              onChanged: m.dyneqOn ? setBandOn : null,
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqFreq,
          value: freq,
          defaultValue: defFreq,
          onResetToDefault: () => setFreq(defFreq),
          min: freqMin,
          max: freqMax,
          unit: 'Hz',
          enabled: en,
          format: (v) => v >= 1000 ? '${(v / 1000).toStringAsFixed(1)}k' : v.toStringAsFixed(0),
          onChanged: setFreq,
          onChangedEnd: setFreq,
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqQ,
          infoMessage: 'Mid 为钟形带宽；Low/High 为搁架斜率共振。',
          value: q,
          defaultValue: defQ,
          onResetToDefault: () => setQ(defQ),
          min: qMin,
          max: qMax,
          unit: '',
          enabled: en,
          format: (v) => v.toStringAsFixed(2),
          onChanged: setQ,
          onChangedEnd: setQ,
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqGain,
          infoMessage: '静态基础增益，常时有效；动态部分只做衰减。',
          value: gain,
          defaultValue: defGain,
          onResetToDefault: () => setGain(defGain),
          min: -12,
          max: 12,
          unit: 'dB',
          enabled: en,
          format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
          onChanged: setGain,
          onChangedEnd: setGain,
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqRange,
          infoMessage: '频段能量超阈后最大再衰减多少。0 = 纯静态整形。',
          value: range,
          defaultValue: defRange,
          onResetToDefault: () => setRange(defRange),
          min: 0,
          max: 24,
          unit: 'dB',
          enabled: en,
          format: (v) => v.toStringAsFixed(1),
          onChanged: setRange,
          onChangedEnd: setRange,
        ),
        const SizedBox(height: AuraSpace.sm),
        ValueSlider(
          label: l.dyneqThreshold,
          infoMessage: '该频段包络超过此电平才开始动态衰减。太低误杀，太高不动作。',
          value: threshold,
          defaultValue: defThreshold,
          onResetToDefault: () => setThreshold(defThreshold),
          min: -60,
          max: 0,
          unit: 'dB',
          enabled: en,
          format: (v) => v.toStringAsFixed(0),
          onChanged: setThreshold,
          onChangedEnd: setThreshold,
        ),
      ],
    );
  }
}
