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
import '../core/ui_helpers.dart';
import '../engine/auradsp_ffi.dart' show VizBands;
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
  /// latencyMs 的来源标注：true = 脉冲响应实测，false/null = 未测量
  final bool? latencyMeasured;
  /// 测量进行中（禁用重复点击）
  final bool? latencyProbing;
  final VoidCallback? onRefreshLatency;
  final int latencyTick;

  /// 是否折叠卡片内容区（关闭时整条折叠，仅保留标题与开关）
  final bool collapsed;

  /// 标题右侧的帮助气泡提示
  final String? titleTooltip;

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
    this.latencyMeasured,
    this.latencyProbing,
    this.onRefreshLatency,
    this.latencyTick = 0,
    this.collapsed = false,
    this.titleTooltip,
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
                  measured: latencyMeasured ?? false,
                  probing: latencyProbing ?? false,
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
      body.add(SectionTitle(title!,
          index: index,
          trailing: effectiveTrailing,
          titleTooltip: titleTooltip));

      final content = Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hint != null) ...[
            const SizedBox(height: AuraSpace.sm),
            Text(hint!, style: captionOf(p)),
          ],
          const SizedBox(height: AuraSpace.cardHeadGap),
          child,
        ],
      );

      body.add(
        ClipRect(
          child: AnimatedAlign(
            alignment: Alignment.topCenter,
            duration: AuraDur.base,
            curve: AuraCurve.standard,
            heightFactor: collapsed ? 0.0 : 1.0,
            child: AnimatedOpacity(
              duration: AuraDur.fast,
              curve: AuraCurve.standard,
              opacity: collapsed ? 0.0 : 1.0,
              child: content,
            ),
          ),
        ),
      );
    } else {
      body.add(child);
    }

    return Container(
      // hero 分支已删：唯一 hero:true 调用方（home_page 引擎状态卡）自带显式 padding，
      // 默认分支无任何调用者走 hero ? xl。hero 字段仅保留强调色细边语义。
      padding: padding ??
          EdgeInsets.all(
              collapsed ? AuraSpace.cardPadCollapsed : AuraSpace.cardPad),
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
  final String? titleTooltip;
  const SectionTitle(this.text,
      {super.key, this.index, this.trailing, this.titleTooltip});

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
        Expanded(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Flexible(
                child: Text(
                  text,
                  style: sectionOf(p),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (titleTooltip != null) ...[
                const SizedBox(width: 6),
                InfoBadge(message: titleTooltip!),
              ],
            ],
          ),
        ),
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
/// 效果卡片的「高级参数」折叠区。
///
/// 此前 Bass / Stereo / Tube 三处各抄了一份**逐字节相同**的折叠头
/// （MouseRegion → GestureDetector(opaque) → Row[AnimatedRotation(0.25),
/// expand_more, 「高级」, Spacer, 等宽摘要] → AnimatedCrossFade），
/// 唯一差别只有右侧那行摘要文字。抽到这里后改一次三处同步生效。
class AdvancedSection extends StatefulWidget {
  /// 右侧等宽小字摘要（各效果不同，例如 "120 Hz · 35%"）
  final String summary;
  /// 展开内容的构建函数。签名带 BuildContext，便于内部自行取 palette/l10n。
  final Widget Function(BuildContext context) builder;

  /// 初始是否展开。各卡片的历史默认态由调用方决定。
  final bool initOpen;

  /// 高级标题旁的小问号 hover 气泡提示
  final String? helpTooltip;

  const AdvancedSection({
    super.key,
    required this.summary,
    required this.builder,
    this.initOpen = false,
    this.helpTooltip,
  });

  @override
  State<AdvancedSection> createState() => _AdvancedSectionState();
}

class _AdvancedSectionState extends State<AdvancedSection> {
  late bool _open = widget.initOpen;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => setState(() => _open = !_open),
            child: Row(
              children: [
                AnimatedRotation(
                  duration: AuraDur.fast,
                  turns: _open ? 0.25 : 0,
                  child: Icon(Icons.expand_more_rounded,
                      size: 20, color: p.accent),
                ),
                const SizedBox(width: AuraSpace.sm),
                Text(l.advanced, style: labelOf(p, color: p.text)),
                if (widget.helpTooltip != null) ...[
                  const SizedBox(width: 6),
                  InfoBadge(message: widget.helpTooltip!),
                ],
                const Spacer(),
                Text(widget.summary,
                    style: monoOf(p, size: 10, color: p.textDim)),
              ],
            ),
          ),
        ),
        AnimatedCrossFade(
          duration: AuraDur.base,
          sizeCurve: AuraCurve.standard,
          crossFadeState:
              _open ? CrossFadeState.showSecond : CrossFadeState.showFirst,
          // 收起时用零高占位，避免布局跳动
          firstChild: const SizedBox(width: double.infinity),
          secondChild: Padding(
            padding: const EdgeInsets.only(top: AuraSpace.sm),
            child: widget.builder(context),
          ),
        ),
      ],
    );
  }
}

/// 统一的输出级边框容器（AGC 自动增益与输出增益门包裹用）
class OutputGainFrame extends StatelessWidget {
  final Widget child;
  const OutputGainFrame({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      decoration: BoxDecoration(
        color: p.panelRaised.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline.withValues(alpha: 0.7)),
      ),
      padding: const EdgeInsets.all(AuraSpace.sm),
      child: child,
    );
  }
}

class ComponentLatencyBadge extends StatefulWidget {
  final double latencyMs;
  /// 该数值是否来自真实脉冲响应实测。false 表示解析估算或未测量。
  final bool measured;
  final VoidCallback? onRefresh;
  final int refreshTick;
  final bool probing;

  const ComponentLatencyBadge({
    super.key,
    required this.latencyMs,
    this.measured = false,
    this.onRefresh,
    this.refreshTick = 0,
    this.probing = false,
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
    final l = l10nOf(context);
    final text = widget.measured
        ? '${widget.latencyMs.toStringAsFixed(1)} ms'
        : l.latUnmeasured;
    // 如实标注来源：实测 / 估算 / 未测量。旧实现把查表常量标成"实测"，
    // 而 refreshComponentLatency 只是改了个时间戳、根本没做测量。
    final tooltip = widget.measured
        ? l.latTipMeasured(text)
        : (widget.probing
            ? l.latTipProbing
            : l.latTipUnmeasured);
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
          message: tooltip,
          waitDuration: const Duration(milliseconds: 250),
          child: InkWell(
            onTap: widget.probing
                ? null
                : () {
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
                      color: !widget.measured
                          ? p.textDim
                          : (widget.latencyMs > 20
                              ? p.warning
                              : (widget.latencyMs > 0 ? p.accent2 : p.textDim)),
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
  /// 最小柱宽（px）。高频带真实跨度极窄，低于此值就成了发丝线。
  static const _minBarWidth = 3.0;

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
      // 竖网格线必须落在对数刻度上（100/1k/10k 三个十倍频程），
      // 否则与下方 FreqAxis 的频率标签对不齐。
      for (final hz in const [100.0, 1000.0, 10000.0]) {
        final x = VizBands.logX(hz) * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), gp);
      }
    }

    final bands = spectrum.value;
    final n = bands.length.clamp(1, VizBands.count);
    final paint = Paint()..color = spectrumColor;
    final cap = Paint()..color = capperColor;
    final pk = peaks?.value;

    for (var i = 0; i < n; i++) {
      final v = bands[i].clamp(0.0, 1.0);
      final h = v * size.height;
      // 横坐标取该频带的真实对数跨度，不再均分 —— 与 FreqAxis 同一套刻度。
      final x0 = VizBands.edgeX(i) * size.width;
      final x1 = VizBands.edgeX(i + 1) * size.width;
      final span = x1 - x0;
      // 高频带的真实跨度极窄（19k~20k 仅为中频带的 ~1/4），减去 gap 后会塌成
      // 1px 发丝。故设最小柱宽并在带内居中，宁可相邻柱轻微相接也不出发丝。
      final bw = math.max(_minBarWidth, span - gap).toDouble();
      final x = x0 + (span - bw) / 2;
      final radius = Radius.circular(math.min(2.0, bw / 2).toDouble());
      if (h > 0.5) {
        final rect = Rect.fromLTWH(x, size.height - h, bw, h)
            .deflate(bw < 6 ? 0 : 0.5);
        canvas.drawRRect(
            RRect.fromRectAndCorners(rect,
                topLeft: radius, topRight: radius),
            paint);
        // 顶端 2px 亮帽：给柱体一个明确的"读数头"
        if (h > 4) {
          canvas.drawRRect(
              RRect.fromRectAndRadius(
                  Rect.fromLTWH(x, size.height - h, bw, 2), radius),
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
    return LayoutBuilder(builder: (ctx, box) {
      return SizedBox(
        height: 14,
        child: Stack(
          children: [
            for (final m in _marks)
              Positioned(
                left: VizBands.logX(m.hz) * box.maxWidth,
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

/* ---- 通用选择 Chip（Bass 模式 / 电子管风格 / 过采样档位共用） ---- */

/// 小尺寸单选片：等宽 11px 标签，选中态强调色描边 + 淡底。
/// 由 effects_page._ChoiceChip 迁移，并吸收 interactive_eq._FilterChoice /
/// _BandChip（两处选中底 alpha 0.15/0.18 归一到 0.16，肉眼不可辨），供各卡片复用。
/// 与 AuraChip 的区别：更小（无固定 30 高、无 hover 底），专用于卡片内选项组。
class AuraChoiceChip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  const AuraChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AuraRadius.xs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? p.accent.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          border: Border.all(
            color: selected ? p.accent : p.hairline,
          ),
        ),
        child: Text(
          label,
          style: monoOf(
            p,
            size: 11,
            color: selected ? p.accent : p.textDim,
          ),
        ),
      ),
    );
  }
}

/* ---- 扫描进度条（C2：Android 风格水平进度） ---- */

/// Android/Material 风格的水平进度条。
/// - total > 0：确定性模式，按 done/total 填充（扫描知道候选总数时用）
/// - total <= 0：不确定模式，一段渐变沿轨道左右扫动（Android 的 indeterminate
///   观感：加速—减速往复），用于「枚举中」「候选数未知」阶段。
///
/// 刻意不用 Material 的 CircularProgressIndicator：扫描是"遍历一批文件"这种
/// 长任务，线性条更能表达"推进感"，也与插件库区块的横向布局一致。
class AuraScanProgress extends StatefulWidget {
  final int done;
  final int total;
  final double height;

  const AuraScanProgress({
    super.key,
    required this.done,
    required this.total,
    this.height = 3,
  });

  @override
  State<AuraScanProgress> createState() => _AuraScanProgressState();
}

class _AuraScanProgressState extends State<AuraScanProgress>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    if (widget.total <= 0) _ctrl.repeat();
  }

  @override
  void didUpdateWidget(covariant AuraScanProgress old) {
    super.didUpdateWidget(old);
    // 从"不知道总数"变成"知道总数"时停掉扫动，切到确定性填充。
    final wasIndeterminate = old.total <= 0;
    final isIndeterminate = widget.total <= 0;
    if (wasIndeterminate && !isIndeterminate) {
      _ctrl.stop();
      _ctrl.value = 0;
    } else if (!wasIndeterminate && isIndeterminate && !_ctrl.isAnimating) {
      _ctrl.repeat();
    }
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final trackColor = p.hairline;
    final gradient = LinearGradient(
      colors: [
        p.accent.withValues(alpha: 0.15),
        p.accent,
        p.accent.withValues(alpha: 0.15),
      ],
    );

    return ClipRRect(
      borderRadius: BorderRadius.circular(widget.height / 2),
      child: SizedBox(
        height: widget.height,
        child: Stack(
          children: [
            Container(color: trackColor),
            if (widget.total > 0)
              // 确定性：填充已处理比例（clamp 防 done>total 的越界观感）。
              // 用 TweenAnimationBuilder 让推进是"滑动"而非"跳变"。
              TweenAnimationBuilder<double>(
                tween: Tween<double>(
                    begin: (widget.done / widget.total).clamp(0.0, 1.0),
                    end: (widget.done / widget.total).clamp(0.0, 1.0)),
                duration: const Duration(milliseconds: 180),
                builder: (context, frac, _) {
                  return LayoutBuilder(builder: (context, constraints) {
                    return Stack(
                      children: [
                        Positioned(
                          left: 0,
                          top: 0,
                          bottom: 0,
                          width: constraints.maxWidth * frac,
                          child: DecoratedBox(
                              decoration: BoxDecoration(gradient: gradient)),
                        ),
                      ],
                    );
                  });
                },
              )
            else
              // 不确定：一段宽度 35% 的渐变沿轨道扫动（ease-in-out 往复）
              AnimatedBuilder(
                animation: _ctrl,
                builder: (context, _) {
                  final t = Curves.easeInOut.transform(_ctrl.value);
                  return LayoutBuilder(builder: (context, constraints) {
                    final segW = constraints.maxWidth * 0.35;
                    final left = -segW + t * (constraints.maxWidth + segW);
                    return Stack(
                      children: [
                        Positioned(
                          left: left,
                          width: segW,
                          top: 0,
                          bottom: 0,
                          child: DecoratedBox(
                              decoration: BoxDecoration(gradient: gradient)),
                        ),
                      ],
                    );
                  });
                },
              ),
          ],
        ),
      ),
    );
  }
}

/* ---- i18n 便捷入口（生成类：AppLocalizations） ---- */

AppLocalizations l10nOf(BuildContext context) => AppLocalizations.of(context)!;
