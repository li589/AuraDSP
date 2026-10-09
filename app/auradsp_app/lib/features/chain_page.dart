/*
 * chain_page.dart — 处理链页（M3.5-b v1）：处理顺序调整（Element 式）
 *
 * 数据：stage 顺序（默认 = vendor 链序，Dart 镜像）→ ReorderableListView
 * 拖拽重排 → setParamStr("graph.order", ...) 下发（引擎 P-004 表驱动）。
 * 每节点右侧显示该效果是否"参数已开放"（exposed）与开关归属提示。
 * 多通道电平显示依赖 per-node viz 分接（M3.5-c），本版为占位灰条。
 */
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
import 'widgets.dart';

/// vendor 链序 stage 元数据（与引擎 kAuraStages 对齐）
const List<({String id, String label, bool exposed})> kStages = [
  (id: 'tube', label: '真空管', exposed: true),
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
    return PageScaffold(
      title: '处理链',
      children: [
        SectionCard(
          title: '处理顺序',
          hint: '拖拽调整信号处理先后（自上而下）；改动后点"应用"。'
              '带 ★ 的节点参数在效果页调整；排序不改变效果开关。',
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
            height: 40.0 * _order.length + 8,
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
                return ReorderableDragStartListener(
                  key: ValueKey(id),
                  index: i,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 1),
                    padding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.md, vertical: AuraSpace.xs + 1),
                    decoration: BoxDecoration(
                      color: p.panel,
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      border: Border.all(color: p.hairline),
                    ),
                    child: Row(children: [
                      Icon(Icons.drag_indicator_rounded,
                          size: 16, color: p.textDim),
                      const SizedBox(width: AuraSpace.sm),
                      Container(
                        width: 24,
                        alignment: Alignment.center,
                        child: Text('${i + 1}',
                            style: monoOf(p, size: 11, color: p.accent)),
                      ),
                      const SizedBox(width: AuraSpace.md),
                      Expanded(
                        child: Text(meta.label,
                            style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.w600,
                                color: meta.exposed ? p.text : p.textDim)),
                      ),
                      if (!meta.exposed)
                        Text('参数开放中',
                            style: captionOf(p)),
                      // 多通道电平占位（M3.5-c：per-node viz 分接）
                      Container(
                        width: 72,
                        height: 5,
                        decoration: BoxDecoration(
                          color: p.hairline,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                      const SizedBox(width: AuraSpace.md),
                      Icon(Icons.chevron_right_rounded,
                          size: 16, color: p.textDim.withValues(alpha: 0.5)),
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
    );
  }
}
