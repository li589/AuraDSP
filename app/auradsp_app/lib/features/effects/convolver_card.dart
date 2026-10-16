// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 03 脉冲响应卷积 (Convolver) ---- */

/// 文件资源槽：带边框、标题行与状态位的按钮组。
///
/// 卷积 / VDC 两张卡片此前都是裸 `Wrap` 丢几个 chip，与下方内容既无分组也无
/// 边界，视觉上像「随便扔在那」。这里给它们一个统一的容器，读起来是
/// 「该效果依赖哪个外部文件」这一明确区块。

class _ConvolverCard extends StatelessWidget {
  final AppModel model;
  const _ConvolverCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      index: kEffectCardIndex['spatialConv'],
      title: l.convTitle,
      // 常规语义：关闭即收起。用户先前明确要求「无文件时保持开关开启、
// 效果内部直通(旁路)，待合格文件加载成功后自动生效」，
// 因此可达性由 state 层的 auto-bypass 解决，而不是靠改这里的折叠判据。
      // D1 曾改成 convEnabled && convReady，导致「打开开关反而收起」的反向手感。
      collapsed: !model.convEnabled,
      latencyMs: model.componentLatency('convolver').ms,
              latencyMeasured: model.componentLatency('convolver').measured,
              latencyEstimated: model.componentLatency('convolver').estimated,
              latencyProbing: model.isProbingLatency('convolver'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('convolver')
          ? () => model.refreshComponentLatency('convolver')
          : null,
      latencyTick: model.getComponentLatencyTick('convolver'),
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.convEnabled,
          onChanged: (v) => model.setConvolverEnabled(v),
        ),
      ),
      child: ListenableBuilder(
        listenable: model,
        builder: (_, _) {
          if (!model.convReady) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _ResourceSlot(
                  icon: Icons.folder_open_outlined,
                  title: l.convIrTitle,
                  actions: [
                    AuraChip(l.convOpenIr, icon: Icons.folder_open_outlined,
                        onTap: () => _pickIr(context)),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                Text(l.convNoIr, style: captionOf(p)),
              ],
            );
          }
          // convFrames 是**重采样到引擎 fs 之后**的帧数（见 load_ir_file 的离线重采样），
          // 所以换算基准是设备采样率，不是 IR 文件原始的 convSrcRate。
          final durMs = model.convFrames * 1000.0 / model.deviceRate;
          final dur = durMs >= 1000
              ? '${(durMs / 1000).toStringAsFixed(2)} s'
              : '${durMs.toStringAsFixed(0)} ms';
          final resampled = AppModel.irWasResampled(
            srcRate: model.convSrcRate,
            deviceRate: model.deviceRate,
          );
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _ResourceSlot(
                icon: Icons.graphic_eq_outlined,
                title: l.convIrTitle,
                detail: '${model.convChannels}ch · $dur',
                actions: [
                  AuraChip(l.convOpenIr, icon: Icons.folder_open_outlined,
                      onTap: () => _pickIr(context)),
                  AuraChip(l.convClear, icon: Icons.delete_outline, danger: true,
                      onTap: () => model.clearConvolver()),
                ],
              ),
              const SizedBox(height: AuraSpace.md),
              if (model.convSpectrum.isNotEmpty) ...[
                _IrWaveformGraph(
                  spectrum: model.convSpectrum,
                  channels: model.convChannels,
                ),
                const SizedBox(height: AuraSpace.md),
              ],
              ValueSlider(
                label: l.convMix,
                infoMessage: '卷积混响混合比。0% 为原始干声，100% 完全沉浸在采样的空间声学混响中。',
                value: model.convMix,
                defaultValue: ParamDefaults.convMix,
                onResetToDefault: () =>
                    model.setFloat('convolver.mix', ParamDefaults.convMix),
                min: 0,
                max: 1,
                unit: '%',
                format: (v) => (v * 100).toStringAsFixed(0),
                onChanged: (v) => model.setFloat('convolver.mix', v),
                onChangedEnd: (v) => model.setFloat('convolver.mix', v),
              ),
              const SizedBox(height: AuraSpace.md),
              // 帧数行与重采样提示同行、提示右对齐；窄屏（Android/小窗）
              // 放不下时提示自动换到下一行并保持右对齐。
              LayoutBuilder(builder: (context, box) {
                final framesText = Text(
                  l.convFramesLine(
                      model.convFrames,
                      dur,
                      model.convChannels,
                      (20 * math.log(model.convPeak <= 1e-6 ? 1e-6 : model.convPeak) / math.ln10).toStringAsFixed(1),
                      model.convSrcRate),
                  style: monoOf(p, size: 12, color: p.text),
                );
                if (!resampled) return framesText;
                final hint = Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.info_outline, size: 13, color: p.warning),
                    const SizedBox(width: AuraSpace.xs + 2),
                    Flexible(
                      child: Text(l.convResampled, style: captionOf(p)),
                    ),
                  ],
                );
                if (box.maxWidth >= 420) {
                  return Row(
                    children: [
                      Expanded(child: framesText),
                      const SizedBox(width: AuraSpace.sm),
                      hint,
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    framesText,
                    const SizedBox(height: 2),
                    Align(alignment: Alignment.centerRight, child: hint),
                  ],
                );
              }),
            ],
          );
        },
      ),
    );
  }

  Future<void> _pickIr(BuildContext context) async {
    const type = XTypeGroup(label: 'Audio IR (*.irs, *.wav, *.flac)',
        extensions: ['irs', 'wav', 'flac']);
    final f = await openFile(
      acceptedTypeGroups: [type],
      initialDirectory: PathMemory.dirFor(PathMemory.slotConvolverIr) ??
          PathMemory.fallbackDir(PathMemory.slotConvolverIr),
    );
    if (f != null) {
      PathMemory.recordPick(PathMemory.slotConvolverIr, f.path);
      model.loadConvolverIr(f.path);
    }
  }
}
