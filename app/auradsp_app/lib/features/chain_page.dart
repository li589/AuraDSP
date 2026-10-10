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
          // M1 第三方插件插槽状态与处理链插入阶段调整
          SectionCard(
            title: '第三方 VST / CLAP 插件挂载槽与阶段处理顺序',
            hint: '支持多插槽并行挂载；可在下方为每个插件单独设定在全局音频链上的插入阶段与处理先后。',
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
              Text('全局信号流顺序示意 (自左至右)：',
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
                stageNode(-1, '低频搁架 EQ', isCore: true),
                _flowArrow(p),
                stageNode(PluginInsertStage.preVendor, 'Stage 1 (Pre-Vendor)'),
                _flowArrow(p),
                stageNode(-2, '12级内部 DSP 链路', isCore: true),
                _flowArrow(p),
                stageNode(PluginInsertStage.postVendor, 'Stage 2 (Post-Vendor)'),
                _flowArrow(p),
                stageNode(-3, '混响与声场', isCore: true),
                _flowArrow(p),
                stageNode(PluginInsertStage.postReverb, 'Stage 3 (Post-Reverb)'),
                _flowArrow(p),
                stageNode(-4, '主限幅 Limiter', isCore: true),
                _flowArrow(p),
                stageNode(PluginInsertStage.postLimiter, 'Stage 4 (Post-Limiter)'),
                _flowArrow(p),
                stageNode(-5, '音频输出', isCore: true),
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
                          ? '插槽 ${slot + 1}：${active!.name} (${active.format.label})'
                          : '插槽 ${slot + 1}：未挂载插件',
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
                      ? '状态：${isBypassed ? "已旁路 (直通)" : "正在处理"} • 延迟：${manager.getSlotLatency(slot)} 采样'
                      : '可在“插件”页面选择效果器加载至本插槽',
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
              tooltip: '打开原生界面 (GUI)',
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              onPressed: () => manager.showEditor(slot: slot),
              visualDensity: VisualDensity.compact,
            ),
            const SizedBox(width: AuraSpace.xs),
            // 旁路开关
            AuraChip(
              isBypassed ? '已旁路' : '生效中',
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
