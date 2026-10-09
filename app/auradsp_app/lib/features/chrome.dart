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
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/theme.dart';

/* ==================== 1. 页面骨架 ==================== */

class PageScaffold extends StatefulWidget {
  /// 眉标（等宽小字，如 "CONSOLE" / "DSP CHAIN"）
  final String eyebrow;

  /// 页面主标题
  final String title;

  /// 标题右侧动作区
  final Widget? trailing;

  /// 卡片序列（PageScaffold 负责间距与交错入场）
  final List<Widget> children;

  /// 氛围频谱数据源；为 null 则该页无氛围层
  final ValueListenable<List<double>>? ambient;

  /// 内容区最大宽度（超宽屏居中留白）
  final double maxWidth;

  const PageScaffold({
    super.key,
    required this.eyebrow,
    required this.title,
    required this.children,
    this.trailing,
    this.ambient,
    this.maxWidth = AuraSpace.contentMaxW,
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
          padding: const EdgeInsets.fromLTRB(
              AuraSpace.pageX, AuraSpace.pageTop, AuraSpace.pageX,
              AuraSpace.pageBottom),
          child: Center(
            heightFactor: 1.0,
            child: ConstrainedBox(
              constraints: BoxConstraints(maxWidth: widget.maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  PageHeader(
                    eyebrow: widget.eyebrow,
                    title: widget.title,
                    trailing: widget.trailing,
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
  const PageHeader({
    super.key,
    required this.eyebrow,
    required this.title,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
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
  late _AmbientPainter _painter = _AmbientPainter(
    spectrum: widget.spectrum,
    palette: widget.palette,
  );

  @override
  void didUpdateWidget(AmbientSpectrum old) {
    super.didUpdateWidget(old);
    if (widget.palette != old.palette) {
      // 换主题时换 painter 实例以触发重绘，同时保留平滑缓冲
      _painter = _painter.withPalette(widget.palette);
    }
  }

  @override
  void dispose() {
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

class _AmbientPainter extends CustomPainter {
  static const _bars = 72;
  final ValueListenable<List<double>> spectrum;
  final List<double> _smooth = List.filled(_bars, 0);
  AuraPalette palette;

  _AmbientPainter({required this.spectrum, required this.palette})
      : super(repaint: spectrum);

  _AmbientPainter withPalette(AuraPalette p) {
    final n = _AmbientPainter(spectrum: spectrum, palette: p);
    for (var i = 0; i < _bars; i++) {
      n._smooth[i] = _smooth[i];
    }
    return n;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final src = spectrum.value;
    if (src.isEmpty) return;

    // 取对数频段 + 时间平滑，避免氛围层抖动
    for (var i = 0; i < _bars; i++) {
      final t = i / (_bars - 1);
      final idx = (math.pow(t, 1.6) * (src.length - 1)).round();
      final v = src[idx.clamp(0, src.length - 1)].clamp(0.0, 1.0);
      _smooth[i] = math.max(v, _smooth[i] * 0.82);
    }

    final peak = math.max(0.35, _smooth.reduce(math.max));
    final intensity = palette.isDark ? 1.0 : 0.45;
    final baseAlpha = (0.16 * intensity * 255).round();
    final bw = size.width / _bars;

    for (var i = 0; i < _bars; i++) {
      final v = (_smooth[i] / peak).clamp(0.0, 1.0);
      if (v < 0.02) continue;
      final h = v * size.height * 0.92;
      final rect = Rect.fromLTWH(i * bw, size.height - h, bw * 0.62, h);
      final paint = Paint()
        ..shader = LinearGradient(
          begin: Alignment.bottomCenter,
          end: Alignment.topCenter,
          colors: [
            palette.accent.withValues(alpha: baseAlpha / 255),
            palette.accent.withValues(alpha: 0),
          ],
        ).createShader(rect)
        // 高斯模糊：氛围层只做"光"，不做"形"，虚化后不与前景内容抢细节
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7);
      canvas.drawRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(_AmbientPainter old) => old.palette != palette;

  void dispose() {}
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
                      widget.selected ? FontWeight.w700 : FontWeight.w500,
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
