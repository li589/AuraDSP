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
            // 按钮与标题同行：文字左对齐、按钮右对齐。
            const SizedBox(width: AuraSpace.sm),
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

      final label = isLogScale ? '${val.toInt()}dB' : '${(val * 100).toInt()}%';
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

/* ---- 3D 声学室空间渲染 (极简无框置顶视效：深度透视 + 对称声波 + 空间尺寸响应) ---- */

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
        height: 140,
        decoration: BoxDecoration(
          color: p.panelRaised.withValues(alpha: 0.6),
          border: Border.all(color: p.hairline.withValues(alpha: 0.6)),
        ),
        child: Stack(
          children: [
            Positioned.fill(
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
            // 右上角极简度量（微弱透明度，不喧宾夺主）
            Positioned(
              top: 6,
              right: 10,
              child: Text(
                'Room ${roomSize.toStringAsFixed(1)}x · Decay ${(decay * 100).toStringAsFixed(0)}% · Width ${stereoWidth.toStringAsFixed(1)}',
                style: monoOf(p, size: 9, color: p.textDim.withValues(alpha: 0.6)),
              ),
            ),
          ],
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
    final baseAlpha = active ? 1.0 : 0.2;
    // 空间尺寸增强系数：0.4 ~ 2.4
    final sizeFactor = (roomSize / 1.2).clamp(0.4, 2.4);

    // 消失点（透视中心）：roomSize 越大，透视深远感越强
    final vpX = w / 2;
    final vpY = (h * (0.22 - (sizeFactor - 1.0) * 0.06)).clamp(h * 0.08, h * 0.30);

    // 地面四角
    final flL = Offset(w * 0.03, h * 0.98);
    final flR = Offset(w * 0.97, h * 0.98);
    final backHalfW = (w * (0.32 / math.sqrt(sizeFactor))).clamp(w * 0.16, w * 0.42);
    final bkL = Offset(vpX - backHalfW, vpY + 16);
    final bkR = Offset(vpX + backHalfW, vpY + 16);

    // ── 1. 透视地板网格 ──
    final gridPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.22 * baseAlpha)
      ..strokeWidth = 0.6;

    // 纵深线（左→右均匀 8 条）
    for (var i = 0; i <= 8; i++) {
      final t = i / 8.0;
      final botX = flL.dx + (flR.dx - flL.dx) * t;
      final topX = bkL.dx + (bkR.dx - bkL.dx) * t;
      canvas.drawLine(
        Offset(botX, flL.dy),
        Offset(topX, bkL.dy),
        gridPaint,
      );
    }
    // 横向线（6 条，近疏远密）
    for (var i = 0; i <= 6; i++) {
      final t = math.pow(i / 6.0, 1.6);
      final y = flL.dy + (bkL.dy - flL.dy) * t;
      final lx = flL.dx + (bkL.dx - flL.dx) * t;
      final rx = flR.dx + (bkR.dx - flR.dx) * t;
      canvas.drawLine(Offset(lx, y), Offset(rx, y), gridPaint);
    }

    // ── 2. 3D 空间立体线框盒子（地面 + 后墙 + 天花板） ──
    final wallPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.38 * baseAlpha)
      ..strokeWidth = 1.0;
    canvas.drawLine(flL, bkL, wallPaint);
    canvas.drawLine(flR, bkR, wallPaint);
    canvas.drawLine(flL, flR, wallPaint);
    canvas.drawLine(bkL, bkR, wallPaint);

    // 天花板高度与后墙轮廓
    final ceilH = (22.0 * math.sqrt(sizeFactor)).clamp(16.0, 38.0);
    final ceilL = Offset(bkL.dx, bkL.dy - ceilH);
    final ceilR = Offset(bkR.dx, bkR.dy - ceilH);
    final ceilPaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.22 * baseAlpha)
      ..strokeWidth = 0.8;
    canvas.drawLine(ceilL, ceilR, ceilPaint);
    canvas.drawLine(bkL, ceilL, ceilPaint);
    canvas.drawLine(bkR, ceilR, ceilPaint);

    // 侧墙透视延伸线（增强立方体感）
    final sidePaint = Paint()
      ..color = palette.vizGrid.withValues(alpha: 0.12 * baseAlpha)
      ..strokeWidth = 0.5;
    canvas.drawLine(Offset(flL.dx, flL.dy - h * 0.7), ceilL, sidePaint);
    canvas.drawLine(Offset(flR.dx, flR.dy - h * 0.7), ceilR, sidePaint);

    if (!active) return;

    // ── 3. 声源位置 ──
    final widthOff = (w * 0.22 * stereoWidth).clamp(16.0, w * 0.44);
    final srcY = h * 0.78;
    final srcL = Offset(vpX - widthOff, srcY);
    final srcR = Offset(vpX + widthOff, srcY);

    // 声源光晕（外圈漫反射）
    final srcGlow = Paint()
      ..color = palette.accent.withValues(alpha: 0.25)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10);
    canvas.drawCircle(srcL, 8, srcGlow);
    canvas.drawCircle(srcR, 8, srcGlow);

    // 声源实心点
    final srcDot = Paint()
      ..color = palette.accent.withValues(alpha: 0.9)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(srcL, 3.5, srcDot);
    canvas.drawCircle(srcR, 3.5, srcDot);

    // ── 4. 早期反射路径（声源 → 侧墙反弹点 → 远处交叉） ──
    final reflAlpha = (0.18 * (1.0 - damp * 0.6)).clamp(0.04, 0.25) * baseAlpha;
    final reflPaint = Paint()
      ..color = palette.accent.withValues(alpha: reflAlpha)
      ..strokeWidth = 0.9
      ..style = PaintingStyle.stroke;

    final wallHitL = Offset(flL.dx + (bkL.dx - flL.dx) * 0.45, flL.dy + (bkL.dy - flL.dy) * 0.45);
    final wallHitR = Offset(flR.dx + (bkR.dx - flR.dx) * 0.45, flR.dy + (bkR.dy - flR.dy) * 0.45);
    canvas.drawLine(srcL, wallHitL, reflPaint);
    canvas.drawLine(wallHitL, bkR, reflPaint..strokeWidth = 0.5);
    canvas.drawLine(srcR, wallHitR, reflPaint..strokeWidth = 0.9);
    canvas.drawLine(wallHitR, bkL, reflPaint..strokeWidth = 0.5);

    // 直达路径（到后墙中心）
    final directPaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.12 * baseAlpha)
      ..strokeWidth = 0.7
      ..style = PaintingStyle.stroke;
    final backCenter = Offset(vpX, (bkL.dy + bkR.dy) / 2);
    canvas.drawLine(srcL, backCenter, directPaint);
    canvas.drawLine(srcR, backCenter, directPaint);

    // ── 5. 衰减扩散环（修复右音箱扩散朝向：左右关于中轴对称向房间内前方扩散） ──
    final ringCount = (3 + decay * 4).toInt().clamp(2, 7);
    for (var i = 1; i <= ringCount; i++) {
      final t = i / (ringCount + 1);
      final ringAlpha = (0.16 * (1.0 - t) * decay * (1.0 - damp * 0.4)).clamp(0.02, 0.22);
      final ringPaint = Paint()
        ..color = palette.accent.withValues(alpha: ringAlpha * baseAlpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = (1.2 - t * 0.6).clamp(0.3, 1.2);

      final radius = 14.0 + t * 52 * sizeFactor;

      // 左声源波纹弧（向右前方扩散，中心约 -0.44π）
      canvas.drawArc(
        Rect.fromCircle(center: srcL, radius: radius),
        -math.pi * 0.70,
        math.pi * 0.52,
        false,
        ringPaint,
      );
      // 右声源波纹弧（向左前方扩散，中心约 -0.56π，绝对对称，杜绝向右下扩散错误）
      canvas.drawArc(
        Rect.fromCircle(center: srcR, radius: radius),
        -math.pi * 0.82,
        math.pi * 0.52,
        false,
        ringPaint,
      );
    }

    // ── 6. 后墙漫反射光晕 ──
    final backGlow = Paint()
      ..color = palette.accent.withValues(alpha: (0.08 * decay * (1.0 - damp * 0.5)).clamp(0.01, 0.15))
      ..maskFilter = MaskFilter.blur(BlurStyle.normal, 20 * sizeFactor);
    canvas.drawOval(
      Rect.fromCenter(center: Offset(vpX, vpY + 14), width: (bkR.dx - bkL.dx) * 0.85, height: 24 * sizeFactor),
      backGlow,
    );

    // ── 7. 聆听位置指示（小三角底部中央） ──
    final listenerY = h * 0.92;
    final listenerPaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;
    final triPath = Path()
      ..moveTo(vpX, listenerY - 5)
      ..lineTo(vpX - 4, listenerY + 2)
      ..lineTo(vpX + 4, listenerY + 2)
      ..close();
    canvas.drawPath(triPath, listenerPaint);

    final listGlow = Paint()
      ..color = palette.accent.withValues(alpha: 0.1)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
    canvas.drawCircle(Offset(vpX, listenerY - 2), 8, listGlow);

    // ── 8. 阻尼渐变蒙层 ──
    final dampGrad = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.center,
        colors: [
          palette.bg.withValues(alpha: (damp * 0.4).clamp(0.0, 0.35)),
          palette.bg.withValues(alpha: 0.0),
        ],
      ).createShader(Rect.fromLTWH(0, 0, w, h));
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h * 0.6), dampGrad);
  }

  // [PATCHED-AuraDSP P-032] 用 epsilon 比较：引擎侧存的是 float32，UI 侧
  // 是精确 double，回读往返必然带 ~1e-8 尾数差 → 用 != 判定会让 3D 图
  // 在每次回读后无条件重绘一次（用户看到"图形跳两次"的另一半原因）。
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
