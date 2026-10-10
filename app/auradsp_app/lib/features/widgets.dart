/*
 * widgets.dart — 共享 UI 组件（设计系统 §7 落地件）
 *
 * - 频谱/电平全部 CustomPaint 自绘，60fps 由 RepaintBoundary 隔离
 * - SectionCard 统一「卡片内边距 / 标题→内容间距」，是所有留白一致性的落点
 * - 徽标三态明示（处理中/旁路/失效）+ 等宽延迟读数 + 呼吸点
 */
import 'dart:math' as math;

import 'package:auradsp_app/l10n/gen/app_localizations.dart';
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';

/* ---- 区块卡片 ---- */

class SectionCard extends StatelessWidget {
  final Widget child;
  final EdgeInsets? padding;

  /// 卡片标题（含时自动带上「标题 → 内容」统一间距）
  final String? title;

  /// 分区序号（"01"），等宽强调色
  final String? index;

  /// 标题下的辅助说明
  final String? hint;

  /// 标题右侧动作区
  final Widget? trailing;

  /// hero 卡片：更大内边距 + 强调色细边
  final bool hero;

  /// 组件级微型延迟（ms）：非空时在 trailing 开关前渲染 [ 0.0 ms ↻ ] 徽标
  final double? latencyMs;
  final VoidCallback? onRefreshLatency;
  final int latencyTick;

  const SectionCard({
    super.key,
    required this.child,
    this.padding,
    this.title,
    this.index,
    this.hint,
    this.trailing,
    this.hero = false,
    this.latencyMs,
    this.onRefreshLatency,
    this.latencyTick = 0,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final body = <Widget>[];
    if (title != null) {
      final effectiveTrailing = (latencyMs != null)
          ? Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                ComponentLatencyBadge(
                  latencyMs: latencyMs!,
                  onRefresh: onRefreshLatency,
                  refreshTick: latencyTick,
                ),
                if (trailing != null) ...[
                  const SizedBox(width: AuraSpace.sm),
                  trailing!,
                ],
              ],
            )
          : trailing;
      body.add(SectionTitle(title!, index: index, trailing: effectiveTrailing));
      if (hint != null) {
        body.add(const SizedBox(height: AuraSpace.sm));
        body.add(Text(hint!, style: captionOf(p)));
      }
      body.add(const SizedBox(height: AuraSpace.cardHeadGap));
    }
    body.add(child);

    return Container(
      padding: padding ??
          EdgeInsets.all(hero ? AuraSpace.xl : AuraSpace.cardPad),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.md),
        border: Border.all(
          color: hero ? p.accent.withValues(alpha: 0.28) : p.hairline,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: body,
      ),
    );
  }
}

class SectionTitle extends StatelessWidget {
  final String text;
  final String? index;
  final Widget? trailing;
  const SectionTitle(this.text, {super.key, this.index, this.trailing});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (index != null) ...[
          Text(index!, style: monoOf(p, size: 11, color: p.accent)),
          const SizedBox(width: AuraSpace.sm + 2),
        ] else ...[
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: p.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
        ],
        Expanded(child: Text(text, style: sectionOf(p))),
        if (trailing != null) ...[
          const SizedBox(width: AuraSpace.md),
          trailing!,
        ],
      ],
    );
  }
}

/* ---- 状态徽标 ---- */

class StateBadge extends StatelessWidget {
  final int engineState;
  final bool playing;
  const StateBadge({super.key, required this.engineState, required this.playing});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final (text, color) = switch (engineState) {
      2 => (l.stateError, p.error),
      0 => (l.stateBypass, p.textDim),
      _ => playing
          ? (l.stateProcessing, p.success)
          : (l.stateBypass, p.textDim),
    };
    return Container(
      padding: const EdgeInsets.symmetric(
          horizontal: AuraSpace.md, vertical: AuraSpace.sm - 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: color.withValues(alpha: 0.5), width: 1),
      ),
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        PulseDot(color: color, active: engineState == 1 && playing),
        const SizedBox(width: AuraSpace.sm - 2),
        Text(text,
            style: TextStyle(
                fontSize: 12, color: color, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class LatencyBadge extends StatelessWidget {
  final double ms;
  const LatencyBadge({super.key, required this.ms});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final c = latencyColor(ms, p);
    final l = l10nOf(context);
    return Tooltip(
      message: l.latencyTip,
      waitDuration: const Duration(milliseconds: 350),
      child: Container(
        padding: const EdgeInsets.symmetric(
            horizontal: AuraSpace.md, vertical: AuraSpace.sm - 2),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(AuraRadius.sm),
          border: Border.all(color: p.hairline, width: 1),
        ),
        child: Text(l.latencyMs(ms.round()),
            style: monoOf(p, size: 12, color: c)),
      ),
    );
  }
}

/// 组件级微型延迟徽标：[ 0.0 ms  ↻ ]
class ComponentLatencyBadge extends StatefulWidget {
  final double latencyMs;
  final VoidCallback? onRefresh;
  final int refreshTick;

  const ComponentLatencyBadge({
    super.key,
    required this.latencyMs,
    this.onRefresh,
    this.refreshTick = 0,
  });

  @override
  State<ComponentLatencyBadge> createState() => _ComponentLatencyBadgeState();
}

class _ComponentLatencyBadgeState extends State<ComponentLatencyBadge>
    with SingleTickerProviderStateMixin {
  late AnimationController _pulseController;

  @override
  void initState() {
    super.initState();
    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );
  }

  @override
  void didUpdateWidget(covariant ComponentLatencyBadge oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.refreshTick != oldWidget.refreshTick) {
      _pulseController.forward(from: 0.0);
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final text = '${widget.latencyMs.toStringAsFixed(1)} ms';
    return AnimatedBuilder(
      animation: _pulseController,
      builder: (context, _) {
        final pulse = _pulseController.value;
        final glowAlpha = (math.sin(pulse * math.pi) * 0.45).clamp(0.0, 1.0);
        final borderColor = Color.lerp(
          p.hairline,
          p.accent,
          glowAlpha,
        )!;

        return Tooltip(
          message: '组件实测处理延迟: $text\n点击 ↻ 立即进行单组件延迟探测评估',
          waitDuration: const Duration(milliseconds: 250),
          child: InkWell(
            onTap: () {
              _pulseController.forward(from: 0.0);
              widget.onRefresh?.call();
            },
            borderRadius: BorderRadius.circular(AuraRadius.xs),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.05 + glowAlpha * 0.2),
                borderRadius: BorderRadius.circular(AuraRadius.xs),
                border: Border.all(color: borderColor, width: 1.0),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  Text(
                    text,
                    style: monoOf(
                      p,
                      size: 10,
                      color: widget.latencyMs > 20
                          ? p.warning
                          : (widget.latencyMs > 0 ? p.accent2 : p.textDim),
                    ),
                  ),
                  const SizedBox(width: 3),
                  RotationTransition(
                    turns: _pulseController,
                    child: Icon(
                      Icons.refresh_rounded,
                      size: 11,
                      color: p.textDim,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/* ---- 电平表（L/R dBFS 横条） ---- */

class LevelMeter extends StatelessWidget {
  final ValueListenable<double> level;
  final String label;
  const LevelMeter({super.key, required this.level, required this.label});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Row(children: [
      SizedBox(
        width: 14,
        child: Text(label, style: monoOf(p, size: 11, color: p.textDim)),
      ),
      const SizedBox(width: AuraSpace.sm),
      Expanded(
        child: ValueListenableBuilder<double>(
          valueListenable: level,
          builder: (_, db, _) {
            final n = ((db + 60) / 60).clamp(0.0, 1.0);
            return SizedBox(
              height: 8,
              child: CustomPaint(
                size: const Size(double.infinity, 8),
                painter: _MeterPainter(
                  value: n,
                  track: p.hairline,
                  fill: db > -3 ? p.error : p.accent,
                ),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

class _MeterPainter extends CustomPainter {
  final double value;
  final Color track, fill;
  _MeterPainter({required this.value, required this.track, required this.fill});

  @override
  void paint(Canvas canvas, Size size) {
    const r = Radius.circular(4);
    canvas.drawRRect(
        RRect.fromRectAndRadius(Offset.zero & size, r), Paint()..color = track);
    if (value > 0) {
      canvas.drawRRect(
          RRect.fromRectAndRadius(
              Offset.zero & Size(size.width * value, size.height), r),
          Paint()..color = fill);
    }
    // 刻度：在轨道上打 3 道浅竖线作视觉参照
    final tick = Paint()..color = fill.withValues(alpha: 0.22);
    for (final f in const [0.3, 0.5, 0.7]) {
      canvas.drawRect(
          Rect.fromLTWH(size.width * f, 2, 1, size.height - 4), tick);
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.value != value;
}

/* ---- 频谱（32 带柱状 + 峰值保持） ---- */

class SpectrumView extends StatelessWidget {
  final ValueListenable<List<double>> spectrum;
  final ValueListenable<List<double>>? peaks;
  final double barGap;
  final bool showGrid;
  final bool gridAccent;

  const SpectrumView({
    super.key,
    required this.spectrum,
    this.peaks,
    this.barGap = 2,
    this.showGrid = true,
    this.gridAccent = false,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return CustomPaint(
      painter: _SpectrumPainter(
        spectrum: spectrum,
        peaks: peaks,
        gap: barGap,
        spectrumColor: p.vizSpectrum,
        capperColor: p.text.withValues(alpha: 0.85),
        gridColor: gridAccent ? p.accent.withValues(alpha: 0.10) : p.vizGrid,
        dimColor: p.textDim.withValues(alpha: 0.45),
        showGrid: showGrid,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _SpectrumPainter extends CustomPainter {
  final ValueListenable<List<double>> spectrum;
  final ValueListenable<List<double>>? peaks;
  final double gap;
  final Color spectrumColor, capperColor, gridColor, dimColor;
  final bool showGrid;

  _SpectrumPainter({
    required this.spectrum,
    required this.peaks,
    required this.gap,
    required this.spectrumColor,
    required this.capperColor,
    required this.gridColor,
    required this.dimColor,
    required this.showGrid,
  }) : super(repaint: spectrum);

  @override
  void paint(Canvas canvas, Size size) {
    if (showGrid) {
      final gp = Paint()
        ..color = gridColor
        ..strokeWidth = 1;
      for (var i = 1; i < 4; i++) {
        final y = size.height * i / 4;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), gp);
      }
      for (var i = 1; i < 8; i++) {
        final x = size.width * i / 8;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), gp);
      }
    }

    final bands = spectrum.value;
    final n = bands.length.clamp(1, 64);
    final bw = (size.width - gap * (n - 1)) / n;
    final paint = Paint()..color = spectrumColor;
    final cap = Paint()..color = capperColor;
    final pk = peaks?.value;

    for (var i = 0; i < n; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      final h = v * size.height;
      final x = i * (bw + gap);
      if (h > 0.5) {
        final rect = Rect.fromLTWH(x, size.height - h, bw, h)
            .deflate(bw < 4 ? 0 : 0.5);
        canvas.drawRRect(
            RRect.fromRectAndCorners(rect,
                topLeft: const Radius.circular(2),
                topRight: const Radius.circular(2)),
            paint);
        // 顶端 2px 亮帽：给柱体一个明确的"读数头"
        if (h > 4) {
          canvas.drawRRect(
              RRect.fromRectAndRadius(
                  Rect.fromLTWH(x, size.height - h, bw, 2),
                  const Radius.circular(1)),
              cap);
        }
      }
      // 峰值保持线
      if (pk != null && i < pk.length && pk[i] > 0.01) {
        final py = size.height - pk[i].clamp(0.0, 1.0) * size.height;
        canvas.drawLine(Offset(x, py), Offset(x + bw, py),
            Paint()..color = dimColor..strokeWidth = 1.5);
      }
    }
  }

  @override
  bool shouldRepaint(_SpectrumPainter old) => false; // repaint 由 listenable 驱动
}

/// 频谱频率轴：对数额点标签，按 log10(f/20) / log10(20000/20) 定位，
/// 与引擎 32 个对数频带的真实横坐标对齐（不是均分！）。
class FreqAxis extends StatelessWidget {
  static const _marks = [
    (hz: 60.0, label: '60'),
    (hz: 250.0, label: '250'),
    (hz: 1000.0, label: '1k'),
    (hz: 4000.0, label: '4k'),
    (hz: 16000.0, label: '16k'),
  ];
  const FreqAxis({super.key});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    const fMin = 20.0, fMax = 20000.0;
    final denom = math.log(fMax / fMin);
    return LayoutBuilder(builder: (ctx, box) {
      return SizedBox(
        height: 14,
        child: Stack(
          children: [
            for (final m in _marks)
              Positioned(
                left: math.log(m.hz / fMin) / denom * box.maxWidth,
                child: FractionalTranslation(
                  translation: const Offset(-0.5, 0),
                  child: Text(m.label,
                      style: monoOf(p, size: 10,
                          color: p.textDim.withValues(alpha: 0.7))),
                ),
              ),
          ],
        ),
      );
    });
  }
}

/* ---- 峰值保持计算器（UI 侧，无引擎负担） ---- */

class PeakHolder {
  final List<double> _peaks = List.filled(32, 0);
  final List<double> _decay = List.filled(32, 0);

  List<double> update(List<double> spectrum) {
    for (var i = 0; i < _peaks.length && i < spectrum.length; i++) {
      final v = spectrum[i];
      if (v >= _peaks[i]) {
        _peaks[i] = v;
        _decay[i] = 0.008; // 每帧下落量
      } else {
        _peaks[i] = (_peaks[i] - _decay[i]).clamp(0.0, 1.0);
        _decay[i] *= 1.15;
      }
    }
    return _peaks;
  }
}

/* ---- i18n 便捷入口（生成类：AppLocalizations） ---- */

AppLocalizations l10nOf(BuildContext context) => AppLocalizations.of(context)!;
