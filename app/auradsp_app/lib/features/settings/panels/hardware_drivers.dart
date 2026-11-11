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
 *   组合），可见性不再被范式选择裁剪。
 *
 * 版式统一（2026-11-10 晚，用户裁定）：每个驱动一律走 _DriverBlock
 * ——左侧文字栏（驱动名 12/600 + 状态行 + 明细行，左对齐）、动作
 * 按钮同行右侧右对齐；整层最后一行恒为操作系统信息。Linux 设备
 * 面（sections.dart 的 _LinuxDevicePanel）同口径。 */

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

/* ---- 驱动块统一版式（2026-11-10 用户裁定） ----
 * 一块 = 一行：左 = 文字栏（标题 + 若干状态/明细行），右 = 动作
 * 按钮组（右对齐、与文字同行）；below 承错误条等整宽尾随件。
 * 字号口径全层唯一：标题 12/600、状态行 11.5/500、明细 mono 10、
 * 键值行标签 11（宽 76）+ 值 mono 11。Windows 三块与 Linux 设备
 * 面的引擎/虚拟设备/内核驱动块共用本组件。 */
class _DriverBlock extends StatelessWidget {
  final String title;
  final List<Widget> lines;
  final List<Widget> actions;
  final Widget? below;
  const _DriverBlock({
    required this.title,
    this.lines = const [],
    this.actions = const [],
    this.below,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: p.text)),
                  for (final line in lines) ...[
                    const SizedBox(height: 2),
                    line,
                  ],
                ],
              ),
            ),
            if (actions.isNotEmpty) ...[
              const SizedBox(width: AuraSpace.sm),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: AuraSpace.sm,
                runSpacing: AuraSpace.xs,
                children: actions,
              ),
            ],
          ],
        ),
        ?below,
      ],
    );
  }
}

/// 驱动块状态行（单行小字，颜色表状态）。
class _DriverStatus extends StatelessWidget {
  final String text;
  final Color color;
  const _DriverStatus(this.text, this.color);

  @override
  Widget build(BuildContext context) => Text(text,
      style:
          TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: color));
}

/// 驱动块明细行（mono 小字，恒 dim）。
class _DriverDetail extends StatelessWidget {
  final String text;
  const _DriverDetail(this.text);

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Text(text, style: monoOf(p, size: 10, color: p.textDim));
  }
}

/// 驱动块键值行（标签左、值右接，同 _InfoRow 的紧凑版）。
class _DriverKv extends StatelessWidget {
  final String k, v;
  const _DriverKv(this.k, this.v);

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
            width: 76,
            child: Text(k, style: labelOf(p, size: 11, color: p.textDim))),
        Expanded(child: Text(v, style: monoOf(p, size: 11))),
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
          // 全面复审 S2（ASIO-3 呈现半）：起桥失败 note 上屏（与
          // VAIO 面板 note 行同口径；通知半已在 S1 落地）。
          if (info['note'] is String && (info['note'] as String).isNotEmpty)
            _InfoRow('ASIO', '${info['note']}'),
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

    return _DriverBlock(
      title: l.vaioDriverCardTitle,
      lines: [
        _DriverStatus(
          !detected
              ? l.setVaioUnknown
              : (found ? l.setVaioReady : l.setVaioMissing),
          !detected ? p.textDim : (found ? p.success : p.warning),
        ),
        _DriverDetail(l.setVaioDesc),
        // 全面复审 S2（VAIO-8）：驱动版本/track/KMDF 上屏——detect
        // 早已回传，此前无呈现点，装机版本排障只能靠日志。
        if (found && det['driverVersion'] is String)
          _DriverDetail(
              'v${det['driverVersion']} · ${det['track']} · KMDF ${det['kmdf']}'),
      ],
      actions: [
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
                    : (model.vaioActionUnverified
                        ? l.setVaioInstallUnverified
                        : (model.lastVaioError ?? l.setDriverInstallFailed)),
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
                ok
                    ? l.setVaioUninstallOk
                    : (model.vaioActionUnverified
                        ? l.setVaioUninstallUnverified
                        : l.setDriverUninstallFailed),
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
      below: model.lastVaioError == null
          ? null
          : _ErrorBanner(
              message: model.lastVaioError!,
              onDismiss: () => model.clearVaioError(),
            ),
    );
  }
}

class _WasapiDriverRow extends StatelessWidget {
  final AppModel model;
  const _WasapiDriverRow({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final info = model.info;

    return _DriverBlock(
      title: l.wasapiDriverCardTitle,
      lines: [
        _DriverDetail(info != null
            ? 'ABI v${info.abi} · ${info.version} · ${info.deviceRate}Hz'
            : l.setWasapiDesc),
      ],
      actions: [
        AuraChip(
          l.setRefreshDevice,
          icon: Icons.refresh_rounded,
          onTap: () => model.refreshAudioDevices(),
        ),
      ],
      below: model.lastAudioError == null
          ? null
          : _ErrorBanner(
              message: model.lastAudioError!,
              onDismiss: () => model.clearAudioError(),
            ),
    );
  }
}

class _VirtualAsioDriverCard extends StatelessWidget {
  final AppModel model;
  const _VirtualAsioDriverCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);

    // 版式统一（2026-11-10 用户裁定）：检测/注册/注销与状态文字同行，
    // 按钮在文字栏右侧右对齐（此前为卡底独占一行）。文字两行
    // （驱动状态 / DAW 状态）走 _DriverKv 紧凑键值行。
    return _DriverBlock(
      title: l.asioDriverCardTitle,
      lines: [
        _DriverKv(
          l.asioDriverStatus,
          model.asioDriverInstalled
              ? l.asioDriverRegistered
              : l.asioDriverNotRegistered,
        ),
        _DriverKv(
          l.asioDawStatus,
          model.asioActive ? l.asioDawConnected : l.asioDawIdle,
        ),
      ],
      actions: [
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
        // 按钮顺序（2026-11-10 用户裁定）：注册/注销在左、检测在右，
        // 与 VAIO 行一致——检测恒为按钮组最右，整组右对齐。
        AuraChip(
          l.asioStatusCheck,
          icon: Icons.refresh_rounded,
          onTap: () => model.checkAsioDriverStatus(),
        ),
      ],
      below: model.lastAsioError == null
          ? null
          : _ErrorBanner(
              message: model.lastAsioError!,
              onDismiss: () => model.clearAsioError(),
            ),
    );
  }
}

