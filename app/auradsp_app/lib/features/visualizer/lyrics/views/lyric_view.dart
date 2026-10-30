import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/theme.dart';
import '../../../../core/ui_helpers.dart';
import '../models/lyric_models.dart';

/// Immersive synchronized lyrics viewer with smooth spring-physics scrolling
class LyricView extends StatefulWidget {
  final LyricDocument document;
  final int activeIndex;
  final bool showTranslation;
  final ValueChanged<int>? onLineTap;

  /// 悬停行右侧“校准”入口：点击后把该行对齐到当前播放位置
  final ValueChanged<int>? onLineCalibrate;

  const LyricView({
    super.key,
    required this.document,
    required this.activeIndex,
    this.showTranslation = true,
    this.onLineTap,
    this.onLineCalibrate,
  });

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _lineKeys = [];
  int? _pendingScrollIndex;
  int? _lastScrolledIndex;

  @override
  void initState() {
    super.initState();
    _rebuildKeys();
  }

  @override
  void didUpdateWidget(LyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.document.lines.length != _lineKeys.length) {
      _rebuildKeys();
    }
    if (widget.activeIndex != oldWidget.activeIndex && widget.activeIndex >= 0) {
      _scheduleScrollToActiveLine();
    }
  }

  void _rebuildKeys() {
    _lineKeys.clear();
    for (var i = 0; i < widget.document.lines.length; i++) {
      _lineKeys.add(GlobalKey());
    }
  }

  /// 在布局完成后滚动，且同一目标行只排队一次：
  /// 避免在 build 阶段调用 ensureVisible，也避免高频行切换时叠加多条滚动动画。
  void _scheduleScrollToActiveLine() {
    final idx = widget.activeIndex;
    if (idx < 0 || idx >= _lineKeys.length) return;
    if (_pendingScrollIndex == idx) return;
    _pendingScrollIndex = idx;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingScrollIndex = null;
      _scrollToActiveLine();
    });
  }

  void _scrollToActiveLine() {
    final idx = widget.activeIndex;
    if (idx < 0 || idx >= _lineKeys.length) return;
    if (_lastScrolledIndex == idx) return;

    final key = _lineKeys[idx];
    final currentContext = key.currentContext;
    if (currentContext != null) {
      _lastScrolledIndex = idx;
      Scrollable.ensureVisible(
        currentContext,
        duration: const Duration(milliseconds: 340),
        curve: Curves.easeOutCubic,
        alignment: 0.45, // Keep active line slightly above vertical center
      );
    }
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).extension<AuraPalette>() ?? auraDark;

    if (widget.document.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lyrics_outlined, size: 36, color: p.textDim),
            const SizedBox(height: 12),
            Text(
              'No lyrics loaded',
              style: TextStyle(fontSize: 13, color: p.textDim),
            ),
          ],
        ),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final topPad = constraints.maxHeight * 0.35;
        final botPad = constraints.maxHeight * 0.45;

        return ListView.builder(
          controller: _scrollController,
          padding: EdgeInsets.fromLTRB(20, topPad, 20, botPad),
          physics: const BouncingScrollPhysics(),
          itemCount: widget.document.lines.length,
          itemBuilder: (context, index) {
            final line = widget.document.lines[index];
            final isActive = index == widget.activeIndex;

            return _LyricLineTile(
              key: _lineKeys[index],
              line: line,
              isActive: isActive,
              showTranslation: widget.showTranslation,
              onTap: () => widget.onLineTap?.call(index),
              onCalibrate: widget.onLineCalibrate == null
                  ? null
                  : () => widget.onLineCalibrate!(index),
            );
          },
        );
      },
    );
  }
}

class _LyricLineTile extends StatefulWidget {
  final LyricLine line;
  final bool isActive;
  final bool showTranslation;
  final VoidCallback onTap;
  final VoidCallback? onCalibrate;

  const _LyricLineTile({
    super.key,
    required this.line,
    required this.isActive,
    required this.showTranslation,
    required this.onTap,
    this.onCalibrate,
  });

  @override
  State<_LyricLineTile> createState() => _LyricLineTileState();
}

class _LyricLineTileState extends State<_LyricLineTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).extension<AuraPalette>() ?? auraDark;

    return MouseRegion(
      onEnter: (_) {
        if (widget.onCalibrate != null && !_hovered) {
          setState(() => _hovered = true);
        }
      },
      onExit: (_) {
        if (_hovered) setState(() => _hovered = false);
      },
      child: InkWell(
        onTap: widget.onTap,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        hoverColor: p.accent.withValues(alpha: 0.06),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 280),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Main lyric text
                  AnimatedDefaultTextStyle(
                    duration: const Duration(milliseconds: 280),
                    curve: Curves.easeOutCubic,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: widget.isActive ? 20 : 15,
                      fontWeight:
                          widget.isActive ? FontWeight.w700 : FontWeight.w400,
                      color: widget.isActive
                          ? p.text
                          : p.textDim.withValues(alpha: 0.45),
                      letterSpacing: 0.3,
                      height: 1.35,
                    ),
                    child: Text(widget.line.text),
                  ),

                  // Optional translation
                  if (widget.showTranslation &&
                      widget.line.translation != null) ...[
                    const SizedBox(height: 4),
                    AnimatedDefaultTextStyle(
                      duration: const Duration(milliseconds: 280),
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: widget.isActive ? 13 : 11,
                        fontWeight: FontWeight.w400,
                        color: widget.isActive
                            ? p.accent.withValues(alpha: 0.88)
                            : p.textDim.withValues(alpha: 0.3),
                        height: 1.25,
                      ),
                      child: Text(widget.line.translation!),
                    ),
                  ],
                ],
              ),

              // 悬停校准图标：浮在行右侧，不参与文本布局，出现时不挤动歌词
              if (widget.onCalibrate != null)
                Positioned(
                  right: 0,
                  top: 0,
                  bottom: 0,
                  child: Center(
                    child: AnimatedOpacity(
                      opacity: _hovered ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 140),
                      child: IgnorePointer(
                        ignoring: !_hovered,
                        child: Tooltip(
                          message: l10nOf(context).visualizerLyricsCalibrate,
                          child: IconButton(
                            icon: const Icon(
                              Icons.my_location_rounded,
                              size: 16,
                            ),
                            color: p.accent,
                            visualDensity: VisualDensity.compact,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 28,
                              minHeight: 28,
                            ),
                            onPressed: widget.onCalibrate,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
