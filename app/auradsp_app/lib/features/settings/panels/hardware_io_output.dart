part of '../../settings_page.dart';
// P1-1c（2026-10-23）：hardware_io 再拆——输出层（WASAPI/VAIO/ASIO Client 输出子面板 + 测试音源）。


/* ---- 第三层：输出的信息和开关 ---- */

class _OutputLayer extends StatelessWidget {
  final AppModel model;
  const _OutputLayer({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final enabled = model.pipelineOutputEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.output_rounded, size: 15, color: p.accent),
                const SizedBox(width: AuraSpace.xs),
                Text(l.outputLayerTitle,
                    style: sectionOf(p, color: p.text)),
                const SizedBox(width: AuraSpace.xs),
                InfoBadge(message: l.tooltipOutputWasapi),
              ],
            ),
            AuraSwitch(
              value: enabled,
              onChanged: (v) => model.setPipelineOutputEnabled(v),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        if (!enabled)
          Container(
            padding: const EdgeInsets.symmetric(
                horizontal: AuraSpace.sm, vertical: AuraSpace.xs + 2),
            decoration: BoxDecoration(
              color: p.panelRaised,
              borderRadius: BorderRadius.circular(AuraRadius.sm),
              border: Border.all(color: p.hairline),
            ),
            child: Row(
              children: [
                Icon(Icons.volume_off_outlined, size: 15, color: p.textDim),
                const SizedBox(width: AuraSpace.xs),
                Expanded(
                  child: Text(
                    l.outputDisabledNotice,
                    style: captionOf(p, color: p.textDim),
                  ),
                ),
              ],
            ),
          )
        else ...[
          if (model.pipelineOutput == AudioModes.outputWasapi)
            _WasapiOutputSubpanel(model: model)
          else if (model.pipelineOutput == AudioModes.outputVaio)
            HbBuilder(tick: model.hbTick,
                builder: (_) => _VaioOutputSubpanel(model: model))
          else
            _AsioClientOutputSubpanel(model: model),
        ],
      ],
    );
  }
}

class _WasapiOutputSubpanel extends StatelessWidget {
  final AppModel model;
  const _WasapiOutputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    // 互斥规格（第四轮项 2）：候选已在状态层剔除输入已选端点。
    final outputs = model.wasapiOutputsExcludingInput;
    final curDev = model.pipelineOutputDevice;
    final matched = outputs.cast<AudioDeviceItem?>().firstWhere(
        (d) => d?.id == curDev || d?.name == curDev,
        orElse: () => null);
    final selectedValue = matched != null
        ? (matched.id.isNotEmpty ? matched.id : matched.name)
        : (curDev.isEmpty ? '' : curDev);
    final info = model.info;
    // '' 默认项是系统默认渲染端点的别名：输入占据渲染槽时它与
    // 输入是同一端点，必须撤下（单声卡机撤完即无任何可选）。
    final inputBlocksDefault = model.inputOccupiesRenderSlot;
    // 当前输出值不在候选里且与输入构成自激对 = 被互斥规则撤下，
    // 不是离线——不许离线兜底项把它再塞回来。
    final curExcluded =
        curDev.isNotEmpty && matched == null && model.pipelinePairConflicts;
    final offlineShown = curDev.isNotEmpty && matched == null && !curExcluded;
    final noItems = inputBlocksDefault && outputs.isEmpty && !offlineShown;
    // 项 4 诚实呈现（第七轮 S2）：合成链为桥链（VAIO/ASIO）时本
    // 下拉的设备字段不被链路消费（只供捕获链）——与输入侧
    // overriddenByVaio 同口径：说明行 + 置灰，不再假装切换有效
    // （实测：输入 VAIO 时切「系统默认渲染」无事发生且无提示）。
    final overriddenByBridge = model.pipelineChain == PipelineChain.vaio ||
        model.pipelineChain == PipelineChain.asio;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.outputWasapi, l.ioWasapiRenderDesc),
        if (overriddenByBridge) ...[
          _InfoRow(
              l.outputDeviceLabel,
              model.pipelineChain == PipelineChain.vaio
                  ? l.ioOutputOverriddenByVaio
                  : l.ioOutputOverriddenByAsio),
          const SizedBox(height: AuraSpace.xs),
        ],
        const SizedBox(height: AuraSpace.xs),
        Row(
          children: [
            SizedBox(
              width: 104,
              child: Text(l.outputDeviceLabel,
                  style: labelOf(p, size: 12, color: p.textDim)),
            ),
            Expanded(
              child: AuraDropdown<String>(
                value: selectedValue,
                items: [
                  if (!inputBlocksDefault)
                  DropdownMenuItem<String>(
                    value: '',
                    child: Row(
                      children: [
                        Icon(Icons.auto_mode_rounded,
                            size: 14,
                            color: curDev.isEmpty ? p.accent : p.textDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l.defaultOutputDevice,
                            style: TextStyle(
                              fontSize: 12,
                              color: curDev.isEmpty ? p.accent : p.text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (offlineShown)
                    DropdownMenuItem<String>(
                      value: curDev,
                      child: Row(
                        children: [
                          Icon(Icons.link_off_rounded,
                              size: 14, color: p.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l.setOfflineSuffix(_formatOfflineDeviceName(l, curDev, outputs)),
                              style: TextStyle(
                                fontSize: 12,
                                color: p.warning,
                                fontStyle: FontStyle.italic,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                  for (final item in outputs)
                    DropdownMenuItem<String>(
                      value: item.id.isNotEmpty ? item.id : item.name,
                      child: Row(
                        children: [
                          Icon(
                            _getAudioDeviceIcon(item.name, isRender: true),
                            size: 14,
                            color: (item.id == curDev || item.name == curDev)
                                ? p.accent
                                : p.textDim,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              item.friendlyName,
                              style: TextStyle(
                                fontSize: 12,
                                color: (item.id == curDev || item.name == curDev)
                                    ? p.accent
                                    : p.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                // 无任何可选时控件按空 items 呈置灰态，文案按成因
                // 区分：枚举里连渲染端点都没有是「无输出设备」；有
                // 渲染端点但全是虚拟端点（被名字过滤）是「仅有虚拟
                // 输出端点」（第七轮 S2 项 5 极端口径）；被互斥撤
                // 空是用户规格的「无可用声卡」。
                hint: noItems
                    ? (model.filteredWasapiOutputs.isEmpty
                        ? (model.wasapiDevices.any((d) => d.isRender)
                            ? l.ioOnlyVirtualOutputs
                            : l.ioNoOutputDevices)
                        : l.ioNoAvailableSoundCard)
                    : (outputs.isEmpty && !inputBlocksDefault
                        ? l.ioNoOutputDevices
                        : null),
                onChanged: overriddenByBridge
                    ? null
                    : (v) {
                        if (v != null) model.setPipelineOutputDevice(v);
                      },
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(
              l.ioRefreshDevice,
              icon: Icons.refresh_rounded,
              onTap: () => model.refreshAudioDevices(),
            ),
          ],
        ),
        if (info != null) ...[
          _InfoRow(
              l.sampleRate, '${info.deviceRate} Hz / ${info.deviceCh} ch'),
          _InfoRow(l.buffer, '${info.bufferFrames} frames'),
          if (info.deviceRate != model.config.sampleRate)
            _InfoRow(
                l.sampleRate,
                l.wasapiSrFallback('${info.deviceRate}',
                    '${model.config.sampleRate}')),
        ],
        if (model.wasapiError.isNotEmpty) ...[
          _InfoRow('WASAPI', model.wasapiError),
          Padding(
            padding: const EdgeInsets.only(top: AuraSpace.sm),
            child: AuraChip(
              l.retryNow,
              icon: Icons.refresh,
              onTap: () => model.retryWasapi(),
            ),
          ),
        ],
      ],
    );
  }
}

class _VaioOutputSubpanel extends StatelessWidget {
  final AppModel model;
  const _VaioOutputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final info = model.vaioInfo;
    final endpoints = model.vaioPhysicalEndpoints;
    final curEndpoint = model.config.vaioOutputEndpoint;
    final matched = endpoints.cast<AudioDeviceItem?>().firstWhere(
        (e) => e?.name == curEndpoint || e?.id == curEndpoint,
        orElse: () => null);
    final selectedValue = matched != null
        ? matched.name
        : (curEndpoint.isEmpty ? '' : curEndpoint);
    // 第七轮 S2（项 4 同口径）：合成链为 ASIO 桥时 VAIO 物理落点
    // 不被消费——说明行 + 置灰，与 WASAPI 输出子面板一致。
    final overriddenByAsio = model.pipelineChain == PipelineChain.asio;

    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(AuraSpace.sm),
            decoration: BoxDecoration(
              color: p.panelRaised,
              borderRadius: BorderRadius.circular(AuraRadius.sm),
              border: Border.all(color: p.warning.withValues(alpha: 0.4)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.info_outline, size: 16, color: p.warning),
                    const SizedBox(width: AuraSpace.xs),
                    Expanded(
                      child: Text(l.virtualSinkNotice,
                          style: captionOf(p, color: p.warning)),
                    ),
                  ],
                ),
                const SizedBox(height: AuraSpace.sm),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(l.monitorMirroring, style: labelOf(p, size: 12)),
                    AuraSwitch(
                      value: model.monitorMirroring,
                      onChanged: (v) => model.setMonitorMirroring(v),
                    ),
                  ],
                ),
                Text(l.monitorMirroringHint,
                    style: monoOf(p, size: 10, color: p.textDim)),
              ],
            ),
          ),
          const SizedBox(height: AuraSpace.sm),
          if (overriddenByAsio) ...[
            _InfoRow(l.ioPhysicalOutput, l.ioOutputOverriddenByAsio),
            const SizedBox(height: AuraSpace.sm),
          ],
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.ioPhysicalOutput,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: AuraDropdown<String>(
                value: selectedValue,
                items: [
                  DropdownMenuItem<String>(
                    value: '',
                    child: Row(
                      children: [
                        Icon(Icons.auto_mode_rounded,
                            size: 14,
                            color: curEndpoint.isEmpty ? p.accent : p.textDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(l.ioAutoSelect,
                              style: TextStyle(
                                  fontSize: 12,
                                  color: curEndpoint.isEmpty
                                      ? p.accent
                                      : p.text),
                              overflow: TextOverflow.ellipsis),
                        ),
                      ],
                    ),
                  ),
                  if (curEndpoint.isNotEmpty && matched == null)
                    DropdownMenuItem<String>(
                      value: curEndpoint,
                      child: Row(
                        children: [
                          Icon(Icons.link_off_rounded,
                              size: 14, color: p.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                                l.setOfflineSuffix(_formatOfflineDeviceName(l, curEndpoint, endpoints)),
                                style: TextStyle(
                                    fontSize: 12,
                                    color: p.warning,
                                    fontStyle: FontStyle.italic),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                  for (final ep in endpoints)
                    DropdownMenuItem<String>(
                      value: ep.name,
                      child: Row(
                        children: [
                          Icon(
                            _getAudioDeviceIcon(ep.name, isRender: true),
                            size: 14,
                            color: (ep.name == curEndpoint || ep.id == curEndpoint)
                                ? p.accent
                                : p.textDim,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(ep.friendlyName,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: (ep.name == curEndpoint || ep.id == curEndpoint)
                                        ? p.accent
                                        : p.text),
                                overflow: TextOverflow.ellipsis),
                          ),
                        ],
                      ),
                    ),
                ],
                hint: endpoints.isEmpty ? l.ioNoPhysicalOutputs : null,
                onChanged: overriddenByAsio
                    ? null
                    : (v) {
                        if (v != null) model.setVaioOutputEndpoint(v);
                      },
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(l.asioRefresh,
                icon: Icons.refresh_rounded,
                onTap: () => model.refreshVaioDetect()),
          ]),
          if (info['note'] is String && (info['note'] as String).isNotEmpty)
            _InfoRow('AuraVAIO', '${info['note']}'),
          if (model.vaioActive) ...[
            if (info['sr'] is num)
              _InfoRow(l.sampleRate, '${(info['sr'] as num).toInt()} Hz / 2 ch'),
            if (info['frames'] is num)
              _InfoRow(l.ioProcessedFrames, '${(info['frames'] as num).toInt()} frames'),
            if (info['outputEndpoint'] is String &&
                (info['outputEndpoint'] as String).isNotEmpty)
              _InfoRow(l.ioOutputLabel, '${info['outputEndpoint']}'),
          ],
        ],
      ),
    );
  }
}

class _AsioClientOutputSubpanel extends StatelessWidget {
  final AppModel model;
  const _AsioClientOutputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final active = model.asioActive;
    final l = l10nOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.ioOutputLabel, l.ioAsioHwOutput),
        _InfoRow(l.ioChannelMap,
            l.ioChannelPair(model.config.asioOutPair * 2 + 1,
                model.config.asioOutPair * 2 + 2)),
        _InfoRow(l.ioOutputStatus, active ? l.ioAsioPassthrough : l.ioAsioReadyStatus),
        // V-04/R4+R5：ASIO Client 的【设置】控件（驱动选择/缓冲/
        // 声道对）归输出层管理，此前混在只读的驱动信息层。
        const SizedBox(height: AuraSpace.sm),
        HbBuilder(
            tick: model.hbTick,
            builder: (_) => _AsioClientDriverRow(model: model)),
      ],
    );
  }
}

class _TestSourceChips extends StatelessWidget {
  final AppModel model;
  const _TestSourceChips({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Wrap(
        spacing: AuraSpace.sm,
        runSpacing: AuraSpace.sm,
        children: [
          AuraChip(
            l.srcTone,
            icon: Icons.graphic_eq,
            selected: model.playing && model.sourceKind == 'tone',
            onTap: () => model.setSource('tone'),
          ),
          AuraChip(
            l.srcPink,
            icon: Icons.blur_on,
            selected: model.playing && model.sourceKind == 'pink',
            onTap: () => model.setSource('pink'),
          ),
          AuraChip(
            l.srcFile,
            icon: Icons.folder_open_outlined,
            selected: model.playing &&
                model.sourceKind == 'file' &&
                model.sourceExt != 'mp3',
            onTap: () async {
              final path = await AuraPathPickerDialog.show(
                context,
                title: l.srcFile,
                prompt: l.testAudioWavPrompt,
                allowedExtensions: const ['wav'],
                memorySlot: PathMemory.slotTestAudio,
                confirmLabel: l.testAudioLoad,
              );
              if (path != null) {
                model.setSource('file', path: path);
              }
            },
          ),
          AuraChip(
            l.srcMp3,
            icon: Icons.music_note_outlined,
            selected: model.playing &&
                model.sourceKind == 'file' &&
                model.sourceExt == 'mp3',
            onTap: () async {
              final path = await AuraPathPickerDialog.show(
                context,
                title: l.srcMp3,
                prompt: l.testAudioMp3Prompt,
                allowedExtensions: const ['mp3'],
                memorySlot: PathMemory.slotTestAudio,
                confirmLabel: l.testAudioLoad,
              );
              if (path != null) {
                model.setSource('file', path: path);
              }
            },
          ),
          if (model.sourceKind == 'file' && model.fileChannels > 2) ...[
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
          if (model.playing)
            AuraChip(
              l.srcStop,
              icon: Icons.stop_rounded,
              danger: true,
              selected: true,
              onTap: () => model.setSource('stop'),
            ),
        ],
      ),
    );
  }
}

