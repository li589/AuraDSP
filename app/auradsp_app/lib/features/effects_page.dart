/*
 * effects_page.dart — 控制页：对齐 engine_api 参数模型 v1
 *
 * 守卫哲学：UI 不预拦截——被拒的参数照样可点，引擎返回 E_LATENCY_GUARD(-3)
 * 后由 EventBanner 明示原因（ADR-002 守卫在引擎侧，UI 绕不过，可当场验证）。
 *
 * 层级：每张卡 = 序号 + 效果名 + 启用开关；卡内一行一个参数，标签/读数固定列宽。
 */
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
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
        _SignalFlowBar(model: model), // M3：vendor 固定顺序的可视化（重排序后置 M3.5）
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _BassCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _ReverbCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _ConvolverCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _StereoCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _PostCard(model: model),
        ),
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

/* ---- 信号流条：vendor 固定顺序的单行可视化，启用节点亮色 ---- */

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
        // vendor process 顺序（limiter/post 合并为输出级）
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
              'reverb' => model.reverbPreset >= 0,
              _ => true, // 输出级常亮
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

/* ---- 01 Bass ---- */

class _BassCard extends StatelessWidget {
  final AppModel model;
  const _BassCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '01',
      title: l.bassBoost,
      trailing: AuraSwitch(
        value: model.bassOn,
        onChanged: (v) => model.setInt('bass.enable', v ? 1 : 0),
      ),
      child: ValueSlider(
        label: l.bassGain,
        value: model.bassGain,
        min: 0,
        max: 15,
        unit: 'dB',
        enabled: model.bassOn,
        format: (v) => v.toStringAsFixed(1),
        onChanged: (v) => model.setFloat('bass.gain', v),
        onChangedEnd: (v) => model.setFloat('bass.gain', v),
      ),
    );
  }
}

/* ---- 02 Reverb（T2，品质档限定；点击预设时自动切品质档） ---- */

class _ReverbCard extends StatelessWidget {
  final AppModel model;
  const _ReverbCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final blocked = model.reverbBlockedNow();
    final presets = <int, String>{
      -1: l.reverbOff,
      0: l.reverbPreset0, 1: l.reverbPreset1, 2: l.reverbPreset2,
      3: l.reverbPreset3, 4: l.reverbPreset4, 5: l.reverbPreset5,
      6: l.reverbPreset6, 7: l.reverbPreset7,
    };
    return SectionCard(
      index: '02',
      title: l.reverb,
      hint: blocked ? l.reverbAutoQualityHint : null,
      trailing: blocked
          ? // 可点击的守卫徽标：直接升档，不再让用户跑去设置页
          _GuardActionChip(
              label: l.reverbNeedsQuality,
              onTap: () => model.setLatencyMode(2),
            )
          : null,
      child: Wrap(
        spacing: AuraSpace.sm,
        runSpacing: AuraSpace.sm,
        children: [
          for (final e in presets.entries)
            AuraChip(
              e.value,
              selected: model.reverbPreset == e.key,
              onTap: () => model.setReverbPreset(
                  e.key, autoQualityMsg: l.reverbAutoQuality),
            ),
        ],
      ),
    );
  }
}

/// 守卫提示徽标（可点击）：点击即切品质档
class _GuardActionChip extends StatefulWidget {
  final String label;
  final VoidCallback onTap;
  const _GuardActionChip({required this.label, required this.onTap});

  @override
  State<_GuardActionChip> createState() => _GuardActionChipState();
}

class _GuardActionChipState extends State<_GuardActionChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AuraDur.fast,
          padding: const EdgeInsets.symmetric(
              horizontal: AuraSpace.sm, vertical: AuraSpace.xxs + 1),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(
                color: p.warning
                    .withValues(alpha: _hover ? 0.9 : 0.55)),
            color: _hover ? p.warning.withValues(alpha: 0.10) : null,
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.bolt_rounded, size: 12, color: p.warning),
            const SizedBox(width: AuraSpace.xxs),
            Text(widget.label,
                style: TextStyle(fontSize: 10.5, color: p.warning)),
          ]),
        ),
      ),
    );
  }
}

/* ---- 03 Convolver / IR（T2，品质档限定；门卫在引擎 load_ir_file） ---- */

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
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.convEnabled,
          onChanged: model.convReady
              ? (v) => model.setConvolverEnabled(
                      v, autoQualityMsg: l.convAutoQuality)
              : null,
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

/* ---- 04 Equalizer / Stereo ---- */

class _StereoCard extends StatelessWidget {
  final AppModel model;
  const _StereoCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '04',
      title: l.equalizer,
      trailing: AuraSwitch(
        value: model.eqOn,
        onChanged: (v) => model.setInt('eq.enable', v ? 1 : 0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.stereoWiden,
            value: model.stereoMix,
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
          _StereoAdvanced(model: model), // M5/P-002：分带细化，默认折叠
        ],
      ),
    );
  }
}

/// 声场分带细化（默认折叠）：5 个子带独立 mix，拖总滑块回到统一模式
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
    final m = widget.model;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 高级开关行
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
                    size: 16, color: p.textDim),
              ),
              const SizedBox(width: AuraSpace.xs + 2),
              Text('高级 · 分带宽度',
                  style: labelOf(p, color: p.textDim)),
              const Spacer(),
              ListenableBuilder(
                listenable: m,
                builder: (_, _) => Text(
                    '分带模式：${m.stereoBandUsed ? "开" : "关"}',
                    style: monoOf(p, size: 10.5,
                        color: p.textDim.withValues(alpha: 0.7))),
              ),
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
            child: Column(children: [
              for (var i = 0; i < 5; i++)
                _BandSlider(model: m, index: i, label: _bandLabels[i]),
              const SizedBox(height: AuraSpace.xs),
              Text('0% = 中置全保留，100% = 该带中置全剥离；拖动总宽度滑块将回到统一模式',
                  style: captionOf(p)),
            ]),
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
  const _BandSlider({required this.model, required this.index, required this.label});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final m = model;
    return Row(children: [
      SizedBox(
        width: 60,
        child: Text(label,
            style: labelOf(p, color: p.textDim)),
      ),
      Expanded(
        child: ListenableBuilder(
          listenable: m,
          builder: (_, _) {
            final v = m.stereoBands[index];
            return Slider(
              value: v.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              onChanged: (v) => m.setFloat('stereo.band${index + 1}', v),
            );
          },
        ),
      ),
      SizedBox(
        width: 44,
        child: ListenableBuilder(
          listenable: m,
          builder: (_, _) => Text(
              '${(m.stereoBands[index] * 100).toStringAsFixed(0)}%',
              textAlign: TextAlign.right,
              style: monoOf(p, size: 12, color: p.text)),
        ),
      ),
    ]);
  }
}

/* ---- 04 Post Gain / Limiter ---- */

class _PostCard extends StatelessWidget {
  final AppModel model;
  const _PostCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '05',
      title: l.postGain,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.postGain,
            value: model.postGain,
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
  final double value, min, max;
  final String unit;
  final String Function(double) format;

  /// 拖动中提交（节流，默认 40ms）；为 null 则只在松手时提交
  final ValueChanged<double>? onChanged;

  /// 松手时最终提交（必发，保证与引擎最终一致）
  final ValueChanged<double> onChangedEnd;
  final bool enabled;

  const ValueSlider({
    super.key,
    required this.label,
    required this.value,
    required this.min,
    required this.max,
    required this.unit,
    required this.format,
    required this.onChangedEnd,
    this.onChanged,
    this.enabled = true,
  });

  @override
  State<ValueSlider> createState() => _ValueSliderState();
}

class _ValueSliderState extends State<ValueSlider> {
  static const _commitGapMs = 40; // ≈25Hz，既实时又不轰参数
  late double _drag = widget.value;
  int _lastCommitMs = 0;
  bool _dragging = false;

  @override
  void didUpdateWidget(ValueSlider old) {
    super.didUpdateWidget(old);
    if (!widget.enabled) _drag = widget.value;
  }

  void _commit(double v) {
    final cb = widget.onChanged;
    if (cb == null) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - _lastCommitMs < _commitGapMs) return;
    _lastCommitMs = now;
    cb(v);
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final c = !widget.enabled
        ? p.textDim
        : (_dragging ? p.accent : p.text);
    return Row(children: [
      SizedBox(
        width: 96,
        child: Text(widget.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: labelOf(p, color: widget.enabled ? p.text : p.textDim)),
      ),
      Expanded(
        child: Slider(
          value: _drag.clamp(widget.min, widget.max),
          min: widget.min,
          max: widget.max,
          onChangeStart:
              widget.enabled ? (_) => setState(() => _dragging = true) : null,
          onChanged: widget.enabled
              ? (v) {
                  setState(() => _drag = v); // 本地即时视觉
                  _commit(v); // 节流提交引擎
                }
              : null,
          onChangeEnd: (v) {
            setState(() => _dragging = false);
            _lastCommitMs = 0;
            widget.onChangedEnd(v);
          },
        ),
      ),
      const SizedBox(width: AuraSpace.md),
      SizedBox(
        width: 72,
        child: AnimatedDefaultTextStyle(
          duration: AuraDur.fast,
          style: monoOf(p, size: 13, color: c),
          child: Text(
            '${widget.format(_drag)}${widget.unit}',
            textAlign: TextAlign.right,
            maxLines: 1,
          ),
        ),
      ),
    ]);
  }
}
