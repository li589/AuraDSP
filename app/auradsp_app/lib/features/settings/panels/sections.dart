part of '../../settings_page.dart';
// part of '../settings_page.dart' —— P1-1（2026-10-23）机械拆分，零逻辑改动。


/* ---- 底部分类选卡（固定悬浮；点选切换设置分组） ---- */

class _CatBar extends StatelessWidget {
  final int selected;
  final List<String> labels;
  final ValueChanged<int> onChanged;
  const _CatBar({
    required this.selected,
    required this.labels,
    required this.onChanged,
  });

  static const _icons = [
    Icons.color_lens_outlined,
    Icons.graphic_eq_rounded,
    Icons.memory_outlined,
    Icons.science_outlined,
    Icons.info_outline,
  ];

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    return Container(
      decoration: BoxDecoration(
        color: p.panel,
        border: Border(top: BorderSide(color: p.hairline)),
      ),
      padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).padding.bottom + AuraSpace.xs,
          top: AuraSpace.xs),
      child: Row(
        children: [
          for (var i = 0; i < labels.length; i++)
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onChanged(i),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(vertical: AuraSpace.xs + 2),
                  decoration: BoxDecoration(
                    border: Border(
                      top: BorderSide(
                        color: i == selected ? p.accent : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_icons[i],
                          size: 19,
                          color: i == selected ? p.accent : p.textDim),
                      const SizedBox(height: 2),
                      Text(
                        labels[i],
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: i == selected
                              ? FontWeight.w600
                              : FontWeight.w400,
                          color: i == selected ? p.text : p.textDim,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}



/* ---- 04 动态设备与精细化调节面板（ADR-009） ---- */

class _DynamicAudioPanel extends StatelessWidget {
  final AppModel model;
  const _DynamicAudioPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    // Linux（ADR-012 D-5/D-6）：设备面只有 PulseAudio sink/source，不存在
    // Windows 的 APO / VAIO / ASIO 三层管线；必须在此提前返回，否则
    // categoryForMode('system') 会落到管线分支、把 Windows 专有设备
    // （WASAPI 端点/VAIO/ASIO）误显示到 Linux 设置页。
    if (PlatformProfile.isLinux) {
      return _LinuxDevicePanel(model: model);
    }

    // V-04/R6：驱动信息层恒显示，可见性不再被处理范式裁剪；
    // 范式只决定其下是附加面板还是管线输入/输出层。
    final p = paletteOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _DriverLayer(model: model),
        const SizedBox(height: AuraSpace.md),
        Container(height: 1, color: p.hairline),
        const SizedBox(height: AuraSpace.md),
        if (model.modeCategory == AudioModes.categoryAttachment)
          if (model.attachmentMode == AudioModes.attachVoicemeeterApi)
            HbBuilder(
                tick: model.hbTick,
                builder: (_) => _VoicemeeterPanel(model: model))
          else
            _SystemApoPanel(model: model)
        else ...[
          _InputLayer(model: model),
          const SizedBox(height: AuraSpace.md),
          Container(height: 1, color: p.hairline),
          const SizedBox(height: AuraSpace.md),
          _OutputLayer(model: model),
        ],
      ],
    );
  }
}

/* ---- Linux 设备卡（ADR-012 D-5）：PulseAudio 输出/采集状态 ---- */

class _LinuxDevicePanel extends StatelessWidget {
  final AppModel model;
  const _LinuxDevicePanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final info = model.info;
    final sink = model.linuxDefaultSink;
    final captureOn = model.linuxCaptureActive;
    final capSource = model.linuxCaptureSource;
    final alsa = model.config.linuxAudioBackend == 'alsa';
    final alsaDevice = model.config.alsaOutputDevice;
    final capDevice = model.config.alsaCaptureDevice;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 版式与 Windows 驱动层统一（2026-11-10 用户裁定）：层标题 +
        // _DriverBlock 块组（文字左、按钮同行右）+ 操作系统行收尾。
        Row(
          children: [
            Icon(Icons.developer_board_rounded, size: 15, color: p.accent),
            const SizedBox(width: AuraSpace.xs),
            Text(l.driverLayerTitle, style: sectionOf(p, color: p.text)),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        _DriverBlock(
          title: alsa ? 'ALSA (Linux)' : 'PulseAudio (Linux)',
          lines: [
            if (info != null) _DriverDetail('ABI v${info.abi} · ${info.version}'),
            if (info != null)
              _DriverDetail('${info.deviceRate} Hz · ${info.deviceCh} ch · '
                  '${info.bufferFrames} frames'),
          ],
          actions: [
            AuraChip(
              l.setRefreshStatus,
              icon: Icons.refresh_rounded,
              onTap: () => model.refreshLinuxStatus(),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        Row(children: [
          SizedBox(
              width: 104,
              child: Text(l.linuxBackendLabel,
                  style: labelOf(p, size: 12, color: p.textDim))),
          Expanded(
            child: AuraDropdown<String>(
              value: alsa ? 'alsa' : 'pulse',
              items: [
                DropdownMenuItem<String>(
                  value: 'pulse',
                  child: Text(l.linuxBackendPulse,
                      style: const TextStyle(fontSize: 12)),
                ),
                DropdownMenuItem<String>(
                  value: 'alsa',
                  child: Text(l.linuxBackendAlsa,
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
              hint: '—',
              onChanged: (v) {
                if (v != null) model.setLinuxAudioBackend(v);
              },
            ),
          ),
        ]),
        const SizedBox(height: AuraSpace.xs),
        if (!alsa)
          _InfoRow(l.linuxOutputSink,
              sink.isEmpty ? l.linuxOutputSinkDefault : sink)
        else
          Row(children: [
            Expanded(
              child: _InfoRow(l.linuxAlsaOutDevice,
                  alsaDevice.isEmpty ? l.linuxAlsaDeviceUnset : alsaDevice),
            ),
            AuraChip(
              l.linuxAlsaDeviceEdit,
              icon: Icons.edit_rounded,
              onTap: () => _editAlsaDevice(context),
            ),
          ]),
        if (alsa)
          Row(children: [
            Expanded(
              child: _InfoRow(l.linuxAlsaCapDevice,
                  capDevice.isEmpty ? l.linuxAlsaDeviceUnset : capDevice),
            ),
            AuraChip(
              l.linuxAlsaDeviceEdit,
              icon: Icons.edit_rounded,
              onTap: () => _editAlsaCaptureDevice(context),
            ),
          ]),
        _InfoRow(
            l.linuxCaptureSource,
            captureOn
                ? (capSource.isEmpty ? '—' : capSource)
                : l.linuxCaptureNone),
        const SizedBox(height: AuraSpace.xs),
        _DriverBlock(
          title: l.linuxVirtualDevice,
          lines: [
            _DriverStatus(
              model.linuxVirtualSink
                  ? l.linuxVirtualPresent
                  : l.linuxVirtualAbsent,
              model.linuxVirtualSink ? p.success : p.textDim,
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.sm),
        _DriverBlock(
          title: l.linuxModeDriver,
          lines: [
            _DriverStatus(
              model.linuxDriverLoaded
                  ? l.linuxDriverPresent
                  : l.linuxDriverAbsent,
              model.linuxDriverLoaded ? p.success : p.textDim,
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        Text(alsa ? l.linuxAlsaExpertHint : l.linuxDeviceHint,
            style: captionOf(p, color: p.textDim).copyWith(fontSize: 11)),
        const SizedBox(height: AuraSpace.xs),
        _InfoRow(l.osVersionLabel, PlatformProfile.osVersion),
      ],
    );
  }

  Future<void> _editAlsaDevice(BuildContext context) => _editAlsaDeviceDialog(
        context,
        title: l10nOf(context).linuxAlsaOutDevice,
        initial: model.config.alsaOutputDevice,
        capture: false,
        hintText: 'hw:0,0 / plughw:1,0 / default',
        onSave: model.setAlsaOutputDevice,
      );

  Future<void> _editAlsaCaptureDevice(BuildContext context) =>
      _editAlsaDeviceDialog(
        context,
        title: l10nOf(context).linuxAlsaCapDevice,
        initial: model.config.alsaCaptureDevice,
        capture: true,
        hintText: 'hw:Loopback / plughw:2,0 / default',
        onSave: model.setAlsaCaptureDevice,
      );

  /// ALSA 设备编辑对话框（输出/采集共用）：枚举下拉（按方向过滤）
  /// + 手填。controller 在对话框退出动画结束后经 post-frame 释放，
  /// 避免 await 返回与路由动画重叠期 use-after-dispose（打磨三期）。
  Future<void> _editAlsaDeviceDialog(
    BuildContext context, {
    required String title,
    required String initial,
    required bool capture,
    required String hintText,
    required ValueChanged<String> onSave,
  }) async {
    final l = l10nOf(context);
    final controller = TextEditingController(text: initial);
    final enumerated = model.listAlsaDevices(capture: capture);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title, style: const TextStyle(fontSize: 14)),
        content: StatefulBuilder(
          builder: (ctx, setLocal) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (enumerated.isNotEmpty)
                DropdownButton<String>(
                  isExpanded: true,
                  value: enumerated.contains(controller.text)
                      ? controller.text
                      : null,
                  hint: Text(l.linuxAlsaDeviceUnset,
                      style: const TextStyle(fontSize: 12)),
                  items: [
                    for (final n in enumerated)
                      DropdownMenuItem<String>(
                        value: n,
                        child: Text(n, style: const TextStyle(fontSize: 12)),
                      ),
                  ],
                  onChanged: (v) {
                    if (v != null) {
                      controller.text = v;
                      setLocal(() {});
                    }
                  },
                ),
              TextField(
                controller: controller,
                autofocus: true,
                decoration: InputDecoration(hintText: hintText),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(l.dlgCancel),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: Text(l.dlgSave),
          ),
        ],
      ),
    );
    WidgetsBinding.instance
        .addPostFrameCallback((_) => controller.dispose());
    if (result != null) onSave(result);
  }
}

/// VB 桥 note 语义化（V-03/R2）：桥写入的 slug 形内部 token
/// （如 no-voicemeeter-remote-dll）与 bridge-missing 前缀是诊断信息，
/// 永不直接当用户文案外显，统一映射为「Voicemeeter 未启用」；
/// 其余自由文本（如桥的人类可读状态）原样透传。
String _vbNoteText(AppLocalizations l, Object? note) {
  if (note is! String || note.isEmpty) return l.setConnIdle;
  if (note.startsWith('bridge-missing') ||
      RegExp(r'^[a-z0-9]+(-[a-z0-9]+)+$').hasMatch(note)) {
    return l.setVbNotEnabled;
  }
  return note;
}

class _VoicemeeterPanel extends StatelessWidget {
  final AppModel model;
  const _VoicemeeterPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final sr = model.vbInfo['sr'];
    final note = model.vbInfo['note'];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.audioParadigm, '${l.paradigmAttachment} · ${l.modeVoicemeeterApi}'),
        _InfoRow(l.setConnStatus, model.vbActive ? l.setConnActive : _vbNoteText(l, note)),
        if (sr is num) _InfoRow(l.sampleRate, '${sr.toInt()} Hz'),
        if (model.vbActive)
          HbBuilder(tick: model.hbTick, builder: (_) => _VbBuses(model: model)),
      ],
    );
  }
}

/// 格式化离线/已断开设备的展示名称，避免给用户展示裸 GUID 或 Map.toString() 乱码
String _formatOfflineDeviceName(AppLocalizations l, String idOrName,
    [List<AudioDeviceItem>? known]) {
  var s = idOrName.trim();
  if (s.isEmpty) return l.setDeviceDisconnected;
  // 防御 Map.toString() 残留（如 `{name: 扬声器, id: ...}`）
  if (s.startsWith('{') && s.contains('name:')) {
    final m = RegExp(r'name:\s*(.*?)(?:,\s*id:|\s*})').firstMatch(s);
    if (m != null) s = m.group(1)!.trim();
  }
  // 若在已知设备列表中有匹配项，直接采用其 friendlyName
  if (known != null) {
    for (final d in known) {
      if (d.id == s || d.name == s) {
        return d.friendlyName;
      }
    }
  }
  // 若是裸 GUID，截取简短端点代号
  if (s.startsWith('{0.0.') && s.length > 30) {
    final shortId = s.length >= 8 ? s.substring(s.length - 8, s.length - 1) : l.setEndpointShort;
    return l.setEndpointWithId(shortId);
  }
  return s;
}

/// 根据设备名称和类型推荐图标
IconData _getAudioDeviceIcon(String name, {required bool isRender}) {
  final lower = name.toLowerCase();
  if (!isRender) return Icons.mic_none_outlined;
  if (lower.contains('headphone') ||
      lower.contains('headset') ||
      lower.contains('耳机') || // l10n-ignore: 设备名匹配关键词
      lower.contains('耳麦')) { // l10n-ignore: 设备名匹配关键词
    return Icons.headphones_outlined;
  }
  if (lower.contains('speaker') ||
      lower.contains('扬声器') || // l10n-ignore: 设备名匹配关键词
      lower.contains('喇叭')) { // l10n-ignore: 设备名匹配关键词
    return Icons.speaker_outlined;
  }
  return Icons.volume_up_outlined;
}

class _SystemApoPanel extends StatelessWidget {
  final AppModel model;
  const _SystemApoPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final endpoints = model.vaioPhysicalEndpoints;
    final selEndpoint = model.apoTargetEndpoint;
    final matched = endpoints.cast<AudioDeviceItem?>().firstWhere(
        (e) => e?.name == selEndpoint || e?.id == selEndpoint,
        orElse: () => null);
    // 目标值用端点 ID（全局唯一）：用名称子串匹配时，同一
    // 物理设备的扬声器/麦克风端点、VAIO 与物理的同名扬声器
    // 都会造成「匹配到多个端点」（真机报告 2026-11-10）；
    // ID 匹配永不歧义。旧配置存的名称仍兼容（工具按子串
    // 匹配 id/name 两路，状态侧 apoAttached 亦然）。
    final selectedValue = matched != null
        ? matched.id
        : (selEndpoint.isEmpty ? '' : selEndpoint);

    // APO 引擎状态行口径（第五轮 S3）：故障 > 加载失败（telemetry
    // v4 诊断）> 处理中 > 等待。加载失败附 stage/err 原始码便于
    // 排障（文案本体走 l10n）；心跳活跃不再等同于处理中（心跳
    // 芯片已改述其真实含义，见下方 setApoHeartbeat）。
    final apoLoadFailed = model.apoLoadStage >= 1 && model.apoLoadStage <= 4;
    final apoNoteText = model.apoEngineFault
        ? l.apoEngineNoteFault
        : apoLoadFailed
            ? '${l.apoEngineNoteLoadFailed} '
                '[stage=${model.apoLoadStage} err=${model.apoLoadErr}]'
            : model.apoEngineActive
                ? l.apoEngineNoteActive
                : l.apoEngineNoteWaiting;
    final apoNoteColor = model.apoEngineFault || apoLoadFailed
        ? p.warning
        : model.apoEngineActive
            ? p.accent
            : p.textDim;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // 第十二轮 D（文案修剪）：V-03 的模式语义说明整段常显太占
        // 版面，缩为范式行尾的「?」气泡（文本仍是 apoModeHint 本体）。
        Row(
          children: [
            Expanded(
              child: _InfoRow(
                  l.audioParadigm, '${l.paradigmAttachment} · System APO'),
            ),
            Tooltip(
              message: l.apoModeHint,
              child: Icon(Icons.help_outline_rounded,
                  size: 14, color: p.textDim),
            ),
          ],
        ),
        // APO 引擎状态行（立项 P3，撤下第四轮的透传止损标注）：
        // sysapo 模式且已附加时按 telemetry 回传呈现真实状态——
        // 故障已退回直通（warning）/ 等待就绪（dim）。状态来自
        // audiodg 内座位实例的回传块，非推测。全面复审 S2
        // （APO-7）的实测明细（rate/channels/params）第十二轮 D
        // 起收进本行的悬停气泡，不再单独占一行。
        // 「处理中」绿字行已按业主 2026-11-12 裁定移除：正常处
        // 理是常态、不需要一行常驻文案；故障/加载失败/等待仍显。
        if (model.audioMode == 'sysapo' &&
            model.apoAnyAttached &&
            !(model.apoEngineActive &&
                !model.apoEngineFault &&
                !apoLoadFailed))
          Padding(
            padding: const EdgeInsets.only(top: 2, bottom: 2),
            child: model.apoEngineRate > 0
                ? Tooltip(
                    message: l.apoEngineDetail('${model.apoEngineRate}',
                        '${model.apoEngineChannels}',
                        '${model.apoParamsApplied}'),
                    child: Text(apoNoteText,
                        style: captionOf(p, color: apoNoteColor)
                            .copyWith(fontSize: 11)),
                  )
                : Text(apoNoteText,
                    style: captionOf(p, color: apoNoteColor)
                        .copyWith(fontSize: 11)),
          ),
        const SizedBox(height: AuraSpace.xs),
        Row(
          children: [
            SizedBox(
              width: 104,
              child: Text(l.apoTargetEndpoint,
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
                            color: selEndpoint.isEmpty ? p.accent : p.textDim),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            l.setDefaultEndpoint,
                            style: TextStyle(
                              fontSize: 12,
                              color: selEndpoint.isEmpty ? p.accent : p.text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (selEndpoint.isNotEmpty && matched == null)
                    DropdownMenuItem<String>(
                      value: selEndpoint,
                      child: Row(
                        children: [
                          Icon(Icons.link_off_rounded,
                              size: 14, color: p.warning),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              l.setOfflineSuffix(
                                  _formatOfflineDeviceName(l, selEndpoint, endpoints)),
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
                  for (final ep in endpoints)
                    DropdownMenuItem<String>(
                      value: ep.id,
                      child: Row(
                        children: [
                          Icon(
                            _getAudioDeviceIcon(ep.name, isRender: true),
                            size: 14,
                            color: (ep.name == selEndpoint || ep.id == selEndpoint)
                                ? p.accent
                                : p.textDim,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ep.friendlyName,
                              style: TextStyle(
                                fontSize: 12,
                                color: (ep.name == selEndpoint || ep.id == selEndpoint)
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
                hint: endpoints.isEmpty ? l.setNoEndpoint : null,
                onChanged: (v) {
                  if (v != null) model.setApoTargetEndpoint(v);
                },
              ),
            ),
            const SizedBox(width: AuraSpace.xs),
            AuraChip(l.asioRefresh,
                icon: Icons.refresh_rounded,
                // V-03：旧实现只发 vaiodetect，对 APO 状态毫无作用，
                // 用户感知为「点刷新没反应」。端点列表（经 detect 回
                // vaioPhysicalEndpoints）与 APO 挂载状态一并刷新。
                onTap: () {
                  model.refreshVaioDetect();
                  model.checkApoStatus();
                }),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        Row(
          children: [
            SizedBox(
              width: 104,
              child: Text(l.apoStatus, style: labelOf(p, size: 12, color: p.textDim)),
            ),
            Expanded(
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                runSpacing: 4,
                children: [
                  Text(
                    // 状态行报真值（第六轮项 3）：目标已附加 /
                    // 已附加在他端点（具名，不被当前选择藏起）/
                    // 未附加。
                    model.apoAttached
                        ? l.apoAttached
                        : (model.apoAnyAttached
                            ? l.apoAttachedOn(model.apoAttachedName)
                            : l.apoNotAttached),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: model.apoAnyAttached ? p.accent : p.textDim,
                    ),
                  ),
                  if (model.apoHeartbeatAlive)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.green.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.green.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.graphic_eq_rounded, size: 12, color: Colors.green),
                          const SizedBox(width: 4),
                          Text(
                            l.setApoHeartbeat(model.apoHeartbeatSr,
                                model.apoHeartbeatFrames),
                            style: const TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    )
                  else if (model.apoAnyAttached)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: Colors.orange.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: Colors.orange.withValues(alpha: 0.5)),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.hourglass_top_rounded, size: 12, color: Colors.orange),
                          const SizedBox(width: 4),
                          Text(
                            l.setApoAttached,
                            style: const TextStyle(fontSize: 10, color: Colors.orange),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
        if (model.lastApoError != null) ...[
          const SizedBox(height: AuraSpace.sm),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: p.error.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: p.error.withValues(alpha: 0.4)),
            ),
            child: Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: p.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    model.lastApoError!,
                    style: TextStyle(fontSize: 12, color: p.error),
                  ),
                ),
                GestureDetector(
                  onTap: () => model.clearApoError(),
                  child: Icon(Icons.close, size: 14, color: p.error),
                ),
              ],
            ),
          ),
        ],
        const SizedBox(height: AuraSpace.sm),
        Wrap(
          spacing: AuraSpace.sm,
          runSpacing: AuraSpace.xs,
          children: [
            AuraChip(
              model.isApoOperating ? l.setProcessing : l.apoActionAttach,
              icon: Icons.link,
              selected: model.apoAttached,
              // 当前选择已附加时置灰（Stage 0 / §8.2）：重复附加
              // 只会重走备份/写槽并刷新时间戳，让人误以为卸载
              // 「没反应」后又被重挂；与复合钮置灰同口径。切换
              // 到未附加端点时 apoAttached 转假、自动恢复可点。
              onTap: (model.isApoOperating || model.apoAttached)
                  ? null
                  : () async {
                      final ok = await model.attachSystemApo();
                      model.postNotice(
                        ok
                            ? l.setApoRegistered
                            : (model.lastApoError ?? l.setApoAttachFailed),
                        level: ok ? NoticeLevel.info : NoticeLevel.error,
                      );
                    },
            ),
            AuraChip(
              model.isApoOperating ? l.setProcessing : l.apoActionDetach,
              icon: Icons.link_off,
              danger: true,
              onTap: model.isApoOperating
                  ? null
                  : () async {
                      final ok = await model.detachSystemApo();
                      model.postNotice(
                        ok
                            ? l.setApoUnregistered
                            : (model.lastApoError ?? l.setApoUnregisterFailed),
                        level: ok ? NoticeLevel.info : NoticeLevel.error,
                      );
                    },
            ),
            // 第十二轮 C：复合与否只在附加那一刻被工具消费，附加
            // 中/已附加后点选是假交互——禁用（与附加/卸载同口径），
            // 理由收进气泡。
            Tooltip(
              message: l.apoCompositeTip,
              child: AuraChip(
                l.setCompositeSlot,
                icon: model.apoCompositeMode
                    ? Icons.layers_rounded
                    : Icons.layers_outlined,
                selected: model.apoCompositeMode,
                onTap: (model.isApoOperating || model.apoAttached)
                    ? null
                    : () =>
                        model.setApoCompositeMode(!model.apoCompositeMode),
              ),
            ),
            AuraChip(
              l.setRefreshStatus,
              icon: Icons.refresh_rounded,
              onTap: () => model.checkApoStatus(),
            ),
            // 第十二轮 D：注册表安全说明整段常显改为盾形气泡，
            // 文本仍是 setApoSafetyNote 本体，版面只留一个图标。
            Tooltip(
              message: l.setApoSafetyNote,
              child: Padding(
                padding: const EdgeInsets.only(top: 7),
                child: Icon(Icons.shield_outlined,
                    size: 15, color: p.textDim),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

