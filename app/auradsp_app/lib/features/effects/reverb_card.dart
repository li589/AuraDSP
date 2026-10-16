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
    final isEnabled = m.isSpatialReverbOn;

    final presets = <int, String>{
      0: l.reverbPreset0, // 大音乐厅
      1: l.reverbPreset1, // 音乐厅
      2: l.reverbPreset2, // 中音乐厅
      3: l.reverbPreset3, // 小音乐厅
      4: l.reverbPreset4, // 录音棚
      5: l.reverbPreset5, // 房间
      6: l.reverbPreset6, // 大礼堂
      7: l.reverbPreset7, // 板式混响
    };

    return SectionCard(
      index: kEffectCardIndex['spatialReverb'],
      title: l.spatialReverbTitle,
      collapsed: !isEnabled,
      latencyMs: m.componentLatency('reverb').ms,
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

          // 2. 预设空间选择
          Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.sm,
            children: [
              for (final e in presets.entries)
                AuraChip(
                  e.value,
                  selected: isEnabled && m.reverbPreset == e.key,
                  onTap: () => m.selectReverbPreset(e.key),
                ),
              AuraChip(
                l.reverbCustom,
                icon: Icons.tune_rounded,
                selected: isEnabled && m.reverbPreset == -2 && m.fvOn,
                onTap: () {
                  if (m.reverbPreset != -2) {
                    m.selectReverbPreset(-2);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),

          // 3. 核心滑块：混响干湿比 (Wet/Dry Mix)
          ValueSlider(
            label: l.reverbMix,
            infoMessage: '混响声的音量占比。数值越高，空间空灵回荡感越强，如同置身音乐厅或教堂。',
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
          const SizedBox(height: AuraSpace.md),

          // 4. 高级声学物理精调（标准折叠面板）
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

    return AdvancedSection(
      summary: '$roomStr · $agcStr · $trimStr',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.reverbRoomSize,
            infoMessage: '模拟虚拟房间尺寸。尺寸越大，声场越开阔、反射间隔越长。',
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
            infoMessage: '反射残响消散时间。数值越大，声音余韵回荡持续越久。',
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
            infoMessage: '混响声的双耳立体声扩展度。让回声包围整个头部。',
            value: m.fvWidth,
            defaultValue: ParamDefaults.fvWidth,
            onResetToDefault: () =>
                m.setReverbCustomParam('width', ParamDefaults.fvWidth),
            min: 0.2,
            max: 2.0,
            unit: 'x',
            enabled: isEnabled,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => m.setReverbCustomParam('width', v),
            onChangedEnd: (v) => m.setReverbCustomParam('width', v),
          ),
          ValueSlider(
            label: l.fvDampLabel,
            infoMessage: '高频阻尼吸收。越大音色越温暖柔和，越小越明亮通透。',
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
            infoMessage: '原始直达声保留量。确保人声吐字清晰结实。',
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
