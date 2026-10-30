/*
 * visualizer_page.dart — 可视化聚合入口页：多风格渲染舞台 + 沉浸全屏 + 实时声学仪表
 *
 * 模块化拆分目录：
 *   - models/      : VisualizerConfig, VisualizerStyle, VisualizerColorTheme
 *   - controllers/ : PeakPhysicsEngine, WaveformSynthesizer
 *   - styles/      : SpectrumBars, Oscilloscope, Goniometer, CyberGrid, PulseOrb, GpuShader, Milkdrop
 *   - views/       : VisualizerStage, VisualizerHud, VisualizerDrawer, VisualizerMeters, VisualizerDbScale
 */
import 'dart:math' as math;
import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/design.dart';
import '../core/nav.dart';
import '../core/state.dart';
import '../core/ui_helpers.dart';
import '../platform/platform_profile.dart';
import 'chrome.dart';
import 'visualizer/lyrics/services/media_sync_service.dart';
import 'visualizer/models/visualizer_types.dart';
import 'visualizer/views/visualizer_drawer.dart';
import 'visualizer/views/visualizer_meters.dart';
import 'visualizer/views/visualizer_stage.dart';

class VisualizerPage extends StatefulWidget {
  final AppModel model;
  const VisualizerPage({super.key, required this.model});

  @override
  State<VisualizerPage> createState() => _VisualizerPageState();
}

class _VisualizerPageState extends State<VisualizerPage> {
  VisualizerConfig _config = const VisualizerConfig();
  final MediaSyncService _mediaSync = MediaSyncService();
  bool _drawerOpen = false;
  bool _isSystemFullscreen = false;
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    if (PlatformProfile.supportsWindowManagement) {
      windowManager.isFullScreen().then((isFull) {
        if (mounted) setState(() => _isSystemFullscreen = isFull);
      }).catchError((_) {});
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
    _mediaSync.dispose();
    super.dispose();
  }

  void _toggleLyrics() {
    setState(() {
      _config = _config.copyWith(showLyrics: !_config.showLyrics);
    });
  }

  void _toggleFullscreen() {
    setState(() {
      _config = _config.copyWith(isMaximized: !_config.isMaximized);
    });
  }

  Future<void> _toggleSystemFullscreen() async {
    if (PlatformProfile.supportsWindowManagement) {
      try {
        final isFull = await windowManager.isFullScreen();
        await windowManager.setFullScreen(!isFull);
        if (mounted) {
          setState(() => _isSystemFullscreen = !isFull);
        }
      } catch (_) {}
    } else {
      setState(() => _isSystemFullscreen = !_isSystemFullscreen);
      if (_isSystemFullscreen) {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      } else {
        SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
      }
    }
  }

  void _openDrawer() {
    setState(() => _drawerOpen = true);
  }

  void _closeDrawer() {
    setState(() => _drawerOpen = false);
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is KeyDownEvent) {
      if (event.logicalKey == LogicalKeyboardKey.f11) {
        _toggleSystemFullscreen();
      } else if (event.logicalKey == LogicalKeyboardKey.escape) {
        if (_isSystemFullscreen) {
          _toggleSystemFullscreen();
        } else if (_config.isMaximized) {
          _toggleFullscreen();
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppPage>(
      valueListenable: widget.model.visiblePage,
      builder: (_, page, _) => _buildBody(
        context,
        active: page == AppPage.visualizer,
      ),
    );
  }

  Widget _buildBody(BuildContext context, {required bool active}) {
    final p = paletteOf(context);
    final l = l10nOf(context);

    return KeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Stack(
        fit: StackFit.expand,
        children: [
          // 背景微动微晕
          AmbientSpectrum(spectrum: widget.model.spectrum, palette: p),
          if (p.isDark) const GrainOverlay(),

          // 主视效展示层：独占全屏或标准工作区
          if (_config.isMaximized)
            Positioned.fill(
              child: VisualizerStage(
                playing: widget.model.liveSpectrum,
                spectrum: widget.model.spectrum,
                levelL: widget.model.levelL,
                levelR: widget.model.levelR,
                config: _config,
                onStyleChanged: (st) =>
                    setState(() => _config = _config.copyWith(style: st)),
                onToggleFullscreen: _toggleFullscreen,
                onToggleSystemFullscreen: _toggleSystemFullscreen,
                isSystemFullscreen: _isSystemFullscreen,
                onToggleLyrics: _toggleLyrics,
                onOpenDrawer: _openDrawer,
                mediaSync: _mediaSync,
                emptyText: l.noAudio,
                active: active,
              ),
            )
          else
            Padding(
              padding: EdgeInsets.fromLTRB(
                context.responsivePageX,
                AuraSpace.pageTop,
                context.responsivePageX,
                AuraSpace.pageBottom,
              ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: context.responsiveMaxW),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 顶栏标头
                      PageHeader(
                        eyebrow: l.pageVisualizerEyebrow,
                        title: l.pageVisualizerTitle,
                        trailing: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            _PeakReadout(
                              spectrum: widget.model.spectrum,
                              label: l.peakLabel,
                              active: active,
                            ),
                            const SizedBox(width: AuraSpace.md),
                            IconButton(
                              icon: const Icon(Icons.tune_rounded, size: 20),
                              color: p.textDim,
                              tooltip: 'Visualizer Settings',
                              onPressed: _openDrawer,
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: AuraSpace.xl),

                      // 核心视效舞台
                      Expanded(
                        child: ListenableBuilder(
                          listenable: widget.model,
                          builder: (_, _) => VisualizerStage(
                            playing: widget.model.liveSpectrum,
                            spectrum: widget.model.spectrum,
                            levelL: widget.model.levelL,
                            levelR: widget.model.levelR,
                            config: _config,
                            onStyleChanged: (st) => setState(
                                () => _config = _config.copyWith(style: st)),
                            onToggleFullscreen: _toggleFullscreen,
                            onToggleSystemFullscreen: _toggleSystemFullscreen,
                            isSystemFullscreen: _isSystemFullscreen,
                            onToggleLyrics: _toggleLyrics,
                            onOpenDrawer: _openDrawer,
                            mediaSync: _mediaSync,
                            emptyText: l.noAudio,
                            active: active,
                          ),
                        ),
                      ),
                      const SizedBox(height: AuraSpace.xl),

                      // 底部声学测量电平
                      VisualizerMeters(
                        model: widget.model,
                        active: active,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // 浮动参数抽屉侧滑面板
          if (_drawerOpen) ...[
            GestureDetector(
              onTap: _closeDrawer,
              child: Container(
                color: Colors.black.withValues(alpha: 0.45),
              ),
            ),
            Align(
              alignment: Alignment.centerRight,
              child: VisualizerConfigDrawer(
                config: _config,
                onConfigChanged: (newCfg) =>
                    setState(() => _config = newCfg),
                onClose: _closeDrawer,
                onResetToDefaults: () =>
                    setState(() => _config = const VisualizerConfig()),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/* ---- 峰值读数（页面右上） ---- */
class _PeakReadout extends StatelessWidget {
  final ValueListenable<List<double>> spectrum;
  final String label;
  final bool active;
  const _PeakReadout({
    required this.spectrum,
    required this.label,
    this.active = true,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    if (!active) {
      return StatReadout(
        label: label,
        value: dbfsText(-90.0),
        unit: 'dBFS',
        size: 20,
        valueColor: p.textDim,
      );
    }
    return ValueListenableBuilder<List<double>>(
      valueListenable: spectrum,
      builder: (_, bands, _) {
        var peak = 0.0;
        for (final v in bands) {
          peak = math.max(peak, v);
        }
        final db = bands.isEmpty || peak <= 0 ? -90.0 : peak * 60 - 60;
        return StatReadout(
          label: label,
          value: dbfsText(db),
          unit: 'dBFS',
          size: 20,
          valueColor: db > -3 ? p.error : p.accent,
        );
      },
    );
  }
}
