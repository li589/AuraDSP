/*
 * visualizer_page.dart — 可视化页：引擎 RT 线程 → SPSC ring → UI 拉取的终点
 *
 * 布局不走 PageScaffold：本页只有一个主舞台 + 一条电平带，需要「占满剩余高度」，
 * 因此直接 Column + Expanded 布局，保证频谱是页面的绝对主体。
 * 峰值保持线在 UI 侧计算（PeakHolder），不给引擎加任何负担。
 */
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
import 'widgets.dart';

class VisualizerPage extends StatefulWidget {
  final AppModel model;
  const VisualizerPage({super.key, required this.model});

  @override
  State<VisualizerPage> createState() => _VisualizerPageState();
}

class _VisualizerPageState extends State<VisualizerPage> {
  final PeakHolder _peaks = PeakHolder();
  final ValueNotifier<List<double>> _peakNotifier =
      ValueNotifier<List<double>>(List.filled(32, 0));

  @override
  void initState() {
    super.initState();
    widget.model.spectrum.addListener(_onSpectrum);
  }

  void _onSpectrum() {
    _peakNotifier.value = List.of(_peaks.update(widget.model.spectrum.value));
  }

  @override
  void dispose() {
    widget.model.spectrum.removeListener(_onSpectrum);
    _peakNotifier.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        AmbientSpectrum(spectrum: widget.model.spectrum, palette: p),
        if (p.isDark) const GrainOverlay(),
        Padding(
          padding: const EdgeInsets.fromLTRB(AuraSpace.pageX, AuraSpace.pageTop,
              AuraSpace.pageX, AuraSpace.pageBottom),
          child: Center(
            child: ConstrainedBox(
              constraints:
                  const BoxConstraints(maxWidth: AuraSpace.contentMaxW),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PageHeader(
                    eyebrow: l.pageVisualizerEyebrow,
                    title: l.pageVisualizerTitle,
                    trailing: _PeakReadout(
                        spectrum: widget.model.spectrum, label: l.peakLabel),
                  ),
                  const SizedBox(height: AuraSpace.lg),
                  Expanded(
                    child: ListenableBuilder(
                      listenable: widget.model,
                      builder: (_, _) => _Stage(
                        playing: widget.model.playing,
                        spectrum: widget.model.spectrum,
                        peaks: _peakNotifier,
                        emptyText: l.noAudio,
                      ),
                    ),
                  ),
                  const SizedBox(height: AuraSpace.lg),
                  SectionCard(
                    index: '01',
                    title: l.levelsTitle,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Expanded(
                              child: LevelMeter(
                                  level: widget.model.levelL, label: 'L')),
                          const SizedBox(width: AuraSpace.xl),
                          Expanded(
                              child: LevelMeter(
                                  level: widget.model.levelR, label: 'R')),
                        ]),
                        const SizedBox(height: AuraSpace.sm + 2),
                        Align(
                          alignment: Alignment.centerRight,
                          child: ValueListenableBuilder<double>(
                            valueListenable: widget.model.levelL,
                            builder: (_, lDb, _) =>
                                ValueListenableBuilder<double>(
                              valueListenable: widget.model.levelR,
                              builder: (_, rDb, _) => Text(
                                  'L ${dbfsText(lDb)}  R ${dbfsText(rDb)} dBFS',
                                  style: monoOf(p, size: 11, color: p.textDim)),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/* ---- 主舞台 ---- */

class _Stage extends StatelessWidget {
  final bool playing;
  final ValueListenable<List<double>> spectrum;
  final ValueListenable<List<double>> peaks;
  final String emptyText;
  const _Stage({
    required this.playing,
    required this.spectrum,
    required this.peaks,
    required this.emptyText,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return AnimatedContainer(
      duration: AuraDur.base,
      curve: AuraCurve.standard,
      decoration: BoxDecoration(
        color: p.bg,
        borderRadius: BorderRadius.circular(AuraRadius.md),
        border: Border.all(
            color: playing ? p.accent.withValues(alpha: 0.22) : p.hairline,
            width: 1),
      ),
      clipBehavior: Clip.antiAlias,
      child: playing
          ? _StageContent(spectrum: spectrum, peaks: peaks)
          : Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.graphic_eq_outlined, size: 36, color: p.textDim),
                  const SizedBox(height: AuraSpace.md),
                  Text(emptyText, style: captionOf(p)),
                ],
              ),
            ),
    );
  }
}

class _StageContent extends StatelessWidget {
  final ValueListenable<List<double>> spectrum;
  final ValueListenable<List<double>> peaks;
  const _StageContent({required this.spectrum, required this.peaks});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
          AuraSpace.xl, AuraSpace.lg, AuraSpace.xl, AuraSpace.md),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: SpectrumView(
                    spectrum: spectrum,
                    peaks: peaks,
                    barGap: 3,
                    gridAccent: true,
                  ),
                ),
                const SizedBox(height: AuraSpace.sm),
                const FreqAxis(),
              ],
            ),
          ),
          const SizedBox(width: AuraSpace.md),
          // 右侧 dB 纵轴（绘图区同高，底部预留 FreqAxis 高度）
          const _DbScale(),
        ],
      ),
    );
  }
}

/// 右侧 dB 纵轴：0/-15/-30/-45/-60 dBFS，与频谱横向网格线（4 等分）对位
class _DbScale extends StatelessWidget {
  const _DbScale();

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    const marks = ['0', '-15', '-30', '-45', '-60'];
    return SizedBox(
      width: 28,
      child: Padding(
        // 与频谱绘图区上下对齐（给 FreqAxis 留出同高空间：14 轴高 + 8 间距）
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in marks)
              Text(m,
                  style: monoOf(p, size: 10,
                      color: p.textDim.withValues(alpha: 0.7))),
          ],
        ),
      ),
    );
  }
}

/* ---- 峰值读数（页面右上） ---- */

class _PeakReadout extends StatelessWidget {
  final ValueListenable<List<double>> spectrum;
  final String label;
  const _PeakReadout({required this.spectrum, required this.label});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ValueListenableBuilder<List<double>>(
      valueListenable: spectrum,
      builder: (_, bands, _) {
        var peak = 0.0;
        for (final v in bands) {
          peak = math.max(peak, v);
        }
        final db = bands.isEmpty || peak <= 0 ? -90.0 : peak * 60 - 60;
        return StatReadout(
          label: label,
          value: dbfsText(db),
          unit: 'dBFS',
          size: 20,
          valueColor: db > -3 ? p.error : p.accent,
        );
      },
    );
  }
}
