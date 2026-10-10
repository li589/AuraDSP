/*
 * chain_page.dart — 处理链页（M3.5-c 完整落地）：
 * 1. 处理顺序调整（Element 式拖拽重排 + graph.order 下发）
 * 2. 12 节点 per-stage 双声道实时微型电平表（Mini Stereo Peak Meter）
 * 3. 节点独立旁路开关（Bypass / Enable）双向状态联动
 */
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
import 'widgets.dart';

/// vendor 链序 stage 元数据（与引擎 kAuraStages 对齐）
const List<({String id, String label, bool exposed})> kStages = [
  (id: 'tube', label: '电子管', exposed: true),
  (id: 'comp', label: '压限器', exposed: false),
  (id: 'bass', label: '低音增强', exposed: true),
  (id: 'eq', label: '均衡器', exposed: true),
  (id: 'arbmag', label: '任意响应 EQ', exposed: false),
  (id: 'convolver', label: '脉冲响应', exposed: true),
  (id: 'ddc', label: 'DDC', exposed: false),
  (id: 'liveprog', label: '脚本', exposed: true),
  (id: 'crossfeed', label: '串扰消除', exposed: true),
  (id: 'stereo', label: '声场展宽', exposed: true),
  (id: 'reverb', label: '混响', exposed: true),
  (id: 'output', label: '输出级', exposed: true),
];

const String kDefaultOrder =
    'tube,comp,bass,eq,arbmag,convolver,ddc,liveprog,crossfeed,stereo,reverb,output';

class ChainPage extends StatefulWidget {
  final AppModel model;
  const ChainPage({super.key, required this.model});

  @override
  State<ChainPage> createState() => _ChainPageState();
}

class _ChainPageState extends State<ChainPage> {
  late List<String> _order;
  bool _dirty = false;

  @override
  void initState() {
    super.initState();
    _order = (widget.model.graphOrder ?? kDefaultOrder).split(',');
  }

  void _apply() {
    final order = _order.join(',');
    widget.model.setGraphOrder(order);
    setState(() => _dirty = false);
  }

  void _reset() {
    setState(() {
      _order = kDefaultOrder.split(',');
      _dirty = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: widget.model,
      builder: (context, _) => PageScaffold(
        title: '处理链',
        children: [
          SectionCard(
            title: '处理顺序与状态',
            hint: '拖拽调整信号处理先后（自上而下）；改动后点"应用"。'
                '支持独立旁路/启用单节点；右侧显示每节点实时双声道电平。',
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_dirty)
                Padding(
                  padding: const EdgeInsets.only(right: AuraSpace.sm),
                  child: AuraChip('应用顺序', icon: Icons.check_rounded,
                      onTap: _apply),
                ),
              AuraChip('恢复默认', icon: Icons.restart_alt_rounded, onTap: _reset),
            ]),
            child: SizedBox(
              height: 48.0 * _order.length + 8,
              child: ReorderableListView.builder(
                buildDefaultDragHandles: false,
                itemCount: _order.length,
                onReorder: (oldI, newI) { // ignore: deprecated_member_use
                  setState(() {
                    if (newI > oldI) newI -= 1;
                    final item = _order.removeAt(oldI);
                    _order.insert(newI, item);
                    _dirty = true;
                  });
                },
                proxyDecorator: (child, index, anim) => AnimatedBuilder(
                  animation: anim,
                  builder: (_, c) => Material(
                    color: p.accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AuraRadius.sm),
                    child: c,
                  ),
                  child: child,
                ),
                itemBuilder: (ctx, i) {
                  final id = _order[i];
                  final meta = kStages.firstWhere((s) => s.id == id,
                      orElse: () => (id: id, label: id, exposed: false));
                  final isEnabled = widget.model.isStageEnabled(id);
                  final stageIdx = kStages.indexWhere((s) => s.id == id);

                  return ReorderableDragStartListener(
                    key: ValueKey(id),
                    index: i,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 2),
                      padding: const EdgeInsets.symmetric(
                          horizontal: AuraSpace.md, vertical: AuraSpace.xs + 2),
                      decoration: BoxDecoration(
                        color: isEnabled
                            ? p.panel
                            : p.panel.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(AuraRadius.sm),
                        border: Border.all(
                          color: isEnabled ? p.hairline : p.hairline.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(children: [
                        Icon(Icons.drag_indicator_rounded,
                            size: 16, color: p.textDim),
                        const SizedBox(width: AuraSpace.sm),
                        Container(
                          width: 22,
                          alignment: Alignment.center,
                          child: Text('${i + 1}',
                              style: monoOf(p,
                                  size: 11,
                                  color: isEnabled ? p.accent : p.textDim)),
                        ),
                        const SizedBox(width: AuraSpace.sm + 2),
                        Expanded(
                          child: Text(
                            meta.label,
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isEnabled
                                  ? p.text
                                  : p.textDim.withValues(alpha: 0.8),
                            ),
                          ),
                        ),
                        // 节点旁路 / 启用胶囊
                        if (meta.exposed) ...[
                          _StageBypassPill(
                            isEnabled: isEnabled,
                            onTap: () => widget.model.toggleStage(id),
                          ),
                          const SizedBox(width: AuraSpace.md),
                        ] else ...[
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: p.panelRaised,
                              borderRadius: BorderRadius.circular(AuraRadius.xs),
                              border: Border.all(color: p.hairline),
                            ),
                            child: Text('预留', style: captionOf(p)),
                          ),
                          const SizedBox(width: AuraSpace.md),
                        ],
                        // [M3.5-c] 双声道微型实时电平表
                        _StageStereoMeter(
                          stageIndex: stageIdx,
                          isEnabled: isEnabled,
                          model: widget.model,
                        ),
                        const SizedBox(width: AuraSpace.sm),
                        Icon(Icons.chevron_right_rounded,
                            size: 16,
                            color: p.textDim.withValues(alpha: 0.4)),
                      ]),
                    ),
                  );
                },
              ),
            ),
          ),
          // 信号流参照（处理顺序的可视化，只读）
          SectionCard(
            title: '信号流（当前顺序）',
            child: Wrap(
              spacing: AuraSpace.xs + 2,
              runSpacing: AuraSpace.xs + 2,
              children: [
                for (var i = 0; i < _order.length; i++) ...[
                  if (i > 0)
                    Icon(Icons.arrow_forward_rounded,
                        size: 12, color: p.textDim.withValues(alpha: 0.5)),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.sm, vertical: 3),
                    decoration: BoxDecoration(
                      color: p.panelRaised,
                      borderRadius: BorderRadius.circular(AuraRadius.xs),
                      border: Border.all(color: p.hairline),
                    ),
                    child: Text(_order[i],
                        style: monoOf(p, size: 10, color: p.textDim)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 节点旁路开关交互胶囊
class _StageBypassPill extends StatelessWidget {
  final bool isEnabled;
  final VoidCallback onTap;

  const _StageBypassPill({required this.isEnabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2.5),
        decoration: BoxDecoration(
          color: isEnabled
              ? p.accent.withValues(alpha: 0.12)
              : p.panelRaised,
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          border: Border.all(
            color: isEnabled
                ? p.accent.withValues(alpha: 0.35)
                : p.hairline,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5,
              height: 5,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isEnabled ? p.accent : p.textDim.withValues(alpha: 0.5),
              ),
            ),
            const SizedBox(width: 4),
            Text(
              isEnabled ? '启用' : '旁路',
              style: monoOf(
                p,
                size: 10,
                color: isEnabled ? p.accent : p.textDim,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// [M3.5-c] 双声道微型实时电平表
class _StageStereoMeter extends StatelessWidget {
  final int stageIndex;
  final bool isEnabled;
  final AppModel model;

  const _StageStereoMeter({
    required this.stageIndex,
    required this.isEnabled,
    required this.model,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([model.stageLevelsL, model.stageLevelsR]),
      builder: (ctx, _) {
        final levelsL = model.stageLevelsL.value;
        final levelsR = model.stageLevelsR.value;
        final dbL = (stageIndex >= 0 && stageIndex < levelsL.length)
            ? levelsL[stageIndex]
            : -120.0;
        final dbR = (stageIndex >= 0 && stageIndex < levelsR.length)
            ? levelsR[stageIndex]
            : -120.0;

        return CustomPaint(
          size: const Size(64, 12),
          painter: _MeterPainter(
            dbL: dbL,
            dbR: dbR,
            isEnabled: isEnabled,
            palette: p,
          ),
        );
      },
    );
  }
}

class _MeterPainter extends CustomPainter {
  final double dbL;
  final double dbR;
  final bool isEnabled;
  final AuraPalette palette;

  _MeterPainter({
    required this.dbL,
    required this.dbR,
    required this.isEnabled,
    required this.palette,
  });

  static double _norm(double db) {
    if (db <= -60.0) return 0.0;
    if (db >= 0.0) return 1.0;
    return (db + 60.0) / 60.0;
  }

  Color _colorFor(double frac) {
    if (!isEnabled) return palette.textDim.withValues(alpha: 0.3);
    if (frac >= 0.95) return palette.error;
    if (frac >= 0.85) return palette.warning;
    return palette.accent;
  }

  @override
  void paint(Canvas canvas, Size size) {
    final trackPaint = Paint()
      ..color = palette.hairline.withValues(alpha: 0.5)
      ..style = PaintingStyle.fill;

    final barH = (size.height - 2) / 2;

    // L 声道底槽与填充
    final rL = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, 0, size.width, barH), const Radius.circular(1.5));
    canvas.drawRRect(rL, trackPaint);

    final fL = _norm(dbL);
    if (fL > 0) {
      final fillL = RRect.fromRectAndRadius(
          Rect.fromLTWH(0, 0, size.width * fL, barH), const Radius.circular(1.5));
      canvas.drawRRect(fillL, Paint()..color = _colorFor(fL));
    }

    // R 声道底槽与填充
    final topR = barH + 2;
    final rR = RRect.fromRectAndRadius(
        Rect.fromLTWH(0, topR, size.width, barH), const Radius.circular(1.5));
    canvas.drawRRect(rR, trackPaint);

    final fR = _norm(dbR);
    if (fR > 0) {
      final fillR = RRect.fromRectAndRadius(
          Rect.fromLTWH(0, topR, size.width * fR, barH), const Radius.circular(1.5));
      canvas.drawRRect(fillR, Paint()..color = _colorFor(fR));
    }
  }

  @override
  bool shouldRepaint(covariant _MeterPainter old) =>
      old.dbL != dbL || old.dbR != dbR || old.isEnabled != isEnabled;
}
