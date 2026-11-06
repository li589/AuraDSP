import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../ui/widgets.dart' show FreqAxis;
import '../controllers/peak_physics_engine.dart';
import '../controllers/waveform_synthesizer.dart';
import '../models/visualizer_themes.dart';
import '../models/visualizer_types.dart';
import '../styles/style_atmosphere.dart';
import '../styles/visualizer_painter_dispatcher.dart';
import '../styles/visualizer_time_aware.dart';
import 'visualizer_db_scale.dart';

/// 画笔包装：数据驱动风格（频谱柱/示波器/相位仪）不挂时间监听，
/// 只在频谱帧重建时重绘（~20fps）；时间驱动风格（脉动星云/赛博网络/
/// 流体/龙卷风/MilkDrop/GPU 着色器）挂时间轴，由视口缓存同一份画笔实例。
///
/// 2026-10-31 内存优化：旧实现每帧 `build(time)` 新建一个画笔，Path /
/// Paint / Shader 等 Skia 原生对象只能等 GC finalizer 回收；在核显上还会
/// 让光栅线程落后、GPU 表面排队（实测可视化页可涨到 2GB+）。
/// 单层合批渲染画笔：将背景氛围层与主视效画笔合并到同一个 Canvas 进行绘制
/// 彻底废除双层全屏 RepaintBoundary 堆叠，消除双份全屏离屏 Surface 显存占用与 GPU 排队。
class _CompositeVisualizerPainter extends CustomPainter {
  final CustomPainter? ambience;
  final CustomPainter mainPainter;
  final ValueListenable<double>? mainTime;
  final ValueListenable<double>? ambienceTime;

  _CompositeVisualizerPainter({
    this.ambience,
    required this.mainPainter,
    this.mainTime,
    this.ambienceTime,
  }) : super(repaint: mainTime ?? ambienceTime);

  @override
  void paint(Canvas canvas, Size size) {
    final a = ambience;
    if (a != null) {
      final at = ambienceTime;
      if (at != null && a is VisualizerTimeAware) {
        (a as VisualizerTimeAware).setVisualizerTime(at.value);
      }
      a.paint(canvas, size);
    }
    final mt = mainTime;
    final mp = mainPainter;
    if (mt != null && mp is VisualizerTimeAware) {
      (mp as VisualizerTimeAware).setVisualizerTime(mt.value);
    }
    mp.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _CompositeVisualizerPainter oldDelegate) {
    if (oldDelegate.ambience != ambience || oldDelegate.mainPainter != mainPainter) {
      return true;
    }
    return mainTime == null;
  }
}

/// 视效主舞台活跃渲染画布视口
class VisualizerCanvasViewport extends StatefulWidget {
  final ValueListenable<double> time;
  final ValueListenable<List<double>> spectrum;
  final ValueListenable<double> levelL;
  final ValueListenable<double> levelR;
  final VisualizerConfig config;
  final VisualizerPalette palette;
  final PeakPhysicsEngine peakEngine;
  final WaveformSynthesizer waveformSynth;

  const VisualizerCanvasViewport({
    super.key,
    required this.time,
    required this.spectrum,
    required this.levelL,
    required this.levelR,
    required this.config,
    required this.palette,
    required this.peakEngine,
    required this.waveformSynth,
  });

  @override
  State<VisualizerCanvasViewport> createState() =>
      _VisualizerCanvasViewportState();
}

class _VisualizerCanvasViewportState extends State<VisualizerCanvasViewport> {
  CustomPainter? _delegate;
  Object? _delegateKey;

  CustomPainter? _ambience;
  Object? _ambienceKey;

  /// 氛围层时间轴：独立的 ~20fps 节流通知（星点漂移/光晕呼吸本就是慢动作，
  /// 无需跟随 30fps 主画布；旧实现每帧重建整屏径向渐变）。
  final ValueNotifier<double> _ambienceTime = ValueNotifier<double>(0.0);

  @override
  void initState() {
    super.initState();
    _ambienceTime.value = widget.time.value;
    widget.time.addListener(_onTime);
  }

  @override
  void didUpdateWidget(VisualizerCanvasViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.time != widget.time) {
      oldWidget.time.removeListener(_onTime);
      widget.time.addListener(_onTime);
    }
  }

  @override
  void dispose() {
    widget.time.removeListener(_onTime);
    _ambienceTime.dispose();
    super.dispose();
  }

  void _onTime() {
    if (widget.time.value - _ambienceTime.value >= 0.05) {
      _ambienceTime.value = widget.time.value;
    }
  }

  bool _usesAmbience(VisualizerStyle style) => switch (style) {
        // 自带完整背景构图（光晕/地面雾气）的风格不再叠加星尘氛围层，避免双层噪点
        VisualizerStyle.auroraShader ||
        VisualizerStyle.tunnelShader ||
        VisualizerStyle.milkDrop ||
        VisualizerStyle.fluidDynamics ||
        VisualizerStyle.tornado =>
          false,
        _ => true,
      };

  /// 仅在「风格/配置/调色板/数据缓冲身份」变化时重建画笔；常规频谱帧
  /// 只触发重绘（数据列表是原地复用的，画笔持有同一引用即可看到新值）。
  CustomPainter _delegateFor(
      List<double> renderedBands, List<double> peaks) {
    final key = (
      widget.config,
      widget.palette,
      renderedBands,
      peaks,
    );
    if (_delegate == null || _delegateKey != key) {
      _delegateKey = key;
      _delegate = buildVisualizerPainter(
        style: widget.config.style,
        config: widget.config,
        palette: widget.palette,
        rawBands: renderedBands,
        peaks: peaks,
        waveformSynth: widget.waveformSynth,
        time: widget.time.value,
      );
    }
    return _delegate!;
  }

  CustomPainter _ambienceFor(List<double> renderedBands) {
    final key = (widget.palette, widget.config.bloom, renderedBands);
    if (_ambience == null || _ambienceKey != key) {
      _ambienceKey = key;
      _ambience = AtmospherePainter(
        bands: renderedBands,
        palette: widget.palette,
        animationTime: widget.time.value,
        intensity: 0.55 + widget.config.bloom * 0.45,
      );
    }
    return _ambience!;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<List<double>>(
      valueListenable: widget.spectrum,
      builder: (_, rawBands, _) {
        final peaks = widget.peakEngine.update(
          rawBands,
          targetBands: widget.config.barCount,
          sensitivity: widget.config.sensitivity,
          gravity: widget.config.gravity,
          decay: widget.config.decayRate,
        );

        widget.waveformSynth.update(
          rawBands,
          levelLDbfs: widget.levelL.value,
          levelRDbfs: widget.levelR.value,
          sensitivity: widget.config.sensitivity,
        );

        final renderedBands = widget.peakEngine.renderedBands.isNotEmpty
            ? widget.peakEngine.renderedBands
            : rawBands;

        final delegate = _delegateFor(renderedBands, peaks);
        final bool usesAmbience = _usesAmbience(widget.config.style);
        final CustomPainter? ambienceDelegate =
            usesAmbience ? _ambienceFor(renderedBands) : null;

        // 单层合批渲染：将背景氛围与主画笔合为一个 CustomPaint，0 额外 GPU 离屏缓冲
        final paintLayer = RepaintBoundary(
          child: CustomPaint(
            // 内容每帧都在变：显式告知光栅缓存不要为它保留离屏层，
            // 否则 30 Hz 变化的全屏 Picture 会在 GPU 侧持续占住大块 Shared 内存。
            willChange: true,
            painter: _CompositeVisualizerPainter(
              ambience: ambienceDelegate,
              mainPainter: delegate,
              mainTime: delegate is VisualizerTimeAware ? widget.time : null,
              ambienceTime: usesAmbience ? _ambienceTime : null,
            ),
            child: const SizedBox.expand(),
          ),
        );

        Widget body;
        if (widget.config.style == VisualizerStyle.bars) {
          body = Padding(
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
                      Expanded(child: paintLayer),
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
        } else {
          body = paintLayer;
        }

        // 视效风格切换过渡动效：280ms 交叉平滑淡入淡出，彻底消除突变跳跃感
        return AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          layoutBuilder: (currentChild, previousChildren) => Stack(
            fit: StackFit.expand,
            children: [
              ...previousChildren,
              ?currentChild,
            ],
          ),
          child: KeyedSubtree(
            key: ValueKey(widget.config.style),
            child: body,
          ),
        );
      },
    );
  }
}

/// 音频静音或停止时的待机占位视图
class VisualizerIdlePlaceholder extends StatelessWidget {
  final String emptyText;

  const VisualizerIdlePlaceholder({
    super.key,
    required this.emptyText,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_outlined, size: 40, color: p.textDim),
          const SizedBox(height: AuraSpace.md),
          Text(emptyText, style: captionOf(p)),
        ],
      ),
    );
  }
}
