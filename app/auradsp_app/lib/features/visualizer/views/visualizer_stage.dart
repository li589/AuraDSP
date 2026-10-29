import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../../../ui/widgets.dart' show FreqAxis;
import '../controllers/peak_physics_engine.dart';
import '../controllers/waveform_synthesizer.dart';
import '../models/visualizer_themes.dart';
import '../models/visualizer_types.dart';
import '../styles/style_cyber_grid.dart';
import '../styles/style_goniometer.dart';
import '../styles/style_oscilloscope.dart';
import '../styles/style_pulse_orb.dart';
import '../styles/style_spectrum_bars.dart';
import 'visualizer_hud.dart';

/// 可视化核心舞台（支持 5 大视效引擎切换、鼠标隐退交互与全屏沉浸）
class VisualizerStage extends StatefulWidget {
  final bool playing;
  final ValueListenable<List<double>> spectrum;
  final ValueListenable<double> levelL;
  final ValueListenable<double> levelR;
  final VisualizerConfig config;
  final ValueChanged<VisualizerStyle> onStyleChanged;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onOpenDrawer;
  final String emptyText;
  final bool active;

  const VisualizerStage({
    super.key,
    required this.playing,
    required this.spectrum,
    required this.levelL,
    required this.levelR,
    required this.config,
    required this.onStyleChanged,
    required this.onToggleFullscreen,
    required this.onOpenDrawer,
    required this.emptyText,
    required this.active,
  });

  @override
  State<VisualizerStage> createState() => _VisualizerStageState();
}

class _VisualizerStageState extends State<VisualizerStage>
    with SingleTickerProviderStateMixin {
  final PeakPhysicsEngine _peakEngine = PeakPhysicsEngine();
  final WaveformSynthesizer _waveformSynth = WaveformSynthesizer();

  late final AnimationController _animController;
  Timer? _hudHideTimer;
  bool _hudVisible = true;
  double _time = 0.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..addListener(_onTick);

    if (widget.active) {
      _animController.repeat();
    }
    _startHudTimer();
  }

  void _onTick() {
    if (!mounted || !widget.active) return;
    setState(() {
      _time += 0.016;
    });
  }

  @override
  void didUpdateWidget(VisualizerStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      if (widget.active) {
        if (!_animController.isAnimating) _animController.repeat();
      } else {
        _animController.stop();
      }
    }
  }

  @override
  void dispose() {
    _hudHideTimer?.cancel();
    _animController.dispose();
    super.dispose();
  }

  void _onUserPointerActivity() {
    if (!_hudVisible) {
      setState(() => _hudVisible = true);
    }
    _startHudTimer();
  }

  void _startHudTimer() {
    _hudHideTimer?.cancel();
    _hudHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _hudVisible) {
        setState(() => _hudVisible = false);
      }
    });
  }

  void _resetPeaks() {
    _peakEngine.reset();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final palette = VisualizerPalette.resolve(widget.config.colorTheme, p);

    return MouseRegion(
      onHover: (_) => _onUserPointerActivity(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onUserPointerActivity,
        onDoubleTap: widget.onToggleFullscreen,
        child: AnimatedContainer(
          duration: AuraDur.base,
          curve: AuraCurve.standard,
          decoration: BoxDecoration(
            color: p.bg,
            borderRadius: BorderRadius.circular(
              widget.config.isMaximized ? 0 : AuraRadius.md,
            ),
            border: Border.all(
              color: widget.playing
                  ? palette.primary.withValues(alpha: 0.28)
                  : p.hairline,
              width: 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 主画面渲染视口
              if (widget.playing)
                _buildActiveCanvas(palette)
              else
                _buildIdlePlaceholder(p),

              // 底部悬浮控制岛 HUD
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: VisualizerHud(
                    config: widget.config,
                    visible: _hudVisible,
                    onStyleChanged: (style) {
                      _onUserPointerActivity();
                      widget.onStyleChanged(style);
                    },
                    onToggleFullscreen: () {
                      _onUserPointerActivity();
                      widget.onToggleFullscreen();
                    },
                    onOpenDrawer: () {
                      _onUserPointerActivity();
                      widget.onOpenDrawer();
                    },
                    onResetPeaks: () {
                      _onUserPointerActivity();
                      _resetPeaks();
                    },
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildActiveCanvas(VisualizerPalette palette) {
    return ValueListenableBuilder<List<double>>(
      valueListenable: widget.spectrum,
      builder: (_, rawBands, _) {
        final peaks = _peakEngine.update(
          rawBands,
          targetBands: widget.config.barCount,
          sensitivity: widget.config.sensitivity,
          gravity: widget.config.gravity,
          decay: widget.config.decayRate,
        );

        _waveformSynth.update(
          rawBands,
          levelLDbfs: widget.levelL.value,
          levelRDbfs: widget.levelR.value,
          sensitivity: widget.config.sensitivity,
        );

        if (widget.config.style == VisualizerStyle.bars) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(
              AuraSpace.xl,
              AuraSpace.lg,
              AuraSpace.xl,
              AuraSpace.md,
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Expanded(
                        child: RepaintBoundary(
                          child: CustomPaint(
                            painter: SpectrumBarsPainter(
                              bands: rawBands,
                              peaks: peaks,
                              palette: palette,
                              showGrid: widget.config.showGrid,
                              showPeaks: widget.config.showPeaks,
                              bloom: widget.config.bloom,
                            ),
                            child: const SizedBox.expand(),
                          ),
                        ),
                      ),
                      if (widget.config.showGrid) ...[
                        const SizedBox(height: AuraSpace.sm),
                        const FreqAxis(),
                      ],
                    ],
                  ),
                ),
                if (widget.config.showDbScale) ...[
                  const SizedBox(width: AuraSpace.md),
                  const _DbScale(),
                ],
              ],
            ),
          );
        }

        CustomPainter painter;
        switch (widget.config.style) {
          case VisualizerStyle.oscilloscope:
            painter = OscilloscopePainter(
              waveL: _waveformSynth.waveL,
              waveR: _waveformSynth.waveR,
              palette: palette,
              showGrid: widget.config.showGrid,
              bloom: widget.config.bloom,
            );
            break;
          case VisualizerStyle.goniometer:
            painter = GoniometerPainter(
              points: _waveformSynth.lissajousPoints,
              palette: palette,
              showGrid: widget.config.showGrid,
              bloom: widget.config.bloom,
            );
            break;
          case VisualizerStyle.cyberGrid:
            painter = CyberGridPainter(
              bands: rawBands,
              palette: palette,
              bloom: widget.config.bloom,
              animationTime: _time,
            );
            break;
          case VisualizerStyle.pulseOrb:
            painter = PulseOrbPainter(
              bands: rawBands,
              palette: palette,
              bloom: widget.config.bloom,
              animationTime: _time,
            );
            break;
          case VisualizerStyle.bars:
            // Handled above
            painter = SpectrumBarsPainter(
              bands: rawBands,
              peaks: peaks,
              palette: palette,
              showGrid: widget.config.showGrid,
              showPeaks: widget.config.showPeaks,
              bloom: widget.config.bloom,
            );
            break;
        }

        return RepaintBoundary(
          child: CustomPaint(
            painter: painter,
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }

  Widget _buildIdlePlaceholder(AuraPalette p) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_outlined, size: 40, color: p.textDim),
          const SizedBox(height: AuraSpace.md),
          Text(widget.emptyText, style: captionOf(p)),
        ],
      ),
    );
  }
}

/// 右侧 dB 纵轴：0/-15/-30/-45/-60 dBFS
class _DbScale extends StatelessWidget {
  const _DbScale();

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    const marks = ['0', '-15', '-30', '-45', '-60'];
    return SizedBox(
      width: 28,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 22),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            for (final m in marks)
              Text(
                m,
                style: monoOf(
                  p,
                  size: 10,
                  color: p.textDim.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

