/*
 * chain_page.dart — 处理链页（M3.5-c 完整落地，Phase 2 分组）：
 * 1. 处理顺序调整（Element 式拖拽重排 + graph.order 下发；组头不可拖拽，原地不动）
 * 2. 全 20 级节点双声道实时微型电平表（Mini Stereo Peak Meter；
 *    12 个 vendor + 8 个自研 stage 均具备独立输出峰值采样，见 stageMeterIndex）
 * 3. 节点独立旁路开关（Bypass / Enable）双向状态联动
 * 4. 链组折叠头（6 组，空间独立成组）+ 整组旁路（跳过常驻限幅器）
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
  (id: 'gate', exposed: true),
  (id: 'dyneq', exposed: true),
  (id: 'filter', exposed: true),
  (id: 'bassmono', exposed: true),  (id: 'tube', exposed: true),
  (id: 'comp', exposed: true),
  (id: 'bass', exposed: true),
  (id: 'eq', exposed: true),
  (id: 'arbmag', exposed: true),
  (id: 'convolver', exposed: true),
  (id: 'ddc', exposed: true),
  (id: 'liveprog', exposed: true),
  (id: 'crossfeed', exposed: true),
  (id: 'stereo', exposed: true),
  (id: 'haas', exposed: true),
  (id: 'spatial', exposed: true),
  (id: 'exciter', exposed: true),
  (id: 'loudness', exposed: true),
  (id: 'reverb', exposed: true),
  (id: 'output', exposed: true),
];

/// stage id → 展示名（l10n；与效果器卡片名称严格对齐；未知 id 回退原文）。
String stageLabelOf(AppLocalizations l, String id) => switch (id) {
      'gate' => l.stGate,
      'dyneq' => l.stDyneq,
      'filter' => l.stFilter,
      'bass_shaping' => l.bassShapingTitle,
      'bassmono' => l.stBassmono,
      'shelf' => l.shelfTitle,
      'tube' => l.tubeTitle,
      'comp' => l.compTitle,
      'bass' => l.bassBoost,
      'eq' => l.eqMultiBand,
      'arbmag' => l.stArbmag,
      'convolver' => l.convTitle,
      'ddc' => l.ddcTitle,
      'liveprog' => l.stScript,
      'crossfeed' => l.crossfeedTitle,
      'stereo' => l.stereoWiden,
      'haas' => l.stHaas,
      'spatial' => l.spatialTitle,
      'exciter' => l.stExciter,
      'loudness' => l.stLoudness,
      'reverb' => l.spatialReverbTitle,
      'output' => l.postGain,
      _ => id,
    };

const List<String> kDefaultCoreOrder = [
  'gate',
  'filter',
  'dyneq',
  'bassmono',
  'tube',
  'comp',
  'bass',
  'eq',
  'arbmag',
  'convolver',
  'ddc',
  'liveprog',
  'crossfeed',
  'stereo',
  'haas',
  'spatial',
  'exciter',
  'reverb',
  'loudness',
];

/// 链组（Phase 2）：按链位置 contiguous 分组；组头可折叠 + 整组旁路。
/// 空间独立成组（B 组单行）；reverb 归入输出段尾链（激励→房间→响度→出口）。
const Map<String, List<String>> kChainGroups = {
  'chInput': ['gate', 'filter'],
  // dyneq 与 comp 被 bassmono/tube 隔开是默认链序的如实样子，强行拆成两组
  // 会在默认视图下打出两个“动态控制”头；此处按连续段合并为一组。
  'chTone': ['dyneq', 'bassmono', 'tube', 'comp', 'bass'],
  'chEq': ['eq', 'arbmag', 'convolver', 'ddc', 'liveprog'],
  'chSound': ['crossfeed', 'stereo', 'haas'],
  'chSpatial': ['spatial'],
  'chOut': ['exciter', 'reverb', 'loudness', 'output'],
};

/// 链组 id → 展示名（l10n）。
String chainGroupLabelOf(AppLocalizations l, String g) => switch (g) {
      'chInput' => l.chainGrpInput,
      'chTone' => l.chainGrpTone,
      'chEq' => l.chainGrpEqScript,
      'chSound' => l.chainGrpSound,
      'chSpatial' => l.chainGrpSpatial,
      'chOut' => l.chainGrpOut,
      _ => g,
    };

/// stage → 组逆查（未知 id 归入上一组，防御未来新增 stage）。
final Map<String, String> _stageToGroup = {
  for (final e in kChainGroups.entries)
    for (final id in e.value) id: e.key,
};

/// stage id → 分类展示名（方框徽标用，随中英文切换）。
String stageCategoryLabelOf(BuildContext ctx, String id) {
  final isZh = Localizations.localeOf(ctx).languageCode == 'zh';
  final g = _stageToGroup[id];
  return switch (g) {
    'chInput' => isZh ? '输入' : 'Input',
    'chTone' => isZh ? '音色' : 'Tone',
    'chEq' => isZh ? '均衡' : 'EQ',
    'chSound' => isZh ? '声场' : 'Field',
    'chSpatial' => isZh ? '空间' : 'Spatial',
    'chOut' => isZh ? '输出' : 'Output',
    _ => isZh ? '效果' : 'FX',
  };
}

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
    final raw = (widget.model.graphOrder ?? kDefaultCoreOrder.join(',')).split(',');
    _order = raw.where((id) => id != 'output' && id != 'input' && kDefaultCoreOrder.contains(id)).toList();
    // 缺失 id 按规范位置补入（旧存档缺 spatial 时落 haas 后，而非尾部）。
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

  void _apply() {
    final fullOrder = '${_order.join(',')},output';
    widget.model.setGraphOrder(fullOrder);
    setState(() => _dirty = false);
  }

  void _reset() {
    setState(() {
      _order = List<String>.from(kDefaultCoreOrder);
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  height: 54.0 * _order.length + 8,
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
                        borderRadius: BorderRadius.circular(AuraRadius.md),
                        child: c,
                      ),
                      child: child,
                    ),
                    itemBuilder: (ctx, i) {
                      final id = _order[i];
                      final meta = kStageMeta.firstWhere((s) => s.id == id,
                          orElse: () => (id: id, exposed: false));
                      final isEnabled = widget.model.isStageEnabled(id);
                      return ReorderableDragStartListener(
                        key: ValueKey(id),
                        index: i,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 3),
                          padding: const EdgeInsets.symmetric(
                              horizontal: AuraSpace.md + 2, vertical: AuraSpace.sm + 1),
                          decoration: BoxDecoration(
                            color: isEnabled
                                ? p.panel
                                : p.panel.withValues(alpha: 0.75),
                            borderRadius: BorderRadius.circular(AuraRadius.md),
                            border: Border.all(
                              color: isEnabled ? p.hairline : p.hairline.withValues(alpha: 0.5),
                            ),
                          ),
                          child: Row(children: [
                            Icon(Icons.drag_indicator_rounded,
                                size: 16, color: p.textDim),
                            const SizedBox(width: AuraSpace.sm),
                            Container(
                              width: 24,
                              alignment: Alignment.center,
                              child: Text('${i + 1}',
                                  style: monoOf(p,
                                      size: 11.5,
                                      color: isEnabled ? p.accent : p.textDim)),
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
                            // 分类方框标记（自适应主色主题切换）
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 5, vertical: 1.5),
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
                            // [M3.5-c] 双声道微型实时电平表（全 19 级节点逐级独立峰值采样）
                            _StageStereoMeter(
                              meterIndex:
                                  widget.model.stageMeterIndex(id),
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
                const SizedBox(height: AuraSpace.md),
                // 完整实际处理链路顺序流图（顺序钉死的输入门控 -> 动态核心节点 -> 顺序钉死的输出门控）
                _FullChainOrderFlowView(order: _order, model: widget.model),
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
                // 双插槽独立控制卡片列表（插入阶段由卡片内下拉菜单精确调整）
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

/// 完整实际音频处理链路顺序流图组件（展示首尾钉死门控与中间动态节点）
class _FullChainOrderFlowView extends StatelessWidget {
  final List<String> order;
  final AppModel model;

  const _FullChainOrderFlowView({required this.order, required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return Container(
      padding: const EdgeInsets.all(AuraSpace.sm + 3),
      decoration: BoxDecoration(
        color: p.panelRaised.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.route_rounded, size: 14, color: p.accent),
              const SizedBox(width: 4),
              Text(
                l.chainFlowCaption,
                style: monoOf(p, size: 11, color: p.textDim).copyWith(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          Wrap(
            spacing: 5,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              // 1. 输入门控（常驻钉死首位）
              _flowNode(
                p: p,
                label: l.chainNodeInput,
                isFixed: true,
                isActive: true,
                tag: l.chainPinnedFirst,
              ),
              _flowArrow(p),

              // 2. 核心动态音效节点（按用户拖拽顺序实时展示）
              for (var i = 0; i < order.length; i++) ...[
                () {
                  final id = order[i];
                  final label = stageLabelOf(l, id);
                  final isEnabled = model.isStageEnabled(id);
                  return _flowNode(
                    p: p,
                    label: label,
                    isFixed: false,
                    isActive: isEnabled,
                  );
                }(),
                _flowArrow(p),
              ],

              // 3. 输出门控（常驻钉死末位）
              _flowNode(
                p: p,
                label: l.chainNodeOutputGate,
                isFixed: true,
                isActive: true,
                tag: l.chainPinnedLast,
              ),
              _flowArrow(p),

              // 4. 主限幅器
              _flowNode(
                p: p,
                label: l.chainNodeLimiter,
                isFixed: true,
                isActive: model.limiterOn,
              ),
              _flowArrow(p),

              // 5. 最终音频输出
              _flowNode(
                p: p,
                label: l.chainNodeOutput,
                isFixed: true,
                isActive: true,
              ),
            ],
          ),
        ],
      ),
    );
  }

  static Widget _flowNode({
    required AuraPalette p,
    required String label,
    required bool isFixed,
    required bool isActive,
    String? tag,
  }) {
    final bgColor = isFixed
        ? p.accent.withValues(alpha: 0.12)
        : (isActive ? p.panel : p.panel.withValues(alpha: 0.5));
    final borderColor = isFixed
        ? p.accent.withValues(alpha: 0.6)
        : (isActive ? p.accent.withValues(alpha: 0.4) : p.hairline);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(isFixed ? AuraRadius.xs : 10),
        border: Border.all(color: borderColor, width: isFixed ? 1.2 : 0.9),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isFixed)
            Padding(
              padding: const EdgeInsets.only(right: 3),
              child: Icon(Icons.lock_outline_rounded, size: 10, color: p.accent),
            )
          else
            Container(
              width: 5,
              height: 5,
              margin: const EdgeInsets.only(right: 4),
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: isActive ? p.accent : p.textDim.withValues(alpha: 0.4),
              ),
            ),
          Text(
            label,
            style: TextStyle(
              fontSize: 10.5,
              fontWeight: isFixed || isActive ? FontWeight.bold : FontWeight.normal,
              color: isActive ? p.text : p.textDim.withValues(alpha: 0.7),
            ),
          ),
          if (tag != null) ...[
            const SizedBox(width: 3),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
              decoration: BoxDecoration(
                color: p.accent.withValues(alpha: 0.2),
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                tag,
                style: TextStyle(fontSize: 8, color: p.accent, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ],
      ),
    );
  }

  static Widget _flowArrow(AuraPalette p) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 1.5),
      child: Icon(Icons.arrow_forward_rounded,
          size: 10.5, color: p.textDim.withValues(alpha: 0.5)),
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
            AuraDropdown<int>(
              value: currentStage,
              isExpanded: false,
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
            const SizedBox(width: AuraSpace.sm),
            // GUI 打开按钮
            IconButton(
              tooltip: l10nOf(context).chainOpenGui,
              icon: const Icon(Icons.open_in_new_rounded, size: 17),
              // C1：同一插件可挂多槽，标题必须带槽位号区分两个编辑器窗口。
              onPressed: () => manager.showEditor(
                slot: slot,
                title: active != null
                    ? l10nOf(context).plugEditorTitleNamed(slot + 1, active.name)
                    : null,
              ),
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
    return ListenableBuilder(
      listenable: Listenable.merge([model.stageLevelsL, model.stageLevelsR]),
      builder: (ctx, _) {
        final levelsL = model.stageLevelsL.value;
        final levelsR = model.stageLevelsR.value;
        final dbL = (meterIndex >= 0 && meterIndex < levelsL.length)
            ? levelsL[meterIndex]
            : -120.0;
        final dbR = (meterIndex >= 0 && meterIndex < levelsR.length)
            ? levelsR[meterIndex]
            : -120.0;

        // 硬件合成器分段 LED 电平表（双声道支持，可扩展多通道）
        return _SynthLedLadderMeter(
          channelsDb: [dbL, dbR],
          isEnabled: isEnabled,
          palette: p,
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
      // 点亮的段数（0 ~ kSegments），防御 clamp 闭区间
      final litCount = isEnabled ? (normVal * kSegments).round().clamp(0, kSegments) : 0;
      final colLeft = c * (colW + colGap);

      // 从底向上绘制每一段 LED（0 为最底端，kSegments - 1 为最顶端）
      for (var s = 0; s < kSegments; s++) {
        final segBottom = size.height - s * (segH + 1.5);
        final segTop = segBottom - segH;
        final isLit = s < litCount;

        // 分段色彩：
        // 底段 0..4: 翠绿 (安全动态)
        // 中段 5..6: 琥珀橙/黄 (高能量预警)
        // 顶段 7: 鲜红 (削波过载 Peak)
        final Color litColor;
        if (s >= 7) {
          litColor = const Color(0xFFEF4444); // 鲜红
        } else if (s >= 5) {
          litColor = const Color(0xFFF59E0B); // 琥珀黄
        } else {
          litColor = const Color(0xFF10B981); // 翠绿
        }

        final rect = RRect.fromRectAndRadius(
          Rect.fromLTWH(colLeft, segTop, colW, segH),
          const Radius.circular(0.8),
        );

        if (isLit) {
          // 点亮状态：主体色填充
          final paint = Paint()
            ..color = litColor
            ..style = PaintingStyle.fill;
          canvas.drawRRect(rect, paint);
        } else {
          // 熄灭底座：深色半透明硬件凹槽
          final offColor = isEnabled
              ? litColor.withValues(alpha: 0.12)
              : palette.textDim.withValues(alpha: 0.10);
          final offPaint = Paint()
            ..color = offColor
            ..style = PaintingStyle.fill;
          canvas.drawRRect(rect, offPaint);
        }
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
