part of '../../settings_page.dart';
// P1-1b（2026-10-23）：hardware 再拆——管线三层 + 驱动行（ASIO/VAIO/WASAPI/VASIO）。



/* ---- 第一层：驱动信息（只读状态 + 安装/检查动作） ----
 *
 * V-04 重设计（2026-11-09，真机报告 §5.3/R3–R6）：
 * - 本层只呈现 AuraDSP 自有驱动/引擎的客观状态（VAIO 三态、虚拟
 *   ASIO 注册与 DAW 连接、WASAPI 引擎版本、OS 版本），恒显示，
 *   不再按输入/输出组合裁剪（旧实现选 ASIO 输出时 VAIO 状态消失）；
 * - 一切【设置】控件不在本层：ASIO Client 的驱动/缓冲/声道对已
 *   下沉输出层（_AsioClientOutputSubpanel）；本层动作只有安装/
 *   卸载/注册/检查一类；
 * - 本层在管线与附加两种处理范式下都显示（_DynamicAudioPanel
 *   组合），可见性不再被范式选择裁剪。 */

class _DriverLayer extends StatelessWidget {
  final AppModel model;
  const _DriverLayer({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);

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
        _VaioDriverRow(model: model),
        const SizedBox(height: AuraSpace.sm),
        _VirtualAsioDriverCard(model: model),
        const SizedBox(height: AuraSpace.sm),
        _WasapiDriverRow(model: model),
        const SizedBox(height: AuraSpace.xs),
        _InfoRow(l.osVersionLabel, PlatformProfile.osVersion),
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
    // 三态（V-01）：未检测（det 为空，自动检测尚未回）不得与「已检测
    // 未发现」混为一谈——旧实现空 map 恒判 missing 是真机误报的显示面。
    final detected = det.isNotEmpty;
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
                    !detected
                        ? l.setVaioUnknown
                        : (found ? l.setVaioReady : l.setVaioMissing),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: !detected
                          ? p.textDim
                          : (found ? p.success : p.warning),
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
                if (detected && !found)
                  AuraChip(
                    l.setInstallDriverUac,
                    icon: Icons.admin_panel_settings,
                    selected: true,
                    onTap: () async {
                      model.postNotice(l.setInstallDriverUacPrompt);
                      final ok = await model.installVaioDriver(elevated: true);
                      model.postNotice(
                        ok
                            ? l.setVaioInstallOk
                            : (model.lastVaioError ?? l.setDriverInstallFailed),
                        level: ok ? NoticeLevel.info : NoticeLevel.error,
                      );
                    },
                  )
                else if (found)
                  AuraChip(
                    l.setUninstallDriver,
                    icon: Icons.delete_outline,
                    danger: true,
                    onTap: () async {
                      final ok = await model.uninstallVaioDriver(elevated: true);
                      model.postNotice(
                        ok ? l.setVaioUninstallOk : l.setDriverUninstallFailed,
                        level: ok ? NoticeLevel.info : NoticeLevel.error,
                      );
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
        // R1：注册/反注册动作同行右对齐（旧实现卡底左对齐独占一行）。
        Wrap(
          alignment: WrapAlignment.end,
          spacing: AuraSpace.sm,
          children: [
            if (!model.asioDriverInstalled)
              AuraChip(
                l.setAsioRegisterUac,
                icon: Icons.admin_panel_settings,
                selected: true,
                onTap: () async {
                  model.postNotice(l.setAsioRegisterPrompt);
                  final ok = await model.registerAsioDriver(elevated: true);
                  model.postNotice(
                    ok
                        ? l.setAsioRegisterOk
                        : (model.lastAsioError ?? l.setAsioRegisterFailed),
                    level: ok ? NoticeLevel.info : NoticeLevel.error,
                  );
                },
              )
            else
              AuraChip(
                l.asioDriverActionUnregister,
                icon: Icons.remove_circle_outline,
                danger: true,
                onTap: () async {
                  final ok = await model.unregisterAsioDriver(elevated: true);
                  model.postNotice(
                    ok
                        ? l.setAsioUnregisterOk
                        : (model.lastAsioError ?? l.setAsioUnregisterFailed),
                    level: ok ? NoticeLevel.info : NoticeLevel.error,
                  );
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

