// part of effects_page.dart —— “空间音效” mega 卡（P3）。
// hero：风格三预设 + 虚拟扬声器摆位图（随 width 张开）+ 早期反射 tap 图
// （随 room 拉伸）；空间核心展开；混响 / 脉冲 / 声场（crossfeed+haas）/
// 立体声折叠搬入。引擎 / 参数 / 预设 / 回放全部不动，纯 UI 搬家。
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
      hint: l.spatialHint,
      collapsed: !model.spatialOn,
      latencyMs: model.componentLatency('spatial').ms,
      latencyMeasured: model.componentLatency('spatial').measured,
      latencyEstimated: model.componentLatency('spatial').estimated,
      latencyProbing: model.isProbingLatency('spatial'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('spatial')
          ? () => model.refreshComponentLatency('spatial')
          : null,
      latencyTick: model.getComponentLatencyTick('spatial'),
      trailing: AuraSwitch(
        value: model.spatialOn,
        onChanged: model.setSpatialEnabled,
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
              Wrap(
                spacing: AuraSpace.sm,
                children: [
                  AuraChoiceChip(
                    label: l.spatialStyleDolby,
                    selected: model.spatialStyle == 0,
                    onTap: model.spatialOn
                        ? () => model.setSpatialStyle(0)
                        : null,
                  ),
                  AuraChoiceChip(
                    label: l.spatialStyleDts,
                    selected: model.spatialStyle == 1,
                    onTap: model.spatialOn
                        ? () => model.setSpatialStyle(1)
                        : null,
                  ),
                  AuraChoiceChip(
                    label: l.spatialStyleNeutral,
                    selected: model.spatialStyle == 2,
                    onTap: model.spatialOn
                        ? () => model.setSpatialStyle(2)
                        : null,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          // hero：摆位图 + 反射 tap 图（数据驱动，随 width/room 实时变化）
          _SpatialStageView(
            width: model.spatialWidth,
            room: model.spatialRoom,
            accent: p.accent,
            dim: p.textDim,
            hairline: p.hairline,
          ),
          const SizedBox(height: AuraSpace.sm),
          // 空间核心（展开）
          ValueSlider(
            label: l.spatialRoom,
            infoMessage: l.spatialRoomInfo,
            value: model.spatialRoom,
            defaultValue: ParamDefaults.spatialRoom,
            onResetToDefault: () =>
                model.setSpatialRoom(ParamDefaults.spatialRoom),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.spatialOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setSpatialRoom,
            onChangedEnd: model.setSpatialRoom,
          ),
          const SizedBox(height: AuraSpace.sm),
          ValueSlider(
            label: l.spatialWidth,
            infoMessage: l.spatialWidthInfo,
            value: model.spatialWidth,
            defaultValue: ParamDefaults.spatialWidth,
            onResetToDefault: () =>
                model.setSpatialWidth(ParamDefaults.spatialWidth),
            min: 0.5,
            max: 1.5,
            unit: '×',
            enabled: model.spatialOn,
            format: (v) => v.toStringAsFixed(2),
            onChanged: model.setSpatialWidth,
            onChangedEnd: model.setSpatialWidth,
          ),
          const SizedBox(height: AuraSpace.sm),
          ValueSlider(
            label: l.spatialCenter,
            infoMessage: l.spatialCenterInfo,
            value: model.spatialCenter,
            defaultValue: ParamDefaults.spatialCenter,
            onResetToDefault: () =>
                model.setSpatialCenter(ParamDefaults.spatialCenter),
            min: 0,
            max: 1,
            unit: '%',
            enabled: model.spatialOn,
            format: (v) => (v * 100).toStringAsFixed(0),
            onChanged: model.setSpatialCenter,
            onChangedEnd: model.setSpatialCenter,
          ),
          const SizedBox(height: AuraSpace.sm),
          ValueSlider(
            label: l.spatialOutGain,
            infoMessage: l.spatialOutGainInfo,
            value: model.spatialOutGain,
            defaultValue: ParamDefaults.spatialOutGain,
            onResetToDefault: () =>
                model.setSpatialOutGain(ParamDefaults.spatialOutGain),
            min: -12,
            max: 6,
            unit: 'dB',
            enabled: model.spatialOn,
            format: (v) =>
                '${v >= 0 ? "+" : ""}${v.toStringAsFixed(1)}',
            onChanged: model.setSpatialOutGain,
            onChangedEnd: model.setSpatialOutGain,
          ),
          const SizedBox(height: AuraSpace.sm),
          Row(
            children: [
              Text(l.spatialAutoGain, style: labelOf(p, color: p.text)),
              const SizedBox(width: 4),
              InfoBadge(message: l.spatialAutoGainInfo),
              const Spacer(),
              AuraSwitch(
                value: model.spatialAutoGain,
                onChanged: model.spatialOn
                    ? model.setSpatialAutoGain
                    : null,
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

/// 虚拟 5.0 摆位 + 早期反射 tap 示意（纯展示，不接受输入）。
/// 上半：人头圆 + 5 扬声器点（方位 = 引擎 kSpatDeg × width，±160° 钳位同引擎）；
/// 下半：8 tap（时间 = kSpatTapMs × tscale，tscale = 0.5+1.5×room 同引擎），
/// 偶 tap 朝上（L）奇 tap 朝下（R），高度 ∝ |增益|。
class _SpatialStageView extends StatelessWidget {
  final double width;
  final double room;
  final Color accent;
  final Color dim;
  final Color hairline;
  const _SpatialStageView({
    required this.width,
    required this.room,
    required this.accent,
    required this.dim,
    required this.hairline,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      size: const Size(double.infinity, 132),
      painter: _SpatialStagePainter(
        width: width,
        room: room,
        accent: accent,
        dim: dim,
        hairline: hairline,
      ),
    );
  }
}

class _SpatialStagePainter extends CustomPainter {
  static const _degs = [-30.0, 0.0, 30.0, -110.0, 110.0];
  static const _tapMs = [5.5, 9.0, 14.0, 21.0, 30.0, 42.0, 55.0, 68.0];
  static const _tapG = [0.25, 0.25, 0.18, 0.18, 0.12, 0.12, 0.07, 0.07];

  final double width;
  final double room;
  final Color accent;
  final Color dim;
  final Color hairline;
  const _SpatialStagePainter({
    required this.width,
    required this.room,
    required this.accent,
    required this.dim,
    required this.hairline,
  });

  @override
  void paint(Canvas canvas, Size size) {
    // 上半：摆位图
    final cx = size.width / 2;
    const cy = 40.0;
    const r = 30.0;
    canvas.drawCircle(
      Offset(cx, cy),
      7.0,
      Paint()..color = dim
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
    final dot = Paint()..color = accent;
    for (final d in _degs) {
      var deg = d * width;
      if (deg < -160.0) deg = -160.0;
      if (deg > 160.0) deg = 160.0;
      final rad = deg * math.pi / 180.0;
      canvas.drawCircle(
        Offset(cx + r * math.sin(rad), cy - r * math.cos(rad)),
        3.5,
        dot,
      );
    }
    // 下半：反射 tap 图（基线 + 8 刻度）
    const baseY = 108.0;
    canvas.drawLine(
      Offset(8, baseY),
      Offset(size.width - 8, baseY),
      Paint()..color = hairline
        ..strokeWidth = 1.0,
    );
    final tscale = 0.5 + 1.5 * room;
    const maxMs = 68.0 * 2.0; // tscale 上限 2.0
    final tick = Paint()
      ..color = accent
      ..strokeWidth = 2.0
      ..strokeCap = StrokeCap.round;
    for (var t = 0; t < 8; ++t) {
      final x = 8 +
          (size.width - 16) * (_tapMs[t] * tscale / maxMs);
      final h = 4.0 + 20.0 * (_tapG[t] / 0.25);
      final dir = (t & 1) == 0 ? -1.0 : 1.0; // 偶→L 朝上，奇→R 朝下
      canvas.drawLine(Offset(x, baseY), Offset(x, baseY + dir * h), tick);
    }
  }

  @override
  bool shouldRepaint(_SpatialStagePainter old) =>
      old.width != width || old.room != room;
}
