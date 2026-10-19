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
      index: kEffectCardIndex['spatial'],
      title: l.spatialTitle,
      titleTooltip: l.spatialHint,
      collapsed: !model.spatialOn,
      latencyMs: model.componentLatency('spatial').ms,
      latencyEnabled: model.isSectionEnabled('spatial'),
      latencyMeasured: model.componentLatency('spatial').measured,
      latencyEstimated: model.componentLatency('spatial').estimated,
      latencyProbing: model.isProbingLatency('spatial'),
      onRefreshLatency: AppModel.hasLatencyRefresh('spatial')
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
          // 风格预设选择
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
                  l.spatialStyleCinema,
                  l.spatialStyleImaging,
                  l.spatialStyleNeutral,
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),

          // 极简物理声场渲染视效
          _SpatialStageView(
            width: model.spatialWidth,
            room: model.spatialRoom,
            center: model.spatialCenter,
            palette: p,
            active: model.spatialOn,
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialMix,
            model: model,
            customLabel: l.spatialMix,
            infoMessage: l.spatialMixInfo,
          ),
          const SizedBox(height: AuraSpace.sm),

          // 核心空间控制滑块
          ParamSlider(
            param: ParamRegistry.spatialRoom,
            model: model,
            customLabel: l.spatialRoom,
            infoMessage: '模拟虚拟声学室的物理反射体量。数值越大空间感越深邃宏大，反射余韵越丰满。',
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialWidth,
            model: model,
            customLabel: l.spatialWidth,
            infoMessage: '扩展双耳立体声张角与虚拟环绕音箱间距。拉大可获得脱箱广阔声场，适度调控以保声音饱满。',
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialCenter,
            model: model,
            customLabel: l.spatialCenter,
            infoMessage: '控制中央人声与对白结像实体聚焦感。适度提升可令人声居中清晰且不被环绕声掩盖。',
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialElevation,
            model: model,
            customLabel: l.spatialElevation,
            infoMessage: l.spatialElevationInfo,
          ),
          const SizedBox(height: AuraSpace.sm),
          Row(
            children: [
              Text(l.spatialBinaural, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.spatialBinauralInfo),
              const Spacer(),
              ParamSwitch(
                param: ParamRegistry.spatialBinaural,
                model: model,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          Row(
            children: [
              Text(l.spatialFdn, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.spatialFdnInfo),
              const Spacer(),
              ParamSwitch(
                param: ParamRegistry.spatialFdn,
                model: model,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialLate,
            model: model,
            customLabel: l.spatialLate,
            infoMessage: l.spatialLateInfo,
          ),
          const SizedBox(height: AuraSpace.sm),
          Row(
            children: [
              Text(l.spatialHeadTrack, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.spatialHeadTrackInfo),
              const Spacer(),
              ParamSwitch(
                param: ParamRegistry.spatialHeadTrack,
                model: model,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialHeadAzim,
            model: model,
            customLabel: l.spatialHeadAzim,
            infoMessage: l.spatialHeadAzimInfo,
          ),
          const SizedBox(height: AuraSpace.sm),
          ParamSlider(
            param: ParamRegistry.spatialOutGain,
            model: model,
            customLabel: l.spatialOutGain,
            infoMessage: '在全自动等能量物理归一化基础上的输出增益微调 (-12 ~ +6 dB)。',
          ),
          const SizedBox(height: AuraSpace.sm),
          Row(
            children: [
              Text(l.spatialAutoGain, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              const InfoBadge(message: '全站等响度自动平衡算法。自动平抑多扬声器上混带来的能量增益，彻底杜绝滑块变音量调节器的问题。'),
              const Spacer(),
              ParamSwitch(
                param: ParamRegistry.spatialAutoGain,
                model: model,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 极简全景声学声场可视化
class _SpatialStageView extends StatelessWidget {
  final double width;
  final double room;
  final double center;
  final AuraPalette palette;
  final bool active;

  const _SpatialStageView({
    required this.width,
    required this.room,
    required this.center,
    required this.palette,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      height: 160,
      decoration: BoxDecoration(
        color: palette.panel.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: palette.hairline.withValues(alpha: 0.4), width: 1.0),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        child: RepaintBoundary(
          child: CustomPaint(
            size: const Size(double.infinity, 160),
            painter: _SpatialStagePainter(
              width: width,
              room: room,
              center: center,
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
  static const _spkLabels = ['L', 'C', 'R', 'Ls', 'Rs'];
  static const _spkBaseAngles = [-30.0, 0.0, 30.0, -110.0, 110.0];

  final double width;
  final double room;
  final double center;
  final AuraPalette palette;
  final bool active;

  _SpatialStagePainter({
    required this.width,
    required this.room,
    required this.center,
    required this.palette,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final cx = w / 2;
    final cy = h * 0.52;
    final soundstageR = math.min(w * 0.38, h * 0.42);

    // ── 1. Corner Labels ──
    final titleTp = TextPainter(
      text: TextSpan(
        text: 'VIRTUAL 5.0 SOUNDSTAGE',
        style: monoOf(palette, size: 8, color: palette.textDim.withValues(alpha: 0.6))
            .copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    titleTp.paint(canvas, const Offset(12.0, 10.0));

    final widthPct = (width * 100).toInt();
    final roomPct = (room * 100).toInt();
    final metricTp = TextPainter(
      text: TextSpan(
        text: 'WIDTH $widthPct% · ROOM $roomPct%',
        style: monoOf(palette, size: 8, color: active ? palette.accent : palette.textDim.withValues(alpha: 0.5))
            .copyWith(fontWeight: FontWeight.w600),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    metricTp.paint(canvas, Offset(w - 12.0 - metricTp.width, 10.0));

    // ── 2. Subtle Acoustic Wavefield Rings ──
    final ringPaint = Paint()
      ..color = palette.hairline.withValues(alpha: active ? 0.22 : 0.10)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.8;

    final ringSteps = [0.35, 0.65, 1.0];
    for (final frac in ringSteps) {
      canvas.drawCircle(Offset(cx, cy), soundstageR * frac, ringPaint);
    }

    // ── 3. Dynamic Soundstage Aperture Cone (随 width 展开) ──
    final halfDeg = (28.0 + 38.0 * (width - 0.5)).clamp(25.0, 75.0);
    final halfRad = halfDeg * math.pi / 180.0;

    final conePath = Path();
    conePath.moveTo(cx, cy);
    conePath.arcTo(
      Rect.fromCircle(center: Offset(cx, cy), radius: soundstageR),
      -math.pi / 2.0 - halfRad,
      halfRad * 2.0,
      false,
    );
    conePath.close();

    final coneShader = RadialGradient(
      center: Alignment.center,
      radius: 0.85,
      colors: [
        active ? palette.accent.withValues(alpha: 0.20) : palette.textDim.withValues(alpha: 0.05),
        active ? palette.accent.withValues(alpha: 0.02) : Colors.transparent,
      ],
    ).createShader(Rect.fromCircle(center: Offset(cx, cy), radius: soundstageR));

    final conePaint = Paint()
      ..shader = coneShader
      ..style = PaintingStyle.fill;
    canvas.drawPath(conePath, conePaint);

    // Cone boundary rays
    final rayPaint = Paint()
      ..color = (active ? palette.accent : palette.textDim).withValues(alpha: 0.25)
      ..strokeWidth = 0.8;
    final leftRay = Offset(cx + soundstageR * math.sin(-halfRad), cy - soundstageR * math.cos(-halfRad));
    final rightRay = Offset(cx + soundstageR * math.sin(halfRad), cy - soundstageR * math.cos(halfRad));
    canvas.drawLine(Offset(cx, cy), leftRay, rayPaint);
    canvas.drawLine(Offset(cx, cy), rightRay, rayPaint);

    // ── 4. Central Vocal Focus Beam (随 center 强度聚拢) ──
    if (active && center > 0.05) {
      final centerBeamPath = Path();
      const beamHalfDeg = 12.0;
      final beamHalfRad = beamHalfDeg * math.pi / 180.0;
      centerBeamPath.moveTo(cx, cy);
      centerBeamPath.arcTo(
        Rect.fromCircle(center: Offset(cx, cy), radius: soundstageR * 0.95),
        -math.pi / 2.0 - beamHalfRad,
        beamHalfRad * 2.0,
        false,
      );
      centerBeamPath.close();

      final beamPaint = Paint()
        ..color = palette.accent2.withValues(alpha: 0.12 * center)
        ..style = PaintingStyle.fill;
      canvas.drawPath(centerBeamPath, beamPaint);
    }

    // ── 5. Ambient Physical Room Diffusion Particles (高斯微粒扩散场) ──
    if (active && room > 0.02) {
      final particlePaint = Paint()..style = PaintingStyle.fill;
      const particleCount = 28;
      for (var i = 0; i < particleCount; i++) {
        final seedAngle = (i * 13.37) % (2 * math.pi);
        final baseDist = soundstageR * (0.8 + 0.35 * room * (((i * 7) % 10) / 10.0));
        final px = cx + baseDist * math.cos(seedAngle);
        final py = cy + baseDist * math.sin(seedAngle);

        if (px >= 6 && px <= w - 6 && py >= 6 && py <= h - 6) {
          final pAlpha = (0.15 + 0.35 * (1.0 - ((baseDist - soundstageR) / soundstageR).clamp(0.0, 1.0))) * room;
          particlePaint.color = palette.accent.withValues(alpha: pAlpha.clamp(0.05, 0.45));
          canvas.drawCircle(Offset(px, py), 1.2, particlePaint);
        }
      }
    }

    // ── 6. 5 Spatial Transducer Pods (L, C, R, Ls, Rs) ──
    for (var i = 0; i < _spkBaseAngles.length; i++) {
      final baseDeg = _spkBaseAngles[i];
      final isCenter = (i == 1);
      final isSurround = (i >= 3);

      var deg = baseDeg;
      if (!isCenter) {
        if (isSurround) {
          deg = baseDeg * (0.85 + 0.15 * width);
        } else {
          deg = baseDeg * width;
        }
      }
      final rad = deg * math.pi / 180.0;
      final dist = isCenter ? (soundstageR * 0.92) : soundstageR;
      final sx = cx + dist * math.sin(rad);
      final sy = cy - dist * math.cos(rad);

      final col = isSurround ? palette.accent2 : palette.accent;

      // Soft glow halo
      if (active) {
        final glow = Paint()
          ..color = col.withValues(alpha: 0.30)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5.0);
        canvas.drawCircle(Offset(sx, sy), 6.0, glow);
      }

      // Speaker body
      final bodyPaint = Paint()
        ..color = palette.panelRaised
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(sx, sy), 4.5, bodyPaint);

      final borderPaint = Paint()
        ..color = active ? col : palette.textDim.withValues(alpha: 0.4)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2;
      canvas.drawCircle(Offset(sx, sy), 4.5, borderPaint);

      final corePaint = Paint()
        ..color = active ? col : palette.textDim
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(sx, sy), 1.8, corePaint);

      // Label
      final lx = cx + (dist + 12.0) * math.sin(rad);
      final ly = cy - (dist + 12.0) * math.cos(rad);
      final tp = TextPainter(
        text: TextSpan(
          text: _spkLabels[i],
          style: monoOf(palette, size: 8, color: active ? col : palette.textDim)
              .copyWith(fontWeight: FontWeight.w600),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(lx - tp.width / 2, ly - tp.height / 2));
    }

    // ── 7. Central Binaural Listener Head ──
    final headRadius = 7.0;
    // Ear nubs (L & R)
    final earPaint = Paint()
      ..color = (active ? palette.accent : palette.textDim).withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx - headRadius, cy), radius: 2.5),
      math.pi * 0.5,
      math.pi,
      false,
      earPaint,
    );
    canvas.drawArc(
      Rect.fromCircle(center: Offset(cx + headRadius, cy), radius: 2.5),
      -math.pi * 0.5,
      math.pi,
      false,
      earPaint,
    );

    // Head circle
    final headFill = Paint()
      ..color = palette.panelRaised
      ..style = PaintingStyle.fill;
    canvas.drawCircle(Offset(cx, cy), headRadius, headFill);

    final headBorder = Paint()
      ..color = active ? palette.accent : palette.textDim.withValues(alpha: 0.7)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;
    canvas.drawCircle(Offset(cx, cy), headRadius, headBorder);

    // Forward direction pointer (nose notch)
    final notchPaint = Paint()
      ..color = active ? palette.accent : palette.textDim
      ..style = PaintingStyle.fill;
    final notch = Path()
      ..moveTo(cx - 2.5, cy - headRadius)
      ..lineTo(cx + 2.5, cy - headRadius)
      ..lineTo(cx, cy - headRadius - 3.5)
      ..close();
    canvas.drawPath(notch, notchPaint);

    // ── 8. Bottom Status Tag ──
    final tagTp = TextPainter(
      text: TextSpan(
        text: 'EQUAL-LOUDNESS CALIBRATED',
        style: monoOf(palette, size: 7.5, color: palette.textDim.withValues(alpha: 0.45)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tagTp.paint(canvas, Offset(cx - tagTp.width / 2, h - 14.0));
  }

  @override
  bool shouldRepaint(_SpatialStagePainter old) =>
      old.width != width ||
      old.room != room ||
      old.center != center ||
      old.active != active ||
      old.palette != palette;
}
