part of '../../settings_page.dart';
// P1-1b（2026-10-23）：hardware 再拆——管线三层 + 驱动行（ASIO/VAIO/WASAPI/VASIO）。



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
                            child: Text(l.setDriverOffline(curDriver),
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
    final l = l10nOf(context);
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
                        ? l.setVaioReady
                        : l.setVaioMissing,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: found ? p.success : p.warning,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    l.setVaioDesc,
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
                    l.setInstallDriverUac,
                    icon: Icons.admin_panel_settings,
                    selected: true,
                    onTap: () async {
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text(l.setInstallDriverUacPrompt),
                        duration: const Duration(milliseconds: 2000),
                      ));
                      final ok = await model.installVaioDriver(elevated: true);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? l.setVaioInstallOk
                              : (model.lastVaioError ?? l.setDriverInstallFailed)),
                          duration: const Duration(milliseconds: 2500),
                        ));
                      }
                    },
                  )
                else
                  AuraChip(
                    l.setUninstallDriver,
                    icon: Icons.delete_outline,
                    danger: true,
                    onTap: () async {
                      final ok = await model.uninstallVaioDriver(elevated: true);
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? l.setVaioUninstallOk
                              : l.setDriverUninstallFailed),
                          duration: const Duration(milliseconds: 2000),
                        ));
                      }
                    },
                  ),
                AuraChip(
                  l.setRedetect,
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
    final l = l10nOf(context);
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
                        : l.setWasapiDesc,
                    style: monoOf(p, size: 10, color: p.textDim),
                  ),
                ],
              ),
            ),
            AuraChip(
              l.setRefreshDevice,
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
                l.setAsioRegisterUac,
                icon: Icons.admin_panel_settings,
                selected: true,
                onTap: () async {
                  ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                    content: Text(l.setAsioRegisterPrompt),
                    duration: const Duration(milliseconds: 1500),
                  ));
                  final ok = await model.registerAsioDriver(elevated: true);
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok
                          ? l.setAsioRegisterOk
                          : (model.lastAsioError ?? l.setAsioRegisterFailed)),
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
                      content: Text(ok
                          ? l.setAsioUnregisterOk
                          : (model.lastAsioError ?? l.setAsioUnregisterFailed)),
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

