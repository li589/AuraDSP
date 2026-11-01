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

import '../core/debug/debug_trace.dart';
import '../core/design.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';
import '../platform/adapters.dart';
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
  final HelpVisibilityController _helpController = HelpVisibilityController();

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
    _helpController.dispose();
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
      // 每张卡片独立图层（2026-10-29）：入场时 Opacity 只混合缓存纹理，
      // 不逐帧重绘卡片；滚动时整列位移只做图层合成，不再重画所有卡片
      // 的圆角/描边/阴影（此前 SingleChildScrollView 单列无边界，滚动
      // 每帧重绘整页内容，是滚动 GPU 峰值的主因）。
      child: RepaintBoundary(child: child),
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

    return HelpVisibilityScope(
      controller: _helpController,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (widget.ambient != null)
            AmbientSpectrum(spectrum: widget.ambient!, palette: p),
          if (p.isDark) const GrainOverlay(),
          NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              if (notification is ScrollUpdateNotification ||
                  notification is UserScrollNotification ||
                  notification is ScrollStartNotification) {
                _helpController.recordScroll();
              }
              return false;
            },
            child: SingleChildScrollView(
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
          ),
        ],
      ),
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

class _AmbientSpectrumState extends State<AmbientSpectrum> {
  // 仅在需要时拨动：painter 的 repaint 只挂 _clock（不再直接挂 spectrum）。
  // 由本 state 在 spectrum 帧到达时节流到 ~20fps 拨一次；无信号期由
  // stale 衰减 Timer 拨动。彻底移除原来的常驻 60fps Ticker——它在有信号时
  // 不做任何有效工作却持续 force-schedule 帧，是后台 GPU/CPU 占用的主因。
  final ValueNotifier<int> _clock = ValueNotifier<int>(0);

  late _AmbientPainter _painter = _AmbientPainter(
    spectrum: widget.spectrum,
    palette: widget.palette,
    clock: _clock,
  );

  // 页面是否处于可见栈位（IndexedStack 离屏页 TickerMode=false）。
  // 据此摘除 spectrum 订阅与一切 Timer，离屏页不再因 30fps 帧调度占用。
  bool _pageActive = true;

  // spectrum 帧节流：paint 间隔下限。把全屏雾化 blit 从 30fps 降到 20fps，
  // 视觉几乎无差（氛围层低不透明度 + 柱体攻击/释放本就迟钝），GPU 全屏
  // 纹理上传/合成开销直接砍 1/3。
  static const _paintIntervalMs = 50; // 20fps
  int _lastPaintMs = 0;

  // 无信号判定与衰减：帧停滞后 _staleMs 触发一次性 stale，随后 _decayTimer
  // 以 ~30fps 步进衰减直到柱体归零即停。有信号期这两个 Timer 都不持有，
  // 也不占用任何帧回调。
  static const _staleMs = 200;
  static const _decayIntervalMs = 33;
  Timer? _staleTimer;
  Timer? _decayTimer;
  int _lastFrameMs = DateTime.now().millisecondsSinceEpoch;

  bool get _effective =>
      _pageActive && PlatformAdapters.instance.window.isVisible;

  @override
  void initState() {
    super.initState();
    widget.spectrum.addListener(_onFrame);
    PlatformAdapters.instance.window.visibleListenable.addListener(_onVisibilityChanged);
    // 首帧到达前也可能已有历史值（切页回来），先武装一次无信号检测。
    _armStaleTimer();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final active = TickerMode.valuesOf(context).enabled;
    if (_pageActive != active) {
      _pageActive = active;
      _syncSubscription();
    }
  }

  void _onVisibilityChanged() => _syncSubscription();

  /// 按可见性挂/摘 stale 监视 Timer。spectrum 监听始终挂着（离屏时
  /// _onFrame 早退，零开销且不调度帧）。
  void _syncSubscription() {
    if (_effective) {
      _armStaleTimer();
      // 回页/窗口恢复时补一次重绘：离屏期间保留的是最后一帧位图，
      // 若期间柱子未归零且没有新帧，这里主动拨钟让画面立即刷新。
      if (_painter.maxValue > AmbientEnvelope.epsilon) _clock.value++;
    } else {
      _staleTimer?.cancel();
      _staleTimer = null;
      _decayTimer?.cancel();
      _decayTimer = null;
    }
  }

  void _onFrame() {
    if (!_effective) return;
    _lastFrameMs = DateTime.now().millisecondsSinceEpoch;
    // 恢复真实信号：paint 时重新按 spectrum 重采样。
    _painter.clearStale();
    // 有新帧：停掉可能正在跑的衰减循环。
    _decayTimer?.cancel();
    _decayTimer = null;
    _armStaleTimer();
    // 节流 repaint：距上次 paint ≥ _paintIntervalMs 才拨动 _clock。
    if (_lastFrameMs - _lastPaintMs >= _paintIntervalMs) {
      _lastPaintMs = _lastFrameMs;
      _clock.value++;
    }
  }

  /// 幂等武装：已武装则不重建 Timer。有信号期每 200ms 才需要一个
  /// Timer 到期回调，避免每帧 create/cancel 的分配抖动。
  void _armStaleTimer() {
    if (_staleTimer?.isActive ?? false) return;
    _staleTimer = Timer(const Duration(milliseconds: _staleMs), _onStale);
  }

  void _onStale() {
    if (!_effective) return;
    // 到期时仍有新帧（Timer 武装后帧又刷新过）→ 继续等下一轮。
    final idle = DateTime.now().millisecondsSinceEpoch - _lastFrameMs;
    if (idle < _staleMs) {
      _armStaleTimer();
      return;
    }
    // 进入无信号期：周期性衰减直到柱体归零。
    _decayTimer?.cancel();
    _decayTimer =
        Timer.periodic(const Duration(milliseconds: _decayIntervalMs), _onDecay);
  }

  void _onDecay(Timer _) {
    if (!_effective) {
      _decayTimer?.cancel();
      _decayTimer = null;
      return;
    }
    if (_painter.decayStale()) {
      _clock.value++;
    } else {
      _decayTimer?.cancel();
      _decayTimer = null;
    }
  }

  @override
  void didUpdateWidget(AmbientSpectrum old) {
    super.didUpdateWidget(old);
    if (widget.spectrum != old.spectrum) {
      old.spectrum.removeListener(_onFrame);
      widget.spectrum.addListener(_onFrame);
    }
    if (widget.palette != old.palette) {
      // 换主题时换 painter 实例以触发重绘，同时保留平滑缓冲
      _painter.dispose();
      _painter = _painter.withPalette(widget.palette, clock: _clock);
    }
  }

  @override
  void dispose() {
    PlatformAdapters.instance.window.visibleListenable.removeListener(_onVisibilityChanged);
    _staleTimer?.cancel();
    _decayTimer?.cancel();
    widget.spectrum.removeListener(_onFrame);
    _clock.dispose();
    _painter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => IgnorePointer(
        child: RepaintBoundary(
          child: CustomPaint(
              painter: _painter, child: const SizedBox.expand()),
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

  /// 双线性放大画笔（固定 medium 滤波，通过低分图双线性放大实现纯正高斯状雾化光晕）
  final Paint _blitPaint = Paint()..filterQuality = FilterQuality.medium;

  /// 单复用柱体画笔
  final Paint _barPaint = Paint();

  /// 柱体渐变 shader：整幅离屏图共用一份（旧实现每根柱每帧新建
  /// `ui.Gradient.linear` → 72 个/帧 × 20fps 的 Skia 原生分配）。
  ui.Shader? _barShader;

  /// 同步小图双缓冲句柄（严格单实例轮替，零异步跨帧，杜绝 UAF 悬挂指针）
  ui.Image? _lastImg;

  _AmbientPainter({
    required this.spectrum,
    required this.palette,
    required this.clock,
  }) : super(repaint: clock);

  _AmbientPainter withPalette(AuraPalette p,
      {required ValueListenable<int> clock}) {
    final n = _AmbientPainter(spectrum: spectrum, palette: p, clock: clock);
    for (var i = 0; i < AmbientEnvelope.bars; i++) {
      n._env.smooth[i] = _env.smooth[i];
    }
    // 2026-10-31：把上一帧小图的所有权转交给新 painter。旧实现两个实例
    // 各自持有同一张图却不释放前者的引用，换主题时遗留一张未 dispose 的 GPU 小图。
    n._lastImg = _lastImg;
    _lastImg = null;
    return n;
  }

  void clearStale() => _env.stale = false;

  double get maxValue => _env.maxValue;

  /// 无信号期衰减；返回是否仍有残留（false = 已衰减干净，可停止看门狗）。
  bool decayStale() {
    return _env.decay();
  }

  @override
  void paint(Canvas canvas, Size size) {
    if (!PlatformAdapters.instance.window.isVisible) return;
    if (_env.stale) {
      // 无信号：只衰减，不重采样陈旧数据
      _env.decay();
    } else {
      _env.feed(spectrum.value);
    }

    if (_env.maxValue <= AmbientEnvelope.epsilon) {
      // 静音期无须光栅化任何内容，零 GPU / 显存开销；释放已有小图
      if (_lastImg != null) {
        _lastImg!.dispose();
        _lastImg = null;
      }
      return;
    }

    final peak = math.max(0.35, _env.maxValue);
    final intensity = palette.isDark ? 1.0 : 0.45;
    final baseAlpha = (0.16 * intensity * 255).round();

    // 低分图离屏尺寸：144×90 像素（像素总数 12,960，显存仅约 50KB）
    // 宽 144px 对应 72 根柱子（槽宽 2px：柱宽 1.25px，间距 0.75px）
    // 经双线性插值 10~15 倍放大到全屏后，原本小图硬边被自然平滑为真实的高斯雾化柔和光晕，
    // 完全复原最原始优化前的暗色弥散质感，彻底消除生硬的塑料外层框与假地平线。
    const lw = 144.0;
    const lh = 90.0;
    const bars = AmbientEnvelope.bars;
    const bw = lw / bars;

    final recorder = ui.PictureRecorder();
    final c = Canvas(recorder, const Rect.fromLTWH(0, 0, lw, lh));

    // 整幅离屏图共用一份垂直渐隐 shader：柱体越矮只用到渐变底部（不透明度
    // 更高），高柱自然淡出顶部，视觉与原逐柱渐变一致，但每帧零 Shader 创建。
    _barShader ??= ui.Gradient.linear(
      Offset(0, lh),
      Offset(0, 0),
      [
        palette.accent.withValues(alpha: baseAlpha / 255),
        palette.accent.withValues(alpha: 0.0),
      ],
    );
    _barPaint.shader = _barShader;

    // 每根柱子独立从底部至顶部垂直渐隐消融
    for (var i = 0; i < bars; i++) {
      final v = (_env.smooth[i] / peak).clamp(0.0, 1.0);
      if (v < 0.02) continue;
      final h = v * lh * 0.92;
      final rect = Rect.fromLTWH(i * bw, lh - h, bw * 0.62, h);
      c.drawRect(rect, _barPaint);
    }

    final pic = recorder.endRecording();
    final img = pic.toImageSync(144, 90);
    pic.dispose();

    // 双线性平滑放大铺满全屏，呈现深邃自然的原始氛围雾化
    canvas.drawImageRect(
      img,
      const Rect.fromLTWH(0, 0, lw, lh),
      Offset.zero & size,
      _blitPaint,
    );

    // 安全生命周期管理：释放上一帧纹理，保留当前帧直到下一帧完成
    _lastImg?.dispose();
    _lastImg = img;
  }

  @override
  bool shouldRepaint(_AmbientPainter old) => old.palette != palette;

  void dispose() {
    _lastImg?.dispose();
    _lastImg = null;
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
    if (widget.active && PlatformAdapters.instance.window.isVisible) {
      _c.repeat();
    }
    PlatformAdapters.instance.window.visibleListenable.addListener(_onVisibilityChanged);
  }

  void _onVisibilityChanged() {
    if (!PlatformAdapters.instance.window.isVisible) {
      if (_c.isAnimating) _c.stop();
    } else if (widget.active && !_c.isAnimating) {
      _c.repeat();
    }
  }

  @override
  void didUpdateWidget(PulseDot old) {
    super.didUpdateWidget(old);
    final visible = PlatformAdapters.instance.window.isVisible;
    if (widget.active && visible && !_c.isAnimating) {
      _c.repeat();
    } else if (!visible && _c.isAnimating) {
      _c.stop();
      _c.value = 0.35;
    } else if (!widget.active && _c.isAnimating) {
      _c.stop();
      _c.animateTo(0.35, duration: AuraDur.fast);
    }
  }

  @override
  void dispose() {
    PlatformAdapters.instance.window.visibleListenable.removeListener(_onVisibilityChanged);
    _c.dispose();
    super.dispose();
  }

  @override
  // RepaintBoundary（2026-10-29）：呼吸动画 60fps 持续整场播放；此前它没有
  // 独立图层，每帧把最近的整条顶栏/hero 行标脏重绘。加边界后每帧只重绘
  // 这颗 ~16px 圆点，非可视化页面的 GPU 占用回到接近 0。
  Widget build(BuildContext context) => RepaintBoundary(
        child: SizedBox(
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
  final String? tooltip;
  const AuraSegment(this.value, this.label, {this.tooltip});
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
                        child: () {
                          Widget btn = GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onTap: enabled
                                ? () {
                                    DebugTrace.instance.tap(
                                        'segment', segments[k].label);
                                    onChanged!(segments[k].value);
                                  }
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
                          );
                          final tip = segments[k].tooltip;
                          if (tip != null && tip.isNotEmpty) {
                            return Tooltip(
                              message: tip,
                              waitDuration: const Duration(milliseconds: 300),
                              child: btn,
                            );
                          }
                          return btn;
                        }(),
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

  /// 半激活态（Z15「部分旁路」）：插件名义生效但实际被 VB 超预算保护
  /// 旁路该路——warning 醒目但区别于 danger（用户全旁路）与 selected
  /// （完全生效）。视觉权重与 selected 同（底色/描边），仅换警示色。
  final bool warning;

  /// 切换在途：文字替换为受控尺寸的小 spinner（高度锁 chipH，不跳版），
  /// 用于旁路等异步切换的过渡反馈。onTap 应同时置 null 禁点。
  final bool busy;
  const AuraChip(
    this.label, {
    super.key,
    this.selected = false,
    this.icon,
    this.onTap,
    this.danger = false,
    this.busy = false,
    this.warning = false,
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
        : (widget.warning
            ? p.warning
            : (widget.selected ? p.accent : p.text));
    final active = widget.selected || widget.warning;
    final bg = active
        ? tint.withValues(alpha: 0.14)
        : (_hover ? hoverOn(p) : Colors.transparent);
    final border = active
        ? tint.withValues(alpha: 0.55)
        : (_hover ? p.textDim.withValues(alpha: 0.45) : p.hairline);

    return MouseRegion(
      cursor: widget.onTap == null
          ? MouseCursor.defer
          : SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap == null
            ? null
            : () {
                DebugTrace.instance.tap('chip', widget.label);
                widget.onTap!();
              },
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
              AnimatedSwitcher(
                duration: AuraDur.fast,
                switchInCurve: AuraCurve.standard,
                switchOutCurve: AuraCurve.standard,
                transitionBuilder: (child, anim) =>
                    FadeTransition(opacity: anim, child: child),
                child: widget.busy
                    ? SizedBox(
                        key: const ValueKey('busy'),
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          valueColor: AlwaysStoppedAnimation(tint),
                        ),
                      )
                    : AnimatedDefaultTextStyle(
                        key: const ValueKey('label'),
                        duration: AuraDur.fast,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: widget.selected
                              ? FontWeight.w600
                              : FontWeight.w500,
                          fontFamilyFallback: kBodyCjkFallback,
                          letterSpacing: 0.1,
                          color: tint,
                        ),
                        child: Text(widget.label),
                      ),
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
/// 1s 级状态心跳消费者（P0-2，2026-10-23）：把子树重建范围限定在心跳
/// 更新内，不牵动外层粗粒度 `ListenableBuilder(listenable: model)`。
/// 用于 VB/VAIO/ASIO 状态面板（电平表 / 保护行 / 设备读数）。
class HbBuilder extends StatelessWidget {
  final ValueListenable<int> tick;
  final Widget Function(BuildContext) builder;
  const HbBuilder({super.key, required this.tick, required this.builder});

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
        valueListenable: tick,
        builder: (c, _, _) => builder(c),
      );
}

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

/* ==================== 6. 下拉选择器 ==================== */

/// 下拉选择框：契合 Aura 8pt 设计规范，固定高度 30/32，悬浮微动效，
/// 自动适配明暗主题面板色与边框高亮，内置安全去重与无设备留空占位。
class AuraDropdown<T> extends StatefulWidget {
  final T? value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? hint;
  final double height;
  final bool isExpanded;
  final Widget? icon;

  const AuraDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.hint,
    this.height = 32.0,
    this.isExpanded = true,
    this.icon,
  });

  @override
  State<AuraDropdown<T>> createState() => _AuraDropdownState<T>();
}

class _AuraDropdownState<T> extends State<AuraDropdown<T>> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final enabled = widget.onChanged != null && widget.items.isNotEmpty;

    final border = enabled
        ? (_hover ? p.accent.withValues(alpha: 0.6) : p.hairline)
        : p.hairline.withValues(alpha: 0.4);
    final bg = enabled
        ? (_hover ? hoverOn(p) : p.panelRaised.withValues(alpha: 0.75))
        : p.panelRaised.withValues(alpha: 0.35);

    // 1. 无可用项时的留空占位状态
    if (widget.items.isEmpty) {
      return Container(
        height: widget.height,
        padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm + 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(color: border),
        ),
        alignment: Alignment.centerLeft,
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Text(
                widget.hint ?? l10nOf(context).noAvailableDevice,
                style: monoOf(p, size: 12, color: p.textDim),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            Icon(Icons.keyboard_arrow_down_rounded,
                color: p.textDim.withValues(alpha: 0.5), size: 18),
          ],
        ),
      );
    }

    // 2. 去重过滤，防止底层设备枚举出现重复 ID 时 Flutter 断言崩溃
    final uniqueItems = <DropdownMenuItem<T>>[];
    final seen = <T?>{};
    for (final it in widget.items) {
      if (seen.add(it.value)) {
        uniqueItems.add(it);
      }
    }

    // 3. 防御性安全值校验：确保选中的 value 在有效项中
    final effectiveValue = (widget.value != null &&
            uniqueItems.any((it) => it.value == widget.value))
        ? widget.value
        : (uniqueItems.isNotEmpty ? uniqueItems.first.value : null);

    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: AnimatedContainer(
        duration: AuraDur.fast,
        curve: AuraCurve.standard,
        height: widget.height,
        padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm + 2),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(color: border),
        ),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<T>(
            value: effectiveValue,
            items: uniqueItems,
            onChanged: enabled
                ? (v) {
                    DebugTrace.instance
                        .tap('dropdown', '${widget.value ?? '-'} -> $v');
                    widget.onChanged!(v);
                  }
                : null,
            isDense: true,
            isExpanded: widget.isExpanded,
            dropdownColor: p.panelRaised,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            style: labelOf(p),
            icon: widget.icon ??
                Icon(
                  Icons.keyboard_arrow_down_rounded,
                  color: enabled ? p.accent : p.textDim,
                  size: 18,
                ),
          ),
        ),
      ),
    );
  }
}
