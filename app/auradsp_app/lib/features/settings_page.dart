/*
 * settings_page.dart — 设置页：延迟模式 / 配色 / 语言 / 声道 / 引擎信息
 *
 * 一卡一节，序号贯通；说明文字统一挂在卡片标题下（hint），不再散落在控件之间。
 */
import 'package:flutter/material.dart';

import '../core/config.dart';
import '../core/design.dart';
import '../core/session_memory.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
import 'widgets.dart';

class SettingsPage extends StatelessWidget {
  final AppModel model;
  const SettingsPage({super.key, required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => PageScaffold(
        eyebrow: l.pageSettingsEyebrow,
        title: l.pageSettingsTitle,
        children: [
          // 01 延迟模式（ADR-002 三档）
          SectionCard(
            index: '01',
            title: l.latencyMode,
            hint: switch (model.latencyMode) {
              0 => l.latencyRealtimeDesc,
              1 => l.latencyMusicDesc,
              _ => l.latencyQualityDesc,
            },
            child: AuraSegmented<int>(
              segments: [
                AuraSegment(0, l.latencyRealtime),
                AuraSegment(1, l.latencyMusic),
                AuraSegment(2, l.latencyQuality),
              ],
              selected: model.latencyMode,
              onChanged: model.setLatencyMode,
            ),
          ),
          // 02 配色
          SectionCard(
            index: '02',
            title: l.theme,
            child: Row(
              children: [
                Expanded(
                  child: _ThemeCard(
                    name: l.themeAuraDark,
                    selected: model.themeId == AuraThemeId.auraDark,
                    swatch: const [
                      Color(0xFF0E0F13),
                      Color(0xFF171A21),
                      Color(0xFFD4FF3F),
                    ],
                    onTap: () => model.setTheme(AuraThemeId.auraDark),
                  ),
                ),
                const SizedBox(width: AuraSpace.md),
                Expanded(
                  child: _ThemeCard(
                    name: l.themeAuraLight,
                    selected: model.themeId == AuraThemeId.auraLight,
                    swatch: const [
                      Color(0xFFF4F1EA),
                      Color(0xFFFFFFFF),
                      Color(0xFFE63B2E),
                    ],
                    onTap: () => model.setTheme(AuraThemeId.auraLight),
                  ),
                ),
                const SizedBox(width: AuraSpace.md),
                Expanded(
                  child: _ThemeCard(
                    name: l.themeAurora,
                    selected: model.themeId == AuraThemeId.aurora,
                    swatch: const [
                      Color(0xFF070B14),
                      Color(0xFF0D1522),
                      Color(0xFF64F0DC),
                    ],
                    onTap: () => model.setTheme(AuraThemeId.aurora),
                  ),
                ),
              ],
            ),
          ),
          // 03 语言
          SectionCard(
            index: '03',
            title: l.language,
            child: AuraSegmented<String>(
              segments: const [
                AuraSegment('zh', '简体中文'),
                AuraSegment('en', 'English'),
                AuraSegment('ja', '日本語'),
              ],
              selected: model.locale.languageCode,
              onChanged: (v) => model.setLocale(Locale(v)),
            ),
          ),
          // 04 声道模式（ADR-003 Phase A）
          SectionCard(
            index: '04',
            title: l.channelMode,
            hint: l.channelPhaseA,
            child: AuraSegmented<int>(
              segments: [
                AuraSegment(0, l.channelsStereo),
                AuraSegment(1, l.channels51),
                AuraSegment(2, l.channels71),
              ],
              selected: model.channelsMode,
              onChanged: (v) => model.setInt('channels.mode', v),
            ),
          ),
          // 05 引擎信息
          SectionCard(
            index: '05',
            title: l.engineInfo,
            child: _EngineInfo(model: model),
          ),
          // 06 持久化记忆与外置配置
          SectionCard(
            index: '06',
            title: '持久化记忆与配置外置',
            hint: '自动记录当前所有效果调音状态，并在应用下次启动时无缝恢复。',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text('退出时自动保存并恢复会话记忆', style: labelOf(p)),
                    AuraSwitch(
                      value: model.config.autoRestoreSession,
                      onChanged: model.setAutoRestoreSession,
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                Text('配置存储目录: ${ConfigManager.baseDir}',
                    style: monoOf(p, size: 10, color: p.textDim)),
                const SizedBox(height: AuraSpace.sm),
                Row(
                  children: [
                    AuraChip(
                      '清除会话记忆',
                      icon: Icons.delete_outline_rounded,
                      onTap: () {
                        SessionMemory.clear();
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('已清除持久化会话记忆，下次启动将使用纯净默认值'),
                          duration: Duration(milliseconds: 1400),
                        ));
                      },
                    ),
                    const SizedBox(width: AuraSpace.sm),
                    AuraChip(
                      '重置外置配置为默认',
                      icon: Icons.restore_rounded,
                      onTap: () {
                        model.resetConfig();
                        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                          content: Text('已重置 config.json 为标准配置模板'),
                          duration: Duration(milliseconds: 1400),
                        ));
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _EngineInfo extends StatelessWidget {
  final AppModel model;
  const _EngineInfo({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final info = model.info;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.engineForm, 'Desktop · in-process DLL'),
        if (info != null) ...[
          _InfoRow('ABI', 'v${info.abi} · ${info.version}'),
          _InfoRow('Device', '${info.deviceRate} Hz / ${info.deviceCh} ch'),
          _InfoRow('Buffer', '${info.bufferFrames} frames'),
        ],
        _InfoRow('Latency', '${model.latencyMs.toStringAsFixed(1)} ms'),
        const SizedBox(height: AuraSpace.md),
        Container(height: 1, color: p.hairline),
        const SizedBox(height: AuraSpace.md),
        Text(l.about, style: sectionOf(p)),
        const SizedBox(height: AuraSpace.sm),
        Text(l.aboutBody, style: captionOf(p)),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  final String k, v;
  const _InfoRow(this.k, this.v);

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: AuraSpace.xs),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(k, style: labelOf(p, size: 12, color: p.textDim)),
          ),
          Expanded(child: Text(v, style: monoOf(p, size: 12))),
        ],
      ),
    );
  }
}

class _ThemeCard extends StatefulWidget {
  final String name;
  final bool selected;
  final List<Color> swatch;
  final VoidCallback onTap;
  const _ThemeCard({
    required this.name,
    required this.selected,
    required this.swatch,
    required this.onTap,
  });

  @override
  State<_ThemeCard> createState() => _ThemeCardState();
}

class _ThemeCardState extends State<_ThemeCard> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final border = widget.selected
        ? p.accent
        : (_hover ? p.textDim.withValues(alpha: 0.5) : p.hairline);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: AuraDur.base,
          curve: AuraCurve.standard,
          padding: const EdgeInsets.all(AuraSpace.sm),
          decoration: BoxDecoration(
            color: widget.selected
                ? p.accent.withValues(alpha: 0.06)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AuraRadius.sm),
            border: Border.all(color: border, width: widget.selected ? 1.5 : 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(AuraRadius.xs),
                child: SizedBox(
                  height: 28,
                  child: Row(
                    children: [
                      for (final c in widget.swatch)
                        Expanded(child: Container(color: c)),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: AuraSpace.sm),
              AnimatedDefaultTextStyle(
                duration: AuraDur.fast,
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight:
                      widget.selected ? FontWeight.w600 : FontWeight.w400,
                  color: widget.selected ? p.text : p.textDim,
                ),
                child: Text(widget.name,
                    maxLines: 1, overflow: TextOverflow.ellipsis),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
