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
import '../core/ui_helpers.dart';
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

class _SignalFlowBar extends StatefulWidget {
  final AppModel model;
  const _SignalFlowBar({required this.model});

  @override
  State<_SignalFlowBar> createState() => _SignalFlowBarState();
}

class _SignalFlowBarState extends State<_SignalFlowBar> {
  final _scroll = ScrollController();

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final model = widget.model;
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
                // 横向滚动 + 细滚动条（窄屏指示器；桌面端仅滚动时显现）
                child: Scrollbar(
                  controller: _scroll,
                  thumbVisibility: false,
                  child: SingleChildScrollView(
                    controller: _scroll,
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
            infoMessage: '增强低音量感与冲击力。越高低频下潜越震撼，建议适度提升防轰头。',
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
                  AuraChoiceChip(
                    label: l.bassModeDynamic,
                    selected: model.bassMode == 0,
                    onTap: () => model.setBassMode(0),
                  ),
                  AuraChoiceChip(
                    label: l.bassModeShelf,
                    selected: model.bassMode == 1,
                    onTap: () => model.setBassMode(1),
                  ),
                  AuraChoiceChip(
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
                infoMessage: '低音增强作用的最高频率。低于该频率的声音将被加厚，一般建议 60~120Hz。',
                value: m.bassCutoff,
                defaultValue: ParamDefaults.bassCutoff,
                min: 30,
                max: 300,
                unit: 'Hz',
                enabled: m.bassOn,
                format: (v) => v.toStringAsFixed(0),
                onChanged: m.setBassCutoff,
                onChangedEnd: m.setBassCutoff,
                onResetToDefault: () => m.setBassCutoff(ParamDefaults.bassCutoff),
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
                onResetToDefault: () => m.setBassHarmonics(ParamDefaults.bassHarmonics),
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
                onResetToDefault: () =>
                    m.setBassHarmonicBlend(ParamDefaults.bassHarmonicBlend),
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
                onResetToDefault: () => m.setBassSubFloor(ParamDefaults.bassSubFloor),
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
                  // 自动展开高级调节面板
                  if (!_open) setState(() => _open = true);
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

          // 4. 高级声学物理精调（默认折叠）
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
              ],
            ),
          ),
        ),
      ],
    );
  }
}

/* ---- 03 脉冲响应卷积 (Convolver) ---- */

/// 文件资源槽：带边框、标题行与状态位的按钮组。
///
/// 卷积 / VDC 两张卡片此前都是裸 `Wrap` 丢几个 chip，与下方内容既无分组也无
/// 边界，视觉上像「随便扔在那」。这里给它们一个统一的容器，读起来是
/// 「该效果依赖哪个外部文件」这一明确区块。
class _ResourceSlot extends StatelessWidget {
  const _ResourceSlot({
    required this.icon,
    required this.title,
    required this.actions,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AuraSpace.sm),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.hairline),
        borderRadius: BorderRadius.circular(AuraRadius.md),
      ),
      child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: p.textDim),
            const SizedBox(width: 6),
            Text(title, style: captionOf(p)),
            const Spacer(),
            if (detail != null)
              Text(
                detail!,
                style: captionOf(p).copyWith(color: p.accent),
              ),
            // 按钮与标题同行：文字左对齐、按钮右对齐。
            const SizedBox(width: AuraSpace.sm),
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ],
        ),
    );
  }
}

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
      // 常规语义：关闭即收起。用户先前明确要求「无文件时保持开关开启、
// 效果内部直通(旁路)，待合格文件加载成功后自动生效」，
// 因此可达性由 state 层的 auto-bypass 解决，而不是靠改这里的折叠判据。
      // D1 曾改成 convEnabled && convReady，导致「打开开关反而收起」的反向手感。
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
                _ResourceSlot(
                  icon: Icons.folder_open_outlined,
                  title: l.convIrTitle,
                  actions: [
                    AuraChip(l.convOpenIr, icon: Icons.folder_open_outlined,
                        onTap: () => _pickIr(context)),
                  ],
                ),
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
              _ResourceSlot(
                icon: Icons.graphic_eq_outlined,
                title: l.convIrTitle,
                detail: '${model.convChannels}ch · $dur',
                actions: [
                  AuraChip(l.convOpenIr, icon: Icons.folder_open_outlined,
                      onTap: () => _pickIr(context)),
                  AuraChip(l.convClear, icon: Icons.delete_outline, danger: true,
                      onTap: () => model.clearConvolver()),
                ],
              ),
              const SizedBox(height: AuraSpace.md),
              if (model.convSpectrum.isNotEmpty) ...[
                _IrWaveformGraph(
                  spectrum: model.convSpectrum,
                  channels: model.convChannels,
                ),
                const SizedBox(height: AuraSpace.md),
              ],
              ValueSlider(
                label: l.convMix,
                infoMessage: '卷积混响混合比。0% 为原始干声，100% 完全沉浸在采样的空间声学混响中。',
                value: model.convMix,
                defaultValue: ParamDefaults.convMix,
                min: 0,
                max: 1,
                unit: '%',
                format: (v) => (v * 100).toStringAsFixed(0),
                onChanged: (v) => model.setFloat('convolver.mix', v),
                onChangedEnd: (v) => model.setFloat('convolver.mix', v),
              ),
              const SizedBox(height: AuraSpace.md),
              Text(
                l.convFramesLine(
                    model.convFrames,
                    dur,
                    model.convChannels,
                    (20 * math.log(model.convPeak <= 1e-6 ? 1e-6 : model.convPeak) / math.ln10).toStringAsFixed(1),
                    model.convSrcRate),
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
    const type = XTypeGroup(label: 'Audio IR (*.irs, *.wav, *.flac)',
        extensions: ['irs', 'wav', 'flac']);
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
      collapsed: !model.ddcOn, // 同上：常规语义 + state 层 auto-bypass
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
            _ResourceSlot(
              icon: Icons.filter_alt_outlined,
              title: l.ddcFilterTitle,
              detail: model.ddcReady ? l.ddcLoaded : null,
              actions: [
                AuraChip(l.ddcOpen, icon: Icons.folder_open_outlined,
                    onTap: () => _pickVdc(context)),
                if (model.ddcReady)
                  AuraChip(l.ddcLoaded, icon: Icons.check_circle_outline,
                      onTap: null),
              ],
            ),
            const SizedBox(height: AuraSpace.sm),
            // D3：parseVdcMetadata 已算出文件名与采样率/长度，这里真正展示出来，
            // 否则用户只能看到一句「已加载」，无从判断加载的是哪个文件。
            if (model.ddcFileName != null) ...[
              Text('${l.ddcLoaded}：${model.ddcFileName}',
                  style: captionOf(p)),
              if (model.ddcDetails != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(model.ddcDetails!, style: captionOf(p)),
                ),
            ] else
              Text(l.ddcNoFile, style: captionOf(p)),
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
            infoMessage: '拉伸左右耳声像边界。适度拉伸让耳机如大音箱脱箱，拉太大可能削弱中央人声聚焦。',
            value: model.stereoMix,
            defaultValue: ParamDefaults.stereoMix,
            onResetToDefault: model.resetStereoWiden,
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.stereoOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => model.setStereoMix(v),
            onChangedEnd: (v) => model.setStereoMix(v),
          ),
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
                label: [l10nOf(context).stBand0, l10nOf(context).stBand1, l10nOf(context).stBand2, l10nOf(context).stBand3, l10nOf(context).stBand4][i],
              ),
            const SizedBox(height: AuraSpace.xs),
            Text(l10nOf(context).stBandHint,
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
    final m = model;
    return ListenableBuilder(
      listenable: m,
      builder: (_, _) {
        final v = m.stereoBands[index];
        return ValueSlider(
          label: label,
          value: v,
          defaultValue: ParamDefaults.stereoBand,
          min: 0,
          max: 1,
          unit: '%',
          enabled: m.stereoOn,
          format: (val) => (val * 100).toStringAsFixed(0),
          onChanged: (val) => m.setStereoBand(index, val),
          onChangedEnd: (val) => m.setStereoBand(index, val),
          onResetToDefault: () => m.resetStereoBand(index),
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
            infoMessage: '模拟经典电子管偶次谐波失真。带来醇厚耐听的模拟胶片暖色调，消除数码干冷感。',
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
                  AuraChoiceChip(
                    label: l.tubeStyleTriode,
                    selected: model.tubeStyle == 0,
                    onTap: () => model.setTubeStyle(0),
                  ),
                  AuraChoiceChip(
                    label: l.tubeStylePentode,
                    selected: model.tubeStyle == 1,
                    onTap: () => model.setTubeStyle(1),
                  ),
                  AuraChoiceChip(
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
                  AuraChoiceChip(
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
            infoMessage: '全局总输出音量补偿。多重 DSP 处理后若音量偏小可适当微调。',
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

  /// 标签旁问号徽标的说明文案（null 不渲染；用于替代滑块下方常驻 hint 行）
  final String? infoMessage;

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
    this.infoMessage,
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
      padding: const EdgeInsets.symmetric(vertical: AuraSpace.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 140,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelOf(p,
                            color: widget.enabled ? p.text : p.textDim),
                      ),
                    ),
                    if (widget.infoMessage != null) ...[
                      const SizedBox(width: AuraSpace.xxs),
                      InfoBadge(message: widget.infoMessage!),
                    ],
                  ],
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
                const SizedBox(width: AuraSpace.xs),
                Tooltip(
                  message: l10nOf(context).sliderResetTip,
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
                Text(l.presetFactoryTitle,
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
                          content: Text(l.presetLoadedFactory(item.name)),
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
              Text(l.presetUserTitle,
                  style: monoOf(p, size: 11, color: p.accent2)),
            ],
          ),
          const SizedBox(height: AuraSpace.xs),
          if (userPresets.isEmpty)
            Text(l.presetUserEmpty,
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
                              content: Text(l.presetLoadedUser(item.name)),
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
                    hintText: l.presetSaveHint,
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

/* ---- 脉冲响应波形与频响包络 (EasyEffects 风格真实双声道波形图) ---- */

class _IrWaveformGraph extends StatefulWidget {
  final List<List<double>> spectrum;
  final int channels;

  const _IrWaveformGraph({
    required this.spectrum,
    required this.channels,
  });

  @override
  State<_IrWaveformGraph> createState() => _IrWaveformGraphState();
}

class _IrWaveformGraphState extends State<_IrWaveformGraph> {
  bool _isLogScale = true;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isMono = widget.channels <= 1;

    return Container(
      padding: const EdgeInsets.all(AuraSpace.sm),
      decoration: BoxDecoration(
        color: p.panelRaised.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AuraRadius.md),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.waves_rounded, size: 14, color: p.accent),
              const SizedBox(width: 6),
              Text('脉冲响应包络 (EasyEffects 风格)',
                  style: captionOf(p).copyWith(fontWeight: FontWeight.w600, color: p.text)),
              const SizedBox(width: AuraSpace.sm),
              // 声道指示点
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 8, height: 8, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF00E5FF))),
                  const SizedBox(width: 4),
                  Text('L', style: monoOf(p, size: 10, color: p.textDim)),
                  const SizedBox(width: 8),
                  Container(width: 8, height: 8, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFF43F5E))),
                  const SizedBox(width: 4),
                  Text(isMono ? 'R (镜像)' : 'R', style: monoOf(p, size: 10, color: p.textDim)),
                ],
              ),
              const Spacer(),
              // 模式切换 Chip：Linear / Log dB
              Container(
                decoration: BoxDecoration(
                  color: p.panel,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                padding: const EdgeInsets.all(2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _scaleButton(
                      label: 'Linear',
                      selected: !_isLogScale,
                      onTap: () => setState(() => _isLogScale = false),
                      p: p,
                    ),
                    _scaleButton(
                      label: 'Log dB',
                      selected: _isLogScale,
                      onTap: () => setState(() => _isLogScale = true),
                      p: p,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            child: Container(
              height: 110,
              width: double.infinity,
              color: Colors.black.withValues(alpha: 0.3),
              child: CustomPaint(
                painter: _IrWaveformPainter(
                  spectrum: widget.spectrum,
                  channels: widget.channels,
                  isLogScale: _isLogScale,
                  palette: p,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scaleButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required AuraPalette p,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AuraRadius.xs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? p.accent.withValues(alpha: 0.25) : Colors.transparent,
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          border: selected ? Border.all(color: p.accent.withValues(alpha: 0.5), width: 1) : null,
        ),
        child: Text(
          label,
          style: monoOf(p, size: 10, color: selected ? p.accent : p.textDim),
        ),
      ),
    );
  }
}

class _IrWaveformPainter extends CustomPainter {
  final List<List<double>> spectrum;
  final int channels;
  final bool isLogScale;
  final AuraPalette palette;

  _IrWaveformPainter({
    required this.spectrum,
    required this.channels,
    required this.isLogScale,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0 || spectrum.isEmpty) return;

    final gridPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: palette.textDim.withValues(alpha: 0.6),
      fontSize: 9,
      fontFamily: 'monospace',
    );

    // 绘制横向刻度线 (Grid)
    final lines = isLogScale ? [0.0, -20.0, -40.0, -60.0] : [1.0, 0.75, 0.5, 0.25, 0.0];
    for (final val in lines) {
      final yFrac = isLogScale ? (1.0 - (val + 60.0) / 60.0) : (1.0 - val);
      final y = (yFrac * (h - 16) + 6).clamp(6.0, h - 10);
      canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);

      final label = isLogScale ? '${val.toInt()}dB' : '${(val * 100).toInt()}%';
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(w - tp.width - 4, y - tp.height - 1));
    }

    // 频段标签：20Hz, 100Hz, 500Hz, 2kHz, 10kHz, 20kHz
    final freqLabels = ['20Hz', '100Hz', '500Hz', '2kHz', '10kHz', '20kHz'];
    for (var i = 0; i < freqLabels.length; i++) {
      final x = (i / (freqLabels.length - 1)) * (w - 40) + 10;
      final tp = TextPainter(
        text: TextSpan(text: freqLabels[i], style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, h - tp.height - 2));
    }

    // 提取 L 和 R 数据
    final lData = spectrum[0];
    final rData = spectrum.length > 1 ? spectrum[1] : spectrum[0]; // 单声道自动镜像为双声道

    // 绘制左右声道平滑曲线与渐变
    _drawChannelPath(canvas, size, rData, const Color(0xFFF43F5E), isRight: true);
    _drawChannelPath(canvas, size, lData, const Color(0xFF00E5FF), isRight: false);
  }

  void _drawChannelPath(
    Canvas canvas,
    Size size,
    List<double> rawData,
    Color color, {
    required bool isRight,
  }) {
    if (rawData.isEmpty) return;
    final w = size.width;
    final h = size.height - 18; // 留出底端频标空间
    final n = rawData.length;

    // 坐标计算
    final points = <Offset>[];
    for (var i = 0; i < n; i++) {
      final x = (i / (n - 1)) * w;
      var rawVal = rawData[i].clamp(0.0, 1.0);
      double yFrac;
      if (isLogScale) {
        // -60dB ~ 0dB
        final db = (rawVal > 1e-3) ? (20.0 * math.log(rawVal) / math.ln10) : -60.0;
        final clampedDb = db.clamp(-60.0, 0.0);
        yFrac = (clampedDb + 60.0) / 60.0;
      } else {
        yFrac = rawVal;
      }
      final y = h - (yFrac * (h - 8)) - 4;
      points.add(Offset(x, y.clamp(2.0, h)));
    }

    if (points.isEmpty) return;

    // 构建平滑贝塞尔曲线
    final path = Path();
    path.moveTo(points[0].dx, points[0].dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final cx = (p0.dx + p1.dx) / 2;
      path.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
    }

    // 填充渐变 Path
    final fillPath = Path.from(path)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: isRight ? 0.20 : 0.25),
          color.withValues(alpha: 0.02),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    // 描边主线条（带发光感）
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.90)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _IrWaveformPainter oldDelegate) =>
      oldDelegate.spectrum != spectrum ||
      oldDelegate.channels != channels ||
      oldDelegate.isLogScale != isLogScale ||
      oldDelegate.palette != palette;
}

/* ---- 3D 声场空间渲染 (高级可视化：透视网格 + 声波扩散 + 衰减光晕) ---- */

/* ---- 3D 声学室空间渲染 (极简无框置顶视效：深度透视 + 对称声波 + 空间尺寸响应) ---- */

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
    return ClipRRect(
      borderRadius: BorderRadius.circular(AuraRadius.sm),
      child: Container(
        height: 140,
        decoration: BoxDecoration(
          color: p.panelRaised.withValues(alpha: 0.6),
          border: Border.all(color: p.hairline.withValues(alpha: 0.6)),
        ),
        child: Stack(
          children: [
            Positioned.fill(
              child: CustomPaint(
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
            // 右上角极简度量（微弱透明度，不喧宾夺主）
            Positioned(
              top: 6,
              right: 10,
              child: Text(
                'Room ${roomSize.toStringAsFixed(1)}x · Decay ${(decay * 100).toStringAsFixed(0)}% · Width ${stereoWidth.toStringAsFixed(1)}',
                style: monoOf(p, size: 9, color: p.textDim.withValues(alpha: 0.6)),
              ),
            ),
          ],
        ),
      ),
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
    // 空间尺寸增强系数：0.4 ~ 2.4
    final sizeFactor = (roomSize / 1.2).clamp(0.4, 2.4);

    // 消失点（透视中心）：roomSize 越大，透视深远感越强
    final vpX = w / 2;
    final vpY = (h * (0.22 - (sizeFactor - 1.0) * 0.06)).clamp(h * 0.08, h * 0.30);

    // 地面四角
    final flL = Offset(w * 0.03, h * 0.98);
    final flR = Offset(w * 0.97, h * 0.98);
    final backHalfW = (w * (0.32 / math.sqrt(sizeFactor))).clamp(w * 0.16, w * 0.42);
    final bkL = Offset(vpX - backHalfW, vpY + 16);
    final bkR = Offset(vpX + backHalfW, vpY + 16);

    // ── 1. 透视地板网格 ──
    final gridPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.22 * baseAlpha)
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
    // 横向线（6 条，近疏远密）
    for (var i = 0; i <= 6; i++) {
      final t = math.pow(i / 6.0, 1.6);
      final y = flL.dy + (bkL.dy - flL.dy) * t;
      final lx = flL.dx + (bkL.dx - flL.dx) * t;
      final rx = flR.dx + (bkR.dx - flR.dx) * t;
      canvas.drawLine(Offset(lx, y), Offset(rx, y), gridPaint);
    }

    // ── 2. 3D 空间立体线框盒子（地面 + 后墙 + 天花板） ──
    final wallPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.38 * baseAlpha)
      ..strokeWidth = 1.0;
    canvas.drawLine(flL, bkL, wallPaint);
    canvas.drawLine(flR, bkR, wallPaint);
    canvas.drawLine(flL, flR, wallPaint);
    canvas.drawLine(bkL, bkR, wallPaint);

    // 天花板高度与后墙轮廓
    final ceilH = (22.0 * math.sqrt(sizeFactor)).clamp(16.0, 38.0);
    final ceilL = Offset(bkL.dx, bkL.dy - ceilH);
    final ceilR = Offset(bkR.dx, bkR.dy - ceilH);
    final ceilPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.22 * baseAlpha)
      ..strokeWidth = 0.8;
    canvas.drawLine(ceilL, ceilR, ceilPaint);
    canvas.drawLine(bkL, ceilL, ceilPaint);
    canvas.drawLine(bkR, ceilR, ceilPaint);

    // 侧墙透视延伸线（增强立方体感）
    final sidePaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.12 * baseAlpha)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(flL.dx, flL.dy - h * 0.7), ceilL, sidePaint);
    canvas.drawLine(Offset(flR.dx, flR.dy - h * 0.7), ceilR, sidePaint);

    if (!active) return;

    // ── 3. 声源位置 ──
    final widthOff = (w * 0.22 * stereoWidth).clamp(16.0, w * 0.44);
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

    // ── 4. 早期反射路径（声源 → 侧墙反弹点 → 远处交叉） ──
    final reflAlpha = (0.18 * (1.0 - damp * 0.6)).clamp(0.04, 0.25) * baseAlpha;
    final reflPaint = Paint()
      ..color = palette.accent.withValues(alpha: reflAlpha)
      ..strokeWidth = 0.9
      ..style = PaintingStyle.stroke;

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

    // ── 5. 衰减扩散环（修复右音箱扩散朝向：左右关于中轴对称向房间内前方扩散） ──
    final ringCount = (3 + decay * 4).toInt().clamp(2, 7);
    for (var i = 1; i <= ringCount; i++) {
      final t = i / (ringCount + 1);
      final ringAlpha = (0.16 * (1.0 - t) * decay * (1.0 - damp * 0.4)).clamp(0.02, 0.22);
      final ringPaint = Paint()
        ..color = palette.accent.withValues(alpha: ringAlpha * baseAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (1.2 - t * 0.6).clamp(0.3, 1.2);

      final radius = 14.0 + t * 52 * sizeFactor;

      // 左声源波纹弧（向右前方扩散，中心约 -0.44π）
      canvas.drawArc(
        Rect.fromCircle(center: srcL, radius: radius),
        -math.pi * 0.70,
        math.pi * 0.52,
        false,
        ringPaint,
      );
      // 右声源波纹弧（向左前方扩散，中心约 -0.56π，绝对对称，杜绝向右下扩散错误）
      canvas.drawArc(
        Rect.fromCircle(center: srcR, radius: radius),
        -math.pi * 0.82,
        math.pi * 0.52,
        false,
        ringPaint,
      );
    }

    // ── 6. 后墙漫反射光晕 ──
    final backGlow = Paint()
      ..color = palette.accent.withValues(alpha: (0.08 * decay * (1.0 - damp * 0.5)).clamp(0.01, 0.15))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 20 * sizeFactor);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(vpX, vpY + 14), width: (bkR.dx - bkL.dx) * 0.85, height: 24 * sizeFactor),
      backGlow,
    );

    // ── 7. 聆听位置指示（小三角底部中央） ──
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

    final listGlow = Paint()
      ..color = palette.accent.withValues(alpha: 0.1)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(Offset(vpX, listenerY - 2), 8, listGlow);

    // ── 8. 阻尼渐变蒙层 ──
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
