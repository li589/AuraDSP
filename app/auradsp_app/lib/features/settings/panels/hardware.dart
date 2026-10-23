part of '../../settings_page.dart';
// part of '../settings_page.dart' —— P1-1（2026-10-23）机械拆分，零逻辑改动。


/* ---- 04 管线模式三层设备卡（ADR-009：驱动层 / 输入层 / 输出层） ---- */

class _PipelineThreeLayerCard extends StatelessWidget {
  final AppModel model;
  const _PipelineThreeLayerCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 第一层：驱动的信息和按钮
        _DriverLayer(model: model),

        const SizedBox(height: AuraSpace.md),
        Container(height: 1, color: p.hairline),
        const SizedBox(height: AuraSpace.md),

        // 第二层：输入的信息和开关
        _InputLayer(model: model),

        const SizedBox(height: AuraSpace.md),
        Container(height: 1, color: p.hairline),
        const SizedBox(height: AuraSpace.md),

        // 第三层：输出的信息和开关
        _OutputLayer(model: model),
      ],
    );
  }
}

/* ---- 第一层：驱动的信息和控制 ---- */

class _DriverLayer extends StatelessWidget {
  final AppModel model;
  const _DriverLayer({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    final widgets = <Widget>[];

    // 如果输出是 ASIO Client：显示专业 ASIO 驱动选择、缓冲档、输出声道对、刷新入口
    if (model.pipelineOutput == AudioModes.outputAsioClient) {
      widgets.add(HbBuilder(
          tick: model.hbTick,
          builder: (_) => _AsioClientDriverRow(model: model)));
    }

    // 如果输入是虚拟 ASIO 驱动：显示 AuraDSP Virtual ASIO 驱动注册状态与 DAW 状态卡片
    if (model.pipelineInput == AudioModes.inputAsioDriver) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: AuraSpace.sm));
      }
      widgets.add(_VirtualAsioDriverCard(model: model));
    }

    // 如果输入或输出使用了 AuraVAIO：显示 AuraVAIO KMDF 虚拟声卡驱动状态
    if (model.pipelineInput == AudioModes.inputVaio ||
        model.pipelineOutput == AudioModes.outputVaio) {
      if (widgets.isNotEmpty) {
        widgets.add(const SizedBox(height: AuraSpace.sm));
      }
      widgets.add(_VaioDriverRow(model: model));
    }

    // 如果输入和输出均为 WASAPI 标准模式：显示 Windows WASAPI 引擎状态与刷新
    if (model.pipelineInput == AudioModes.inputWasapi &&
        model.pipelineOutput == AudioModes.outputWasapi) {
      widgets.add(_WasapiDriverRow(model: model));
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.developer_board_rounded, size: 15, color: p.accent),
            const SizedBox(width: AuraSpace.xs),
            Text(l.driverLayerTitle,
                style: sectionOf(p, color: p.text)),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        ...widgets,
      ],
    );
  }
}

class _AsioClientDriverRow extends StatelessWidget {
  final AppModel model;
  const _AsioClientDriverRow({required this.model});

  static const _bufSizes = [0, 64, 128, 256, 512, 1024, 2048];
  static const _outPairs = [0, 1, 2, 3];

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final drivers = model.asioDrivers;
    final names = [for (final d in drivers) d['name'] ?? ''];
    final curDriver = model.config.asioDriver;
    final sel = curDriver.isNotEmpty
        ? curDriver
        : (names.isNotEmpty ? names.first : '');
    final note = model.asioDriversNote;
    final info = model.asioInfo;

    return ListenableBuilder(
      listenable: model,
      builder: (_, _) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioDriver,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: names.isEmpty && curDriver.isEmpty
                  ? Text('—', style: monoOf(p, size: 12))
                  : AuraDropdown<String>(
                      value: sel,
                      items: [
                        if (curDriver.isNotEmpty && !names.contains(curDriver))
                          DropdownMenuItem<String>(
                            value: curDriver,
                            child: Text('$curDriver [未检测到/离线]',
                                style: TextStyle(
                                    fontSize: 12,
                                    color: p.warning,
                                    fontStyle: FontStyle.italic),
                                overflow: TextOverflow.ellipsis),
                          ),
                        for (final n in names)
                          DropdownMenuItem<String>(
                            value: n,
                            child: Text(n,
                                style: TextStyle(
                                    fontSize: 12,
                                    color: n == sel ? p.accent : p.text),
                                overflow: TextOverflow.ellipsis),
                          ),
                      ],
                      hint: '—',
                      onChanged: (v) {
                        if (v != null) model.setAsioDriver(v);
                      },
                    ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(l.asioRefresh,
                icon: Icons.refresh_rounded,
                onTap: () => model.refreshAsioDrivers()),
          ]),
          if (note.isNotEmpty) _InfoRow('ASIO', note),
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioBufSize,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: AuraDropdown<int>(
                value: _bufSizes.contains(model.config.asioBufSize)
                    ? model.config.asioBufSize
                    : 0,
                items: [
                  for (final b in _bufSizes)
                    DropdownMenuItem<int>(
                      value: b,
                      child: Text(
                          b == 0 ? l.asioBufAuto : '$b frames',
                          style: TextStyle(
                              fontSize: 12,
                              color: b == model.config.asioBufSize
                                  ? p.accent
                                  : p.text)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) model.setAsioBufSize(v);
                },
              ),
            ),
          ]),
          const SizedBox(height: AuraSpace.xs),
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioOutPair,
                    style: labelOf(p, size: 12, color: p.textDim))),
            Expanded(
              child: AuraDropdown<int>(
                value: _outPairs.contains(model.config.asioOutPair)
                    ? model.config.asioOutPair
                    : 0,
                items: [
                  for (final n in _outPairs)
                    DropdownMenuItem<int>(
                      value: n,
                      child: Text('ch ${n * 2 + 1}/${n * 2 + 2}',
                          style: TextStyle(
                              fontSize: 12,
                              color: n == model.config.asioOutPair
                                  ? p.accent
                                  : p.text)),
                    ),
                ],
                onChanged: (v) {
                  if (v != null) model.setAsioOutPair(v);
                },
              ),
            ),
          ]),
          if (model.asioActive) ...[
            if (info['inCh'] is num && info['outCh'] is num)
              _InfoRow(l.asioDeviceChannels,
                  'IN ${info['inCh']} / OUT ${info['outCh']}'),
            if (info['ioCh'] is num && (info['ioCh'] as num) > 2)
              _InfoRow(l.asioTransportChannels, '${info['ioCh']} ch'),
            _InfoRow(l.asioSwitches, '${info['switches'] ?? 0}'),
            if (info['sr'] is num)
              _InfoRow(l.sampleRate,
                  '${(info['sr'] as num).toInt()} Hz / ${info['nbs'] ?? '?'} frames'),
            if ((info['dropouts'] as int? ?? 0) > 0)
              _InfoRow(l.asioDropouts, '${info['dropouts']}'),
            if ((info['latenciesChanged'] as int? ?? 0) == 1)
              _InfoRow('ASIO', l.asioLatChanged),
            if (info['sr'] is num &&
                (info['sr'] as num).toInt() != model.config.sampleRate)
              _InfoRow(
                  l.sampleRate,
                  l.asioSrMismatch('${(info['sr'] as num).toInt()}',
                      '${model.config.sampleRate}')),
          ],
        ],
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  final String message;
  final VoidCallback? onDismiss;
  const _ErrorBanner({required this.message, this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      margin: const EdgeInsets.only(top: AuraSpace.xs + 2),
      padding: const EdgeInsets.symmetric(
          horizontal: AuraSpace.sm + 2, vertical: AuraSpace.xs + 2),
      decoration: BoxDecoration(
        color: p.error.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.error.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.warning_amber_rounded, size: 16, color: p.error),
          const SizedBox(width: AuraSpace.sm),
          Expanded(
            child: Text(
              message,
              style: TextStyle(fontSize: 11.5, color: p.error),
            ),
          ),
          if (onDismiss != null)
            GestureDetector(
              onTap: onDismiss,
              child: Padding(
                padding: const EdgeInsets.all(2),
                child: Icon(Icons.close_rounded, size: 14, color: p.error),
              ),
            ),
        ],
      ),
    );
  }
}

class _VaioDriverRow extends StatelessWidget {
  final AppModel model;
  const _VaioDriverRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final det = model.vaioDetectInfo;
    final found = det['found'] == true;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    found
                        ? 'AuraVAIO KMDF 驱动已就绪 (Sysvad 虚拟声卡)'
                        : '未检测到 AuraVAIO 虚拟声卡驱动',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: found ? p.success : p.warning,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    'KMDF 内核模式虚拟音频驱动，提供全双工虚拟音频线缆通道',
                    style: monoOf(p, size: 10, color: p.textDim),
                  ),
                ],
              ),
            ),
            Wrap(
              spacing: AuraSpace.sm,
              children: [
                if (!found)
                  AuraChip(
                    'UAC提权安装驱动',
                    icon: Icons.admin_panel_settings,
                    selected: true,
                    onTap: () async {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('正在唤起 Windows UAC 授权弹窗，请在系统提示中点击“是”允许安装驱动...'),
                        duration: Duration(milliseconds: 2000),
                      ));
                      final ok = await model.installVaioDriver(elevated: true);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? 'AuraVAIO 驱动已成功安装并通过系统验收！'
                              : (model.lastVaioError ?? '驱动安装未完成')),
                          duration: const Duration(milliseconds: 2500),
                        ));
                      }
                    },
                  )
                else
                  AuraChip(
                    '卸载驱动',
                    icon: Icons.delete_outline,
                    danger: true,
                    onTap: () async {
                      final ok = await model.uninstallVaioDriver(elevated: true);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok ? 'AuraVAIO 驱动已成功卸载' : '卸载未完成'),
                          duration: const Duration(milliseconds: 2000),
                        ));
                      }
                    },
                  ),
                AuraChip(
                  '重新检测',
                  icon: Icons.refresh_rounded,
                  onTap: () => model.refreshVaioDetect(),
                ),
              ],
            ),
          ],
        ),
        if (model.lastVaioError != null)
          _ErrorBanner(
            message: model.lastVaioError!,
            onDismiss: () => model.clearVaioError(),
          ),
      ],
    );
  }
}

class _WasapiDriverRow extends StatelessWidget {
  final AppModel model;
  const _WasapiDriverRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final info = model.info;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Windows CoreAudio WASAPI Engine',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: p.text,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    info != null
                        ? 'ABI v${info.abi} · ${info.version} · ${info.deviceRate}Hz'
                        : '系统底层 WASAPI 共享/独占音频引擎，无额外驱动依赖',
                    style: monoOf(p, size: 10, color: p.textDim),
                  ),
                ],
              ),
            ),
            AuraChip(
              '刷新设备',
              icon: Icons.refresh_rounded,
              onTap: () => model.refreshAudioDevices(),
            ),
          ],
        ),
        if (model.lastAudioError != null)
          _ErrorBanner(
            message: model.lastAudioError!,
            onDismiss: () => model.clearAudioError(),
          ),
      ],
    );
  }
}

class _VirtualAsioDriverCard extends StatelessWidget {
  final AppModel model;
  const _VirtualAsioDriverCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(l.asioDriverCardTitle,
                style: sectionOf(p, color: p.text)),
            AuraChip(
              l.asioStatusCheck,
              icon: Icons.refresh_rounded,
              onTap: () => model.checkAsioDriverStatus(),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        _InfoRow(
          l.asioDriverStatus,
          model.asioDriverInstalled
              ? l.asioDriverRegistered
              : l.asioDriverNotRegistered,
        ),
        _InfoRow(
          l.asioDawStatus,
          model.asioActive ? l.asioDawConnected : l.asioDawIdle,
        ),
        const SizedBox(height: AuraSpace.sm),
        Wrap(
          spacing: AuraSpace.sm,
          children: [
            if (!model.asioDriverInstalled)
              AuraChip(
                'UAC提权注册驱动',
                icon: Icons.admin_panel_settings,
                selected: true,
                onTap: () async {
                  ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                    content: Text('正在唤起 Windows UAC 授权弹窗注册虚拟 ASIO 驱动...'),
                    duration: Duration(milliseconds: 1500),
                  ));
                  final ok = await model.registerAsioDriver(elevated: true);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok
                          ? '虚拟 ASIO 驱动注册成功！DAW 中现已可选'
                          : (model.lastAsioError ?? '注册失败，请使用管理员权限重试')),
                      duration: const Duration(milliseconds: 2500),
                    ));
                  }
                },
              )
            else
              AuraChip(
                l.asioDriverActionUnregister,
                icon: Icons.remove_circle_outline,
                danger: true,
                onTap: () async {
                  final ok = await model.unregisterAsioDriver(elevated: true);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok ? '虚拟 ASIO 驱动已从系统注销' : (model.lastAsioError ?? '注销失败，请使用管理员权限重试')),
                      duration: const Duration(milliseconds: 2000),
                    ));
                  }
                },
              ),
          ],
        ),
        if (model.lastAsioError != null)
          _ErrorBanner(
            message: model.lastAsioError!,
            onDismiss: () => model.clearAsioError(),
          ),
      ],
    );
  }
}


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
                              '${_formatOfflineDeviceName(curDev, inputs)} [离线/未连接]',
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
                hint: inputs.isEmpty ? '无可用输入设备' : null,
                onChanged: (v) {
                  if (v != null) model.setPipelineInputDevice(v);
                },
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(
              '刷新设备',
              icon: Icons.refresh_rounded,
              onTap: () => model.refreshAudioDevices(),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          curDev.isEmpty
              ? '默认内录/环回模式：实时采集系统主回放端点音频'
              : '针对指定硬件/虚拟端口进行低延迟 WASAPI 独占/共享采集',
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow('输入端点', 'AuraVAIO 虚拟输入端点 (Stereo / 7.1 ch)'),
        _InfoRow('通道状态', active ? '活跃传输中 (全双工 DMA 环形缓冲)' : '就绪 (等待系统/应用推流)'),
        const SizedBox(height: 2),
        Text(
          '请在 Windows 声音设置或播放器中将默认输出选择为 "AuraVAIO"，声音将通过此虚拟输入端点送入 AuraDSP 核心管线处理。',
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow('输入端点', 'AuraDSP Virtual ASIO Client Stream'),
        _InfoRow('输入通道', active ? 'DAW 实时注入 (活跃)' : '等待 DAW 连接 (宿主未开启)'),
        const SizedBox(height: 2),
        Text(
          '在 DAW (FL Studio / Cubase / Reaper / Ableton) 的 Audio Device 中选择 "AuraDSP Virtual ASIO" 即可将工程音频路由至此。',
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
        _InfoRow(l.outputWasapi, 'WASAPI 物理渲染 (扬声器/耳机)'),
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
                              '${_formatOfflineDeviceName(curDev, outputs)} [离线/未连接]',
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
                hint: outputs.isEmpty ? '无可用输出设备' : null,
                onChanged: (v) {
                  if (v != null) model.setPipelineOutputDevice(v);
                },
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(
              '刷新设备',
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
                child: Text('物理输出',
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
                          child: Text('自动选择（非VAIO扬声器）',
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
                                '${_formatOfflineDeviceName(curEndpoint, endpoints)} [离线/未连接]',
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
                hint: endpoints.isEmpty ? '无可用物理输出设备' : null,
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
              _InfoRow('已处理帧', '${(info['frames'] as num).toInt()} frames'),
            if (info['outputEndpoint'] is String &&
                (info['outputEndpoint'] as String).isNotEmpty)
              _InfoRow('输出端点', '${info['outputEndpoint']}'),
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

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow('输出端点', 'AuraDSP ASIO Client 硬件输出'),
        _InfoRow('声道映射',
            '通道 ${model.config.asioOutPair * 2 + 1} / ${model.config.asioOutPair * 2 + 2}'),
        _InfoRow('输出状态', active ? '正在直通硬件监听 (超低延迟)' : '就绪 (等待驱动会话)'),
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

