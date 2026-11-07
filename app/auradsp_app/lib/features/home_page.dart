/*
 * home_page.dart — 主页：引擎状态大屏 + 频谱/电平
 *
 * 层级：频谱可视化（无序号） → hero 状态区（最大字号 + A/B 主操作）。
 * 测试音频源已移入设置页测试卡（为输入/输出设备选择预留位置）。
 * 注：右上引擎简报行已移除（信息冗余，设备信息见设置页设备卡）。
 */
import 'dart:async';

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/nav.dart';
import '../core/state.dart';
import '../core/theme.dart';
import '../platform/adapters.dart';
import 'chrome.dart';
import 'widgets.dart';

class HomePage extends StatefulWidget {
  final AppModel model;
  const HomePage({super.key, required this.model});

  /// R2：离屏时 AmbientSpectrum 改订阅冻结通知器（不随 30fps 频谱重建；
  /// 回页时 didUpdateWidget 自动换回真通知器）。
  static final _frozenSpectrum =
      ValueNotifier<List<double>>(List.filled(32, 0.0));

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  /// 主页活动门：呼吸点与频谱卡共用同一份「有没有真实能量」判断。
  late final _HomeActivityGate _activity = _HomeActivityGate(widget.model);

  @override
  void dispose() {
    _activity.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final model = widget.model;
    return ValueListenableBuilder<AppPage>(
      valueListenable: model.visiblePage,
      builder: (_, page, _) {
        final active = page == AppPage.home;
        // 氛围开关走独立 ValueListenable：本页被外壳 IndexedStack 保活、
        // 实例缓存，模型 notifyListeners 不会让 build 重跑；设置页又是模态
        // 覆盖层，visiblePage 也不会变 —— 只听 model 的话开关按了不生效。
        return ValueListenableBuilder<bool>(
          valueListenable: model.ambientEnabled,
          builder: (_, ambientOn, _) => PageScaffold(
            eyebrow: l.pageHomeEyebrow,
            title: l.pageHomeTitle,
            // 关掉氛围背景 → 直接不传数据源，整层不构造（零绘制/零订阅）
            ambient: !ambientOn
                ? null
                : (active ? model.spectrum : HomePage._frozenSpectrum),
            children: [
              _SpectrumCard(model: model, active: active, audible: _activity),
              _Hero(model: model, audible: _activity),
            ],
          ),
        );
      },
    );
  }
}

/* ---- 主页活动门 ---- */

/// 主页「有没有真实音频能量」门控（**仅主页**）。
///
/// 与可视化页是两套东西：可视化页有自己的 `active`/时间轴门（P0-1），这里
/// 不触碰它。本门只回答一件事——现在有没有真实能量，供两处消费：
///   1. Hero 呼吸点：连接态（VB 已挂载 / ASIO 已开）不等于有音频。旧实现把
///      「引擎在处理」直接当活动，桥挂上但没媒体时呼吸点 60fps 空转，Impeller
///      每帧整窗重绘，实测 VB 主页 165~172% CPU / 32~37% GPU，全部由这颗点驱动。
///   2. 频谱卡：静默/隐藏时停止转发帧，绘制侧零重绘（最后一帧保留）。
///
/// 判定：任一面板电平 > -60 dBFS 或任一频段 > 0.001 即有声；无声后保持 2s
/// 再落闸（让柱体自然衰减到底）。窗口不可见（最小化/托盘）直接落闸，
/// 恢复可见后由首个有声帧重新拉起。
class _HomeActivityGate extends ValueNotifier<bool> {
  static const double _audibleLevelDb = -60.0;
  static const double _audibleBandPeak = 0.001;
  static const Duration _silenceHold = Duration(seconds: 2);

  final AppModel _model;
  Timer? _hold;
  bool _visible = PlatformAdapters.instance.window.isVisible;

  _HomeActivityGate(this._model) : super(false) {
    _model.spectrum.addListener(_onFrame);
    PlatformAdapters.instance.window.visibleListenable
        .addListener(_onVisibility);
  }

  void _onVisibility() {
    final visible = PlatformAdapters.instance.window.isVisible;
    if (visible == _visible) return;
    _visible = visible;
    _hold?.cancel();
    _hold = null;
    // 隐藏期不产帧；恢复可见由下一帧有声数据拉起，避免用陈旧状态续跑。
    value = false;
  }

  void _onFrame() {
    if (!_visible) return;
    final bands = _model.spectrum.value;
    var peak = 0.0;
    for (final v in bands) {
      if (v > peak) peak = v;
    }
    final lDb = _model.levelL.value;
    final rDb = _model.levelR.value;
    final level = lDb > rDb ? lDb : rDb;
    if (level > _audibleLevelDb || peak > _audibleBandPeak) {
      _hold?.cancel();
      _hold = null;
      if (!value) value = true;
    } else if (value) {
      // 迟滞窗口内保持开闸，让柱体自然衰减到底再冻结。
      _hold ??= Timer(_silenceHold, () {
        _hold = null;
        value = false;
      });
    }
  }

  @override
  void dispose() {
    _hold?.cancel();
    _model.spectrum.removeListener(_onFrame);
    PlatformAdapters.instance.window.visibleListenable
        .removeListener(_onVisibility);
    super.dispose();
  }
}

/* ---- hero 状态区 ---- */

class _Hero extends StatelessWidget {
  final AppModel model;

  /// 主页活动门：连接态 ≠ 有音频。呼吸点只在这份门为真时产帧。
  final ValueListenable<bool> audible;
  const _Hero({required this.model, required this.audible});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: Listenable.merge([model, audible]),
      builder: (_, _) {
        // 与 StateBadge 同口径，见 AppModel.engineDisplay。
        final disp = model.engineDisplay;
        final (text, color) = switch (disp) {
          EngineDisplay.error => (l.stateError, p.error),
          EngineDisplay.bypass => (l.stateBypass, p.textDim),
          EngineDisplay.idle => (l.stateIdle, p.textDim),
          EngineDisplay.processing => (l.stateProcessing, p.accent),
        };
        // 旧口径 liveSpectrum 在 VB/ASIO 挂载后恒真（没有媒体也算），
        // 呼吸点会 60fps 空转；这里额外要求真实能量。
        final live = disp == EngineDisplay.processing && audible.value;
        return SectionCard(
          hero: true,
          padding: const EdgeInsets.all(AuraSpace.xl),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Text(l.statusLabel, style: eyebrowOf(p)),
                        const SizedBox(width: AuraSpace.sm),
                        PulseDot(
                          color: color,
                          active: live,
                          size: 6,
                        ),
                      ],
                    ),
                    const SizedBox(height: AuraSpace.md),
                    AnimatedDefaultTextStyle(
                      duration: AuraDur.base,
                      curve: AuraCurve.standard,
                      style: displayOf(p, size: 40, color: color),
                      child: Text(text, maxLines: 1,
                          overflow: TextOverflow.ellipsis),
                    ),
                    const SizedBox(height: AuraSpace.sm + 2),
                    Text(
                      model.liveSpectrum
                          ? l.heroHintProcessing
                          : l.heroHintIdle,
                      style: captionOf(p),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: AuraSpace.xl),
              // 延迟读数（数字即设计；语义为"算法附加延迟"，悬停有解释）
              Tooltip(
                message: l.latencyTip,
                waitDuration: const Duration(milliseconds: 350),
                child: StatReadout(
                  label: l.latencyLabel,
                  value: LatencyPresenter.number(model.latencyMs),
                  unit: 'ms',
                  size: 30,
                  valueColor: LatencyPresenter.color(model.latencyMs, p),
                ),
              ),
              const SizedBox(width: AuraSpace.xl),
              _BypassButton(model: model),
            ],
          ),
        );
      },
    );
  }
}

class _BypassButton extends StatefulWidget {
  final AppModel model;
  const _BypassButton({required this.model});

  @override
  State<_BypassButton> createState() => _BypassButtonState();
}

class _BypassButtonState extends State<_BypassButton> {
  bool _hover = false;
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: widget.model,
      builder: (_, _) {
        final on = widget.model.bypass;
        final bg = on ? p.accent2 : p.panelRaised;
        final fg = on ? p.accentContrast : p.text;
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          onEnter: (_) => setState(() => _hover = true),
          onExit: (_) => setState(() {
            _hover = false;
            _down = false;
          }),
          child: GestureDetector(
            onTapDown: (_) => setState(() => _down = true),
            onTapUp: (_) => setState(() => _down = false),
            onTapCancel: () => setState(() => _down = false),
            onTap: widget.model.toggleBypass,
            child: AnimatedScale(
              duration: AuraDur.instant,
              scale: _down ? 0.97 : 1.0,
              child: AnimatedContainer(
                duration: AuraDur.base,
                curve: AuraCurve.emphasized,
                height: AuraSize.heroCompact,
                padding: const EdgeInsets.symmetric(horizontal: AuraSpace.xl),
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(AuraRadius.md),
                  border: Border.all(
                    color: on
                        ? p.accent2
                        : (_hover ? p.textDim.withValues(alpha: 0.5) : p.hairline),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(on ? Icons.power_settings_new : Icons.bolt_outlined,
                        size: 18, color: fg),
                    const SizedBox(width: AuraSpace.sm + 2),
                    Text(on ? l.bypassOn : l.bypassOff,
                        style: TextStyle(
                            fontSize: 14, fontWeight: FontWeight.w700,
                            letterSpacing: 0.3, color: fg)),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

/* ---- 频谱 + 电平 ---- */

class _SpectrumCard extends StatefulWidget {
  final AppModel model;
  /// R2（2026-10-23）：宿主页可见性（HomePage 经 visiblePage 门控传入）。
  /// false = 离屏——LevelMeter 与 dBFS 读数不订阅 30fps 通知器。
  final bool active;

  /// 主页活动门（能量判定 + 窗口可见性 + 2s 静默迟滞，见 _HomeActivityGate）。
  final _HomeActivityGate audible;
  const _SpectrumCard({
    required this.model,
    required this.audible,
    this.active = true,
  });

  @override
  State<_SpectrumCard> createState() => _SpectrumCardState();
}

/// 主页频谱卡的活动门控（2026-11-06，结案报告 7.3 的遗留项）。
///
/// 与可视化页是两套东西：这里只决定「本卡片要不要消费频谱帧」，不触碰
/// 可视化页的 `active`/时间轴开关。三个条件同时成立才向下游转发：
/// 页面在栈位上、引擎有实时数据、当前有真实能量（含 2s 迟滞，窗口隐藏时
/// 由活动门直接落闸）。任一不成立即冻结 SpectrumView 代理通知器——
/// `CustomPaint` 的 repaint 挂在代理上，冻结后不再产帧，但最后一帧保留。
/// 恢复播放/重新可见后由首个有声帧立即开闸。
class _SpectrumCardState extends State<_SpectrumCard> {
  /// 门控后的频谱代理：静默/离屏期不转发，绘制侧零重绘。
  late final ValueNotifier<List<double>> _gatedSpectrum =
      ValueNotifier<List<double>>(widget.model.spectrum.value);

  bool get _effective =>
      widget.active && widget.model.liveSpectrum && widget.audible.value;

  @override
  void initState() {
    super.initState();
    widget.model.spectrum.addListener(_onSpectrumFrame);
  }

  void _onSpectrumFrame() => _syncGate();

  /// 门控唯一入口：不满足条件即停止转发（保留最后一帧）；
  /// 恢复后由下一帧续上，不会停留在陈旧柱体上。
  void _syncGate() {
    if (!_effective) return;
    _gatedSpectrum.value = widget.model.spectrum.value;
  }

  @override
  void didUpdateWidget(_SpectrumCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.model != widget.model) {
      oldWidget.model.spectrum.removeListener(_onSpectrumFrame);
      widget.model.spectrum.addListener(_onSpectrumFrame);
    }
    if (oldWidget.active != widget.active) {
      // 切页立刻按新条件裁定一次；回页用当前值补一帧。
      _syncGate();
    }
  }

  @override
  void dispose() {
    widget.model.spectrum.removeListener(_onSpectrumFrame);
    _gatedSpectrum.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      title: l.spectrum,
      trailing: _StateHint(model: widget.model),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 140,
            child: ListenableBuilder(
              listenable: widget.model,
              builder: (_, _) {
                if (!widget.model.liveSpectrum) {
                  return _EmptySpectrum(text: l.noAudio);
                }
                // 频谱主体 + 右侧 dB 纵轴（与可视化页同一套坐标语义）。
                // 传门控代理而非 model.spectrum：静默/最小化时零重绘。
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: SpectrumView(spectrum: _gatedSpectrum)),
                    const SizedBox(width: AuraSpace.sm),
                    const _DbScaleMini(),
                  ],
                );
              },
            ),
          ),
          const SizedBox(height: AuraSpace.sm),
          const FreqAxis(),
          const SizedBox(height: AuraSpace.lg),
          // 总线轴标识：8 根柱是「当前最热总线」的声道轴，不是 A1–B3 总线轴。
          if (widget.model.vbActive) ...[
            _MeterBusScope(model: widget.model),
            const SizedBox(height: AuraSpace.xs),
          ],
          _OutputLevelRow(model: widget.model, active: widget.active),
          const SizedBox(height: AuraSpace.sm + 2),
          Align(
            alignment: Alignment.centerRight,
            // R2：离屏不订阅 levelL/R——静态读数替代（回页父级以
            // active=true 重建即恢复）。
            child: widget.active
                ? ValueListenableBuilder<double>(
                    valueListenable: widget.model.levelL,
                    builder: (_, lDb, _) => ValueListenableBuilder<double>(
                      valueListenable: widget.model.levelR,
                      builder: (_, rDb, _) => Text(
                          'L ${dbfsText(lDb)}  R ${dbfsText(rDb)} dBFS',
                          style: monoOf(p, size: 11, color: p.textDim)),
                    ),
                  )
                : Text('L ${dbfsText(-90.0)}  R ${dbfsText(-90.0)} dBFS',
                    style: monoOf(p, size: 11, color: p.textDim)),
          ),
        ],
      ),
    );
  }
}

/// [Phase B 多声道电平] 输出电平条：stereo（chCount<=2/无帧）为 L/R 两柱
/// ——与改造前逐位一致；MC（5.1/7.1）按 channelLevels 展开 N 柱。
/// 不新增设置项/入口，只在既有电平展示组件内扩柱（Z15 原则）。
class _OutputLevelRow extends StatelessWidget {
  final AppModel model;
  final bool active;
  const _OutputLevelRow({required this.model, required this.active});

  /// WAVEFORMATEX 声道序标签（与引擎 speaker_layout.h 同序）：
  /// 4ch 是 Quad 4.0（FL FR BL BR），6/8ch 才是 FL FR C LFE SL SR [BL BR]。
  static List<String> _labelsFor(int ch) {
    if (ch == 4) return const ['FL', 'FR', 'BL', 'BR'];
    return const ['FL', 'FR', 'C', 'LFE', 'SL', 'SR', 'BL', 'BR'];
  }

  @override
  Widget build(BuildContext context) {
    if (!active) {
      // 离屏：静态空轨，与现路径一致（不订阅 30fps）。
      return Row(children: [
        Expanded(
            child: LevelMeter(level: model.levelL, label: 'L', active: false)),
        const SizedBox(width: AuraSpace.lg),
        Expanded(
            child: LevelMeter(level: model.levelR, label: 'R', active: false)),
      ]);
    }
    return ValueListenableBuilder<int>(
      valueListenable: model.vizChannelCount,
      builder: (_, cc, _) {
        if (cc <= 2) {
          // stereo：原两柱路径（levelL/R 与 channel_levels[0]/[1] 同源）。
          return Row(children: [
            Expanded(child: LevelMeter(level: model.levelL, label: 'L')),
            const SizedBox(width: AuraSpace.lg),
            Expanded(child: LevelMeter(level: model.levelR, label: 'R')),
          ]);
        }
        return ValueListenableBuilder<List<double>>(
          valueListenable: model.vizChannelLevels,
          builder: (_, levels, _) {
            final p = paletteOf(context);
            final n = cc.clamp(3, 8);
            final labels = _labelsFor(cc);
            return Row(
              children: [
                for (var c = 0; c < n; c++) ...[
                  if (c > 0) const SizedBox(width: AuraSpace.sm),
                  Expanded(
                    child: Row(children: [
                      SizedBox(
                        width: 22,
                        child: Text(labels[c],
                            style: monoOf(p, size: 9, color: p.textDim)),
                      ),
                      const SizedBox(width: 3),
                      Expanded(
                        child: RepaintBoundary(
                          child: SizedBox(
                            height: 8,
                            child: CustomPaint(
                              size: const Size(double.infinity, 8),
                              painter: MeterPainter(
                                value: ((levels[c] + 60) / 60).clamp(0.0, 1.0),
                                track: p.hairline,
                                fill: levels[c] > -3 ? p.error : p.accent,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ]),
                  ),
                ],
              ],
            );
          },
        );
      },
    );
  }
}

/// 主页电平区总线标识：读 VB 桥 status 的 `vizGrp`（当前 viz 跟随的总线组），
/// 明示「这 8 根柱是哪条总线的声道」，避免把声道轴误读成 A1–B3 总线轴。
/// 只改显示，不动电平数值口径；按 hbTick 心跳更新，不牵动外层重建。
class _MeterBusScope extends StatelessWidget {
  final AppModel model;
  const _MeterBusScope({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return HbBuilder(
      tick: model.hbTick,
      builder: (context) {
        if (!model.vbActive) return const SizedBox.shrink();
        final g = (model.vbInfo['vizGrp'] as num?)?.toInt() ?? -1;
        if (g < 0 || g > 7) return const SizedBox.shrink();
        final names =
            vbBusNames((model.vbInfo['edition'] as num?)?.toInt() ?? 0);
        final bus = g < names.length ? names[g] : 'G${g + 1}';
        final cc = model.vizChannelCount.value;
        return Align(
          alignment: Alignment.centerLeft,
          child: Text(
            l.meterBusScope(bus, cc),
            style: monoOf(p, size: 10, color: p.textDim),
          ),
        );
      },
    );
  }
}

/// 首页频谱右侧的紧凑 dB 纵轴（0 / -15 / -30 / -45 / -60 dBFS）
class _DbScaleMini extends StatelessWidget {
  const _DbScaleMini();

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    const marks = ['0', '-15', '-30', '-45', '-60'];
    return SizedBox(
      width: 26,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final m in marks)
            Text(m,
                style: monoOf(
                    p, size: 9, color: p.textDim.withValues(alpha: 0.7))),
        ],
      ),
    );
  }
}

class _StateHint extends StatelessWidget {
  final AppModel model;
  const _StateHint({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Text(
        model.engineDisplay == EngineDisplay.processing
            ? '● live'
            : model.engineDisplay == EngineDisplay.bypass
                ? l.stateBypass
                : l.stateIdle,
        style: monoOf(p, size: 10,
            color: model.engineDisplay == EngineDisplay.processing
                ? p.success
                : p.textDim.withValues(alpha: 0.7)),
      ),
    );
  }
}

class _EmptySpectrum extends StatelessWidget {
  final String text;
  const _EmptySpectrum({required this.text});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.graphic_eq_outlined, size: 18, color: p.textDim),
          const SizedBox(width: AuraSpace.sm),
          Text(text, style: captionOf(p)),
        ],
      ),
    );
  }
}
