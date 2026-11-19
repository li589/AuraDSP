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
                // 第四十四轮 S2（user 裁定）：VAIO 输入指引（简化
                // 版）自子面板末行移入本气泡；ASIO 指引同型移入。
                InfoBadge(
                    message: model.pipelineInput == AudioModes.inputVaio
                        ? l.ioVaioGuideShort
                        : model.pipelineInput == AudioModes.inputAsioDriver
                            ? l.ioAsioGuide
                            : l.tooltipInputWasapi),
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
    // 项 4 一致性（呈现层）：合成链为 VAIO 桥时输入被桥吸收
    // （桥只吃 VAIO 端点），本子面板的选择不生效——加说明行并
    // 置灰下拉，避免挂着「离线未连接」的设备行误导用户以为
    // 输入已断链。不改状态、不改合成矩阵。
    final overriddenByVaio = model.pipelineChain == PipelineChain.vaio;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (overriddenByVaio) ...[
          _InfoRow(l.inputDeviceLabel, l.ioInputOverriddenByVaio),
          const SizedBox(height: AuraSpace.xs),
        ],
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
                onChanged: overriddenByVaio
                    ? null
                    : (v) {
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
        // 第三十七轮（业主目检裁定）：末行模式说明文字删除
        // （原「默认内录/环回模式：实时…」与独占说明）——下拉
        // 项上的环回/录音标签已表意。
      ],
    );
  }
}

class _VaioInputSubpanel extends StatelessWidget {
  final AppModel model;
  const _VaioInputSubpanel({required this.model});

  // 端点声道数 -> 布局名（与音频页声道档位口径一致：2=Stereo、
  // 4=4.0、6=5.1、8=7.1；其余档位直写声道数）。
  static String _layoutLabel(int ch) => switch (ch) {
        1 => 'Mono',
        2 => 'Stereo',
        4 => '4.0',
        6 => '5.1',
        8 => '7.1',
        _ => '$ch ch',
      };

  static String _rateLabel(int rate) => rate % 1000 == 0
      ? '${rate ~/ 1000} kHz'
      : '${(rate / 1000).toStringAsFixed(1)} kHz';

  @override
  Widget build(BuildContext context) {
    final active = model.vaioActive;
    final l = l10nOf(context);
    // r57 P1（user 建议）：端点括号内显示系统实时声道布局，并新增
    // 工作格式行（系统设置的位深/采样率）——数据源为设备扫描的端点
    // 共享格式（统一系统监听在格式变更时触发重扫）。未扫到格式时
    // 回退旧静态文案且不显示工作格式行（不编造数值）。
    final ep = model.vaioRenderEndpoint;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(
            l.ioInputLabel,
            (ep != null && ep.ch > 0)
                ? l.ioVaioEndpointDescLayout(_layoutLabel(ep.ch))
                : l.ioVaioEndpointDesc),
        _InfoRow(l.ioChannelStatus, active ? l.ioVaioActive : l.ioVaioReady),
        if (ep != null && ep.rate > 0 && ep.bits > 0)
          _InfoRow(l.ioWorkFormat,
              l.ioWorkFormatValue(ep.bits, _rateLabel(ep.rate))),
        // 指引文案已移至输入层标题旁气泡（第四十四轮 S2）。
      ],
    );
  }
}

class _VirtualAsioInputSubpanel extends StatelessWidget {
  final AppModel model;
  const _VirtualAsioInputSubpanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final active = model.asioActive;
    final l = l10nOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.ioInputLabel, 'AuraDSP Virtual ASIO Client Stream'),
        _InfoRow(l.ioAsioChannelLabel, active ? l.ioAsioActive : l.ioAsioWait),
        // 指引文案已移至输入层标题旁气泡（第四十四轮 S2）。
      ],
    );
  }
}

