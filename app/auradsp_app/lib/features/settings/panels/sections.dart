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
    // 1. 附加模式
    if (model.modeCategory == AudioModes.categoryAttachment) {
      if (model.attachmentMode == AudioModes.attachVoicemeeterApi) {
        return HbBuilder(
            tick: model.hbTick, builder: (_) => _VoicemeeterPanel(model: model));
      } else {
        return _SystemApoPanel(model: model);
      }
    }

    // 2. 管线模式：三层设备显示卡（驱动层、输入层、输出层）
    return _PipelineThreeLayerCard(model: model);
  }
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
        _InfoRow(l.setConnStatus, model.vbActive ? l.setConnActive : (note is String && note.isNotEmpty ? note : l.setConnIdle)),
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
    final selectedValue = matched != null
        ? matched.name
        : (selEndpoint.isEmpty ? '' : selEndpoint);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _InfoRow(l.audioParadigm, '${l.paradigmAttachment} · System APO'),
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
                      value: ep.name,
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
                onTap: () => model.refreshVaioDetect()),
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
                    model.apoAttached ? l.apoAttached : l.apoNotAttached,
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: model.apoAttached ? p.accent : p.textDim,
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
                            l.setApoActive(model.apoHeartbeatSr,
                                model.apoHeartbeatFrames),
                            style: const TextStyle(fontSize: 10, color: Colors.green, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    )
                  else if (model.apoAttached)
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
              onTap: model.isApoOperating
                  ? null
                  : () async {
                      final ok = await model.attachSystemApo();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? l.setApoRegistered
                              : (model.lastApoError ?? l.setApoAttachFailed)),
                          duration: const Duration(milliseconds: 2000),
                        ));
                      }
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
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(ok
                              ? l.setApoUnregistered
                              : (model.lastApoError ?? l.setApoUnregisterFailed)),
                          duration: const Duration(milliseconds: 2000),
                        ));
                      }
                    },
            ),
            AuraChip(
              l.setCompositeSlot,
              icon: model.apoCompositeMode ? Icons.layers_rounded : Icons.layers_outlined,
              selected: model.apoCompositeMode,
              onTap: () => model.setApoCompositeMode(!model.apoCompositeMode),
            ),
            AuraChip(
              l.setRefreshStatus,
              icon: Icons.refresh_rounded,
              onTap: () => model.checkApoStatus(),
            ),
          ],
        ),
        const SizedBox(height: AuraSpace.xs),
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.shield_outlined, size: 13, color: p.accent),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                l.setApoSafetyNote,
                style: TextStyle(fontSize: 11, color: p.textDim, height: 1.3),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

