/*
 * interactive_eq.dart — 多段交互式图形均衡器 (Interactive Multi-Band EQ)
 *
 * 规范落地 (§3)：
 * 1. 7/10/15/31 段规格切换与风格预设
 * 2. 交互式多段频响曲线：Catmull-Rom 插值、节点拖曳、双击归零/拉平、悬停浮标
 * 3. 背后叠加实时输出 32 带 FFT 频谱柱状光晕
 * 4. 外置 Q-Factor 环形发光旋钮
 * 5. 高级折叠面板：FIR/IIR 架构与 Makima/PCHIP 插值器
 */

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../l10n/gen/app_localizations.dart';
import 'chrome.dart';
import 'widgets.dart';

class InteractiveSpectrumEQPanel extends StatefulWidget {
  final AppModel model;
  const InteractiveSpectrumEQPanel({super.key, required this.model});

  @override
  State<InteractiveSpectrumEQPanel> createState() =>
      _InteractiveSpectrumEQPanelState();
}

class _InteractiveSpectrumEQPanelState
    extends State<InteractiveSpectrumEQPanel> {
  int? _hoveredIndex;
  int? _draggedIndex;
  Offset? _hoverPos;
  bool _advancedOpen = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final model = widget.model;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // ---- 顶层控制栏：频段规格切换 + 预设风格 + 动作按键 ----
        Wrap(
          spacing: AuraSpace.sm,
          runSpacing: AuraSpace.sm,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            // 频段规格切换
            for (final b in const [7, 10, 15, 31])
              AuraChoiceChip(
                label: l.eqBands(b),
                selected: model.eqBandsCount == b,
                onTap: () => model.setEqBandsCount(b),
              ),
            const SizedBox(width: AuraSpace.xs),
            Container(width: 1, height: 18, color: p.hairline),
            const SizedBox(width: AuraSpace.xs),
            // 预设风格选择
            _PresetDropdown(model: model),
            // 动作按钮：平直复位与旁路对比
            AuraChip(
              l.eqFlat,
              icon: Icons.horizontal_rule_rounded,
              onTap: model.flattenEq,
            ),
            AuraChip(
              l.eqBypass,
              icon: model.eqBypass
                  ? Icons.visibility_off_rounded
                  : Icons.visibility_rounded,
              selected: model.eqBypass,
              onTap: model.toggleEqBypass,
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.md),

        // ---- 核心主体区：频谱响应画布 + 外置发光 Q 旋钮 ----
        Container(
          height: 220,
          decoration: BoxDecoration(
            color: p.panelRaised.withValues(alpha: 0.65),
            borderRadius: BorderRadius.circular(AuraRadius.md),
            border: Border.all(color: p.hairline),
          ),
          child: Row(
            children: [
              // 交互式曲线与实时频谱画布
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.horizontal(
                    left: Radius.circular(AuraRadius.md),
                  ),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final w = constraints.maxWidth;
                      final h = constraints.maxHeight;
                      return MouseRegion(
                        onHover: (e) {
                          final idx = _hitTestNode(e.localPosition, w, h);
                          setState(() {
                            _hoveredIndex = idx;
                            _hoverPos = e.localPosition;
                          });
                        },
                        onExit: (_) {
                          setState(() {
                            _hoveredIndex = null;
                            _hoverPos = null;
                          });
                        },
                        child: GestureDetector(
                          onDoubleTapDown: (details) {
                            final idx =
                                _hitTestNode(details.localPosition, w, h);
                            if (idx != null) {
                              // 双击单个节点：归零
                              model.setEqBandGain(idx, 0.0);
                            } else {
                              // 双击画布空白：拉平整条曲线
                              model.flattenEq();
                            }
                          },
                          onPanStart: (details) {
                            final idx =
                                _hitTestNode(details.localPosition, w, h);
                            if (idx != null) {
                              setState(() => _draggedIndex = idx);
                            }
                          },
                          onPanUpdate: (details) {
                            final idx = _draggedIndex ?? _hoveredIndex;
                            if (idx != null && idx < model.eqGains.length) {
                              final gain = _yToGain(details.localPosition.dy, h);
                              model.setEqBandGain(idx, gain);
                              setState(() {
                                _hoverPos = details.localPosition;
                              });
                            }
                          },
                          onPanEnd: (_) {
                            setState(() => _draggedIndex = null);
                          },
                          child: RepaintBoundary(
                            child: ListenableBuilder(
                              listenable: Listenable.merge([
                                model.eqInSpectrum,
                                model,
                              ]),
                              builder: (context, _) {
                                return CustomPaint(
                                  size: Size(w, h),
                                  painter: _SpectrumEQPainter(
                                    palette: p,
                                    // 背景柱画的是**均衡器输出**频谱，不是整链输出：
                                    // EQ 之后的混响/卷积/Freeverb/插件全都混在
                                    // model.spectrum 里，拿它当背景，用户看到的根本不是
                                    // 均衡器输出的东西。EQ 在 vendor 单体链内部拿不到
                                    // 输出 tap，于是按 |Y| = |X|·|H_eq| 用 EQ 输入谱
                                    // （eqInSpectrum）+ 实测响应合成，见
                                    // AppModel.composeEqOutputSpectrum。
                                    spectrumBands: AppModel.composeEqOutputSpectrum(
                                      model.eqInSpectrum.value,
                                      model.eqResponseDb,
                                      bypassed: model.eqBypass,
                                    ),
                                    frequencies: model.eqFrequencies,
                                    gains: model.eqGains,
                                    hoveredIndex: _draggedIndex ?? _hoveredIndex,
                                    hoverPos: _hoverPos,
                                    isBypassed: model.eqBypass,
                                    measuredResponse: model.eqResponseDb,
                                    measuredForCurve: model.eqResponseCurve,
                                  ),
                                );
                              },
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              // 分隔线
              Container(width: 1, height: double.infinity, color: p.hairline),
              // 外置发光 Q 旋钮
              SizedBox(
                width: 96,
                child: _RotaryQKnob(
                  q: model.eqQ,
                  onChanged: model.setEqQ,
                  onReset: () => model.setEqQ(ParamDefaults.eqQ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: AuraSpace.sm),

        // 底部提示（Wrap：窄屏自动换行，避免 Row 在小宽度下横向溢出；
        // 桌面端一行放下时与原来视觉一致）
        Wrap(
          spacing: AuraSpace.sm,
          runSpacing: AuraSpace.xs,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              l.eqCanvasHint,
              style: captionOf(p),
            ),
            if (model.eqBypass)
              Text(
                l.eqBypassOn,
                style: monoOf(p, size: 11, color: p.warning),
              ),
          ],
        ),
        const SizedBox(height: AuraSpace.md),

        // ---- 高级折叠面板：FIR/IIR 与 插值算法 ----
        _buildAdvancedPanel(context),
      ],
    );
  }

  int? _hitTestNode(Offset pos, double width, double height) {
    final freqs = widget.model.eqFrequencies;
    final gains = widget.model.eqGains;
    for (var i = 0; i < freqs.length; i++) {
      if (i >= gains.length) break;
      final nx = _freqToX(freqs[i], width);
      final ny = _gainToY(gains[i], height);
      final dist = (pos - Offset(nx, ny)).distance;
      if (dist <= 16.0) return i;
    }
    return null;
  }

  Widget _buildAdvancedPanel(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final model = widget.model;

    return Container(
      decoration: BoxDecoration(
        color: p.panelRaised.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        children: [
          InkWell(
            onTap: () => setState(() => _advancedOpen = !_advancedOpen),
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AuraSpace.md,
                vertical: AuraSpace.sm,
              ),
              child: Row(
                children: [
                  Icon(
                    _advancedOpen
                        ? Icons.keyboard_arrow_down_rounded
                        : Icons.keyboard_arrow_right_rounded,
                    size: 18,
                    color: p.accent,
                  ),
                  const SizedBox(width: AuraSpace.xs),
                  Text(l.advanced, style: labelOf(p)),
                  const Spacer(),
                  Text(
                    model.eqFilter == 0 ? 'FIR · Makima' : 'IIR · Makima',
                    style: monoOf(p, size: 10, color: p.textDim),
                  ),
                ],
              ),
            ),
          ),
          if (_advancedOpen) ...[
            Divider(height: 1, color: p.hairline),
            Padding(
              padding: const EdgeInsets.all(AuraSpace.md),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l.eqFilterType, style: captionOf(p)),
                  const SizedBox(height: AuraSpace.xs),
                  Wrap(
                    spacing: AuraSpace.sm,
                    runSpacing: AuraSpace.sm,
                    children: [
                      AuraChoiceChip(
                        label: l.eqFilterMinphase,
                        selected: model.eqFilter == 0,
                        onTap: () => model.setEqFilter(0),
                      ),
                      AuraChoiceChip(
                        label: l.eqFilterIir6,
                        selected: model.eqFilter == 1,
                        onTap: () => model.setEqFilter(1),
                      ),
                      AuraChoiceChip(
                        label: l.eqFilterIir12,
                        selected: model.eqFilter == 2,
                        onTap: () => model.setEqFilter(2),
                      ),
                    ],
                  ),
                  const SizedBox(height: AuraSpace.md),
                  Text(l.eqInterpolation, style: captionOf(p)),
                  const SizedBox(height: AuraSpace.xs),
                  Wrap(
                    spacing: AuraSpace.sm,
                    children: [
                      AuraChoiceChip(
                        label: l.eqInterpMakima,
                        selected: model.eqInterp == 1,
                        onTap: () => model.setEqInterp(1),
                      ),
                      AuraChoiceChip(
                        label: l.eqInterpPchip,
                        selected: model.eqInterp == 0,
                        onTap: () => model.setEqInterp(0),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/* ---- 预设风格下拉菜单 ---- */

class _PresetDropdown extends StatelessWidget {
  final AppModel model;
  const _PresetDropdown({required this.model});

  /// 预设 id → 展示名（展示名走 l10n，不能是 const）。
  static List<(String, String)> _presetsOf(AppLocalizations l) => [
    ('flat', l.eqPresetFlat),
    ('pop', l.eqPresetPop),
    ('rock', l.eqPresetRock),
    ('jazz', l.eqPresetJazz),
    ('classical', l.eqPresetClassical),
    ('vocal', l.eqPresetVocal),
    ('smile', l.eqPresetSmile),
    ('bass_boost', l.eqPresetBass),
    ('treble_boost', l.eqPresetTreble),
  ];

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final cur = _presetsOf(l10nOf(context)).firstWhere(
      (e) => e.$1 == model.eqPresetName,
      orElse: () => ('custom', l10nOf(context).eqPresetCustom),
    );

    return PopupMenuButton<String>(
      tooltip: l10nOf(context).eqPresetPick,
      color: p.panelRaised,
      elevation: 6,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        side: BorderSide(color: p.hairline),
      ),
      onSelected: model.applyEqPreset,
      itemBuilder: (context) => [
        for (final item in _presetsOf(l10nOf(context)))
          PopupMenuItem<String>(
            value: item.$1,
            child: Row(
              children: [
                if (item.$1 == model.eqPresetName)
                  Icon(Icons.check_rounded, size: 14, color: p.accent)
                else
                  const SizedBox(width: 14),
                const SizedBox(width: 6),
                Text(item.$2, style: monoOf(p, size: 12)),
              ],
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: p.panel,
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          border: Border.all(color: p.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.tune_rounded, size: 13, color: p.accent),
            const SizedBox(width: 6),
            Text(cur.$2, style: monoOf(p, size: 11, color: p.text)),
            const SizedBox(width: 4),
            Icon(Icons.arrow_drop_down_rounded, size: 16, color: p.textDim),
          ],
        ),
      ),
    );
  }
}

/* ---- 外置发光 Q 旋钮 (Rotary Q Knob) ---- */

class _RotaryQKnob extends StatefulWidget {
  final double q;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;

  const _RotaryQKnob({
    required this.q,
    required this.onChanged,
    required this.onReset,
  });

  @override
  State<_RotaryQKnob> createState() => _RotaryQKnobState();
}

class _RotaryQKnobState extends State<_RotaryQKnob> {
  double? _dragStartY;
  double? _dragStartQ;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return GestureDetector(
      onDoubleTap: widget.onReset,
      onVerticalDragStart: (details) {
        _dragStartY = details.localPosition.dy;
        _dragStartQ = widget.q;
      },
      onVerticalDragUpdate: (details) {
        if (_dragStartY != null && _dragStartQ != null) {
          final dy = _dragStartY! - details.localPosition.dy;
          // 每 10 像素调节 0.2 Q 值
          final newQ = (_dragStartQ! + (dy / 50.0)).clamp(0.3, 10.0);
          widget.onChanged(newQ);
        }
      },
      onVerticalDragEnd: (_) {
        _dragStartY = null;
        _dragStartQ = null;
      },
      child: Tooltip(
        message: l.eqQTip,
        child: Container(
          color: Colors.transparent,
          padding: const EdgeInsets.all(8),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              CustomPaint(
                size: const Size(60, 60),
                painter: _KnobPainter(q: widget.q, palette: p),
              ),
              const SizedBox(height: 6),
              Text(
                widget.q.toStringAsFixed(2),
                style: monoOf(p, size: 12, color: p.accent),
              ),
              const SizedBox(height: 2),
              Text(
                l.eqQFactor,
                style: captionOf(p).copyWith(fontSize: 9),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _KnobPainter extends CustomPainter {
  final double q;
  final AuraPalette palette;
  const _KnobPainter({required this.q, required this.palette});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 4;

    // 轨道角度：-135° 到 +135° (总计 270°)
    const startAngle = 135.0 * math.pi / 180.0;
    const sweepTotal = 270.0 * math.pi / 180.0;

    // 绘制灰色底环轨道
    final trackPaint = Paint()
      ..color = palette.hairline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweepTotal,
      false,
      trackPaint,
    );

    // 计算当前比例 (0.3 ~ 10.0 对数映射)
    final logMin = math.log(0.3);
    final logMax = math.log(10.0);
    final ratio = ((math.log(q) - logMin) / (logMax - logMin)).clamp(0.0, 1.0);
    final sweep = sweepTotal * ratio;

    // 绘制高亮发光弧
    final activePaint = Paint()
      ..color = palette.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.5
      ..strokeCap = StrokeCap.round;

    canvas.drawArc(
      Rect.fromCircle(center: center, radius: radius),
      startAngle,
      sweep,
      false,
      activePaint,
    );

    // 绘制中心旋钮圆盘
    final discPaint = Paint()
      ..color = palette.panel
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - 6, discPaint);

    final discBorder = Paint()
      ..color = palette.hairline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, radius - 6, discBorder);

    // 绘制指针指示点
    final currentAngle = startAngle + sweep;
    final dotX = center.dx + (radius - 11) * math.cos(currentAngle);
    final dotY = center.dy + (radius - 11) * math.sin(currentAngle);
    final dotPaint = Paint()..color = palette.accent;
    canvas.drawCircle(Offset(dotX, dotY), 2.5, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _KnobPainter oldDelegate) =>
      oldDelegate.q != q || oldDelegate.palette != palette;
}

/* ---- 核心画布绘制器 (CustomPainter) ---- */

class _SpectrumEQPainter extends CustomPainter {
  final AuraPalette palette;
  final List<double> spectrumBands;
  final List<double> frequencies;
  final List<double> gains;
  final int? hoveredIndex;
  final Offset? hoverPos;
  final bool isBypassed;

  /// 引擎实测的幅度响应（dB，长度 129，log 等分 20Hz..20kHz）。
  ///
  /// null 或与当前曲线不匹配时，[_drawResponseCurve] 回退到本地 smoothstep
  /// 近似 —— 探针约 29ms 且只在拖拽停下后触发，拖拽过程中必然拿不到新值，
  /// 所以近似不是「旧代码」，而是必要的实时降级路径。
  final List<double>? measuredResponse;

  /// [measuredResponse] 对应的曲线签名；与当前不符即视为过期。
  final String? measuredForCurve;

  const _SpectrumEQPainter({
    required this.palette,
    required this.spectrumBands,
    required this.frequencies,
    required this.gains,
    required this.hoveredIndex,
    required this.hoverPos,
    required this.isBypassed,
    this.measuredResponse,
    this.measuredForCurve,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 1. 绘制网格与标尺线
    _drawGrid(canvas, w, h);

    // 2. 绘制背后 32 带 FFT 频谱光晕柱
    _drawSpectrumBands(canvas, w, h);

    // 3. 绘制平滑频响曲线与渐变光晕填充
    _drawResponseCurve(canvas, w, h);

    // 4. 绘制各中心频点手柄与悬停高亮
    _drawNodes(canvas, w, h);
  }

  void _drawGrid(Canvas canvas, double w, double h) {
    final gridPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.35)
      ..strokeWidth = 1.0;

    final zeroPaint = Paint()
      ..color = palette.textDim.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    // 水平增益标尺线：+18, +12, +6, 0, -6, -12, -18 dB
    const dbLines = [18.0, 12.0, 6.0, 0.0, -6.0, -12.0, -18.0];
    for (final db in dbLines) {
      final y = _gainToY(db, h);
      canvas.drawLine(
        Offset(0, y),
        Offset(w, y),
        db == 0.0 ? zeroPaint : gridPaint,
      );
    }

    // 垂直频率标尺线：100Hz, 1kHz, 10kHz
    const fLines = [100.0, 1000.0, 10000.0];
    for (final f in fLines) {
      final x = _freqToX(f, w);
      canvas.drawLine(Offset(x, 0), Offset(x, h), gridPaint);
    }

    // 标尺文字
    _drawText(canvas, '+18dB', Offset(4, 4), palette.textDim.withValues(alpha: 0.5));
    _drawText(canvas, '0dB', Offset(4, _gainToY(0, h) - 12), palette.textDim.withValues(alpha: 0.5));
    _drawText(canvas, '-18dB', Offset(4, h - 16), palette.textDim.withValues(alpha: 0.5));

    _drawText(canvas, '100Hz', Offset(_freqToX(100, w) + 4, h - 16), palette.textDim.withValues(alpha: 0.5));
    _drawText(canvas, '1kHz', Offset(_freqToX(1000, w) + 4, h - 16), palette.textDim.withValues(alpha: 0.5));
    _drawText(canvas, '10kHz', Offset(_freqToX(10000, w) + 4, h - 16), palette.textDim.withValues(alpha: 0.5));
  }

  void _drawSpectrumBands(Canvas canvas, double w, double h) {
    if (spectrumBands.isEmpty) return;

    final barCount = math.min(32, spectrumBands.length);
    final barW = (w / (barCount * 1.35)).clamp(3.0, 14.0);

    for (var i = 0; i < barCount; i++) {
      final val = spectrumBands[i].clamp(0.0, 1.0);
      if (val <= 0.005) continue;

      // 在对数频率轴上均匀分布
      final t = (i + 0.5) / barCount;
      final x = t * w;
      final barH = val * (h * 0.85);
      final y = h - barH;

      final rect = Rect.fromLTWH(x - barW / 2, y, barW, barH);
      final gradient = LinearGradient(
        begin: Alignment.bottomCenter,
        end: Alignment.topCenter,
        colors: [
          palette.accent.withValues(alpha: 0.02),
          palette.accent.withValues(alpha: 0.18 * val),
        ],
      );

      final barPaint = Paint()
        ..shader = gradient.createShader(rect)
        ..style = PaintingStyle.fill;

      canvas.drawRRect(
        RRect.fromRectAndRadius(rect, const Radius.circular(2)),
        barPaint,
      );

      // 顶部高亮微光横线
      final tipPaint = Paint()
        ..color = palette.accent.withValues(alpha: 0.45 * val)
        ..strokeWidth = 1.5;
      canvas.drawLine(
        Offset(x - barW / 2, y),
        Offset(x + barW / 2, y),
        tipPaint,
      );
    }
  }

  void _drawResponseCurve(Canvas canvas, double w, double h) {
    if (frequencies.isEmpty || gains.isEmpty) return;

    // 对画布采样 160 个点。优先用引擎实测响应 —— 它是 makima + 最小相位 IR
    // + FFT 卷积真正产生的幅度（实测与本地 smoothstep 近似最大差 2.61 dB）；
    // 拿不到时才退回本地插值。探针约 29ms 且只在拖拽停下后触发，拖拽过程中
    // 必然拿不到新值，所以本地插值不是「旧代码」，而是必要的实时降级路径。
    const samples = 160;
    final measured = measuredResponse;
    final respLen = measured?.length ?? 0;
    final curvePoints = <Offset>[];

    for (var i = 0; i <= samples; i++) {
      final t = i / samples;
      final x = t * w;
      final f = _xToFreq(x, w);
      double g;
      if (respLen >= 2) {
        // 探针在 [20, 20000] 上 log 等分取样，这里按同一映射反查并线性内插
        const fMin = 20.0, fMax = 20000.0;
        final clamped = f.clamp(fMin, fMax).toDouble();
        final lf = (math.log(clamped) - math.log(fMin)) /
            (math.log(fMax) - math.log(fMin));
        final pos = lf * (respLen - 1);
        final i0 = pos.floor().clamp(0, respLen - 1);
        final i1 = (i0 + 1).clamp(0, respLen - 1);
        final k = pos - i0;
        g = measured![i0] + (measured[i1] - measured[i0]) * k;
      } else {
        g = _interpolateGain(f);
      }
      if (isBypassed) g = 0.0;
      final y = _gainToY(g, h);
      curvePoints.add(Offset(x, y));
    }

    if (curvePoints.length < 2) return;

    // 绘制曲线填充路径（从曲线到 0dB 基准线）
    final zeroY = _gainToY(0.0, h);
    final fillPath = Path()..moveTo(curvePoints.first.dx, zeroY);
    for (final pt in curvePoints) {
      fillPath.lineTo(pt.dx, pt.dy);
    }
    fillPath.lineTo(curvePoints.last.dx, zeroY);
    fillPath.close();

    final fillGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        palette.accent.withValues(alpha: isBypassed ? 0.02 : 0.14),
        palette.accent.withValues(alpha: 0.0),
      ],
    );
    final fillPaint = Paint()
      ..shader = fillGradient.createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // 绘制曲线描边
    final strokePath = Path()..moveTo(curvePoints.first.dx, curvePoints.first.dy);
    for (var i = 1; i < curvePoints.length; i++) {
      strokePath.lineTo(curvePoints[i].dx, curvePoints[i].dy);
    }

    final strokePaint = Paint()
      ..color = isBypassed
          ? palette.textDim.withValues(alpha: 0.5)
          : palette.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(strokePath, strokePaint);
  }

  void _drawNodes(Canvas canvas, double w, double h) {
    for (var i = 0; i < frequencies.length; i++) {
      if (i >= gains.length) break;
      final f = frequencies[i];
      final g = isBypassed ? 0.0 : gains[i];
      final nx = _freqToX(f, w);
      final ny = _gainToY(g, h);
      final isHovered = hoveredIndex == i;

      final radius = isHovered ? 7.5 : 5.0;

      // 外圈光晕
      if (isHovered && !isBypassed) {
        final glowPaint = Paint()
          ..color = palette.accent.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);
        canvas.drawCircle(Offset(nx, ny), radius + 4, glowPaint);
      }

      // 内心实底
      final corePaint = Paint()
        ..color = palette.panel
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(nx, ny), radius, corePaint);

      // 外环强调圈
      final ringPaint = Paint()
        ..color = isBypassed
            ? palette.textDim
            : (isHovered ? palette.accent : palette.accent.withValues(alpha: 0.85))
        ..style = PaintingStyle.stroke
        ..strokeWidth = isHovered ? 2.5 : 1.8;
      canvas.drawCircle(Offset(nx, ny), radius, ringPaint);

      // 如果当前正在悬停/拖拽，绘制浮动读数微标
      if (isHovered) {
        final fStr = f >= 1000
            ? '${(f / 1000).toStringAsFixed(1)} kHz'
            : '${f.round()} Hz';
        final gStr = '${g >= 0 ? '+' : ''}${g.toStringAsFixed(1)} dB';
        final tipText = '$fStr : $gStr';
        _drawTooltipBadge(canvas, tipText, Offset(nx, ny - 24), palette);
      }
    }
  }

  double _interpolateGain(double freq) {
    if (frequencies.isEmpty || gains.isEmpty) return 0.0;
    if (freq <= frequencies.first) return gains.first;
    if (freq >= frequencies.last) return gains.last;

    var idx = 0;
    while (idx < frequencies.length - 1 && frequencies[idx + 1] < freq) {
      idx++;
    }

    final f0 = frequencies[idx];
    final f1 = frequencies[idx + 1];
    final g0 = gains[idx];
    final g1 = gains[idx + 1];

    final lf0 = math.log(f0);
    final lf1 = math.log(f1);
    final lft = math.log(freq);
    final t = (lft - lf0) / (lf1 - lf0);

    // 三次平滑插值 (Smoothstep)
    final s = t * t * (3.0 - 2.0 * t);
    return g0 + s * (g1 - g0);
  }

  void _drawTooltipBadge(
      Canvas canvas, String text, Offset center, AuraPalette palette) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: kMonoFallback,
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: palette.accentContrast,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();

    final padH = 6.0;
    final padV = 3.0;
    final rect = Rect.fromCenter(
      center: center,
      width: tp.width + padH * 2,
      height: tp.height + padV * 2,
    );

    final bgPaint = Paint()..color = palette.accent;
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(4)),
      bgPaint,
    );

    tp.paint(canvas, Offset(rect.left + padH, rect.top + padV));
  }

  void _drawText(Canvas canvas, String text, Offset pos, Color color) {
    final tp = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'monospace',
          fontFamilyFallback: kMonoFallback,
          fontSize: 9,
          color: color,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, pos);
  }

  @override
  bool shouldRepaint(covariant _SpectrumEQPainter oldDelegate) => true;
}

/* ---- 辅助频率与增益转换函数 ---- */

double _freqToX(double freq, double width) {
  final logMin = math.log(20.0);
  final logMax = math.log(20000.0);
  final clamped = freq.clamp(20.0, 20000.0);
  return ((math.log(clamped) - logMin) / (logMax - logMin)) * width;
}

double _xToFreq(double x, double width) {
  final logMin = math.log(20.0);
  final logMax = math.log(20000.0);
  final t = (x / width).clamp(0.0, 1.0);
  return math.exp(logMin + t * (logMax - logMin));
}

double _gainToY(double gain, double height) {
  final clamped = gain.clamp(-18.0, 18.0);
  return (1.0 - (clamped + 18.0) / 36.0) * height;
}

double _yToGain(double y, double height) {
  final t = (1.0 - y / height).clamp(0.0, 1.0);
  return (t * 36.0) - 18.0;
}
