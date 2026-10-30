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
 *   - styles/      : SpectrumBars, Oscilloscope, Goniometer, CyberGrid, PulseOrb,
 *                    FluidDynamics, ParticleTornado, GpuShader, Milkdrop, Atmosphere
 *   - views/       : VisualizerStage, VisualizerHud, VisualizerDrawer, VisualizerMeters, VisualizerDbScale
 */
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:window_manager/window_manager.dart';

import '../core/design.dart';
import '../core/error_sink.dart';
import '../core/nav.dart';
import '../core/path_memory.dart';
import '../core/state.dart';
import '../core/ui_helpers.dart';
import '../core/visualizer_types.dart';
import '../platform/platform_profile.dart';
import '../ui/path_picker_dialog.dart';
import 'chrome.dart';
import 'visualizer/lyrics/parsers/lrc_parser.dart';
import 'visualizer/lyrics/services/media_sync_service.dart';
import 'visualizer/views/visualizer_drawer_widgets.dart';
import 'visualizer/views/visualizer_meters.dart';
import 'visualizer/views/visualizer_stage.dart';

class VisualizerPage extends StatefulWidget {
  final AppModel model;
  const VisualizerPage({super.key, required this.model});

  @override
  State<VisualizerPage> createState() => _VisualizerPageState();
}

class _VisualizerPageState extends State<VisualizerPage> {
  /// 媒体同步服务：构造时带上配置里的歌词来源（预置在首次访问页面时创建）。
  late final MediaSyncService _mediaSync = MediaSyncService(
    lyricsSource: widget.model.visualizerConfig.value.lyricsSource,
  );
  bool _drawerOpen = false;
  VisualizerDisplayMode _displayMode = VisualizerDisplayMode.restore;
  final FocusNode _focusNode = FocusNode();

  /// 帮助问号可见性控制器：本页不走 PageScaffold，必须自建 Scope，
  /// 否则移动端 InfoBadge 因找不到 Scope 而永久不可见（审查发现）。
  final HelpVisibilityController _helpController = HelpVisibilityController();

  /// 配置变化监听所需的镜像（仅用于识别“歌词开关/歌词来源”翻转）
  bool _lyricsEnabled = false;
  LyricsSource _lastLyricsSource = LyricsSource.auto;

  /// 播放状态的选择性监听：模型每帧都会 notify（频谱/电平），
  /// 若直接 ListenableBuilder(model) 会让整个舞台子树以音频帧率重建，
  /// 造成 UI 不跟手与大量短命对象。此处只在“是否在播放”翻转时触发重建。
  final ValueNotifier<bool> _playing = ValueNotifier<bool>(false);

  /// OS 全屏请求串行化：快速连点时保证「最后一次意图」最终生效。
  Future<void> _fullscreenChain = Future<void>.value();

  @override
  void initState() {
    super.initState();
    // 页面保活在 IndexedStack 中：切到其它页时兜底复位，避免整应用停留在沉浸态。
    widget.model.visiblePage.addListener(_onVisiblePageChanged);
    _playing.value = widget.model.liveSpectrum;
    widget.model.addListener(_onModelChanged);
    final cfg = widget.model.visualizerConfig.value;
    _lyricsEnabled = cfg.showLyrics;
    _lastLyricsSource = cfg.lyricsSource;
    widget.model.visualizerConfig.addListener(_onVisualizerConfigChanged);
    // 页面初始即为可视页时（如应用直接恢复到可视化页）不会触发变更回调，这里兜底启动
    if (widget.model.visiblePage.value == AppPage.visualizer) {
      _mediaSync.startAutoSync();
    }
  }

  @override
  void dispose() {
    widget.model.visiblePage.removeListener(_onVisiblePageChanged);
    widget.model.removeListener(_onModelChanged);
    widget.model.visualizerConfig.removeListener(_onVisualizerConfigChanged);
    _playing.dispose();
    if (_displayMode == VisualizerDisplayMode.immersive) {
      widget.model.visualizerImmersive.value = false;
      _queueSystemFullscreen(false);
    }
    _focusNode.dispose();
    _helpController.dispose();
    _mediaSync.dispose();
    super.dispose();
  }

  /// 模型通知：仅当“是否在播放”变化时才驱动舞台重建
  void _onModelChanged() {
    final playing = widget.model.liveSpectrum;
    if (playing != _playing.value) {
      _playing.value = playing;
    }
  }

  /// 可视化配置变化：歌词开关翻转 → 启停媒体监听；歌词来源切换 → 换源重试。
  /// 这样预设载入 / 会话恢复 / 抽屉修改三条路径都走同一反应逻辑。
  void _onVisualizerConfigChanged() {
    final cfg = widget.model.visualizerConfig.value;
    if (cfg.lyricsSource != _lastLyricsSource) {
      _lastLyricsSource = cfg.lyricsSource;
      _mediaSync.setLyricsSource(cfg.lyricsSource);
    }
    if (cfg.showLyrics != _lyricsEnabled) {
      _lyricsEnabled = cfg.showLyrics;
      if (cfg.showLyrics) {
        _mediaSync.startAutoSync();
      } else {
        _mediaSync.stopAutoSync();
      }
    }
  }

  void _onVisiblePageChanged() {
    if (!mounted) return;
    if (widget.model.visiblePage.value == AppPage.visualizer) {
      // 首次进入页面才启动系统媒体监听，避免应用启动即拉起常驻进程
      _mediaSync.startAutoSync();
      // 回到页面时恢复键盘焦点，F11 / Esc 立即可用
      _focusNode.requestFocus();
      return;
    }
    // 离开页面即停媒体监听：旧实现只在关闭歌词时停订阅，切页后
    // SMTC PowerShell 子进程仍每秒轮询（审查发现的后台空转）。
    _mediaSync.stopAutoSync();
    if (_displayMode != VisualizerDisplayMode.restore) {
      _applyDisplayMode(VisualizerDisplayMode.restore);
    }
    if (_drawerOpen) {
      setState(() => _drawerOpen = false);
    }
  }

  void _toggleLyrics() {
    final cfg = widget.model.visualizerConfig.value;
    // 启停媒体监听由 _onVisualizerConfigChanged 统一响应（预设/会话同路径）
    widget.model.setVisualizerConfig(cfg.copyWith(showLyrics: !cfg.showLyrics));
  }

  /// 手动加载本地 LRC 文件（在线检索无结果或离线曲目时的兜底）。
  ///
  /// R4（2026-10-31）：统一走 AuraPathPickerDialog——项目铁律要求所有
  /// 文件/目录选择都必须经这个专用 UI（支持键入路径、系统选择器、扩展名
  /// 校验与路径记忆），不得在页面里直接用 file_selector。
  Future<void> _pickLocalLrc() async {
    final l = l10nOf(context);
    final path = await AuraPathPickerDialog.show(
      context,
      title: l.visualizerLyricsPickLocalTitle,
      prompt: l.visualizerLyricsPickLocalPrompt,
      allowedExtensions: const ['lrc'],
      memorySlot: PathMemory.slotLyricsLrc,
      confirmLabel: l.visualizerLyricsPickLocal,
    );
    if (path == null || path.isEmpty) return;

    try {
      final content = await File(path).readAsString();
      final doc = LrcParser.parse(content);
      if (doc.isNotEmpty) {
        _mediaSync.loadLyricDocument(doc);
      }
    } catch (e, st) {
      // 文件读取失败属可预期路径，留痕后静默回退
      swallow(e, st);
    }
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
      builder: (_, page, _) => ValueListenableBuilder<VisualizerConfig>(
        valueListenable: widget.model.visualizerConfig,
        builder: (_, config, _) => _buildBody(
          context,
          active: page == AppPage.visualizer,
          config: config,
        ),
      ),
    );
  }

  Widget _buildBody(
    BuildContext context, {
    required bool active,
    required VisualizerConfig config,
  }) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final expanded = _displayMode.isExpanded;

    return HelpVisibilityScope(
      controller: _helpController,
      child: NotificationListener<ScrollNotification>(
        // 移动端：滚动会话内让 InfoBadge 短暂可见（桌面端恒可见，无副作用）
        onNotification: (_) {
          _helpController.recordScroll();
          return false;
        },
        child: KeyboardListener(
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
                                        VisualizerPeakReadout(
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
                        child: ValueListenableBuilder<bool>(
                          valueListenable: _playing,
                          builder: (_, playing, _) => VisualizerStage(
                            playing: playing,
                            spectrum: widget.model.spectrum,
                            levelL: widget.model.levelL,
                            levelR: widget.model.levelR,
                            config: config,
                            displayMode: _displayMode,
                            onStyleChanged: (st) => widget.model
                                .setVisualizerConfig(config.copyWith(style: st)),
                            onToggleStageMode: _toggleStageMode,
                            onDisplayModeChanged: _applyDisplayMode,
                            onToggleLyrics: _toggleLyrics,
                            onOpenDrawer: _openDrawer,
                            onOpenLocalLrc: _pickLocalLrc,
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
          VisualizerDrawerOverlay(
            open: _drawerOpen,
            config: config,
            onConfigChanged: (newCfg) =>
                widget.model.setVisualizerConfig(newCfg),
            onClose: _closeDrawer,
            onResetToDefaults: () =>
                widget.model.setVisualizerConfig(const VisualizerConfig()),
          ),
            ],
          ),
        ),
      ),
    );
  }
}
