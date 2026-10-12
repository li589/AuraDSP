/*
 * chrome.dart — 页面骨架 + 氛围层 + 自定义控件
 *
 * 三件事：
 *   1. 布局：PageScaffold 统一页面留白（8pt 网格 + 内容区最大宽居中），
 *      保证「组件 ↔ 外框」的留白处处一致；PageHeader 统一页面层级入口。
 *   2. 氛围：AmbientSpectrum（频谱即背景光源，低不透明度单色）+ Grain 细噪点，
 *      只在负空间可见——卡片是不透明面板，不会被糊掉。
 *   3. 动效：交错入场（一次编排的页面加载）、PulseDot 呼吸、AuraSwitch/
 *      AuraSegmented/AuraChip 的即时按压与滑动反馈。
 */
import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart'
    show ValueListenable, visibleForTesting;
import 'package:flutter/material.dart';

import 'package:flutter/scheduler.dart';

import '../core/design.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';
import '../engine/auradsp_ffi.dart' show VizBands;

/* ==================== 1. 页面骨架 ==================== */

class PageScaffold extends StatefulWidget {
  /// 眉标（等宽小字）——六页架构后默认不传（去小标题设计）
  final String? eyebrow;

  /// 页面主标题
  final String title;

  /// 标题右侧动作区
  final Widget? trailing;

  /// 卡片序列（PageScaffold 负责间距与交错入场）
  final List<Widget> children;

  /// 氛围频谱数据源；为 null 则该页无氛围层
  final ValueListenable<List<double>>? ambient;

  /// 内容区最大宽度（null 时按断点自适应：mobile 480 / tablet 720 / desktop 1080）
  final double? maxWidth;

  const PageScaffold({
    super.key,
    this.eyebrow,
    required this.title,
    required this.children,
    this.trailing,
    this.ambient,
    this.maxWidth,
  });

  @override
  State<PageScaffold> createState() => _PageScaffoldState();
}

class _PageScaffoldState extends State<PageScaffold>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: AuraDur.staggerSpan,
  );

  @override
  void initState() {
    super.initState();
    final reduce = WidgetsBinding.instance.platformDispatcher
            .accessibilityFeatures.disableAnimations ==
        true;
    if (reduce) {
      _c.value = 1.0;
    } else {
      _c.forward();
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  Widget _reveal(int i, Widget child) {
    final start = (i * 0.075).clamp(0.0, 0.42);
    final anim = CurvedAnimation(
      parent: _c,
      curve: Interval(start, (start + 0.58).clamp(0.0, 1.0),
          curve: AuraCurve.entrance),
    );
    return AnimatedBuilder(
      animation: anim,
      builder: (_, c) => Opacity(
        opacity: anim.value,
        child: Transform.translate(
          offset: Offset(0, (1 - anim.value) * 14),
          child: c,
        ),
      ),
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final body = <Widget>[];
    for (var i = 0; i < widget.children.length; i++) {
      if (i > 0) body.add(const SizedBox(height: AuraSpace.cardGap));
      body.add(_reveal(i, widget.children[i]));
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        if (widget.ambient != null)
          AmbientSpectrum(spectrum: widget.ambient!, palette: p),
        if (p.isDark) const GrainOverlay(),
        SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
              context.responsivePageX, AuraSpace.pageTop,
              context.responsivePageX, AuraSpace.pageBottom),
          child: Center(
            heightFactor: 1.0,
            child: ConstrainedBox(
              constraints:
                  BoxConstraints(maxWidth: widget.maxWidth ?? context.responsiveMaxW),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (widget.eyebrow != null)
                    PageHeader(
                      eyebrow: widget.eyebrow!,
                      title: widget.title,
                      trailing: widget.trailing,
                    )
                  else
                    PageHeader(
                      eyebrow: '',
                      title: widget.title,
                      trailing: widget.trailing,
                      bare: true,
                    ),
                  const SizedBox(height: AuraSpace.xl),
                  ...body,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class PageHeader extends StatelessWidget {
  final String eyebrow;
  final String title;
  final Widget? trailing;

  /// bare=true：无眉标模式（六页架构）——标题字号提升，保留分隔线
  final bool bare;
  const PageHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.trailing,
    this.bare = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    if (bare) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: displayOf(p, size: 30)),
          const SizedBox(height: AuraSpace.md),
          Row(
            children: [
              Container(
                width: 22,
                height: 2,
                decoration: BoxDecoration(
                  color: p.accent,
                  borderRadius: BorderRadius.circular(1),
                ),
              ),
              const SizedBox(width: AuraSpace.sm),
              Expanded(child: Container(height: 1, color: p.hairline)),
            ],
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(eyebrow, style: eyebrowOf(p)),
                  const SizedBox(height: AuraSpace.sm),
                  Text(title, style: displayOf(p, size: 26)),
                ],
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: AuraSpace.lg),
              Padding(
                padding: const EdgeInsets.only(bottom: AuraSpace.xxs),
                child: trailing!,
              ),
            ],
          ],
        ),
        const SizedBox(height: AuraSpace.md),
        // 标题下的分隔线：左端一小段强调色，指向内容起点
        Row(
          children: [
            Container(
              width: 22,
              height: 2,
              decoration: BoxDecoration(
                color: p.accent,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
            const SizedBox(width: AuraSpace.sm),
            Expanded(child: Container(height: 1, color: p.hairline)),
          ],
        ),
      ],
    );
  }
}

/* ==================== 2. 氛围层 ==================== */

/// 频谱氛围背景：把实时频谱当作界面的「氛围光源」，低不透明度、单色化。
/// 卡片是不透明面板，因此氛围只在留白与卡片间隙中透出。
class AmbientSpectrum extends StatefulWidget {
  final ValueListenable<List<double>> spectrum;
  final AuraPalette palette;
  const AmbientSpectrum({
    super.key,
    required this.spectrum,
    required this.palette,
  });

  @override
  State<AmbientSpectrum> createState() => _AmbientSpectrumState();
}

class _AmbientSpectrumState extends State<AmbientSpectrum>
    with SingleTickerProviderStateMixin {
  /// 驱动 painter 重绘的时钟。音频停止后引擎不再产出 viz 帧，
  /// 而 painter 的 repaint 原本只挂在 spectrum 上 → 画面定格在最后一帧。
  /// 由看门狗在「无新帧」时拨动它，配合 painter 内部的快速衰减归零。
  final ValueNotifier<int> _clock = ValueNotifier<int>(0);

  late _AmbientPainter _painter = _AmbientPainter(
    spectrum: widget.spectrum,
    palette: widget.palette,
    clock: _clock,
  );

  Ticker? _watchdog;
  int _lastFrameMs = DateTime.now().millisecondsSinceEpoch;

  /// 超过该时长没有新频谱帧即判定为「无信号」（音频停止/欠载）。
  static const _staleMs = 200;

  @override
  void initState() {
    super.initState();
    widget.spectrum.addListener(_onFrame);
  }

  /// 看门狗只在「有东西可能变陈旧」时跑：柱子已全部归零则完全不占用帧回调。
  void _ensureTicking() {
    _watchdog ??= createTicker(_onTick)..start();
  }

  void _stopTicking() {
    _watchdog?.stop();
    _watchdog?.dispose();
    _watchdog = null;
  }

  void _onFrame() {
    _lastFrameMs = DateTime.now().millisecondsSinceEpoch;
    // 恢复真实信号：下一帧 paint 会重新按 spectrum 重采样。
    _painter.clearStale();
    _ensureTicking();
  }

  void _onTick(Duration _) {
    final idle = DateTime.now().millisecondsSinceEpoch - _lastFrameMs;
    if (idle < _staleMs) {
      // 仍有信号；但若柱子已全平，也无需继续监视。
      if (_painter.maxValue <= 0) _stopTicking();
      return;
    }
    // stale 期间不再吃陈旧的 spectrum 值（否则会被重新抬高、永不归零），
    // 只做快速衰减；返回 false 表示已衰减干净，停表。
    if (_painter.decayStale()) {
      _clock.value++;
    } else {
      _stopTicking();
    }
  }

  @override
  void didUpdateWidget(AmbientSpectrum old) {
    super.didUpdateWidget(old);
    if (widget.palette != old.palette) {
      // 换主题时换 painter 实例以触发重绘，同时保留平滑缓冲
      _painter.dispose();
      _painter = _painter.withPalette(widget.palette, clock: _clock);
    }
  }

  @override
  void dispose() {
    _stopTicking();
    widget.spectrum.removeListener(_onFrame);
    _clock.dispose();
    _painter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(painter: _painter, child: const SizedBox.expand()),
        ),
      );
}

/// 氛围频谱包络：32 带引擎频谱 → 72 根氛围条的重采样 + 攻击/释放平滑 +
/// 无信号期快速衰减。独立成类以便单测直接断言「音频停止后归零」。
class AmbientEnvelope {
  static const int bars = 72;
  static const double release = 0.82;     // 有信号时的释放系数
  static const double staleDecay = 0.70;  // 无信号时的快速衰减
  static const double epsilon = 0.0008;

  /// 氛围柱的频率覆盖范围（对数均分到 [focusMinHz, focusMaxHz]）。
  ///
  /// 原本铺满 20Hz–20kHz，但两端几乎是空的：72 根柱里约 13 根落在 80Hz
  /// 以下、约 9 根落在 14kHz 以上，对绝大多数音乐内容都是空柱，真正有
  /// 信息的全挤在中段。后端又只有 32 个频带，于是等于把有限分辨率
  /// 平均摊给了两根空区间。把 72 根柱集中到 80Hz–14kHz，是把密度花在
  /// 真正有内容的地方（柱形密度不变，仍是 72 根）。
  static const double focusMinHz = 80.0;
  static const double focusMaxHz = 14000.0;

  /// 每根氛围柱对应的源频带下标。**只算一次**。
  ///
  /// 原实现在 [feed] 里对 72 根柱各调一次 `VizBands.sampleIndex`
  /// （内含 log），而 feed 随频谱帧以 30Hz 被调用 → 2160 次 log/s，
  /// 产出的结果却和上一帧完全相同。表格化后降到 0。
  static final List<int> _srcBand = List<int>.generate(bars, (i) {
    final hz =
        focusMinHz * math.pow(focusMaxHz / focusMinHz, i / (bars - 1));
    return VizBands.sampleIndex(VizBands.logX(hz))
        .round()
        .clamp(0, VizBands.count - 1);
  });

  @visibleForTesting
  static List<int> get sourceBands => _srcBand;

  final List<double> smooth = List.filled(bars, 0);

  /// 无信号（音频停止/欠载）状态。为 true 时不再重采样陈旧数据——
  /// 否则最后一帧的高值会把 smooth 反复抬回去，永远不归零。
  bool stale = false;

  /// 喂入一帧真实频谱（32 带）。按 [focusMinHz]–[focusMaxHz] 的对数刻度
  /// 重采样；旧实现用 pow(t, 1.6) 幂律，会把低频拉宽、高频压扁。
  void feed(List<double> src) {
    stale = false;
    if (src.isEmpty) return;
    final last = src.length - 1;
    for (var i = 0; i < bars; i++) {
      final b = _srcBand[i] < last ? _srcBand[i] : last;
      final v = src[b].clamp(0.0, 1.0);
      smooth[i] = math.max(v, smooth[i] * release);
    }
  }

  /// 无信号期：只做衰减，不吃陈旧数据。返回是否仍有残留（false=已归零）。
  bool decay() {
    stale = true;
    var any = false;
    for (var i = 0; i < bars; i++) {
      if (smooth[i] > epsilon) {
        smooth[i] *= staleDecay;
        any = true;
      } else {
        smooth[i] = 0;
      }
    }
    return any;
  }

  double get maxValue => smooth.fold<double>(0.0, math.max);
}

class _AmbientPainter extends CustomPainter {
  final ValueListenable<List<double>> spectrum;
  final AuraPalette palette;
  final ValueListenable<int> clock;
  final AmbientEnvelope _env = AmbientEnvelope();

  /// 低分图缓存：把 72 根柱子画进一张约 1/10 分辨率的离屏图，再放大绘制。
  /// 放大自带双线性平滑（等价于廉价模糊），彻底移除原来「每柱一次
  /// MaskFilter.blur」的写法——那是 72 次高斯模糊/帧，Windows/D3D11 下每次
  /// 模糊都倾向分配离屏渲染目标，直接导致 GPU ~70%、内存锯齿尖峰。
  /// 低分图重渲染节流到 ~15fps，尺寸仅约 140×90，开销可忽略。
  ui.Image? _img;
  bool _rendering = false;
  bool _disposed = false;
  int _lastRenderMs = 0;
  static const _renderIntervalMs = 66;

  /// 手上这张图是不是从「全零包络」渲染出来的。
  ///
  /// 静音间隙（曲子中间的空白、欠载）里引擎照样产帧，包络却恒为 0，
  /// 于是每 66ms 仍然要走一遍 PictureRecorder→toImage——那是异步 GPU
  /// 光栅化，外加一次新建 + 释放 ui.Image 纹理，画出来的却是一张全黑图。
  /// 记下这张图的「静默」属性后，同为静默就直接复用，不再重复光栅。
  bool _renderedSilent = false;

  _AmbientPainter({
    required this.spectrum,
    required this.palette,
    required this.clock,
  }) : super(repaint: Listenable.merge([spectrum, clock]));

  _AmbientPainter withPalette(AuraPalette p,
      {required ValueListenable<int> clock}) {
    final n = _AmbientPainter(spectrum: spectrum, palette: p, clock: clock);
    for (var i = 0; i < AmbientEnvelope.bars; i++) {
      n._env.smooth[i] = _env.smooth[i];
    }
    return n;
  }

  void clearStale() => _env.stale = false;

  double get maxValue => _env.maxValue;

  /// 无信号期衰减；返回是否仍有残留（false = 已衰减干净，可停止看门狗）。
  bool decayStale() {
    final any = _env.decay();
    // 强制下一次 paint 重建低分图，否则画布仍是衰减前的旧图。
    _lastRenderMs = 0;
    return any;
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (_env.stale) {
      // 无信号：只衰减，不重采样陈旧数据（否则被最后一帧抬回、永不归零）。
      _env.decay();
    } else {
      _env.feed(spectrum.value);
    }

    // 节流重渲染低分图；绘制始终走缓存图。
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_img == null || now - _lastRenderMs >= _renderIntervalMs) {
      final silent = _env.maxValue <= AmbientEnvelope.epsilon;
      // 首帧必须出图；之后只有「静默状态发生变化」才值得再光栅一次。
      if (_img == null || silent != _renderedSilent) {
        _lastRenderMs = now;
        _renderedSilent = silent;
        unawaited(_rerender(size));
      }
    }

    final img = _img;
    if (img == null) return; // 首帧尚未就绪，跳过；下一帧（≈33ms）即可用
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Offset.zero & size,
      // 双线性放大：把低分图的硬边平滑成光晕，替代 MaskFilter.blur
      Paint()..filterQuality = FilterQuality.medium,
    );
  }

  void _drawBars(Canvas canvas, Size size) {
    final peak = math.max(0.35, _env.maxValue);
    final intensity = palette.isDark ? 1.0 : 0.45;
    final baseAlpha = (0.16 * intensity * 255).round();
    final bw = size.width / AmbientEnvelope.bars;

    // 画笔 / 渐变 / 两种颜色都只建一次：原实现每根柱都新建一个 Paint、
    // 调两次 Color.withValues、再 new 一个 LinearGradient，一次重渲染
    // 最多 216 个短命对象。渐变本身与柱无关（只有绑定它的 rect 变），
    // 所以渐变对象也能复用，只保留每柱必要的 createShader。
    final paint = Paint();
    final grad = LinearGradient(
      begin: Alignment.bottomCenter,
      end: Alignment.topCenter,
      colors: [
        palette.accent.withValues(alpha: baseAlpha / 255),
        palette.accent.withValues(alpha: 0),
      ],
    );

    for (var i = 0; i < AmbientEnvelope.bars; i++) {
      final v = (_env.smooth[i] / peak).clamp(0.0, 1.0);
      if (v < 0.02) continue;
      final h = v * size.height * 0.92;
      final rect = Rect.fromLTWH(i * bw, size.height - h, bw * 0.62, h);
      paint.shader = grad.createShader(rect);
      canvas.drawRect(rect, paint);
    }
  }

  Future<void> _rerender(Size target) async {
    if (_rendering || _disposed) return;
    _rendering = true;
    try {
      final lw = math.max(72.0, target.width / 10);
      final lh = math.max(48.0, target.height / 10);
      final recorder = ui.PictureRecorder();
      final c = Canvas(recorder, Rect.fromLTWH(0, 0, lw, lh));
      _drawBars(c, Size(lw, lh));
      final pic = recorder.endRecording();
      final img = await pic.toImage(lw.round(), lh.round());
      pic.dispose();
      if (_disposed) {
        img.dispose();
        return;
      }
      final old = _img;
      _img = img;
      old?.dispose();
    } catch (_) {
      // 渲染失败不致命：下一帧重试
    } finally {
      _rendering = false;
    }
  }

  @override
  bool shouldRepaint(_AmbientPainter old) => old.palette != palette;

  void dispose() {
    _disposed = true;
    _img?.dispose();
    _img = null;
  }
}

/// 程序化细噪点：给大面积纯色底加一层"物质感"，非贴图、可复现。
class GrainOverlay extends StatelessWidget {
  const GrainOverlay({super.key});

  static final List<Offset> _pts = _seed();

  static List<Offset> _seed() {
    final r = math.Random(20261009);
    return List.generate(2200, (_) => Offset(r.nextDouble(), r.nextDouble()));
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(painter: const _GrainPainter(), child: const SizedBox.expand()),
        ),
      );
}

class _GrainPainter extends CustomPainter {
  const _GrainPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()..color = const Color(0xFFFFFFFF).withValues(alpha: 0.022);
    for (final o in GrainOverlay._pts) {
      canvas.drawRect(
        Rect.fromLTWH(o.dx * size.width, o.dy * size.height, 1, 1),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_GrainPainter old) => false;
}

/* ==================== 3. 动效组件 ==================== */

/// 呼吸圆点：处理中时不间断脉动，是「引擎活着」的最小信号
class PulseDot extends StatefulWidget {
  final Color color;
  final bool active;
  final double size;
  const PulseDot({
    super.key,
    required this.color,
    required this.active,
    this.size = 6,
  });

  @override
  State<PulseDot> createState() => _PulseDotState();
}

class _PulseDotState extends State<PulseDot>
    with SingleTickerProviderStateMixin {
  late final AnimationController _c = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1150),
  );

  @override
  void initState() {
    super.initState();
    if (widget.active) _c.repeat();
  }

  @override
  void didUpdateWidget(PulseDot old) {
    super.didUpdateWidget(old);
    if (widget.active && !_c.isAnimating) {
      _c.repeat();
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
      _c.animateTo(0.35, duration: AuraDur.fast);
    }
  }

  @override
  void dispose() {
    _c.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => SizedBox(
        width: widget.size * 2.6,
        height: widget.size * 2.6,
        child: AnimatedBuilder(
          animation: _c,
          builder: (_, _) {
            final t = Curves.easeInOut.transform(_c.value);
            return Stack(
              alignment: Alignment.center,
              children: [
                // 光晕
                Container(
                  width: widget.size + t * widget.size * 1.5,
                  height: widget.size + t * widget.size * 1.5,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color.withValues(alpha: 0.30 * (1 - t)),
                  ),
                ),
                Container(
                  width: widget.size,
                  height: widget.size,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: widget.color,
                  ),
                ),
              ],
            );
          },
        ),
      );
}

/* ==================== 4. 自定义控件 ==================== */

/// 紧凑开关：尺寸固定 38×22（8pt 网格内），滑动有明确反馈
class AuraSwitch extends StatelessWidget {
  final bool value;
  final ValueChanged<bool>? onChanged;
  const AuraSwitch({super.key, required this.value, this.onChanged});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final enabled = onChanged != null;
    final track = value
        ? (enabled ? p.accent : p.accent.withValues(alpha: 0.4))
        : p.hairline;
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: enabled ? () => onChanged!(!value) : null,
        child: Padding(
          // 命中区扩展到 40×40（8pt 网格），视觉尺寸仍为 38×22
          padding: const EdgeInsets.symmetric(
              vertical: (40 - AuraSize.switchH) / 2, horizontal: 1),
          child: AnimatedContainer(
            duration: AuraDur.fast,
            curve: AuraCurve.standard,
            width: AuraSize.switchW,
            height: AuraSize.switchH,
            decoration: BoxDecoration(
              color: track,
              borderRadius: BorderRadius.circular(8),
            ),
            child: AnimatedAlign(
              duration: AuraDur.base,
              curve: AuraCurve.emphasized,
              alignment: value ? Alignment.centerRight : Alignment.centerLeft,
              child: Container(
                width: AuraSize.switchThumb,
                height: AuraSize.switchThumb,
                margin: const EdgeInsets.symmetric(horizontal: 3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: value ? p.accentContrast : p.textDim,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class AuraSegment<T> {
  final T value;
  final String label;
  const AuraSegment(this.value, this.label);
}

/// 分段控件：选中态是一枚会滑动的实心块（Material SegmentedButton 尺寸过粗）
class AuraSegmented<T> extends StatelessWidget {
  static const _h = 38.0; // 外高
  static const _pad = 3.0; // 内缩
  final List<AuraSegment<T>> segments;
  final T selected;
  final ValueChanged<T>? onChanged;
  const AuraSegmented({
    super.key,
    required this.segments,
    required this.selected,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final enabled = onChanged != null;
    final n = segments.length;
    final i = segments.indexWhere((s) => s.value == selected);

    return Container(
      height: _h,
      padding: const EdgeInsets.all(_pad),
      decoration: BoxDecoration(
        color: p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      child: LayoutBuilder(
        builder: (ctx, box) {
          final w = box.maxWidth / n;
          return Stack(
            children: [
              if (i >= 0)
                AnimatedAlign(
                  duration: AuraDur.base,
                  curve: AuraCurve.emphasized,
                  alignment: Alignment(n == 1 ? 0.0 : -1 + 2 * i / (n - 1), 0),
                  child: Container(
                    width: w,
                    height: _h - _pad * 2,
                    decoration: BoxDecoration(
                      color: enabled ? p.accent : p.hairline,
                      borderRadius: BorderRadius.circular(AuraRadius.sm - 2),
                    ),
                  ),
                ),
              Row(
                children: [
                  for (var k = 0; k < n; k++)
                    Expanded(
                      child: MouseRegion(
                        cursor: enabled
                            ? SystemMouseCursors.click
                            : SystemMouseCursors.basic,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: enabled
                              ? () => onChanged!(segments[k].value)
                              : null,
                          child: Center(
                            child: AnimatedDefaultTextStyle(
                              duration: AuraDur.fast,
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: k == i
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                                color: k == i
                                    ? (enabled ? p.accentContrast : p.textDim)
                                    : p.textDim,
                              ),
                              child: Text(segments[k].label,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}

/// 标签片：固定高度 30，选中/hover/危险态三态明确
class AuraChip extends StatefulWidget {
  final String label;
  final bool selected;
  final IconData? icon;
  final VoidCallback? onTap;
  final bool danger;
  const AuraChip(
    this.label, {
    super.key,
    this.selected = false,
    this.icon,
    this.onTap,
    this.danger = false,
  });

  @override
  State<AuraChip> createState() => _AuraChipState();
}

class _AuraChipState extends State<AuraChip> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final tint = widget.danger
        ? p.error
        : (widget.selected ? p.accent : p.text);
    final bg = widget.selected
        ? tint.withValues(alpha: 0.14)
        : (_hover ? hoverOn(p) : Colors.transparent);
    final border = widget.selected
        ? tint.withValues(alpha: 0.55)
        : (_hover ? p.textDim.withValues(alpha: 0.45) : p.hairline);

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AuraDur.fast,
          curve: AuraCurve.standard,
          height: AuraSize.chipH,
          padding: const EdgeInsets.symmetric(horizontal: AuraSpace.md),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: border, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (widget.icon != null) ...[
                Icon(widget.icon, size: 14, color: tint),
                const SizedBox(width: AuraSpace.sm - 2),
              ],
              AnimatedDefaultTextStyle(
                duration: AuraDur.fast,
                style: TextStyle(
                  fontSize: 12.5,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w500,
                  fontFamilyFallback: kBodyCjkFallback,
                  letterSpacing: 0.1,
                  color: tint,
                ),
                child: Text(widget.label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/* ==================== 5. 数值读数 ==================== */

/// 等宽数值块：标签在上、数值在下（tabular），用于状态/延迟/设备读数
class StatReadout extends StatelessWidget {
  final String label;
  final String value;
  final String? unit;
  final Color? valueColor;
  final double size;
  const StatReadout({
    super.key,
    required this.label,
    required this.value,
    this.unit,
    this.valueColor,
    this.size = 22,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(label.toUpperCase(), style: eyebrowOf(p)),
        const SizedBox(height: AuraSpace.xs + 2),
        Row(
          crossAxisAlignment: CrossAxisAlignment.baseline,
          textBaseline: TextBaseline.alphabetic,
          children: [
            Text(value,
                style: monoOf(p, size: size, color: valueColor ?? p.text)),
            if (unit != null) ...[
              const SizedBox(width: AuraSpace.xs),
              Text(unit!, style: monoOf(p, size: 11, color: p.textDim)),
            ],
          ],
        ),
      ],
    );
  }
}
