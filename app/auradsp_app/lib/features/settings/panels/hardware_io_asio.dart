part of '../../settings_page.dart';

// ASIO 模式重构 S2（2026-11-20，方案 docs/20-执行/ASIO模式重构
// 方案-2026-11-20.md §2.2/§2.3）：ASIO 范式下 I/O 配置卡的专属
// 面板——Client 与虚拟 ASIO 两形态合一卡呈现，不再拆输入层/
// 输出层（ASIO 是全双工单设备连接，输入/输出之分在此无意义）。
// 控件全部复用既有件：Client 形态 = _AsioClientOutputSubpanel
// （状态行 + 驱动/缓冲/声道对）+ 协商结果行；虚拟形态 =
// _VirtualAsioInputSubpanel + 驱动状态行 + 声道档位行
// （_AsioDriverChannelsRow，与驱动卡共用）。注册/注销/检测动作
// 仍归页面末尾的驱动卡（V-04 口径不变）。后端输出端点选择与
// DAW 遥测属 S3/S4，本面板不预置无后端控件。

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
class _AsioVirtualPanel extends StatelessWidget {
  final AppModel model;
  const _AsioVirtualPanel({required this.model});

  @override
  Widget build(BuildContext context) {
    final l = l10nOf(context);
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
        if (model.asioActive)
          _InfoRow(l.asioDawStatus, l.asioDawConnected),
        const SizedBox(height: AuraSpace.xs),
        _AsioDriverChannelsRow(model: model),
      ],
    );
  }
}
