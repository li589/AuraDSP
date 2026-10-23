part of '../../settings_page.dart';
// P1-1b（2026-10-23）：hardware 再拆——输入/输出层与各子面板 + 测试音源。



/* ---- 第二层：输入的信息和开关 ---- */

class _InputLayer extends StatelessWidget {
  final AppModel model;
  const _InputLayer({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final enabled = model.pipelineInputEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.input_rounded, size: 15, color: p.accent),
                const SizedBox(width: AuraSpace.xs),
                Text(l.inputLayerTitle,
                    style: sectionOf(p, color: p.text)),
                const SizedBox(width: AuraSpace.xs),
                InfoBadge(message: l.tooltipInputWasapi),
              ],
            ),
            AuraSwitch(
              value: enabled,
              onChanged: (v) => model.setPipelineInputEnabled(v),
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
                Icon(Icons.mic_off_outlined, size: 15, color: p.textDim),
                const SizedBox(width: AuraSpace.xs),
                Expanded(
                  child: Text(
                    l.inputDisabledNotice,
                    style: captionOf(p, color: p.textDim),
                  ),
                ),
              ],
            ),
          )
        else ...[
          if (model.pipelineInput == AudioModes.inputWasapi)
            _WasapiInputSubpanel(model: model)
          else if (model.pipelineInput == AudioModes.inputVaio)
            _VaioInputSubpanel(model: model)
          else
            _VirtualAsioInputSubpanel(model: model),
        ],
      ],
    );
  }
}

class _WasapiInputSubpanel extends StatelessWidget {
  final AppModel model;
  const _WasapiInputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final inputs = model.filteredWasapiInputs;
    final curDev = model.pipelineInputDevice;
    final matched = inputs.cast<AudioDeviceItem?>().firstWhere(
        (d) => d?.id == curDev || d?.name == curDev,
        orElse: () => null);
    final selectedValue = matched != null
        ? (matched.id.isNotEmpty ? matched.id : matched.name)
        : (curDev.isEmpty ? '' : curDev);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: 104,
              child: Text(l.inputDeviceLabel,
                  style: labelOf(p, size: 12, color: p.textDim)),
            ),
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
                            color: curDev.isEmpty ? p.accent : p.textDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l.defaultInputDevice,
                            style: TextStyle(
                              fontSize: 12,
                              color: curDev.isEmpty ? p.accent : p.text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: curDev.isEmpty
                                ? p.accent.withValues(alpha: 0.15)
                                : p.hairline.withValues(alpha: 0.3),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            l.tagLoopback,
                            style: TextStyle(
                              fontSize: 9,
                              color: curDev.isEmpty ? p.accent : p.textDim,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (curDev.isNotEmpty && matched == null)
                    DropdownMenuItem<String>(
                      value: curDev,
                      child: Row(
                        children: [
                          Icon(Icons.link_off_rounded,
                              size: 14, color: p.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l.setOfflineSuffix(_formatOfflineDeviceName(l, curDev, inputs)),
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
                  for (final item in inputs)
                    DropdownMenuItem<String>(
                      value: item.id.isNotEmpty ? item.id : item.name,
                      child: Row(
                        children: [
                          Icon(
                            _getAudioDeviceIcon(item.name,
                                isRender: item.isRender),
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
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 4, vertical: 1),
                            decoration: BoxDecoration(
                              color: (item.id == curDev || item.name == curDev)
                                  ? p.accent.withValues(alpha: 0.15)
                                  : p.hairline.withValues(alpha: 0.3),
                              borderRadius: BorderRadius.circular(3),
                            ),
                            child: Text(
                              item.isRender
                                  ? l.tagLoopback
                                  : l.tagRecording,
                              style: TextStyle(
                                fontSize: 9,
                                color: (item.id == curDev || item.name == curDev)
                                    ? p.accent
                                    : p.textDim,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                hint: inputs.isEmpty ? l.ioNoInputDevices : null,
                onChanged: (v) {
                  if (v != null) model.setPipelineInputDevice(v);
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
        const SizedBox(height: 4),
        Text(
          curDev.isEmpty ? l.ioLoopbackDesc : l.ioExclusiveDesc,
          style: monoOf(p, size: 10, color: p.textDim),
        ),
      ],
    );
  }
}

class _VaioInputSubpanel extends StatelessWidget {
  final AppModel model;
  const _VaioInputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final active = model.vaioActive;
    final l = l10nOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.ioInputLabel, l.ioVaioEndpointDesc),
        _InfoRow(l.ioChannelStatus, active ? l.ioVaioActive : l.ioVaioReady),
        const SizedBox(height: 2),
        Text(
          l.ioVaioGuide,
          style: monoOf(p, size: 10, color: p.textDim),
        ),
      ],
    );
  }
}

class _VirtualAsioInputSubpanel extends StatelessWidget {
  final AppModel model;
  const _VirtualAsioInputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final active = model.asioActive;
    final l = l10nOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.ioInputLabel, 'AuraDSP Virtual ASIO Client Stream'),
        _InfoRow(l.ioAsioChannelLabel, active ? l.ioAsioActive : l.ioAsioWait),
        const SizedBox(height: 2),
        Text(
          l.ioAsioGuide,
          style: monoOf(p, size: 10, color: p.textDim),
        ),
      ],
    );
  }
}

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
    final outputs = model.filteredWasapiOutputs;
    final curDev = model.pipelineOutputDevice;
    final matched = outputs.cast<AudioDeviceItem?>().firstWhere(
        (d) => d?.id == curDev || d?.name == curDev,
        orElse: () => null);
    final selectedValue = matched != null
        ? (matched.id.isNotEmpty ? matched.id : matched.name)
        : (curDev.isEmpty ? '' : curDev);
    final info = model.info;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.outputWasapi, l.ioWasapiRenderDesc),
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
                  if (curDev.isNotEmpty && matched == null)
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
                hint: outputs.isEmpty ? l.ioNoOutputDevices : null,
                onChanged: (v) {
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
                onChanged: (v) {
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
              const type = XTypeGroup(label: 'WAV', extensions: ['wav']);
              final f = await openFile(
                acceptedTypeGroups: [type],
                initialDirectory: PathMemory.dirFor(PathMemory.slotTestAudio) ??
                    PathMemory.fallbackDir(PathMemory.slotTestAudio),
              );
              if (f != null) {
                PathMemory.recordPick(PathMemory.slotTestAudio, f.path);
                model.setSource('file', path: f.path);
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
              const type = XTypeGroup(label: 'MP3', extensions: ['mp3']);
              final f = await openFile(
                acceptedTypeGroups: [type],
                initialDirectory: PathMemory.dirFor(PathMemory.slotTestAudio) ??
                    PathMemory.fallbackDir(PathMemory.slotTestAudio),
              );
              if (f != null) {
                PathMemory.recordPick(PathMemory.slotTestAudio, f.path);
                model.setSource('file', path: f.path);
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

