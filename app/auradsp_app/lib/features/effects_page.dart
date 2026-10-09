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
import '../core/presets.dart';
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
          builder: (_, _) => _FreeverbCard(model: model),
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
          builder: (_, _) => _StereoCard(model: model),
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.bassGain,
            value: model.bassGain,
            defaultValue: ParamDefaults.bassGain,
            min: 0,
            max: 15,
            unit: 'dB',
            enabled: model.bassOn,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => model.setFloat('bass.gain', v),
            onChangedEnd: (v) => model.setFloat('bass.gain', v),
          ),
          const SizedBox(height: AuraSpace.md),
          _BassShelfAdvanced(model: model), // M5-b：低频搁架，默认折叠
        ],
      ),
    );
  }
}

/// 低频搁架（M5-b，默认折叠）：独立于 dbb 的 low-shelf，频点/增益可调
class _BassShelfAdvanced extends StatefulWidget {
  final AppModel model;
  const _BassShelfAdvanced({required this.model});

  @override
  State<_BassShelfAdvanced> createState() => _BassShelfAdvancedState();
}

class _BassShelfAdvancedState extends State<_BassShelfAdvanced> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
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
              Text('高级 · 低频搁架',
                  style: labelOf(p,
                      color: m.shelfOn ? p.accent : p.text)),
              const Spacer(),
              // 开关保留（功能必需），但不加状态文字
              AuraSwitch(
                value: m.shelfOn,
                onChanged: (v) => m.setInt('shelf.enable', v ? 1 : 0),
              ),
              const SizedBox(width: AuraSpace.sm),
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
            child: ListenableBuilder(
              listenable: m,
              builder: (_, _) => Column(children: [
                ValueSlider(
                  label: '频点',
                  value: m.shelfFreq,
                  defaultValue: ParamDefaults.shelfFreq,
                  min: 40,
                  max: 400,
                  unit: 'Hz',
                  enabled: m.shelfOn,
                  format: (v) => v.toStringAsFixed(0),
                  onChanged: (v) => m.setFloat('shelf.freq', v),
                  onChangedEnd: (v) => m.setFloat('shelf.freq', v),
                ),
                ValueSlider(
                  label: '增益',
                  value: m.shelfGain,
                  defaultValue: ParamDefaults.shelfGain,
                  min: -15,
                  max: 15,
                  unit: 'dB',
                  enabled: m.shelfOn,
                  format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                  onChanged: (v) => m.setFloat('shelf.gain', v),
                  onChangedEnd: (v) => m.setFloat('shelf.gain', v),
                ),
                const SizedBox(height: AuraSpace.xs),
                Text('独立 low-shelf 滤波器（位于链头，先于低音增强）；'
                    'f0 为半增益点；强正增益可能被输出限幅器收峰',
                    style: captionOf(p)),
              ]),
            ),
          ),
        ),
      ],
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

/* ---- 03 参数化混响（Freeverb，T2；独立于预设混响可并存） ---- */

class _FreeverbCard extends StatelessWidget {
  final AppModel model;
  const _FreeverbCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '03',
      title: l.fvTitle,
      hint: l.fvHint,
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.fvOn,
          onChanged: (v) => model.setFreeverbEnabled(
              v, autoQualityMsg: l.convAutoQuality),
        ),
      ),
      child: ListenableBuilder(
        listenable: model,
        builder: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _Freeverb3DStage(model: model),
            const SizedBox(height: AuraSpace.md),
            _FvSlider(
                model: model,
                label: l.fvDecayLabel,
                value: model.fvDecay,
                defaultValue: ParamDefaults.fvDecay,
                onChanged: (v) => model.setFloat('freeverb.decay', v)),
            _FvSlider(
                model: model,
                label: l.fvDampLabel,
                value: model.fvDamp,
                defaultValue: ParamDefaults.fvDamp,
                onChanged: (v) => model.setFloat('freeverb.damp', v)),
            _FvSlider(
                model: model,
                label: l.fvWetLabel,
                value: model.fvWet,
                defaultValue: ParamDefaults.fvWet,
                onChanged: (v) => model.setFloat('freeverb.wet', v)),
            _FvSlider(
                model: model,
                label: l.fvDryLabel,
                value: model.fvDry,
                defaultValue: ParamDefaults.fvDry,
                onChanged: (v) => model.setFloat('freeverb.dry', v)),
          ],
        ),
      ),
    );
  }
}

class _FvSlider extends StatelessWidget {
  final AppModel model;
  final String label;
  final double value;
  final double? defaultValue;
  final ValueChanged<double> onChanged;
  const _FvSlider({
    required this.model,
    required this.label,
    required this.value,
    required this.onChanged,
    this.defaultValue,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final enabled = model.fvOn;
    return MouseRegion(
      cursor: defaultValue != null ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onDoubleTap: (enabled && defaultValue != null)
            ? () => onChanged(defaultValue!)
            : null,
        child: Row(children: [
          SizedBox(
              width: 64,
              child: Text(label,
                  style: labelOf(p, color: enabled ? p.text : p.textDim))),
          Expanded(
            child: Slider(
              value: value.clamp(0.0, 1.0),
              min: 0,
              max: 1,
              onChanged: enabled ? onChanged : null,
            ),
          ),
          SizedBox(
            width: 44,
            child: Text('${(value * 100).toStringAsFixed(0)}%',
                textAlign: TextAlign.right,
                style: monoOf(p,
                    size: 12, color: enabled ? p.text : p.textDim)),
          ),
        ]),
      ),
    );
  }
}

/* ---- 04 Convolver / IR（T2，品质档限定；门卫在引擎 load_ir_file） ---- */

class _ConvolverCard extends StatelessWidget {
  final AppModel model;
  const _ConvolverCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      index: '04',
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

/* ---- 04 VDC 空间校正（耳机/扬声器校正系数，兼容蝰蛇 DDC） ---- */

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

/* ---- 05 Equalizer / Stereo ---- */

class _StereoCard extends StatelessWidget {
  final AppModel model;
  const _StereoCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '06',
      title: l.equalizer,
      trailing: AuraSwitch(
        value: model.eqOn,
        onChanged: (v) => model.setInt('eq.enable', v ? 1 : 0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // M5 第二批：EQ 频率轴曲线（multimodalEQ makima 插值，15 点）
          Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.sm,
            children: [
              for (final c in const [
                ('平直', '20:0;100:0;440:0;1000:0;4000:0;10000:0;20000:0'),
                ('低音', '20:6;100:5;440:1;1000:0;4000:0;10000:0;20000:0'),
                ('人声', '20:0;100:0;440:2;1000:4;4000:3;10000:0;20000:0'),
                ('微笑', '20:5;100:4;440:0;1000:-2;4000:3;10000:5;20000:5'),
              ])
                AuraChip(c.$1,
                    icon: Icons.equalizer_rounded,
                    onTap: () {
                      model.setInt('eq.enable', 1);
                      model.setStringParam('eq.curve', c.$2);
                    }),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
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
                    size: 20, color: p.accent),
              ),
              const SizedBox(width: AuraSpace.sm),
              // 生效态用标题颜色表达（去掉右侧状态文字）
              ListenableBuilder(
                listenable: m,
                builder: (_, _) => Text('高级 · 分带宽度',
                    style: labelOf(p,
                        color: m.stereoBandUsed ? p.accent : p.text)),
              ),
              const Spacer(),
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
    return ListenableBuilder(
      listenable: m,
      builder: (_, _) {
        final v = m.stereoBands[index];
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            // 双击整行归位中性值 50%
            onDoubleTap: () =>
                m.setFloat('stereo.band${index + 1}', ParamDefaults.stereoBand),
            child: Row(children: [
              SizedBox(
                width: 60,
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
          ),
        );
      },
    );
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
      index: '07',
      title: l.postGain,
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
  final double value, min, max;
  final String unit;
  final String Function(double) format;

  /// 双击归位的默认值（null = 不启用双击归位）
  final double? defaultValue;

  /// 双击归位时的扩展回调（如声场总滑块双击归位时联动重置子带）
  final VoidCallback? onResetToDefault;

  /// 被高级参数覆盖时置灰 + 尾注（如分带模式生效时主展宽滑块）
  final bool overridden;
  final String? overriddenNote;

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
    this.defaultValue,
    this.onResetToDefault,
    this.overridden = false,
    this.overriddenNote,
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

  void _resetToDefault() {
    final d = widget.defaultValue;
    if (d == null) return;
    setState(() => _drag = d);
    widget.onChangedEnd(d);
    widget.onResetToDefault?.call();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final c = !widget.enabled
        ? p.textDim
        : widget.overridden
            ? p.textDim.withValues(alpha: 0.55)
            : (_dragging ? p.accent : p.text);
    return MouseRegion(
      cursor: widget.defaultValue != null
          ? SystemMouseCursors.click
          : MouseCursor.defer,
      child: GestureDetector(
        // 双击归位默认值（整行 opaque，保证 label 与留白区均可响应）
        onDoubleTap: widget.enabled ? _resetToDefault : null,
        behavior: HitTestBehavior.opaque,
        child: _sliderRow(p, c),
      ),
    );
  }

  Widget _sliderRow(AuraPalette p, Color c) {
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
        width: widget.overridden && widget.overriddenNote != null ? 104 : 72,
        child: AnimatedDefaultTextStyle(
          duration: AuraDur.fast,
          style: monoOf(p, size: 13, color: c),
          child: Text(
            widget.overridden && widget.overriddenNote != null
                ? widget.overriddenNote!
                : '${widget.format(_drag)}${widget.unit}',
            textAlign: TextAlign.right,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ),
    ]);
  }
}


/* ---- 07 预设：引擎全量参数快照 ---- */

class _PresetCard extends StatefulWidget {
  final AppModel model;
  const _PresetCard({required this.model});

  @override
  State<_PresetCard> createState() => _PresetCardState();
}

class _PresetCardState extends State<_PresetCard> {
  final TextEditingController _name = TextEditingController(text: 'my-preset');
  List<String> _presets = const [];

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    if (mounted) setState(() => _presets = PresetLibrary.list());
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _toast(String msg) {
    if (!mounted) return;
    final p = paletteOf(context);
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(msg, style: TextStyle(color: p.text, fontSize: 13)),
      duration: const Duration(seconds: 2),
    ));
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final m = widget.model;
    return SectionCard(
      index: '08',
      title: l.presetTitle,
      hint: l.presetHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (_presets.isEmpty)
            Text(l.presetEmpty, style: captionOf(p))
          else ...[
            Text(l.presetLoadHint, style: captionOf(p)),
            const SizedBox(height: AuraSpace.sm),
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              children: [
                for (final f in _presets)
                  AuraChip(
                    f.replaceAll('.json', ''),
                    icon: Icons.tune_rounded,
                    onTap: () {
                      final params = PresetLibrary.load(f);
                      if (params == null) {
                        _toast(l.presetLoadFail);
                        return;
                      }
                      PresetLibrary.apply(m, params);
                      _toast(l.presetLoaded);
                    },
                  ),
              ],
            ),
            const SizedBox(height: AuraSpace.md),
          ],
          Row(children: [
            SizedBox(
              width: 180,
              child: TextField(
                controller: _name,
                style: monoOf(p, size: 12.5, color: p.text),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: 'my-preset',
                  hintStyle: monoOf(p, size: 12.5, color: p.textDim),
                  contentPadding: const EdgeInsets.symmetric(
                      horizontal: AuraSpace.md, vertical: AuraSpace.sm),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    borderSide: BorderSide(color: p.hairline),
                  ),
                ),
              ),
            ),
            const SizedBox(width: AuraSpace.sm),
            AuraChip(l.presetSave, icon: Icons.save_outlined,
                onTap: () {
                  final ok = PresetLibrary.save(
                      _name.text.trim(), PresetLibrary.snapshot(m));
                  _refresh();
                  _toast(ok ? l.presetSaved : l.presetSaveFail);
                }),
            const SizedBox(width: AuraSpace.sm),
            AuraChip(l.presetDelete, icon: Icons.delete_outline, danger: true,
                onTap: () {
                  final name = _name.text.trim();
                  final f = name.toLowerCase().endsWith('.json')
                      ? name
                      : '$name.json';
                  final ok = PresetLibrary.delete(f);
                  _refresh();
                  _toast(ok ? l.presetDeleted : l.presetDeleteFail);
                }),
          ]),
        ],
      ),
    );
  }
}

/* ---- 多声道 IR 频响包络图（复用 viz FFT 基础设施） ---- */

class _IrSpectrumGraph extends StatelessWidget {
  final List<List<double>> spectrum;
  final int channels;

  const _IrSpectrumGraph({
    required this.spectrum,
    required this.channels,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final chCount = spectrum.length;

    final channelColors = [
      p.vizSpectrum,                       // Ch1 / L: Cyan
      const Color(0xFFFF5EA8),             // Ch2 / R: Pink
      const Color(0xFFFFB86C),             // Ch3 / C: Orange
      const Color(0xFFBD93F9),             // Ch4 / LFE: Purple
      const Color(0xFF50FA7B),             // Ch5: Green
      const Color(0xFF8BE9FD),             // Ch6: Sky
      const Color(0xFFFF79C6),             // Ch7: Magenta
      const Color(0xFFF1FA8C),             // Ch8: Yellow
    ];

    String channelLabel(int c) {
      if (channels == 1) return 'Mono';
      if (channels == 2) return c == 0 ? 'L' : 'R';
      if (channels == 6) {
        const labels = ['L', 'R', 'C', 'LFE', 'Ls', 'Rs'];
        return c < labels.length ? labels[c] : 'Ch${c + 1}';
      }
      return 'Ch${c + 1}';
    }

    return Container(
      decoration: BoxDecoration(
        color: p.bg.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      padding: const EdgeInsets.fromLTRB(AuraSpace.md, AuraSpace.sm, AuraSpace.md, AuraSpace.xs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(l.convSpectrumTitle, style: captionOf(p, color: p.textDim)),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  for (var c = 0; c < chCount; c++)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: BoxDecoration(
                            color: channelColors[c % channelColors.length],
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          channelLabel(c),
                          style: monoOf(p, size: 10, color: p.textDim),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.xs),
          SizedBox(
            height: 72,
            child: CustomPaint(
              painter: _IrSpectrumPainter(
                spectrum: spectrum,
                channelColors: channelColors,
                gridColor: p.hairline.withValues(alpha: 0.6),
                freqTextColor: p.textDim.withValues(alpha: 0.6),
              ),
              child: const SizedBox.expand(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('20Hz', style: monoOf(p, size: 9, color: p.textDim.withValues(alpha: 0.6))),
                Text('100Hz', style: monoOf(p, size: 9, color: p.textDim.withValues(alpha: 0.6))),
                Text('1kHz', style: monoOf(p, size: 9, color: p.textDim.withValues(alpha: 0.6))),
                Text('10kHz', style: monoOf(p, size: 9, color: p.textDim.withValues(alpha: 0.6))),
                Text('20kHz', style: monoOf(p, size: 9, color: p.textDim.withValues(alpha: 0.6))),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _IrSpectrumPainter extends CustomPainter {
  final List<List<double>> spectrum;
  final List<Color> channelColors;
  final Color gridColor;
  final Color freqTextColor;

  _IrSpectrumPainter({
    required this.spectrum,
    required this.channelColors,
    required this.gridColor,
    required this.freqTextColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final gp = Paint()
      ..color = gridColor
      ..strokeWidth = 1;

    for (var i = 1; i < 4; i++) {
      final y = size.height * i / 4;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gp);
    }
    for (final frac in [0.22, 0.55, 0.88]) {
      final x = size.width * frac;
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gp);
    }

    if (spectrum.isEmpty) return;

    for (var c = 0; c < spectrum.length; c++) {
      final bands = spectrum[c];
      if (bands.isEmpty) continue;
      final color = channelColors[c % channelColors.length];
      final path = Path();
      final fillPath = Path();

      final n = bands.length;
      final dx = size.width / (n - 1);

      final pts = <Offset>[];
      for (var i = 0; i < n; i++) {
        final v = bands[i].clamp(0.0, 1.0);
        final x = i * dx;
        final y = size.height - (v * (size.height - 4)) - 2;
        pts.add(Offset(x, y));
      }

      path.moveTo(pts[0].dx, pts[0].dy);
      fillPath.moveTo(pts[0].dx, size.height);
      fillPath.lineTo(pts[0].dx, pts[0].dy);

      for (var i = 0; i < pts.length - 1; i++) {
        final p0 = pts[i];
        final p1 = pts[i + 1];
        final mx = (p0.dx + p1.dx) / 2;
        path.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
        fillPath.cubicTo(mx, p0.dy, mx, p1.dy, p1.dx, p1.dy);
      }

      fillPath.lineTo(pts.last.dx, size.height);
      fillPath.close();

      final fillPaint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            color.withValues(alpha: 0.22),
            color.withValues(alpha: 0.02),
          ],
        ).createShader(Offset.zero & size);
      canvas.drawPath(fillPath, fillPaint);

      final strokePaint = Paint()
        ..color = color.withValues(alpha: 0.9)
        ..strokeWidth = 1.6
        ..style = PaintingStyle.stroke;
      canvas.drawPath(path, strokePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _IrSpectrumPainter old) {
    if (old.spectrum.length != spectrum.length) return true;
    for (var c = 0; c < spectrum.length; c++) {
      if (old.spectrum[c] != spectrum[c]) return true;
    }
    return false;
  }
}

/* ---- Freeverb 3D 空间声学室渲染 ---- */

class _Freeverb3DStage extends StatelessWidget {
  final AppModel model;
  const _Freeverb3DStage({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return Container(
      height: 125,
      decoration: BoxDecoration(
        color: p.bg.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(AuraRadius.md),
        border: Border.all(
          color: model.fvOn ? p.accent.withValues(alpha: 0.25) : p.hairline,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        fit: StackFit.expand,
        children: [
          ValueListenableBuilder<double>(
            valueListenable: model.levelL,
            builder: (_, lvlL, _) => ValueListenableBuilder<double>(
              valueListenable: model.levelR,
              builder: (_, lvlR, _) => CustomPaint(
                painter: _Freeverb3DPainter(
                  enabled: model.fvOn,
                  decay: model.fvDecay,
                  damp: model.fvDamp,
                  wet: model.fvWet,
                  levelL: lvlL,
                  levelR: lvlR,
                  playing: model.playing,
                  accentColor: p.accent,
                  secondaryColor: const Color(0xFFFF5EA8),
                  hairlineColor: p.hairline,
                  gridColor: p.accent.withValues(alpha: 0.09),
                  textColor: p.textDim,
                ),
              ),
            ),
          ),
          Positioned(
            top: AuraSpace.sm,
            left: AuraSpace.md,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.view_in_ar_outlined,
                    size: 14, color: model.fvOn ? p.accent : p.textDim),
                const SizedBox(width: 4),
                Text(l.fv3DTitle,
                    style: monoOf(p, size: 11,
                        color: model.fvOn ? p.text : p.textDim)),
              ],
            ),
          ),
          Positioned(
            top: AuraSpace.sm,
            right: AuraSpace.md,
            child: Text(
              model.fvOn
                  ? 'RT 3D · 衰减 ${(model.fvDecay * 100).toInt()}% · 阻尼 ${(model.fvDamp * 100).toInt()}%'
                  : '待机 (Bypass)',
              style: monoOf(p, size: 10,
                  color: model.fvOn ? p.accent.withValues(alpha: 0.8) : p.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

class _Freeverb3DPainter extends CustomPainter {
  final bool enabled;
  final double decay;
  final double damp;
  final double wet;
  final double levelL;
  final double levelR;
  final bool playing;
  final Color accentColor;
  final Color secondaryColor;
  final Color hairlineColor;
  final Color gridColor;
  final Color textColor;

  _Freeverb3DPainter({
    required this.enabled,
    required this.decay,
    required this.damp,
    required this.wet,
    required this.levelL,
    required this.levelR,
    required this.playing,
    required this.accentColor,
    required this.secondaryColor,
    required this.hairlineColor,
    required this.gridColor,
    required this.textColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 1) 3D 透视室地面与四壁
    final fl = Offset(w * 0.06, h * 0.94);
    final fr = Offset(w * 0.94, h * 0.94);
    final bl = Offset(w * 0.30, h * 0.40);
    final br = Offset(w * 0.70, h * 0.40);
    final tl = Offset(w * 0.30, h * 0.16);
    final tr = Offset(w * 0.70, h * 0.16);

    final roomPaint = Paint()
      ..color = hairlineColor.withValues(alpha: enabled ? 0.35 : 0.18)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;

    canvas.drawRect(Rect.fromPoints(tl, br), roomPaint);
    canvas.drawLine(bl, fl, roomPaint);
    canvas.drawLine(br, fr, roomPaint);
    canvas.drawLine(tl, Offset(w * 0.06, h * 0.02), roomPaint);
    canvas.drawLine(tr, Offset(w * 0.94, h * 0.02), roomPaint);

    final gridP = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (final frac in [0.15, 0.35, 0.50, 0.65, 0.85]) {
      final bottomPt = Offset(w * frac, h * 0.94);
      final topPt = Offset(
        bl.dx + (br.dx - bl.dx) * ((bottomPt.dx - fl.dx) / (fr.dx - fl.dx)),
        bl.dy,
      );
      canvas.drawLine(topPt, bottomPt, gridP);
    }
    for (final z in [0.25, 0.50, 0.75]) {
      final y = bl.dy + (fl.dy - bl.dy) * (z * z);
      final leftX = bl.dx + (fl.dx - bl.dx) * (z * z);
      final rightX = br.dx + (fr.dx - br.dx) * (z * z);
      canvas.drawLine(Offset(leftX, y), Offset(rightX, y), gridP);
    }

    // 2) 声源与听者节点
    final srcL = Offset(w * 0.36, h * 0.48);
    final srcR = Offset(w * 0.64, h * 0.48);
    final listener = Offset(w * 0.50, h * 0.86);

    final listenerP = Paint()
      ..color = textColor.withValues(alpha: 0.8)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(listener, 4.5, listenerP);
    final headPath = Path()
      ..moveTo(listener.dx, listener.dy - 6)
      ..lineTo(listener.dx - 3, listener.dy - 3)
      ..lineTo(listener.dx + 3, listener.dy - 3)
      ..close();
    canvas.drawPath(headPath, listenerP);

    // 3) 实时动态脉冲
    final normL = playing ? ((levelL + 60) / 60).clamp(0.0, 1.0) : 0.0;
    final normR = playing ? ((levelR + 60) / 60).clamp(0.0, 1.0) : 0.0;

    final pL = Paint()..color = accentColor;
    canvas.drawCircle(srcL, 3.5 + normL * 3, pL);
    if (enabled && normL > 0.05) {
      canvas.drawCircle(
        srcL,
        6 + normL * 14,
        Paint()
          ..color = accentColor.withValues(alpha: normL * 0.28)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    final pR = Paint()..color = secondaryColor;
    canvas.drawCircle(srcR, 3.5 + normR * 3, pR);
    if (enabled && normR > 0.05) {
      canvas.drawCircle(
        srcR,
        6 + normR * 14,
        Paint()
          ..color = secondaryColor.withValues(alpha: normR * 0.28)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    // 4) 3D 声学反射射线束
    if (!enabled) return;

    final rayLColor = Color.lerp(accentColor, const Color(0xFFFFB86C), damp * 0.6)!;
    final rayRColor = Color.lerp(secondaryColor, const Color(0xFFFF79C6), damp * 0.4)!;
    final baseAlpha = (0.2 + wet * 0.6).clamp(0.1, 0.9);
    final rayWidth = 1.0 + (1.0 - damp) * 0.8;

    final directPL = Paint()
      ..color = rayLColor.withValues(alpha: baseAlpha * 0.7)
      ..strokeWidth = rayWidth
      ..style = PaintingStyle.stroke;
    canvas.drawLine(srcL, listener, directPL);

    final directPR = Paint()
      ..color = rayRColor.withValues(alpha: baseAlpha * 0.7)
      ..strokeWidth = rayWidth
      ..style = PaintingStyle.stroke;
    canvas.drawLine(srcR, listener, directPR);

    final wallLy = h * (0.55 + 0.15 * decay);
    final wallLx = fl.dx + (bl.dx - fl.dx) * (1.0 - (wallLy - bl.dy) / (fl.dy - bl.dy));
    final ptWallL = Offset(wallLx, wallLy);

    final rayPathL = Path()
      ..moveTo(srcL.dx, srcL.dy)
      ..lineTo(ptWallL.dx, ptWallL.dy)
      ..lineTo(listener.dx, listener.dy);
    canvas.drawPath(
      rayPathL,
      Paint()
        ..color = rayLColor.withValues(alpha: baseAlpha * 0.65)
        ..strokeWidth = rayWidth
        ..style = PaintingStyle.stroke,
    );

    final wallRy = h * (0.55 + 0.15 * decay);
    final wallRx = fr.dx + (br.dx - fr.dx) * (1.0 - (wallRy - br.dy) / (fr.dy - br.dy));
    final ptWallR = Offset(wallRx, wallRy);

    final rayPathR = Path()
      ..moveTo(srcR.dx, srcR.dy)
      ..lineTo(ptWallR.dx, ptWallR.dy)
      ..lineTo(listener.dx, listener.dy);
    canvas.drawPath(
      rayPathR,
      Paint()
        ..color = rayRColor.withValues(alpha: baseAlpha * 0.65)
        ..strokeWidth = rayWidth
        ..style = PaintingStyle.stroke,
    );

    if (decay > 0.2) {
      final backBounceXL = w * (0.35 + 0.1 * decay);
      final ptBackL = Offset(backBounceXL, bl.dy);
      final rayBackL = Path()
        ..moveTo(srcL.dx, srcL.dy)
        ..lineTo(ptBackL.dx, ptBackL.dy)
        ..lineTo(ptWallR.dx, ptWallR.dy * 0.9)
        ..lineTo(listener.dx, listener.dy);
      canvas.drawPath(
        rayBackL,
        Paint()
          ..color = rayLColor.withValues(alpha: baseAlpha * 0.4 * decay)
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke,
      );

      final backBounceXR = w * (0.65 - 0.1 * decay);
      final ptBackR = Offset(backBounceXR, br.dy);
      final rayBackR = Path()
        ..moveTo(srcR.dx, srcR.dy)
        ..lineTo(ptBackR.dx, ptBackR.dy)
        ..lineTo(ptWallL.dx, ptWallL.dy * 0.9)
        ..lineTo(listener.dx, listener.dy);
      canvas.drawPath(
        rayBackR,
        Paint()
          ..color = rayRColor.withValues(alpha: baseAlpha * 0.4 * decay)
          ..strokeWidth = 1.0
          ..style = PaintingStyle.stroke,
      );
    }

    final hazePaint = Paint()
      ..shader = RadialGradient(
        colors: [
          accentColor.withValues(alpha: 0.12 * wet),
          secondaryColor.withValues(alpha: 0.08 * wet),
          Colors.transparent,
        ],
      ).createShader(Rect.fromCircle(center: Offset(w * 0.5, h * 0.55), radius: w * 0.35));
    canvas.drawCircle(Offset(w * 0.5, h * 0.55), w * 0.35, hazePaint);
  }

  @override
  bool shouldRepaint(covariant _Freeverb3DPainter old) {
    return old.enabled != enabled ||
        old.decay != decay ||
        old.damp != damp ||
        old.wet != wet ||
        old.levelL != levelL ||
        old.levelR != levelR ||
        old.playing != playing;
  }
}
