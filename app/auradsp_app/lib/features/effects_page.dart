/*
 * effects_page.dart — 控制页：对齐 engine_api 参数模型 v1
 *
 * 规范落地：
 * - Phase 1: 视觉降噪与术语规整，废除品质档拦截
 * - Phase 2: 空间混响二合一，双向状态机联动，3D 声学室动态尺寸映射
 * - Phase 3: 多段交互式 EQ 频谱面板与发光 Q 旋钮
 * - Phase 4: 低音重构（谐波注入）、电子管模拟器卡片与组件级微型延迟徽标
 */
import 'dart:math' as math;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/design.dart';
import '../core/presets.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../core/ui_helpers.dart';
import '../l10n/gen/app_localizations.dart';
import 'chrome.dart';
import 'interactive_eq.dart';
import 'widgets.dart';

class EffectsPage extends StatelessWidget {
  final AppModel model;
  const EffectsPage({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return PageScaffold(
      eyebrow: l.pageEffectsEyebrow,
      title: l.pageEffectsTitle,
      children: [
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _InputCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _GateCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _CompressorCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _BassCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _BassMonoCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _SpatialReverbCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _ConvolverCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _DdcCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _EqualizerCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _ArbmagCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _CrossfeedCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _StereoCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _HaasCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _ExciterCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _TubeCard(model: model),
        ),
        ListenableBuilder(
          listenable: model,
          builder: (_, _) => _PostCard(model: model),
        ),
        _PresetCard(model: model),
      ],
    );
  }
}

/* ---- 00 Input Gate (输入门控：常驻不可关闭、总增益旋钮、本级 IN/OUT 电平对比、高级区条形声道平衡) ---- */

class _InputCard extends StatelessWidget {
  final AppModel model;
  const _InputCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: '00',
      title: l.inputGate,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 上半区：左侧全通道总增益旋钮 + 右侧多通道本级 IN/OUT 电平对比表
          LayoutBuilder(
            builder: (context, constraints) {
              final isCompact = constraints.maxWidth < 460;
              final knobWidget = _InputMasterGainKnob(
                gain: model.inputGain,
                onChanged: model.setInputGain,
                onReset: () => model.setInputGain(0.0),
                label: l.inputGain,
                palette: p,
              );
              final meterWidget = _InputStageMeterMatrix(
                model: model,
                palette: p,
                l10n: l,
              );

              if (isCompact) {
                return Column(
                  children: [
                    Center(child: knobWidget),
                    const SizedBox(height: AuraSpace.md),
                    meterWidget,
                  ],
                );
              }

              return Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 140,
                    child: Center(child: knobWidget),
                  ),
                  Container(
                    width: 1,
                    height: 100,
                    margin: const EdgeInsets.symmetric(horizontal: AuraSpace.sm),
                    color: p.hairline.withValues(alpha: 0.5),
                  ),
                  Expanded(child: meterWidget),
                ],
              );
            },
          ),
          const SizedBox(height: AuraSpace.md),

          // 下半区：高级展开区 - 声道平衡功能 (条形控制)
          AdvancedSection(
            summary: 'L: ${(model.inputBalanceL * 100).round()}% · R: ${(model.inputBalanceR * 100).round()}%',
            helpTooltip: l.channelBalanceHint,
            builder: (ctx) => _InputBalanceAdvanced(
              model: model,
              palette: p,
              l10n: l,
            ),
          ),
        ],
      ),
    );
  }
}

class _InputMasterGainKnob extends StatefulWidget {
  final double gain;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;
  final String label;
  final AuraPalette palette;

  const _InputMasterGainKnob({
    required this.gain,
    required this.onChanged,
    required this.onReset,
    required this.label,
    required this.palette,
  });

  @override
  State<_InputMasterGainKnob> createState() => _InputMasterGainKnobState();
}

class _InputMasterGainKnobState extends State<_InputMasterGainKnob> {
  double? _dragStartY;
  double? _dragStartGain;

  @override
  Widget build(BuildContext context) {
    final p = widget.palette;
    final gainText = (widget.gain >= 0 ? '+' : '') + widget.gain.toStringAsFixed(1);

    return GestureDetector(
      onDoubleTap: widget.onReset,
      onVerticalDragStart: (details) {
        _dragStartY = details.localPosition.dy;
        _dragStartGain = widget.gain;
      },
      onVerticalDragUpdate: (details) {
        if (_dragStartY != null && _dragStartGain != null) {
          final dy = _dragStartY! - details.localPosition.dy;
          final newGain = (_dragStartGain! + dy * 0.1).clamp(-15.0, 15.0);
          final snapped = (newGain * 10).round() / 10.0;
          widget.onChanged(snapped);
        }
      },
      onVerticalDragEnd: (_) {
        _dragStartY = null;
        _dragStartGain = null;
      },
      child: Tooltip(
        message: '${widget.label}: $gainText dB\n上下拖拽微调 · 双击归零',
        child: Container(
          color: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CustomPaint(
                size: const Size(68, 68),
                painter: _GainKnobPainter(gain: widget.gain, palette: p),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.baseline,
                textBaseline: TextBaseline.alphabetic,
                children: [
                  Text(
                    gainText,
                    style: monoOf(p, size: 13, color: p.accent).copyWith(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 2),
                  Text(
                    'dB',
                    style: monoOf(p, size: 9.5, color: p.textDim),
                  ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                widget.label,
                style: captionOf(p).copyWith(fontSize: 10, fontWeight: FontWeight.w600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _GainKnobPainter extends CustomPainter {
  final double gain; // -15.0 to 15.0
  final AuraPalette palette;

  const _GainKnobPainter({required this.gain, required this.palette});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2 - 5;

    // 轨道角度：-135° (135°) 到 +135° (405°)，12点钟正上方 270° 对应 0.0 dB
    const startAngle = 135.0 * math.pi / 180.0;
    const sweepTotal = 270.0 * math.pi / 180.0;
    const zeroAngle = 270.0 * math.pi / 180.0;

    // 1. 轨道底环
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

    // 2. 0 dB 刻度指示线（正上方 12 点钟）
    final tickPaint = Paint()
      ..color = palette.textDim.withValues(alpha: 0.6)
      ..strokeWidth = 1.2;
    canvas.drawLine(
      Offset(center.dx, center.dy - radius - 3),
      Offset(center.dx, center.dy - radius + 3),
      tickPaint,
    );

    // 3. 有效增益发光弧
    final halfSweep = sweepTotal / 2.0;
    final normalized = (gain / 15.0).clamp(-1.0, 1.0);
    final sweep = normalized * halfSweep;

    if (sweep.abs() > 0.005) {
      final activePaint = Paint()
        ..color = palette.accent
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round;

      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        zeroAngle,
        sweep,
        false,
        activePaint,
      );
    }

    // 4. 中心圆盘
    final discPaint = Paint()
      ..color = palette.panelRaised
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, radius - 6.5, discPaint);

    final discBorder = Paint()
      ..color = palette.hairline
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawCircle(center, radius - 6.5, discBorder);

    // 5. 指针指示点
    final pointerAngle = zeroAngle + sweep;
    final dotX = center.dx + (radius - 12) * math.cos(pointerAngle);
    final dotY = center.dy + (radius - 12) * math.sin(pointerAngle);
    final dotPaint = Paint()..color = palette.accent;
    canvas.drawCircle(Offset(dotX, dotY), 2.6, dotPaint);
  }

  @override
  bool shouldRepaint(covariant _GainKnobPainter oldDelegate) =>
      oldDelegate.gain != gain || oldDelegate.palette != palette;
}

class _InputStageMeterMatrix extends StatelessWidget {
  final AppModel model;
  final AuraPalette palette;
  final AppLocalizations l10n;

  const _InputStageMeterMatrix({
    required this.model,
    required this.palette,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        model.inputMeterInL,
        model.inputMeterInR,
        model.inputMeterOutL,
        model.inputMeterOutR,
      ]),
      builder: (context, _) {
        final inL = model.inputMeterInL.value;
        final inR = model.inputMeterInR.value;
        final outL = model.inputMeterOutL.value;
        final outR = model.inputMeterOutR.value;

        return Container(
          padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: AuraSpace.xs + 2),
          decoration: BoxDecoration(
            color: palette.panelRaised.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: palette.hairline.withValues(alpha: 0.7)),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶栏：本级输入 (IN) 与 本级输出 (OUT) 胶囊标签
              Row(
                children: [
                  _StageBadge(
                    label: l10n.inputStageIn,
                    color: palette.textDim,
                    icon: Icons.input_rounded,
                  ),
                  const Spacer(),
                  Icon(Icons.arrow_forward_rounded,
                      size: 12, color: palette.textDim.withValues(alpha: 0.5)),
                  const Spacer(),
                  _StageBadge(
                    label: l10n.inputStageOut,
                    color: palette.accent,
                    icon: Icons.output_rounded,
                  ),
                ],
              ),
              const SizedBox(height: AuraSpace.xs + 2),
              // 电平柱阵列
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // IN L & R
                  _MeterChannelBar(label: 'L', db: inL, palette: palette),
                  _MeterChannelBar(label: 'R', db: inR, palette: palette),
                  // 分贝刻度尺
                  _MeterScaleRuler(palette: palette),
                  // OUT L & R
                  _MeterChannelBar(label: 'L', db: outL, palette: palette),
                  _MeterChannelBar(label: 'R', db: outR, palette: palette),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StageBadge extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;

  const _StageBadge({
    required this.label,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        border: Border.all(color: color.withValues(alpha: 0.35), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: color),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 9.5,
              fontWeight: FontWeight.bold,
              color: color,
            ),
          ),
        ],
      ),
    );
  }
}

class _MeterScaleRuler extends StatelessWidget {
  final AuraPalette palette;
  const _MeterScaleRuler({required this.palette});

  @override
  Widget build(BuildContext context) {
    const ticks = ['0', '-6', '-18', '-36'];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          for (final t in ticks) ...[
            Text(
              t,
              style: monoOf(palette, size: 7.5, color: palette.textDim.withValues(alpha: 0.7)),
            ),
          ],
          const SizedBox(height: 14), // 对齐下方声道标签行高
        ],
      ),
    );
  }
}

class _MeterChannelBar extends StatelessWidget {
  final String label;
  final double db;
  final AuraPalette palette;

  const _MeterChannelBar({
    required this.label,
    required this.db,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final isClip = db > -0.05;
    final dbStr = (db <= -59.5 || db.isNaN || db.isInfinite)
        ? '-∞'
        : (db >= 0 ? '+${db.toStringAsFixed(1)}' : db.toStringAsFixed(1));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 峰值过载 LED
        Container(
          width: 8,
          height: 3,
          margin: const EdgeInsets.only(bottom: 2),
          decoration: BoxDecoration(
            color: isClip ? const Color(0xFFEF4444) : const Color(0xFFEF4444).withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(1),
          ),
        ),
        // 阶梯式 LED 柱
        CustomPaint(
          size: const Size(10, 52),
          painter: _ChannelLedPainter(db: db, palette: palette),
        ),
        const SizedBox(height: 3),
        Text(
          label,
          style: monoOf(palette, size: 9, color: palette.text).copyWith(fontWeight: FontWeight.bold),
        ),
        Text(
          dbStr,
          style: monoOf(palette, size: 7.5, color: isClip ? const Color(0xFFEF4444) : palette.textDim),
        ),
      ],
    );
  }
}

class _ChannelLedPainter extends CustomPainter {
  final double db;
  final AuraPalette palette;
  static const int kSegments = 10;

  const _ChannelLedPainter({required this.db, required this.palette});

  static double _norm(double db) {
    if (db.isNaN || db.isInfinite || db <= -60.0) return 0.0;
    if (db >= 0.0) return 1.0;
    return ((db + 60.0) / 60.0).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final normVal = _norm(db);
    final litCount = (normVal * kSegments).round().clamp(0, kSegments);
    final segH = (size.height - (kSegments - 1) * 1.5) / kSegments;

    for (var s = 0; s < kSegments; s++) {
      final segBottom = size.height - s * (segH + 1.5);
      final segTop = segBottom - segH;
      final isLit = s < litCount;

      final Color litColor;
      if (s >= 9) {
        litColor = const Color(0xFFEF4444); // 红色
      } else if (s >= 7) {
        litColor = const Color(0xFFF59E0B); // 琥珀黄
      } else {
        litColor = const Color(0xFF10B981); // 翠绿
      }

      final rect = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, segTop, size.width, segH),
        const Radius.circular(0.8),
      );

      final paint = Paint()
        ..color = isLit ? litColor : litColor.withValues(alpha: 0.12)
        ..style = PaintingStyle.fill;
      canvas.drawRRect(rect, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ChannelLedPainter oldDelegate) =>
      oldDelegate.db != db || oldDelegate.palette != palette;
}

class _InputBalanceAdvanced extends StatelessWidget {
  final AppModel model;
  final AuraPalette palette;
  final AppLocalizations l10n;

  const _InputBalanceAdvanced({
    required this.model,
    required this.palette,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final isCustom = (model.inputBalanceL - 1.0).abs() > 0.001 ||
        (model.inputBalanceR - 1.0).abs() > 0.001;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (isCustom)
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(bottom: AuraSpace.xs),
              child: TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                icon: const Icon(Icons.refresh_rounded, size: 13),
                label: const Text('重置 100%', style: TextStyle(fontSize: 11)),
                onPressed: () {
                  model.setInputBalanceL(1.0);
                  model.setInputBalanceR(1.0);
                },
              ),
            ),
          ),
        _ChannelBalanceBar(
          label: l10n.channelLeft,
          value: model.inputBalanceL,
          masterGainDb: model.inputGain,
          onChanged: model.setInputBalanceL,
          onReset: () => model.setInputBalanceL(1.0),
          palette: palette,
          l10n: l10n,
        ),
        const SizedBox(height: AuraSpace.sm),
        _ChannelBalanceBar(
          label: l10n.channelRight,
          value: model.inputBalanceR,
          masterGainDb: model.inputGain,
          onChanged: model.setInputBalanceR,
          onReset: () => model.setInputBalanceR(1.0),
          palette: palette,
          l10n: l10n,
        ),
      ],
    );
  }
}

class _ChannelBalanceBar extends StatelessWidget {
  final String label;
  final double value; // 0.0 ~ 2.0 (0% ~ 200%)
  final double masterGainDb;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;
  final AuraPalette palette;
  final AppLocalizations l10n;

  const _ChannelBalanceBar({
    required this.label,
    required this.value,
    required this.masterGainDb,
    required this.onChanged,
    required this.onReset,
    required this.palette,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final p = palette;
    final percent = (value * 100).round();
    final isCustom = (value - 1.0).abs() > 0.001;

    // 计算最终合成音量: 总控 (dB) * 单控 (线性比例)
    final String finalDesc;
    if (value <= 0.0001) {
      finalDesc = '-∞ dB (0%)';
    } else {
      final finalDb = masterGainDb + (20.0 * math.log(value) / math.ln10);
      final finalPct = ((math.pow(10.0, masterGainDb / 20.0) * value) * 100).round();
      final sign = finalDb >= 0 ? '+' : '';
      finalDesc = '$sign${finalDb.toStringAsFixed(1)} dB ($finalPct%)';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: AuraSpace.sm, vertical: AuraSpace.xs),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        border: Border.all(color: p.hairline.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                label,
                style: labelOf(p, size: 12).copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: AuraSpace.sm),
              // 单控百分比徽标
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                decoration: BoxDecoration(
                  color: isCustom ? p.accent.withValues(alpha: 0.15) : p.panelRaised,
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                  border: Border.all(
                    color: isCustom ? p.accent.withValues(alpha: 0.4) : p.hairline,
                    width: 0.8,
                  ),
                ),
                child: Text(
                  '$percent%',
                  style: monoOf(p, size: 10, color: isCustom ? p.accent : p.textDim)
                      .copyWith(fontWeight: isCustom ? FontWeight.bold : FontWeight.normal),
                ),
              ),
              const Spacer(),
              // 最终音量合成显示
              Text(
                '最终: $finalDesc',
                style: monoOf(p, size: 10.5, color: isCustom ? p.accent : p.textDim),
              ),
              if (isCustom) ...[
                const SizedBox(width: AuraSpace.xs),
                Tooltip(
                  message: '双击或点击恢复 100%',
                  child: InkWell(
                    onTap: onReset,
                    borderRadius: BorderRadius.circular(AuraRadius.xs),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: Icon(Icons.refresh_rounded, size: 13, color: p.accent),
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: AuraSpace.xxs),
          // 条形滑块控制
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 6,
              activeTrackColor: p.accent,
              inactiveTrackColor: p.hairline,
              thumbColor: p.accent,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 7),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: value.clamp(0.0, 2.0),
              min: 0.0,
              max: 2.0,
              divisions: 200,
              onChanged: (v) {
                final snapped = (v * 100).round() / 100.0;
                onChanged(snapped);
              },
            ),
          ),
        ],
      ),
    );
  }
}

/* ---- 00B Gate + Deesser（噪声门 + 齿音消除，链头第一道）----
 * 主卡 = 噪声门（阈值/attack/release）；
 * 高级区 = Deesser（开关 + 频段 + 强度）+ 噪声门自动增益补偿开关。 */
class _GateCard extends StatelessWidget {
  final AppModel model;
  const _GateCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: '00',
      title: l.stGate,
      titleTooltip: l.gateHint,
      collapsed: !model.gateOn,
      latencyMs: model.componentLatency('gate').ms,
      latencyMeasured: model.componentLatency('gate').measured,
      latencyProbing: model.isProbingLatency('gate'),
      onRefreshLatency: () => model.refreshComponentLatency('gate'),
      latencyTick: model.getComponentLatencyTick('gate'),
      trailing: AuraSwitch(
        value: model.gateOn,
        onChanged: model.setGateEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 阈值
          ValueSlider(
            label: l.gateThreshold,
            infoMessage: '低于该电平的背景噪声被压掉。太高会吃掉弱音尾音，太低门几乎不动作。',
            value: model.gateThreshold,
            defaultValue: ParamDefaults.gateThreshold,
            onResetToDefault: () =>
                model.setGateThreshold(ParamDefaults.gateThreshold),
            min: -60,
            max: 0,
            unit: 'dB',
            enabled: model.gateOn,
            format: (v) => v.toStringAsFixed(0),
            onChanged: model.setGateThreshold,
            onChangedEnd: model.setGateThreshold,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 开启时间
          ValueSlider(
            label: l.gateAttack,
            infoMessage: '信号越过阈值后门打开的速度。太慢会吃掉起音，太快可能"咔"。',
            value: model.gateAttackMs,
            defaultValue: ParamDefaults.gateAttack,
            onResetToDefault: () =>
                model.setGateAttack(ParamDefaults.gateAttack),
            min: 1,
            max: 100,
            unit: 'ms',
            enabled: model.gateOn,
            format: (v) => v.toStringAsFixed(0),
            onChanged: model.setGateAttack,
            onChangedEnd: model.setGateAttack,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 释放时间
          ValueSlider(
            label: l.gateRelease,
            infoMessage: '信号跌回阈值以下后门关闭的速度。太短会截断衰减尾音，太长噪声拖尾。',
            value: model.gateReleaseMs,
            defaultValue: ParamDefaults.gateRelease,
            onResetToDefault: () =>
                model.setGateRelease(ParamDefaults.gateRelease),
            min: 10,
            max: 500,
            unit: 'ms',
            enabled: model.gateOn,
            format: (v) => v.toStringAsFixed(0),
            onChanged: model.setGateRelease,
            onChangedEnd: model.setGateRelease,
          ),
          const SizedBox(height: AuraSpace.md),
          // 高级区：Deesser（齿音消除）与输出级自动增益补偿
          AdvancedSection(
            summary: '${l.deesserTitle}: ${model.deesserOn ? "ON" : "OFF"} · AGC: ${model.gateAutoGain ? "ON" : "OFF"}',
            helpTooltip: '侧链动态去齿音与噪声门输出响度自动补偿。',
            builder: (ctx) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(l.deesserTitle, style: labelOf(p, color: p.text)),
                    const SizedBox(width: 4),
                    InfoBadge(message: '针对高频咝咝声、齿音（s/sh/ch）进行动态衰减，保留低频自然丰满度。'),
                    const Spacer(),
                    AuraSwitch(
                      value: model.deesserOn,
                      onChanged: model.gateOn ? model.setDeesserEnabled : null,
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                ValueSlider(
                  label: l.deesserFreq,
                  infoMessage: '检测齿音（s/sh 音）的侧链频段。齿音重往低调，太闷往高调。',
                  value: model.deesserFreq,
                  defaultValue: ParamDefaults.deesserFreq,
                  onResetToDefault: () =>
                      model.setDeesserFreq(ParamDefaults.deesserFreq),
                  min: 2000,
                  max: 10000,
                  unit: 'Hz',
                  enabled: model.gateOn && model.deesserOn,
                  format: (v) => '${(v / 1000).toStringAsFixed(1)}k',
                  onChanged: model.setDeesserFreq,
                  onChangedEnd: model.setDeesserFreq,
                ),
                const SizedBox(height: AuraSpace.sm),
                ValueSlider(
                  label: l.deesserAmount,
                  infoMessage: '齿音压制强度。只衰减高频成分，低频人声不动。',
                  value: model.deesserAmount,
                  defaultValue: ParamDefaults.deesserAmount,
                  onResetToDefault: () =>
                      model.setDeesserAmount(ParamDefaults.deesserAmount),
                  min: 0,
                  max: 1,
                  unit: '%',
                  enabled: model.gateOn && model.deesserOn,
                  format: (v) => (v * 100).toStringAsFixed(0),
                  onChanged: model.setDeesserAmount,
                  onChangedEnd: model.setDeesserAmount,
                ),
                const SizedBox(height: AuraSpace.md),
                // 输出级外框（自动增益补偿）
                OutputGainFrame(
                  child: _AutoGainRow(
                    label: l.gateAutoGain,
                    tooltip: '实时补偿噪声门造成的整体电平下降，保持响度不塌。',
                    value: model.gateAutoGain,
                    enabled: model.gateOn,
                    onChanged: model.setGateAutoGain,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ---- 01 Compressor (动态压限器) ---- */

class _CompressorCard extends StatelessWidget {
  final AppModel model;
  const _CompressorCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: '01',
      title: l.compTitle,
      collapsed: !model.compOn,
      latencyMs: model.componentLatency('comp').ms,
      latencyMeasured: model.componentLatency('comp').measured,
      latencyProbing: model.isProbingLatency('comp'),
      onRefreshLatency: () => model.refreshComponentLatency('comp'),
      latencyTick: model.getComponentLatencyTick('comp'),
      trailing: AuraSwitch(
        value: model.compOn,
        onChanged: model.setCompEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 响应时常数（Time Constant）主滑块
          ValueSlider(
            label: l.compTimeconstant,
            infoMessage: '控制动态压缩与包络跟踪的释放响应时间。较小时瞬态冲击更明显，较大时动态压缩更平顺通透。',
            value: model.compTimeconstant,
            defaultValue: 0.14,
            min: 0.02,
            max: 1.0,
            unit: 'ms',
            enabled: model.compOn,
            format: (v) => (v * 1000).toStringAsFixed(0),
            onChanged: model.setCompTimeconstant,
            onChangedEnd: model.setCompTimeconstant,
            onResetToDefault: () => model.setCompTimeconstant(0.14),
          ),
          const SizedBox(height: AuraSpace.sm),
          AdvancedSection(
            summary: '${model.compGranularity == 0 ? l.compGranularityCoarse : (model.compGranularity == 1 ? l.compGranularityNormal : l.compGranularityFine)} · AGC: ${model.compAutoGain ? "ON" : "OFF"} · ${(model.compOutputGain >= 0 ? "+" : "")}${model.compOutputGain.toStringAsFixed(1)} dB',
            builder: (ctx) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 分析颗粒度模式 (Granularity)
                Row(
                  children: [
                    Text(l.compGranularity, style: labelOf(p, color: p.text)),
                    const Spacer(),
                    Wrap(
                      spacing: AuraSpace.sm,
                      children: [
                        AuraChoiceChip(
                          label: l.compGranularityCoarse,
                          selected: model.compGranularity == 0,
                          onTap: model.compOn ? () => model.setCompGranularity(0) : null,
                        ),
                        AuraChoiceChip(
                          label: l.compGranularityNormal,
                          selected: model.compGranularity == 1,
                          onTap: model.compOn ? () => model.setCompGranularity(1) : null,
                        ),
                        AuraChoiceChip(
                          label: l.compGranularityFine,
                          selected: model.compGranularity == 2,
                          onTap: model.compOn ? () => model.setCompGranularity(2) : null,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                // 2. 时频分辨率 (Time-Frequency Resolution)
                Row(
                  children: [
                    Text(l.compTfresolution, style: labelOf(p, color: p.text)),
                    const Spacer(),
                    Wrap(
                      spacing: AuraSpace.sm,
                      children: [
                        AuraChoiceChip(
                          label: l.compTfresTransient,
                          selected: model.compTfresolution == 0,
                          onTap: model.compOn ? () => model.setCompTfresolution(0) : null,
                        ),
                        AuraChoiceChip(
                          label: l.compTfresBalanced,
                          selected: model.compTfresolution == 1,
                          onTap: model.compOn ? () => model.setCompTfresolution(1) : null,
                        ),
                        AuraChoiceChip(
                          label: l.compTfresFine,
                          selected: model.compTfresolution == 2,
                          onTap: model.compOn ? () => model.setCompTfresolution(2) : null,
                        ),
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.md),
                // 3. 输出级外框（自动增益补偿与输出增益门）
                OutputGainFrame(
                  child: Column(
                    children: [
                      _AutoGainRow(
                        label: l.autoGainCompensation,
                        tooltip: l.autoGainCompensationTooltip,
                        value: model.compAutoGain,
                        enabled: model.compOn,
                        onChanged: model.setCompAutoGain,
                      ),
                      const SizedBox(height: AuraSpace.xs),
                      ValueSlider(
                        label: l.outputGainGate,
                        infoMessage: l.outputGainGateTooltip,
                        value: model.compOutputGain,
                        defaultValue: ParamDefaults.compOutputGain,
                        onResetToDefault: () =>
                            model.setCompOutputGain(ParamDefaults.compOutputGain),
                        min: -12.0,
                        max: 6.0,
                        unit: 'dB',
                        enabled: model.compOn,
                        format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                        onChanged: model.setCompOutputGain,
                        onChangedEnd: model.setCompOutputGain,
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ---- 02 Bass (低音增强重构) ---- */

class _BassCard extends StatelessWidget {
  final AppModel model;
  const _BassCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return SectionCard(
      index: '02',
      title: l.bassBoost,
      collapsed: !model.bassOn,
      latencyMs: model.componentLatency('bass').ms,
              latencyMeasured: model.componentLatency('bass').measured,
              latencyProbing: model.isProbingLatency('bass'),
      onRefreshLatency: () => model.refreshComponentLatency('bass'),
      latencyTick: model.getComponentLatencyTick('bass'),
      trailing: AuraSwitch(
        value: model.bassOn,
        onChanged: (v) => model.setInt('bass.enable', v ? 1 : 0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 主驱动：低音增强强度 (Bass Intensity)
          ValueSlider(
            label: l.bassIntensity,
            infoMessage: '增强低音量感与冲击力。越高低频下潜越震撼，建议适度提升防轰头。',
            value: model.bassIntensity,
            defaultValue: ParamDefaults.bassIntensity,
            onResetToDefault: () =>
                model.setBassIntensity(ParamDefaults.bassIntensity),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.bassOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setBassIntensity,
            onChangedEnd: model.setBassIntensity,
          ),
          const SizedBox(height: AuraSpace.md),
          // 低音增强模式 — 标签与选项同行，选项右对齐
          Row(
            children: [
              Text(l.bassMode, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.bassModeTooltip),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  AuraChoiceChip(
                    label: l.bassModeDynamic,
                    selected: model.bassMode == 0,
                    onTap: () => model.setBassMode(0),
                  ),
                  AuraChoiceChip(
                    label: l.bassModeShelf,
                    selected: model.bassMode == 1,
                    onTap: () => model.setBassMode(1),
                  ),
                  AuraChoiceChip(
                    label: l.bassModeHarmonic,
                    selected: model.bassMode == 2,
                    onTap: () => model.setBassMode(2),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _BassAdvanced(model: model),
        ],
      ),
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

class _BassAdvanced extends StatelessWidget {
  final AppModel model;
  const _BassAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    return AdvancedSection(
      summary: '${m.bassCutoff.toStringAsFixed(0)} Hz · AGC: ${m.bassAutoGain ? "ON" : "OFF"} · ${(m.bassOutputGain >= 0 ? "+" : "")}${m.bassOutputGain.toStringAsFixed(1)} dB',
      builder: (context) => Column(
        children: [
              ValueSlider(
                label: l.bassCutoff,
                infoMessage: '低音增强作用的最高频率。低于该频率的声音将被加厚，一般建议 60~120Hz。',
                value: m.bassCutoff,
                defaultValue: ParamDefaults.bassCutoff,
                min: 30,
                max: 300,
                unit: 'Hz',
                enabled: m.bassOn,
                format: (v) => v.toStringAsFixed(0),
                onChanged: m.setBassCutoff,
                onChangedEnd: m.setBassCutoff,
                onResetToDefault: () => m.setBassCutoff(ParamDefaults.bassCutoff),
              ),
              ValueSlider(
                label: l.bassHarmonics,
                value: m.bassHarmonics,
                defaultValue: ParamDefaults.bassHarmonics,
                min: 0,
                max: 1,
                unit: '%',
                // 引擎侧暂无 bass.harmonics 参数：先只存 UI/预设状态，
                // 待谐波合成 DSP 落地后再接线。
                enabled: m.bassOn,
                format: (v) => (v * 100).toStringAsFixed(0),
                onChanged: m.setBassHarmonics,
                onChangedEnd: m.setBassHarmonics,
                onResetToDefault: () => m.setBassHarmonics(ParamDefaults.bassHarmonics),
              ),
              ValueSlider(
                label: l.bassBlend,
                value: m.bassHarmonicBlend,
                defaultValue: ParamDefaults.bassHarmonicBlend,
                min: 0,
                max: 1,
                unit: '%',
                // 同上：引擎侧无对应参数，先只存 UI/预设状态。
                enabled: m.bassOn,
                format: (v) => (v * 100).toStringAsFixed(0),
                onChanged: m.setBassHarmonicBlend,
                onChangedEnd: m.setBassHarmonicBlend,
                onResetToDefault: () =>
                    m.setBassHarmonicBlend(ParamDefaults.bassHarmonicBlend),
              ),
              ValueSlider(
                label: l.bassSubFloor,
                value: m.bassSubFloor,
                defaultValue: ParamDefaults.bassSubFloor,
                min: 10,
                max: 40,
                unit: 'Hz',
                // 同上：引擎侧无对应参数，先只存 UI/预设状态。
                enabled: m.bassOn,
                format: (v) => v.toStringAsFixed(0),
                onChanged: m.setBassSubFloor,
                onChangedEnd: m.setBassSubFloor,
                onResetToDefault: () => m.setBassSubFloor(ParamDefaults.bassSubFloor),
              ),
              const SizedBox(height: AuraSpace.md),
              OutputGainFrame(
                child: Column(
                  children: [
                    _AutoGainRow(
                      label: l.autoGainCompensation,
                      tooltip: l.autoGainCompensationTooltip,
                      value: m.bassAutoGain,
                      enabled: m.bassOn,
                      onChanged: m.setBassAutoGain,
                    ),
                    const SizedBox(height: AuraSpace.xs),
                    ValueSlider(
                      label: l.outputGainGate,
                      infoMessage: l.outputGainGateTooltip,
                      value: m.bassOutputGain,
                      defaultValue: ParamDefaults.bassOutputGain,
                      onResetToDefault: () =>
                          m.setBassOutputGain(ParamDefaults.bassOutputGain),
                      min: -12.0,
                      max: 6.0,
                      unit: 'dB',
                      enabled: m.bassOn,
                      format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                      onChanged: m.setBassOutputGain,
                      onChangedEnd: m.setBassOutputGain,
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}

class _SpatialReverbCard extends StatefulWidget {
  final AppModel model;
  const _SpatialReverbCard({required this.model});

  @override
  State<_SpatialReverbCard> createState() => _SpatialReverbCardState();
}

class _SpatialReverbCardState extends State<_SpatialReverbCard> {

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = widget.model;
    final isEnabled = m.isSpatialReverbOn;

    final presets = <int, String>{
      0: l.reverbPreset0, // 大音乐厅
      1: l.reverbPreset1, // 音乐厅
      2: l.reverbPreset2, // 中音乐厅
      3: l.reverbPreset3, // 小音乐厅
      4: l.reverbPreset4, // 录音棚
      5: l.reverbPreset5, // 房间
      6: l.reverbPreset6, // 大礼堂
      7: l.reverbPreset7, // 板式混响
    };

    return SectionCard(
      index: '04',
      title: l.spatialReverbTitle,
      collapsed: !isEnabled,
      latencyMs: m.componentLatency('reverb').ms,
              latencyMeasured: m.componentLatency('reverb').measured,
              latencyProbing: m.isProbingLatency('reverb'),
      onRefreshLatency: () => m.refreshComponentLatency('reverb'),
      latencyTick: m.getComponentLatencyTick('reverb'),
      trailing: AuraSwitch(
        value: isEnabled,
        onChanged: (v) => m.setSpatialReverbEnabled(v),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 置顶 3D 声学室沉浸视效（动态联动 roomSize 与 stereoWidth）
          RepaintBoundary(
            child: _Freeverb3DStage(
              decay: m.fvDecay,
              damp: m.fvDamp,
              roomSize: m.fvRoomSize,
              stereoWidth: m.fvWidth,
              active: isEnabled,
            ),
          ),
          const SizedBox(height: AuraSpace.md),

          // 2. 预设空间选择
          Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.sm,
            children: [
              for (final e in presets.entries)
                AuraChip(
                  e.value,
                  selected: isEnabled && m.reverbPreset == e.key,
                  onTap: () => m.selectReverbPreset(e.key),
                ),
              AuraChip(
                l.reverbCustom,
                icon: Icons.tune_rounded,
                selected: isEnabled && m.reverbPreset == -2 && m.fvOn,
                onTap: () {
                  if (m.reverbPreset != -2) {
                    m.selectReverbPreset(-2);
                  }
                },
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),

          // 3. 核心滑块：混响干湿比 (Wet/Dry Mix)
          ValueSlider(
            label: l.reverbMix,
            infoMessage: '混响声的音量占比。数值越高，空间空灵回荡感越强，如同置身音乐厅或教堂。',
            value: m.fvWet,
            defaultValue: ParamDefaults.fvWet,
            onResetToDefault: () => m.setReverbCustomParam('wet', ParamDefaults.fvWet),
            min: 0,
            max: 1,
            unit: '%',
            enabled: isEnabled,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => m.setReverbCustomParam('wet', v),
            onChangedEnd: (v) => m.setReverbCustomParam('wet', v),
          ),
          const SizedBox(height: AuraSpace.md),

          // 4. 高级声学物理精调（标准折叠面板）
          _SpatialReverbAdvanced(model: m),
        ],
      ),
    );
  }
}

class _SpatialReverbAdvanced extends StatelessWidget {
  final AppModel model;
  const _SpatialReverbAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    final isEnabled = m.isSpatialReverbOn;
    final agcStr = 'AGC: ${m.reverbAutoGain ? "ON" : "OFF"}';
    final trimStr =
        '${(m.reverbOutputGain >= 0 ? "+" : "")}${m.reverbOutputGain.toStringAsFixed(1)} dB';
    final roomStr =
        '${(m.fvRoomSize).toStringAsFixed(1)}x · ${(m.fvDecay * 100).toStringAsFixed(0)}%';

    return AdvancedSection(
      summary: '$roomStr · $agcStr · $trimStr',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.reverbRoomSize,
            infoMessage: '模拟虚拟房间尺寸。尺寸越大，声场越开阔、反射间隔越长。',
            value: m.fvRoomSize,
            defaultValue: ParamDefaults.fvRoomSize,
            onResetToDefault: () =>
                m.setReverbCustomParam('roomSize', ParamDefaults.fvRoomSize),
            min: 0.5,
            max: 2.5,
            unit: 'x',
            enabled: isEnabled,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => m.setReverbCustomParam('roomSize', v),
            onChangedEnd: (v) => m.setReverbCustomParam('roomSize', v),
          ),
          ValueSlider(
            label: l.fvDecayLabel,
            infoMessage: '反射残响消散时间。数值越大，声音余韵回荡持续越久。',
            value: m.fvDecay,
            defaultValue: ParamDefaults.fvDecay,
            onResetToDefault: () =>
                m.setReverbCustomParam('decay', ParamDefaults.fvDecay),
            min: 0,
            max: 1,
            unit: '%',
            enabled: isEnabled,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => m.setReverbCustomParam('decay', v),
            onChangedEnd: (v) => m.setReverbCustomParam('decay', v),
          ),
          ValueSlider(
            label: l.reverbStereoWidth,
            infoMessage: '混响声的双耳立体声扩展度。让回声包围整个头部。',
            value: m.fvWidth,
            defaultValue: ParamDefaults.fvWidth,
            onResetToDefault: () =>
                m.setReverbCustomParam('width', ParamDefaults.fvWidth),
            min: 0.2,
            max: 2.0,
            unit: 'x',
            enabled: isEnabled,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => m.setReverbCustomParam('width', v),
            onChangedEnd: (v) => m.setReverbCustomParam('width', v),
          ),
          ValueSlider(
            label: l.fvDampLabel,
            infoMessage: '高频阻尼吸收。越大音色越温暖柔和，越小越明亮通透。',
            value: m.fvDamp,
            defaultValue: ParamDefaults.fvDamp,
            onResetToDefault: () =>
                m.setReverbCustomParam('damp', ParamDefaults.fvDamp),
            min: 0,
            max: 1,
            unit: '%',
            enabled: isEnabled,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => m.setReverbCustomParam('damp', v),
            onChangedEnd: (v) => m.setReverbCustomParam('damp', v),
          ),
          ValueSlider(
            label: l.fvDryLabel,
            infoMessage: '原始直达声保留量。确保人声吐字清晰结实。',
            value: m.fvDry,
            defaultValue: ParamDefaults.fvDry,
            onResetToDefault: () =>
                m.setReverbCustomParam('dry', ParamDefaults.fvDry),
            min: 0,
            max: 1,
            unit: '%',
            enabled: isEnabled,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => m.setReverbCustomParam('dry', v),
            onChangedEnd: (v) => m.setReverbCustomParam('dry', v),
          ),
          const SizedBox(height: AuraSpace.md),
          OutputGainFrame(
            child: Column(
              children: [
                _AutoGainRow(
                  label: l.autoGainCompensation,
                  tooltip: l.autoGainCompensationTooltip,
                  value: m.reverbAutoGain,
                  enabled: isEnabled,
                  onChanged: m.setReverbAutoGain,
                ),
                const SizedBox(height: AuraSpace.xs),
                ValueSlider(
                  label: l.outputGainGate,
                  infoMessage: l.outputGainGateTooltip,
                  value: m.reverbOutputGain,
                  defaultValue: ParamDefaults.reverbOutputGain,
                  onResetToDefault: () =>
                      m.setReverbOutputGain(ParamDefaults.reverbOutputGain),
                  min: -12.0,
                  max: 6.0,
                  unit: 'dB',
                  enabled: isEnabled,
                  format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                  onChanged: m.setReverbOutputGain,
                  onChangedEnd: m.setReverbOutputGain,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ---- 02B BassMono (低频单声道化，链头) ----
 * 分频点以下 L/R 取平均。与 bass 卡相邻但独立开关：链头处理，
 * 不随 bassOn 折叠。频率滑块到下限不关开关（stereo 解耦教训）。 */
class _BassMonoCard extends StatelessWidget {
  final AppModel model;
  const _BassMonoCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: '03',
      title: l.stBassmono,
      collapsed: !model.bassmonoOn,
      latencyMs: model.componentLatency('bassmono').ms,
      latencyMeasured: model.componentLatency('bassmono').measured,
      latencyProbing: model.isProbingLatency('bassmono'),
      onRefreshLatency: () => model.refreshComponentLatency('bassmono'),
      latencyTick: model.getComponentLatencyTick('bassmono'),
      trailing: AuraSwitch(
        value: model.bassmonoOn,
        onChanged: model.setBassmonoEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 快捷分频点（主卡展示）
          Row(
            children: [
              Text(l.bassmonoFreq, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.bassmonoCombinedTooltip),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  for (final f in const [80.0, 120.0, 200.0])
                    AuraChoiceChip(
                      label: '${f.toStringAsFixed(0)} Hz',
                      selected:
                          (model.bassmonoFreq - f).abs() < 0.5,
                      onTap: model.bassmonoOn
                          ? () => model.setBassmonoFreq(f)
                          : null,
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          AdvancedSection(
            summary: '${model.bassmonoFreq.toStringAsFixed(0)} Hz',
            builder: (ctx) => ValueSlider(
              label: l.bassmonoFreq,
              infoMessage: l.bassmonoCombinedTooltip,
              value: model.bassmonoFreq,
              defaultValue: ParamDefaults.bassmonoFreq,
              onResetToDefault: () =>
                  model.setBassmonoFreq(ParamDefaults.bassmonoFreq),
              min: 20,
              max: 300,
              unit: 'Hz',
              enabled: model.bassmonoOn,
              format: (v) => v.toStringAsFixed(0),
              onChanged: model.setBassmonoFreq,
              onChangedEnd: model.setBassmonoFreq,
            ),
          ),
        ],
      ),
    );
  }
}

/* ---- 03 脉冲响应卷积 (Convolver) ---- */

/// 文件资源槽：带边框、标题行与状态位的按钮组。
///
/// 卷积 / VDC 两张卡片此前都是裸 `Wrap` 丢几个 chip，与下方内容既无分组也无
/// 边界，视觉上像「随便扔在那」。这里给它们一个统一的容器，读起来是
/// 「该效果依赖哪个外部文件」这一明确区块。
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
            Text(title, style: captionOf(p)),
            const Spacer(),
            if (detail != null)
              Text(
                detail!,
                style: captionOf(p).copyWith(color: p.accent),
              ),
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

class _ConvolverCard extends StatelessWidget {
  final AppModel model;
  const _ConvolverCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      index: '05',
      title: l.convTitle,
      // 常规语义：关闭即收起。用户先前明确要求「无文件时保持开关开启、
// 效果内部直通(旁路)，待合格文件加载成功后自动生效」，
// 因此可达性由 state 层的 auto-bypass 解决，而不是靠改这里的折叠判据。
      // D1 曾改成 convEnabled && convReady，导致「打开开关反而收起」的反向手感。
      collapsed: !model.convEnabled,
      latencyMs: model.componentLatency('convolver').ms,
              latencyMeasured: model.componentLatency('convolver').measured,
              latencyProbing: model.isProbingLatency('convolver'),
      onRefreshLatency: () => model.refreshComponentLatency('convolver'),
      latencyTick: model.getComponentLatencyTick('convolver'),
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.convEnabled,
          onChanged: (v) => model.setConvolverEnabled(v),
        ),
      ),
      child: ListenableBuilder(
        listenable: model,
        builder: (_, _) {
          if (!model.convReady) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ResourceSlot(
                  icon: Icons.folder_open_outlined,
                  title: l.convIrTitle,
                  actions: [
                    AuraChip(l.convOpenIr, icon: Icons.folder_open_outlined,
                        onTap: () => _pickIr(context)),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                Text(l.convNoIr, style: captionOf(p)),
              ],
            );
          }
          // convFrames 是**重采样到引擎 fs 之后**的帧数（见 load_ir_file 的离线重采样），
          // 所以换算基准是设备采样率，不是 IR 文件原始的 convSrcRate。
          final durMs = model.convFrames * 1000.0 / model.deviceRate;
          final dur = durMs >= 1000
              ? '${(durMs / 1000).toStringAsFixed(2)} s'
              : '${durMs.toStringAsFixed(0)} ms';
          final resampled = AppModel.irWasResampled(
            srcRate: model.convSrcRate,
            deviceRate: model.deviceRate,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ResourceSlot(
                icon: Icons.graphic_eq_outlined,
                title: l.convIrTitle,
                detail: '${model.convChannels}ch · $dur',
                actions: [
                  AuraChip(l.convOpenIr, icon: Icons.folder_open_outlined,
                      onTap: () => _pickIr(context)),
                  AuraChip(l.convClear, icon: Icons.delete_outline, danger: true,
                      onTap: () => model.clearConvolver()),
                ],
              ),
              const SizedBox(height: AuraSpace.md),
              if (model.convSpectrum.isNotEmpty) ...[
                _IrWaveformGraph(
                  spectrum: model.convSpectrum,
                  channels: model.convChannels,
                ),
                const SizedBox(height: AuraSpace.md),
              ],
              ValueSlider(
                label: l.convMix,
                infoMessage: '卷积混响混合比。0% 为原始干声，100% 完全沉浸在采样的空间声学混响中。',
                value: model.convMix,
                defaultValue: ParamDefaults.convMix,
                onResetToDefault: () =>
                    model.setFloat('convolver.mix', ParamDefaults.convMix),
                min: 0,
                max: 1,
                unit: '%',
                format: (v) => (v * 100).toStringAsFixed(0),
                onChanged: (v) => model.setFloat('convolver.mix', v),
                onChangedEnd: (v) => model.setFloat('convolver.mix', v),
              ),
              const SizedBox(height: AuraSpace.md),
              // 帧数行与重采样提示同行、提示右对齐；窄屏（Android/小窗）
              // 放不下时提示自动换到下一行并保持右对齐。
              LayoutBuilder(builder: (context, box) {
                final framesText = Text(
                  l.convFramesLine(
                      model.convFrames,
                      dur,
                      model.convChannels,
                      (20 * math.log(model.convPeak <= 1e-6 ? 1e-6 : model.convPeak) / math.ln10).toStringAsFixed(1),
                      model.convSrcRate),
                  style: monoOf(p, size: 12, color: p.text),
                );
                if (!resampled) return framesText;
                final hint = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.info_outline, size: 13, color: p.warning),
                    const SizedBox(width: AuraSpace.xs + 2),
                    Flexible(
                      child: Text(l.convResampled, style: captionOf(p)),
                    ),
                  ],
                );
                if (box.maxWidth >= 420) {
                  return Row(
                    children: [
                      Expanded(child: framesText),
                      const SizedBox(width: AuraSpace.sm),
                      hint,
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    framesText,
                    const SizedBox(height: 2),
                    Align(alignment: Alignment.centerRight, child: hint),
                  ],
                );
              }),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickIr(BuildContext context) async {
    const type = XTypeGroup(label: 'Audio IR (*.irs, *.wav, *.flac)',
        extensions: ['irs', 'wav', 'flac']);
    final f = await openFile(acceptedTypeGroups: [type]);
    if (f != null) model.loadConvolverIr(f.path);
  }
}

/* ---- 04 VDC 空间校正 ---- */

class _DdcCard extends StatelessWidget {
  final AppModel model;
  const _DdcCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      index: '06',
      title: l.ddcTitle,
      collapsed: !model.ddcOn, // 同上：常规语义 + state 层 auto-bypass
      latencyMs: model.componentLatency('ddc').ms,
              latencyMeasured: model.componentLatency('ddc').measured,
              latencyProbing: model.isProbingLatency('ddc'),
      onRefreshLatency: () => model.refreshComponentLatency('ddc'),
      latencyTick: model.getComponentLatencyTick('ddc'),
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.ddcOn,
          onChanged: (v) => model.setDdcEnabled(v),
        ),
      ),
      child: ListenableBuilder(
        listenable: model,
        builder: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ResourceSlot(
              icon: Icons.filter_alt_outlined,
              title: l.ddcFilterTitle,
              detail: model.ddcReady ? l.ddcLoaded : null,
              actions: [
                AuraChip(l.ddcOpen, icon: Icons.folder_open_outlined,
                    onTap: () => _pickVdc(context)),
                if (model.ddcReady)
                  AuraChip(l.ddcLoaded, icon: Icons.check_circle_outline,
                      onTap: null),
              ],
            ),
            const SizedBox(height: AuraSpace.sm),
            // D3：parseVdcMetadata 已算出文件名与采样率/长度，这里真正展示出来，
            // 否则用户只能看到一句「已加载」，无从判断加载的是哪个文件。
            if (model.ddcFileName != null) ...[
              Text('${l.ddcLoaded}：${model.ddcFileName}',
                  style: captionOf(p)),
              if (model.ddcDetails != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(model.ddcDetails!, style: captionOf(p)),
                ),
            ] else
              Text(l.ddcNoFile, style: captionOf(p)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickVdc(BuildContext context) async {
    const type = XTypeGroup(label: 'VDC', extensions: ['vdc']);
    final f = await openFile(acceptedTypeGroups: [type]);
    if (f != null) model.loadVdc(f.path);
  }
}

/* ---- 05 Equalizer (多段图形均衡器) ---- */

class _EqualizerCard extends StatelessWidget {
  final AppModel model;
  const _EqualizerCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '07',
      title: l.eqMultiBand,
      collapsed: !model.eqOn,
      latencyMs: model.componentLatency('eq').ms,
              latencyMeasured: model.componentLatency('eq').measured,
              latencyProbing: model.isProbingLatency('eq'),
      onRefreshLatency: () => model.refreshComponentLatency('eq'),
      latencyTick: model.getComponentLatencyTick('eq'),
      trailing: AuraSwitch(
        value: model.eqOn,
        onChanged: (v) => model.setInt('eq.enable', v ? 1 : 0),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InteractiveSpectrumEQPanel(model: model),
          const SizedBox(height: AuraSpace.sm),
          _EqualizerAdvanced(model: model),
        ],
      ),
    );
  }
}

class _EqualizerAdvanced extends StatelessWidget {
  final AppModel model;
  const _EqualizerAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = model;
    final filterStr = m.eqFilter == 0
        ? (m.eqInterp == 1 ? 'FIR · Makima' : 'FIR · PCHIP')
        : (m.eqFilter == 1 ? 'IIR6' : 'IIR12');
    final agcStr = 'AGC: ${m.eqAutoGain ? "ON" : "OFF"}';
    final trimStr =
        '${(m.eqOutputGain >= 0 ? "+" : "")}${m.eqOutputGain.toStringAsFixed(1)} dB';

    return AdvancedSection(
      summary: '$filterStr · $agcStr · $trimStr',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 滤波器架构
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(l.eqFilterType, style: labelOf(p, color: p.text)),
              const SizedBox(width: AuraSpace.md),
              Expanded(
                child: Align(
                  alignment: Alignment.centerRight,
                  child: Wrap(
                    spacing: AuraSpace.sm,
                    runSpacing: AuraSpace.xs,
                    alignment: WrapAlignment.end,
                    children: [
                      AuraChoiceChip(
                        label: l.eqFilterMinphase,
                        selected: m.eqFilter == 0,
                        onTap: () => m.setEqFilter(0),
                      ),
                      AuraChoiceChip(
                        label: l.eqFilterIir6,
                        selected: m.eqFilter == 1,
                        onTap: () => m.setEqFilter(1),
                      ),
                      AuraChoiceChip(
                        label: l.eqFilterIir12,
                        selected: m.eqFilter == 2,
                        onTap: () => m.setEqFilter(2),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),

          // 2. 插值算法（FIR 模式下生效）
          Opacity(
            opacity: m.eqFilter == 0 ? 1.0 : 0.45,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Text(l.eqInterpolation, style: labelOf(p, color: p.text)),
                const SizedBox(width: AuraSpace.md),
                Expanded(
                  child: Align(
                    alignment: Alignment.centerRight,
                    child: Wrap(
                      spacing: AuraSpace.sm,
                      runSpacing: AuraSpace.xs,
                      alignment: WrapAlignment.end,
                      children: [
                        AuraChoiceChip(
                          label: l.eqInterpMakima,
                          selected: m.eqInterp == 1,
                          onTap: m.eqFilter == 0 ? () => m.setEqInterp(1) : null,
                        ),
                        AuraChoiceChip(
                          label: l.eqInterpPchip,
                          selected: m.eqInterp == 0,
                          onTap: m.eqFilter == 0 ? () => m.setEqInterp(0) : null,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: AuraSpace.md),

          // 3. 输出级外框（自动增益补偿与输出增益门）
          OutputGainFrame(
            child: Column(
              children: [
                _AutoGainRow(
                  label: l.autoGainCompensation,
                  tooltip: l.autoGainCompensationTooltip,
                  value: m.eqAutoGain,
                  enabled: m.eqOn,
                  onChanged: m.setEqAutoGain,
                ),
                const SizedBox(height: AuraSpace.xs),
                ValueSlider(
                  label: l.outputGainGate,
                  infoMessage: l.outputGainGateTooltip,
                  value: m.eqOutputGain,
                  defaultValue: ParamDefaults.eqOutputGain,
                  onResetToDefault: () =>
                      m.setEqOutputGain(ParamDefaults.eqOutputGain),
                  min: -12.0,
                  max: 6.0,
                  unit: 'dB',
                  enabled: m.eqOn,
                  format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                  onChanged: m.setEqOutputGain,
                  onChangedEnd: m.setEqOutputGain,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ---- 07 ArbMag (任意响应均衡器 / AutoEq GraphicEQ) ---- */

class _ArbmagCard extends StatefulWidget {
  final AppModel model;
  const _ArbmagCard({required this.model});

  @override
  State<_ArbmagCard> createState() => _ArbmagCardState();
}

class _ArbmagCardState extends State<_ArbmagCard> {
  final TextEditingController _codeCtrl = TextEditingController();
  bool _codeSynced = false;

  @override
  void initState() {
    super.initState();
    _codeCtrl.text = widget.model.arbmagString;
  }

  @override
  void didUpdateWidget(covariant _ArbmagCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!_codeSynced || oldWidget.model.arbmagString != widget.model.arbmagString) {
      _codeCtrl.text = widget.model.arbmagString;
      _codeSynced = true;
    }
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  static const String _kPresetFlat = 'GraphicEQ: 20 0.0; 1000 0.0; 20000 0.0';
  static const String _kPresetHarman =
      'GraphicEQ: 20 5.4; 32 5.0; 64 4.0; 125 2.5; 250 1.0; 500 0.0; 1000 0.0; 2000 1.5; 3000 3.0; 4000 1.0; 6000 -1.5; 8000 -2.0; 10000 0.0; 16000 -3.0; 20000 -6.0';
  static const String _kPresetDiffuse =
      'GraphicEQ: 20 0.0; 100 0.0; 1000 0.0; 2000 3.5; 3000 8.0; 4000 4.0; 6000 1.5; 8000 3.0; 10000 1.0; 16000 -2.0; 20000 -5.0';

  String _cleanGraphicEqText(String input) {
    final trimmed = input.trim();
    if (trimmed.isEmpty) return '';
    if (!trimmed.toLowerCase().startsWith('graphiceq:')) {
      return 'GraphicEQ: $trimmed';
    }
    return trimmed;
  }

  Future<void> _importFile(BuildContext context) async {
    const type = XTypeGroup(label: 'AutoEq GraphicEQ', extensions: ['txt', 'csv']);
    final file = await openFile(acceptedTypeGroups: [type]);
    if (file != null) {
      try {
        final text = await file.readAsString();
        final cleaned = _cleanGraphicEqText(text);
        if (cleaned.isNotEmpty) {
          widget.model.setArbmagString(cleaned);
          _codeCtrl.text = cleaned;
        }
      } catch (e) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('读取文件失败: $e')),
          );
        }
      }
    }
  }

  Future<void> _pasteClipboard(BuildContext context) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text?.trim() ?? '';
    if (text.isEmpty) return;
    final cleaned = _cleanGraphicEqText(text);
    if (cleaned.isNotEmpty) {
      widget.model.setArbmagString(cleaned);
      _codeCtrl.text = cleaned;
    }
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = widget.model;

    return SectionCard(
      index: '08',
      title: l.stArbmag,
      collapsed: !m.arbmagOn,
      latencyMs: m.componentLatency('arbmag').ms,
      latencyMeasured: m.componentLatency('arbmag').measured,
      latencyProbing: m.isProbingLatency('arbmag'),
      onRefreshLatency: () => m.refreshComponentLatency('arbmag'),
      latencyTick: m.getComponentLatencyTick('arbmag'),
      trailing: AuraSwitch(
        value: m.arbmagOn,
        onChanged: m.setArbmagEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l.arbmagSubtitle, style: captionOf(p)),
          const SizedBox(height: AuraSpace.sm),

          // 1. 微缩频响曲线预览
          _ArbmagCurvePreview(
            rawString: m.arbmagString,
            palette: p,
            emptyHint: l.arbmagEmptyHint,
          ),
          const SizedBox(height: AuraSpace.sm),

          // 2. 经典目标预设芯片栏
          Wrap(
            spacing: AuraSpace.sm,
            runSpacing: AuraSpace.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              AuraChoiceChip(
                label: l.arbmagPresetFlat,
                selected: m.arbmagString == _kPresetFlat,
                onTap: () {
                  m.setArbmagString(_kPresetFlat);
                  _codeCtrl.text = _kPresetFlat;
                },
              ),
              AuraChoiceChip(
                label: l.arbmagPresetHarman,
                selected: m.arbmagString == _kPresetHarman,
                onTap: () {
                  m.setArbmagString(_kPresetHarman);
                  _codeCtrl.text = _kPresetHarman;
                },
              ),
              AuraChoiceChip(
                label: l.arbmagPresetDiffuse,
                selected: m.arbmagString == _kPresetDiffuse,
                onTap: () {
                  m.setArbmagString(_kPresetDiffuse);
                  _codeCtrl.text = _kPresetDiffuse;
                },
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),

          // 3. 高级折叠面板（源码编辑、导入/粘贴工具、AGC、输出增益门）
          _ArbmagAdvanced(
            model: m,
            codeCtrl: _codeCtrl,
            onApplyCode: (code) {
              final cleaned = _cleanGraphicEqText(code);
              m.setArbmagString(cleaned);
            },
            onImportFile: () => _importFile(context),
            onPasteClipboard: () => _pasteClipboard(context),
            onClear: () {
              m.clearArbmag();
              _codeCtrl.clear();
            },
          ),
        ],
      ),
    );
  }
}

class _ArbmagCurvePreview extends StatelessWidget {
  final String rawString;
  final AuraPalette palette;
  final String emptyHint;

  const _ArbmagCurvePreview({
    required this.rawString,
    required this.palette,
    required this.emptyHint,
  });

  static List<({double freq, double gain})> parseNodes(String raw) {
    if (raw.isEmpty) return const [];
    final clean = raw.replaceAll(RegExp(r'^[Gg]raphic[Ee][Qq]:\s*'), '');
    final pairs = clean.split(';');
    final list = <({double freq, double gain})>[];
    for (final p in pairs) {
      final parts = p.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2) {
        final f = double.tryParse(parts[0]);
        final g = double.tryParse(parts[1]);
        if (f != null && g != null) {
          list.add((freq: f, gain: g));
        }
      }
    }
    list.sort((a, b) => a.freq.compareTo(b.freq));
    return list;
  }

  @override
  Widget build(BuildContext context) {
    final nodes = parseNodes(rawString);

    return Container(
      height: 120,
      width: double.infinity,
      decoration: BoxDecoration(
        color: palette.panelRaised.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: palette.hairline.withValues(alpha: 0.8)),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          CustomPaint(
            size: Size.infinite,
            painter: _ArbmagCurvePainter(
              nodes: nodes,
              palette: palette,
            ),
          ),
          if (nodes.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  emptyHint,
                  textAlign: TextAlign.center,
                  style: captionOf(palette).copyWith(fontSize: 11),
                ),
              ),
            )
          else
            Positioned(
              right: 8,
              top: 6,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: palette.panel.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                  border: Border.all(color: palette.hairline.withValues(alpha: 0.5)),
                ),
                child: Text(
                  '${nodes.length} 频点',
                  style: monoOf(palette, size: 9.5, color: palette.accent),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _ArbmagCurvePainter extends CustomPainter {
  final List<({double freq, double gain})> nodes;
  final AuraPalette palette;

  const _ArbmagCurvePainter({
    required this.nodes,
    required this.palette,
  });

  static const double _minF = 20.0;
  static const double _maxF = 20000.0;
  static const double _maxDb = 20.0;
  static const double _minDb = -20.0;

  static double _fToX(double f, double width) {
    final clampedF = f.clamp(_minF, _maxF);
    final logMin = math.log(_minF);
    final logMax = math.log(_maxF);
    return ((math.log(clampedF) - logMin) / (logMax - logMin)) * width;
  }

  static double _dbToY(double db, double height) {
    final clampedDb = db.clamp(_minDb, _maxDb);
    final norm = (clampedDb - _minDb) / (_maxDb - _minDb);
    return (1.0 - norm) * height;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;

    // 1. 网格背景线 (对数频标 100, 1k, 10k)
    final gridPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.4)
      ..strokeWidth = 0.8;
    for (final f in [100.0, 1000.0, 10000.0]) {
      final x = _fToX(f, w);
      canvas.drawLine(Offset(x, 0), Offset(x, h), gridPaint);
    }

    // 分贝基线: 0dB
    final zeroY = _dbToY(0.0, h);
    final zeroPaint = Paint()
      ..color = palette.textDim.withValues(alpha: 0.3)
      ..strokeWidth = 1.0;
    canvas.drawLine(Offset(0, zeroY), Offset(w, zeroY), zeroPaint);

    // +10dB, -10dB 浅色细线
    for (final db in [10.0, -10.0]) {
      final y = _dbToY(db, h);
      canvas.drawLine(Offset(0, y), Offset(w, y), gridPaint);
    }

    if (nodes.isEmpty) return;

    // 2. 绘制频响曲线路径
    final path = Path();
    final fillPath = Path();

    final firstX = _fToX(nodes.first.freq, w);
    final firstY = _dbToY(nodes.first.gain, h);

    path.moveTo(0, firstY);
    path.lineTo(firstX, firstY);

    fillPath.moveTo(0, zeroY);
    fillPath.lineTo(0, firstY);
    fillPath.lineTo(firstX, firstY);

    for (var i = 1; i < nodes.length; i++) {
      final prevX = _fToX(nodes[i - 1].freq, w);
      final prevY = _dbToY(nodes[i - 1].gain, h);
      final curX = _fToX(nodes[i].freq, w);
      final curY = _dbToY(nodes[i].gain, h);

      final cX = (prevX + curX) / 2.0;
      path.cubicTo(cX, prevY, cX, curY, curX, curY);
      fillPath.cubicTo(cX, prevY, cX, curY, curX, curY);
    }

    final lastX = _fToX(nodes.last.freq, w);
    final lastY = _dbToY(nodes.last.gain, h);
    if (lastX < w) {
      path.lineTo(w, lastY);
      fillPath.lineTo(w, lastY);
    }

    fillPath.lineTo(w, zeroY);
    fillPath.close();

    // 渐变填充
    final fillGradient = LinearGradient(
      begin: Alignment.topCenter,
      end: Alignment.bottomCenter,
      colors: [
        palette.accent.withValues(alpha: 0.28),
        palette.accent.withValues(alpha: 0.04),
      ],
    );
    final fillPaint = Paint()
      ..shader = fillGradient.createShader(Rect.fromLTWH(0, 0, w, h))
      ..style = PaintingStyle.fill;
    canvas.drawPath(fillPath, fillPaint);

    // 曲线轮廓
    final strokePaint = Paint()
      ..color = palette.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(path, strokePaint);

    // 绘制离散节点圆点（当节点数小于 40 时绘制微型亮点）
    if (nodes.length <= 40) {
      final dotPaint = Paint()
        ..color = palette.accent
        ..style = PaintingStyle.fill;
      for (final n in nodes) {
        final x = _fToX(n.freq, w);
        final y = _dbToY(n.gain, h);
        canvas.drawCircle(Offset(x, y), 2.2, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _ArbmagCurvePainter oldDelegate) =>
      oldDelegate.nodes != nodes || oldDelegate.palette != palette;
}

class _ArbmagAdvanced extends StatelessWidget {
  final AppModel model;
  final TextEditingController codeCtrl;
  final ValueChanged<String> onApplyCode;
  final VoidCallback onImportFile;
  final VoidCallback onPasteClipboard;
  final VoidCallback onClear;

  const _ArbmagAdvanced({
    required this.model,
    required this.codeCtrl,
    required this.onApplyCode,
    required this.onImportFile,
    required this.onPasteClipboard,
    required this.onClear,
  });

  bool get _hasValidCode {
    final text = codeCtrl.text.trim();
    if (text.isEmpty) return false;
    final lower = text.toLowerCase();
    final content = lower.startsWith('graphiceq:') ? text.substring(10).trim() : text;
    // 粗略校验至少包含一个分号或频点数对
    return content.contains(';') || content.split(RegExp(r'\s+')).length >= 2;
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = model;

    final agcStr = 'AGC: ${m.arbmagAutoGain ? "ON" : "OFF"}';
    final trimStr =
        '${(m.arbmagOutputGain >= 0 ? "+" : "")}${m.arbmagOutputGain.toStringAsFixed(1)} dB';
    final nodesStr = '${m.arbmagNodeCount} 节点';

    return AdvancedSection(
      summary: '$agcStr · $trimStr · $nodesStr',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. GraphicEQ 代码编辑器
          Text(l.arbmagEditor, style: labelOf(p, color: p.text)),
          const SizedBox(height: AuraSpace.xxs),
          Container(
            decoration: BoxDecoration(
              color: p.panelRaised,
              borderRadius: BorderRadius.circular(AuraRadius.xs),
              border: Border.all(color: p.hairline.withValues(alpha: 0.6)),
            ),
            padding: const EdgeInsets.all(8),
            child: TextField(
              controller: codeCtrl,
              maxLines: 4,
              minLines: 2,
              style: monoOf(p, size: 11, color: p.text),
              decoration: InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.zero,
                border: InputBorder.none,
                hintText: 'GraphicEQ: 20 0.0; 1000 0.0; 20000 0.0',
                hintStyle: monoOf(p, size: 11, color: p.textDim),
              ),
            ),
          ),
          const SizedBox(height: AuraSpace.sm),

          // 2. 工具栏：[应用代码] [导入文件] [从剪贴板粘贴] [清空]
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: codeCtrl,
            builder: (context, value, _) {
              final canApply = _hasValidCode;
              return Row(
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: canApply ? p.accent : p.panelRaised,
                      foregroundColor: canApply ? p.panel : p.textDim,
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                      minimumSize: Size.zero,
                      textStyle: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                    onPressed: canApply ? () => onApplyCode(codeCtrl.text) : null,
                    child: Text(l.arbmagApply),
                  ),
                  const SizedBox(width: AuraSpace.sm),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.text,
                      side: BorderSide(color: p.hairline),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    icon: const Icon(Icons.file_upload_outlined, size: 14),
                    label: Text(l.arbmagImport),
                    onPressed: onImportFile,
                  ),
                  const SizedBox(width: AuraSpace.sm),
                  OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: p.text,
                      side: BorderSide(color: p.hairline),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
                      textStyle: const TextStyle(fontSize: 12),
                    ),
                    icon: const Icon(Icons.content_paste_rounded, size: 14),
                    label: Text(l.arbmagPaste),
                    onPressed: onPasteClipboard,
                  ),
                  const Spacer(),
                  if (m.arbmagString.isNotEmpty || codeCtrl.text.isNotEmpty)
                    TextButton.icon(
                      style: TextButton.styleFrom(
                        foregroundColor: p.textDim,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        textStyle: const TextStyle(fontSize: 12),
                      ),
                      icon: const Icon(Icons.clear_all_rounded, size: 14),
                      label: Text(l.arbmagClear),
                      onPressed: onClear,
                    ),
                ],
              );
            },
          ),
          const SizedBox(height: AuraSpace.md),

          // 3. 输出级外框（自动增益补偿与输出增益门）
          OutputGainFrame(
            child: Column(
              children: [
                _AutoGainRow(
                  label: l.autoGainCompensation,
                  tooltip: l.autoGainCompensationTooltip,
                  value: m.arbmagAutoGain,
                  enabled: m.arbmagOn,
                  onChanged: m.setArbmagAutoGain,
                ),
                const SizedBox(height: AuraSpace.xs),
                ValueSlider(
                  label: l.outputGainGate,
                  infoMessage: l.outputGainGateTooltip,
                  value: m.arbmagOutputGain,
                  defaultValue: ParamDefaults.arbmagOutputGain,
                  onResetToDefault: () =>
                      m.setArbmagOutputGain(ParamDefaults.arbmagOutputGain),
                  min: -12.0,
                  max: 6.0,
                  unit: 'dB',
                  enabled: m.arbmagOn,
                  format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                  onChanged: m.setArbmagOutputGain,
                  onChangedEnd: m.setArbmagOutputGain,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/* ---- 09 Crossfeed (串扰消除 / 交叉馈送) ---- */

class _CrossfeedCard extends StatelessWidget {
  final AppModel model;
  const _CrossfeedCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = model;
    final isEnabled = m.xfeedOn;

    final modeLabels = <int, String>{
      0: l.crossfeedModeDefault,
      1: l.crossfeedModeChuMoy,
      2: l.crossfeedModeJanMeier,
      3: l.crossfeedModeCustom,
    };

    return SectionCard(
      index: '09',
      title: l.crossfeedTitle,
      titleTooltip: l.crossfeedDesc,
      collapsed: !isEnabled,
      latencyMs: m.componentLatency('crossfeed').ms,
      latencyMeasured: m.componentLatency('crossfeed').measured,
      latencyProbing: m.isProbingLatency('crossfeed'),
      onRefreshLatency: () => m.refreshComponentLatency('crossfeed'),
      latencyTick: m.getComponentLatencyTick('crossfeed'),
      trailing: AuraSwitch(
        value: isEnabled,
        onChanged: (v) => m.setCrossfeedEnabled(v),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 模式切换行：模式标签 + 问号帮助气泡 + AuraChoiceChip 芯片组
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Text(l.crossfeedMode, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: '切换经典硬件耳机串扰模拟算法预设或自定义微调。消除耳机“头中效应”，还原自然音箱声场。'),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                runSpacing: AuraSpace.xs,
                alignment: WrapAlignment.end,
                children: [
                  for (final e in modeLabels.entries)
                    AuraChoiceChip(
                      label: e.value,
                      selected: isEnabled && m.xfeedMode == e.key,
                      onTap: isEnabled ? () => m.setCrossfeedMode(e.key) : null,
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _CrossfeedAdvanced(model: m),
        ],
      ),
    );
  }
}

class _CrossfeedAdvanced extends StatelessWidget {
  final AppModel model;
  const _CrossfeedAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    final isEnabled = m.xfeedOn;

    final modeLabels = <int, String>{
      0: l.crossfeedModeDefault,
      1: l.crossfeedModeChuMoy,
      2: l.crossfeedModeJanMeier,
      3: l.crossfeedModeCustom,
    };
    final curModeLabel = modeLabels[m.xfeedMode] ?? l.crossfeedModeDefault;

    return AdvancedSection(
      summary: '${m.xfeedFcut.toStringAsFixed(0)} Hz · ${m.xfeedFeed.toStringAsFixed(1)} dB · $curModeLabel',
      helpTooltip: '自定义串扰低通截止频率与互馈衰减深度微调。',
      builder: (ctx) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.crossfeedCutoff,
            infoMessage: '串扰低通滤波器的截止频率 (300 ~ 2000 Hz)。频率越高，被互馈到对侧声道的频带范围越宽。',
            value: m.xfeedFcut,
            defaultValue: 700.0,
            onResetToDefault: () => m.setCrossfeedFcut(700.0),
            min: 300.0,
            max: 2000.0,
            unit: 'Hz',
            enabled: isEnabled,
            format: (v) => v.toStringAsFixed(0),
            onChanged: (v) => m.setCrossfeedFcut(v),
            onChangedEnd: (v) => m.setCrossfeedFcut(v),
          ),
          const SizedBox(height: AuraSpace.sm),
          ValueSlider(
            label: l.crossfeedFeed,
            infoMessage: '低频串扰互馈衰减量 (1.0 ~ 15.0 dB)。数值越小互馈越多、声场越宽；数值越大串扰越轻微。',
            value: m.xfeedFeed,
            defaultValue: 4.5,
            onResetToDefault: () => m.setCrossfeedFeed(4.5),
            min: 1.0,
            max: 15.0,
            unit: 'dB',
            enabled: isEnabled,
            format: (v) => v.toStringAsFixed(1),
            onChanged: (v) => m.setCrossfeedFeed(v),
            onChangedEnd: (v) => m.setCrossfeedFeed(v),
          ),
        ],
      ),
    );
  }
}

/* ---- 06 Stereo (立体声声场展宽) ---- */

class _StereoCard extends StatelessWidget {
  final AppModel model;
  const _StereoCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '10',
      title: l.stereoWiden,
      collapsed: !model.stereoOn,
      latencyMs: model.componentLatency('stereo').ms,
              latencyMeasured: model.componentLatency('stereo').measured,
              latencyProbing: model.isProbingLatency('stereo'),
      onRefreshLatency: () => model.refreshComponentLatency('stereo'),
      latencyTick: model.getComponentLatencyTick('stereo'),
      trailing: AuraSwitch(
        value: model.stereoOn,
        onChanged: (v) => model.setStereoEnabled(v),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.stereoWiden,
            infoMessage: '拉伸左右耳声像边界。适度拉伸让耳机如大音箱脱箱，拉太大可能削弱中央人声聚焦。',
            value: model.stereoMix,
            defaultValue: ParamDefaults.stereoMix,
            onResetToDefault: model.resetStereoWiden,
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.stereoOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: (v) => model.setStereoMix(v),
            onChangedEnd: (v) => model.setStereoMix(v),
          ),
          const SizedBox(height: AuraSpace.md),
          _StereoAdvanced(model: model),
        ],
      ),
    );
  }
}

/// 声场分带细化（默认折叠）：5 个子带独立 mix
class _StereoAdvanced extends StatelessWidget {
  final AppModel model;
  const _StereoAdvanced({required this.model});


  @override
  Widget build(BuildContext context) {
    final m = model;
    return AdvancedSection(
      summary: '${(m.stereoMix * 100).toStringAsFixed(0)}%',
      helpTooltip: l10nOf(context).stBandHint,
      builder: (context) {
        return Column(
          children: [
            for (var i = 0; i < 5; i++)
              _BandSlider(
                model: m,
                index: i,
                label: [l10nOf(context).stBand0, l10nOf(context).stBand1, l10nOf(context).stBand2, l10nOf(context).stBand3, l10nOf(context).stBand4][i],
              ),
          ],
        );
      },
    );
  }
}

class _BandSlider extends StatelessWidget {
  final AppModel model;
  final int index;
  final String label;

  const _BandSlider({
    required this.model,
    required this.index,
    required this.label,
  });

  @override
  Widget build(BuildContext context) {
    final m = model;
    return ListenableBuilder(
      listenable: m,
      builder: (_, _) {
        final v = m.stereoBands[index];
        return ValueSlider(
          label: label,
          value: v,
          defaultValue: ParamDefaults.stereoBand,
          min: 0,
          max: 1,
          unit: '%',
          enabled: m.stereoOn,
          format: (val) => (val * 100).toStringAsFixed(0),
          onChanged: (val) => m.setStereoBand(index, val),
          onChangedEnd: (val) => m.setStereoBand(index, val),
          onResetToDefault: () => m.resetStereoBand(index),
        );
      },
    );
  }
}

/* ---- 06B Haas 差分环绕 (右声道延迟 + 干湿混合) ----
 * stereo 后 / reverb 前；左声道恒直通保单声道兼容。
 * 延迟滑块到 0 只归零延迟，不关开关（stereo 解耦教训）。 */
class _HaasCard extends StatelessWidget {
  final AppModel model;
  const _HaasCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: '11',
      title: l.stHaas,
      collapsed: !model.haasOn,
      latencyMs: model.componentLatency('haas').ms,
      latencyMeasured: model.componentLatency('haas').measured,
      latencyProbing: model.isProbingLatency('haas'),
      onRefreshLatency: () => model.refreshComponentLatency('haas'),
      latencyTick: model.getComponentLatencyTick('haas'),
      trailing: AuraSwitch(
        value: model.haasOn,
        onChanged: model.setHaasEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 延迟侧切换（差分环绕的声道偏好）
          Row(
            children: [
              Text(l.haasSide, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.haasSideTooltip),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  AuraChoiceChip(
                    label: l.haasSideRight,
                    selected: model.haasSide == 0,
                    onTap: model.haasOn
                        ? () => model.setHaasSide(0)
                        : null,
                  ),
                  AuraChoiceChip(
                    label: l.haasSideLeft,
                    selected: model.haasSide == 1,
                    onTap: model.haasOn
                        ? () => model.setHaasSide(1)
                        : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // 延迟量
          ValueSlider(
            label: l.haasDelay,
            infoMessage: '延迟侧 0~25ms（Haas 定位差）。12ms 附近声场出头中，太大则成回声。',
            value: model.haasDelayMs,
            defaultValue: ParamDefaults.haasDelayMs,
            onResetToDefault: () =>
                model.setHaasDelay(ParamDefaults.haasDelayMs),
            min: 0,
            max: 25,
            unit: 'ms',
            enabled: model.haasOn,
            format: (v) => v.toStringAsFixed(1),
            onChanged: model.setHaasDelay,
            onChangedEnd: model.setHaasDelay,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 干湿混合
          ValueSlider(
            label: l.haasMix,
            infoMessage: '湿声（延迟差分）比例。拉低保中央人声聚焦，单声道设备自动兼容。',
            value: model.haasMix,
            defaultValue: ParamDefaults.haasMix,
            onResetToDefault: () =>
                model.setHaasMix(ParamDefaults.haasMix),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.haasOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setHaasMix,
            onChangedEnd: model.setHaasMix,
          ),
        ],
      ),
    );
  }
}

/* ---- 06C Exciter (激励器，最后一道音色工序) ----
 * HPF 取高频 + tanh 谐波混回。只暴露 amount/hifreq（drive 固定防刺耳）。
 * 文案禁用“杜比/母带级”等词。 */
class _ExciterCard extends StatelessWidget {
  final AppModel model;
  const _ExciterCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return SectionCard(
      index: '12',
      title: l.stExciter,
      collapsed: !model.exciterOn,
      latencyMs: model.componentLatency('exciter').ms,
      latencyMeasured: model.componentLatency('exciter').measured,
      latencyProbing: model.isProbingLatency('exciter'),
      onRefreshLatency: () => model.refreshComponentLatency('exciter'),
      latencyTick: model.getComponentLatencyTick('exciter'),
      trailing: AuraSwitch(
        value: model.exciterOn,
        onChanged: model.setExciterEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 激励器模式
          Row(
            children: [
              Text(l.exciterMode, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.exciterModeTooltip),
              const Spacer(),
              AuraChip(
                'tanh',
                selected: true,
                onTap: null,
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // 谐波量
          ValueSlider(
            label: l.exciterAmount,
            infoMessage: l.exciterAmountInfo,
            value: model.exciterAmount,
            defaultValue: ParamDefaults.exciterAmount,
            onResetToDefault: () =>
                model.setExciterAmount(ParamDefaults.exciterAmount),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.exciterOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setExciterAmount,
            onChangedEnd: model.setExciterAmount,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 取频点
          ValueSlider(
            label: l.exciterHifreq,
            infoMessage: '只取该频率以上成分做谐波。MP3 缺高频时往低调，齿音重时往高调。',
            value: model.exciterHifreq,
            defaultValue: ParamDefaults.exciterHifreq,
            onResetToDefault: () =>
                model.setExciterHifreq(ParamDefaults.exciterHifreq),
            min: 3000,
            max: 10000,
            unit: 'Hz',
            enabled: model.exciterOn,
            format: (v) => '${(v / 1000).toStringAsFixed(1)}k',
            onChanged: model.setExciterHifreq,
            onChangedEnd: model.setExciterHifreq,
          ),
        ],
      ),
    );
  }
}

/* ---- 07 Tube Simulator (电子管模拟器) ---- */

class _TubeCard extends StatelessWidget {
  final AppModel model;
  const _TubeCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return SectionCard(
      index: '13',
      title: l.tubeTitle,
      collapsed: !model.tubeOn,
      latencyMs: model.componentLatency('tube').ms,
              latencyMeasured: model.componentLatency('tube').measured,
              latencyProbing: model.isProbingLatency('tube'),
      onRefreshLatency: () => model.refreshComponentLatency('tube'),
      latencyTick: model.getComponentLatencyTick('tube'),
      trailing: AuraSwitch(
        value: model.tubeOn,
        onChanged: model.setTubeEnabled,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 饱和驱动度 (Drive / Saturation)
          ValueSlider(
            label: l.tubeDrive,
            infoMessage: '模拟经典电子管偶次谐波失真。带来醇厚耐听的模拟胶片暖色调，消除数码干冷感。',
            value: model.tubeGain,
            defaultValue: ParamDefaults.tubeGain,
            onResetToDefault: () => model.setTubeGain(ParamDefaults.tubeGain),
            min: -3,
            max: 12,
            unit: 'dB',
            enabled: model.tubeOn,
            format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
            onChanged: model.setTubeGain,
            onChangedEnd: model.setTubeGain,
          ),
          const SizedBox(height: AuraSpace.md),
          // 电子管音色风格
          // 电子管音色风格 — 标签与选项同行，选项右对齐
          Row(
            children: [
              Text(l.tubeStyle, style: labelOf(p, color: p.text)),
              const Spacer(),
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  AuraChoiceChip(
                    label: l.tubeStyleTriode,
                    selected: model.tubeStyle == 0,
                    onTap: () => model.setTubeStyle(0),
                  ),
                  AuraChoiceChip(
                    label: l.tubeStylePentode,
                    selected: model.tubeStyle == 1,
                    onTap: () => model.setTubeStyle(1),
                  ),
                  AuraChoiceChip(
                    label: l.tubeStyleTape,
                    selected: model.tubeStyle == 2,
                    onTap: () => model.setTubeStyle(2),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.md),
          _TubeAdvanced(model: model),
        ],
      ),
    );
  }
}

class _TubeAdvanced extends StatelessWidget {
  final AppModel model;
  const _TubeAdvanced({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final m = model;
    return AdvancedSection(
      summary:
          '${m.tubeOversampling}x · AGC: ${m.tubeAutoGain ? "ON" : "OFF"} · ${(m.tubeOutputGain >= 0 ? "+" : "")}${m.tubeOutputGain.toStringAsFixed(1)} dB',
      builder: (context) {
        final p = paletteOf(context);
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    l.tubeOversampling,
                    style: labelOf(p, color: p.text),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: AuraSpace.sm),
                Wrap(
                  spacing: AuraSpace.sm,
                  alignment: WrapAlignment.end,
                  children: [
                    for (final os in const [1, 2, 4])
                      AuraChoiceChip(
                        label: '${os}x',
                        selected: m.tubeOversampling == os,
                        onTap: () => m.setTubeOversampling(os),
                      ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: AuraSpace.sm),
            ValueSlider(
              label: l.tubeMix,
              value: m.tubeMix,
              defaultValue: ParamDefaults.tubeMix,
              onResetToDefault: () => m.setTubeMix(ParamDefaults.tubeMix),
              min: 0,
              max: 1,
              unit: '%',
              enabled: m.tubeOn,
              format: (v) => (v * 100).toStringAsFixed(0),
              onChanged: m.setTubeMix,
              onChangedEnd: m.setTubeMix,
            ),
            const SizedBox(height: AuraSpace.md),
            // 输出级外框（自动增益补偿与输出增益门）
            OutputGainFrame(
              child: Column(
                children: [
                  _AutoGainRow(
                    label: l.autoGainCompensation,
                    tooltip: l.autoGainCompensationTooltip,
                    value: m.tubeAutoGain,
                    enabled: m.tubeOn,
                    onChanged: m.setTubeAutoGain,
                  ),
                  const SizedBox(height: AuraSpace.xs),
                  ValueSlider(
                    label: l.outputGainGate,
                    infoMessage: l.outputGainGateTooltip,
                    value: m.tubeOutputGain,
                    defaultValue: ParamDefaults.tubeOutputGain,
                    onResetToDefault: () =>
                        m.setTubeOutputGain(ParamDefaults.tubeOutputGain),
                    min: -12.0,
                    max: 6.0,
                    unit: 'dB',
                    enabled: m.tubeOn,
                    format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
                    onChanged: m.setTubeOutputGain,
                    onChangedEnd: m.setTubeOutputGain,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _PostCard extends StatelessWidget {
  final AppModel model;
  const _PostCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return SectionCard(
      index: '14',
      title: l.postGain,
      latencyMs: model.componentLatency('post').ms,
              latencyMeasured: model.componentLatency('post').measured,
              latencyProbing: model.isProbingLatency('post'),
      onRefreshLatency: () => model.refreshComponentLatency('post'),
      latencyTick: model.getComponentLatencyTick('post'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ValueSlider(
            label: l.postGain,
            infoMessage: '全局总输出音量补偿。多重 DSP 处理后若音量偏小可适当微调。',
            value: model.postGain,
            defaultValue: ParamDefaults.postGain,
            onResetToDefault: () =>
                model.setFloat('post.gain', ParamDefaults.postGain),
            min: -15,
            max: 15,
            unit: 'dB',
            format: (v) => (v >= 0 ? '+' : '') + v.toStringAsFixed(1),
            onChanged: (v) => model.setFloat('post.gain', v),
            onChangedEnd: (v) => model.setFloat('post.gain', v),
          ),
          const SizedBox(height: AuraSpace.md),
          Container(height: 1, color: paletteOf(context).hairline),
          const SizedBox(height: AuraSpace.md),
          SectionTitle(
            l.limiter,
            trailing: AuraSwitch(
              value: model.limiterOn,
              onChanged: (v) => model.setInt('limiter.enable', v ? 1 : 0),
            ),
          ),
        ],
      ),
    );
  }
}

/* ---- 参数滑块 ---- */

class ValueSlider extends StatefulWidget {
  final String label;
  final double value;
  final double defaultValue;
  final double min, max;
  final String unit;
  final bool enabled;
  final String Function(double)? format;
  final ValueChanged<double> onChanged;
  final ValueChanged<double>? onChangedEnd;
  final VoidCallback? onResetToDefault;
  final bool overridden;
  final String? overriddenNote;

  /// 标签旁问号徽标的说明文案（null 不渲染；用于替代滑块下方常驻 hint 行）
  final String? infoMessage;

  const ValueSlider({
    super.key,
    required this.label,
    required this.value,
    required this.defaultValue,
    required this.min,
    required this.max,
    required this.unit,
    required this.onChanged,
    this.onChangedEnd,
    this.onResetToDefault,
    this.enabled = true,
    this.format,
    this.overridden = false,
    this.overriddenNote,
    this.infoMessage,
  });

  @override
  State<ValueSlider> createState() => _ValueSliderState();
}

class _ValueSliderState extends State<ValueSlider> {
  double? _dragging;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final displayed = _dragging ?? widget.value;
    final fmt = widget.format ?? (v) => v.toStringAsFixed(1);
    final isCustom = (widget.value - widget.defaultValue).abs() > 1e-4;

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AuraSpace.xxs),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 140,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Flexible(
                      child: Text(
                        widget.label,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: labelOf(p,
                            color: widget.enabled ? p.text : p.textDim),
                      ),
                    ),
                    if (widget.infoMessage != null) ...[
                      const SizedBox(width: AuraSpace.xxs),
                      InfoBadge(message: widget.infoMessage!),
                    ],
                  ],
                ),
              ),
              Expanded(
                child: Slider(
                  value: displayed.clamp(widget.min, widget.max),
                  min: widget.min,
                  max: widget.max,
                  onChanged: widget.enabled
                      ? (v) {
                          setState(() => _dragging = v);
                          widget.onChanged(v);
                        }
                      : null,
                  onChangeEnd: widget.enabled
                      ? (v) {
                          setState(() => _dragging = null);
                          widget.onChangedEnd?.call(v);
                        }
                      : null,
                ),
              ),
              const SizedBox(width: AuraSpace.sm),
              SizedBox(
                width: 60,
                child: Text(
                  '${fmt(displayed)} ${widget.unit}',
                  textAlign: TextAlign.right,
                  style: monoOf(p,
                      size: 12,
                      color: widget.enabled ? p.text : p.textDim),
                ),
              ),
              if (widget.onResetToDefault != null) ...[
                const SizedBox(width: AuraSpace.xs),
                Tooltip(
                  message: l10nOf(context).sliderResetTip,
                  child: InkWell(
                    onTap: widget.onResetToDefault,
                    borderRadius: BorderRadius.circular(AuraRadius.xs),
                    child: Padding(
                      padding: const EdgeInsets.all(4.0),
                      child: Icon(
                        Icons.refresh_rounded,
                        size: 14,
                        color: isCustom ? p.accent : p.textDim.withValues(alpha: 0.3),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
          if (widget.overridden && widget.overriddenNote != null)
            Padding(
              padding: const EdgeInsets.only(left: 140),
              child: Text(
                widget.overriddenNote!,
                style: captionOf(p, color: p.warning),
              ),
            ),
        ],
      ),
    );
  }
}

/* ---- 预设快照卡片 ---- */

class _PresetCard extends StatefulWidget {
  final AppModel model;
  const _PresetCard({required this.model});

  @override
  State<_PresetCard> createState() => _PresetCardState();
}

class _PresetCardState extends State<_PresetCard> {
  final _saveNameCtrl = TextEditingController();
  List<AuraPreset> _presets = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _saveNameCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _presets = PresetLibrary.listAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final m = widget.model;

    final factoryPresets = _presets.where((p) => p.isFactory).toList();
    final userPresets = _presets.where((p) => !p.isFactory).toList();

    return SectionCard(
      title: l.presetTitle,
      hint: l.presetHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 出厂预设
          if (factoryPresets.isNotEmpty) ...[
            Row(
              children: [
                Icon(Icons.stars_rounded, size: 14, color: p.accent),
                const SizedBox(width: 4),
                Text(l.presetFactoryTitle,
                    style: monoOf(p, size: 11, color: p.accent)),
              ],
            ),
            const SizedBox(height: AuraSpace.xs),
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              children: [
                for (final item in factoryPresets)
                  AuraChip(
                    item.name,
                    icon: Icons.music_note_rounded,
                    selected: m.activePresetName == item.name,
                    onTap: () {
                      m.loadPreset(item);
                      _reload();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(l.presetLoadedFactory(item.name)),
                          duration: const Duration(milliseconds: 1400),
                        ));
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: AuraSpace.md),
          ],

          // 用户自建预设
          Row(
            children: [
              Icon(Icons.folder_shared_rounded, size: 14, color: p.accent2),
              const SizedBox(width: 4),
              Text(l.presetUserTitle,
                  style: monoOf(p, size: 11, color: p.accent2)),
            ],
          ),
          const SizedBox(height: AuraSpace.xs),
          if (userPresets.isEmpty)
            Text(l.presetUserEmpty,
                style: captionOf(p, color: p.textDim))
          else
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              children: [
                for (final item in userPresets)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AuraChip(
                        item.name,
                        icon: Icons.bookmark_border_rounded,
                        selected: m.activePresetName == item.name,
                        onTap: () {
                          m.loadPreset(item);
                          _reload();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(l.presetLoadedUser(item.name)),
                              duration: const Duration(milliseconds: 1400),
                            ));
                          }
                        },
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        onTap: () {
                          PresetLibrary.deletePreset(item);
                          _reload();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(l.presetDeleted),
                              duration: const Duration(milliseconds: 1200),
                            ));
                          }
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded,
                              size: 13, color: p.textDim),
                        ),
                      ),
                      const SizedBox(width: AuraSpace.xs),
                    ],
                  ),
              ],
            ),

          const SizedBox(height: AuraSpace.md),
          // 保存栏
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _saveNameCtrl,
                  decoration: InputDecoration(
                    hintText: l.presetSaveHint,
                    hintStyle: captionOf(p),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.md, vertical: AuraSpace.sm),
                    filled: true,
                    fillColor: p.panelRaised,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      borderSide: BorderSide(color: p.hairline),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AuraSpace.sm),
              AuraChip(
                l.presetSave,
                icon: Icons.save_alt_rounded,
                selected: true,
                onTap: () {
                  final name = _saveNameCtrl.text.trim();
                  if (name.isEmpty) return;
                  final ok = m.saveAsUserPreset(name);
                  if (ok) _saveNameCtrl.clear();
                  _reload();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok ? l.presetSaved : l.presetSaveFail),
                      duration: const Duration(milliseconds: 1400),
                    ));
                  }
                },
              ),
            ],
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
              Text('脉冲响应包络',
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
                  Text(isMono ? 'R (镜像)' : 'R', style: monoOf(p, size: 10, color: p.textDim)),
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

  @override
  bool shouldRepaint(covariant _Freeverb3DPainter oldDelegate) =>
      oldDelegate.decay != decay ||
      oldDelegate.damp != damp ||
      oldDelegate.roomSize != roomSize ||
      oldDelegate.stereoWidth != stereoWidth ||
      oldDelegate.palette != palette ||
      oldDelegate.active != active;
}
