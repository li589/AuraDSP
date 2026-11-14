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
        const SizedBox(height: AuraSpace.sm),
        _EngineEffectiveBlock(model: model),
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

/* ---- 引擎生效值回读（第三十五轮，业主立项） ----
 * 可展开/收回的状态块：收起时一行摘要（当前主引擎的回读值），
 * 展开时三引擎（本机/桥/System APO）逐行列出声道模式、未用
 * 声道铺满、声道数、采样率（APO 另带已应用参数数）。数据全部
 * 来自引擎回读——本机/桥经 isolate get_param、APO 经 telemetry
 * v6 的 auradsp_get_param 回读段——不是设置镜像：设置与回读
 * 不一致时以回读为准（第三十四轮 VAIO/APO 下混分歧的教训：
 * 光看设置值无法判定哪个引擎在跑什么）。展开期间 2 秒轮询，
 * 收起即停；首次构建时单发一次让摘要有值。 */
class _EngineEffectiveBlock extends StatefulWidget {
  final AppModel model;
  const _EngineEffectiveBlock({required this.model});

  @override
  State<_EngineEffectiveBlock> createState() => _EngineEffectiveBlockState();
}

class _EngineEffectiveBlockState extends State<_EngineEffectiveBlock> {
  bool _expanded = false;
  Timer? _poll;

  @override
  void initState() {
    super.initState();
    widget.model.requestEngineValues();
  }

  @override
  void dispose() {
    _poll?.cancel();
    super.dispose();
  }

  void _toggle() {
    setState(() => _expanded = !_expanded);
    if (_expanded) {
      widget.model.requestEngineValues();
      _poll = Timer.periodic(
          const Duration(seconds: 2), (_) => widget.model.requestEngineValues());
    } else {
      _poll?.cancel();
      _poll = null;
    }
  }

  String _fmt(AppLocalizations l,
      {int? mode, int? fill, int? rate, int? ch, int? applied}) {
    final parts = <String>[];
    if (mode != null && mode >= 0) {
      parts.add(mode == 1 ? l.effModeDiscrete : l.effModeMatrix);
    }
    if (fill != null && fill >= 0) {
      parts.add('${l.effFillLabel} ${fill == 1 ? l.effOn : l.effOff}');
    }
    if (ch != null && ch > 0) parts.add('$ch ${l.effChannelsUnit}');
    if (rate != null && rate > 0) parts.add('$rate Hz');
    if (applied != null) parts.add('${l.effApplied} $applied');
    return parts.isEmpty ? '—' : parts.join(' · ');
  }

  /// 收起态摘要：当前模式的主引擎回读一行。
  String _summary(AppLocalizations l) {
    final m = widget.model;
    if (m.audioMode == 'sysapo') {
      if (!m.apoEngineActive) return l.effNotRunning;
      return _fmt(l,
          mode: m.apoEffMode,
          fill: m.apoEffFill,
          rate: m.apoEngineRate,
          ch: m.apoEngineChannels,
          applied: m.apoParamsApplied);
    }
    final b = m.bridgeEffValues;
    if (b != null) {
      return _fmt(l, mode: b['mode'], fill: b['fill'], rate: b['rate'], ch: b['ch']);
    }
    final lo = m.localEffValues;
    if (lo != null) {
      return _fmt(l, mode: lo['mode'], fill: lo['fill'], rate: lo['rate']);
    }
    return '—';
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final m = widget.model;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: _toggle,
          borderRadius: BorderRadius.circular(6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(_expanded ? Icons.expand_less : Icons.expand_more,
                  size: 15, color: p.textDim),
              const SizedBox(width: AuraSpace.xs),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l.engineEffectiveTitle,
                        style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                            color: p.text)),
                    const SizedBox(height: 2),
                    _DriverStatus(_summary(l), p.textDim),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (_expanded) ...[
          const SizedBox(height: AuraSpace.xs),
          Padding(
            padding: const EdgeInsets.only(left: 23),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _DriverKv(
                    l.effEngineLocal,
                    m.localEffValues == null
                        ? l.effNotRunning
                        : _fmt(l,
                            mode: m.localEffValues!['mode'],
                            fill: m.localEffValues!['fill'],
                            rate: m.localEffValues!['rate'])),
                const SizedBox(height: 2),
                _DriverKv(
                    l.effEngineBridge,
                    m.bridgeEffValues == null
                        ? l.effNoBridge
                        : _fmt(l,
                            mode: m.bridgeEffValues!['mode'],
                            fill: m.bridgeEffValues!['fill'],
                            rate: m.bridgeEffValues!['rate'],
                            ch: m.bridgeEffValues!['ch'])),
                const SizedBox(height: 2),
                _DriverKv(
                    l.effEngineApo,
                    !m.apoEngineActive
                        ? l.effNotRunning
                        : _fmt(l,
                            mode: m.apoEffMode,
                            fill: m.apoEffFill,
                            rate: m.apoEngineRate,
                            ch: m.apoEngineChannels,
                            applied: m.apoParamsApplied)),
                const SizedBox(height: AuraSpace.xs),
                Text(l.engineEffectiveHint,
                    style: labelOf(p, size: 11, color: p.textDim)),
              ],
            ),
          ),
        ],
      ],
    );
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
  // 全面复审 S3（ASIO-1）：档位即「输出块起始声道偏移」（与桥
  // outBase / 配置注释同语义）；旧档位 0..3 是声道对序号，与桥的
  // 偏移消费错位一档（选 ch 3/4 实播偏移 1）。存量配置经 config
  // v4 / 会话 v8 一次性迁移按旧标签意图换算。
  static const _outPairs = [0, 2, 4, 6];

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
                      child: Text('ch ${n + 1}/${n + 2}',
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

/// 断路器暂停横幅（第二十一轮用户裁定）：崩溃断路器跳过
/// VAIO 自动起桥后，设备页必须有常驻显式状态与一键出口，
/// 不能只靠一条易错过的通知（真机实证：用户误判为驱动
/// 损坏并反复卸载驱动）。按钮即知情接管，与手动重选
/// VAIO 模式同语义（AppModel.startVaioDespiteGuard）。
class _VaioGuardBanner extends StatelessWidget {
  final AppModel model;
  const _VaioGuardBanner({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return Container(
      margin: const EdgeInsets.only(top: AuraSpace.xs + 2),
      padding: const EdgeInsets.symmetric(
          horizontal: AuraSpace.sm + 2, vertical: AuraSpace.xs + 2),
      decoration: BoxDecoration(
        color: p.warning.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.warning.withValues(alpha: 0.45)),
      ),
      child: Row(
        children: [
          Icon(Icons.pause_circle_outline_rounded,
              size: 16, color: p.warning),
          const SizedBox(width: AuraSpace.sm),
          Expanded(
            child: Text(
              l.setVaioGuardPaused,
              style: TextStyle(fontSize: 11.5, color: p.warning),
            ),
          ),
          const SizedBox(width: AuraSpace.sm),
          AuraChip(
            l.setVaioStartAnyway,
            icon: Icons.play_arrow_rounded,
            selected: true,
            onTap: () => model.startVaioDespiteGuard(),
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
    // 第十九轮（user 裁定）：VAIO 块只留标题 + 一行状态。已就绪行
    // 按 user 口径内嵌 track（auravaio kmdf modern/legacy 驱动已
    // 就绪（sysvad））；原说明行与版本/track/KMDF 明细行删除——
    // track 信息已并入状态行，版本数值排障走 detect 日志。
    final track = det['track'] is String &&
            (det['track'] as String).isNotEmpty
        ? det['track'] as String
        : 'modern';

    return _DriverBlock(
      title: l.vaioDriverCardTitle,
      lines: [
        _DriverStatus(
          !detected
              ? l.setVaioUnknown
              : (found ? l.setVaioReady(track) : l.setVaioMissing),
          !detected ? p.textDim : (found ? p.success : p.warning),
        ),
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
      below: _below(),
    );
  }

  /// 尾随区：断路器暂停横幅（在时恒显）+ 驱动动作错误条
  /// （在时其后）。两者皆无时返回 null，保持块版式紧凑。
  Widget? _below() {
    final showGuard = model.vaioGuardBlocksCurrentMode;
    if (!showGuard && model.lastVaioError == null) return null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showGuard) _VaioGuardBanner(model: model),
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
      below: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (model.lastAsioError != null)
            _ErrorBanner(
              message: model.lastAsioError!,
              onDismiss: () => model.clearAsioError(),
            ),
          // 全面复审 S3（ASIO-4）：驱动声道档位写者——此前注册表
          // Channels 值只有驱动读、无人写，档位恒缺省 2。驱动在
          // 被 DAW 创建时读取，故提示下次连接生效。
          const SizedBox(height: AuraSpace.xs),
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(l.asioDriverChannels,
                    style: labelOf(paletteOf(context), size: 12,
                        color: paletteOf(context).textDim))),
            Expanded(
              child: AuraDropdown<int>(
                value: model.asioDriverChannels,
                items: [
                  for (final n in const [2, 4, 6, 8])
                    DropdownMenuItem<int>(
                      value: n,
                      child: Text('$n ch',
                          style: TextStyle(
                              fontSize: 12,
                              color: n == model.asioDriverChannels
                                  ? paletteOf(context).accent
                                  : paletteOf(context).text)),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  final ok = model.setAsioDriverChannels(v);
                  model.postNotice(
                    ok
                        ? l.asioDriverChannelsSaved
                        : l.asioDriverChannelsFailed,
                    level: ok ? NoticeLevel.info : NoticeLevel.error,
                  );
                },
              ),
            ),
          ]),
          Text(l.asioDriverChannelsHint,
              style: captionOf(paletteOf(context),
                  color: paletteOf(context).textDim)),
        ],
      ),
    );
  }
}

