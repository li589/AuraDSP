/*
 * chain_page.dart — 处理链页（M3.5-c 完整落地）：
 * 1. 处理顺序调整（Element 式拖拽重排 + graph.order 下发）
 * 2. 12 节点 per-stage 双声道实时微型电平表（Mini Stereo Peak Meter）
 * 3. 节点独立旁路开关（Bypass / Enable）双向状态联动
 */
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/plugin_manager.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
import '../l10n/gen/app_localizations.dart';
import 'widgets.dart';

/// vendor 链序 stage 元数据（与引擎 kAuraStages 对齐）
/// id 与是否对外暴露是常量；展示名走 l10n（st*），随语言切换。
const List<({String id, bool exposed})> kStageMeta = [
  (id: 'tube', exposed: true),
  (id: 'comp', exposed: false),
  (id: 'bass', exposed: true),
  (id: 'eq', exposed: true),
  (id: 'arbmag', exposed: false),
  (id: 'convolver', exposed: true),
  (id: 'ddc', exposed: false),
  (id: 'liveprog', exposed: true),
  (id: 'crossfeed', exposed: true),
  (id: 'stereo', exposed: true),
  (id: 'reverb', exposed: true),
  (id: 'output', exposed: true),
];

/// stage id → 展示名（l10n；未知 id 回退原文）。
String stageLabelOf(AppLocalizations l, String id) => switch (id) {
      'tube' => l.stTube,
      'comp' => l.stComp,
      'bass' => l.stBass,
      'eq' => l.stEq,
      'arbmag' => l.stArbmag,
      'convolver' => l.stConv,
      'liveprog' => l.stScript,
      'crossfeed' => l.stXfeed,
      'stereo' => l.stStereo,
      'reverb' => l.stReverb,
      'output' => l.stOutput,
      _ => id,
    };

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
        title: l10nOf(context).chainTitle,
        children: [
          SectionCard(
            title: l10nOf(context).chainOrderTitle,
            hint: l10nOf(context).chainOrderHint,
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (_dirty)
                Padding(
                  padding: const EdgeInsets.only(right: AuraSpace.sm),
                  child: AuraChip(l10nOf(context).chainApply, icon: Icons.check_rounded,
                      onTap: _apply),
                ),
              AuraChip(l10nOf(context).chainReset, icon: Icons.restart_alt_rounded, onTap: _reset),
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
                  final meta = kStageMeta.firstWhere((s) => s.id == id,
                      orElse: () => (id: id, exposed: false));
                  final isEnabled = widget.model.isStageEnabled(id);
                  final stageIdx = kStageMeta.indexWhere((s) => s.id == id);

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
                            stageLabelOf(l10nOf(ctx), id),
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
                            child: Text(l10nOf(context).chainReserved, style: captionOf(p)),
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
            title: l10nOf(context).chainFlowTitle,
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
          // M1 第三方插件插槽状态与处理链插入阶段调整
          SectionCard(
            title: l10nOf(context).chainVstTitle,
            hint: l10nOf(context).chainVstHint,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 1. 全局音效链路阶段拓扑流示意
                _PluginStageTopologyView(manager: widget.model.pluginManager),
                const SizedBox(height: AuraSpace.md),

                // 2. 双插槽独立控制卡片列表
                for (var s = 0; s < PluginManager.kMaxSlots; s++) ...[
                  _PluginSlotChainCard(
                    model: widget.model,
                    slot: s,
                  ),
                  if (s < PluginManager.kMaxSlots - 1)
                    const SizedBox(height: AuraSpace.sm),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// 全局音效链路阶段拓扑流示意组件
class _PluginStageTopologyView extends StatelessWidget {
  final PluginManager manager;
  const _PluginStageTopologyView({required this.manager});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    Widget stageNode(int stage, String name, {bool isCore = false}) {
      final activeSlots = <int>[];
      for (var s = 0; s < PluginManager.kMaxSlots; s++) {
        if (manager.isSlotActive(s) && manager.getSlotStage(s) == stage) {
          activeSlots.add(s);
        }
      }
      final hasActivePlugin = activeSlots.isNotEmpty;

      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: hasActivePlugin
              ? p.accent.withValues(alpha: 0.15)
              : (isCore ? p.panelRaised : p.panel),
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          border: Border.all(
            color: hasActivePlugin
                ? p.accent
                : (isCore ? p.hairline : p.hairline.withValues(alpha: 0.6)),
            width: hasActivePlugin ? 1.5 : 1.0,
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              name,
              style: TextStyle(
                fontSize: 10,
                fontWeight: isCore ? FontWeight.bold : FontWeight.w500,
                color: hasActivePlugin ? p.accent : p.text,
              ),
            ),
            if (hasActivePlugin) ...[
              const SizedBox(height: 2),
              Wrap(
                spacing: 2,
                children: activeSlots.map((s) {
                  final meta = manager.getSlotPlugin(s);
                  return Container(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                    decoration: BoxDecoration(
                      color: p.accent,
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      'S${s + 1}:${meta?.name ?? ""}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                        color: p.accentContrast,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      );
    }

    return Container(
      padding: const EdgeInsets.all(AuraSpace.sm + 2),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.timeline_rounded, size: 14, color: p.accent),
              const SizedBox(width: 4),
              Text(l10nOf(context).chainFlowCaption,
                  style: monoOf(p, size: 10.5, color: p.textDim)),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                stageNode(PluginInsertStage.preDsp, 'Stage 0 (Pre-DSP)'),
                _flowArrow(p),
                stageNode(-1, l10nOf(context).chainNodeShelf, isCore: true),
                _flowArrow(p),
                stageNode(PluginInsertStage.preVendor, 'Stage 1 (Pre-Vendor)'),
                _flowArrow(p),
                stageNode(-2, l10nOf(context).chainNodeVendor, isCore: true),
                _flowArrow(p),
                stageNode(PluginInsertStage.postVendor, 'Stage 2 (Post-Vendor)'),
                _flowArrow(p),
                stageNode(-3, l10nOf(context).chainNodeReverb, isCore: true),
                _flowArrow(p),
                stageNode(PluginInsertStage.postReverb, 'Stage 3 (Post-Reverb)'),
                _flowArrow(p),
                stageNode(-4, l10nOf(context).chainNodeLimiter, isCore: true),
                _flowArrow(p),
                stageNode(PluginInsertStage.postLimiter, 'Stage 4 (Post-Limiter)'),
                _flowArrow(p),
                stageNode(-5, l10nOf(context).chainNodeOutput, isCore: true),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static Widget _flowArrow(AuraPalette p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Icon(Icons.arrow_forward_rounded,
          size: 11, color: p.textDim.withValues(alpha: 0.5)),
    );
  }
}

/// 插槽独立处理链调整卡片
class _PluginSlotChainCard extends StatelessWidget {
  final AppModel model;
  final int slot;

  const _PluginSlotChainCard({
    required this.model,
    required this.slot,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final manager = model.pluginManager;
    final isActive = manager.isSlotActive(slot);
    final active = manager.getSlotPlugin(slot);
    final isBypassed = manager.isSlotBypassed(slot);
    final currentStage = manager.getSlotStage(slot);

    return Container(
      padding: const EdgeInsets.all(AuraSpace.md),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: isActive
              ? (isBypassed ? p.warning.withValues(alpha: 0.4) : p.accent.withValues(alpha: 0.4))
              : p.hairline,
        ),
      ),
      child: Row(
        children: [
          // 插槽徽章
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: isActive ? p.accent.withValues(alpha: 0.15) : p.panelRaised,
              shape: BoxShape.circle,
              border: Border.all(color: isActive ? p.accent : p.hairline),
            ),
            alignment: Alignment.center,
            child: Text(
              '${slot + 1}',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: isActive ? p.accent : p.textDim,
              ),
            ),
          ),
          const SizedBox(width: AuraSpace.md),

          // 插件详情
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      isActive
                          ? l10nOf(context).chainSlotActive(slot + 1, active!.name, active.format.label)
                          : l10nOf(context).chainSlotEmpty(slot + 1),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.bold,
                        color: p.text,
                      ),
                    ),
                    if (isActive && active != null) ...[
                      const SizedBox(width: AuraSpace.sm),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                        decoration: BoxDecoration(
                          color: p.hairline,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Text(
                          active.format.label,
                          style: monoOf(p, size: 9.5, color: p.textDim),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  isActive
                      ? l10nOf(context).chainSlotStatusLine(
                          isBypassed ? l10nOf(context).chainSlotBypassed : l10nOf(context).chainSlotProcessing,
                          manager.getSlotLatency(slot))
                      : l10nOf(context).chainSlotHint,
                  style: captionOf(p, color: p.textDim),
                ),
              ],
            ),
          ),

          // 插入阶段选择器
          if (isActive) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: p.panelRaised,
                borderRadius: BorderRadius.circular(AuraRadius.sm),
                border: Border.all(color: p.hairline),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<int>(
                  value: currentStage,
                  isDense: true,
                  dropdownColor: p.panelRaised,
                  style: labelOf(p),
                  icon: Icon(Icons.arrow_drop_down_rounded, color: p.accent),
                  items: const [
                    PluginInsertStage.preDsp,
                    PluginInsertStage.preVendor,
                    PluginInsertStage.postVendor,
                    PluginInsertStage.postReverb,
                    PluginInsertStage.postLimiter,
                  ].map<DropdownMenuItem<int>>((stg) {
                    return DropdownMenuItem<int>(
                      value: stg,
                      child: Text(
                        PluginInsertStage.labelOf(stg),
                        style: TextStyle(
                          fontSize: 12,
                          color: stg == currentStage ? p.accent : p.text,
                          fontWeight: stg == currentStage
                              ? FontWeight.bold
                              : FontWeight.normal,
                        ),
                      ),
                    );
                  }).toList(),
                  onChanged: (val) {
                    if (val != null) {
                      manager.setInsertStage(val, slot: slot);
                    }
                  },
                ),
              ),
            ),
            const SizedBox(width: AuraSpace.sm),
            // GUI 打开按钮
            IconButton(
              tooltip: l10nOf(context).chainOpenGui,
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              onPressed: () => manager.showEditor(slot: slot),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: AuraSpace.xs),
            // 旁路开关
            AuraChip(
              isBypassed ? l10nOf(context).chainBypassed : l10nOf(context).chainActive,
              selected: !isBypassed,
              danger: isBypassed,
              onTap: () => manager.toggleBypass(slot: slot),
            ),
          ],
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
              isEnabled ? l10nOf(context).chainEnable : l10nOf(context).chainBypass,
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
