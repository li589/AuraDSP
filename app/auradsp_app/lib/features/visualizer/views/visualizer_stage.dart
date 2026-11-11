import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../../../core/design.dart';
import '../../../core/theme.dart';
import '../../../core/ui_helpers.dart';
import '../../../platform/adapters.dart';
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

class _VisualizerStageState extends State<VisualizerStage> {
  final PeakPhysicsEngine _peakEngine = PeakPhysicsEngine();
  final WaveformSynthesizer _waveformSynth = WaveformSynthesizer();

  Timer? _timelineTimer;
  Timer? _hudHideTimer;
  bool _hudVisible = true;

  /// 动画时间轴（秒）。必须是可监听量：父级 build 只在播放态/配置变化时
  /// 执行，若把裸 double 传进视口，时间会被冻结在最后一次 build 的数值
  /// （2026-10-31 审查发现的“背景不动/旋转跳变”根因）。
  final ValueNotifier<double> _time = ValueNotifier<double>(0.0);

  /// P0-1 静默门控：频谱能量与电平都低于门限并持续 [_silenceHold] 后判定
  /// 为“无声”，停掉时间轴——可见但无声的舞台不再产帧。门限 −60 dBFS /
  /// 0.001 归一化频谱（刻度见 VisualizerPeakReadout：peak*60−60 即 dBFS）。
  static const double _audibleLevelDb = -60.0;
  static const double _audibleBandPeak = 0.001;
  static const Duration _silenceHold = Duration(seconds: 2);
  bool _audible = false;
  Timer? _silenceTimer;

  /// 窗口可见性：最小化/托盘隐藏时与 `active` 一样参与时间轴门控。
  /// 隔离层（setVizSuspended）只停了 `viz` 事件推送，UI 侧此前仍会按
  /// 30 Hz 空转，两者必须一起停。
  bool _windowVisible = PlatformAdapters.instance.window.isVisible;

  /// 门控后的频谱代理：静默期不再向下游转发，数据驱动样式也不会因
  /// 零值帧重建/重绘。
  late final ValueNotifier<List<double>> _gatedSpectrum =
      ValueNotifier<List<double>>(widget.spectrum.value);

  @override
  void initState() {
    super.initState();
    widget.spectrum.addListener(_onSpectrumFrame);
    PlatformAdapters.instance.window.visibleListenable
        .addListener(_onWindowVisibility);
    // 默认静止：只有收到真实有声帧后时间轴才启动。
    _syncTimeline();
    _startHudTimer();
    GpuShaderService.instance.initialize().then((_) {
      if (mounted) setState(() {});
    });
  }

  /// 产帧节奏：固定 30 Hz 时间轴驱动，不再跟着 vsync 空跑。
  /// 旧实现用 AnimationController.repeat() + 每两帧推进一次，在 60 Hz 屏上
  /// 时间轴约 30 Hz，但在 144 Hz 屏上变成约 72 Hz（时间轴 2.3 倍速），
  /// 且 UI/Raster 线程按刷新率空转。改为按时间轴节奏定时产帧后，
  /// 任意刷新率下都稳定在 ~30 Hz。
  static const Duration _timelinePeriod = Duration(milliseconds: 33);
  static const double _timelineStep = 0.032;

  void _onTimelineTick() {
    if (!widget.active || !widget.playing || !_audible || !_windowVisible) {
      return;
    }
    _time.value += _timelineStep;
  }

  void _onWindowVisibility() {
    final visible = PlatformAdapters.instance.window.isVisible;
    if (visible == _windowVisible) return;
    _windowVisible = visible;
    _syncTimeline();
  }

  /// 时间轴启停的唯一入口：四者同时成立才产帧（页面可见、窗口可见、
  /// 引擎在播放、真实能量未静默）。
  void _syncTimeline() {
    final shouldRun =
        widget.active && widget.playing && _audible && _windowVisible;
    if (shouldRun) {
      _timelineTimer ??= Timer.periodic(_timelinePeriod, (_) {
        _onTimelineTick();
      });
    } else {
      _timelineTimer?.cancel();
      _timelineTimer = null;
    }
  }

  /// 频谱帧到达：用真实能量判定有声/静默（不改变 `viz` 事件本身，
  /// 只决定 UI 侧是否消费）。
  void _onSpectrumFrame() {
    if (!widget.active || !widget.playing) return;
    final bands = widget.spectrum.value;
    var peak = 0.0;
    for (final v in bands) {
      if (v > peak) peak = v;
    }
    final level = math.max(widget.levelL.value, widget.levelR.value);
    if (level > _audibleLevelDb || peak > _audibleBandPeak) {
      _markAudible();
    } else {
      _markSilenced();
    }
  }

  /// 有声帧：立即开闸（首个有声帧不等待防抖）。
  void _markAudible() {
    _silenceTimer?.cancel();
    _silenceTimer = null;
    _audible = true;
    _gatedSpectrum.value = widget.spectrum.value;
    _syncTimeline();
  }

  /// 静默帧：连续静默满 [_silenceHold] 才停，避免句间停顿/轻音误判。
  /// 若静默期间不再有新帧，Timer 到期同样会停，不依赖后续通知。
  void _markSilenced() {
    if (!_audible) {
      _syncTimeline();
      return;
    }
    // 迟滞窗口内继续转发静默帧，让柱体/峰值自然衰减到底再冻结，
    // 而不是停在最后一张有声帧上。
    _gatedSpectrum.value = widget.spectrum.value;
    _silenceTimer ??= Timer(_silenceHold, () {
      _silenceTimer = null;
      if (!mounted || !widget.active || !widget.playing) return;
      _audible = false;
      _syncTimeline();
    });
  }

  @override
  void didUpdateWidget(VisualizerStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.spectrum != widget.spectrum) {
      oldWidget.spectrum.removeListener(_onSpectrumFrame);
      widget.spectrum.addListener(_onSpectrumFrame);
      _gatedSpectrum.value = widget.spectrum.value;
    }
    final shouldRun = widget.active && widget.playing;
    final wasRunning = oldWidget.active && oldWidget.playing;
    if (shouldRun != wasRunning) {
      if (!shouldRun) {
        // 暂停/切页/无媒体：立刻关闸，不等待迟滞。
        _silenceTimer?.cancel();
        _silenceTimer = null;
        _audible = false;
      }
      _syncTimeline();
    }
    if (widget.playing != oldWidget.playing) {
      _syncHudWithPlayback();
    }
  }

  @override
  void dispose() {
    _hudHideTimer?.cancel();
    _timelineTimer?.cancel();
    _silenceTimer?.cancel();
    widget.spectrum.removeListener(_onSpectrumFrame);
    PlatformAdapters.instance.window.visibleListenable
        .removeListener(_onWindowVisibility);
    _gatedSpectrum.dispose();
    _time.dispose();
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
          LyricsSyncState.unsupported => l.visualizerLyricsUnsupported,
        };
        final statusHint = switch (state) {
          LyricsSyncState.idle || LyricsSyncState.noMedia =>
            l.visualizerLyricsNoMediaHint,
          LyricsSyncState.searching => l.visualizerLyricsSearchingHint,
          LyricsSyncState.ready => doc.artist?.isNotEmpty == true
              ? doc.artist!
              : l.visualizerLyricsReady,
          LyricsSyncState.notFound => l.visualizerLyricsNotFoundHint,
          LyricsSyncState.unsupported => l.visualizerLyricsUnsupportedHint,
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
              // 浅色底上视效色彩更亮，遮罩需要更实，否则歌词（尤其非当前行）对比不足
              colors: [
                p.bg.withValues(alpha: p.isDark ? 0.58 : 0.74),
                p.bg.withValues(alpha: p.isDark ? 0.8 : 0.9),
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
                          LyricsSyncState.unsupported =>
                            Icons.desktop_access_disabled_rounded,
                          LyricsSyncState.idle || LyricsSyncState.noMedia =>
                            Icons.music_off_rounded,
                        },
                        title: statusTitle,
                        hint: statusHint,
                      )
                    : LyricView(
                        document: doc,
                        activeIndex: sync.activeLineIndex.value,
                        showTranslation: widget.config.showTranslation,
                        onLineCalibrate: sync.calibrateToLine,
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
                  time: _time,
                  spectrum: _gatedSpectrum,
                  levelL: widget.levelL,
                  levelR: widget.levelR,
                  config: widget.config,
                  palette: palette,
                  peakEngine: _peakEngine,
                  waveformSynth: _waveformSynth,
                )
              else
                VisualizerIdlePlaceholder(emptyText: widget.emptyText),

              // 歌词层：开启后始终渲染；即使无歌词也显示曲目、检索状态与重试入口
              if (widget.config.showLyrics && widget.mediaSync != null)
                Positioned.fill(child: _buildLyricsLayer(context, p)),

              // 底部悬浮控制岛 HUD：独立 RepaintBoundary，HUD 自身淡入淡出
              // 不参与画布层的光栅，避免把静态/动态画面拖入重绘。
              Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: EdgeInsets.only(bottom: expanded ? 20 : 16),
                  child: RepaintBoundary(
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

/// 无歌词时的可见空态：只给状态说明。
///
/// 2026-10-31：移除居中的「重新获取 / 本地 LRC」按钮——歌词层右上角已有
/// 两个入口图标，空态再放按钮会在沉浸视效上造成干扰；未找到歌词时只保留
/// 一行干净的状态文案。
class _LyricsEmptyState extends StatelessWidget {
  final IconData icon;
  final bool busy;
  final String title;
  final String hint;

  const _LyricsEmptyState({
    required this.icon,
    required this.busy,
    required this.title,
    required this.hint,
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
          ],
        ),
      ),
    );
  }
}
