part of '../../settings_page.dart';
// P1-1c（2026-10-23）：hardware_io 再拆——输入层（WASAPI/VAIO/VASIO 输入子面板）。




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

