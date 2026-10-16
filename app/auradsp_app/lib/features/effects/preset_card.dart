// part of effects_page.dart —— P1 按卡拆分，纯搬运零改行。
// 共享 import 与 EffectsPage/ValueSlider 见父文件。
part of '../effects_page.dart';
/* ---- 预设快照卡片 ---- */

class _PresetCard extends StatefulWidget {
  final AppModel model;
  const _PresetCard({required this.model});

  @override
  State<_PresetCard> createState() => _PresetCardState();
}

class _PresetCardState extends State<_PresetCard> {
  final _saveNameCtrl = TextEditingController();
  List<AuraPreset> _presets = [];

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _saveNameCtrl.dispose();
    super.dispose();
  }

  void _reload() {
    setState(() {
      _presets = PresetLibrary.listAll();
    });
  }

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final l = l10nOf(context);
    final m = widget.model;

    final factoryPresets = _presets.where((p) => p.isFactory).toList();
    final userPresets = _presets.where((p) => !p.isFactory).toList();

    return SectionCard(
      title: l.presetTitle,
      hint: l.presetHint,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 出厂预设
          if (factoryPresets.isNotEmpty) ...[
            Row(
              children: [
                Icon(Icons.stars_rounded, size: 14, color: p.accent),
                const SizedBox(width: 4),
                Text(l.presetFactoryTitle,
                    style: monoOf(p, size: 11, color: p.accent)),
              ],
            ),
            const SizedBox(height: AuraSpace.xs),
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              children: [
                for (final item in factoryPresets)
                  AuraChip(
                    item.name,
                    icon: Icons.music_note_rounded,
                    selected: m.activePresetName == item.name,
                    onTap: () {
                      m.loadPreset(item);
                      _reload();
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(l.presetLoadedFactory(item.name)),
                          duration: const Duration(milliseconds: 1400),
                        ));
                      }
                    },
                  ),
              ],
            ),
            const SizedBox(height: AuraSpace.md),
          ],

          // 用户自建预设
          Row(
            children: [
              Icon(Icons.folder_shared_rounded, size: 14, color: p.accent2),
              const SizedBox(width: 4),
              Text(l.presetUserTitle,
                  style: monoOf(p, size: 11, color: p.accent2)),
            ],
          ),
          const SizedBox(height: AuraSpace.xs),
          if (userPresets.isEmpty)
            Text(l.presetUserEmpty,
                style: captionOf(p, color: p.textDim))
          else
            Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              children: [
                for (final item in userPresets)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AuraChip(
                        item.name,
                        icon: Icons.bookmark_border_rounded,
                        selected: m.activePresetName == item.name,
                        onTap: () {
                          m.loadPreset(item);
                          _reload();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(l.presetLoadedUser(item.name)),
                              duration: const Duration(milliseconds: 1400),
                            ));
                          }
                        },
                      ),
                      const SizedBox(width: 2),
                      InkWell(
                        onTap: () {
                          PresetLibrary.deletePreset(item);
                          _reload();
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                              content: Text(l.presetDeleted),
                              duration: const Duration(milliseconds: 1200),
                            ));
                          }
                        },
                        borderRadius: BorderRadius.circular(12),
                        child: Padding(
                          padding: const EdgeInsets.all(4),
                          child: Icon(Icons.close_rounded,
                              size: 13, color: p.textDim),
                        ),
                      ),
                      const SizedBox(width: AuraSpace.xs),
                    ],
                  ),
              ],
            ),

          // 偏离即未保存（2026-10-16 决策 #3）：当前状态与已应用预设
          // 有任何一点不同 → 显示「自定义（未保存）」徽标。
          if (m.presetDirty) ...[
            const SizedBox(height: AuraSpace.sm),
            Row(
              children: [
                Icon(Icons.edit_rounded, size: 13, color: p.accent2),
                const SizedBox(width: 4),
                Text(l.presetDirtyBadge,
                    style: monoOf(p, size: 11, color: p.accent2)),
              ],
            ),
          ],

          const SizedBox(height: AuraSpace.md),
          // 保存栏
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _saveNameCtrl,
                  decoration: InputDecoration(
                    hintText: l.presetSaveHint,
                    hintStyle: captionOf(p),
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: AuraSpace.md, vertical: AuraSpace.sm),
                    filled: true,
                    fillColor: p.panelRaised,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(AuraRadius.sm),
                      borderSide: BorderSide(color: p.hairline),
                    ),
                  ),
                ),
              ),
              const SizedBox(width: AuraSpace.sm),
              AuraChip(
                l.presetSave,
                icon: Icons.save_alt_rounded,
                selected: true,
                onTap: () {
                  final name = _saveNameCtrl.text.trim();
                  if (name.isEmpty) return;
                  final ok = m.saveAsUserPreset(name);
                  if (ok) _saveNameCtrl.clear();
                  _reload();
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                      content: Text(ok ? l.presetSaved : l.presetSaveFail),
                      duration: const Duration(milliseconds: 1400),
                    ));
                  }
                },
              ),
            ],
          ),
        ],
      ),
    );
  }
}
