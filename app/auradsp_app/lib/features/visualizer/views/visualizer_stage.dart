import 'dart:async';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../../../ui/widgets.dart' show FreqAxis;
import '../controllers/peak_physics_engine.dart';
import '../controllers/waveform_synthesizer.dart';
import '../lyrics/models/lyric_models.dart';
import '../lyrics/services/media_sync_service.dart';
import '../lyrics/views/lyric_view.dart';
import '../models/visualizer_themes.dart';
import '../models/visualizer_types.dart';
import '../shaders/gpu_shader_service.dart';
import '../styles/visualizer_painter_dispatcher.dart';
import 'visualizer_db_scale.dart';
import 'visualizer_hud.dart';

/// 可视化核心舞台（支持多视效引擎切换、鼠标隐退交互、窗口与系统全屏沉浸）
class VisualizerStage extends StatefulWidget {
  final bool playing;
  final ValueListenable<List<double>> spectrum;
  final ValueListenable<double> levelL;
  final ValueListenable<double> levelR;
  final VisualizerConfig config;
  final ValueChanged<VisualizerStyle> onStyleChanged;
  final VoidCallback onToggleFullscreen;
  final VoidCallback onToggleSystemFullscreen;
  final bool isSystemFullscreen;
  final VoidCallback onToggleLyrics;
  final VoidCallback onOpenDrawer;
  final MediaSyncService? mediaSync;
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
    required this.onToggleSystemFullscreen,
    this.isSystemFullscreen = false,
    required this.onToggleLyrics,
    required this.onOpenDrawer,
    this.mediaSync,
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
    GpuShaderService.instance.initialize().then((_) {
      if (mounted) setState(() {});
    });
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

              // 实时歌词叠加展示层
              if (widget.config.showLyrics && widget.mediaSync != null)
                ValueListenableBuilder<LyricDocument>(
                  valueListenable: widget.mediaSync!.currentLyrics,
                  builder: (_, doc, _) => ValueListenableBuilder<int>(
                    valueListenable: widget.mediaSync!.activeLineIndex,
                    builder: (_, activeIdx, _) => Container(
                      color: p.bg.withValues(alpha: 0.72),
                      child: LyricView(
                        document: doc,
                        activeIndex: activeIdx,
                        showTranslation: widget.config.showTranslation,
                      ),
                    ),
                  ),
                ),

              // 底部悬浮控制岛 HUD
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: VisualizerHud(
                    config: widget.config,
                    visible: _hudVisible,
                    isSystemFullscreen: widget.isSystemFullscreen,
                    onStyleChanged: (style) {
                      _onUserPointerActivity();
                      widget.onStyleChanged(style);
                    },
                    onToggleFullscreen: () {
                      _onUserPointerActivity();
                      widget.onToggleFullscreen();
                    },
                    onToggleSystemFullscreen: () {
                      _onUserPointerActivity();
                      widget.onToggleSystemFullscreen();
                    },
                    onToggleLyrics: () {
                      _onUserPointerActivity();
                      widget.onToggleLyrics();
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

        // 统一使用物理引擎平滑后的频段渲染柱状谱，消除低频抖动与条宽错位
        final painter = buildVisualizerPainter(
          style: widget.config.style,
          config: widget.config,
          palette: palette,
          rawBands: _peakEngine.renderedBands.isNotEmpty
              ? _peakEngine.renderedBands
              : rawBands,
          peaks: peaks,
          waveformSynth: _waveformSynth,
          time: _time,
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
                            painter: painter,
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
                  const VisualizerDbScale(),
                ],
              ],
            ),
          );
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
