// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 02B BassMono (低频单声道化，链头) ----
 * 分频点以下 L/R 取平均。与 bass 卡相邻但独立开关：链头处理，
 * 不随 bassOn 折叠。频率滑块到下限不关开关（stereo 解耦教训）。 */
class _BassMonoCard extends StatelessWidget {
  final AppModel model;
  const _BassMonoCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: '03',
      title: l.stBassmono,
      collapsed: !model.bassmonoOn,
      latencyMs: model.componentLatency('bassmono').ms,
      latencyMeasured: model.componentLatency('bassmono').measured,
      latencyProbing: model.isProbingLatency('bassmono'),
      onRefreshLatency: () => model.refreshComponentLatency('bassmono'),
      latencyTick: model.getComponentLatencyTick('bassmono'),
      trailing: AuraSwitch(
        value: model.bassmonoOn,
        onChanged: model.setBassmonoEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 快捷分频点（主卡展示）
          Row(
            children: [
              Text(l.bassmonoFreq, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.bassmonoCombinedTooltip),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  for (final f in const [80.0, 120.0, 200.0])
                    AuraChoiceChip(
                      label: '${f.toStringAsFixed(0)} Hz',
                      selected:
                          (model.bassmonoFreq - f).abs() < 0.5,
                      onTap: model.bassmonoOn
                          ? () => model.setBassmonoFreq(f)
                          : null,
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          AdvancedSection(
            summary: '${model.bassmonoFreq.toStringAsFixed(0)} Hz',
            builder: (ctx) => ValueSlider(
              label: l.bassmonoFreq,
              infoMessage: l.bassmonoCombinedTooltip,
              value: model.bassmonoFreq,
              defaultValue: ParamDefaults.bassmonoFreq,
              onResetToDefault: () =>
                  model.setBassmonoFreq(ParamDefaults.bassmonoFreq),
              min: 20,
              max: 300,
              unit: 'Hz',
              enabled: model.bassmonoOn,
              format: (v) => v.toStringAsFixed(0),
              onChanged: model.setBassmonoFreq,
              onChangedEnd: model.setBassmonoFreq,
            ),
          ),
        ],
      ),
    );
  }
}
