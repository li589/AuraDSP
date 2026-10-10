/*
 * effects_page.dart — 控制页：对齐 engine_api 参数模型 v1
 *
 * 规范落地：
 * - Phase 1: 视觉降噪与术语规整，废除品质档拦截
 * - Phase 2: 空间混响二合一，双向状态机联动，3D 声学室动态尺寸映射
 * - Phase 3: 多段交互式 EQ 频谱面板与发光 Q 旋钮
 * - Phase 4: 低音重构（谐波注入）、电子管模拟器卡片与组件级微型延迟徽标
 */
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/presets.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
import 'interactive_eq.dart';
import 'widgets.dart';

class EffectsPage extends StatelessWidget {
  final AppModel model;
  const EffectsPage({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return PageScaffold(
      eyebrow: l.pageEffectsEyebrow,
      title: l.pageEffectsTitle,
      children: [
        _SignalFlowBar(model: model), // 信号流节点
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _BassCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _SpatialReverbCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _ConvolverCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _DdcCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _EqualizerCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _StereoCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _TubeCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _PostCard(model: model),
        ),
        _PresetCard(model: model),
        // 收尾说明（静音，不加卡片）
        Padding(
          padding: const EdgeInsets.fromLTRB(
              AuraSpace.xs, AuraSpace.sm, AuraSpace.xs, 0),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(Icons.info_outline, size: 14,
                  color: p.warning.withValues(alpha: 0.8)),
              const SizedBox(width: AuraSpace.sm),
              Expanded(child: Text(l.guardBlocked, style: captionOf(p))),
            ],
          ),
        ),
      ],
    );
  }
}

/* ---- 信号流条：单行紧凑可视化，启用节点高亮 ---- */

class _SignalFlowBar extends StatelessWidget {
  final AppModel model;
  const _SignalFlowBar({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        const nodes = [
          ('tube', 'TUBE'),
          ('bass', 'BASS'),
          ('eq', 'EQ'),
          ('convolver', 'IR'),
          ('liveprog', 'SCRIPT'),
          ('crossfeed', 'XFEED'),
          ('stereo', 'WIDTH'),
          ('reverb', 'REVERB'),
          ('out', 'OUT'),
        ];
        bool on(String id) => switch (id) {
              'tube' => model.tubeOn,
              'bass' => model.bassOn,
              'eq' => model.eqOn,
              'convolver' => model.convEnabled && model.convReady,
              'liveprog' => model.lpEnabled,
              'crossfeed' => model.xfeedOn,
              'stereo' => model.stereoMix > 0,
              'reverb' => model.isSpatialReverbOn,
              _ => true,
            };
        return Container(
          padding: const EdgeInsets.symmetric(
              horizontal: AuraSpace.md, vertical: AuraSpace.sm + 2),
          decoration: BoxDecoration(
            color: p.panel,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: p.hairline),
          ),
          child: Row(
            children: [
              Text(l.signalFlow.toUpperCase(), style: eyebrowOf(p)),
              const SizedBox(width: AuraSpace.md),
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (var i = 0; i < nodes.length; i++) ...[
                        if (i > 0)
                          Icon(Icons.arrow_forward_rounded,
                              size: 12, color: p.textDim.withValues(alpha: 0.5)),
                        const SizedBox(width: AuraSpace.xs + 2),
                        _FlowNode(
                            label: nodes[i].$2,
                            active: on(nodes[i].$1)),
                        const SizedBox(width: AuraSpace.xs + 2),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FlowNode extends StatelessWidget {
  final String label;
  final bool active;
  const _FlowNode({required this.label, required this.active});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return AnimatedContainer(
      duration: AuraDur.fast,
      curve: AuraCurve.standard,
      padding: const EdgeInsets.symmetric(
          horizontal: AuraSpace.sm, vertical: AuraSpace.xxs + 1),
      decoration: BoxDecoration(
        color: active ? p.accent.withValues(alpha: 0.14) : Colors.transparent,
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        border: Border.all(
          color: active ? p.accent.withValues(alpha: 0.55) : p.hairline,
        ),
      ),
      child: Text(label,
          style: monoOf(p, size: 10, color: active ? p.accent : p.textDim)),
    );
  }
}

/* ---- 通用选择 Chip ---- */

class _ChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;

  const _ChoiceChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AuraRadius.xs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? p.accent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          border: Border.all(
            color: selected ? p.accent : p.hairline,
          ),
        ),
        child: Text(
          label,
          style: monoOf(
            p,
            size: 11,
            color: selected ? p.accent : p.textDim,
          ),
        ),
      ),
    );
  }
}

/* ---- 01 Bass (低音增强重构) ---- */

class _BassCard extends StatelessWidget {
  final AppModel model;
  const _BassCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return SectionCard(
      index: '01',
      title: l.bassBoost,
      latencyMs: model.getComponentLatency('bass'),
      onRefreshLatency: () => model.refreshComponentLatency('bass'),
      latencyTick: model.getComponentLatencyTick('bass'),
      trailing: AuraSwitch(
        value: model.bassOn,
        onChanged: (v) => model.setInt('bass.enable', v ? 1 : 0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 主驱动：低音增强强度 (Bass Intensity)
          ValueSlider(
            label: l.bassIntensity,
            value: model.bassIntensity,
            defaultValue: ParamDefaults.bassIntensity,
            onResetToDefault: () =>
                model.setBassIntensity(ParamDefaults.bassIntensity),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.bassOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setBassIntensity,
            onChangedEnd: model.setBassIntensity,
          ),
          const SizedBox(height: AuraSpace.md),
          // 低音增强模式 (动态 DBB / 纯净低架 / 心理声学谐波)
          Text(l.bassMode, style: captionOf(p)),
          const SizedBox(height: AuraSpace.xs),
          Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.sm,
            children: [
              _ChoiceChip(
                label: l.bassModeDynamic,
                selected: model.bassMode == 0,
                onTap: () => model.setBassMode(0),
              ),
              _ChoiceChip(
                label: l.bassModeShelf,
                selected: model.bassMode == 1,
                onTap: () => model.setBassMode(1),
              ),
              _ChoiceChip(
                label: l.bassModeHarmonic,
                selected: model.bassMode == 2,
                onTap: () => model.setBassMode(2),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _BassAdvanced(model: model),
        ],
      ),
    );
  }
}

class _BassAdvanced extends StatefulWidget {
  final AppModel model;
  const _BassAdvanced({required this.model});

  @override
  State<_BassAdvanced> createState() => _BassAdvancedState();
}

class _BassAdvancedState extends State<_BassAdvanced> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final m = widget.model;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                AnimatedRotation(
                  duration: AuraDur.fast,
                  turns: _open ? 0.25 : 0,
                  child: Icon(Icons.expand_more_rounded,
                      size: 20, color: p.accent),
                ),
                const SizedBox(width: AuraSpace.sm),
                Text(l.advanced, style: labelOf(p, color: p.text)),
                const Spacer(),
                Text(
                  '${m.bassCutoff.toStringAsFixed(0)} Hz · ${(m.bassHarmonics * 100).toStringAsFixed(0)}%',
                  style: monoOf(p, size: 10, color: p.textDim),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: AuraDur.base,
          sizeCurve: AuraCurve.standard,
          crossFadeState:
              _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: AuraSpace.sm),
            child: Column(
              children: [
                ValueSlider(
                  label: l.bassCutoff,
                  value: m.bassCutoff,
                  defaultValue: ParamDefaults.bassCutoff,
                  min: 30,
                  max: 300,
                  unit: 'Hz',
                  enabled: m.bassOn,
                  format: (v) => v.toStringAsFixed(0),
                  onChanged: m.setBassCutoff,
                  onChangedEnd: m.setBassCutoff,
                ),
                ValueSlider(
                  label: l.bassHarmonics,
                  value: m.bassHarmonics,
                  defaultValue: ParamDefaults.bassHarmonics,
                  min: 0,
                  max: 1,
                  unit: '%',
                  enabled: m.bassOn,
                  format: (v) => (v * 100).toStringAsFixed(0),
                  onChanged: m.setBassHarmonics,
                  onChangedEnd: m.setBassHarmonics,
                ),
                ValueSlider(
                  label: l.bassBlend,
                  value: m.bassHarmonicBlend,
                  defaultValue: ParamDefaults.bassHarmonicBlend,
                  min: 0,
                  max: 1,
                  unit: '%',
                  enabled: m.bassOn,
                  format: (v) => (v * 100).toStringAsFixed(0),
                  onChanged: m.setBassHarmonicBlend,
                  onChangedEnd: m.setBassHarmonicBlend,
                ),
                ValueSlider(
                  label: l.bassSubFloor,
                  value: m.bassSubFloor,
                  defaultValue: ParamDefaults.bassSubFloor,
                  min: 10,
                  max: 40,
                  unit: 'Hz',
                  enabled: m.bassOn,
                  format: (v) => v.toStringAsFixed(0),
                  onChanged: m.setBassSubFloor,
                  onChangedEnd: m.setBassSubFloor,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/* ---- 02 空间混响 (Spatial Reverb，统一预设与参数精调架构) ---- */

class _SpatialReverbCard extends StatefulWidget {
  final AppModel model;
  const _SpatialReverbCard({required this.model});

  @override
  State<_SpatialReverbCard> createState() => _SpatialReverbCardState();
}

class _SpatialReverbCardState extends State<_SpatialReverbCard> {
  bool _open = false;

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
      index: '02',
      title: l.spatialReverbTitle,
      latencyMs: m.getComponentLatency('reverb'),
      onRefreshLatency: () => m.refreshComponentLatency('reverb'),
      latencyTick: m.getComponentLatencyTick('reverb'),
      trailing: AuraSwitch(
        value: isEnabled,
        onChanged: (v) => m.setSpatialReverbEnabled(v),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 预设空间选择
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
                selected: isEnabled && m.reverbPreset == -1 && m.fvOn,
                onTap: () {
                  if (m.reverbPreset != -1) {
                    m.selectReverbPreset(-1);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),

          // 核心滑块：混响干湿比 (Wet/Dry Mix)
          ValueSlider(
            label: l.reverbMix,
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

          // 3D 声学室视效（动态联动 roomSize 与 stereoWidth）
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

          // 高级声学物理精调（默认折叠）
          _SpatialReverbAdvanced(
            model: m,
            open: _open,
            onToggle: () => setState(() => _open = !_open),
          ),
        ],
      ),
    );
  }
}

class _SpatialReverbAdvanced extends StatelessWidget {
  final AppModel model;
  final bool open;
  final VoidCallback onToggle;

  const _SpatialReverbAdvanced({
    required this.model,
    required this.open,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final m = model;
    final isEnabled = m.isSpatialReverbOn;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onToggle,
            child: Row(
              children: [
                AnimatedRotation(
                  duration: AuraDur.fast,
                  turns: open ? 0.25 : 0,
                  child: Icon(Icons.expand_more_rounded,
                      size: 20, color: p.accent),
                ),
                const SizedBox(width: AuraSpace.sm),
                Text(l.advanced, style: labelOf(p, color: p.text)),
                const Spacer(),
                Text(
                  '${(m.fvRoomSize).toStringAsFixed(1)}x · ${(m.fvDecay * 100).toStringAsFixed(0)}%',
                  style: monoOf(p, size: 10, color: p.textDim),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: AuraDur.base,
          sizeCurve: AuraCurve.standard,
          crossFadeState:
              open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: AuraSpace.sm),
            child: Column(
              children: [
                ValueSlider(
                  label: l.reverbRoomSize,
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
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/* ---- 03 脉冲响应卷积 (Convolver) ---- */

class _ConvolverCard extends StatelessWidget {
  final AppModel model;
  const _ConvolverCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      index: '03',
      title: l.convTitle,
      latencyMs: model.getComponentLatency('convolver'),
      onRefreshLatency: () => model.refreshComponentLatency('convolver'),
      latencyTick: model.getComponentLatencyTick('convolver'),
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.convEnabled,
          onChanged: model.convReady ? model.setConvolverEnabled : null,
        ),
      ),
      child: ListenableBuilder(
        listenable: model,
        builder: (_, _) {
          if (!model.convReady) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(spacing: AuraSpace.sm, runSpacing: AuraSpace.sm, children: [
                  AuraChip(l.convOpenIr, icon: Icons.folder_open_outlined,
                      onTap: () => _pickIr(context)),
                ]),
                const SizedBox(height: AuraSpace.sm),
                Text(l.convNoIr, style: captionOf(p)),
              ],
            );
          }
          final durMs = model.convFrames * 1000.0 / 48000.0;
          final dur = durMs >= 1000
              ? '${(durMs / 1000).toStringAsFixed(2)} s'
              : '${durMs.toStringAsFixed(0)} ms';
          final resampled = model.convSrcRate != 0 && model.convSrcRate != 48000;
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Wrap(spacing: AuraSpace.sm, runSpacing: AuraSpace.sm, children: [
                AuraChip(l.convOpenIr, icon: Icons.folder_open_outlined,
                    onTap: () => _pickIr(context)),
                AuraChip(l.convClear, icon: Icons.delete_outline, danger: true,
                    onTap: () => model.clearConvolver()),
              ]),
              const SizedBox(height: AuraSpace.md),
              if (model.convSpectrum.isNotEmpty) ...[
                _IrSpectrumGraph(
                  spectrum: model.convSpectrum,
                  channels: model.convChannels,
                ),
                const SizedBox(height: AuraSpace.md),
              ],
              ValueSlider(
                label: l.convMix,
                value: model.convMix,
                defaultValue: ParamDefaults.convMix,
                min: 0,
                max: 1,
                unit: '%',
                format: (v) => (v * 100).toStringAsFixed(0),
                onChanged: (v) => model.setFloat('convolver.mix', v),
                onChangedEnd: (v) => model.setFloat('convolver.mix', v),
              ),
              const SizedBox(height: AuraSpace.xs),
              Text(l.convMixHint, style: captionOf(p)),
              const SizedBox(height: AuraSpace.md),
              Text(
                '${model.convFrames} 帧 · $dur · '
                '${model.convChannels}ch · 峰值 '
                '${(20 * math.log(model.convPeak <= 1e-6 ? 1e-6 : model.convPeak) / math.ln10).toStringAsFixed(1)} dBFS'
                ' · 源 ${model.convSrcRate}Hz',
                style: monoOf(p, size: 12, color: p.text),
              ),
              if (resampled) ...[
                const SizedBox(height: AuraSpace.xs),
                Row(children: [
                  Icon(Icons.info_outline, size: 13, color: p.warning),
                  const SizedBox(width: AuraSpace.xs + 2),
                  Text(l.convResampled, style: captionOf(p)),
                ]),
              ],
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickIr(BuildContext context) async {
    const type = XTypeGroup(label: 'Audio IR',
        extensions: ['wav', 'flac']);
    final f = await openFile(acceptedTypeGroups: [type]);
    if (f != null) model.loadConvolverIr(f.path);
  }
}

/* ---- 04 VDC 空间校正 ---- */

class _DdcCard extends StatelessWidget {
  final AppModel model;
  const _DdcCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      index: '04',
      title: l.ddcTitle,
      latencyMs: model.getComponentLatency('ddc'),
      onRefreshLatency: () => model.refreshComponentLatency('ddc'),
      latencyTick: model.getComponentLatencyTick('ddc'),
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.ddcOn,
          onChanged: model.ddcReady ? model.setDdcEnabled : null,
        ),
      ),
      child: ListenableBuilder(
        listenable: model,
        builder: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(spacing: AuraSpace.sm, runSpacing: AuraSpace.sm, children: [
              AuraChip(l.ddcOpen, icon: Icons.folder_open_outlined,
                  onTap: () => _pickVdc(context)),
              if (model.ddcReady)
                AuraChip(l.ddcLoaded, icon: Icons.check_circle_outline,
                    onTap: null),
            ]),
            const SizedBox(height: AuraSpace.sm),
            Text(model.ddcReady ? '${l.ddcLoaded}：VDC' : l.ddcNoFile,
                style: captionOf(p)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickVdc(BuildContext context) async {
    const type = XTypeGroup(label: 'VDC', extensions: ['vdc']);
    final f = await openFile(acceptedTypeGroups: [type]);
    if (f != null) model.loadVdc(f.path);
  }
}

/* ---- 05 Equalizer (多段图形均衡器) ---- */

class _EqualizerCard extends StatelessWidget {
  final AppModel model;
  const _EqualizerCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '05',
      title: l.eqMultiBand,
      latencyMs: model.getComponentLatency('eq'),
      onRefreshLatency: () => model.refreshComponentLatency('eq'),
      latencyTick: model.getComponentLatencyTick('eq'),
      trailing: AuraSwitch(
        value: model.eqOn,
        onChanged: (v) => model.setInt('eq.enable', v ? 1 : 0),
      ),
      child: InteractiveSpectrumEQPanel(model: model),
    );
  }
}

/* ---- 06 Stereo (立体声声场展宽) ---- */

class _StereoCard extends StatelessWidget {
  final AppModel model;
  const _StereoCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '06',
      title: l.stereoWiden,
      latencyMs: model.getComponentLatency('stereo'),
      onRefreshLatency: () => model.refreshComponentLatency('stereo'),
      latencyTick: model.getComponentLatencyTick('stereo'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.stereoWiden,
            value: model.stereoMix,
            defaultValue: ParamDefaults.stereoMix,
            onResetToDefault: model.resetStereoWiden,
            overridden: model.stereoBandUsed,
            overriddenNote: model.stereoBandUsed ? '分带生效中' : null,
            min: 0,
            max: 1,
            unit: '%',
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) =>
                model.setFloat('stereo.mix', v * AppModel.stereoWidenMax),
            onChangedEnd: (v) =>
                model.setFloat('stereo.mix', v * AppModel.stereoWidenMax),
          ),
          const SizedBox(height: AuraSpace.xs),
          Text(l.stereoWidenHint, style: captionOf(paletteOf(context))),
          const SizedBox(height: AuraSpace.md),
          _StereoAdvanced(model: model),
        ],
      ),
    );
  }
}

/// 声场分带细化（默认折叠）：5 个子带独立 mix
class _StereoAdvanced extends StatefulWidget {
  final AppModel model;
  const _StereoAdvanced({required this.model});

  @override
  State<_StereoAdvanced> createState() => _StereoAdvancedState();
}

class _StereoAdvancedState extends State<_StereoAdvanced> {
  bool _open = false;
  static const _bandLabels = ['低频带', '中低带', '中频带', '中高带', '高频带'];

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final m = widget.model;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(children: [
              AnimatedRotation(
                duration: AuraDur.fast,
                turns: _open ? 0.25 : 0,
                child: Icon(Icons.expand_more_rounded,
                    size: 20, color: p.accent),
              ),
              const SizedBox(width: AuraSpace.sm),
              Text(l.advanced,
                  style: labelOf(p,
                      color: m.stereoBandUsed ? p.accent : p.text)),
              const Spacer(),
              if (m.stereoBandUsed)
                AuraChip('重置分带',
                    icon: Icons.restore_rounded,
                    onTap: m.resetStereoBandsToGlobal),
            ]),
          ),
        ),
        AnimatedCrossFade(
          duration: AuraDur.base,
          sizeCurve: AuraCurve.standard,
          crossFadeState:
              _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: AuraSpace.sm),
            child: Column(
              children: [
                for (var i = 0; i < 5; i++)
                  _BandSlider(
                    model: m,
                    index: i,
                    label: _bandLabels[i],
                  ),
                const SizedBox(height: AuraSpace.xs),
                Text('独立调节各频段展开度；调节任一带即脱离全局总滑块',
                    style: captionOf(p)),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _BandSlider extends StatelessWidget {
  final AppModel model;
  final int index;
  final String label;

  const _BandSlider({
    required this.model,
    required this.index,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final m = model;
    return ListenableBuilder(
      listenable: m,
      builder: (_, _) {
        final v = m.stereoBands[index];
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            SizedBox(
              width: 56,
              child: Text(label, style: labelOf(p, color: p.textDim)),
            ),
            Expanded(
              child: Slider(
                value: v.clamp(0.0, 1.0),
                min: 0,
                max: 1,
                onChanged: (val) =>
                    m.setFloat('stereo.band${index + 1}', val),
              ),
            ),
            SizedBox(
              width: 44,
              child: Text(
                  '${(v * 100).toStringAsFixed(0)}%',
                  textAlign: TextAlign.right,
                  style: monoOf(p, size: 12, color: p.text)),
            ),
          ]),
        );
      },
    );
  }
}

/* ---- 07 Tube Simulator (电子管模拟器) ---- */

class _TubeCard extends StatelessWidget {
  final AppModel model;
  const _TubeCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return SectionCard(
      index: '07',
      title: l.tubeTitle,
      latencyMs: model.getComponentLatency('tube'),
      onRefreshLatency: () => model.refreshComponentLatency('tube'),
      latencyTick: model.getComponentLatencyTick('tube'),
      trailing: AuraSwitch(
        value: model.tubeOn,
        onChanged: model.setTubeEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 饱和驱动度 (Drive / Saturation)
          ValueSlider(
            label: l.tubeDrive,
            value: model.tubeGain,
            defaultValue: ParamDefaults.tubeGain,
            onResetToDefault: () => model.setTubeGain(ParamDefaults.tubeGain),
            min: -3,
            max: 12,
            unit: 'dB',
            enabled: model.tubeOn,
            format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
            onChanged: model.setTubeGain,
            onChangedEnd: model.setTubeGain,
          ),
          const SizedBox(height: AuraSpace.md),
          // 电子管音色风格
          Text(l.tubeStyle, style: captionOf(p)),
          const SizedBox(height: AuraSpace.xs),
          Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.sm,
            children: [
              _ChoiceChip(
                label: l.tubeStyleTriode,
                selected: model.tubeStyle == 0,
                onTap: () => model.setTubeStyle(0),
              ),
              _ChoiceChip(
                label: l.tubeStylePentode,
                selected: model.tubeStyle == 1,
                onTap: () => model.setTubeStyle(1),
              ),
              _ChoiceChip(
                label: l.tubeStyleTape,
                selected: model.tubeStyle == 2,
                onTap: () => model.setTubeStyle(2),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _TubeAdvanced(model: model),
        ],
      ),
    );
  }
}

class _TubeAdvanced extends StatefulWidget {
  final AppModel model;
  const _TubeAdvanced({required this.model});

  @override
  State<_TubeAdvanced> createState() => _TubeAdvancedState();
}

class _TubeAdvancedState extends State<_TubeAdvanced> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final m = widget.model;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                AnimatedRotation(
                  duration: AuraDur.fast,
                  turns: _open ? 0.25 : 0,
                  child: Icon(Icons.expand_more_rounded,
                      size: 20, color: p.accent),
                ),
                const SizedBox(width: AuraSpace.sm),
                Text(l.advanced, style: labelOf(p, color: p.text)),
                const Spacer(),
                Text(
                  '${m.tubeOversampling}x · ${(m.tubeCompensation >= 0 ? '+' : '')}${m.tubeCompensation.toStringAsFixed(1)} dB',
                  style: monoOf(p, size: 10, color: p.textDim),
                ),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: AuraDur.base,
          sizeCurve: AuraCurve.standard,
          crossFadeState:
              _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: AuraSpace.sm),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l.tubeOversampling, style: captionOf(p)),
                const SizedBox(height: AuraSpace.xs),
                Wrap(
                  spacing: AuraSpace.sm,
                  children: [
                    for (final os in const [1, 2, 4])
                      _ChoiceChip(
                        label: '${os}x',
                        selected: m.tubeOversampling == os,
                        onTap: () => m.setTubeOversampling(os),
                      ),
                  ],
                ),
                const SizedBox(height: AuraSpace.md),
                ValueSlider(
                  label: l.tubeCompensation,
                  value: m.tubeCompensation,
                  defaultValue: ParamDefaults.tubeCompensation,
                  min: -6,
                  max: 6,
                  unit: 'dB',
                  enabled: m.tubeOn,
                  format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                  onChanged: m.setTubeCompensation,
                  onChangedEnd: m.setTubeCompensation,
                ),
                ValueSlider(
                  label: l.tubeMix,
                  value: m.tubeMix,
                  defaultValue: ParamDefaults.tubeMix,
                  min: 0,
                  max: 1,
                  unit: '%',
                  enabled: m.tubeOn,
                  format: (v) => (v * 100).toStringAsFixed(0),
                  onChanged: m.setTubeMix,
                  onChangedEnd: m.setTubeMix,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/* ---- 08 Post Gain / Limiter ---- */

class _PostCard extends StatelessWidget {
  final AppModel model;
  const _PostCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '08',
      title: l.postGain,
      latencyMs: model.getComponentLatency('post'),
      onRefreshLatency: () => model.refreshComponentLatency('post'),
      latencyTick: model.getComponentLatencyTick('post'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.postGain,
            value: model.postGain,
            defaultValue: ParamDefaults.postGain,
            min: -15,
            max: 15,
            unit: 'dB',
            format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
            onChanged: (v) => model.setFloat('post.gain', v),
            onChangedEnd: (v) => model.setFloat('post.gain', v),
          ),
          const SizedBox(height: AuraSpace.md),
          Container(height: 1, color: paletteOf(context).hairline),
          const SizedBox(height: AuraSpace.md),
          SectionTitle(
            l.limiter,
            trailing: AuraSwitch(
              value: model.limiterOn,
              onChanged: (v) => model.setInt('limiter.enable', v ? 1 : 0),
            ),
          ),
        ],
      ),
    );
  }
}

/* ---- 参数滑块 ---- */

class ValueSlider extends StatefulWidget {
  final String label;
  final double value;
  final double defaultValue;
  final double min, max;
  final String unit;
  final bool enabled;
  final String Function(double)? format;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangedEnd;
  final VoidCallback? onResetToDefault;
  final bool overridden;
  final String? overriddenNote;

  const ValueSlider({
    super.key,
    required this.label,
    required this.value,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    this.onChangedEnd,
    this.onResetToDefault,
    this.enabled = true,
    this.format,
    this.overridden = false,
    this.overriddenNote,
  });

  @override
  State<ValueSlider> createState() => _ValueSliderState();
}

class _ValueSliderState extends State<ValueSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final displayed = _dragging ?? widget.value;
    final fmt = widget.format ?? (v) => v.toStringAsFixed(1);
    final isCustom = (widget.value - widget.defaultValue).abs() > 1e-4;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 140,
                child: Text(
                  widget.label,
                  style: labelOf(p,
                      color: widget.enabled ? p.text : p.textDim),
                ),
              ),
              Expanded(
                child: Slider(
                  value: displayed.clamp(widget.min, widget.max),
                  min: widget.min,
                  max: widget.max,
                  onChanged: widget.enabled
                      ? (v) {
                          setState(() => _dragging = v);
                          widget.onChanged(v);
                        }
                      : null,
                  onChangeEnd: widget.enabled
                      ? (v) {
                          setState(() => _dragging = null);
                          widget.onChangedEnd?.call(v);
                        }
                      : null,
                ),
              ),
              const SizedBox(width: AuraSpace.sm),
              SizedBox(
                width: 60,
                child: Text(
                  '${fmt(displayed)} ${widget.unit}',
                  textAlign: TextAlign.right,
                  style: monoOf(p,
                      size: 12,
                      color: widget.enabled ? p.text : p.textDim),
                ),
              ),
              if (widget.onResetToDefault != null) ...[
                const SizedBox(width: 4),
                Tooltip(
                  message: '双击重置默认值',
                  child: InkWell(
                    onTap: widget.onResetToDefault,
                    borderRadius: BorderRadius.circular(AuraRadius.xs),
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(
                        Icons.refresh_rounded,
                        size: 14,
                        color: isCustom ? p.accent : p.textDim.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (widget.overridden && widget.overriddenNote != null)
            Padding(
              padding: const EdgeInsets.only(left: 140),
              child: Text(
                widget.overriddenNote!,
                style: captionOf(p, color: p.warning),
              ),
            ),
        ],
      ),
    );
  }
}

/* ---- 预设快照卡片 ---- */

class _PresetCard extends StatefulWidget {
  final AppModel model;
  const _PresetCard({required this.model});

  @override
  State<_PresetCard> createState() => _PresetCardState();
}

class _PresetCardState extends State<_PresetCard> {
  final _saveNameCtrl = TextEditingController();
  List<AuraPreset> _presets = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _saveNameCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _presets = PresetLibrary.listAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final m = widget.model;

    final factoryPresets = _presets.where((p) => p.isFactory).toList();
    final userPresets = _presets.where((p) => !p.isFactory).toList();

    return SectionCard(
      title: l.presetTitle,
      hint: l.presetHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 出厂预设
          if (factoryPresets.isNotEmpty) ...[
            Row(
              children: [
                Icon(Icons.stars_rounded, size: 14, color: p.accent),
                const SizedBox(width: 4),
                Text('出厂经典调音预设',
                    style: monoOf(p, size: 11, color: p.accent)),
              ],
            ),
            const SizedBox(height: AuraSpace.xs),
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              children: [
                for (final item in factoryPresets)
                  AuraChip(
                    item.name,
                    icon: Icons.music_note_rounded,
                    selected: m.activePresetName == item.name,
                    onTap: () {
                      m.loadPreset(item);
                      _reload();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('已载入出厂预设: ${item.name}'),
                          duration: const Duration(milliseconds: 1400),
                        ));
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: AuraSpace.md),
          ],

          // 用户自建预设
          Row(
            children: [
              Icon(Icons.folder_shared_rounded, size: 14, color: p.accent2),
              const SizedBox(width: 4),
              Text('我的自定义预设',
                  style: monoOf(p, size: 11, color: p.accent2)),
            ],
          ),
          const SizedBox(height: AuraSpace.xs),
          if (userPresets.isEmpty)
            Text('暂无用户自定义预设 — 调好参数后在下方保存',
                style: captionOf(p, color: p.textDim))
          else
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              children: [
                for (final item in userPresets)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AuraChip(
                        item.name,
                        icon: Icons.bookmark_border_rounded,
                        selected: m.activePresetName == item.name,
                        onTap: () {
                          m.loadPreset(item);
                          _reload();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text('已载入自定义预设: ${item.name}'),
                              duration: const Duration(milliseconds: 1400),
                            ));
                          }
                        },
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        onTap: () {
                          PresetLibrary.deletePreset(item);
                          _reload();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(l.presetDeleted),
                              duration: const Duration(milliseconds: 1200),
                            ));
                          }
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded,
                              size: 13, color: p.textDim),
                        ),
                      ),
                      const SizedBox(width: AuraSpace.xs),
                    ],
                  ),
              ],
            ),

          const SizedBox(height: AuraSpace.md),
          // 保存栏
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _saveNameCtrl,
                  decoration: InputDecoration(
                    hintText: '输入预设名称保存当前状态为用户预设',
                    hintStyle: captionOf(p),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.md, vertical: AuraSpace.sm),
                    filled: true,
                    fillColor: p.panelRaised,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      borderSide: BorderSide(color: p.hairline),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AuraSpace.sm),
              AuraChip(
                l.presetSave,
                icon: Icons.save_alt_rounded,
                selected: true,
                onTap: () {
                  final name = _saveNameCtrl.text.trim();
                  if (name.isEmpty) return;
                  final ok = m.saveAsUserPreset(name);
                  if (ok) _saveNameCtrl.clear();
                  _reload();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok ? l.presetSaved : l.presetSaveFail),
                      duration: const Duration(milliseconds: 1400),
                    ));
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/* ---- 脉冲频响包络柱状图 ---- */

class _IrSpectrumGraph extends StatelessWidget {
  final List<List<double>> spectrum;
  final int channels;

  const _IrSpectrumGraph({required this.spectrum, required this.channels});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(l.convSpectrumTitle, style: captionOf(p, color: p.textDim)),
            const Spacer(),
            Text('32 频带 · 0..1 归一化能量',
                style: monoOf(p, size: 10, color: p.textDim)),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        Container(
          height: 64,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
          decoration: BoxDecoration(
            color: p.panelRaised,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: p.hairline),
          ),
          child: CustomPaint(
            size: const Size(double.infinity, 56),
            painter: _IrSpectrumPainter(spectrum: spectrum, palette: p),
          ),
        ),
      ],
    );
  }
}

class _IrSpectrumPainter extends CustomPainter {
  final List<List<double>> spectrum;
  final AuraPalette palette;

  _IrSpectrumPainter({required this.spectrum, required this.palette});

  @override
  void paint(Canvas canvas, Size size) {
    if (spectrum.isEmpty) return;
    final chCount = spectrum.length;
    final bands = spectrum.first.length;
    if (bands == 0) return;

    final w = size.width;
    final h = size.height;
    final slotW = w / bands;
    final barW = (slotW * 0.75).clamp(1.0, 8.0);

    for (var b = 0; b < bands; b++) {
      var maxVal = 0.0;
      for (var c = 0; c < chCount; c++) {
        if (b < spectrum[c].length) {
          maxVal = math.max(maxVal, spectrum[c][b]);
        }
      }
      final barH = (maxVal.clamp(0.0, 1.0) * h).clamp(1.0, h);
      final x = b * slotW + (slotW - barW) / 2;
      final y = h - barH;

      final paint = Paint()
        ..color = palette.accent.withValues(alpha: 0.35 + maxVal * 0.55)
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(x, y, barW, barH),
          const Radius.circular(1),
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _IrSpectrumPainter oldDelegate) =>
      oldDelegate.spectrum != spectrum || oldDelegate.palette != palette;
}

/* ---- 3D 声场空间渲染 (动态尺寸与声场宽度联动) ---- */

class _Freeverb3DStage extends StatelessWidget {
  final double decay;
  final double damp;
  final double roomSize;
  final double stereoWidth;
  final bool active;

  const _Freeverb3DStage({
    required this.decay,
    required this.damp,
    this.roomSize = 1.2,
    this.stereoWidth = 1.0,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(l.fv3DTitle, style: captionOf(p, color: p.textDim)),
            const Spacer(),
            Text(
              '透视网格 · 阻尼渐变 · 尺寸 ${roomSize.toStringAsFixed(1)}x',
              style: monoOf(p, size: 10, color: p.textDim),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        Container(
          height: 100,
          decoration: BoxDecoration(
            color: p.panelRaised,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: p.hairline),
          ),
          child: CustomPaint(
            size: const Size(double.infinity, 100),
            painter: _Freeverb3DPainter(
              decay: decay,
              damp: damp,
              roomSize: roomSize,
              stereoWidth: stereoWidth,
              palette: p,
              active: active,
            ),
          ),
        ),
      ],
    );
  }
}

class _Freeverb3DPainter extends CustomPainter {
  final double decay;
  final double damp;
  final double roomSize;
  final double stereoWidth;
  final AuraPalette palette;
  final bool active;

  _Freeverb3DPainter({
    required this.decay,
    required this.damp,
    required this.roomSize,
    required this.stereoWidth,
    required this.palette,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    final baseAlpha = active ? 1.0 : 0.25;
    final gridColor = palette.vizGrid.withValues(alpha: 0.45 * baseAlpha);

    // 动态空间尺寸映射：0.5x ~ 2.5x 映射到透视原点与边界
    final sizeFactor = (roomSize / 1.5).clamp(0.4, 2.0);
    final vpX = w / 2;
    final vpY = (h * 0.28) / sizeFactor;

    // 地板与侧墙网格
    final pFloorLeft = Offset(w * 0.1, h * 0.95);
    final pFloorRight = Offset(w * 0.9, h * 0.95);
    final pBackLeft = Offset(vpX - (w * 0.25 * sizeFactor), vpY + 20);
    final pBackRight = Offset(vpX + (w * 0.25 * sizeFactor), vpY + 20);

    final linePaint = Paint()
      ..color = gridColor
      ..strokeWidth = 1.0;

    canvas.drawLine(pFloorLeft, pBackLeft, linePaint);
    canvas.drawLine(pFloorRight, pBackRight, linePaint);
    canvas.drawLine(pFloorLeft, pFloorRight, linePaint);
    canvas.drawLine(pBackLeft, pBackRight, linePaint);

    // 室内声波粒子反弹光晕
    if (active) {
      final glowPaint = Paint()
        ..color = palette.accent.withValues(alpha: (0.15 * decay).clamp(0.02, 0.4))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);

      canvas.drawCircle(Offset(vpX, vpY + 25), 18 * sizeFactor, glowPaint);

      // 双发声源展开度 (stereoWidth)
      final widthOffset = (w * 0.18 * stereoWidth).clamp(10.0, w * 0.4);
      final leftSrc = Offset(vpX - widthOffset, h * 0.75);
      final rightSrc = Offset(vpX + widthOffset, h * 0.75);

      final srcPaint = Paint()
        ..color = palette.accent.withValues(alpha: 0.75)
        ..style = PaintingStyle.fill;

      canvas.drawCircle(leftSrc, 3.5, srcPaint);
      canvas.drawCircle(rightSrc, 3.5, srcPaint);

      // 发声源向远处的反射光波
      final wavePaint = Paint()
        ..color = palette.accent.withValues(alpha: 0.12 * (1.0 - damp * 0.5))
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;

      canvas.drawLine(leftSrc, pBackLeft, wavePaint);
      canvas.drawLine(rightSrc, pBackRight, wavePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _Freeverb3DPainter oldDelegate) =>
      oldDelegate.decay != decay ||
      oldDelegate.damp != damp ||
      oldDelegate.roomSize != roomSize ||
      oldDelegate.stereoWidth != stereoWidth ||
      oldDelegate.palette != palette ||
      oldDelegate.active != active;
}
