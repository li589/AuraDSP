// part of effects_page.dart —— “空间音效” mega 卡（P3）。
// hero：风格三预设 + 极坐标全息声场雷达图（随 width 张开）+ 早期反射包络（随 room 动态伸缩）；
// 空间核心展开；混响 / 脉冲 / 声场（crossfeed+haas）/ 立体声折叠搬入。
// 共享 import 与 EffectsPage/ValueSlider/SectionCard 见父文件。
part of '../effects_page.dart';

/* ---- 09 空间音效（L1 参数化 HRTF + 早期反射；haas 后 / exciter 前） ---- */
class _SpatialCard extends StatelessWidget {
  final AppModel model;
  const _SpatialCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      hero: true,
      // 空间卡去编号（含内部搬入子卡）：独立分类，无需序号。
      index: null,
      title: l.spatialTitle,
      titleTooltip: l.spatialHint,
      collapsed: !model.spatialOn,
      latencyMs: model.componentLatency('spatial').ms,
      latencyMeasured: model.componentLatency('spatial').measured,
      latencyEstimated: model.componentLatency('spatial').estimated,
      latencyProbing: model.isProbingLatency('spatial'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('spatial')
          ? () => model.refreshComponentLatency('spatial')
          : null,
      latencyTick: model.getComponentLatencyTick('spatial'),
      trailing: ParamSwitch(
        param: ParamRegistry.spatialEnable,
        model: model,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // hero：风格三预设
          Row(
            children: [
              Text(l.spatialStyle, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.spatialStyleInfo),
              const Spacer(),
              ParamChoiceChips(
                param: ParamRegistry.spatialStyle,
                model: model,
                labels: [
                  l.spatialStyleDolby,
                  l.spatialStyleDts,
                  l.spatialStyleNeutral,
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // hero：全息极坐标声场雷达 + 空间早期反射包络（数据驱动，随 width/room 实时变化）
          _SpatialStageView(
            width: model.spatialWidth,
            room: model.spatialRoom,
            palette: p,
            active: model.spatialOn,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 空间核心（展开）
          ParamSlider(
            param: ParamRegistry.spatialRoom,
            model: model,
            customLabel: l.spatialRoom,
            infoMessage: l.spatialRoomInfo,
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialWidth,
            model: model,
            customLabel: l.spatialWidth,
            infoMessage: l.spatialWidthInfo,
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialCenter,
            model: model,
            customLabel: l.spatialCenter,
            infoMessage: l.spatialCenterInfo,
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialOutGain,
            model: model,
            customLabel: l.spatialOutGain,
            infoMessage: l.spatialOutGainInfo,
          ),
          const SizedBox(height: AuraSpace.sm),
          Row(
            children: [
              Text(l.spatialAutoGain, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.spatialAutoGainInfo),
              const Spacer(),
              ParamSwitch(
                param: ParamRegistry.spatialAutoGain,
                model: model,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          // 搬家区：混响 / 脉冲 / 声场（crossfeed+haas 合并）/ 立体声，折叠搬入。
          // 各卡自带折叠与开关，与搬家前行为一致；序号用 09.x 子编号。
          _SpatialReverbCard(model: model),
          const SizedBox(height: AuraSpace.sm),
          _ConvolverCard(model: model),
          const SizedBox(height: AuraSpace.sm),
          _CrossfeedCard(model: model),
          const SizedBox(height: AuraSpace.sm),
          _HaasCard(model: model),
          const SizedBox(height: AuraSpace.sm),
          _StereoCard(model: model),
        ],
      ),
    );
  }
}

/// 商业级全息极坐标声场雷达 + 空间早期反射包络时间线
class _SpatialStageView extends StatelessWidget {
  final double width;
  final double room;
  final AuraPalette palette;
  final bool active;
  const _SpatialStageView({
    required this.width,
    required this.room,
    required this.palette,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 154,
      decoration: BoxDecoration(
        color: palette.panel.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: palette.hairline.withValues(alpha: 0.4), width: 1.0),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        child: RepaintBoundary(
          child: CustomPaint(
            size: const Size(double.infinity, 154),
            painter: _SpatialStagePainter(
              width: width,
              room: room,
              palette: palette,
              active: active,
            ),
          ),
        ),
      ),
    );
  }
}

class _SpatialStagePainter extends CustomPainter {
  static const _degs = [-30.0, 0.0, 30.0, -110.0, 110.0];
  static const _labels = ['L', 'C', 'R', 'Ls', 'Rs'];
  static const _tapMs = [5.5, 9.0, 14.0, 21.0, 30.0, 42.0, 55.0, 68.0];
  static const _tapG = [0.25, 0.25, 0.18, 0.18, 0.12, 0.12, 0.07, 0.07];

  final double width;
  final double room;
  final AuraPalette palette;
  final bool active;

  _SpatialStagePainter({
    required this.width,
    required this.room,
    required this.palette,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    // ── 1. Top Section: 极坐标全息声场雷达 ──
    final cx = w / 2;
    const cy = 48.0;
    const radarR = 42.0;

    // (1) Polar concentric radar arcs
    final radarPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    final radii = [14.0, 28.0, radarR];
    for (final r in radii) {
      canvas.drawArc(
        Rect.fromCircle(center: Offset(cx, cy), radius: r),
        -math.pi * 0.9,
        math.pi * 1.8,
        false,
        radarPaint,
      );
    }

    // Radial guide spokes (-110, -30, 0, 30, 110 deg)
    final spokePaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.18)
      ..strokeWidth = 0.8;
    for (final deg in [-110.0, -30.0, 0.0, 30.0, 110.0]) {
      final rad = deg * math.pi / 180.0;
      final sx = cx + radii[0] * math.sin(rad);
      final sy = cy - radii[0] * math.cos(rad);
      final ex = cx + (radarR + 4) * math.sin(rad);
      final ey = cy - (radarR + 4) * math.cos(rad);
      canvas.drawLine(Offset(sx, sy), Offset(ex, ey), spokePaint);
    }

    // (2) Holographic Stereo Width Arc / Beam
    final halfAngle = (32.0 * width.clamp(0.2, 2.0)) * math.pi / 180.0;
    final coneR = radarR + 2.0;
    final conePath = Path();
    conePath.moveTo(cx, cy);
    conePath.arcTo(
      Rect.fromCircle(center: Offset(cx, cy), radius: coneR),
      -math.pi / 2.0 - halfAngle,
      halfAngle * 2.0,
      false,
    );
    conePath.close();

    final coneShader = RadialGradient(
      center: Alignment.center,
      radius: 0.9,
      colors: [
        active ? palette.accent.withValues(alpha: 0.20) : palette.textDim.withValues(alpha: 0.06),
        active ? palette.accent2.withValues(alpha: 0.03) : Colors.transparent,
      ],
    ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: coneR));

    final coneFillPaint = Paint()
      ..shader = coneShader
      ..style = PaintingStyle.fill;
    canvas.drawPath(conePath, coneFillPaint);

    final coneStrokePaint = Paint()
      ..color = (active ? palette.accent : palette.textDim).withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawPath(conePath, coneStrokePaint);

    // (3) Central Listener Head Origin
    final headPaint = Paint()
      ..color = palette.panelRaised
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), 6.5, headPaint);

    final headBorder = Paint()
      ..color = (active ? palette.accent : palette.textDim).withValues(alpha: 0.8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(Offset(cx, cy), 6.5, headBorder);

    // Small forward listening notch pointing straight up
    final notchPaint = Paint()
      ..color = active ? palette.accent : palette.textDim
      ..style = PaintingStyle.fill;
    final notchPath = Path()
      ..moveTo(cx - 2.5, cy - 6.5)
      ..lineTo(cx + 2.5, cy - 6.5)
      ..lineTo(cx, cy - 9.5)
      ..close();
    canvas.drawPath(notchPath, notchPaint);

    // (4) 5 Virtual 5.0 Spatial Speaker Pods
    for (var i = 0; i < _degs.length; i++) {
      final baseDeg = _degs[i];
      final isCenter = (i == 1);
      final isSurround = (i >= 3);
      var deg = baseDeg * (isSurround ? (0.75 + 0.25 * width) : width);
      if (deg < -160.0) deg = -160.0;
      if (deg > 160.0) deg = 160.0;
      final rad = deg * math.pi / 180.0;

      final spkDist = isCenter ? (radarR - 4.0) : radarR;
      final sx = cx + spkDist * math.sin(rad);
      final sy = cy - spkDist * math.cos(rad);

      final spkColor = isSurround ? palette.accent2 : palette.accent;

      // Glow halo
      if (active) {
        final haloPaint = Paint()
          ..color = spkColor.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
        canvas.drawCircle(Offset(sx, sy), 5.5, haloPaint);
      }

      // Speaker body
      final spkBodyPaint = Paint()
        ..color = palette.panelRaised
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(sx, sy), 4.0, spkBodyPaint);

      final spkStrokePaint = Paint()
        ..color = active ? spkColor : palette.textDim.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawCircle(Offset(sx, sy), 4.0, spkStrokePaint);

      // Core dot
      final coreDotPaint = Paint()
        ..color = active ? spkColor : palette.textDim
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(sx, sy), 1.8, coreDotPaint);

      // Radiated acoustic wavelets toward center
      if (active) {
        final wavePaint = Paint()
          ..color = spkColor.withValues(alpha: 0.25)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8;
        final waveRad = rad + math.pi;
        canvas.drawArc(
          Rect.fromCircle(center: Offset(sx, sy), radius: 8.0),
          waveRad - 0.45,
          0.9,
          false,
          wavePaint,
        );
      }

      // Channel label (L, C, R, Ls, Rs)
      final labelRad = rad;
      final lx = cx + (radarR + 11.0) * math.sin(labelRad);
      final ly = cy - (radarR + 11.0) * math.cos(labelRad);
      final tp = TextPainter(
        text: TextSpan(
          text: _labels[i],
          style: monoOf(
            palette,
            size: 7.5,
            color: active ? spkColor : palette.textDim.withValues(alpha: 0.6),
          ).copyWith(fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
    }

    // ── 2. Horizontal Divider & Status Readout ──
    const divY = 104.0;
    final divPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.35)
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(12.0, divY), Offset(w - 12.0, divY), divPaint);

    final tscale = 0.5 + 1.5 * room;
    final maxMs = 68.0 * 2.0;

    // Left title
    final leftTp = TextPainter(
      text: TextSpan(
        text: 'EARLY REFLECTIONS',
        style: monoOf(palette, size: 7.5, color: palette.textDim.withValues(alpha: 0.7))
            .copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    leftTp.paint(canvas, const Offset(14.0, divY - 11.0));

    // Right metric
    final roomPct = (room * 100).toInt();
    final delayMs = (tscale * 68.0).toStringAsFixed(1);
    final rightTp = TextPainter(
      text: TextSpan(
        text: '$roomPct% ROOM · $delayMs ms',
        style: monoOf(palette, size: 7.5, color: active ? palette.accent : palette.textDim)
            .copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    rightTp.paint(canvas, Offset(w - 14.0 - rightTp.width, divY - 11.0));

    // ── 3. Bottom Section: 空间早期反射包络 ──
    const baseY = 130.0;
    const leftPad = 20.0;
    final rightPad = 20.0;
    final plotW = w - leftPad - rightPad;

    // Baseline
    final baseLinePaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.25)
      ..strokeWidth = 0.8;
    canvas.drawLine(Offset(leftPad, baseY), Offset(w - rightPad, baseY), baseLinePaint);

    // Exponential Decay Curves (upper L, lower R)
    final envPathUpper = Path()..moveTo(leftPad, baseY - 18.0);
    final envPathLower = Path()..moveTo(leftPad, baseY + 18.0);
    for (var x = 0; x <= 40; x++) {
      final frac = x / 40.0;
      final px = leftPad + frac * plotW;
      final decay = math.exp(-frac * 2.4);
      envPathUpper.lineTo(px, baseY - 18.0 * decay);
      envPathLower.lineTo(px, baseY + 18.0 * decay);
    }
    final envPaint = Paint()
      ..color = palette.textDim.withValues(alpha: 0.15)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;
    canvas.drawPath(envPathUpper, envPaint);
    canvas.drawPath(envPathLower, envPaint);

    // 8 Early Reflection Taps
    for (var t = 0; t < _tapMs.length; ++t) {
      final tapFrac = (_tapMs[t] * tscale / maxMs).clamp(0.0, 1.0);
      final tx = leftPad + plotW * tapFrac;
      final h = 3.5 + 15.0 * (_tapG[t] / 0.25);
      final isLeft = (t % 2 == 0);
      final dir = isLeft ? -1.0 : 1.0;
      final ty = baseY + dir * h;

      final tapColor = isLeft ? palette.accent : palette.accent2;

      // Vertical stem with gradient
      final stemPaint = Paint()
        ..color = active ? tapColor.withValues(alpha: 0.75) : palette.textDim.withValues(alpha: 0.35)
        ..strokeWidth = 1.8
        ..strokeCap = StrokeCap.round;
      canvas.drawLine(Offset(tx, baseY), Offset(tx, ty), stemPaint);

      // Tap particle head
      if (active) {
        final headGlow = Paint()
          ..color = tapColor.withValues(alpha: 0.4)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 2.5);
        canvas.drawCircle(Offset(tx, ty), 3.0, headGlow);
      }
      final headDot = Paint()
        ..color = active ? tapColor : palette.textDim
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(tx, ty), 1.5, headDot);
    }
  }

  @override
  bool shouldRepaint(_SpatialStagePainter old) =>
      old.width != width || old.room != room || old.active != active || old.palette != palette;
}
