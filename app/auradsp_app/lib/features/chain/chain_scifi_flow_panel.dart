/*
 * chain_scifi_flow_panel.dart — 全局信号流顺序科幻全景面板组件
 * 1. 触发条重构：左侧大号标题与节点拓扑摘要，右侧科幻发光“显示”按钮
 * 2. 科幻展开特效：半透明毛玻璃 HUD 覆盖层覆盖于“处理顺序与状态”区域
 * 3. 动态电路装饰背景：PCB 铜箔走线、焊盘过孔、流光脉冲粒子动画
 * 4. 实时插件物理位置嵌入：精准展示 Stage 0~4 (Pre-DSP, Pre-Vendor, Post-Vendor, Post-Reverb, Post-Limiter) 插件芯片节点
 * 5. 重绘科技感能量流光箭头（替代廉价单线箭头）
 * 6. 交互手势支持：基于 InteractiveViewer 的鼠标拖拽平移、滚轮缩放、触屏移动与一键 100% 视角复位
 */

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/plugins/plugin_manager.dart';
import '../../core/plugins/plugin_models.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../core/ui_helpers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../chain_page.dart' show stageLabelOf;

/// 科幻全局信号流全景触发条与覆盖面板
class ChainScifiFlowPanel extends StatefulWidget {
  final List<String> order;
  final AppModel model;

  const ChainScifiFlowPanel({
    super.key,
    required this.order,
    required this.model,
  });

  @override
  State<ChainScifiFlowPanel> createState() => _ChainScifiFlowPanelState();
}

class _ChainScifiFlowPanelState extends State<ChainScifiFlowPanel>
    with TickerProviderStateMixin {
  bool _isExpanded = false;
  late final AnimationController _expandCtrl;
  late final Animation<double> _expandAnim;
  late final AnimationController _circuitPulseCtrl;
  final TransformationController _transCtrl = TransformationController();

  @override
  void initState() {
    super.initState();
    _expandCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _expandAnim = CurvedAnimation(
      parent: _expandCtrl,
      curve: Curves.easeOutCubic,
    );

    // 电路板能量流光脉冲动画（展开时驱动）
    _circuitPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    );
  }

  @override
  void dispose() {
    _expandCtrl.dispose();
    _circuitPulseCtrl.dispose();
    _transCtrl.dispose();
    super.dispose();
  }

  void _toggleExpand() {
    setState(() {
      _isExpanded = !_isExpanded;
      if (_isExpanded) {
        _expandCtrl.forward();
        _circuitPulseCtrl.repeat();
      } else {
        _expandCtrl.reverse();
        _circuitPulseCtrl.stop();
      }
    });
  }

  void _resetZoom() {
    _transCtrl.value = Matrix4.identity();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    // 统计节点状态
    var activeCount = 2; // 输入门控 + 输出门控
    var bypassedCount = 0;
    if (widget.model.limiterOn) {
      activeCount++;
    } else {
      bypassedCount++;
    }
    for (final id in widget.order) {
      if (widget.model.isStageEnabled(id)) {
        activeCount++;
      } else {
        bypassedCount++;
      }
    }

    var pluginCount = 0;
    final pm = widget.model.pluginManager;
    for (var s = 0; s < PluginManager.kMaxSlots; s++) {
      if (pm.isSlotActive(s)) {
        pluginCount++;
        if (pm.isSlotBypassed(s)) {
          bypassedCount++;
        } else {
          activeCount++;
        }
      }
    }

    return Container(
      decoration: BoxDecoration(
        color: p.panelRaised.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(AuraRadius.md),
        border: Border.all(
          color: _isExpanded ? p.accent.withValues(alpha: 0.6) : p.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. 触发条头部（左侧大号标题与拓扑芯片说明，右侧高科技展开按钮）
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AuraSpace.md,
              vertical: AuraSpace.sm + 2,
            ),
            child: Row(
              children: [
                // 科幻状态霓虹标
                Container(
                  width: 3.5,
                  height: 18,
                  decoration: BoxDecoration(
                    color: p.accent,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(
                        color: p.accent.withValues(alpha: 0.75),
                        blurRadius: 6,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: AuraSpace.sm + 2),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '全局信号流顺序',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: p.text,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '全链路 24 节点拓扑 · 实时 Stage 0~4 插件注入映射 · 支持平移缩放',
                      style: monoOf(p, size: 10.5, color: p.textDim),
                    ),
                  ],
                ),
                const Spacer(),

                // 节点简要统计
                Container(
                  margin: const EdgeInsets.only(right: AuraSpace.sm),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: p.bg.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(AuraRadius.xs),
                    border: Border.all(color: p.hairline.withValues(alpha: 0.5)),
                  ),
                  child: Text(
                    '$activeCount 活跃 · $bypassedCount 旁路 · $pluginCount 插件',
                    style: monoOf(p, size: 10.5, color: p.textDim),
                  ),
                ),

                // 科幻风格“显示 / 展开全景”按钮
                InkWell(
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  onTap: _toggleExpand,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _isExpanded
                          ? p.accent.withValues(alpha: 0.2)
                          : p.accent.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      border: Border.all(
                        color: _isExpanded
                            ? p.accent
                            : p.accent.withValues(alpha: 0.4),
                        width: 1.2,
                      ),
                      boxShadow: _isExpanded
                          ? [
                              BoxShadow(
                                color: p.accent.withValues(alpha: 0.25),
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _isExpanded
                              ? Icons.close_fullscreen_rounded
                              : Icons.account_tree_rounded,
                          size: 15,
                          color: p.accent,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _isExpanded ? '收起面板' : '显示全景',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: p.accent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 2. 科幻展开面板（覆盖于状态层）
          SizeTransition(
            sizeFactor: _expandAnim,
            axisAlignment: -1.0,
            child: FadeTransition(
              opacity: _expandAnim,
              child: Container(
                height: 440,
                decoration: BoxDecoration(
                  color: p.bg.withValues(alpha: 0.94),
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(AuraRadius.md),
                    bottomRight: Radius.circular(AuraRadius.md),
                  ),
                  border: Border(
                    top: BorderSide(color: p.accent.withValues(alpha: 0.4)),
                  ),
                ),
                child: Stack(
                  children: [
                    // A. 底层：动态电路板铜箔走线与能量流光脉冲装饰
                    Positioned.fill(
                      child: AnimatedBuilder(
                        animation: _circuitPulseCtrl,
                        builder: (ctx, _) => CustomPaint(
                          painter: _CircuitBoardPainter(
                            palette: p,
                            pulseProgress: _circuitPulseCtrl.value,
                          ),
                        ),
                      ),
                    ),

                    // B. 中层：可拖拽缩放的信号拓扑流图
                    Positioned.fill(
                      child: InteractiveViewer(
                        transformationController: _transCtrl,
                        boundaryMargin: const EdgeInsets.all(180),
                        minScale: 0.5,
                        maxScale: 2.2,
                        constrained: false,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 60.0,
                            vertical: 50.0,
                          ),
                          child: _buildTopologyContent(context, p, l),
                        ),
                      ),
                    ),

                    // C. 顶层：控制工具栏与 HUD 装饰
                    Positioned(
                      top: 10,
                      left: 14,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: p.panelRaised.withValues(alpha: 0.8),
                          borderRadius: BorderRadius.circular(AuraRadius.xs),
                          border: Border.all(color: p.hairline),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.hub_rounded, size: 13, color: p.accent),
                            const SizedBox(width: 5),
                            Text(
                              'SIGNAL ROUTING TOPOLOGY (PHYSICAL ORDER)',
                              style: monoOf(p, size: 10, color: p.textDim)
                                  .copyWith(fontWeight: FontWeight.w700),
                            ),
                          ],
                        ),
                      ),
                    ),

                    Positioned(
                      top: 10,
                      right: 14,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // 100% 视角复位
                          InkWell(
                            borderRadius: BorderRadius.circular(AuraRadius.xs),
                            onTap: _resetZoom,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: p.panelRaised.withValues(alpha: 0.8),
                                borderRadius: BorderRadius.circular(AuraRadius.xs),
                                border: Border.all(color: p.hairline),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.restart_alt_rounded,
                                      size: 13, color: p.accent),
                                  const SizedBox(width: 4),
                                  Text(
                                    '100% 复位',
                                    style: monoOf(p, size: 10, color: p.accent),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(width: AuraSpace.sm),
                          // 关闭全景
                          IconButton(
                            tooltip: '收起全景面板',
                            icon: Icon(Icons.close_rounded, size: 18, color: p.textDim),
                            onPressed: _toggleExpand,
                            visualDensity: VisualDensity.compact,
                          ),
                        ],
                      ),
                    ),

                    // 底部手势引导提示
                    Positioned(
                      bottom: 8,
                      right: 14,
                      child: Text(
                        '按住鼠标左键或触屏平移 · 滚轮缩放',
                        style: monoOf(p, size: 10, color: p.textDim.withValues(alpha: 0.5)),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// 构建端到端物理拓扑流（精准插入 Stage 0~4 插件）
  Widget _buildTopologyContent(BuildContext context, AuraPalette p, AppLocalizations l) {
    final pm = widget.model.pluginManager;

    // 获取特定 Stage 的激活插件槽位
    List<int> getSlotsForStage(int stage) {
      final list = <int>[];
      for (var s = 0; s < PluginManager.kMaxSlots; s++) {
        if (pm.isSlotActive(s) && pm.getSlotStage(s) == stage) {
          list.add(s);
        }
      }
      return list;
    }

    final items = <Widget>[];

    // 1. 输入门控 (常驻固定)
    items.add(_flowNode(
      p: p,
      label: l.chainNodeInput,
      typeLabel: 'PINNED IN',
      isFixed: true,
      isActive: true,
    ));
    items.add(const _ScifiEnergyArrow());

    // 2. Stage 0: Pre-DSP 插件
    final stage0Slots = getSlotsForStage(PluginInsertStage.preDsp);
    for (final slot in stage0Slots) {
      items.add(_pluginNode(p: p, slot: slot, stageName: 'Pre-DSP'));
      items.add(const _ScifiEnergyArrow());
    }

    // 3. 前置处理节点 (gate, filter, bassmono, shelf)
    const frontStages = {'gate', 'filter', 'bassmono', 'shelf'};
    final frontInOrder = widget.order.where((id) => frontStages.contains(id)).toList();
    for (final id in frontInOrder) {
      items.add(_dspNode(p: p, l: l, id: id));
      items.add(const _ScifiEnergyArrow());
    }

    // 4. Stage 1: Pre-Vendor 插件
    final stage1Slots = getSlotsForStage(PluginInsertStage.preVendor);
    for (final slot in stage1Slots) {
      items.add(_pluginNode(p: p, slot: slot, stageName: 'Pre-Vendor'));
      items.add(const _ScifiEnergyArrow());
    }

    // 5. 中置核心 Vendor 效果器 (除去 frontStages 和后置的 reverb/loudness)
    final midInOrder = widget.order.where((id) =>
        !frontStages.contains(id) && id != 'reverb' && id != 'loudness').toList();
    for (final id in midInOrder) {
      items.add(_dspNode(p: p, l: l, id: id));
      items.add(const _ScifiEnergyArrow());
    }

    // 6. Stage 2: Post-Vendor 插件
    final stage2Slots = getSlotsForStage(PluginInsertStage.postVendor);
    for (final slot in stage2Slots) {
      items.add(_pluginNode(p: p, slot: slot, stageName: 'Post-Vendor'));
      items.add(const _ScifiEnergyArrow());
    }

    // 7. 混响节点 (Reverb)
    if (widget.order.contains('reverb')) {
      items.add(_dspNode(p: p, l: l, id: 'reverb'));
      items.add(const _ScifiEnergyArrow());
    }

    // 8. Stage 3: Post-Reverb 插件 (默认插槽阶段)
    final stage3Slots = getSlotsForStage(PluginInsertStage.postReverb);
    for (final slot in stage3Slots) {
      items.add(_pluginNode(p: p, slot: slot, stageName: 'Post-Reverb'));
      items.add(const _ScifiEnergyArrow());
    }

    // 9. 后置响度补偿 (Loudness)
    if (widget.order.contains('loudness')) {
      items.add(_dspNode(p: p, l: l, id: 'loudness'));
      items.add(const _ScifiEnergyArrow());
    }

    // 10. 输出门控 (Output Gate)
    items.add(_flowNode(
      p: p,
      label: l.chainNodeOutputGate,
      typeLabel: 'GATE OUT',
      isFixed: true,
      isActive: true,
    ));
    items.add(const _ScifiEnergyArrow());

    // 11. 主限幅器 (Limiter)
    items.add(_flowNode(
      p: p,
      label: l.chainNodeLimiter,
      typeLabel: 'LOOKAHEAD',
      isFixed: true,
      isActive: widget.model.limiterOn,
    ));
    items.add(const _ScifiEnergyArrow());

    // 12. Stage 4: Post-Limiter 插件 (总输出级)
    final stage4Slots = getSlotsForStage(PluginInsertStage.postLimiter);
    for (final slot in stage4Slots) {
      items.add(_pluginNode(p: p, slot: slot, stageName: 'Post-Limit'));
      items.add(const _ScifiEnergyArrow());
    }

    // 13. 最终物理音频输出 (Audio Output)
    items.add(_flowNode(
      p: p,
      label: l.chainNodeOutput,
      typeLabel: 'PINNED OUT',
      isFixed: true,
      isActive: true,
    ));

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: items,
    );
  }

  /// 常规核心 DSP 节点
  Widget _dspNode({
    required AuraPalette p,
    required AppLocalizations l,
    required String id,
  }) {
    final label = stageLabelOf(l, id);
    final isEnabled = widget.model.isStageEnabled(id);

    return Container(
      width: 104,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: isEnabled ? p.panel : p.panel.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: isEnabled ? p.hairline : p.hairline.withValues(alpha: 0.4),
          width: 1.0,
        ),
        boxShadow: isEnabled
            ? [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.25),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ]
            : null,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: isEnabled ? p.accent : p.textDim.withValues(alpha: 0.4),
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text(
                  id.toUpperCase(),
                  style: monoOf(p, size: 9, color: p.textDim),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isEnabled ? p.text : p.textDim,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            isEnabled ? 'ACTIVE' : 'BYPASS',
            style: monoOf(
              p,
              size: 8.5,
              color: isEnabled ? p.accent : p.textDim.withValues(alpha: 0.5),
            ),
          ),
        ],
      ),
    );
  }

  /// 插件芯片节点（高科技芯片插槽风格）
  Widget _pluginNode({
    required AuraPalette p,
    required int slot,
    required String stageName,
  }) {
    final pm = widget.model.pluginManager;
    final meta = pm.getSlotPlugin(slot);
    final name = meta?.name ?? 'Slot ${slot + 1}';
    final format = meta?.format.label ?? 'VST';
    final isBypassed = pm.isSlotBypassed(slot);
    final latencySpl = pm.getSlotLatency(slot);

    return Container(
      width: 128,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
      decoration: BoxDecoration(
        color: isBypassed
            ? const Color(0xFF1E2129)
            : const Color(0xFF0F262C), // 科技青墨色
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: isBypassed
              ? Colors.amber.withValues(alpha: 0.5)
              : p.accent.withValues(alpha: 0.8),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: (isBypassed ? Colors.amber : p.accent).withValues(alpha: 0.25),
            blurRadius: 6,
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: isBypassed
                      ? Colors.amber.withValues(alpha: 0.15)
                      : p.accent.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  'SLOT ${slot + 1}',
                  style: monoOf(
                    p,
                    size: 8.5,
                    color: isBypassed ? Colors.amber : p.accent,
                  ).copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
                decoration: BoxDecoration(
                  color: Colors.white10,
                  borderRadius: BorderRadius.circular(2),
                ),
                child: Text(
                  format,
                  style: monoOf(p, size: 8, color: p.textDim),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            name,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w700,
              color: isBypassed ? p.textDim : p.text,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Row(
            children: [
              Text(
                stageName,
                style: monoOf(p, size: 8.5, color: p.textDim),
              ),
              const Spacer(),
              Text(
                isBypassed ? 'BYPASS' : '$latencySpl spl',
                style: monoOf(
                  p,
                  size: 8.5,
                  color: isBypassed ? Colors.amber : p.accent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// 钉死首位/末位固定节点
  Widget _flowNode({
    required AuraPalette p,
    required String label,
    required String typeLabel,
    required bool isFixed,
    required bool isActive,
  }) {
    return Container(
      width: 100,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      decoration: BoxDecoration(
        color: p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: isActive ? p.accent.withValues(alpha: 0.6) : p.hairline,
          width: 1.0,
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            typeLabel,
            style: monoOf(p, size: 8.5, color: isActive ? p.accent : p.textDim)
                .copyWith(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isActive ? p.text : p.textDim,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            isActive ? 'FIXED' : 'OFF',
            style: monoOf(p, size: 8.5, color: p.textDim),
          ),
        ],
      ),
    );
  }
}

/// 科幻能量流光连接箭头
class _ScifiEnergyArrow extends StatelessWidget {
  const _ScifiEnergyArrow();

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4.0),
      child: SizedBox(
        width: 22,
        height: 28,
        child: CustomPaint(
          painter: _EnergyArrowPainter(palette: p),
        ),
      ),
    );
  }
}

class _EnergyArrowPainter extends CustomPainter {
  final AuraPalette palette;
  const _EnergyArrowPainter({required this.palette});

  @override
  void paint(Canvas canvas, Size size) {
    final cy = size.height / 2.0;
    final linePaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.6)
      ..strokeWidth = 1.4;

    // 导引水平中轴线
    canvas.drawLine(Offset(0, cy), Offset(size.width - 6, cy), linePaint);

    // 科技双折角能量箭头 »
    final arrowPaint = Paint()
      ..color = palette.accent
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final path1 = Path()
      ..moveTo(size.width - 10, cy - 5)
      ..lineTo(size.width - 6, cy)
      ..lineTo(size.width - 10, cy + 5);

    final path2 = Path()
      ..moveTo(size.width - 5, cy - 5)
      ..lineTo(size.width - 1, cy)
      ..lineTo(size.width - 5, cy + 5);

    canvas.drawPath(path1, arrowPaint);
    canvas.drawPath(path2, arrowPaint);
  }

  @override
  bool shouldRepaint(covariant _EnergyArrowPainter oldDelegate) =>
      oldDelegate.palette != palette;
}

/// 电路板背景铜箔走线与能量光点脉冲绘制器
class _CircuitBoardPainter extends CustomPainter {
  final AuraPalette palette;
  final double pulseProgress;

  const _CircuitBoardPainter({
    required this.palette,
    required this.pulseProgress,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final tracePaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.08)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final padPaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.15)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final pulsePaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.75)
      ..style = PaintingStyle.fill;

    // 绘制横纵交错 PCB 走线
    final stepY = 32.0;
    final rowCount = (size.height / stepY).ceil();

    for (var r = 0; r < rowCount; r++) {
      final y = r * stepY;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), tracePaint);

      // 45 度折角走线
      if (r % 3 == 0) {
        final path = Path()
          ..moveTo(60.0 * (r % 5), y)
          ..lineTo(60.0 * (r % 5) + 20, y + 20)
          ..lineTo(size.width, y + 20);
        canvas.drawPath(path, tracePaint);
      }

      // 焊盘过孔圆环
      for (var c = 0; c < 8; c++) {
        final x = c * 180.0 + (r * 40.0) % 180.0;
        if (x < size.width) {
          canvas.drawCircle(Offset(x, y), 2.5, padPaint);
          canvas.drawCircle(Offset(x, y), 1.0, pulsePaint);
        }
      }
    }

    // 绘制流动能量粒子
    final particleCount = 12;
    for (var i = 0; i < particleCount; i++) {
      final t = (pulseProgress + i / particleCount) % 1.0;
      final x = t * size.width;
      final y = (i * stepY * 1.5) % size.height;

      final glowPaint = Paint()
        ..color = palette.accent.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);

      canvas.drawCircle(Offset(x, y), 3.0, glowPaint);
      canvas.drawCircle(Offset(x, y), 1.8, pulsePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CircuitBoardPainter oldDelegate) =>
      oldDelegate.pulseProgress != pulseProgress ||
      oldDelegate.palette != palette;
}
