// part of plugins_page.dart —— P1 按区拆分，纯搬运零改行。
part of '../plugins_page.dart';
class _CustomDirsSection extends StatelessWidget {
  final AppModel model;
  final VoidCallback onAddDir;
  final VoidCallback onRescan;

  const _CustomDirsSection({
    required this.model,
    required this.onAddDir,
    required this.onRescan,
  });

  @override
  Widget build(BuildContext context) {
    final p = paletteOf(context);
    final customDirs = model.config.customPluginDirs;

    return SectionCard(
      title: l10nOf(context).plugCustomTitle,
      hint: l10nOf(context).plugCustomHint,
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          OutlinedButton.icon(
            onPressed: onAddDir,
            icon: const Icon(Icons.create_new_folder_rounded, size: 15),
            label: Text(l10nOf(context).plugCustomAdd),
            style: OutlinedButton.styleFrom(
              foregroundColor: p.accent,
              side: BorderSide(color: p.accent.withValues(alpha: 0.4)),
              visualDensity: VisualDensity.compact,
            ),
          ),
        ],
      ),
      child: customDirs.isEmpty
          ? Container(
              padding: const EdgeInsets.symmetric(vertical: AuraSpace.sm),
              alignment: Alignment.centerLeft,
              child: Text(
                l10nOf(context).plugCustomEmpty,
                style: captionOf(p),
              ),
            )
          : Wrap(
              spacing: AuraSpace.sm,
              runSpacing: AuraSpace.sm,
              children: customDirs.map((dir) {
                return Chip(
                  avatar: const Icon(Icons.folder_rounded, size: 16),
                  label: Text(dir, style: monoOf(p, size: 11)),
                  backgroundColor: p.panelRaised,
                  side: BorderSide(color: p.hairline),
                  deleteIcon: const Icon(Icons.close_rounded, size: 14),
                  onDeleted: () {
                    model.removeCustomPluginDir(dir);
                    onRescan();
                  },
                );
              }).toList(),
            ),
    );
  }
}

/// D4d logo 三合一：AuraDSP 品牌渐变底 + 厂商首字母 monogram + 格式角标。
///
/// 为什么不做"提取真实图标"：VST3 无标准 logo 接口（只能在 bundle 的
/// Contents/Resources/ 找快照图，且 IPlugView::getSnapshot 需先建实例+建
/// 视图，代价高不稳定）；CLAP 根本没有 logo 概念。三合一是确定性、离线、
/// 对全部插件一致的默认方案（方案 §4.6-1）。
///
/// 空 vendor 时 monogram 降级取插件名首字母（方案 §4.6-2），不再显示
/// "未知厂商"——文本行同步只保留分类。
