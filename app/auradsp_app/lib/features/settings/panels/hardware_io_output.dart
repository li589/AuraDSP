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
          if (model.pipelineOutput == AudioModes.outputWasapi) ...[
            _WasapiOutputSubpanel(model: model),
            // 第八轮项 3（下拉半）：VAIO 桥链下 WASAPI 子面板的
            // 设备字段不被消费（已置灰明示），但桥的物理落点
            // （vaioOutputEndpoint）此前只有把输出类型切成 VAIO
            // 才够得着——用户实测呈「下拉锁定系统默认、无处可
            // 改」。桥链激活时在下方直接续上落点面板，呈现层
            // 补齐入口，不动任何链路语义。
            if (model.pipelineChain == PipelineChain.vaio) ...[
              const SizedBox(height: AuraSpace.md),
              HbBuilder(
                  tick: model.hbTick,
                  builder: (_) => _VaioOutputSubpanel(
                      model: model, asBridgeLanding: true)),
            ],
          ] else if (model.pipelineOutput == AudioModes.outputVaio)
            HbBuilder(tick: model.hbTick,
                builder: (_) => _VaioOutputSubpanel(model: model))
          // ASIO 范式有专属 I/O 面板（_AsioIoPanel）；管线输出
          // 自 S1 起不再有 ASIO 选项，此处无第三种可达状态。
          else
            const SizedBox.shrink(),
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
    // 桥落点形态（业主 2026-11-12 裁定）：VAIO 桥链 + WASAPI
    // 输出时下方紧接着落点面板（物理输出下拉/采样率/已处理帧/
    // 输出端点俱全），本块只保留标题行——原先的桥链说明行、置
    // 灰的设备下拉、采样率与缓冲区四行与落点面板重复，全删。
    if (model.pipelineChain == PipelineChain.vaio) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(l.ioModeLabel, l.outputWasapi),
        ],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.ioModeLabel, l.outputWasapi),
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

  /// 以「桥物理落点」形态呈现（第八轮项 3）：桥链激活时从
  /// WASAPI 输出层续接，此时隐藏虚拟声卡输出提示与监听镜像块
  /// （那是「渲染进 VAIO 供 OBS 采集」形态的说明），只留落点
  /// 下拉与桥状态行。
  final bool asBridgeLanding;
  const _VaioOutputSubpanel({required this.model, this.asBridgeLanding = false});

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
          if (!asBridgeLanding) ...[
          // 业主 2026-11-14 裁定：虚拟端点说明整框常显太占版面，
          // 收进监听镜像行尾的问号气泡（InfoBadge，与第十二轮 D
          // 的 APO 范式说明同形态）。2×2 口径（r65 S4）：本面板
          // 仅在输出轴 = VAIO 时出现，开关即镜像开关（裁定 2）、
          // 下方下拉即镜像目标（裁定 1）；说明文案按输入轴分格。
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l.monitorMirroring, style: labelOf(p, size: 12)),
                  const SizedBox(width: AuraSpace.xs),
                  InfoBadge(
                      message: model.pipelineInput == AudioModes.inputVaio
                          ? l.virtualSinkNoticeVaioIn
                          : l.virtualSinkNotice),
                ],
              ),
              AuraSwitch(
                value: model.monitorMirroring,
                onChanged: (v) => model.setMonitorMirroring(v),
              ),
            ],
          ),
          const SizedBox(height: AuraSpace.sm),
          ],
          Row(children: [
            SizedBox(
                width: 104,
                child: Text(
                    asBridgeLanding ? l.ioPhysicalOutput : l.ioMirrorTarget,
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
            // 端点被占用（0x8889000A）只给一句人话（第四十七轮
            // S4，user 裁定：Windows 口吻，不提进程/十六进制）；
            // 其余 note 仍为诊断原文。
            _InfoRow(
                'AuraVAIO',
                (info['note'] as String)
                        .toUpperCase()
                        .contains('0X8889000A')
                    ? l.vaioDeviceInUse
                    : '${info['note']}'),
          if (model.vaioActive) ...[
            if (info['sr'] is num)
              // 全面复审 S2（VAIO-6）：声道数读桥真值，不再硬编码 2 ch。
              _InfoRow(l.sampleRate,
                  '${(info['sr'] as num).toInt()} Hz / ${(info['channels'] as num?)?.toInt() ?? 2} ch'),
            if (info['frames'] is num)
              _ProcessedFramesRow(model: model),
            // 全面复审 S2（VAIO-8）：格式重同步计数与参数应用失败数
            // 上屏（此前只进日志，切歌噪声排障无从看起）。
            if ((info['fmtResyncs'] as num?)?.toInt() != null &&
                (info['fmtResyncs'] as num).toInt() > 0)
              _InfoRow('fmtResyncs', '${(info['fmtResyncs'] as num).toInt()}'),
            // 第八轮项 3：相位锚校正计数（开关随缘白噪声定罪的
            // 观测面：>0 即本次运行出现过 WriteOffset 与
            // TotalBytesWritten 的相位偏差且已被锚定校正）。
            if ((info['phaseResyncs'] as num?)?.toInt() != null &&
                (info['phaseResyncs'] as num).toInt() > 0)
              _InfoRow(
                  'phaseResyncs',
                  '${(info['phaseResyncs'] as num).toInt()}'
                  ' (skew ${(info['phaseSkew'] as num?)?.toInt() ?? 0} B)'),
            if ((info['paramsFailed'] as num?)?.toInt() != null &&
                (info['paramsFailed'] as num).toInt() > 0)
              _InfoRow('paramsFailed', '${(info['paramsFailed'] as num).toInt()}'),
            if (info['outputEndpoint'] is String &&
                (info['outputEndpoint'] as String).isNotEmpty)
              _InfoRow(l.ioOutputLabel, '${info['outputEndpoint']}'),
          ],
        ],
      ),
    );
  }
}

/// 已处理帧行（第四十四轮 S2，user 裁定）：独立 1 秒节流
/// 刷新——此前随 VAIO 面板在任意模型通知时重建（高频跳动），
/// 且原始整数无极值处理。数值格式走 formatFrameCount。
class _ProcessedFramesRow extends StatefulWidget {
  final AppModel model;
  const _ProcessedFramesRow({required this.model});

  @override
  State<_ProcessedFramesRow> createState() => _ProcessedFramesRowState();
}

class _ProcessedFramesRowState extends State<_ProcessedFramesRow> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final frames = (widget.model.vaioInfo['frames'] as num?)?.toInt() ?? 0;
    return _InfoRow(l.ioProcessedFrames, '${formatFrameCount(frames)} frames');
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
            l.ioChannelPair(model.config.asioOutPair + 1,
                model.config.asioOutPair + 2)),
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
