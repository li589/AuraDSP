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
          // stage id 必须与 AppModel.isStageEnabled 的键一致：
          // 之前这里写 'out' 而 isStageEnabled 认 'output'，落到 on() 的 `_ => true`，
          // 导致 OUT 节点无论限幅开关如何都恒亮。
          ('output', 'OUT'),
        ];
        // 语义刻意与 isStageEnabled 有别：此处是"信号流上是否有信号在跑"，
        // 卷积需 convReady（IR 真加载了才算），混响需涵盖 Freeverb 路径。
        // 两者统一属重构（批次 D），此处只修 id 不匹配。
        bool on(String id) => switch (id) {
              'tube' => model.tubeOn,
              'bass' => model.bassOn,
              'eq' => model.eqOn,
              'convolver' => model.convEnabled && model.convReady,
              'liveprog' => model.lpEnabled,
              'crossfeed' => model.xfeedOn,
              'stereo' => model.stereoMix > 0,
              'reverb' => model.isSpatialReverbOn,
              'output' => model.limiterOn,
              _ => false,
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
      collapsed: !model.bassOn,
      latencyMs: model.componentLatency('bass').ms,
              latencyMeasured: model.componentLatency('bass').measured,
              latencyProbing: model.isProbingLatency('bass'),
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
          // 低音增强模式 — 标签与选项同行，选项右对齐
          Row(
            children: [
              Text(l.bassMode, style: captionOf(p)),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
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
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _BassAdvanced(model: model),
        ],
      ),
    );
  }
}

class _BassAdvanced extends StatelessWidget {
  final AppModel model;
  const _BassAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    return AdvancedSection(
      summary: '${m.bassCutoff.toStringAsFixed(0)} Hz · ${(m.bassHarmonics * 100).toStringAsFixed(0)}%',
      builder: (context) => Column(
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
    );
  }
}

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
      collapsed: !isEnabled,
      latencyMs: m.componentLatency('reverb').ms,
              latencyMeasured: m.componentLatency('reverb').measured,
              latencyProbing: m.isProbingLatency('reverb'),
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
                selected: isEnabled && m.reverbPreset == -2 && m.fvOn,
                onTap: () {
                  if (m.reverbPreset != -2) {
                    m.selectReverbPreset(-2);
                  }
                  // 自动展开高级调节面板
                  if (!_open) setState(() => _open = true);
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
      collapsed: !model.convEnabled,
      latencyMs: model.componentLatency('convolver').ms,
              latencyMeasured: model.componentLatency('convolver').measured,
              latencyProbing: model.isProbingLatency('convolver'),
      onRefreshLatency: () => model.refreshComponentLatency('convolver'),
      latencyTick: model.getComponentLatencyTick('convolver'),
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.convEnabled,
          onChanged: (v) => model.setConvolverEnabled(v),
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
          // convFrames 是**重采样到引擎 fs 之后**的帧数（见 load_ir_file 的离线重采样），
          // 所以换算基准是设备采样率，不是 IR 文件原始的 convSrcRate。
          final durMs = model.convFrames * 1000.0 / model.deviceRate;
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
      collapsed: !model.ddcOn,
      latencyMs: model.componentLatency('ddc').ms,
              latencyMeasured: model.componentLatency('ddc').measured,
              latencyProbing: model.isProbingLatency('ddc'),
      onRefreshLatency: () => model.refreshComponentLatency('ddc'),
      latencyTick: model.getComponentLatencyTick('ddc'),
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.ddcOn,
          onChanged: (v) => model.setDdcEnabled(v),
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
      collapsed: !model.eqOn,
      latencyMs: model.componentLatency('eq').ms,
              latencyMeasured: model.componentLatency('eq').measured,
              latencyProbing: model.isProbingLatency('eq'),
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
      collapsed: !model.stereoOn,
      latencyMs: model.componentLatency('stereo').ms,
              latencyMeasured: model.componentLatency('stereo').measured,
              latencyProbing: model.isProbingLatency('stereo'),
      onRefreshLatency: () => model.refreshComponentLatency('stereo'),
      latencyTick: model.getComponentLatencyTick('stereo'),
      trailing: AuraSwitch(
        value: model.stereoOn,
        onChanged: (v) => model.setStereoEnabled(v),
      ),
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
            enabled: model.stereoOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) =>
                model.setFloat('stereo.mix', v * model.stereoWidenMax),
            onChangedEnd: (v) =>
                model.setFloat('stereo.mix', v * model.stereoWidenMax),
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
class _StereoAdvanced extends StatelessWidget {
  final AppModel model;
  const _StereoAdvanced({required this.model});

  static const _bandLabels = ['低频段', '中低频', '中频', '中高频', '高频'];

  @override
  Widget build(BuildContext context) {
    final m = model;
    return AdvancedSection(
      summary: '${(m.stereoMix * 100).toStringAsFixed(0)}%',
      builder: (context) {
        final p = paletteOf(context);
        return Column(
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
        );
      },
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
      collapsed: !model.tubeOn,
      latencyMs: model.componentLatency('tube').ms,
              latencyMeasured: model.componentLatency('tube').measured,
              latencyProbing: model.isProbingLatency('tube'),
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
          // 电子管音色风格 — 标签与选项同行，选项右对齐
          Row(
            children: [
              Text(l.tubeStyle, style: captionOf(p)),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
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
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _TubeAdvanced(model: model),
        ],
      ),
    );
  }
}

class _TubeAdvanced extends StatelessWidget {
  final AppModel model;
  const _TubeAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    return AdvancedSection(
      summary: '${m.tubeOversampling}x · ${(m.tubeCompensation >= 0 ? '+' : '')}${m.tubeCompensation.toStringAsFixed(1)} dB',
      builder: (context) {
        final p = paletteOf(context);
        return Column(
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
        );
      },
    );
  }
}

class _PostCard extends StatelessWidget {
  final AppModel model;
  const _PostCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '08',
      title: l.postGain,
      latencyMs: model.componentLatency('post').ms,
              latencyMeasured: model.componentLatency('post').measured,
              latencyProbing: model.isProbingLatency('post'),
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

/* ---- 3D 声场空间渲染 (高级可视化：透视网格 + 声波扩散 + 衰减光晕) ---- */

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
              'Room ${roomSize.toStringAsFixed(1)}x · Decay ${(decay * 100).toStringAsFixed(0)}% · Width ${stereoWidth.toStringAsFixed(1)}',
              style: monoOf(p, size: 10, color: p.textDim),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        ClipRRect(
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          child: Container(
            height: 140,
            decoration: BoxDecoration(
              color: p.panelRaised,
              border: Border.all(color: p.hairline),
            ),
            child: CustomPaint(
              size: const Size(double.infinity, 140),
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
    final baseAlpha = active ? 1.0 : 0.2;
    final sizeFactor = (roomSize / 1.5).clamp(0.35, 2.0);

    // 消失点（透视中心）
    final vpX = w / 2;
    final vpY = h * 0.15 / sizeFactor;

    // 地面四角
    final flL = Offset(w * 0.04, h * 0.98);
    final flR = Offset(w * 0.96, h * 0.98);
    final bkL = Offset(vpX - w * 0.28 * sizeFactor, vpY + 18);
    final bkR = Offset(vpX + w * 0.28 * sizeFactor, vpY + 18);

    // ── 1. 透视地板网格 ──
    final gridPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.2 * baseAlpha)
      ..strokeWidth = 0.6;

    // 纵深线（左→右均匀 8 条）
    for (var i = 0; i <= 8; i++) {
      final t = i / 8.0;
      final botX = flL.dx + (flR.dx - flL.dx) * t;
      final topX = bkL.dx + (bkR.dx - bkL.dx) * t;
      canvas.drawLine(
        Offset(botX, flL.dy),
        Offset(topX, bkL.dy),
        gridPaint,
      );
    }
    // 横向线（6 条，用透视缩放间距）
    for (var i = 0; i <= 6; i++) {
      final t = math.pow(i / 6.0, 1.6); // 近疏远密
      final y = flL.dy + (bkL.dy - flL.dy) * t;
      final lx = flL.dx + (bkL.dx - flL.dx) * t;
      final rx = flR.dx + (bkR.dx - flR.dx) * t;
      canvas.drawLine(Offset(lx, y), Offset(rx, y), gridPaint);
    }

    // 墙壁边框（地面 + 后墙 + 侧墙轮廓）
    final wallPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.35 * baseAlpha)
      ..strokeWidth = 1.0;
    canvas.drawLine(flL, bkL, wallPaint);
    canvas.drawLine(flR, bkR, wallPaint);
    canvas.drawLine(flL, flR, wallPaint);
    canvas.drawLine(bkL, bkR, wallPaint);

    // 天花板轮廓（镜像后墙上方）
    final ceilY = vpY - 4;
    final ceilL = Offset(bkL.dx - 2, ceilY);
    final ceilR = Offset(bkR.dx + 2, ceilY);
    final ceilPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.18 * baseAlpha)
      ..strokeWidth = 0.8;
    canvas.drawLine(ceilL, ceilR, ceilPaint);
    canvas.drawLine(bkL, ceilL, ceilPaint);
    canvas.drawLine(bkR, ceilR, ceilPaint);

    if (!active) return;

    // ── 2. 声源位置 ──
    final widthOff = (w * 0.2 * stereoWidth).clamp(12.0, w * 0.42);
    final srcY = h * 0.78;
    final srcL = Offset(vpX - widthOff, srcY);
    final srcR = Offset(vpX + widthOff, srcY);

    // 声源光晕（外圈漫反射）
    final srcGlow = Paint()
      ..color = palette.accent.withValues(alpha: 0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawCircle(srcL, 8, srcGlow);
    canvas.drawCircle(srcR, 8, srcGlow);

    // 声源实心点
    final srcDot = Paint()
      ..color = palette.accent.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(srcL, 3.5, srcDot);
    canvas.drawCircle(srcR, 3.5, srcDot);

    // ── 3. 早期反射路径（声源 → 侧墙反弹点 → 远处交叉） ──
    final reflAlpha = (0.18 * (1.0 - damp * 0.6)).clamp(0.04, 0.25) * baseAlpha;
    final reflPaint = Paint()
      ..color = palette.accent.withValues(alpha: reflAlpha)
      ..strokeWidth = 0.9
      ..style = PaintingStyle.stroke;

    // 左声源 → 左墙反弹 → 远处右后
    final wallHitL = Offset(flL.dx + (bkL.dx - flL.dx) * 0.45, flL.dy + (bkL.dy - flL.dy) * 0.45);
    final wallHitR = Offset(flR.dx + (bkR.dx - flR.dx) * 0.45, flR.dy + (bkR.dy - flR.dy) * 0.45);
    canvas.drawLine(srcL, wallHitL, reflPaint);
    canvas.drawLine(wallHitL, bkR, reflPaint..strokeWidth = 0.5);
    canvas.drawLine(srcR, wallHitR, reflPaint..strokeWidth = 0.9);
    canvas.drawLine(wallHitR, bkL, reflPaint..strokeWidth = 0.5);

    // 直达路径（到后墙中心）
    final directPaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.12 * baseAlpha)
      ..strokeWidth = 0.7
      ..style = PaintingStyle.stroke;
    final backCenter = Offset(vpX, (bkL.dy + bkR.dy) / 2);
    canvas.drawLine(srcL, backCenter, directPaint);
    canvas.drawLine(srcR, backCenter, directPaint);

    // ── 4. 衰减扩散环（从声源向外扩展的弧形声波） ──
    final ringCount = (3 + decay * 4).toInt().clamp(2, 7);
    for (var i = 1; i <= ringCount; i++) {
      final t = i / (ringCount + 1);
      final ringAlpha = (0.15 * (1.0 - t) * decay * (1.0 - damp * 0.4)).clamp(0.02, 0.2);
      final ringPaint = Paint()
        ..color = palette.accent.withValues(alpha: ringAlpha * baseAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (1.2 - t * 0.6).clamp(0.3, 1.2);

      final radius = 14.0 + t * 50 * sizeFactor;

      // 左声源波纹弧（上半圆）
      canvas.drawArc(
        Rect.fromCircle(center: srcL, radius: radius),
        -math.pi * 0.85, math.pi * 0.7,
        false, ringPaint,
      );
      // 右声源波纹弧
      canvas.drawArc(
        Rect.fromCircle(center: srcR, radius: radius),
        -math.pi * 0.15, math.pi * 0.7,
        false, ringPaint,
      );
    }

    // ── 5. 后墙漫反射光晕 ──
    final backGlow = Paint()
      ..color = palette.accent.withValues(alpha: (0.08 * decay * (1.0 - damp * 0.5)).clamp(0.01, 0.15))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 20 * sizeFactor);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(vpX, vpY + 14), width: (bkR.dx - bkL.dx) * 0.8, height: 24 * sizeFactor),
      backGlow,
    );

    // ── 6. 聆听位置指示（小三角底部中央） ──
    final listenerY = h * 0.92;
    final listenerPaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;
    final triPath = Path()
      ..moveTo(vpX, listenerY - 5)
      ..lineTo(vpX - 4, listenerY + 2)
      ..lineTo(vpX + 4, listenerY + 2)
      ..close();
    canvas.drawPath(triPath, listenerPaint);

    // 聆听位置光晕
    final listGlow = Paint()
      ..color = palette.accent.withValues(alpha: 0.1)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(Offset(vpX, listenerY - 2), 8, listGlow);

    // ── 7. 阻尼渐变蒙层（从上往下，damp 越高顶部越暗） ──
    final dampGrad = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.center,
        colors: [
          palette.bg.withValues(alpha: (damp * 0.4).clamp(0.0, 0.35)),
          palette.bg.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h * 0.6), dampGrad);
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
