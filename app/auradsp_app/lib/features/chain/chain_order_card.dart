/*
 * chain_order_card.dart — 处理顺序卡片组件
 * 1. 卡片命名：「处理顺序」（去过度修饰）
 * 2. 拖拽自动应用：移动节点顺序即刻实时同步下发引擎，无需手动点击「应用」
 * 3. 智能重置：仅在当前顺序偏离默认顺序时显现「恢复默认」按钮，默认顺序下自动隐藏
 * 4. 全链路 19 级节点逐级独立实时双声道微型电平表与旁路控制
 * 5. 内嵌科幻全局信号流全景展开面板
 */

import 'package:flutter/material.dart';

import '../../core/design.dart';
import '../../core/nav.dart';
import '../../core/state.dart';
import '../../core/theme.dart';
import '../../engine/auradsp_ffi.dart' show kVizChannelMax;
import '../../ui/chrome.dart';
import '../../ui/widgets.dart';
import '../../ui/wheel_scroll.dart';
import '../chain_page.dart';
import '../effects_page.dart' show kEffectCategories;
import 'chain_scifi_flow_panel.dart';

/// 处理顺序管理卡片
class ChainOrderCard extends StatefulWidget {
  final AppModel model;
  const ChainOrderCard({super.key, required this.model});

  @override
  State<ChainOrderCard> createState() => _ChainOrderCardState();
}

class _ChainOrderCardState extends State<ChainOrderCard> {
  final ScrollController _chainScrollCtrl = ScrollController();
  late List<String> _order;

  @override
  void initState() {
    super.initState();
    _initOrderFromModel();
  }

  void _initOrderFromModel() {
    final raw = (widget.model.graphOrder ?? kDefaultCoreOrder.join(',')).split(',');
    _order = raw.where((id) => id != 'output' && id != 'input' && kDefaultCoreOrder.contains(id)).toList();
    for (final id in kDefaultCoreOrder) {
      if (!_order.contains(id)) {
        final want = kDefaultCoreOrder.indexOf(id);
        var at = _order.length;
        for (var i = 0; i < _order.length; i++) {
          if (kDefaultCoreOrder.indexOf(_order[i]) > want) {
            at = i;
            break;
          }
        }
        _order.insert(at, id);
      }
    }
  }

  /// 检查当前排序是否偏离系统默认排序
  bool get _isNonDefaultOrder {
    if (_order.length != kDefaultCoreOrder.length) return true;
    for (var i = 0; i < _order.length; i++) {
      if (_order[i] != kDefaultCoreOrder[i]) return true;
    }
    return false;
  }

  /// 自动应用新顺序
  void _applyOrder() {
    final fullOrder = '${_order.join(',')},output';
    widget.model.setGraphOrder(fullOrder);
  }

  /// 恢复默认顺序
  void _resetToDefault() {
    setState(() {
      _order = List<String>.from(kDefaultCoreOrder);
      _applyOrder();
    });
  }

  void _navigateToStage(String id) {
    final mappedId = switch (id) {
      'output' => 'post',
      'bassmono' || 'shelf' => 'bass_shaping',
      _ => id,
    };
    for (final entry in kEffectCategories.entries) {
      if (entry.value.contains(mappedId)) {
        widget.model.setEffectsCategory(entry.key);
        widget.model.visiblePage.value = AppPage.effects;
        break;
      }
    }
  }

  @override
  void dispose() {
    _chainScrollCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return SectionCard(
      title: l.chainOrderTitle, // 「处理顺序」
      hint: l.chainOrderHint,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 仅在非默认顺序下才显示「恢复默认」按钮，无需繁琐的「应用」按钮（拖动即刻自动应用）
          if (_isNonDefaultOrder)
            AuraChip(
              l.chainReset,
              icon: Icons.restart_alt_rounded,
              onTap: _resetToDefault,
            ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: (54.0 * _order.length + 8).clamp(
              0.0,
              (MediaQuery.sizeOf(context).height * 0.6).clamp(320.0, 900.0),
            ),
            child: Scrollbar(
              controller: _chainScrollCtrl,
              thumbVisibility: true,
              child: ReorderableListView.builder(
                scrollController: _chainScrollCtrl,
                physics: const AuraListScrollPhysics(),
                buildDefaultDragHandles: false,
                itemCount: _order.length,
                // ignore: deprecated_member_use
                onReorder: (oldI, newI) {
                  setState(() {
                    if (newI > oldI) newI -= 1;
                    final item = _order.removeAt(oldI);
                    _order.insert(newI, item);
                    // 用户移动顺序即刻自动应用，无需手动确认
                    _applyOrder();
                  });
                },
                proxyDecorator: (child, index, anim) => AnimatedBuilder(
                  animation: anim,
                  builder: (_, c) => Material(
                    color: p.accent.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(AuraRadius.md),
                    child: c,
                  ),
                  child: child,
                ),
                itemBuilder: (ctx, i) {
                  final id = _order[i];
                  final meta = kStageMeta.firstWhere(
                    (s) => s.id == id,
                    orElse: () => (id: id, exposed: false),
                  );
                  final isEnabled = widget.model.isStageEnabled(id);

                  return ReorderableDragStartListener(
                    key: ValueKey(id),
                    index: i,
                    child: Container(
                      margin: const EdgeInsets.symmetric(vertical: 3),
                      padding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.md + 2,
                        vertical: AuraSpace.sm + 1,
                      ),
                      decoration: BoxDecoration(
                        color: isEnabled
                            ? p.panel
                            : p.panel.withValues(alpha: 0.75),
                        borderRadius: BorderRadius.circular(AuraRadius.md),
                        border: Border.all(
                          color: isEnabled
                              ? p.hairline
                              : p.hairline.withValues(alpha: 0.5),
                        ),
                      ),
                      child: Row(
                        children: [
                          Icon(Icons.drag_indicator_rounded,
                              size: 16, color: p.textDim),
                          const SizedBox(width: AuraSpace.sm),
                          Container(
                            width: 24,
                            alignment: Alignment.center,
                            child: Text(
                              '${i + 1}',
                              style: monoOf(
                                p,
                                size: 11.5,
                                color: isEnabled ? p.accent : p.textDim,
                              ),
                            ),
                          ),
                          const SizedBox(width: AuraSpace.sm + 2),
                          Text(
                            stageLabelOf(l10nOf(ctx), id),
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: isEnabled
                                  ? p.text
                                  : p.textDim.withValues(alpha: 0.8),
                            ),
                          ),
                          const SizedBox(width: AuraSpace.sm),
                          // 分类方框标记
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: p.accent.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(AuraRadius.xs),
                              border: Border.all(
                                color: p.accent.withValues(alpha: 0.35),
                                width: 1.0,
                              ),
                            ),
                            child: Text(
                              stageCategoryLabelOf(ctx, id),
                              style: monoOf(
                                p,
                                size: 10,
                                color: isEnabled ? p.accent : p.textDim,
                              ).copyWith(fontWeight: FontWeight.w600),
                            ),
                          ),
                          const Spacer(),

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
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: p.panelRaised,
                                borderRadius: BorderRadius.circular(AuraRadius.xs),
                                border: Border.all(color: p.hairline),
                              ),
                              child: Text(
                                l10nOf(context).chainReserved,
                                style: captionOf(p),
                              ),
                            ),
                            const SizedBox(width: AuraSpace.md),
                          ],

                          // 双声道微型实时电平表
                          _StageStereoMeter(
                            meterIndex: widget.model.stageMeterIndex(id),
                            isEnabled: isEnabled,
                            model: widget.model,
                          ),
                          const SizedBox(width: AuraSpace.sm),
                          InkWell(
                            borderRadius: BorderRadius.circular(AuraRadius.xs),
                            onTap: () => _navigateToStage(id),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 2.0,
                                vertical: 4.0,
                              ),
                              child: Icon(
                                Icons.chevron_right_rounded,
                                size: 16,
                                color: p.textDim.withValues(alpha: 0.6),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          const SizedBox(height: AuraSpace.md),
          // 科幻全局信号流全景面板
          ChainScifiFlowPanel(order: _order, model: widget.model),
        ],
      ),
    );
  }
}

/// 节点旁路切换胶囊按钮
class _StageBypassPill extends StatelessWidget {
  final bool isEnabled;
  final VoidCallback onTap;

  const _StageBypassPill({
    required this.isEnabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return InkWell(
      borderRadius: BorderRadius.circular(AuraRadius.xs),
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: isEnabled
              ? p.accent.withValues(alpha: 0.12)
              : p.panelRaised,
          borderRadius: BorderRadius.circular(AuraRadius.xs),
          border: Border.all(
            color: isEnabled
                ? p.accent.withValues(alpha: 0.45)
                : p.hairline,
            width: 1.0,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 5.5,
              height: 5.5,
              decoration: BoxDecoration(
                color: isEnabled ? p.accent : p.textDim.withValues(alpha: 0.4),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 5),
            Text(
              isEnabled ? l.plugActive : l.chainBypass,
              style: monoOf(
                p,
                size: 10.5,
                color: isEnabled ? p.accent : p.textDim,
              ).copyWith(fontWeight: FontWeight.w600),
            ),
          ],
        ),
      ),
    );
  }
}

/// [M3.5-c] 硬件乐器合成器风格分段 LED 点阵电平表（一列灯一个声道，支持多通道扩展）
class _StageStereoMeter extends StatelessWidget {
  /// vendor 链位置（0..11）；自研 stage 为 -1（引擎无逐级电平，不画表）。
  final int meterIndex;
  final bool isEnabled;
  final AppModel model;

  const _StageStereoMeter({
    required this.meterIndex,
    required this.isEnabled,
    required this.model,
  });

  @override
  Widget build(BuildContext context) {
    // 未知或非法 stage 索引：不画表
    if (meterIndex < 0) return const SizedBox.shrink();
    final p = paletteOf(context);

    return ValueListenableBuilder<AppPage>(
      valueListenable: model.visiblePage,
      builder: (ctx, page, _) {
        if (page != AppPage.chain) return const SizedBox.shrink();
        return ListenableBuilder(
          listenable: Listenable.merge([
            model.stageLevelsL,
            model.stageLevelsR,
            model.vizChannelCount,
            model.vizChannelLevels,
            model.vizStageChLevels,
          ]),
          builder: (ctx, _) {
            final levelsL = model.stageLevelsL.value;
            final levelsR = model.stageLevelsR.value;
            final chCount = model.vizChannelCount.value;

            final List<double> columns;
            if (chCount > 2) {
              final grid = model.vizStageChLevels.value;
              final dbL = (meterIndex >= 0 && meterIndex < levelsL.length)
                  ? levelsL[meterIndex]
                  : -120.0;
              final dbR = (meterIndex >= 0 && meterIndex < levelsR.length)
                  ? levelsR[meterIndex]
                  : -120.0;
              // 节点作用域：矩阵模式下节点链是立体声（仅 FL/FR），其余声道
              // 属总线输出口径。禁止在 -120 时借用输出 chLevels —— 那会把
              // 立体声节点画成 8 柱（违反 Phase B G5 诚实显示）。
              final activeCh = model.channelsMode == 0 ? 2 : chCount;

              columns = List<double>.generate(8, (c) {
                if (c >= activeCh) return -120.0; // 作用域外：非活跃态（不涂亮）
                if (c == 0) return dbL;
                if (c == 1) return dbR;
                final idx = meterIndex * kVizChannelMax + c;
                if (idx >= 0 && idx < grid.length && grid[idx] > -119.0) {
                  return grid[idx];
                }
                return -120.0;
              });
            } else {
              final dbL = (meterIndex >= 0 && meterIndex < levelsL.length)
                  ? levelsL[meterIndex]
                  : -120.0;
              final dbR = (meterIndex >= 0 && meterIndex < levelsR.length)
                  ? levelsR[meterIndex]
                  : -120.0;
              columns = [dbL, dbR];
            }

            return _SynthLedLadderMeter(
              channelsDb: columns,
              isEnabled: isEnabled,
              palette: p,
            );
          },
        );
      },
    );
  }
}

/// 合成器分段 LED 阶梯电平表容器组件
class _SynthLedLadderMeter extends StatelessWidget {
  final List<double> channelsDb;
  final bool isEnabled;
  final AuraPalette palette;

  const _SynthLedLadderMeter({
    required this.channelsDb,
    required this.isEnabled,
    required this.palette,
  });

  @override
  Widget build(BuildContext context) {
    final chCount = channelsDb.length;
    final safeCount = chCount > 0 ? chCount : 2;
    const colW = 4.0;
    const colGap = 2.5;
    const totalH = 30.0;
    final totalW = (safeCount * colW) + ((safeCount - 1) * colGap) + 6.0;

    return Container(
      width: totalW,
      height: totalH,
      padding: const EdgeInsets.symmetric(horizontal: 2.5, vertical: 2.0),
      decoration: BoxDecoration(
        color: palette.bg.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(3),
        border: Border.all(
          color: palette.hairline.withValues(alpha: 0.5),
          width: 0.8,
        ),
      ),
      child: CustomPaint(
        size: Size(totalW - 6.0, totalH - 4.0),
        painter: _SynthLedPainter(
          channelsDb: channelsDb,
          isEnabled: isEnabled,
          palette: palette,
        ),
      ),
    );
  }
}

/// 合成器分段 LED 自底向上点阵绘制器
class _SynthLedPainter extends CustomPainter {
  final List<double> channelsDb;
  final bool isEnabled;
  final AuraPalette palette;

  static const int kSegments = 8; // 8 级垂直分段 LED 灯珠

  static final Paint _greenLitPaint = Paint()
    ..color = const Color(0xFF10B981)
    ..style = PaintingStyle.fill;
  static final Paint _amberLitPaint = Paint()
    ..color = const Color(0xFFF59E0B)
    ..style = PaintingStyle.fill;
  static final Paint _redLitPaint = Paint()
    ..color = const Color(0xFFEF4444)
    ..style = PaintingStyle.fill;

  static final Paint _greenOffPaint = Paint()
    ..color = const Color(0xFF10B981).withValues(alpha: 0.12)
    ..style = PaintingStyle.fill;
  static final Paint _amberOffPaint = Paint()
    ..color = const Color(0xFFF59E0B).withValues(alpha: 0.12)
    ..style = PaintingStyle.fill;
  static final Paint _redOffPaint = Paint()
    ..color = const Color(0xFFEF4444).withValues(alpha: 0.12)
    ..style = PaintingStyle.fill;
  static final Paint _disabledOffPaint = Paint()
    ..color = Colors.white.withValues(alpha: 0.08)
    ..style = PaintingStyle.fill;

  _SynthLedPainter({
    required this.channelsDb,
    required this.isEnabled,
    required this.palette,
  });

  static double _norm(double db) {
    if (db.isNaN || db.isInfinite || db <= -60.0) return 0.0;
    if (db >= 0.0) return 1.0;
    return ((db + 60.0) / 60.0).clamp(0.0, 1.0);
  }

  @override
  void paint(Canvas canvas, Size size) {
    final chCount = channelsDb.length;
    if (chCount == 0 || size.height <= 0 || size.width <= 0) return;

    final colW = 4.0;
    final colGap = 2.5;
    final segH = (size.height - (kSegments - 1) * 1.5) / kSegments;

    for (var c = 0; c < chCount; c++) {
      final db = channelsDb[c];
      final normVal = _norm(db);
      final litCount = isEnabled ? (normVal * kSegments).round().clamp(0, kSegments) : 0;
      final colLeft = c * (colW + colGap);

      for (var s = 0; s < kSegments; s++) {
        final segBottom = size.height - s * (segH + 1.5);
        final segTop = segBottom - segH;
        final isLit = s < litCount;

        final Paint segPaint;
        if (isLit) {
          if (s >= 7) {
            segPaint = _redLitPaint;
          } else if (s >= 5) {
            segPaint = _amberLitPaint;
          } else {
            segPaint = _greenLitPaint;
          }
        } else {
          if (!isEnabled) {
            segPaint = _disabledOffPaint;
          } else if (s >= 7) {
            segPaint = _redOffPaint;
          } else if (s >= 5) {
            segPaint = _amberOffPaint;
          } else {
            segPaint = _greenOffPaint;
          }
        }

        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(colLeft, segTop, colW, segH),
          const Radius.circular(0.8),
        );
        canvas.drawRRect(rect, segPaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant _SynthLedPainter old) {
    if (old.isEnabled != isEnabled || old.palette != palette) return true;
    if (old.channelsDb.length != channelsDb.length) return true;
    for (var i = 0; i < channelsDb.length; i++) {
      if (old.channelsDb[i] != channelsDb[i]) return true;
    }
    return false;
  }
}
