/*
 * home_page.dart — 主页：引擎状态大屏 + 频谱/电平
 *
 * 层级：频谱可视化（无序号） → hero 状态区（最大字号 + A/B 主操作）。
 * 测试音频源已移入设置页测试卡（为输入/输出设备选择预留位置）。
 * 注：右上引擎简报行已移除（信息冗余，设备信息见设置页设备卡）。
 */
import 'package:flutter/material.dart';

import '../core/design.dart';
import '../core/nav.dart';
import '../core/state.dart';
import '../core/theme.dart';
import 'chrome.dart';
import 'widgets.dart';

class HomePage extends StatelessWidget {
  final AppModel model;
  const HomePage({super.key, required this.model});

  /// R2：离屏时 AmbientSpectrum 改订阅冻结通知器（不随 30fps 频谱重建；
  /// 回页时 didUpdateWidget 自动换回真通知器）。
  static final _frozenSpectrum =
      ValueNotifier<List<double>>(List.filled(32, 0.0));

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    // R2（2026-10-23）：页可见性门控——IndexedStack 保活后本页离屏仍在
    // 树上（SDK 实证全子节点参与 layout），高频可视化订阅据此摘除。
    return ValueListenableBuilder<AppPage>(
      valueListenable: model.visiblePage,
      builder: (_, page, _) {
        final active = page == AppPage.home;
        return PageScaffold(
          eyebrow: l.pageHomeEyebrow,
          title: l.pageHomeTitle,
          ambient: active ? model.spectrum : _frozenSpectrum,
          children: [
            _SpectrumCard(model: model, active: active), // 可视化置顶：主页的第一视觉（无序号）
            _Hero(model: model), // 引擎总览：状态 / 延迟 / 旁路
          ],
        );
      },
    );
  }
}

/* ---- hero 状态区 ---- */

class _Hero extends StatelessWidget {
  final AppModel model;
  const _Hero({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        // 与 StateBadge 同口径，见 AppModel.engineDisplay。
        final disp = model.engineDisplay;
        final (text, color) = switch (disp) {
          EngineDisplay.error => (l.stateError, p.error),
          EngineDisplay.bypass => (l.stateBypass, p.textDim),
          EngineDisplay.idle => (l.stateIdle, p.textDim),
          EngineDisplay.processing => (l.stateProcessing, p.accent),
        };
        final live = disp == EngineDisplay.processing;
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
                  value: model.latencyMs.toStringAsFixed(1),
                  unit: 'ms',
                  size: 30,
                  valueColor: latencyColor(model.latencyMs, p),
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

class _SpectrumCard extends StatelessWidget {
  final AppModel model;
  /// R2（2026-10-23）：宿主页可见性（HomePage 经 visiblePage 门控传入）。
  /// false = 离屏——LevelMeter 与 dBFS 读数不订阅 30fps 通知器。
  final bool active;
  const _SpectrumCard({required this.model, this.active = true});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      title: l.spectrum,
      trailing: _StateHint(model: model),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            height: 140,
            child: ListenableBuilder(
              listenable: model,
              builder: (_, _) {
                if (!model.liveSpectrum) {
                  return _EmptySpectrum(text: l.noAudio);
                }
                // 频谱主体 + 右侧 dB 纵轴（与可视化页同一套坐标语义）。
                // SpectrumView 走 CustomPainter(repaint:)，离屏只标记脏
                // 不实际绘制，无需门控。
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: SpectrumView(spectrum: model.spectrum)),
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
          Row(children: [
            Expanded(
                child: LevelMeter(
                    level: model.levelL, label: 'L', active: active)),
            const SizedBox(width: AuraSpace.lg),
            Expanded(
                child: LevelMeter(
                    level: model.levelR, label: 'R', active: active)),
          ]),
          const SizedBox(height: AuraSpace.sm + 2),
          Align(
            alignment: Alignment.centerRight,
            // R2：离屏不订阅 levelL/R——静态读数替代（回页父级以
            // active=true 重建即恢复）。
            child: active
                ? ValueListenableBuilder<double>(
                    valueListenable: model.levelL,
                    builder: (_, lDb, _) => ValueListenableBuilder<double>(
                      valueListenable: model.levelR,
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
