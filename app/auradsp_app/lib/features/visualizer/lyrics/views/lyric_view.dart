import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';

import '../../../../core/theme.dart';
import '../../../../core/ui_helpers.dart';
import '../models/lyric_models.dart';

/// Immersive synchronized lyrics viewer with smooth spring-physics scrolling.
///
/// 2026-10-31 修订：
/// - 当前行离开可视区时自动归位（手动滚动松手后也会延迟回到当前行）；
/// - 浅色主题提升非当前行对比度（此前 textDim 低透明度在米色底上接近不可读）；
/// - 滚动条只在鼠标悬停右侧边条时出现并可拖动，滚动时不再闪现。
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

  /// 已知行锚点：index → getOffsetToReveal(0.45) 偏移。
  /// ListView 是惰性构建的，滚远后当前行的 element 可能不存在，
  /// 此时用最近已知锚点 + 平均行高估算目标位置（滚过去后再精确校正）。
  final Map<int, double> _knownOffsets = {};

  /// 用户手动滚动松手后延迟归位（避免与滚动手感打架）
  Timer? _returnTimer;
  bool _userDragging = false;

  /// 右侧滚动条条带 hover 态（仅此时显示/可拖）
  bool _barHovered = false;

  @override
  void initState() {
    super.initState();
    _rebuildKeys();
  }

  @override
  void didUpdateWidget(LyricView oldWidget) {
    super.didUpdateWidget(oldWidget);
    final docChanged = widget.document.lines.length != _lineKeys.length;
    if (docChanged) {
      _rebuildKeys();
    }
    if (docChanged ||
        widget.activeIndex != oldWidget.activeIndex && widget.activeIndex >= 0) {
      _scheduleScrollToActiveLine();
    }
  }

  void _rebuildKeys() {
    _lineKeys.clear();
    _knownOffsets.clear();
    for (var i = 0; i < widget.document.lines.length; i++) {
      _lineKeys.add(GlobalKey());
    }
  }

  /// 在布局完成后检查当前行位置，且同一目标行只排队一次，
  /// 避免在 build 阶段滚动、也避免高频行切换时叠加多条滚动动画。
  void _scheduleScrollToActiveLine({bool force = false}) {
    final idx = widget.activeIndex;
    if (idx < 0 || idx >= _lineKeys.length) return;
    if (!force && _pendingScrollIndex == idx) return;
    _pendingScrollIndex = idx;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _pendingScrollIndex = null;
      _ensureActiveVisible(force: force);
    });
  }

  /// 记录当前所有已构建行的锚点偏移（低频、仅在滚动结束时调用）。
  void _recordKnownOffsets() {
    for (var i = 0; i < _lineKeys.length; i++) {
      final offset = _offsetOfLine(i);
      if (offset != null) _knownOffsets[i] = offset;
    }
  }

  /// 单行的精确目标偏移；该行未被构建（滚太远）时返回 null。
  double? _offsetOfLine(int idx) {
    if (idx < 0 || idx >= _lineKeys.length) return null;
    final currentContext = _lineKeys[idx].currentContext;
    if (currentContext == null) return null;
    final box = currentContext.findRenderObject();
    if (box is! RenderBox || !box.hasSize) return null;
    try {
      return RenderAbstractViewport.of(box)
          .getOffsetToReveal(box, 0.45)
          .offset;
    } catch (e) {
      // swallow: 布局尚未就绪/无视口祖先时查询不可用，等待下一帧即可
      return null;
    }
  }

  /// 当前行的目标偏移：优先精确值；行未被构建时用最近锚点 + 平均行高估算。
  double? _activeLineTargetOffset() {
    final idx = widget.activeIndex;
    if (idx < 0 || idx >= _lineKeys.length) return null;

    final exact = _offsetOfLine(idx);
    if (exact != null) {
      _knownOffsets[idx] = exact;
      return exact;
    }
    if (!_scrollController.hasClients) return null;

    // 1. 有已知锚点：取最近的一行，按相邻锚点差值估计每行高度。
    if (_knownOffsets.isNotEmpty) {
      int nearest = -1;
      var best = double.infinity;
      for (final k in _knownOffsets.keys) {
        final d = (k - idx).abs().toDouble();
        if (d < best) {
          best = d;
          nearest = k;
        }
      }
      if (nearest >= 0) {
        final keys = _knownOffsets.keys.toList()..sort();
        var perLine = 36.0;
        if (keys.length >= 2) {
          final a = keys.first;
          final b = keys.last;
          final span = (b - a).abs();
          if (span > 0) {
            perLine = ((_knownOffsets[b]! - _knownOffsets[a]!) / span).abs();
          }
        }
        if (perLine < 12 || perLine > 160 || !perLine.isFinite) perLine = 36.0;
        return _knownOffsets[nearest]! + (idx - nearest) * perLine;
      }
    }

    // 2. 完全无锚点（首次即滚很远）：按索引比例映射到可滚动范围。
    final pos = _scrollController.position;
    final max = pos.maxScrollExtent;
    if (!max.isFinite || max <= 0 || _lineKeys.length <= 1) return null;
    return max * (idx / (_lineKeys.length - 1));
  }

  /// 当前行已离开可视区（或 [force] 时无条件）就把列表滚回当前行。
  ///
  /// 这正是“跟踪行不在屏幕歌词范围内时不会自动归位”的修复点：旧实现用
  /// `_lastScrolledIndex == idx` 直接跳过，一旦用户手动滚走、或同一行停留
  /// 时间很长，指针就不再跟随。
  void _ensureActiveVisible({bool force = false}) {
    if (!mounted || !_scrollController.hasClients) return;
    final target = _activeLineTargetOffset();
    if (target == null) return;

    final pos = _scrollController.position;
    final max = pos.maxScrollExtent;
    final clamped = target.clamp(pos.minScrollExtent, max.isFinite ? max : target);

    // 容差取视口的 30%：当前行位于上/下三分之一附近时不打扰用户；
    // 一旦真正离开可视区（或被要求强制归位）立即平滑滚回。
    final tolerance = pos.viewportDimension * 0.30;
    if (!force && (pos.pixels - clamped).abs() <= tolerance) return;

    final usedExact = _offsetOfLine(widget.activeIndex) != null;
    _scrollController.animateTo(
      clamped,
      duration: const Duration(milliseconds: 340),
      curve: Curves.easeOutCubic,
    );

    // 估算落点：动画结束后当前行已被构建，再做一次精确校正（只校正一次）。
    if (!usedExact) {
      Timer(const Duration(milliseconds: 420), () {
        if (!mounted || _userDragging) return;
        _ensureActiveVisible();
      });
    }
  }

  /// 用户手动滚动结束：延迟一小段时间后，若当前行已不在可视区则归位。
  bool _onScrollNotification(ScrollNotification n) {
    if (n is ScrollStartNotification && n.dragDetails != null) {
      _userDragging = true;
      _returnTimer?.cancel();
    } else if (n is ScrollEndNotification) {
      final wasDragging = _userDragging;
      _userDragging = false;
      // 滚动结束顺手刷新行锚点，供后续“滚远后估算归位”使用
      _recordKnownOffsets();
      if (wasDragging) {
        _returnTimer?.cancel();
        _returnTimer = Timer(const Duration(milliseconds: 900), () {
          if (!mounted || _userDragging) return;
          _ensureActiveVisible();
        });
      }
    }
    return false;
  }

  @override
  void dispose() {
    _returnTimer?.cancel();
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

        // 滚动条显隐：鼠标进入右侧 14px 条带才淡入，离开立即淡出。
        // 用整块 MouseRegion 追踪指针（不额外盖一层可命中区域，避免挡住
        // 歌词行的点击），Scrollbar 的 thumb 自己在右侧绘制。
        return MouseRegion(
          onHover: (event) {
            final nearRightEdge =
                event.localPosition.dx >= constraints.maxWidth - 14;
            if (nearRightEdge != _barHovered) {
              setState(() => _barHovered = nearRightEdge);
            }
          },
          onExit: (_) {
            if (_barHovered) setState(() => _barHovered = false);
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: _onScrollNotification,
            child: ScrollbarTheme(
              data: ScrollbarThemeData(
                thickness: const WidgetStatePropertyAll(6),
                radius: const Radius.circular(3),
                crossAxisMargin: 2,
                mainAxisMargin: 4,
                trackColor: const WidgetStatePropertyAll(Colors.transparent),
                // 未 hover 时 thumb 完全透明：滚动过程中也不会闪现滚动条。
                thumbColor: WidgetStatePropertyAll(
                  _barHovered
                      ? p.textDim.withValues(alpha: 0.55)
                      : Colors.transparent,
                ),
              ),
              child: Scrollbar(
                controller: _scrollController,
                thumbVisibility: true,
                interactive: _barHovered,
                // 关闭桌面默认的“滚动即闪现”滚动条，只保留上面这条。
                child: ScrollConfiguration(
                  behavior:
                      ScrollConfiguration.of(context).copyWith(scrollbars: false),
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: EdgeInsets.fromLTRB(20, topPad, 20, botPad),
                    physics: const BouncingScrollPhysics(),
                    // 放大缓存：用户滚开数屏后当前行仍可能保留在树里，
                    // 精确归位（getOffsetToReveal）不必依赖估算。
                    scrollCacheExtent:
                        const ScrollCacheExtent.pixels(4000),
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
                  ),
                ),
              ),
            ),
          ),
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
    // 对比度（2026-10-31）：浅色主题下 textDim(#6E6A60) 再叠低透明度会
    // 与米色底融成一片。改为深色主题用低透明度、浅色主题用深色正文的
    // 高不透明度，保证“主次分明但清楚可读”。
    final inactiveTextColor = p.isDark
        ? p.textDim.withValues(alpha: 0.45)
        : p.text.withValues(alpha: 0.72);
    final inactiveTranslationColor = p.isDark
        ? p.textDim.withValues(alpha: 0.30)
        : p.textDim;

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
                      color: widget.isActive ? p.text : inactiveTextColor,
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
                            : inactiveTranslationColor,
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
