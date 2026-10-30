/*
 * visualizer_page.dart — 可视化聚合入口页：多风格渲染舞台 + 三档全屏 + 实时声学仪表
 *
 * 显示档位（单一状态机，替代旧的「舞台最大化 + OS 全屏」双布尔）：
 *   restore   还原：页头 + 舞台 + 电平表，保留应用导航与顶栏
 *   stage     软件全屏：舞台铺满应用窗口，隐藏页头/电平表，窗口不变
 *   immersive 仅视效全屏：再隐藏左栏导航与顶栏（shell 协作），桌面端进入 OS 全屏
 *
 * 快捷键：F11 循环三档；Esc 逐级回退（沉浸 → 软件全屏 → 还原）。
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
import '../core/error_sink.dart';
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
  VisualizerDisplayMode _displayMode = VisualizerDisplayMode.restore;
  final FocusNode _focusNode = FocusNode();

  /// OS 全屏请求串行化：快速连点时保证「最后一次意图」最终生效。
  Future<void> _fullscreenChain = Future<void>.value();

  @override
  void initState() {
    super.initState();
    // 页面保活在 IndexedStack 中：切到其它页时兜底复位，避免整应用停留在沉浸态。
    widget.model.visiblePage.addListener(_onVisiblePageChanged);
  }

  @override
  void dispose() {
    widget.model.visiblePage.removeListener(_onVisiblePageChanged);
    if (_displayMode == VisualizerDisplayMode.immersive) {
      widget.model.visualizerImmersive.value = false;
      _queueSystemFullscreen(false);
    }
    _focusNode.dispose();
    _mediaSync.dispose();
    super.dispose();
  }

  void _onVisiblePageChanged() {
    if (!mounted) return;
    if (widget.model.visiblePage.value == AppPage.visualizer) {
      // 回到页面时恢复键盘焦点，F11 / Esc 立即可用
      _focusNode.requestFocus();
      return;
    }
    if (_displayMode != VisualizerDisplayMode.restore) {
      _applyDisplayMode(VisualizerDisplayMode.restore);
    }
    if (_drawerOpen) {
      setState(() => _drawerOpen = false);
    }
  }

  void _toggleLyrics() {
    setState(() {
      _config = _config.copyWith(showLyrics: !_config.showLyrics);
    });
  }

  /// 应用显示档位：页面布局 + shell 沉浸标志 + OS 窗口全屏三者同步。
  void _applyDisplayMode(VisualizerDisplayMode mode) {
    if (mode == _displayMode) return;
    final wasImmersive = _displayMode == VisualizerDisplayMode.immersive;
    final isImmersive = mode == VisualizerDisplayMode.immersive;

    setState(() => _displayMode = mode);

    if (isImmersive != wasImmersive) {
      widget.model.visualizerImmersive.value = isImmersive;
      _queueSystemFullscreen(isImmersive);
    }
  }

  void _cycleDisplayMode() {
    _applyDisplayMode(switch (_displayMode) {
      VisualizerDisplayMode.restore => VisualizerDisplayMode.stage,
      VisualizerDisplayMode.stage => VisualizerDisplayMode.immersive,
      VisualizerDisplayMode.immersive => VisualizerDisplayMode.restore,
    });
  }

  /// 舞台双击：还原 ↔ 软件全屏；沉浸档双击回到软件全屏（保留 OS 全屏）。
  void _toggleStageMode() {
    _applyDisplayMode(
      _displayMode == VisualizerDisplayMode.stage
          ? VisualizerDisplayMode.restore
          : VisualizerDisplayMode.stage,
    );
  }

  void _queueSystemFullscreen(bool enable) {
    _fullscreenChain = _fullscreenChain
        .then((_) async {
          if (PlatformProfile.supportsWindowManagement) {
            await windowManager.setFullScreen(enable);
          } else {
            await SystemChrome.setEnabledSystemUIMode(
              enable ? SystemUiMode.immersiveSticky : SystemUiMode.edgeToEdge,
            );
          }
        })
        .catchError((Object e, StackTrace st) => swallow(e, st));
  }

  void _openDrawer() {
    _focusNode.requestFocus();
    setState(() => _drawerOpen = true);
  }

  void _closeDrawer() {
    setState(() => _drawerOpen = false);
  }

  void _handleKeyEvent(KeyEvent event) {
    if (event is! KeyDownEvent) return;
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.f11) {
      _cycleDisplayMode();
    } else if (key == LogicalKeyboardKey.escape) {
      if (_drawerOpen) {
        _closeDrawer();
      } else if (_displayMode == VisualizerDisplayMode.immersive) {
        _applyDisplayMode(VisualizerDisplayMode.stage);
      } else if (_displayMode == VisualizerDisplayMode.stage) {
        _applyDisplayMode(VisualizerDisplayMode.restore);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AppPage>(
      valueListenable: widget.model.visiblePage,
      builder: (_, page, _) =>
          _buildBody(context, active: page == AppPage.visualizer),
    );
  }

  Widget _buildBody(BuildContext context, {required bool active}) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final expanded = _displayMode.isExpanded;

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

          // 主内容层：标准工作区 ↔ 铺满；页头与电平表随档位平滑折叠
          Positioned.fill(
            child: AnimatedPadding(
              duration: AuraDur.base,
              curve: AuraCurve.emphasized,
              padding: expanded
                  ? EdgeInsets.zero
                  : EdgeInsets.fromLTRB(
                      context.responsivePageX,
                      AuraSpace.pageTop,
                      context.responsivePageX,
                      AuraSpace.pageBottom,
                    ),
              child: Center(
                child: ConstrainedBox(
                  constraints: BoxConstraints(
                    maxWidth: expanded
                        ? double.infinity
                        : context.responsiveMaxW,
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // 顶栏标头（非还原档折叠为 0 高）
                      AnimatedSwitcher(
                        duration: AuraDur.base,
                        switchInCurve: AuraCurve.emphasized,
                        switchOutCurve: AuraCurve.emphasized,
                        transitionBuilder: (child, animation) => SizeTransition(
                          sizeFactor: animation,
                          alignment: Alignment.topCenter,
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        ),
                        child: expanded
                            ? const SizedBox(
                                key: ValueKey('visualizer-header-hidden'),
                                width: double.infinity,
                              )
                            : Column(
                                key: const ValueKey('visualizer-header'),
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
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
                                          icon: const Icon(
                                            Icons.tune_rounded,
                                            size: 20,
                                          ),
                                          color: p.textDim,
                                          tooltip: l.visualizerSettingsTip,
                                          onPressed: _openDrawer,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: AuraSpace.xl),
                                ],
                              ),
                      ),

                      // 核心视效舞台（三档共用同一实例，状态与动画不重建）
                      Expanded(
                        child: ListenableBuilder(
                          listenable: widget.model,
                          builder: (_, _) => VisualizerStage(
                            playing: widget.model.liveSpectrum,
                            spectrum: widget.model.spectrum,
                            levelL: widget.model.levelL,
                            levelR: widget.model.levelR,
                            config: _config,
                            displayMode: _displayMode,
                            onStyleChanged: (st) => setState(
                              () => _config = _config.copyWith(style: st),
                            ),
                            onToggleStageMode: _toggleStageMode,
                            onDisplayModeChanged: _applyDisplayMode,
                            onToggleLyrics: _toggleLyrics,
                            onOpenDrawer: _openDrawer,
                            mediaSync: _mediaSync,
                            emptyText: l.noAudio,
                            active: active,
                          ),
                        ),
                      ),

                      // 底部声学测量电平（非还原档折叠为 0 高）
                      AnimatedSwitcher(
                        duration: AuraDur.base,
                        switchInCurve: AuraCurve.emphasized,
                        switchOutCurve: AuraCurve.emphasized,
                        transitionBuilder: (child, animation) => SizeTransition(
                          sizeFactor: animation,
                          alignment: Alignment.bottomCenter,
                          child: FadeTransition(
                            opacity: animation,
                            child: child,
                          ),
                        ),
                        child: expanded
                            ? const SizedBox(
                                key: ValueKey('visualizer-meters-hidden'),
                                width: double.infinity,
                              )
                            : Padding(
                                key: const ValueKey('visualizer-meters'),
                                padding: const EdgeInsets.only(
                                  top: AuraSpace.xl,
                                ),
                                child: VisualizerMeters(
                                  model: widget.model,
                                  active: active,
                                ),
                              ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),

          // 浮动参数抽屉：淡入 + 右侧滑入，关闭时反向过渡
          Positioned.fill(
            child: AnimatedSwitcher(
              duration: AuraDur.base,
              switchInCurve: AuraCurve.emphasized,
              switchOutCurve: Curves.easeInCubic,
              layoutBuilder: (current, previous) => Stack(
                fit: StackFit.expand,
                children: [...previous, ?current],
              ),
              transitionBuilder: (child, animation) => FadeTransition(
                opacity: animation,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0.08, 0),
                    end: Offset.zero,
                  ).animate(animation),
                  child: child,
                ),
              ),
              child: _drawerOpen
                  ? Stack(
                      key: const ValueKey('visualizer-drawer'),
                      children: [
                        Positioned.fill(
                          child: GestureDetector(
                            onTap: _closeDrawer,
                            child: ColoredBox(
                              color: Colors.black.withValues(alpha: 0.45),
                            ),
                          ),
                        ),
                        Align(
                          alignment: Alignment.centerRight,
                          child: VisualizerConfigDrawer(
                            config: _config,
                            onConfigChanged: (newCfg) =>
                                setState(() => _config = newCfg),
                            onClose: _closeDrawer,
                            onResetToDefaults: () => setState(
                              () => _config = const VisualizerConfig(),
                            ),
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(
                      key: ValueKey('visualizer-drawer-closed'),
                    ),
            ),
          ),
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
