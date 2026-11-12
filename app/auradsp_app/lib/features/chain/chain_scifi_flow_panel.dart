/*
 * chain_scifi_flow_panel.dart — 全局信号流顺序科幻全景面板组件
 * 1. 标题与交互：13.5px 适度标题、触发条右侧科幻流光胶囊按钮一键展开/收起 HUD
 * 2. 滚轮事件独占：拦截 PointerScrollEvent 阻止外层页面联动滚动
 * 3. 实时缩放仪表：动态显示当前缩放百分比（例如 100% 复位、125% 复位）
 * 4. 极致 PCB 背景与多路径电流粒子：多走向折角铜箔走线、汇流焊盘过孔、分支电流穿梭，零 GC 内存优化
 * 5. 真实芯片节点拓扑：Stage 0~4 插件实时物理嵌入，重绘科技能量双折角流光箭头
 */

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/effect_registry.dart';
import '../../core/plugins/plugin_manager.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../core/ui_helpers.dart';
import '../../l10n/gen/app_localizations.dart';
import '../../platform/adapters.dart';
import '../chain_page.dart' show stageLabelOf, stageCategoryLabelOf;

/// 科幻全局信号流全景展开面板
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
  late AnimationController _expandCtrl;
  late Animation<double> _expandAnim;
  late AnimationController _circuitPulseCtrl;
  final TransformationController _transCtrl = TransformationController();
  double _currentScale = 1.0;

  @override
  void initState() {
    super.initState();
    _expandCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 360),
    );
    _expandAnim = CurvedAnimation(
      parent: _expandCtrl,
      curve: Curves.easeOutCubic,
    );

    // 电路板电流粒子循环动画
    _circuitPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2600),
    );

    _transCtrl.addListener(_onTransformChanged);
    // 窗口可见性门控：展开态的电流脉冲在托盘/最小化时停转，
    // 恢复可见且仍展开时续转（2026-11-12 优化指令）。
    PlatformAdapters.instance.window.visibleListenable
        .addListener(_onVisibilityChanged);
  }

  void _onVisibilityChanged() {
    if (!PlatformAdapters.instance.window.isVisible) {
      if (_circuitPulseCtrl.isAnimating) _circuitPulseCtrl.stop();
    } else if (_isExpanded && !_circuitPulseCtrl.isAnimating) {
      _circuitPulseCtrl.repeat();
    }
  }

  void _onTransformChanged() {
    final scale = _transCtrl.value.getMaxScaleOnAxis();
    if ((scale - _currentScale).abs() > 0.02) {
      setState(() {
        _currentScale = scale;
      });
    }
  }

  @override
  void dispose() {
    PlatformAdapters.instance.window.visibleListenable
        .removeListener(_onVisibilityChanged);
    _transCtrl.removeListener(_onTransformChanged);
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
    setState(() {
      _currentScale = 1.0;
    });
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

    final pm = widget.model.pluginManager;
    var pluginCount = 0;
    for (var s = 0; s < PluginManager.kMaxSlots; s++) {
      if (pm.isSlotActive(s)) {
        pluginCount++;
      }
    }

    return Container(
      margin: const EdgeInsets.only(top: AuraSpace.sm),
      decoration: BoxDecoration(
        color: p.panelRaised.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(AuraRadius.md),
        border: Border.all(
          color: _isExpanded ? p.accent.withValues(alpha: 0.45) : p.hairline,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. 顶部科幻触发条
          InkWell(
            borderRadius: BorderRadius.circular(AuraRadius.md),
            onTap: _toggleExpand,
            child: Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AuraSpace.md,
                vertical: AuraSpace.sm + 2,
              ),
              child: Row(
                children: [
                  // 左侧声学霓虹灯柱
                  Container(
                    width: 3.5,
                    height: 15,
                    decoration: BoxDecoration(
                      color: p.accent,
                      borderRadius: BorderRadius.circular(2),
                      boxShadow: [
                        BoxShadow(
                          color: p.accent.withValues(alpha: 0.75),
                          blurRadius: 5,
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
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                          color: p.text,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '全链路 24 节点拓扑 · 实时 Stage 0~4 插件注入 · 支持平移缩放',
                        style: monoOf(p, size: 10, color: p.textDim),
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
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$activeCount 活跃',
                          style: monoOf(p, size: 10.5, color: p.accent),
                        ),
                        if (pluginCount > 0) ...[
                          Text(' · ', style: TextStyle(color: p.textDim, fontSize: 10)),
                          Text(
                            '$pluginCount 插件',
                            style: monoOf(p, size: 10.5, color: p.accent2),
                          ),
                        ],
                        if (bypassedCount > 0) ...[
                          Text(' · ', style: TextStyle(color: p.textDim, fontSize: 10)),
                          Text(
                            '$bypassedCount 旁路',
                            style: monoOf(p, size: 10.5, color: p.textDim),
                          ),
                        ],
                      ],
                    ),
                  ),

                  // 右侧科幻胶囊展开按钮
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: _isExpanded
                          ? p.accent.withValues(alpha: 0.16)
                          : p.panelRaised,
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      border: Border.all(
                        color: _isExpanded ? p.accent : p.hairline,
                        width: 1.0,
                      ),
                      boxShadow: _isExpanded
                          ? [
                              BoxShadow(
                                color: p.accent.withValues(alpha: 0.25),
                                blurRadius: 8,
                                spreadRadius: 0,
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
                              : Icons.hub_outlined,
                          size: 14,
                          color: _isExpanded ? p.accent : p.text,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          _isExpanded ? '收起面板' : '显示全景',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w600,
                            color: _isExpanded ? p.accent : p.text,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // 2. 展开的 HUD 科幻信号流面板主体
          SizeTransition(
            sizeFactor: _expandAnim,
            alignment: Alignment.topCenter,
            child: AnimatedBuilder(
              animation: _circuitPulseCtrl,
              builder: (context, _) {
                return Container(
                  height: 240,
                  decoration: BoxDecoration(
                    color: p.bg.withValues(alpha: 0.94),
                    borderRadius: const BorderRadius.vertical(
                      bottom: Radius.circular(AuraRadius.md),
                    ),
                    border: Border(
                      top: BorderSide(color: p.accent.withValues(alpha: 0.3)),
                    ),
                  ),
                  child: Stack(
                    children: [
                      // 背景有机电路走线与电流流光粒子
                      Positioned.fill(
                        child: CustomPaint(
                          painter: _CircuitBoardPainter(
                            palette: p,
                            pulseProgress: _circuitPulseCtrl.value,
                          ),
                        ),
                      ),

                      // 滚轮事件独占监听器：拦截 PointerScrollEvent 杜绝外层页面滚动
                      Positioned.fill(
                        child: Listener(
                          behavior: HitTestBehavior.opaque,
                          onPointerSignal: (pointerSignal) {
                            if (pointerSignal is PointerScrollEvent) {
                              // 独占消费滚轮事件，阻止冒泡到外层可滚动页面
                              GestureBinding.instance.pointerSignalResolver.register(
                                pointerSignal,
                                (_) {},
                              );
                            }
                          },
                          child: InteractiveViewer(
                            transformationController: _transCtrl,
                            constrained: false,
                            boundaryMargin: const EdgeInsets.symmetric(
                              horizontal: 2400,
                              vertical: 150,
                            ),
                            minScale: 0.3,
                            maxScale: 2.5,
                            clipBehavior: Clip.hardEdge,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: AuraSpace.xl,
                                vertical: 60,
                              ),
                              child: _buildPhysicalSignalChain(context, p, l),
                            ),
                          ),
                        ),
                      ),

                      // 右上角浮动操作条（动态显示实时缩放比并支持复位）
                      Positioned(
                        top: 8,
                        right: 12,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 动态比例复位按钮
                            InkWell(
                              borderRadius: BorderRadius.circular(AuraRadius.xs),
                              onTap: _resetZoom,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 4,
                                ),
                                decoration: BoxDecoration(
                                  color: p.panelRaised.withValues(alpha: 0.85),
                                  borderRadius: BorderRadius.circular(AuraRadius.xs),
                                  border: Border.all(color: p.hairline),
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(
                                      Icons.restart_alt_rounded,
                                      size: 13,
                                      color: p.accent,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      '${(_currentScale * 100).toInt()}% 复位',
                                      style: monoOf(p, size: 10.5, color: p.accent).copyWith(
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),

                      // 底部手势引导提示
                      Positioned(
                        bottom: 8,
                        right: 14,
                        child: Text(
                          '鼠标左键/触屏拖拽平移 · 滚轮独立缩放',
                          style: monoOf(p, size: 9.5, color: p.textDim.withValues(alpha: 0.5)),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  /// 真实物理音频处理流水线（包含首尾固化门控与 Stage 0~4 插件芯片插槽）
  Widget _buildPhysicalSignalChain(
    BuildContext context,
    AuraPalette p,
    AppLocalizations l,
  ) {
    final pm = widget.model.pluginManager;
    final widgets = <Widget>[];

    void addArrow() {
      widgets.add(const _ScifiEnergyArrow());
    }

    void addPluginSlotsForStage(int stageIndex) {
      for (var s = 0; s < PluginManager.kMaxSlots; s++) {
        if (pm.isSlotActive(s) && pm.getSlotStage(s) == stageIndex) {
          final isBypassed = pm.isSlotBypassed(s);
          final active = pm.getSlotPlugin(s);
          final slotName = active != null ? active.name : 'Plugin Slot ${s + 1}';
          final slotFmt = active != null ? active.format.label : 'VST';
          final latency = pm.getSlotLatency(s);

          widgets.add(
            _PluginChipNode(
              slot: s + 1,
              name: slotName,
              format: slotFmt,
              isBypassed: isBypassed,
              latency: latency,
              palette: p,
            ),
          );
          addArrow();
        }
      }
    }

    // 1. Audio Input
    widgets.add(_PinnedNode(
      name: 'Audio In',
      desc: '系统音频输入',
      icon: Icons.login_rounded,
      palette: p,
      accentColor: p.accent,
    ));
    addArrow();

    // 2. Input Gate
    widgets.add(_PinnedNode(
      name: 'Input Gate',
      desc: '输入物理门控',
      icon: Icons.shield_outlined,
      palette: p,
      isBypassed: false,
    ));
    addArrow();

    void addCoreNode(String id) {
      widgets.add(_CoreEffectNode(
        id: id,
        model: widget.model,
        palette: p,
        l10n: l,
      ));
      addArrow();
    }

    // 第七轮 S1：以下段位严格按引擎 process_stereo_chain 真序拼合。
    // 此前是硬编码分桶（reverb 恒钉 Stage 2 后、loudness 恒钉 Stage 3
    // 后、其余全部塞进主桶），与真实执行序在默认序下即有四处偏差，
    // 且跨桶拖动在图上纹丝不动（项 1 定罪）。

    // 3. 前置钉死段 gate → filter → bassmono
    for (final id in kChainPinnedHead) {
      if (widget.order.contains(id)) addCoreNode(id);
    }

    // 4. Stage 0: Pre-DSP 插件槽位
    addPluginSlotsForStage(0);

    // 5. dyneq（Stage 0 之后、vendor 段之前钉死）
    for (final id in kChainPinnedMid) {
      if (widget.order.contains(id)) addCoreNode(id);
    }

    // 6. Stage 1: Pre-Vendor 插件槽位
    addPluginSlotsForStage(1);

    // 7. vendor 段（相对序 = graphOrder 的 vendor 子序，
    //    reverb 在其真实名次，不再被摘出钉位）
    for (final id in vendorSubsequenceOf(widget.order)) {
      addCoreNode(id);
    }

    // 8. Stage 2: Post-Vendor 插件槽位
    addPluginSlotsForStage(2);

    // 9. 尾段钉死级 haas → spatial → exciter
    for (final id in kChainPinnedTail) {
      if (widget.order.contains(id)) addCoreNode(id);
    }

    // 10. Stage 3: Post-Exciter 插件槽位
    addPluginSlotsForStage(3);

    // 11. loudness（Stage 3 之后、限幅器之前钉死）
    for (final id in kChainPinnedPost) {
      if (widget.order.contains(id)) addCoreNode(id);
    }

    // 12. Output Gate
    widgets.add(_PinnedNode(
      name: 'Output Gate',
      desc: '输出物理门控',
      icon: Icons.shield_outlined,
      palette: p,
      isBypassed: false,
    ));
    addArrow();

    // 13. 前瞻限幅器 (Limiter)
    widgets.add(_PinnedNode(
      name: 'Limiter',
      desc: '1.5ms 前瞻限幅',
      icon: Icons.speed_rounded,
      palette: p,
      isBypassed: !widget.model.limiterOn,
    ));
    addArrow();

    // 14. Stage 4: Post-Limiter 插件槽位
    addPluginSlotsForStage(4);

    // 15. Audio Output
    widgets.add(_PinnedNode(
      name: 'Audio Out',
      desc: '后级音频输出',
      icon: Icons.logout_rounded,
      palette: p,
      accentColor: p.accent,
    ));

    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.center,
      children: widgets,
    );
  }
}

/// 固定首尾门控节点
class _PinnedNode extends StatelessWidget {
  final String name;
  final String desc;
  final IconData icon;
  final AuraPalette palette;
  final bool isBypassed;
  final Color? accentColor;

  const _PinnedNode({
    required this.name,
    required this.desc,
    required this.icon,
    required this.palette,
    this.isBypassed = false,
    this.accentColor,
  });

  @override
  Widget build(BuildContext context) {
    final col = accentColor ?? (isBypassed ? palette.textDim : palette.accent);
    return Container(
      width: 98,
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: palette.panelRaised.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: col.withValues(alpha: isBypassed ? 0.3 : 0.7),
          width: 1.2,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, size: 16, color: col),
          const SizedBox(height: 3),
          Text(
            name,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: isBypassed ? palette.textDim : palette.text,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            desc,
            style: monoOf(palette, size: 8.5, color: palette.textDim),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

/// 核心 DSP 处理节点
class _CoreEffectNode extends StatelessWidget {
  final String id;
  final AppModel model;
  final AuraPalette palette;
  final AppLocalizations l10n;

  const _CoreEffectNode({
    required this.id,
    required this.model,
    required this.palette,
    required this.l10n,
  });

  @override
  Widget build(BuildContext context) {
    final isEnabled = model.isStageEnabled(id);
    final label = stageLabelOf(l10n, id);
    final cat = stageCategoryLabelOf(context, id);

    return Container(
      width: 92,
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
      decoration: BoxDecoration(
        color: isEnabled
            ? palette.panel.withValues(alpha: 0.95)
            : palette.panel.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: isEnabled
              ? palette.accent.withValues(alpha: 0.45)
              : palette.hairline.withValues(alpha: 0.35),
          width: 1.0,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: isEnabled
                  ? palette.accent.withValues(alpha: 0.12)
                  : palette.bg.withValues(alpha: 0.4),
              borderRadius: BorderRadius.circular(AuraRadius.xs),
            ),
            child: Text(
              cat,
              style: monoOf(
                palette,
                size: 8.5,
                color: isEnabled ? palette.accent : palette.textDim,
              ),
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isEnabled ? palette.text : palette.textDim,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            isEnabled ? '活跃' : '旁路',
            style: monoOf(
              palette,
              size: 8.5,
              color: isEnabled ? palette.success : palette.textDim,
            ),
          ),
        ],
      ),
    );
  }
}

/// 芯片插槽式第三方插件节点
class _PluginChipNode extends StatelessWidget {
  final int slot;
  final String name;
  final String format;
  final bool isBypassed;
  final int latency;
  final AuraPalette palette;

  const _PluginChipNode({
    required this.slot,
    required this.name,
    required this.format,
    required this.isBypassed,
    required this.latency,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final chipColor = isBypassed ? palette.warning : palette.accent2;

    return Container(
      width: 124,
      height: 76,
      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
      decoration: BoxDecoration(
        color: palette.bg.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(
          color: chipColor.withValues(alpha: isBypassed ? 0.45 : 0.85),
          width: 1.4,
        ),
        boxShadow: [
          BoxShadow(
            color: chipColor.withValues(alpha: isBypassed ? 0.08 : 0.2),
            blurRadius: 6,
            spreadRadius: 0,
          ),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.memory_rounded, size: 12, color: chipColor),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  'SLOT $slot · $format',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: monoOf(palette, size: 9, color: chipColor).copyWith(
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            name,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w600,
              color: isBypassed ? palette.textDim : palette.text,
            ),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 1),
          Text(
            isBypassed ? '插槽旁路' : '${latency}spl 延迟',
            style: monoOf(
              palette,
              size: 8.5,
              color: isBypassed ? palette.warning : palette.textDim,
            ),
          ),
        ],
      ),
    );
  }
}

/// 能量流光双折角箭头
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

    canvas.drawLine(Offset(0, cy), Offset(size.width - 6, cy), linePaint);

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

/// 有机 PCB 电路背景与轻量级电流脉冲绘制器（零内存抖动架构）
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
      ..color = palette.accent.withValues(alpha: 0.07)
      ..strokeWidth = 1.0
      ..style = PaintingStyle.stroke;

    final padPaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.16)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke;

    final pulsePaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.8)
      ..style = PaintingStyle.fill;

    final pulseGlowPaint = Paint()
      ..color = palette.accent.withValues(alpha: 0.25)
      ..style = PaintingStyle.fill;

    final w = size.width;
    final h = size.height;

    // 1. 绘制多走向设计感 PCB 走线（含 45°/90° 折角母线与汇聚过孔）
    final path = Path();

    // 顶部与底部复合水平母线
    path.moveTo(0, 24);
    path.lineTo(w * 0.35, 24);
    path.lineTo(w * 0.35 + 20, 44);
    path.lineTo(w, 44);

    path.moveTo(0, h - 24);
    path.lineTo(w * 0.65, h - 24);
    path.lineTo(w * 0.65 + 20, h - 44);
    path.lineTo(w, h - 44);

    // 中间交织走线
    path.moveTo(0, h * 0.45);
    path.lineTo(w * 0.2, h * 0.45);
    path.lineTo(w * 0.25, h * 0.45 + 18);
    path.lineTo(w * 0.75, h * 0.45 + 18);
    path.lineTo(w * 0.8, h * 0.45);
    path.lineTo(w, h * 0.45);

    // 纵向连接支线
    path.moveTo(w * 0.15, 0);
    path.lineTo(w * 0.15, 30);
    path.lineTo(w * 0.15 + 15, 45);
    path.lineTo(w * 0.15 + 15, h * 0.5);

    path.moveTo(w * 0.85, h);
    path.lineTo(w * 0.85, h - 30);
    path.lineTo(w * 0.85 - 15, h - 45);
    path.lineTo(w * 0.85 - 15, h * 0.5);

    canvas.drawPath(path, tracePaint);

    // 2. 绘制重要过孔节点与芯片引脚焊盘 (Vias)
    final vias = [
      Offset(w * 0.15, 24),
      Offset(w * 0.35, 24),
      Offset(w * 0.35 + 20, 44),
      Offset(w * 0.25, h * 0.45 + 18),
      Offset(w * 0.75, h * 0.45 + 18),
      Offset(w * 0.65, h - 24),
      Offset(w * 0.85, h - 24),
      Offset(w * 0.85 - 15, h - 45),
    ];

    for (final via in vias) {
      canvas.drawCircle(via, 3.2, padPaint);
      canvas.drawCircle(via, 1.4, pulsePaint);
    }

    // 3. 多分支有机电流脉冲粒子流动（轻量化纯色层叠发光，零内存消耗）
    // 分支 1：沿顶部母线前进
    final t1 = pulseProgress;
    final p1x = t1 * w;
    final p1y = p1x < w * 0.35
        ? 24.0
        : (p1x < w * 0.35 + 20
            ? 24.0 + (p1x - w * 0.35)
            : 44.0);
    canvas.drawCircle(Offset(p1x, p1y), 4.2, pulseGlowPaint);
    canvas.drawCircle(Offset(p1x, p1y), 2.0, pulsePaint);

    // 分支 2：沿中间走线反向流动
    final t2 = (pulseProgress + 0.5) % 1.0;
    final p2x = w * (1.0 - t2);
    final p2y = (p2x > w * 0.25 && p2x < w * 0.75)
        ? h * 0.45 + 18
        : h * 0.45;
    canvas.drawCircle(Offset(p2x, p2y), 4.0, pulseGlowPaint);
    canvas.drawCircle(Offset(p2x, p2y), 1.8, pulsePaint);

    // 分支 3：沿底部母线前进
    final t3 = (pulseProgress + 0.25) % 1.0;
    final p3x = t3 * w;
    final p3y = p3x < w * 0.65
        ? h - 24.0
        : (p3x < w * 0.65 + 20
            ? h - 24.0 - (p3x - w * 0.65)
            : h - 44.0);
    canvas.drawCircle(Offset(p3x, p3y), 4.2, pulseGlowPaint);
    canvas.drawCircle(Offset(p3x, p3y), 2.0, pulsePaint);

    // 分支 4：纵向支线快速脉冲
    final t4 = (pulseProgress + 0.75) % 1.0;
    final p4y = t4 * h;
    final p4x = w * 0.15 + (p4y > 30 && p4y < 45 ? (p4y - 30) : (p4y >= 45 ? 15.0 : 0.0));
    canvas.drawCircle(Offset(p4x, p4y), 3.5, pulseGlowPaint);
    canvas.drawCircle(Offset(p4x, p4y), 1.6, pulsePaint);
  }

  @override
  bool shouldRepaint(covariant _CircuitBoardPainter oldDelegate) =>
      oldDelegate.pulseProgress != pulseProgress ||
      oldDelegate.palette != palette;
}
