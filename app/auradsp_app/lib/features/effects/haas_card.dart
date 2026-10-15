// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 06B Haas 差分环绕 (右声道延迟 + 干湿混合) ----
 * stereo 后 / reverb 前；左声道恒直通保单声道兼容。
 * 延迟滑块到 0 只归零延迟，不关开关（stereo 解耦教训）。 */
class _HaasCard extends StatelessWidget {
  final AppModel model;
  const _HaasCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: kEffectCardIndex['haas'],
      title: l.stHaas,
      collapsed: !model.haasOn,
      latencyMs: model.componentLatency('haas').ms,
      latencyMeasured: model.componentLatency('haas').measured,
      latencyEstimated: model.componentLatency('haas').estimated,
      latencyProbing: model.isProbingLatency('haas'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('haas')
          ? () => model.refreshComponentLatency('haas')
          : null,
      latencyTick: model.getComponentLatencyTick('haas'),
      trailing: AuraSwitch(
        value: model.haasOn,
        onChanged: model.setHaasEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 延迟侧切换（差分环绕的声道偏好）
          Row(
            children: [
              Text(l.haasSide, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.haasSideTooltip),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  AuraChoiceChip(
                    label: l.haasSideRight,
                    selected: model.haasSide == 0,
                    onTap: model.haasOn
                        ? () => model.setHaasSide(0)
                        : null,
                  ),
                  AuraChoiceChip(
                    label: l.haasSideLeft,
                    selected: model.haasSide == 1,
                    onTap: model.haasOn
                        ? () => model.setHaasSide(1)
                        : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // 延迟量
          ValueSlider(
            label: l.haasDelay,
            infoMessage: '延迟侧 0~25ms（Haas 定位差）。12ms 附近声场出头中，太大则成回声。',
            value: model.haasDelayMs,
            defaultValue: ParamDefaults.haasDelayMs,
            onResetToDefault: () =>
                model.setHaasDelay(ParamDefaults.haasDelayMs),
            min: 0,
            max: 25,
            unit: 'ms',
            enabled: model.haasOn,
            format: (v) => v.toStringAsFixed(1),
            onChanged: model.setHaasDelay,
            onChangedEnd: model.setHaasDelay,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 干湿混合
          ValueSlider(
            label: l.haasMix,
            infoMessage: '湿声（延迟差分）比例。拉低保中央人声聚焦，单声道设备自动兼容。',
            value: model.haasMix,
            defaultValue: ParamDefaults.haasMix,
            onResetToDefault: () =>
                model.setHaasMix(ParamDefaults.haasMix),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.haasOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setHaasMix,
            onChangedEnd: model.setHaasMix,
          ),
        ],
      ),
    );
  }
}
