import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../../../core/ui_helpers.dart';
import '../controllers/peak_physics_engine.dart';
import '../controllers/waveform_synthesizer.dart';
import '../lyrics/services/media_sync_service.dart';
import '../lyrics/views/lyric_view.dart';
import '../models/visualizer_themes.dart';
import '../models/visualizer_types.dart';
import '../shaders/gpu_shader_service.dart';
import 'visualizer_hud.dart';
import 'visualizer_viewport.dart';

/// 可视化核心舞台（支持多视效引擎切换、鼠标隐退交互、三档全屏沉浸）
class VisualizerStage extends StatefulWidget {
  final bool playing;
  final ValueListenable<List<double>> spectrum;
  final ValueListenable<double> levelL;
  final ValueListenable<double> levelR;
  final VisualizerConfig config;
  final VisualizerDisplayMode displayMode;
  final ValueChanged<VisualizerStyle> onStyleChanged;
  final VoidCallback onToggleStageMode;
  final ValueChanged<VisualizerDisplayMode> onDisplayModeChanged;
  final VoidCallback onToggleLyrics;
  final VoidCallback onOpenDrawer;
  final VoidCallback? onOpenLocalLrc;
  final MediaSyncService? mediaSync;
  final String emptyText;
  final bool active;

  const VisualizerStage({
    super.key,
    required this.playing,
    required this.spectrum,
    required this.levelL,
    required this.levelR,
    required this.config,
    this.displayMode = VisualizerDisplayMode.restore,
    required this.onStyleChanged,
    required this.onToggleStageMode,
    required this.onDisplayModeChanged,
    required this.onToggleLyrics,
    required this.onOpenDrawer,
    this.onOpenLocalLrc,
    this.mediaSync,
    required this.emptyText,
    required this.active,
  });

  @override
  State<VisualizerStage> createState() => _VisualizerStageState();
}

class _VisualizerStageState extends State<VisualizerStage>
    with SingleTickerProviderStateMixin {
  final PeakPhysicsEngine _peakEngine = PeakPhysicsEngine();
  final WaveformSynthesizer _waveformSynth = WaveformSynthesizer();

  late final AnimationController _animController;
  Timer? _hudHideTimer;
  bool _hudVisible = true;
  double _time = 0.0;

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..addListener(_onTick);

    if (widget.active) {
      _animController.repeat();
    }
    _startHudTimer();
    GpuShaderService.instance.initialize().then((_) {
      if (mounted) setState(() {});
    });
  }

  /// 每帧仅推进时间轴，不再 setState 重建整页（HUD/歌词等只在数据变化时重建）。
  void _onTick() {
    if (!widget.active) return;
    _time += 0.016;
  }

  @override
  void didUpdateWidget(VisualizerStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      if (widget.active) {
        if (!_animController.isAnimating) _animController.repeat();
      } else {
        _animController.stop();
      }
    }
    if (widget.playing != oldWidget.playing) {
      _syncHudWithPlayback();
    }
  }

  @override
  void dispose() {
    _hudHideTimer?.cancel();
    _animController.dispose();
    super.dispose();
  }

  void _onUserPointerActivity() {
    if (!_hudVisible) {
      setState(() => _hudVisible = true);
    }
    _startHudTimer();
  }

  void _startHudTimer() {
    _hudHideTimer?.cancel();
    // 静音/暂停时保持 HUD 常驻，用户随时可再次操作；仅播放中自动隐退。
    if (!widget.playing) return;
    _hudHideTimer = Timer(const Duration(seconds: 3), () {
      if (mounted && _hudVisible) {
        setState(() => _hudVisible = false);
      }
    });
  }

  void _syncHudWithPlayback() {
    _hudHideTimer?.cancel();
    if (!widget.playing) {
      if (!_hudVisible) setState(() => _hudVisible = true);
      return;
    }
    _startHudTimer();
  }

  void _resetPeaks() {
    _peakEngine.reset();
  }

  /// 手动重试：有曲目则重新检索歌词，无曲目则重启媒体会话监听。
  void _retryLyrics() {
    final sync = widget.mediaSync;
    if (sync == null) return;
    if (sync.currentTrack.value.hasContent) {
      unawaited(sync.retryLyrics());
    } else {
      sync.startAutoSync();
    }
  }

  /// 构建歌词叠加层：头部展示曲目/检索状态与操作，正文展示歌词或空态反馈。
  Widget _buildLyricsLayer(BuildContext context, AuraPalette p) {
    final sync = widget.mediaSync!;
    final l = l10nOf(context);

    return AnimatedBuilder(
      animation: Listenable.merge([
        sync.currentLyrics,
        sync.currentTrack,
        sync.activeLineIndex,
        sync.lyricsState,
      ]),
      builder: (context, _) {
        final doc = sync.currentLyrics.value;
        final track = sync.currentTrack.value;
        final state = sync.lyricsState.value;

        final statusTitle = switch (state) {
          LyricsSyncState.idle || LyricsSyncState.noMedia =>
            l.visualizerLyricsNoMedia,
          LyricsSyncState.searching => l.visualizerLyricsSearching,
          LyricsSyncState.ready => l.visualizerLyricsReady,
          LyricsSyncState.notFound => l.visualizerLyricsNotFound,
        };
        final statusHint = switch (state) {
          LyricsSyncState.idle || LyricsSyncState.noMedia =>
            l.visualizerLyricsNoMediaHint,
          LyricsSyncState.searching => l.visualizerLyricsSearchingHint,
          LyricsSyncState.ready => l.visualizerLyricsNotFoundHint,
          LyricsSyncState.notFound => l.visualizerLyricsNotFoundHint,
        };

        final docTitle = doc.title?.trim() ?? '';
        final docArtist = doc.artist?.trim() ?? '';
        final hasTrack = track.hasContent;

        final headerTitle = hasTrack
            ? track.title
            : (docTitle.isNotEmpty ? docTitle : statusTitle);
        final headerSubtitle = hasTrack
            ? [
                if (track.artist.isNotEmpty)
                  track.artist
                else if (track.album.isNotEmpty)
                  track.album,
                statusTitle,
              ].join(' · ')
            : (docTitle.isNotEmpty
                ? (docArtist.isNotEmpty
                    ? docArtist
                    : l.visualizerLyricsReady)
                : statusHint);

        final searching = state == LyricsSyncState.searching;

        return DecoratedBox(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                p.bg.withValues(alpha: 0.58),
                p.bg.withValues(alpha: 0.8),
              ],
            ),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  AuraSpace.lg,
                  AuraSpace.md,
                  AuraSpace.sm,
                  AuraSpace.sm,
                ),
                child: Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: searching
                          ? const CircularProgressIndicator(strokeWidth: 2)
                          : Icon(
                              Icons.lyrics_rounded,
                              size: 18,
                              color: state == LyricsSyncState.ready
                                  ? p.accent
                                  : p.textDim,
                            ),
                    ),
                    const SizedBox(width: AuraSpace.sm),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            headerTitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: p.text,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            headerSubtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 11.5, color: p.textDim),
                          ),
                        ],
                      ),
                    ),
                    _LyricsActionIcon(
                      icon: Icons.refresh_rounded,
                      tooltip: l.visualizerLyricsRetry,
                      color: p.textDim,
                      onPressed: searching ? null : _retryLyrics,
                    ),
                    if (widget.onOpenLocalLrc != null)
                      _LyricsActionIcon(
                        icon: Icons.folder_open_rounded,
                        tooltip: l.visualizerLyricsPickLocal,
                        color: p.textDim,
                        onPressed: widget.onOpenLocalLrc,
                      ),
                    _LyricsActionIcon(
                      icon: Icons.close_rounded,
                      tooltip: l.visualizerHideLyricsTip,
                      color: p.textDim,
                      onPressed: widget.onToggleLyrics,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: doc.isEmpty
                    ? _LyricsEmptyState(
                        busy: searching,
                        icon: switch (state) {
                          LyricsSyncState.searching => Icons.hourglass_top_rounded,
                          LyricsSyncState.notFound => Icons.search_off_rounded,
                          LyricsSyncState.ready => Icons.lyrics_outlined,
                          LyricsSyncState.idle || LyricsSyncState.noMedia =>
                            Icons.music_off_rounded,
                        },
                        title: statusTitle,
                        hint: statusHint,
                        retryLabel: l.visualizerLyricsRetry,
                        localLabel: l.visualizerLyricsPickLocal,
                        onRetry: _retryLyrics,
                        onPickLocal: widget.onOpenLocalLrc,
                      )
                    : LyricView(
                        document: doc,
                        activeIndex: sync.activeLineIndex.value,
                        showTranslation: widget.config.showTranslation,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final palette = VisualizerPalette.resolve(widget.config.colorTheme, p);
    final expanded = widget.displayMode.isExpanded;

    return MouseRegion(
      onHover: (_) => _onUserPointerActivity(),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _onUserPointerActivity,
        onDoubleTap: widget.onToggleStageMode,
        child: AnimatedContainer(
          duration: AuraDur.base,
          curve: AuraCurve.emphasized,
          decoration: BoxDecoration(
            color: p.bg,
            borderRadius: BorderRadius.circular(expanded ? 0 : AuraRadius.md),
            border: Border.all(
              color: widget.playing
                  ? palette.primary.withValues(alpha: 0.28)
                  : p.hairline,
              width: 1,
            ),
          ),
          clipBehavior: Clip.antiAlias,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // 主画面渲染视口
              if (widget.playing)
                VisualizerCanvasViewport(
                  animation: _animController,
                  spectrum: widget.spectrum,
                  levelL: widget.levelL,
                  levelR: widget.levelR,
                  config: widget.config,
                  palette: palette,
                  peakEngine: _peakEngine,
                  waveformSynth: _waveformSynth,
                  time: _time,
                )
              else
                VisualizerIdlePlaceholder(emptyText: widget.emptyText),

              // 歌词层：开启后始终渲染；即使无歌词也显示曲目、检索状态与重试入口
              if (widget.config.showLyrics && widget.mediaSync != null)
                Positioned.fill(child: _buildLyricsLayer(context, p)),

              // 底部悬浮控制岛 HUD
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: expanded ? 20 : 16),
                  child: VisualizerHud(
                    config: widget.config,
                    displayMode: widget.displayMode,
                    visible: _hudVisible,
                    onStyleChanged: (style) {
                      _onUserPointerActivity();
                      widget.onStyleChanged(style);
                    },
                    onDisplayModeChanged: (mode) {
                      _onUserPointerActivity();
                      widget.onDisplayModeChanged(mode);
                    },
                    onToggleLyrics: () {
                      _onUserPointerActivity();
                      widget.onToggleLyrics();
                    },
                    onOpenDrawer: () {
                      _onUserPointerActivity();
                      widget.onOpenDrawer();
                    },
                    onResetPeaks: () {
                      _onUserPointerActivity();
                      _resetPeaks();
                    },
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

/// 歌词层头部的小尺寸动作按钮（重试 / 本地 LRC / 关闭）
class _LyricsActionIcon extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color color;
  final VoidCallback? onPressed;

  const _LyricsActionIcon({
    required this.icon,
    required this.tooltip,
    required this.color,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: Icon(icon, size: 18),
      color: color,
      disabledColor: color.withValues(alpha: 0.35),
      tooltip: tooltip,
      visualDensity: VisualDensity.compact,
      padding: const EdgeInsets.all(6),
      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
      onPressed: onPressed,
    );
  }
}

/// 无歌词时的可见空态：状态说明 + 重新获取 / 本地 LRC 入口
class _LyricsEmptyState extends StatelessWidget {
  final IconData icon;
  final bool busy;
  final String title;
  final String hint;
  final String retryLabel;
  final String localLabel;
  final VoidCallback onRetry;
  final VoidCallback? onPickLocal;

  const _LyricsEmptyState({
    required this.icon,
    required this.busy,
    required this.title,
    required this.hint,
    required this.retryLabel,
    required this.localLabel,
    required this.onRetry,
    required this.onPickLocal,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(
          horizontal: AuraSpace.xl,
          vertical: AuraSpace.md,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: p.accent.withValues(alpha: 0.08),
                border: Border.all(
                  color: p.accent.withValues(alpha: 0.22),
                ),
              ),
              child: Center(
                child: busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Icon(
                        icon,
                        size: 26,
                        color: p.accent.withValues(alpha: 0.8),
                      ),
              ),
            ),
            const SizedBox(height: AuraSpace.md),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w600,
                color: p.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.45,
                color: p.textDim,
              ),
            ),
            const SizedBox(height: AuraSpace.lg),
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              alignment: WrapAlignment.center,
              children: [
                FilledButton.tonalIcon(
                  onPressed: busy ? null : onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 16),
                  label: Text(retryLabel),
                ),
                if (onPickLocal != null)
                  OutlinedButton.icon(
                    onPressed: onPickLocal,
                    icon: const Icon(Icons.folder_open_rounded, size: 16),
                    label: Text(localLabel),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
