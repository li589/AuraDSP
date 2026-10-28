// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';

/* =========================================================================
 * 数据驱动自绑定 UI 控件体系 (Declarative Param Controls - Phase 4)
 * ========================================================================= */

/// 自绑定数值滑块：直接由 ParamSpec 强类型驱动，自动承接范围、步进、单位、格式化与默认值
class ParamSlider extends StatelessWidget {
  final ParamSpec<double> param;
  final AppModel model;
  final String? customLabel;
  final String? infoMessage;
  final bool? enabled;
  final String Function(double)? customFormat;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangedEnd;
  final VoidCallback? onResetToDefault;
  final double? customMin;
  final double? customMax;
  final String? customUnit;
  final bool overridden;
  final String? overriddenNote;

  const ParamSlider({
    super.key,
    required this.param,
    required this.model,
    this.customLabel,
    this.infoMessage,
    this.enabled,
    this.customFormat,
    this.customMin,
    this.customMax,
    this.customUnit,
    this.onChanged,
    this.onChangedEnd,
    this.onResetToDefault,
    this.overridden = false,
    this.overriddenNote,
  });

  @override
  Widget build(BuildContext context) {
    final val = model.getParam(param);
    final isEn = enabled ?? model.isSectionEnabled(param.section);
    return ValueSlider(
      label: customLabel ?? param.key,
      infoMessage: infoMessage,
      value: val,
      defaultValue: param.defaultValue,
      min: customMin ?? param.min,
      max: customMax ?? param.max,
      unit: customUnit ?? param.unit,
      enabled: isEn,
      format: customFormat ?? param.formatter ?? (v) => v.toStringAsFixed(1),
      overridden: overridden,
      overriddenNote: overriddenNote,
      onResetToDefault: onResetToDefault ?? () => model.setParam(param, param.defaultValue),
      onChanged: (v) {
        model.setParam(param, v);
        onChanged?.call(v);
      },
      onChangedEnd: (v) {
        model.setParam(param, v);
        onChangedEnd?.call(v);
      },
    );
  }
}

/// 自绑定开关：直接由 `ParamSpec<bool>` 驱动
class ParamSwitch extends StatelessWidget {
  final ParamSpec<bool> param;
  final AppModel model;
  final bool? enabled;
  final ValueChanged<bool>? onChanged;

  const ParamSwitch({
    super.key,
    required this.param,
    required this.model,
    this.enabled,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final val = model.getParam(param);
    final isEn = enabled ?? (param.key == 'enable' || param.key == 'on' ? true : model.isSectionEnabled(param.section));
    return AuraSwitch(
      value: val,
      onChanged: isEn
          ? (v) {
              model.setParam(param, v);
              onChanged?.call(v);
            }
          : null,
    );
  }
}

/// 自绑定选项组：直接由 `ParamSpec<int>` 驱动，呈现横向 ChoiceChips
class ParamChoiceChips extends StatelessWidget {
  final ParamSpec<int> param;
  final AppModel model;
  final List<String>? labels;
  final bool? enabled;
  final ValueChanged<int>? onChanged;

  const ParamChoiceChips({
    super.key,
    required this.param,
    required this.model,
    this.labels,
    this.enabled,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final cur = model.getParam(param);
    final opts = labels ?? param.options ?? const [];
    final isEn = enabled ?? model.isSectionEnabled(param.section);
    return Wrap(
      spacing: AuraSpace.sm,
      runSpacing: AuraSpace.xs,
      children: List.generate(opts.length, (idx) {
        return AuraChoiceChip(
          label: opts[idx],
          selected: cur == idx,
          onTap: isEn
              ? () {
                  model.setParam(param, idx);
                  onChanged?.call(idx);
                }
              : null,
        );
      }),
    );
  }
}

/// 自绑定自动增益补偿行：连接 `ParamSpec<bool>` 与 _AutoGainRow
class ParamAutoGainRow extends StatelessWidget {
  final ParamSpec<bool> param;
  final AppModel model;
  final String label;
  final String tooltip;
  final bool? enabled;
  final ValueChanged<bool>? onChanged;

  const ParamAutoGainRow({
    super.key,
    required this.param,
    required this.model,
    required this.label,
    required this.tooltip,
    this.enabled,
    this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final isEn = enabled ?? model.isSectionEnabled(param.section);
    return _AutoGainRow(
      label: label,
      tooltip: tooltip,
      value: model.getParam(param),
      enabled: isEn,
      onChanged: (v) {
        model.setParam(param, v);
        onChanged?.call(v);
      },
    );
  }
}

/// 自绑定输出增益门滑块：标准 [-12, +6] dB 输出门
class ParamOutputGainSlider extends StatelessWidget {
  final ParamSpec<double> param;
  final AppModel model;
  final String label;
  final String infoMessage;
  final bool? enabled;

  const ParamOutputGainSlider({
    super.key,
    required this.param,
    required this.model,
    required this.label,
    required this.infoMessage,
    this.enabled,
  });

  @override
  Widget build(BuildContext context) {
    return ParamSlider(
      param: param,
      model: model,
      customLabel: label,
      infoMessage: infoMessage,
      enabled: enabled,
    );
  }
}

class _AutoGainRow extends StatelessWidget {
  final String label;
  final String tooltip;
  final bool value;
  final bool enabled;
  final ValueChanged<bool> onChanged;

  const _AutoGainRow({
    required this.label,
    required this.tooltip,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Tooltip(
      message: tooltip,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: AuraSpace.xs),
        child: Row(
          children: [
            Icon(Icons.auto_fix_high_rounded, size: 16, color: value ? p.accent : p.textDim),
            const SizedBox(width: AuraSpace.sm),
            Expanded(
              child: Text(
                label,
                style: captionOf(p).copyWith(
                  color: enabled ? p.text : p.textDim,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            AuraSwitch(
              value: value,
              onChanged: enabled ? onChanged : null,
            ),
          ],
        ),
      ),
    );
  }
}

class _ResourceSlot extends StatelessWidget {
  const _ResourceSlot({
    required this.icon,
    required this.title,
    required this.actions,
    this.detail,
  });

  final IconData icon;
  final String title;
  final String? detail;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AuraSpace.sm),
      decoration: BoxDecoration(
        color: p.panel,
        border: Border.all(color: p.hairline),
        borderRadius: BorderRadius.circular(AuraRadius.md),
      ),
      child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(icon, size: 14, color: p.textDim),
            const SizedBox(width: 6),
            // [PATCHED-AuraDSP P-032] 标题可能是一长串 IR 文件名 → 用
            // Flexible + ellipsis 让它可压缩，不把右侧按钮挤出边界。
            Flexible(
              child: Text(
                title,
                style: captionOf(p),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
            if (detail != null) ...[
              const SizedBox(width: AuraSpace.sm),
              Text(
                detail!,
                style: captionOf(p).copyWith(color: p.accent),
              ),
            ],
            const Spacer(),
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: actions,
            ),
          ],
        ),
    );
  }
}

/* ---- 脉冲响应波形与频响包络 (EasyEffects 风格真实双声道波形图) ---- */

class _IrWaveformGraph extends StatefulWidget {
  final List<List<double>> spectrum;
  final int channels;

  const _IrWaveformGraph({
    required this.spectrum,
    required this.channels,
  });

  @override
  State<_IrWaveformGraph> createState() => _IrWaveformGraphState();
}

class _IrWaveformGraphState extends State<_IrWaveformGraph> {
  bool _isLogScale = true;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final isMono = widget.channels <= 1;

    return Container(
      padding: const EdgeInsets.all(AuraSpace.sm),
      decoration: BoxDecoration(
        color: p.panelRaised.withValues(alpha: 0.8),
        borderRadius: BorderRadius.circular(AuraRadius.md),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.waves_rounded, size: 14, color: p.accent),
              const SizedBox(width: 6),
              Text(l10nOf(context).irEnvelope,
                  style: captionOf(p).copyWith(fontWeight: FontWeight.w600, color: p.text)),
              const SizedBox(width: AuraSpace.sm),
              // 声道指示点
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(width: 8, height: 8, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFF00E5FF))),
                  const SizedBox(width: 4),
                  Text('L', style: monoOf(p, size: 10, color: p.textDim)),
                  const SizedBox(width: 8),
                  Container(width: 8, height: 8, decoration: const BoxDecoration(shape: BoxShape.circle, color: Color(0xFFF43F5E))),
                  const SizedBox(width: 4),
                  Text(isMono ? l10nOf(context).irMirrorR : 'R', style: monoOf(p, size: 10, color: p.textDim)),
                ],
              ),
              const Spacer(),
              // 模式切换 Chip：Linear / Log dB
              Container(
                decoration: BoxDecoration(
                  color: p.panel,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                padding: const EdgeInsets.all(2),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _scaleButton(
                      label: 'Linear',
                      selected: !_isLogScale,
                      onTap: () => setState(() => _isLogScale = false),
                      p: p,
                    ),
                    _scaleButton(
                      label: 'Log dB',
                      selected: _isLogScale,
                      onTap: () => setState(() => _isLogScale = true),
                      p: p,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          ClipRRect(
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            child: Container(
              height: 110,
              width: double.infinity,
              color: Colors.black.withValues(alpha: 0.3),
              child: CustomPaint(
                size: const Size(double.infinity, 110),
                painter: _IrWaveformPainter(
                  spectrum: widget.spectrum,
                  channels: widget.channels,
                  isLogScale: _isLogScale,
                  palette: p,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _scaleButton({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    required AuraPalette p,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AuraRadius.xs),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: selected ? p.accent.withValues(alpha: 0.25) : Colors.transparent,
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          border: selected ? Border.all(color: p.accent.withValues(alpha: 0.5), width: 1) : null,
        ),
        child: Text(
          label,
          style: monoOf(p, size: 10, color: selected ? p.accent : p.textDim),
        ),
      ),
    );
  }
}

class _IrWaveformPainter extends CustomPainter {
  final List<List<double>> spectrum;
  final int channels;
  final bool isLogScale;
  final AuraPalette palette;

  _IrWaveformPainter({
    required this.spectrum,
    required this.channels,
    required this.isLogScale,
    required this.palette,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0 || spectrum.isEmpty) return;

    final gridPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.25)
      ..strokeWidth = 1.0;

    final textStyle = TextStyle(
      color: palette.textDim.withValues(alpha: 0.6),
      fontSize: 9,
      fontFamily: 'monospace',
    );

    // 绘制横向刻度线 (Grid)
    final lines = isLogScale ? [0.0, -20.0, -40.0, -60.0] : [1.0, 0.75, 0.5, 0.25, 0.0];
    for (final val in lines) {
      final yFrac = isLogScale ? (1.0 - (val + 60.0) / 60.0) : (1.0 - val);
      final y = (yFrac * (h - 16) + 6).clamp(6.0, h - 10);
      canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);

      final label = isLogScale ? '${val.toInt()}dB' : '${(val * 100).round()}%';
      final tp = TextPainter(
        text: TextSpan(text: label, style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(w - tp.width - 4, y - tp.height - 1));
    }

    // 频段标签：20Hz, 100Hz, 500Hz, 2kHz, 10kHz, 20kHz
    final freqLabels = ['20Hz', '100Hz', '500Hz', '2kHz', '10kHz', '20kHz'];
    for (var i = 0; i < freqLabels.length; i++) {
      final x = (i / (freqLabels.length - 1)) * (w - 40) + 10;
      final tp = TextPainter(
        text: TextSpan(text: freqLabels[i], style: textStyle),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(x, h - tp.height - 2));
    }

    // 提取 L 和 R 数据
    final lData = spectrum[0];
    final rData = spectrum.length > 1 ? spectrum[1] : spectrum[0]; // 单声道自动镜像为双声道

    // 绘制左右声道平滑曲线与渐变
    _drawChannelPath(canvas, size, rData, const Color(0xFFF43F5E), isRight: true);
    _drawChannelPath(canvas, size, lData, const Color(0xFF00E5FF), isRight: false);
  }

  void _drawChannelPath(
    Canvas canvas,
    Size size,
    List<double> rawData,
    Color color, {
    required bool isRight,
  }) {
    if (rawData.isEmpty) return;
    final w = size.width;
    final h = size.height - 18; // 留出底端频标空间
    final n = rawData.length;

    // 坐标计算
    final points = <Offset>[];
    for (var i = 0; i < n; i++) {
      final x = (i / (n - 1)) * w;
      var rawVal = rawData[i].clamp(0.0, 1.0);
      double yFrac;
      if (isLogScale) {
        // -60dB ~ 0dB
        final db = (rawVal > 1e-3) ? (20.0 * math.log(rawVal) / math.ln10) : -60.0;
        final clampedDb = db.clamp(-60.0, 0.0);
        yFrac = (clampedDb + 60.0) / 60.0;
      } else {
        yFrac = rawVal;
      }
      final y = h - (yFrac * (h - 8)) - 4;
      points.add(Offset(x, y.clamp(2.0, h)));
    }

    if (points.isEmpty) return;

    // 构建平滑贝塞尔曲线
    final path = Path();
    path.moveTo(points[0].dx, points[0].dy);
    for (var i = 0; i < points.length - 1; i++) {
      final p0 = points[i];
      final p1 = points[i + 1];
      final cx = (p0.dx + p1.dx) / 2;
      path.cubicTo(cx, p0.dy, cx, p1.dy, p1.dx, p1.dy);
    }

    // 填充渐变 Path
    final fillPath = Path.from(path)
      ..lineTo(w, h)
      ..lineTo(0, h)
      ..close();

    final fillPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          color.withValues(alpha: isRight ? 0.20 : 0.25),
          color.withValues(alpha: 0.02),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;

    canvas.drawPath(fillPath, fillPaint);

    // 描边主线条（带发光感）
    final linePaint = Paint()
      ..color = color.withValues(alpha: 0.90)
      ..strokeWidth = 2.0
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    canvas.drawPath(path, linePaint);
  }

  @override
  bool shouldRepaint(covariant _IrWaveformPainter oldDelegate) =>
      oldDelegate.spectrum != spectrum ||
      oldDelegate.channels != channels ||
      oldDelegate.isLogScale != isLogScale ||
      oldDelegate.palette != palette;
}

/* ---- 3D 声场空间渲染 (高级可视化：透视网格 + 声波扩散 + 衰减光晕) ---- */

/* ---- 3D 高级声学腔体仿真渲染 (深邃透视 + 物理漫反射扩散粒子 + 声学吸音构架 + 专业 HUD) ---- */

class _Freeverb3DStage extends StatelessWidget {
  final double decay;
  final double damp;
  final double roomSize;
  final double stereoWidth;
  final bool active;

  const _Freeverb3DStage({
    required this.decay,
    required this.damp,
    this.roomSize = 1.2,
    this.stereoWidth = 1.0,
    required this.active,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(AuraRadius.sm),
      child: Container(
        height: 154,
        decoration: BoxDecoration(
          color: p.panelRaised.withValues(alpha: 0.75),
          border: Border.all(color: p.hairline.withValues(alpha: 0.65)),
        ),
        child: CustomPaint(
          size: Size.infinite,
          painter: _Freeverb3DPainter(
            decay: decay,
            damp: damp,
            roomSize: roomSize,
            stereoWidth: stereoWidth,
            palette: p,
            active: active,
          ),
        ),
      ),
    );
  }
}

class _Freeverb3DPainter extends CustomPainter {
  final double decay;
  final double damp;
  final double roomSize;
  final double stereoWidth;
  final AuraPalette palette;
  final bool active;

  _Freeverb3DPainter({
    required this.decay,
    required this.damp,
    required this.roomSize,
    required this.stereoWidth,
    required this.palette,
    required this.active,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w <= 0 || h <= 0) return;

    final baseAlpha = active ? 1.0 : 0.22;
    // 空间体量膨胀因子：0.5 ~ 2.4
    final sizeFactor = (roomSize / 1.2).clamp(0.5, 2.4);

    // ── 0. 声学暗场底衬与景深光晕 ──
    final bgRect = Rect.fromLTWH(0, 0, w, h);
    final bgShader = RadialGradient(
      center: const Alignment(0.0, -0.2),
      radius: 1.1,
      colors: [
        active
            ? palette.accent.withValues(alpha: 0.08)
            : palette.panelRaised.withValues(alpha: 0.4),
        palette.panelRaised.withValues(alpha: 0.95),
      ],
    ).createShader(bgRect);
    canvas.drawRect(bgRect, Paint()..shader = bgShader);

    // 消失点（透视汇聚中心）
    final vpX = w / 2;
    final vpY = (h * (0.24 - (sizeFactor - 1.0) * 0.05)).clamp(h * 0.10, h * 0.32);

    // 房间地面与边界关键坐标点
    final flL = Offset(w * 0.02, h * 0.98);
    final flR = Offset(w * 0.98, h * 0.98);
    final backHalfW = (w * (0.34 / math.sqrt(sizeFactor))).clamp(w * 0.18, w * 0.42);
    final bkL = Offset(vpX - backHalfW, vpY + 14);
    final bkR = Offset(vpX + backHalfW, vpY + 14);

    // ── 1. 地面高精密声学雷达网格 (Perspective Acoustic Floor Grid) ──
    final floorGridPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.18 * baseAlpha)
      ..strokeWidth = 0.6;

    // 纵深放射线（10 条，向消失点汇聚）
    const numLongLines = 10;
    for (var i = 0; i <= numLongLines; i++) {
      final t = i / numLongLines;
      final botX = flL.dx + (flR.dx - flL.dx) * t;
      final topX = bkL.dx + (bkR.dx - bkL.dx) * t;
      canvas.drawLine(Offset(botX, flL.dy), Offset(topX, bkL.dy), floorGridPaint);
    }

    // 横向等时间距离线（7 条，按指数透视排布）
    const numLatLines = 7;
    for (var i = 0; i <= numLatLines; i++) {
      final t = math.pow(i / numLatLines, 1.7).toDouble();
      final y = flL.dy + (bkL.dy - flL.dy) * t;
      final lx = flL.dx + (bkL.dx - flL.dx) * t;
      final rx = flR.dx + (bkR.dx - flR.dx) * t;
      canvas.drawLine(Offset(lx, y), Offset(rx, y), floorGridPaint);
    }

    // ── 2. 3D 声学室后墙与天花板吸音吊顶 (Ceiling Acoustic Baffles) ──
    final ceilH = (26.0 * math.sqrt(sizeFactor)).clamp(18.0, 44.0);
    final ceilL = Offset(bkL.dx, bkL.dy - ceilH);
    final ceilR = Offset(bkR.dx, bkR.dy - ceilH);

    // 后墙半透明体块
    final backWallPath = Path()
      ..moveTo(bkL.dx, bkL.dy)
      ..lineTo(bkR.dx, bkR.dy)
      ..lineTo(ceilR.dx, ceilR.dy)
      ..lineTo(ceilL.dx, ceilL.dy)
      ..close();
    final backWallPaint = Paint()
      ..color = (active ? palette.accent : palette.textDim).withValues(alpha: 0.04 * baseAlpha)
      ..style = PaintingStyle.fill;
    canvas.drawPath(backWallPath, backWallPaint);

    final wallFramePaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.35 * baseAlpha)
      ..strokeWidth = 0.9;
    canvas.drawPath(backWallPath, wallFramePaint..style = PaintingStyle.stroke);

    // 侧墙与地面主轮廓线
    canvas.drawLine(flL, bkL, wallFramePaint);
    canvas.drawLine(flR, bkR, wallFramePaint);

    // 悬浮天花板声学吊顶棱线 (Acoustic Cloud Ribs)
    final topFrontL = Offset(flL.dx, flL.dy - h * 0.76);
    final topFrontR = Offset(flR.dx, flR.dy - h * 0.76);
    final ceilingRibPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.16 * baseAlpha)
      ..strokeWidth = 0.6;
    canvas.drawLine(topFrontL, ceilL, ceilingRibPaint);
    canvas.drawLine(topFrontR, ceilR, ceilingRibPaint);

    // ── 3. 左右侧壁声学吸音扩散格栅 (Acoustic Diffuser Panels) ──
    final panelCount = 4;
    for (var i = 1; i <= panelCount; i++) {
      final t1 = (i - 0.7) / panelCount;
      final t2 = (i - 0.2) / panelCount;

      final p1Bottom = Offset(flL.dx + (bkL.dx - flL.dx) * t1, flL.dy + (bkL.dy - flL.dy) * t1);
      final p1Top = Offset(topFrontL.dx + (ceilL.dx - topFrontL.dx) * t1, topFrontL.dy + (ceilL.dy - topFrontL.dy) * t1);
      final p2Bottom = Offset(flL.dx + (bkL.dx - flL.dx) * t2, flL.dy + (bkL.dy - flL.dy) * t2);
      final p2Top = Offset(topFrontL.dx + (ceilL.dx - topFrontL.dx) * t2, topFrontL.dy + (ceilL.dy - topFrontL.dy) * t2);

      // 左侧吸音块
      final leftPanel = Path()
        ..moveTo(p1Bottom.dx, p1Bottom.dy)
        ..lineTo(p2Bottom.dx, p2Bottom.dy)
        ..lineTo(p2Top.dx, p2Top.dy)
        ..lineTo(p1Top.dx, p1Top.dy)
        ..close();
      canvas.drawPath(
        leftPanel,
        Paint()
          ..color = (active ? palette.accent2 : palette.textDim).withValues(alpha: 0.035 * baseAlpha)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        leftPanel,
        Paint()
          ..color = palette.hairline.withValues(alpha: 0.20 * baseAlpha)
          ..strokeWidth = 0.5
          ..style = PaintingStyle.stroke,
      );

      // 右侧吸音块
      final pr1Bottom = Offset(flR.dx + (bkR.dx - flR.dx) * t1, flR.dy + (bkR.dy - flR.dy) * t1);
      final pr1Top = Offset(topFrontR.dx + (ceilR.dx - topFrontR.dx) * t1, topFrontR.dy + (ceilR.dy - topFrontR.dy) * t1);
      final pr2Bottom = Offset(flR.dx + (bkR.dx - flR.dx) * t2, flR.dy + (bkR.dy - flR.dy) * t2);
      final pr2Top = Offset(topFrontR.dx + (ceilR.dx - topFrontR.dx) * t2, topFrontR.dy + (ceilR.dy - topFrontR.dy) * t2);

      final rightPanel = Path()
        ..moveTo(pr1Bottom.dx, pr1Bottom.dy)
        ..lineTo(pr2Bottom.dx, pr2Bottom.dy)
        ..lineTo(pr2Top.dx, pr2Top.dy)
        ..lineTo(pr1Top.dx, pr1Top.dy)
        ..close();
      canvas.drawPath(
        rightPanel,
        Paint()
          ..color = (active ? palette.accent2 : palette.textDim).withValues(alpha: 0.035 * baseAlpha)
          ..style = PaintingStyle.fill,
      );
      canvas.drawPath(
        rightPanel,
        Paint()
          ..color = palette.hairline.withValues(alpha: 0.20 * baseAlpha)
          ..strokeWidth = 0.5
          ..style = PaintingStyle.stroke,
      );
    }

    // ── 4. L/R 全频专业监听音箱与声学波导 (Virtual Studio Monitors) ──
    final widthOff = (w * 0.24 * stereoWidth).clamp(20.0, w * 0.44);
    final srcY = h * 0.76;
    final srcL = Offset(vpX - widthOff, srcY);
    final srcR = Offset(vpX + widthOff, srcY);

    if (active) {
      // 4.1 音箱波导扩散辐射锥 (Waveguide Dispersion Cones)
      final coneHalfAngle = (0.28 + 0.15 * stereoWidth).clamp(0.20, 0.48);
      final coneLength = 54.0 * sizeFactor;

      void drawMonitorCone(Offset pos, double directionSign) {
        final centerDir = -math.pi * 0.5 + directionSign * 0.25;
        final conePath = Path()
          ..moveTo(pos.dx, pos.dy)
          ..lineTo(
            pos.dx + coneLength * math.cos(centerDir - coneHalfAngle),
            pos.dy + coneLength * math.sin(centerDir - coneHalfAngle),
          )
          ..lineTo(
            pos.dx + coneLength * math.cos(centerDir + coneHalfAngle),
            pos.dy + coneLength * math.sin(centerDir + coneHalfAngle),
          )
          ..close();

        final coneShader = RadialGradient(
          center: Alignment.center,
          radius: 0.9,
          colors: [
            palette.accent.withValues(alpha: 0.18),
            palette.accent.withValues(alpha: 0.01),
          ],
        ).createShader(Rect.fromCircle(center: pos, radius: coneLength));
        canvas.drawPath(conePath, Paint()..shader = coneShader);
      }

      drawMonitorCone(srcL, 1.0);
      drawMonitorCone(srcR, -1.0);

      // 4.2 早期镜面反射路径 (First-order Specular Ray Paths)
      final reflAlpha = (0.22 * (1.0 - damp * 0.5)).clamp(0.06, 0.32);
      final rayPaint = Paint()
        ..color = palette.accent.withValues(alpha: reflAlpha)
        ..strokeWidth = 0.8
        ..style = PaintingStyle.stroke;

      // 侧壁首反射交点
      final hitL = Offset(flL.dx + (bkL.dx - flL.dx) * 0.48, flL.dy + (bkL.dy - flL.dy) * 0.48);
      final hitR = Offset(flR.dx + (bkR.dx - flR.dx) * 0.48, flR.dy + (bkR.dy - flR.dy) * 0.48);

      canvas.drawLine(srcL, hitL, rayPaint);
      canvas.drawLine(hitL, bkR, rayPaint..strokeWidth = 0.5);
      canvas.drawLine(srcR, hitR, rayPaint..strokeWidth = 0.8);
      canvas.drawLine(hitR, bkL, rayPaint..strokeWidth = 0.5);

      // 侧壁反射高光点 (Wall Impact Highlights)
      final impactGlow = Paint()
        ..color = palette.accent2.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
      canvas.drawCircle(hitL, 2.5, impactGlow);
      canvas.drawCircle(hitR, 2.5, impactGlow);

      // 4.3 动态球面波前扩散弧 (Spherical Wavefront Arcs)
      final ringCount = (4 + decay * 4).round().clamp(3, 8);
      for (var i = 1; i <= ringCount; i++) {
        final t = i / (ringCount + 1);
        final ringAlpha = (0.20 * (1.0 - t) * (0.3 + 0.7 * decay) * (1.0 - damp * 0.35)).clamp(0.02, 0.25);
        final wavePaint = Paint()
          ..color = palette.accent.withValues(alpha: ringAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = (1.4 - t * 0.8).clamp(0.4, 1.4);

        final radius = 12.0 + t * 62.0 * sizeFactor;

        // 左音箱对称波弧
        canvas.drawArc(
          Rect.fromCircle(center: srcL, radius: radius),
          -math.pi * 0.72,
          math.pi * 0.54,
          false,
          wavePaint,
        );
        // 右音箱对称波弧
        canvas.drawArc(
          Rect.fromCircle(center: srcR, radius: radius),
          -math.pi * 0.82,
          math.pi * 0.54,
          false,
          wavePaint,
        );
      }

      // 4.4 声学漫反射衰减粒子群 (Stochastic Diffusion Cloud)
      // 粒子数量与分布随 decay 与 roomSize 呼吸扩散，色彩受 damp 阻尼高频吸收影响
      const particleTotal = 36;
      final pActiveCount = (14 + decay * 22).round().clamp(10, particleTotal);
      final particlePaint = Paint()..style = PaintingStyle.fill;

      // damp 越高，微粒色调越偏温暖柔和；damp 越低，微粒越明亮通透
      final pColor = Color.lerp(palette.accent, palette.accent2, damp.clamp(0.0, 1.0)) ?? palette.accent;

      for (var i = 0; i < pActiveCount; i++) {
        final seedX = (math.sin(i * 91.73) * 0.5 + 0.5);
        final seedY = (math.cos(i * 47.19) * 0.5 + 0.5);
        final seedDepth = (math.sin(i * 123.45 + 1.2) * 0.5 + 0.5);

        // 透视深度映射
        final px = (vpX - backHalfW * 1.3) + seedX * (backHalfW * 2.6);
        final py = (bkL.dy - ceilH * 0.5) + seedY * (flL.dy - bkL.dy + ceilH * 0.5) * 0.85;

        if (px >= flL.dx + 10 && px <= flR.dx - 10 && py >= bkL.dy - ceilH && py <= flL.dy - 6) {
          final pAlpha = ((0.10 + 0.35 * seedDepth) * decay * (1.0 - damp * 0.4)).clamp(0.03, 0.45);
          final pRadius = (0.9 + 1.4 * (1.0 - seedDepth));
          particlePaint.color = pColor.withValues(alpha: pAlpha);
          canvas.drawCircle(Offset(px, py), pRadius, particlePaint);
        }
      }

      // 4.5 后墙大空间能量晕染 (Diffuse Field Halo)
      final backGlow = Paint()
        ..color = palette.accent.withValues(alpha: (0.10 * decay * (1.0 - damp * 0.4)).clamp(0.02, 0.18))
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 22 * sizeFactor);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(vpX, vpY + 12),
          width: (bkR.dx - bkL.dx) * 0.90,
          height: 28 * sizeFactor,
        ),
        backGlow,
      );
    }

    // ── 5. 音箱实体精绘 (Studio Monitor Pods) ──
    void drawSpeakerBox(Offset pos, bool isLeft) {
      // 音箱底盘高光
      if (active) {
        final haloPaint = Paint()
          ..color = palette.accent.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
        canvas.drawCircle(pos, 8.0, haloPaint);
      }

      // 箱体外壳
      final boxRect = Rect.fromCenter(center: pos, width: 14.0, height: 16.0);
      final boxRRect = RRect.fromRectAndRadius(boxRect, const Radius.circular(2.5));
      canvas.drawRRect(
        boxRRect,
        Paint()
          ..color = palette.panelRaised
          ..style = PaintingStyle.fill,
      );
      canvas.drawRRect(
        boxRRect,
        Paint()
          ..color = active ? palette.accent : palette.textDim.withValues(alpha: 0.4)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.0,
      );

      // 低音单元大纸盆
      final wooferCenter = Offset(pos.dx, pos.dy + 2.5);
      canvas.drawCircle(
        wooferCenter,
        3.5,
        Paint()
          ..color = active ? palette.accent.withValues(alpha: 0.6) : palette.textDim.withValues(alpha: 0.3)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 0.8,
      );
      canvas.drawCircle(
        wooferCenter,
        1.5,
        Paint()
          ..color = active ? palette.accent : palette.textDim
          ..style = PaintingStyle.fill,
      );

      // 高音丝膜球顶
      final tweeterCenter = Offset(pos.dx, pos.dy - 3.8);
      canvas.drawCircle(
        tweeterCenter,
        1.3,
        Paint()
          ..color = active ? palette.accent2 : palette.textDim
          ..style = PaintingStyle.fill,
      );

      // 声道标识 L / R
      final chTp = TextPainter(
        text: TextSpan(
          text: isLeft ? 'L' : 'R',
          style: monoOf(palette, size: 7.5, color: active ? palette.accent : palette.textDim)
              .copyWith(fontWeight: FontWeight.w700),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      chTp.paint(canvas, Offset(pos.dx - chTp.width / 2, pos.dy + 9.5));
    }

    drawSpeakerBox(srcL, true);
    drawSpeakerBox(srcR, false);

    // ── 6. 监听席位与声学受体 (Binaural Receiver Position) ──
    final listenerY = h * 0.92;
    final listenerPos = Offset(vpX, listenerY);
    if (active) {
      final listenerGlow = Paint()
        ..color = palette.accent2.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8.0);
      canvas.drawCircle(listenerPos, 9.0, listenerGlow);
    }
    // 监听席双耳几何指示
    final recvPaint = Paint()
      ..color = active ? palette.accent2 : palette.textDim.withValues(alpha: 0.6)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(listenerPos, 3.0, recvPaint);
    canvas.drawCircle(
      listenerPos,
      5.5,
      Paint()
        ..color = active ? palette.accent2.withValues(alpha: 0.7) : palette.textDim.withValues(alpha: 0.3)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.8,
    );

    // ── 7. 专业声学仪表 HUD (Acoustic Telemetry Overlay) ──
    // 7.1 左上角：声学腔体模型标识
    final titleTp = TextPainter(
      text: TextSpan(
        children: [
          TextSpan(
            text: 'ACOUSTIC CAVITY MODEL · ',
            style: monoOf(palette, size: 8, color: palette.textDim.withValues(alpha: 0.7))
                .copyWith(fontWeight: FontWeight.w600),
          ),
          TextSpan(
            text: active ? 'ACTIVE SIMULATION' : 'STANDBY',
            style: monoOf(palette, size: 8, color: active ? palette.accent : palette.textDim.withValues(alpha: 0.4))
                .copyWith(fontWeight: FontWeight.w700),
          ),
        ],
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    titleTp.paint(canvas, const Offset(12.0, 9.0));

    // 7.2 右上角：RT60 估算、声学扩散率、吸音阻尼指标 HUD
    final estRt60 = (0.35 + roomSize * 1.55 * (0.25 + decay * 0.85)).clamp(0.4, 6.5);
    final diffusionPct = (stereoWidth * 65.0).round().clamp(25, 100);
    final dampPct = (damp * 100).round();

    final hudText = active
        ? 'RT60 ~${estRt60.toStringAsFixed(2)}s · DIFF $diffusionPct% · DAMP $dampPct%'
        : 'RT60 -- · ROOM ${roomSize.toStringAsFixed(1)}x';
    final hudTp = TextPainter(
      text: TextSpan(
        text: hudText,
        style: monoOf(palette, size: 8, color: active ? palette.accent : palette.textDim.withValues(alpha: 0.5))
            .copyWith(fontWeight: FontWeight.w700),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    hudTp.paint(canvas, Offset(w - 12.0 - hudTp.width, 9.0));

    // 7.3 左下角微标尺：等效声学容积感知
    final approxVolM3 = (math.pow(roomSize * 10.0, 3) * 0.85).round().clamp(60, 18500);
    final volTp = TextPainter(
      text: TextSpan(
        text: 'VOL ~${approxVolM3}m³ · SPREAD ${(stereoWidth * 100).round()}%',
        style: monoOf(palette, size: 7.5, color: palette.textDim.withValues(alpha: 0.45)),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    volTp.paint(canvas, Offset(12.0, h - 17.0));
  }

  // [PATCHED-AuraDSP P-040] epsilon 保护，阻断单精度 IEEE754 尾数抖动
  static const double _eps = 1e-6;

  @override
  bool shouldRepaint(covariant _Freeverb3DPainter oldDelegate) =>
      (oldDelegate.decay - decay).abs() > _eps ||
      (oldDelegate.damp - damp).abs() > _eps ||
      (oldDelegate.roomSize - roomSize).abs() > _eps ||
      (oldDelegate.stereoWidth - stereoWidth).abs() > _eps ||
      oldDelegate.palette != palette ||
      oldDelegate.active != active;
}

