import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../ui/widgets.dart' show FreqAxis;
import '../controllers/peak_physics_engine.dart';
import '../controllers/waveform_synthesizer.dart';
import '../models/visualizer_themes.dart';
import '../models/visualizer_types.dart';
import '../styles/style_atmosphere.dart';
import '../styles/style_tornado.dart';
import '../styles/visualizer_painter_dispatcher.dart';
import '../styles/visualizer_static_grid.dart';
import '../styles/visualizer_time_aware.dart';
import 'visualizer_db_scale.dart';

/// 画笔包装：数据驱动风格（频谱柱/示波器/相位仪）不挂时间监听，
/// 只在频谱帧重建时重绘（~20fps）；时间驱动风格（脉动星云/赛博网络/
/// 流体/龙卷风/MilkDrop/GPU 着色器）挂时间轴，由视口缓存同一份画笔实例。
///
/// 2026-10-31 内存优化：旧实现每帧 `build(time)` 新建一个画笔，Path /
/// Paint / Shader 等 Skia 原生对象只能等 GC finalizer 回收；在核显上还会
/// 让光栅线程落后、GPU 表面排队（实测可视化页可涨到 2GB+）。
/// 动态层画笔：只承载随时间/频谱变化的主视效（频谱柱、波形、粒子等）。
///
/// 2026-11-06（P2-1）：静态内容（烘焙氛围位图 + 网格基底）已上移到
/// [_StaticLayerPainter] 的独立缓存层，本层 `willChange: true`——
/// 它每帧都变，不应让光栅缓存保留全屏离屏层；由于静态内容在**另一个**
/// RepaintBoundary 里，这里的 willChange 不会让静态层缓存失效。
class _CompositeVisualizerPainter extends CustomPainter {
  final CustomPainter mainPainter;
  final ValueListenable<double>? mainTime;

  _CompositeVisualizerPainter({
    required this.mainPainter,
    this.mainTime,
  }) : super(repaint: mainTime);

  @override
  void paint(Canvas canvas, Size size) {
    final mt = mainTime;
    final mp = mainPainter;
    if (mt != null && mp is VisualizerTimeAware) {
      (mp as VisualizerTimeAware).setVisualizerTime(mt.value);
    }
    mp.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _CompositeVisualizerPainter oldDelegate) {
    if (oldDelegate.mainPainter != mainPainter) return true;
    return mainTime == null;
  }
}

/// 静态层画笔：风格基底 + 烘焙氛围位图 + 网格基底。三者都与音频帧无关
/// （基底只在风格/调色板变化时重建，氛围位图 10 Hz 刷新，网格只在风格/
/// 调色板变化时重建），因此本层允许光栅缓存
/// （`willChange: false`），避免 30 Hz 动态层把它一起拖入每帧重绘。
class _StaticLayerPainter extends CustomPainter {
  final ValueListenable<ui.Image?>? ambienceImage;
  final CustomPainter? grid;

  /// 风格自带的静态基底（如龙卷风的暗场/地面辉光/中轴光柱）。
  final CustomPainter? backdrop;

  /// 烘焙位图与画布像素 1:1，禁用采样即可保证与矢量绘制逐像素一致。
  final Paint _bakedPaint = Paint()
    ..filterQuality = FilterQuality.none
    ..isAntiAlias = false;

  _StaticLayerPainter({this.ambienceImage, this.grid, this.backdrop})
      : super(repaint: ambienceImage);

  @override
  void paint(Canvas canvas, Size size) {
    final b = backdrop;
    if (b != null) b.paint(canvas, size);
    final il = ambienceImage;
    if (il != null) {
      final img = il.value;
      if (img != null) {
        canvas.drawImageRect(
          img,
          Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
          Offset.zero & size,
          _bakedPaint,
        );
      }
    }
    final g = grid;
    if (g != null) g.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant _StaticLayerPainter oldDelegate) =>
      oldDelegate.ambienceImage != ambienceImage ||
      oldDelegate.grid != grid ||
      oldDelegate.backdrop != backdrop;
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

  /// 静态网格画笔墨迹只在风格/调色板变化时重建，配合独立缓存层永不逐帧重绘。
  CustomPainter? _gridPainter;
  Object? _gridKey;

  /// 风格自带静态基底（龙卷风暗场/地面辉光/中轴光柱）。
  CustomPainter? _backdrop;
  Object? _backdropKey;

  /// 氛围层时间轴：独立的 ~10fps 节流通知。星点漂移/光晕呼吸本就是慢动作，
  /// 10 Hz 更新在 30 Hz 主画布上肉眼不可分辨（旧实现是 30 帧全屏径向渐变）。
  final ValueNotifier<double> _ambienceTime = ValueNotifier<double>(0.0);

  /// 烘焙产物：整层氛围位图（像素尺寸 = 画布逻辑尺寸 × DPR）。
  final ValueNotifier<ui.Image?> _ambienceImage =
      ValueNotifier<ui.Image?>(null);

  /// 已退役但仍可能被最近几帧 Picture 引用的位图，延迟释放避免重放已销毁图像。
  final List<ui.Image> _retiredImages = <ui.Image>[];

  Size _canvasSize = Size.zero;
  double _devicePixelRatio = 1.0;
  bool _baking = false;
  bool _bakePending = false;

  @override
  void initState() {
    super.initState();
    _ambienceTime.value = widget.time.value;
    widget.time.addListener(_onTime);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final dpr = MediaQuery.devicePixelRatioOf(context);
    if (dpr != _devicePixelRatio) {
      _devicePixelRatio = dpr;
      if (_canvasSize != Size.zero) _scheduleAmbienceBake();
    }
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
    final current = _ambienceImage.value;
    _ambienceImage.dispose();
    // 仍在退役队列里的位图由各自的延迟计时器释放；当前位图同样延迟，避免
    // 光栅线程重放已销毁图像。
    if (current != null) {
      Timer(const Duration(milliseconds: 400), current.dispose);
    }
    super.dispose();
  }

  void _onTime() {
    if (_canvasSize == Size.zero) return;
    if (widget.time.value - _ambienceTime.value >= _ambiencePeriod) {
      _ambienceTime.value = widget.time.value;
      _scheduleAmbienceBake();
    }
  }

  /// 氛围层烘焙刷新周期：10 Hz。全屏径向渐变从「每帧一次」降为「每 100 ms 一次」。
  static const double _ambiencePeriod = 0.1;

  /// 触发一次烘焙；烘焙是异步的（Picture → GPU 纹理），同一时刻只允许一次在飞。
  void _scheduleAmbienceBake() {
    if (!mounted || _ambience == null || _canvasSize.isEmpty) return;
    if (_baking) {
      _bakePending = true;
      return;
    }
    unawaited(_bakeAmbience());
  }

  Future<void> _bakeAmbience() async {
    _baking = true;
    final painter = _ambience;
    final size = _canvasSize;
    final dpr = _devicePixelRatio;
    if (painter == null || size.isEmpty) {
      _baking = false;
      return;
    }
    final ambienceClock = _ambienceTime.value;
    if (painter is VisualizerTimeAware) {
      (painter as VisualizerTimeAware).setVisualizerTime(ambienceClock);
    }
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(dpr, dpr);
    painter.paint(canvas, size);
    final picture = recorder.endRecording();
    ui.Image? image;
    try {
      image = await picture.toImage(
        (size.width * dpr).round(),
        (size.height * dpr).round(),
      );
    } finally {
      picture.dispose();
      _baking = false;
    }
    if (!mounted) {
      image.dispose();
      return;
    }
    final previous = _ambienceImage.value;
    _ambienceImage.value = image;
    if (previous != null) {
      // 上一帧（甚至上上帧）的 Picture 可能仍在光栅线程排队，延迟 300 ms 再释放。
      _retiredImages.add(previous);
      Timer(const Duration(milliseconds: 300), () {
        _retiredImages.remove(previous);
        previous.dispose();
      });
    }
    if (_bakePending) {
      _bakePending = false;
      _scheduleAmbienceBake();
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
    List<double> renderedBands,
    List<double> peaks, {
    required bool separateGrid,
  }) {
    final key = (
      widget.config,
      widget.palette,
      renderedBands,
      peaks,
      separateGrid,
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
        showGrid: separateGrid ? false : null,
      );
    }
    return _delegate!;
  }

  /// 静态网格画笔：`showGrid` 打开且该风格网格不随时间变化时，交给独立缓存层。
  CustomPainter? _gridFor() {
    if (!widget.config.showGrid ||
        !StaticGridPainter.supports(widget.config.style)) {
      return null;
    }
    final key = (widget.config.style, widget.palette);
    if (_gridPainter == null || _gridKey != key) {
      _gridKey = key;
      _gridPainter = StaticGridPainter(
        style: widget.config.style,
        palette: widget.palette,
      );
    }
    return _gridPainter;
  }

  /// 每风格静态基底：只有龙卷风目前自带一层可烘焙的基底。
  CustomPainter? _backdropFor() {
    if (widget.config.style != VisualizerStyle.tornado) return null;
    final key = (widget.palette, widget.config.bloom);
    if (_backdrop == null || _backdropKey != key) {
      _backdropKey = key;
      _backdrop = TornadoBackdropPainter(
        palette: widget.palette,
        bloom: widget.config.bloom,
      );
    }
    return _backdrop;
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
      // 调色板/强度变化必须重新烘焙，否则会继续贴旧位图。
      _scheduleAmbienceBake();
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

        final gridPainter = _gridFor();
        final delegate = _delegateFor(
          renderedBands,
          peaks,
          separateGrid: gridPainter != null,
        );
        final bool usesAmbience = _usesAmbience(widget.config.style);
        if (usesAmbience) _ambienceFor(renderedBands);
        final backdropPainter = _backdropFor();

        final bool hasStaticLayer =
            usesAmbience || gridPainter != null || backdropPainter != null;

        // 两层分工：静态层（氛围位图 + 网格基底，允许缓存）在下，
        // 动态层（主视效，willChange 不缓存）在上，层间互不影响缓存命中。
        final paintLayer = LayoutBuilder(
          builder: (context, constraints) {
            final size = constraints.biggest;
            if (size.isFinite && size != _canvasSize) {
              _canvasSize = size;
              _scheduleAmbienceBake();
            }
            return Stack(
              fit: StackFit.expand,
              children: [
                if (hasStaticLayer)
                  RepaintBoundary(
                    child: CustomPaint(
                      isComplex: true,
                      willChange: false,
                      painter: _StaticLayerPainter(
                        ambienceImage: usesAmbience ? _ambienceImage : null,
                        grid: gridPainter,
                        backdrop: backdropPainter,
                      ),
                      child: const SizedBox.expand(),
                    ),
                  ),
                RepaintBoundary(
                  child: CustomPaint(
                    // 主内容每帧都在变：显式告知光栅缓存不要为它保留离屏层，
                    // 否则 30 Hz 变化的全屏 Picture 会在 GPU 侧持续占住大块 Shared 内存。
                    willChange: true,
                    painter: _CompositeVisualizerPainter(
                      mainPainter: delegate,
                      mainTime: delegate is VisualizerTimeAware
                          ? widget.time
                          : null,
                    ),
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            );
          },
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
