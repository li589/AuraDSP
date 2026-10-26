/*
 * liveprog_sliders_panel.dart — EEL2 编辑器底部内嵌三类参数调节面板
 *
 * 紧随控制台下方，提供自适应参数调节与统一边框质感。
 * 分成三类可切换：
 * 1. 脚本参数 (Script Sliders)：自适应识别代码中全部变量（slider1..8 实时联动引擎，自定义变量展示初值与范围）
 * 2. 输入通道 (Input Channels, 8 通道)：8 声道统一架构前级平衡 (0.0~2.0x) 与全局输入增益 (-15dB~+15dB)
 * 3. 输出通道 (Output Channels, 8 通道)：8 声道后级独立增益补偿 (-15dB~+15dB) 与全局输出增益 (-15dB~+15dB)
 */
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/param_schema.dart';
import '../../../core/state.dart';
import '../../../core/theme.dart';
import '../../../core/ui_helpers.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../chrome.dart';
import '../eel_editor_support.dart';

class LiveprogSlidersPanel extends StatefulWidget {
  final AppModel model;
  final Map<int, EelSliderMeta> activeSliders;

  const LiveprogSlidersPanel({
    super.key,
    required this.model,
    required this.activeSliders,
  });

  @override
  State<LiveprogSlidersPanel> createState() => _LiveprogSlidersPanelState();
}

class _LiveprogSlidersPanelState extends State<LiveprogSlidersPanel> {
  int _selectedTab = 0; // 0: script, 1: input, 2: output
  bool _expanded = true;
  bool _showAll = false;

  static const _channels8 = ['FL', 'FR', 'C', 'LFE', 'SL', 'SR', 'BL', 'BR'];

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = AppLocalizations.of(context)!;
    final m = widget.model;

    final scriptSliders = widget.activeSliders.values.toList();
    final hostSliders = scriptSliders.where((s) => s.isHostSlider).toList();
    final customVars = scriptSliders.where((s) => !s.isHostSlider).toList();

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(AuraSpace.sm),
      decoration: BoxDecoration(
        color: p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // 顶部标题与三类切换页签栏
          Row(
            children: [
              Icon(Icons.tune_rounded, size: 14, color: p.accent),
              const SizedBox(width: AuraSpace.xs),
              // 三类切换 Pill 页签
              Container(
                height: 28,
                padding: const EdgeInsets.all(2),
                decoration: BoxDecoration(
                  color: p.panel,
                  borderRadius: BorderRadius.circular(AuraRadius.sm),
                  border: Border.all(color: p.hairline),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildPillTab(
                      index: 0,
                      label: l.lpTabScriptSliders,
                      count: scriptSliders.length,
                      palette: p,
                    ),
                    const SizedBox(width: 2),
                    _buildPillTab(
                      index: 1,
                      label: l.lpTabInputChannels,
                      palette: p,
                    ),
                    const SizedBox(width: 2),
                    _buildPillTab(
                      index: 2,
                      label: l.lpTabOutputChannels,
                      palette: p,
                    ),
                  ],
                ),
              ),
              const Spacer(),
              if (_expanded) ...[
                if (_selectedTab == 0 && (scriptSliders.isNotEmpty || _showAll)) ...[
                  AuraChip(
                    _showAll ? l.lpShowAll : l.lpAdaptive(scriptSliders.length),
                    icon: Icons.tune_rounded,
                    selected: !_showAll,
                    onTap: () => setState(() => _showAll = !_showAll),
                  ),
                  const SizedBox(width: AuraSpace.xs),
                  _buildResetButton(
                    tooltip: l.lpResetAll,
                    palette: p,
                    onTap: () {
                      for (var i = 0; i < 8; i++) {
                        final meta = widget.activeSliders[i + 1];
                        m.setLiveprogParam(i, meta?.defaultVal ?? 0.0);
                      }
                    },
                  ),
                ] else if (_selectedTab == 1) ...[
                  _buildResetButton(
                    tooltip: l.lpResetAll,
                    palette: p,
                    onTap: () {
                      m.setParam(ParamRegistry.inputGain, 0.0);
                      m.setParam(ParamRegistry.inputBalanceL, 1.0);
                      m.setParam(ParamRegistry.inputBalanceR, 1.0);
                      for (var c = 2; c < 8; c++) {
                        m.setParamById('input.balance.${c + 1}', 1.0);
                      }
                    },
                  ),
                ] else if (_selectedTab == 2) ...[
                  _buildResetButton(
                    tooltip: l.lpResetAll,
                    palette: p,
                    onTap: () {
                      m.setFloat('post.gain', 0.0);
                      for (var c = 0; c < 8; c++) {
                        m.setFloat('post.gain.c$c', 0.0);
                      }
                    },
                  ),
                ],
                const SizedBox(width: AuraSpace.xs),
              ],
              IconButton(
                icon: Icon(
                  _expanded
                      ? Icons.keyboard_arrow_up_rounded
                      : Icons.keyboard_arrow_down_rounded,
                  size: 16,
                  color: p.textDim,
                ),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
                tooltip: _expanded ? l.lpSlidersCollapse : l.lpSlidersExpand,
                onPressed: () => setState(() => _expanded = !_expanded),
              ),
            ],
          ),

          if (_expanded) ...[
            const SizedBox(height: AuraSpace.xs),
            Divider(color: p.hairline, height: 1),
            const SizedBox(height: AuraSpace.sm),
            ListenableBuilder(
              listenable: m,
              builder: (context, _) {
                switch (_selectedTab) {
                  case 0:
                    return _buildScriptSlidersTab(
                      p: p,
                      l: l,
                      m: m,
                      hostSliders: hostSliders,
                      customVars: customVars,
                    );
                  case 1:
                    return _buildInputChannelsTab(
                      p: p,
                      l: l,
                      m: m,
                    );
                  case 2:
                  default:
                    return _buildOutputChannelsTab(
                      p: p,
                      l: l,
                      m: m,
                    );
                }
              },
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPillTab({
    required int index,
    required String label,
    int? count,
    required AuraPalette palette,
  }) {
    final isSelected = _selectedTab == index;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () => setState(() => _selectedTab = index),
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        child: AnimatedContainer(
          duration: AuraDur.fast,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: isSelected ? palette.accent.withValues(alpha: 0.16) : Colors.transparent,
            borderRadius: BorderRadius.circular(AuraRadius.xs),
            border: isSelected
                ? Border.all(color: palette.accent.withValues(alpha: 0.45), width: 1)
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                label,
                style: monoOf(palette, size: 11, color: isSelected ? palette.accent : palette.textDim).copyWith(
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
                ),
              ),
              if (count != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 0.5),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? palette.accent.withValues(alpha: 0.25)
                        : palette.hairline,
                    borderRadius: BorderRadius.circular(AuraRadius.xs),
                  ),
                  child: Text(
                    '$count',
                    style: monoOf(
                      palette,
                      size: 9.5,
                      color: isSelected ? palette.accent : palette.textDim,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResetButton({
    required String tooltip,
    required AuraPalette palette,
    required VoidCallback onTap,
  }) {
    return IconButton(
      icon: const Icon(Icons.refresh_rounded, size: 14),
      color: palette.textDim,
      tooltip: tooltip,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(),
      onPressed: onTap,
    );
  }

  // ---- Tab 0: 脚本参数 ----
  Widget _buildScriptSlidersTab({
    required AuraPalette p,
    required AppLocalizations l,
    required AppModel m,
    required List<EelSliderMeta> hostSliders,
    required List<EelSliderMeta> customVars,
  }) {
    if (!_showAll && hostSliders.isEmpty && customVars.isEmpty) {
      return Container(
        padding: const EdgeInsets.symmetric(
            vertical: AuraSpace.md, horizontal: AuraSpace.sm),
        alignment: Alignment.center,
        child: Column(
          children: [
            Icon(Icons.tune_outlined, size: 24, color: p.textDim),
            const SizedBox(height: 4),
            Text(
              l.lpNoScriptSliders,
              style: captionOf(p),
            ),
            const SizedBox(height: 6),
            OutlinedButton.icon(
              onPressed: () => setState(() => _showAll = true),
              icon: const Icon(Icons.expand_more_rounded, size: 14),
              label: Text(l.lpExpandSliders),
              style: OutlinedButton.styleFrom(
                foregroundColor: p.accent,
                side: BorderSide(color: p.hairline),
                visualDensity: VisualDensity.compact,
              ),
            ),
          ],
        ),
      );
    }

    final displayedIndices = _showAll
        ? List.generate(8, (i) => i + 1)
        : hostSliders.map((s) => s.index).toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final idx in displayedIndices)
          _LpSliderRow(
            model: m,
            index: idx - 1,
            meta: widget.activeSliders[idx],
          ),
        if (customVars.isNotEmpty) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Text(
                l.lpCustomVarTag,
                style: monoOf(p, size: 10, color: p.textDim),
              ),
              const SizedBox(width: 4),
              InfoBadge(message: l.lpCustomVarHint),
            ],
          ),
          const SizedBox(height: 4),
          for (final cv in customVars)
            _LpCustomVarRow(meta: cv),
        ],
      ],
    );
  }

  // ---- Tab 1: 输入通道 (8 声道) ----
  Widget _buildInputChannelsTab({
    required AuraPalette p,
    required AppLocalizations l,
    required AppModel m,
  }) {
    final inGain = m.inputGain;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l.lpInputMasterGain,
              style: monoOf(p, size: 11, color: p.text).copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            InfoBadge(message: l.lpInputTrimHint),
            const Spacer(),
            Text(
              inGain > 0 ? '+${inGain.toStringAsFixed(1)} dB' : '${inGain.toStringAsFixed(1)} dB',
              style: monoOf(p, size: 11, color: inGain.abs() > 0.01 ? p.accent : p.textDim),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: inGain.clamp(-15.0, 15.0),
            min: -15.0,
            max: 15.0,
            onChanged: (v) => m.setParam(ParamRegistry.inputGain, v),
          ),
        ),
        const SizedBox(height: 4),
        Divider(color: p.hairline, height: 1),
        const SizedBox(height: AuraSpace.xs),
        for (var c = 0; c < 8; c++) ...[
          _buildInputChannelBalanceRow(
            p: p,
            m: m,
            channelIndex: c,
            channelCode: _channels8[c],
          ),
        ],
      ],
    );
  }

  Widget _buildInputChannelBalanceRow({
    required AuraPalette p,
    required AppModel m,
    required int channelIndex,
    required String channelCode,
  }) {
    double bal;
    if (channelIndex == 0) {
      bal = m.getParam(ParamRegistry.inputBalanceL);
    } else if (channelIndex == 1) {
      bal = m.getParam(ParamRegistry.inputBalanceR);
    } else {
      bal = m.mirrorFloat('input.balance.${channelIndex + 1}', 1.0);
    }
    bal = bal.clamp(0.0, 2.0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              channelCode,
              style: monoOf(p, size: 11, color: (bal - 1.0).abs() > 0.01 ? p.accent : p.textDim).copyWith(
                fontWeight: (bal - 1.0).abs() > 0.01 ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
              ),
              child: Slider(
                value: bal,
                min: 0.0,
                max: 2.0,
                onChanged: (v) {
                  if (channelIndex == 0) {
                    m.setParam(ParamRegistry.inputBalanceL, v);
                  } else if (channelIndex == 1) {
                    m.setParam(ParamRegistry.inputBalanceR, v);
                  } else {
                    m.setParamById('input.balance.${channelIndex + 1}', v);
                  }
                },
              ),
            ),
          ),
          SizedBox(
            width: 48,
            child: Text(
              '${bal.toStringAsFixed(2)}x',
              textAlign: TextAlign.right,
              style: monoOf(p, size: 11, color: (bal - 1.0).abs() > 0.01 ? p.text : p.textDim),
            ),
          ),
        ],
      ),
    );
  }

  // ---- Tab 2: 输出通道 (8 声道) ----
  Widget _buildOutputChannelsTab({
    required AuraPalette p,
    required AppLocalizations l,
    required AppModel m,
  }) {
    final postGain = m.postGain;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              l.lpOutputMasterGain,
              style: monoOf(p, size: 11, color: p.text).copyWith(fontWeight: FontWeight.w600),
            ),
            const SizedBox(width: 4),
            InfoBadge(message: l.lpOutputGainHint),
            const Spacer(),
            Text(
              postGain > 0 ? '+${postGain.toStringAsFixed(1)} dB' : '${postGain.toStringAsFixed(1)} dB',
              style: monoOf(p, size: 11, color: postGain.abs() > 0.01 ? p.accent : p.textDim),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
          ),
          child: Slider(
            value: postGain.clamp(-15.0, 15.0),
            min: -15.0,
            max: 15.0,
            onChanged: (v) => m.setFloat('post.gain', v),
          ),
        ),
        const SizedBox(height: 4),
        Divider(color: p.hairline, height: 1),
        const SizedBox(height: AuraSpace.xs),
        for (var c = 0; c < 8; c++) ...[
          _buildOutputChannelTrimRow(
            p: p,
            m: m,
            channelIndex: c,
            channelCode: _channels8[c],
          ),
        ],
      ],
    );
  }

  Widget _buildOutputChannelTrimRow({
    required AuraPalette p,
    required AppModel m,
    required int channelIndex,
    required String channelCode,
  }) {
    final trim = m.mirrorFloat('post.gain.c$channelIndex', 0.0).clamp(-15.0, 15.0);

    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          SizedBox(
            width: 50,
            child: Text(
              channelCode,
              style: monoOf(p, size: 11, color: trim.abs() > 0.01 ? p.accent : p.textDim).copyWith(
                fontWeight: trim.abs() > 0.01 ? FontWeight.bold : FontWeight.normal,
              ),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 2.5,
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 5.5),
              ),
              child: Slider(
                value: trim,
                min: -15.0,
                max: 15.0,
                onChanged: (v) => m.setFloat('post.gain.c$channelIndex', v),
              ),
            ),
          ),
          SizedBox(
            width: 58,
            child: Text(
              trim > 0 ? '+${trim.toStringAsFixed(1)} dB' : '${trim.toStringAsFixed(1)} dB',
              textAlign: TextAlign.right,
              style: monoOf(p, size: 11, color: trim.abs() > 0.01 ? p.text : p.textDim),
            ),
          ),
        ],
      ),
    );
  }
}

class _LpSliderRow extends StatelessWidget {
  final AppModel model;
  final int index;
  final EelSliderMeta? meta;

  const _LpSliderRow({
    required this.model,
    required this.index,
    this.meta,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    var minVal = meta?.minVal ?? 0.0;
    var maxVal = meta?.maxVal ?? 1.0;
    if (minVal > maxVal) {
      final tmp = minVal;
      minVal = maxVal;
      maxVal = tmp;
    } else if (minVal == maxVal) {
      maxVal = minVal + 1.0;
    }
    final displayName = meta?.displayName ?? 'slider${index + 1}';
    final rawName = 'slider${index + 1}';
    final currentVal = model.lpParams[index].clamp(minVal, maxVal);

    String valueDisplay = currentVal.toStringAsFixed(2);
    if (meta != null && meta!.enumOptions.isNotEmpty) {
      final intVal = currentVal.round().clamp(0, meta!.enumOptions.length - 1);
      valueDisplay = meta!.enumOptions[intVal];
    }

    return Padding(
      padding: const EdgeInsets.only(bottom: AuraSpace.xs + 2),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight:
                        meta != null ? FontWeight.bold : FontWeight.normal,
                    color: meta != null ? p.accent : p.text,
                  ),
                ),
                Text(
                  rawName,
                  style: monoOf(p, size: 9.5, color: p.textDim),
                ),
              ],
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                trackHeight: 3,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6.5),
              ),
              child: Slider(
                value: currentVal,
                min: minVal,
                max: maxVal,
                onChanged: (v) => model.setLiveprogParam(index, v),
              ),
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          SizedBox(
            width: 70,
            child: Text(
              valueDisplay,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: monoOf(p, size: 11, color: p.text),
            ),
          ),
        ],
      ),
    );
  }
}

class _LpCustomVarRow extends StatelessWidget {
  final EelSliderMeta meta;

  const _LpCustomVarRow({required this.meta});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = AppLocalizations.of(context)!;

    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: p.panel,
        borderRadius: BorderRadius.circular(AuraRadius.xs),
        border: Border.all(color: p.hairline),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
            decoration: BoxDecoration(
              color: p.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(AuraRadius.xs),
            ),
            child: Text(
              l.lpCustomVarTag,
              style: monoOf(p, size: 9.5, color: p.accent),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  meta.displayName.isNotEmpty ? meta.displayName : meta.rawName,
                  style: monoOf(p, size: 11, color: p.text).copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                Text(
                  '${meta.rawName} = ${meta.defaultVal} (${meta.minVal} ~ ${meta.maxVal})',
                  style: monoOf(p, size: 9.5, color: p.textDim),
                ),
              ],
            ),
          ),
          Tooltip(
            message: l.lpCustomVarHint,
            child: Icon(Icons.info_outline_rounded, size: 14, color: p.textDim),
          ),
        ],
      ),
    );
  }
}
