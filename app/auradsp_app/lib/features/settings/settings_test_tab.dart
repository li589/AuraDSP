part of '../settings_page.dart';

/*
 * settings_test_tab.dart — 测试页（第四十四轮 S4 三段化）
 * 包含：波形生成（正弦/方波/三角/粉噪、0–20000 Hz 对数连续
 * 调频、自动全频段扫频）、使用源测试（单个「打开音频」、
 * 播放/暂停 + 可拖动比率进度条、无时间显示）、调试（调试
 * 模式开关占位段）。波形源与文件源经 AppModel.setSource
 * 唯一互斥点切换——同一时刻只有一个实际发声源。
 */

List<Widget> buildTestTab(BuildContext context, AppModel model) {
  final l = l10nOf(context);

  return [
    // 1. 波形生成
    SectionCard(
      title: l.testWaveTitle,
      hint: l.testSrcHint,
      child: _WaveGenPanel(model: model),
    ),
    // 2. 使用源测试
    SectionCard(
      title: l.testUseSrcTitle,
      child: _FileSourcePanel(model: model),
    ),
    // 3. 调试（先占位：仅调试模式开关，接既有 DebugTrace 设施）
    SectionCard(
      title: l.testDebugTitle,
      child: _DebugPanel(model: model),
    ),
  ];
}

/// 极简拖动条（轨道 + 圆钮）：频率对数标尺与文件进度共用。
/// [value] 为 0..1 比率；拖动连续回调 onChanged，松手/点按
/// 落点回调 onChangeEnd（文件定位只在落点发命令）。
class _TestSlider extends StatelessWidget {
  final double value;
  final bool enabled;
  final ValueChanged<double>? onChanged;
  final ValueChanged<double>? onChangeEnd;
  const _TestSlider({
    required this.value,
    this.enabled = true,
    this.onChanged,
    this.onChangeEnd,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final v = value.clamp(0.0, 1.0).toDouble();
    return LayoutBuilder(builder: (context, c) {
      double ratioAt(double dx) =>
          (dx / c.maxWidth).clamp(0.0, 1.0).toDouble();
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapDown: enabled && onChanged != null
            ? (d) {
                final r = ratioAt(d.localPosition.dx);
                onChanged!(r);
                onChangeEnd?.call(r);
              }
            : null,
        onHorizontalDragUpdate: enabled && onChanged != null
            ? (d) => onChanged!(ratioAt(d.localPosition.dx))
            : null,
        onHorizontalDragEnd: enabled && onChangeEnd != null
            ? (_) => onChangeEnd!(v)
            : null,
        child: SizedBox(
          height: 28,
          child: Stack(
            alignment: Alignment.centerLeft,
            children: [
              Container(
                height: 4,
                decoration: BoxDecoration(
                  color: p.hairline,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              FractionallySizedBox(
                widthFactor: v,
                child: Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: enabled ? p.accent : p.textDim,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Align(
                alignment: Alignment(-1 + 2 * v, 0),
                child: Container(
                  width: 14,
                  height: 14,
                  decoration: BoxDecoration(
                    color: enabled ? p.accent : p.textDim,
                    shape: BoxShape.circle,
                    border: Border.all(color: p.panel, width: 2),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}

/// ASIO 模式测试提示（第四十八轮 S3）：测试信号经 ASIO
/// 驱动输出，驱动路由不通时测试与正常播放同无声——加 ?
/// 气泡先行分流（user 预批方案）。非 ASIO 模式不渲染。
class _AsioTestHint extends StatelessWidget {
  final AppModel model;
  const _AsioTestHint({required this.model});

  @override
  Widget build(BuildContext context) {
    if (model.audioMode != 'asio') return const SizedBox.shrink();
    final l = l10nOf(context);
    final p = paletteOf(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AuraSpace.sm),
      child: Row(
        children: [
          Text('ASIO', style: monoOf(p, size: 12, color: p.textDim)),
          const SizedBox(width: AuraSpace.xs),
          InfoBadge(message: l.testAsioHint),
        ],
      ),
    );
  }
}

/// 波形生成卡：波形四选一 + 对数调频 + 扫频开关 + 播放/停止。
class _WaveGenPanel extends StatelessWidget {
  final AppModel model;
  const _WaveGenPanel({required this.model});

  static double _freqToRatio(double hz) =>
      (math.log(hz) - math.log(20)) / (math.log(20000) - math.log(20));
  static double _ratioToFreq(double r) =>
      (20 * math.pow(1000, r)).toDouble();

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        final isPink = model.waveShape == 'pink';
        final freqEnabled = !isPink && !model.waveSweep;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AsioTestHint(model: model),
            AuraSegmented<String>(
              segments: [
                AuraSegment('sine', l.waveSine),
                AuraSegment('square', l.waveSquare),
                AuraSegment('triangle', l.waveTriangle),
                AuraSegment('pink', l.srcPink),
              ],
              selected:
                  model.sourceKind == 'pink' ? 'pink' : model.waveShape,
              onChanged: (v) => model.setWaveShape(v),
            ),
            const SizedBox(height: AuraSpace.md),
            Row(
              children: [
                Text(l.waveFreq, style: labelOf(p, size: 12, color: p.textDim)),
                const Spacer(),
                Text(
                  '${model.waveFreq.round()} Hz',
                  style: monoOf(p, size: 12, color: freqEnabled ? p.text : p.textDim),
                ),
              ],
            ),
            _TestSlider(
              value: _freqToRatio(model.waveFreq),
              enabled: freqEnabled,
              onChanged: (r) => model.setWaveFreq(_ratioToFreq(r)),
            ),
            Row(
              children: [
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // 粉噪无频率概念：扫频开关与频率条同口径
                    // 禁用（第四十八轮 S4，user 宾机反馈）。
                    Text(l.waveSweep,
                        style: captionOf(p,
                            color: isPink ? p.textDim : p.text)),
                    Text(
                      l.waveSweepDesc,
                      style: captionOf(p, color: p.textDim).copyWith(fontSize: 11),
                    ),
                  ],
                ),
                const Spacer(),
                AuraSwitch(
                  value: model.waveSweep,
                  onChanged: isPink ? null : (on) => model.setWaveSweep(on),
                ),
              ],
            ),
            const SizedBox(height: AuraSpace.md),
            AuraChip(
              model.waveActive ? l.srcStop : l.wavePlay,
              icon: model.waveActive ? Icons.stop_rounded : Icons.play_arrow_rounded,
              danger: model.waveActive,
              selected: model.waveActive,
              onTap: () => model.toggleWave(),
            ),
          ],
        );
      },
    );
  }
}

/// 使用源测试卡：左 = 未选提示 / 播放暂停键 + 进度条；
/// 右 = 「打开音频」（wav/mp3 单按钮，可替换当前文件）。
class _FileSourcePanel extends StatefulWidget {
  final AppModel model;
  const _FileSourcePanel({required this.model});

  @override
  State<_FileSourcePanel> createState() => _FileSourcePanelState();
}

class _FileSourcePanelState extends State<_FileSourcePanel> {
  bool _seeking = false;
  double _seekRatio = 0;

  AppModel get model => widget.model;

  Future<void> _openAudio(BuildContext context) async {
    final l = l10nOf(context);
    final path = await AuraPathPickerDialog.show(
      context,
      title: l.testOpenAudio,
      prompt: l.testAudioAnyPrompt,
      allowedExtensions: const ['wav', 'mp3'],
      memorySlot: PathMemory.slotTestAudio,
      confirmLabel: l.testAudioLoad,
    );
    if (path != null) model.setSource('file', path: path);
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) {
        final hasFile = model.sourcePath.isNotEmpty;
        final filePlaying =
            model.sourceKind == 'file' && !model.sourcePaused;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _AsioTestHint(model: model),
            Row(
              children: [
                Expanded(
                  child: !hasFile
                      ? Text(
                          l.testNoSource,
                          style: captionOf(p, color: p.textDim),
                        )
                      : Row(
                          children: [
                            GestureDetector(
                              onTap: () => model.toggleFilePlay(),
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  border: Border.all(color: p.hairline),
                                  color: p.panelRaised,
                                ),
                                child: Icon(
                                  filePlaying
                                      ? Icons.pause_rounded
                                      : Icons.play_arrow_rounded,
                                  size: 18,
                                  color: p.text,
                                ),
                              ),
                            ),
                            const SizedBox(width: AuraSpace.sm),
                            Expanded(
                              child: _TestSlider(
                                value: _seeking
                                    ? _seekRatio
                                    : model.sourcePosRatio,
                                onChanged: (r) => setState(() {
                                  _seeking = true;
                                  _seekRatio = r;
                                }),
                                onChangeEnd: (r) {
                                  model.seekSource(r);
                                  setState(() => _seeking = false);
                                },
                              ),
                            ),
                          ],
                        ),
                ),
                const SizedBox(width: AuraSpace.sm),
                if (model.sourceKind == 'file') ...[
                  AuraChip(
                    l.srcStop,
                    icon: Icons.stop_rounded,
                    danger: true,
                    selected: true,
                    onTap: () => model.setSource('stop'),
                  ),
                  const SizedBox(width: AuraSpace.sm),
                ],
                AuraChip(
                  l.testOpenAudio,
                  icon: Icons.folder_open_outlined,
                  onTap: () => _openAudio(context),
                ),
              ],
            ),
            if (model.sourceKind == 'file' && model.fileChannels > 2) ...[
              const SizedBox(height: AuraSpace.sm),
              Wrap(
                spacing: AuraSpace.sm,
                runSpacing: AuraSpace.sm,
                children: [
                  AuraChip(
                    l.src51Fold,
                    icon: Icons.alt_route_rounded,
                    selected: model.source51Mode == 0,
                    onTap: () => model.setSource51Mode(0),
                  ),
                  AuraChip(
                    l.src51Pass,
                    icon: Icons.arrow_forward_rounded,
                    selected: model.source51Mode == 1,
                    onTap: () => model.setSource51Mode(1),
                  ),
                  InfoBadge(message: l.src51Hint),
                ],
              ),
            ],
          ],
        );
      },
    );
  }
}

/// 调试卡（占位段）：仅「调试模式」开关——运行时启停既有
/// 结构化调试流（DebugTrace）；开态时根部 HUD 随之挂载。
class _DebugPanel extends StatelessWidget {
  final AppModel model;
  const _DebugPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Row(
        children: [
          Text(l.testDebugMode, style: captionOf(p, color: p.text)),
          const Spacer(),
          AuraSwitch(
            value: model.config.debugMode,
            onChanged: (on) => model.setDebugMode(on),
          ),
        ],
      ),
    );
  }
}
