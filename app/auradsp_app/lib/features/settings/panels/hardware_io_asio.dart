part of '../../settings_page.dart';

// ASIO 模式重构 S2（2026-11-20，方案 docs/20-执行/ASIO模式重构
// 方案-2026-11-20.md §2.2/§2.3）：ASIO 范式下 I/O 配置卡的专属
// 面板——Client 与虚拟 ASIO 两形态合一卡呈现，不再拆输入层/
// 输出层（ASIO 是全双工单设备连接，输入/输出之分在此无意义）。
// 控件全部复用既有件：Client 形态 = _AsioClientOutputSubpanel
// （状态行 + 驱动/缓冲/声道对）+ 协商结果行；虚拟形态 =
// _VirtualAsioInputSubpanel + 驱动状态行 + 声道档位行
// （_AsioDriverChannelsRow，与驱动卡共用）。注册/注销/检测动作
// 仍归页面末尾的驱动卡（V-04 口径不变）。S3 起虚拟形态含后端
// 输出端点选择（注册表接线已通）与最小遥测行；参数块与全量
// 遥测（频谱）属 S4。

class _AsioIoPanel extends StatelessWidget {
  final AppModel model;
  const _AsioIoPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final virtual = model.asioFlavor == AudioModes.asioVirtual;
    // 总闸 = 输入/输出两使能的合取（ASIO 链由合成链整体起停，
    // 单侧使能在本范式无独立语义）；拨动同时写两侧。
    final enabled = model.pipelineInputEnabled && model.pipelineOutputEnabled;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Icon(Icons.cable, size: 15, color: p.accent),
                const SizedBox(width: AuraSpace.xs),
                Text(l.paradigmAsio, style: sectionOf(p, color: p.text)),
                const SizedBox(width: AuraSpace.xs),
                InfoBadge(
                    message: virtual ? l.ioAsioGuide : l.tooltipOutputAsioClient),
              ],
            ),
            AuraSwitch(
              value: enabled,
              onChanged: (v) {
                model.setPipelineInputEnabled(v);
                model.setPipelineOutputEnabled(v);
              },
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
                    l.asioChainDisabledNotice,
                    style: captionOf(p, color: p.textDim),
                  ),
                ),
              ],
            ),
          )
        else if (virtual)
          _AsioVirtualPanel(model: model)
        else
          _AsioClientPanel(model: model),
      ],
    );
  }
}

/// ASIO Client 形态：宿主第三方（或自家）ASIO 驱动——驱动选择、
/// 缓冲档、输出声道对（_AsioClientDriverRow，随子面板内置）+
/// 设备状态行 + 活跃时的协商结果（采样率/缓冲/通道）。
class _AsioClientPanel extends StatelessWidget {
  final AppModel model;
  const _AsioClientPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AsioClientOutputSubpanel(model: model),
        HbBuilder(
          tick: model.hbTick,
          builder: (_) {
            if (!model.asioActive) return const SizedBox.shrink();
            final info = model.asioInfo;
            final sr = (info['sr'] as num?)?.toDouble() ?? 0;
            final nbs = (info['nbs'] as num?)?.toInt() ?? 0;
            final ioCh = (info['ioCh'] as num?)?.toInt() ?? 0;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (sr > 0)
                  _InfoRow(l.sampleRate,
                      '${sr.toInt()} Hz${ioCh > 0 ? ' / $ioCh ch' : ''}'),
                if (nbs > 0) _InfoRow(l.buffer, '$nbs frames'),
              ],
            );
          },
        ),
      ],
    );
  }
}

/// 虚拟 ASIO 形态：本机即 AuraDSP 虚拟 ASIO 驱动——输入流状态、
/// 驱动注册状态、DAW 连接状态（仅活跃时，与驱动卡同口径）与
/// 驱动声道档位（写注册表，DAW 下次创建驱动时读取）。
/// S3 起补：后端输出端点选择（写注册表 RenderEndpoint，驱动汇
/// 消费）与遥测行（DAW 已处理帧 / 汇实际生效端点与格式，数据经
/// 驱动遥测块由桥转入 asioInfo 的 daw* 字段；桥无此字段时 DAW
/// 状态回落 App 自身会话口径）。
class _AsioVirtualPanel extends StatelessWidget {
  final AppModel model;
  const _AsioVirtualPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
    final p = paletteOf(context);
    final endpoints = model.vaioPhysicalEndpoints;
    final curEndpoint = model.config.asioRenderEndpoint;
    final matched = endpoints.cast<AudioDeviceItem?>().firstWhere(
        (e) => e?.id == curEndpoint, orElse: () => null);
    final info = model.asioInfo;
    final hasDaw = info.containsKey('dawSeen');
    final dawSeen = hasDaw && info['dawSeen'] == 1;
    final dawLive = hasDaw ? (dawSeen && info['dawActive'] == 1) : model.asioActive;
    final sinkId = (info['dawSinkEndpoint'] as String?) ?? '';
    final sinkEp = endpoints.cast<AudioDeviceItem?>().firstWhere(
        (e) => e?.id == sinkId, orElse: () => null);
    final sinkRate = (info['dawSinkRate'] as num?)?.toInt() ?? 0;
    final sinkBits = (info['dawSinkBits'] as num?)?.toInt() ?? 0;
    final sinkName = sinkEp != null
        ? sinkEp.friendlyName
        : (sinkId.length > 18
            ? '…${sinkId.substring(sinkId.length - 18)}'
            : sinkId);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _VirtualAsioInputSubpanel(model: model),
        _InfoRow(
          l.asioDriverStatus,
          model.asioDriverInstalled
              ? l.asioDriverRegistered
              : l.asioDriverNotRegistered,
        ),
        if (dawLive) _InfoRow(l.asioDawStatus, l.asioDawConnected),
        if (hasDaw && dawLive)
          _InfoRow(l.ioProcessedFrames,
              '${formatFrameCount((info['dawFrames'] as num?)?.toInt() ?? 0)} frames'),
        const SizedBox(height: AuraSpace.xs),
        Row(
          children: [
            SizedBox(
              width: 104,
              child: Text(l.ioPhysicalOutput,
                  style: labelOf(p, size: 12, color: p.textDim)),
            ),
            Expanded(
              child: AuraDropdown<String>(
                value: curEndpoint,
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
                          child: Text(
                            l.asioRenderFollowDefault,
                            style: TextStyle(
                              fontSize: 12,
                              color: curEndpoint.isEmpty ? p.accent : p.text,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
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
                              l.setOfflineSuffix(curEndpoint.length > 18
                                  ? '…${curEndpoint.substring(curEndpoint.length - 18)}'
                                  : curEndpoint),
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
                            color: ep.id == curEndpoint ? p.accent : p.textDim,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              ep.friendlyName,
                              style: TextStyle(
                                fontSize: 12,
                                color: ep.id == curEndpoint ? p.accent : p.text,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
                hint: endpoints.isEmpty ? l.ioNoPhysicalOutputs : null,
                onChanged: (v) {
                  if (v != null) model.setAsioRenderEndpoint(v);
                },
              ),
            ),
          ],
        ),
        if (hasDaw && dawSeen && sinkId.isNotEmpty)
          _InfoRow(
            l.asioSinkActual,
            '$sinkName'
            '${sinkRate > 0 ? ' · $sinkRate Hz' : ''}'
            '${sinkBits > 0 ? ' / $sinkBits bit' : ''}'
            '${info['dawSinkConfigured'] == 1 ? '' : ' (${l.asioSinkDefaultTag})'}',
          ),
        const SizedBox(height: AuraSpace.xs),
        _AsioDriverChannelsRow(model: model),
      ],
    );
  }
}
