// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
class _SpatialReverbCard extends StatefulWidget {
  final AppModel model;
  const _SpatialReverbCard({required this.model});

  @override
  State<_SpatialReverbCard> createState() => _SpatialReverbCardState();
}

class _SpatialReverbCardState extends State<_SpatialReverbCard> {

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = widget.model;
    final p = paletteOf(context);
    final isEnabled = m.isSpatialReverbOn;

    // curated chip 顺序固定；标签复用 reverbPreset0..7（按听感重命名）。
    final labels = <String>[
      l.reverbPreset0, // 大音乐厅
      l.reverbPreset1, // 音乐厅
      l.reverbPreset2, // 中音乐厅
      l.reverbPreset3, // 小音乐厅
      l.reverbPreset4, // 录音棚
      l.reverbPreset5, // 房间
      l.reverbPreset6, // 大礼堂
      l.reverbPreset7, // 板式混响
    ];
    final legacyId = m.reverbPreset >= 0 &&
            !kReverbCuratedPresets.contains(m.reverbPreset)
        ? m.reverbPreset
        : null;
    // 引擎徽标：优先引擎回读（reverb.engine），无回读时按本地路径兜底。
    final engine = m.reverbPreset == -1
        ? -1
        : (m.reverbEngine >= 0
            ? m.reverbEngine
            : (m.reverbStereoPath ? 0 : 1));

    return SectionCard(
      index: kEffectCardIndex['reverb'],
      title: l.spatialReverbTitle,
      collapsed: !isEnabled,
      latencyMs: m.componentLatency('reverb').ms,
      latencyEnabled: m.isSectionEnabled('reverb'),
              latencyMeasured: m.componentLatency('reverb').measured,
              latencyEstimated: m.componentLatency('reverb').estimated,
              latencyProbing: m.isProbingLatency('reverb'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('reverb')
          ? () => m.refreshComponentLatency('reverb')
          : null,
      latencyTick: m.getComponentLatencyTick('reverb'),
      trailing: AuraSwitch(
        value: isEnabled,
        onChanged: (v) => m.setSpatialReverbEnabled(v),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 置顶 3D 声学室沉浸视效（动态联动 roomSize 与 stereoWidth）
          RepaintBoundary(
            child: _Freeverb3DStage(
              decay: m.fvDecay,
              damp: m.fvDamp,
              roomSize: m.fvRoomSize,
              stereoWidth: m.fvWidth,
              active: isEnabled,
            ),
          ),
          const SizedBox(height: AuraSpace.md),

          // 2. 预设空间选择（curated 8 档 + 旧会话 legacy 档 + 自定义）
          Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.sm,
            children: [
              for (var i = 0; i < kReverbCuratedPresets.length; i++)
                AuraChip(
                  labels[i],
                  selected: isEnabled &&
                      m.reverbPreset == kReverbCuratedPresets[i],
                  onTap: () => m.selectReverbPreset(kReverbCuratedPresets[i]),
                ),
              if (legacyId != null)
                AuraChip(
                  l.reverbLegacyPreset(legacyId),
                  selected: isEnabled,
                  onTap: () => m.selectReverbPreset(legacyId),
                ),
              AuraChip(
                l.reverbCustom,
                icon: Icons.tune_rounded,
                selected: isEnabled && m.reverbPreset == -2,
                onTap: () {
                  if (m.reverbPreset != -2) {
                    m.selectReverbPreset(-2);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),

          // 3. 当前实际引擎（诚实显示：立体声 vendor / 多声道 FDN）
          Row(
            children: [
              Text(l.reverbEngineLabel,
                  style: labelOf(p, color: p.textDim)),
              const SizedBox(width: 4),
              InfoBadge(message: l.reverbEngineInfo),
              const Spacer(),
              _StageBadge(
                label: engine == 1
                    ? l.reverbEngineMc
                    : (engine == 0
                        ? l.reverbEngineStereo
                        : l.reverbEngineOff),
                color: engine == 1 ? p.accent2 : p.success,
                icon: engine == 1
                    ? Icons.speaker_group_rounded
                    : Icons.surround_sound_rounded,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),

          // 4. 核心滑块：混响干湿比 (Wet/Dry Mix)
          ValueSlider(
            label: l.reverbMix,
            infoMessage: l.reverbHintMix,
            value: m.fvWet,
            defaultValue: ParamDefaults.fvWet,
            onResetToDefault: () => m.setReverbCustomParam('wet', ParamDefaults.fvWet),
            min: 0,
            max: 1,
            unit: '%',
            enabled: isEnabled,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => m.setReverbCustomParam('wet', v),
            onChangedEnd: (v) => m.setReverbCustomParam('wet', v),
          ),

          // 5. LFE 入混响（仅 MC 路径且源带 LFE 时显示）
          if (m.reverbMcPath && m.fileChannels >= 6) ...[
            const SizedBox(height: AuraSpace.sm),
            Row(
              children: [
                Text(l.reverbLfe, style: labelOf(p, color: p.text)),
                const SizedBox(width: 4),
                InfoBadge(message: l.reverbLfeInfo),
                const Spacer(),
                ParamSwitch(
                  param: ParamRegistry.reverbLfe,
                  model: m,
                ),
              ],
            ),
          ],
          const SizedBox(height: AuraSpace.md),

          // 6. 高级声学物理精调（标准折叠面板）
          _SpatialReverbAdvanced(model: m),
        ],
      ),
    );
  }
}

class _SpatialReverbAdvanced extends StatelessWidget {
  final AppModel model;
  const _SpatialReverbAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    final isEnabled = m.isSpatialReverbOn;
    final agcStr = 'AGC: ${m.reverbAutoGain ? "ON" : "OFF"}';
    final trimStr =
        '${(m.reverbOutputGain >= 0 ? "+" : "")}${m.reverbOutputGain.toStringAsFixed(1)} dB';
    final roomStr =
        '${(m.fvRoomSize).toStringAsFixed(1)}x · ${(m.fvDecay * 100).toStringAsFixed(0)}%';
    final maxWidth = m.reverbMcPath ? 2.0 : 1.0;

    return AdvancedSection(
      summary: '$roomStr · $agcStr · $trimStr',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // WP1：预延迟暂只在 MC FDN 路径暴露（立体声 vendor 原生参数在 WP2）。
          if (m.reverbMcPath)
            ValueSlider(
              label: l.reverbPredelay,
              infoMessage: l.reverbPredelayInfo,
              value: m.reverbPredelay,
              defaultValue: ParamDefaults.reverbPredelay,
              onResetToDefault: () =>
                  m.setReverbPredelay(ParamDefaults.reverbPredelay),
              min: 0,
              max: 100,
              unit: 'ms',
              enabled: isEnabled,
              format: (v) => v.toStringAsFixed(0),
              onChanged: m.setReverbPredelay,
              onChangedEnd: m.setReverbPredelay,
            ),
          ValueSlider(
            label: l.reverbRoomSize,
            infoMessage: l.reverbHintSize,
            value: m.fvRoomSize,
            defaultValue: ParamDefaults.fvRoomSize,
            onResetToDefault: () =>
                m.setReverbCustomParam('roomSize', ParamDefaults.fvRoomSize),
            min: 0.5,
            max: 2.5,
            unit: 'x',
            enabled: isEnabled,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => m.setReverbCustomParam('roomSize', v),
            onChangedEnd: (v) => m.setReverbCustomParam('roomSize', v),
          ),
          ValueSlider(
            label: l.fvDecayLabel,
            infoMessage: l.reverbHintDecay,
            value: m.fvDecay,
            defaultValue: ParamDefaults.fvDecay,
            onResetToDefault: () =>
                m.setReverbCustomParam('decay', ParamDefaults.fvDecay),
            min: 0,
            max: 1,
            unit: '%',
            enabled: isEnabled,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => m.setReverbCustomParam('decay', v),
            onChangedEnd: (v) => m.setReverbCustomParam('decay', v),
          ),
          ValueSlider(
            label: l.reverbStereoWidth,
            infoMessage:
                m.reverbMcPath ? l.reverbHintWidthMc : l.reverbHintWidth,
            value: m.fvWidth.clamp(0.2, maxWidth),
            defaultValue: ParamDefaults.fvWidth,
            onResetToDefault: () =>
                m.setReverbCustomParam('width', ParamDefaults.fvWidth),
            min: 0.2,
            max: maxWidth,
            unit: 'x',
            enabled: isEnabled,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => m.setReverbCustomParam('width', v),
            onChangedEnd: (v) => m.setReverbCustomParam('width', v),
          ),
          ValueSlider(
            label: l.fvDampLabel,
            infoMessage: l.reverbHintDamp,
            value: m.fvDamp,
            defaultValue: ParamDefaults.fvDamp,
            onResetToDefault: () =>
                m.setReverbCustomParam('damp', ParamDefaults.fvDamp),
            min: 0,
            max: 1,
            unit: '%',
            enabled: isEnabled,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => m.setReverbCustomParam('damp', v),
            onChangedEnd: (v) => m.setReverbCustomParam('damp', v),
          ),
          ValueSlider(
            label: l.fvDryLabel,
            infoMessage: l.reverbHintDry,
            value: m.fvDry,
            defaultValue: ParamDefaults.fvDry,
            onResetToDefault: () =>
                m.setReverbCustomParam('dry', ParamDefaults.fvDry),
            min: 0,
            max: 1,
            unit: '%',
            enabled: isEnabled,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => m.setReverbCustomParam('dry', v),
            onChangedEnd: (v) => m.setReverbCustomParam('dry', v),
          ),
          const SizedBox(height: AuraSpace.md),
          OutputGainFrame(
            child: Column(
              children: [
                _AutoGainRow(
                  label: l.autoGainCompensation,
                  tooltip: l.autoGainCompensationTooltip,
                  value: m.reverbAutoGain,
                  enabled: isEnabled,
                  onChanged: m.setReverbAutoGain,
                ),
                const SizedBox(height: AuraSpace.xs),
                ValueSlider(
                  label: l.outputGainGate,
                  infoMessage: l.outputGainGateTooltip,
                  value: m.reverbOutputGain,
                  defaultValue: ParamDefaults.reverbOutputGain,
                  onResetToDefault: () =>
                      m.setReverbOutputGain(ParamDefaults.reverbOutputGain),
                  min: -12.0,
                  max: 6.0,
                  unit: 'dB',
                  enabled: isEnabled,
                  format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                  onChanged: m.setReverbOutputGain,
                  onChangedEnd: m.setReverbOutputGain,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
