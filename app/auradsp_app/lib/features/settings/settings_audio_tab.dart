part of '../settings_page.dart';

/*
 * settings_audio_tab.dart — 音频设置页
 * 包含：处理范式与模式、设备与精细化调节、采样率、声道配置（声道数量与多声道模式）
 */

List<Widget> buildAudioTab(BuildContext context, AppModel model) {
  final l = l10nOf(context);
  final p = paletteOf(context);

  return [
    // 1. 音频范式与模式（ADR-009：附加模式原地挂载；普通管线模式端到端流转）
    SectionCard(
      title: l.audioParadigm,
      hint: l.audioParadigmHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 第一级：两大范式选择
          AuraSegmented<String>(
            segments: [
              AuraSegment(AudioModes.categoryAttachment, l.paradigmAttachment),
              AuraSegment(AudioModes.categoryPipeline, l.paradigmPipeline),
            ],
            selected: model.modeCategory,
            onChanged: (v) => model.setModeCategory(v),
          ),
          const SizedBox(height: AuraSpace.sm),
          // 第二级：细分形态
          if (model.modeCategory == AudioModes.categoryAttachment) ...[
            Text(l.audioMode, style: labelOf(p, size: 12, color: p.textDim)),
            const SizedBox(height: AuraSpace.xs),
            AuraSegmented<String>(
              segments: [
                AuraSegment(AudioModes.attachSysApo, l.modeSysApo),
                AuraSegment(AudioModes.attachVoicemeeterApi, l.modeVoicemeeterApi),
              ],
              selected: model.attachmentMode,
              onChanged: (v) => model.setAttachmentMode(v),
            ),
          ] else ...[
            // 管线模式：输入端 + 输出端（上下文字对齐，帮助提示统一由 InfoBadge 承担）
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.pipelineIn, style: labelOf(p, size: 12, color: p.textDim)),
                const SizedBox(width: AuraSpace.xs),
                InfoBadge(message: l.pipelineInHint),
              ],
            ),
            const SizedBox(height: AuraSpace.xs),
            AuraSegmented<String>(
              segments: [
                AuraSegment(AudioModes.inputWasapi, l.inputWasapi,
                    tooltip: l.tooltipInputWasapi),
                AuraSegment(AudioModes.inputVaio, l.inputVaio,
                    tooltip: l.tooltipInputVaio),
                AuraSegment(AudioModes.inputAsioDriver, l.inputAsioDriver,
                    tooltip: l.tooltipInputAsioDriver),
              ],
              selected: model.pipelineInput,
              onChanged: (v) => model.setPipelineInput(v),
            ),
            const SizedBox(height: AuraSpace.sm),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(l.pipelineOut, style: labelOf(p, size: 12, color: p.textDim)),
                const SizedBox(width: AuraSpace.xs),
                InfoBadge(message: l.pipelineOutHint),
              ],
            ),
            const SizedBox(height: AuraSpace.xs),
            AuraSegmented<String>(
              segments: [
                AuraSegment(AudioModes.outputWasapi, l.outputWasapi,
                    tooltip: l.tooltipOutputWasapi),
                AuraSegment(AudioModes.outputVaio, l.outputVaio,
                    tooltip: l.tooltipOutputVaio),
                AuraSegment(AudioModes.outputAsioClient, l.outputAsioClient,
                    tooltip: l.tooltipOutputAsioClient),
              ],
              selected: model.pipelineOutput,
              onChanged: (v) => model.setPipelineOutput(v),
            ),
          ],
        ],
      ),
    ),

    // 2. 设备与精细化调节（根据当前范式与配置动态展示）
    SectionCard(
      title: l.audioDevice,
      child: _DynamicAudioPanel(model: model),
    ),

    // 3. 采样率（移入音频页；VB/ASIO 等桥模式跟随驱动，此处作为软件请求值与内部回退基准）
    SectionCard(
      title: l.sampleRate,
      hint: (model.audioMode == 'vbcallback' || model.audioMode == 'asio')
          ? l.sampleRateFollowBridge
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AuraSegmented<int>(
            segments: const [
              AuraSegment(44100, '44100'),
              AuraSegment(48000, '48000'),
              AuraSegment(96000, '96000'),
            ],
            selected: model.config.sampleRate,
            onChanged: (v) => model.setSampleRate(v),
          ),
          // 诚实标注实际协商率
          if (model.engineRate > 0 &&
              model.engineRate != model.config.sampleRate) ...[
            const SizedBox(height: AuraSpace.sm),
            Text(
              l.sampleRateDeviceActual(model.engineRate),
              style: captionOf(p, color: p.textDim).copyWith(fontSize: 11),
            ),
          ],
        ],
      ),
    ),

    // 4. 声道数量（物理设备拓扑：0=自动协商；2/4/6/8 手动指定）
    SectionCard(
      title: l.channelCount,
      hint: l.channelCountHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AuraSegmented<int>(
            segments: [
              AuraSegment(0, l.channelCountAuto),
              const AuraSegment(2, '2.0'),
              const AuraSegment(4, '4.0'),
              const AuraSegment(6, '5.1'),
              const AuraSegment(8, '7.1'),
            ],
            selected: model.channelsCountMode == 0 ? 0 : model.channelsCount,
            onChanged: (v) {
              if (v == 0) {
                model.setChannelsCountMode(0);
              } else {
                model.setChannelsCountMode(1);
                model.setChannelsCount(v);
              }
            },
          ),
          if (model.channelsCountMode == 0) ...[
            const SizedBox(height: AuraSpace.xs),
            Padding(
              padding: const EdgeInsets.only(top: 2, left: 2),
              child: Text(
                l.channelCountAutoDesc(model.effectiveChannelCount),
                style: captionOf(p, color: p.textDim).copyWith(fontSize: 11),
              ),
            ),
          ],
        ],
      ),
    ),

    // 5. 声道模式（多声道 DSP 策略：矩阵下混 vs 离散多声道）
    SectionCard(
      title: l.channelMode,
      hint: l.channelPhaseA,
      child: AuraSegmented<int>(
        segments: [
          AuraSegment(0, l.channelsMatrix),
          AuraSegment(1, l.channelsDiscrete),
        ],
        selected: model.channelsMode.clamp(0, 1),
        onChanged: (v) => model.setInt('channels.mode', v),
      ),
    ),
  ];
}
