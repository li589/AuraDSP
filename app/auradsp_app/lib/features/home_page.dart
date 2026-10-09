/*
 * home_page.dart — 主页：引擎状态大屏 + 音频源快速控制
 *
 * 层级：hero 状态区（最大字号 + A/B 主操作） → 音源 → 频谱/电平 → 引擎简报（静音收尾）
 * 数字即设计：延迟/电平读数全部等宽对齐，肉眼可扫。
 */
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
import 'widgets.dart';

class HomePage extends StatelessWidget {
  final AppModel model;
  const HomePage({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return PageScaffold(
      eyebrow: l.pageHomeEyebrow,
      title: l.pageHomeTitle,
      ambient: model.spectrum,
      children: [
        _SpectrumCard(model: model), // 可视化置顶：主页的第一视觉
        _Hero(model: model), // 引擎总览：状态 / 延迟 / 旁路
        SectionCard(
          index: '01',
          title: l.sourceCard,
          hint: l.heroHintIdle,
          child: _SourceButtons(model: model),
        ),
        _EngineBrief(model: model),
      ],
    );
  }
}

/* ---- hero 状态区 ---- */

class _Hero extends StatelessWidget {
  final AppModel model;
  const _Hero({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        final (text, color) = switch (model.engineState) {
          2 => (l.stateError, p.error),
          0 => (l.stateBypass, p.textDim),
          _ => (
              model.playing ? l.stateProcessing : l.stateBypass,
              model.playing ? p.accent : p.textDim
            ),
        };
        return SectionCard(
          hero: true,
          padding: const EdgeInsets.all(AuraSpace.xl),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(l.statusLabel, style: eyebrowOf(p)),
                        const SizedBox(width: AuraSpace.sm),
                        PulseDot(
                          color: color,
                          active: model.engineState == 1 && model.playing,
                          size: 6,
                        ),
                      ],
                    ),
                    const SizedBox(height: AuraSpace.md),
                    AnimatedDefaultTextStyle(
                      duration: AuraDur.base,
                      curve: AuraCurve.standard,
                      style: displayOf(p, size: 40, color: color),
                      child: Text(text, maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(height: AuraSpace.sm + 2),
                    Text(
                      model.playing ? l.heroHintProcessing : l.heroHintIdle,
                      style: captionOf(p),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AuraSpace.xl),
              // 延迟读数（数字即设计；语义为"算法附加延迟"，悬停有解释）
              Tooltip(
                message: l.latencyTip,
                waitDuration: const Duration(milliseconds: 350),
                child: StatReadout(
                  label: l.latencyLabel,
                  value: model.latencyMs.toStringAsFixed(1),
                  unit: 'ms',
                  size: 30,
                  valueColor: latencyColor(model.latencyMs, p),
                ),
              ),
              const SizedBox(width: AuraSpace.xl),
              _BypassButton(model: model),
            ],
          ),
        );
      },
    );
  }
}

/* ---- 音频源 ---- */

class _SourceButtons extends StatelessWidget {
  final AppModel model;
  const _SourceButtons({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Wrap(
        spacing: AuraSpace.sm,
        runSpacing: AuraSpace.sm,
        children: [
          AuraChip(
            l.srcTone,
            icon: Icons.graphic_eq,
            selected: model.playing && model.sourceKind == 'tone',
            onTap: () => model.setSource('tone'),
          ),
          AuraChip(
            l.srcPink,
            icon: Icons.blur_on,
            selected: model.playing && model.sourceKind == 'pink',
            onTap: () => model.setSource('pink'),
          ),
          AuraChip(
            l.srcFile,
            icon: Icons.folder_open_outlined,
            selected: model.playing && model.sourceKind == 'file',
            onTap: () async {
              const type = XTypeGroup(label: 'WAV', extensions: ['wav']);
              final f = await openFile(acceptedTypeGroups: [type]);
              if (f != null) model.setSource('file', path: f.path);
            },
          ),
          if (model.playing)
            AuraChip(
              l.srcStop,
              icon: Icons.stop_rounded,
              danger: true,
              selected: true,
              onTap: () => model.setSource('stop'),
            ),
        ],
      ),
    );
  }
}

class _BypassButton extends StatefulWidget {
  final AppModel model;
  const _BypassButton({required this.model});

  @override
  State<_BypassButton> createState() => _BypassButtonState();
}

class _BypassButtonState extends State<_BypassButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: widget.model,
      builder: (_, _) {
        final on = widget.model.bypass;
        final bg = on ? p.accent2 : p.panelRaised;
        final fg = on ? p.accentContrast : p.text;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() {
            _hover = false;
            _down = false;
          }),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _down = true),
            onTapUp: (_) => setState(() => _down = false),
            onTapCancel: () => setState(() => _down = false),
            onTap: widget.model.toggleBypass,
            child: AnimatedScale(
              duration: AuraDur.instant,
              scale: _down ? 0.97 : 1.0,
              child: AnimatedContainer(
                duration: AuraDur.base,
                curve: AuraCurve.emphasized,
                height: AuraSpace.hero,
                padding: const EdgeInsets.symmetric(horizontal: AuraSpace.xl),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(AuraRadius.md),
                  border: Border.all(
                    color: on
                        ? p.accent2
                        : (_hover ? p.textDim.withValues(alpha: 0.5) : p.hairline),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(on ? Icons.power_settings_new : Icons.bolt_outlined,
                        size: 18, color: fg),
                    const SizedBox(width: AuraSpace.sm + 2),
                    Text(on ? l.bypassOn : l.bypassOff,
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700,
                            letterSpacing: 0.3, color: fg)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/* ---- 频谱 + 电平 ---- */

class _SpectrumCard extends StatelessWidget {
  final AppModel model;
  const _SpectrumCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      index: '02',
      title: l.spectrum,
      trailing: _StateHint(model: model),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 140,
            child: ListenableBuilder(
              listenable: model,
              builder: (_, _) {
                if (!model.playing) {
                  return _EmptySpectrum(text: l.noAudio);
                }
                // 频谱主体 + 右侧 dB 纵轴（与可视化页同一套坐标语义）
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: SpectrumView(spectrum: model.spectrum)),
                    const SizedBox(width: AuraSpace.sm),
                    const _DbScaleMini(),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: AuraSpace.sm),
          const FreqAxis(),
          const SizedBox(height: AuraSpace.lg),
          Row(children: [
            Expanded(child: LevelMeter(level: model.levelL, label: 'L')),
            const SizedBox(width: AuraSpace.lg),
            Expanded(child: LevelMeter(level: model.levelR, label: 'R')),
          ]),
          const SizedBox(height: AuraSpace.sm + 2),
          Align(
            alignment: Alignment.centerRight,
            child: ValueListenableBuilder<double>(
              valueListenable: model.levelL,
              builder: (_, lDb, _) => ValueListenableBuilder<double>(
                valueListenable: model.levelR,
                builder: (_, rDb, _) => Text(
                    'L ${dbfsText(lDb)}  R ${dbfsText(rDb)} dBFS',
                    style: monoOf(p, size: 11, color: p.textDim)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 首页频谱右侧的紧凑 dB 纵轴（0 / -15 / -30 / -45 / -60 dBFS）
class _DbScaleMini extends StatelessWidget {
  const _DbScaleMini();

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    const marks = ['0', '-15', '-30', '-45', '-60'];
    return SizedBox(
      width: 26,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final m in marks)
            Text(m,
                style: monoOf(
                    p, size: 9, color: p.textDim.withValues(alpha: 0.7))),
        ],
      ),
    );
  }
}

class _StateHint extends StatelessWidget {
  final AppModel model;
  const _StateHint({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Text(
        model.playing ? '● live' : 'idle',
        style: monoOf(p, size: 10,
            color: model.playing ? p.success : p.textDim.withValues(alpha: 0.7)),
      ),
    );
  }
}

class _EmptySpectrum extends StatelessWidget {
  final String text;
  const _EmptySpectrum({required this.text});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_outlined, size: 18, color: p.textDim),
          const SizedBox(width: AuraSpace.sm),
          Text(text, style: captionOf(p)),
        ],
      ),
    );
  }
}

/* ---- 引擎简报（静音收尾，不加卡片） ---- */

class _EngineBrief extends StatelessWidget {
  final AppModel model;
  const _EngineBrief({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        final info = model.info;
        return Padding(
          padding: const EdgeInsets.fromLTRB(
              AuraSpace.xs, AuraSpace.sm, AuraSpace.xs, 0),
          child: Wrap(
            spacing: AuraSpace.md,
            runSpacing: AuraSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(l.engineInfo, style: eyebrowOf(p)),
              Text(l.engineForm, style: captionOf(p)),
              if (info != null)
                Text(
                  '${l.engineAbi(info.abi, info.version)} · '
                  '${info.deviceRate}Hz · ${info.deviceCh}ch · '
                  '${info.bufferFrames}f',
                  style: monoOf(p, size: 11, color: p.textDim),
                ),
            ],
          ),
        );
      },
    );
  }
}
