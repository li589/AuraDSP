import 'package:flutter/material.dart';

import '../../../../core/theme.dart';
import '../models/lyric_models.dart';

/// Immersive synchronized lyrics viewer with smooth spring-physics scrolling
class LyricView extends StatefulWidget {
  final LyricDocument document;
  final int activeIndex;
  final bool showTranslation;
  final ValueChanged<int>? onLineTap;

  const LyricView({
    super.key,
    required this.document,
    required this.activeIndex,
    this.showTranslation = true,
    this.onLineTap,
  });

  @override
  State<LyricView> createState() => _LyricViewState();
}

class _LyricViewState extends State<LyricView> {
  final ScrollController _scrollController = ScrollController();
  final List<GlobalKey> _lineKeys = [];

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
      _scrollToActiveLine();
    }
  }

  void _rebuildKeys() {
    _lineKeys.clear();
    for (var i = 0; i < widget.document.lines.length; i++) {
      _lineKeys.add(GlobalKey());
    }
  }

  void _scrollToActiveLine() {
    final idx = widget.activeIndex;
    if (idx < 0 || idx >= _lineKeys.length) return;

    final key = _lineKeys[idx];
    final currentContext = key.currentContext;
    if (currentContext != null) {
      Scrollable.ensureVisible(
        currentContext,
        duration: const Duration(milliseconds: 380),
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
            );
          },
        );
      },
    );
  }
}

class _LyricLineTile extends StatelessWidget {
  final LyricLine line;
  final bool isActive;
  final bool showTranslation;
  final VoidCallback onTap;

  const _LyricLineTile({
    super.key,
    required this.line,
    required this.isActive,
    required this.showTranslation,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final p = Theme.of(context).extension<AuraPalette>() ?? auraDark;

    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(AuraRadius.sm),
      hoverColor: p.accent.withValues(alpha: 0.06),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 280),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Main lyric text
            AnimatedDefaultTextStyle(
              duration: const Duration(milliseconds: 280),
              curve: Curves.easeOutCubic,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: isActive ? 20 : 15,
                fontWeight: isActive ? FontWeight.w700 : FontWeight.w400,
                color: isActive ? p.text : p.textDim.withValues(alpha: 0.45),
                letterSpacing: 0.3,
                height: 1.35,
              ),
              child: Text(line.text),
            ),

            // Optional translation
            if (showTranslation && line.translation != null) ...[
              const SizedBox(height: 4),
              AnimatedDefaultTextStyle(
                duration: const Duration(milliseconds: 280),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: isActive ? 13 : 11,
                  fontWeight: FontWeight.w400,
                  color: isActive
                      ? p.accent.withValues(alpha: 0.88)
                      : p.textDim.withValues(alpha: 0.3),
                  height: 1.25,
                ),
                child: Text(line.translation!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
