// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 04 VDC 空间校正 ---- */

class _DdcCard extends StatelessWidget {
  final AppModel model;
  const _DdcCard({required this.model});

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    return SectionCard(
      index: kEffectCardIndex['ddc'],
      title: l.ddcTitle,
      collapsed: !model.ddcOn, // 同上：常规语义 + state 层 auto-bypass
      latencyMs: model.componentLatency('ddc').ms,
      latencyEnabled: model.isSectionEnabled('ddc'),
              latencyMeasured: model.componentLatency('ddc').measured,
              latencyEstimated: model.componentLatency('ddc').estimated,
              latencyProbing: model.isProbingLatency('ddc'),
      onRefreshLatency: AppModel.isLatencyProbeSupported('ddc')
          ? () => model.refreshComponentLatency('ddc')
          : null,
      latencyTick: model.getComponentLatencyTick('ddc'),
      trailing: ListenableBuilder(
        listenable: model,
        builder: (_, _) => AuraSwitch(
          value: model.ddcOn,
          onChanged: (v) => model.setDdcEnabled(v),
        ),
      ),
      child: ListenableBuilder(
        listenable: model,
        builder: (_, _) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _ResourceSlot(
              icon: Icons.filter_alt_outlined,
              title: l.ddcFilterTitle,
              detail: model.ddcReady ? l.ddcLoaded : null,
              actions: [
                AuraChip(l.ddcOpen, icon: Icons.folder_open_outlined,
                    onTap: () => _pickVdc(context)),
                // 已加载态由 _ResourceSlot 的 detail 行展示（l.ddcLoaded），
                // 此前这里还有个同文案死芯片（onTap: null），重复且误导，已删。
              ],
            ),
            const SizedBox(height: AuraSpace.sm),
            // D3：parseVdcMetadata 已算出文件名与采样率/长度，这里真正展示出来，
            // 否则用户只能看到一句「已加载」，无从判断加载的是哪个文件。
            if (model.ddcFileName != null) ...[
              Text('${l.ddcLoaded}：${model.ddcFileName}',
                  style: captionOf(p)),
              if (model.ddcDetails != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2.0),
                  child: Text(model.ddcDetails!, style: captionOf(p)),
                ),
            ] else
              Text(l.ddcNoFile, style: captionOf(p)),
          ],
        ),
      ),
    );
  }

  Future<void> _pickVdc(BuildContext context) async {
    const type = XTypeGroup(label: 'VDC', extensions: ['vdc']);
    final f = await openFile(
      acceptedTypeGroups: [type],
      initialDirectory: PathMemory.dirFor(PathMemory.slotDdcVdc) ??
          PathMemory.fallbackDir(PathMemory.slotDdcVdc),
    );
    if (f != null) {
      PathMemory.recordPick(PathMemory.slotDdcVdc, f.path);
      model.loadVdc(f.path);
    }
  }
}
