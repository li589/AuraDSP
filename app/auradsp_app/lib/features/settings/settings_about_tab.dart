part of '../settings_page.dart';

/*
 * settings_about_tab.dart — 关于页（2026-11-09 新增）
 * 包含：版本/形态、开源地址、开源协议、参考核心项目外链。
 * 外链统一经 ShellOpenPort.openUrl 交系统默认浏览器；失败走
 * 通用通知（NoticeHost）。捐赠区（二维码 + 捐赠链接）为预留位，
 * owner 决定开通时在本文件末尾追加一张 SectionCard 即可。
 */

/// 参考核心项目（已实际收编/构建于本软件者；溯源全文见仓库
/// source/ORIGIN.md 与 vendor/ORIGIN.md）。
const List<({String name, String url, String license})> _kRefProjects = [
  (
    name: 'JamesDSP (libjamesdsp)',
    url: 'https://github.com/james34602/JamesDSPManager',
    license: 'GPL-3.0',
  ),
  (
    name: 'JDSP4Linux',
    url: 'https://github.com/Audio4Linux/JDSP4Linux',
    license: 'GPL-3.0',
  ),
  (
    name: 'CLAP',
    url: 'https://github.com/free-audio/clap',
    license: 'MIT',
  ),
  (
    name: 'Steinberg VST3 SDK',
    url: 'https://github.com/steinbergmedia/vst3sdk',
    license: 'GPL-3.0',
  ),
  (
    name: 'vst2sdk (Xaymar)',
    url: 'https://github.com/Xaymar/vst2sdk',
    license: 'BSD-3-Clause',
  ),
];

Future<void> _openAboutLink(BuildContext context, AppModel model,
    AppLocalizations l, String url) async {
  final ok = await PlatformAdapters.instance.shell.openUrl(url);
  if (!ok) {
    model.postNotice(l.aboutOpenFailed, level: NoticeLevel.warning);
  }
}

List<Widget> buildAboutTab(BuildContext context, AppModel model) {
  final l = l10nOf(context);
  final p = paletteOf(context);

  Widget linkRow({
    required String title,
    required String url,
    String? trailing,
  }) {
    return InkWell(
      onTap: () => _openAboutLink(context, model, l, url),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: labelOf(p)),
                  const SizedBox(height: 2),
                  Text(url,
                      style: monoOf(p, size: 10, color: p.accent)),
                ],
              ),
            ),
            if (trailing != null) ...[
              Text(trailing,
                  style: monoOf(p, size: 10, color: p.textDim)),
              const SizedBox(width: AuraSpace.sm),
            ],
            Icon(Icons.open_in_new_rounded, size: 14, color: p.textDim),
          ],
        ),
      ),
    );
  }

  return [
    // 1. 应用信息
    SectionCard(
      title: 'AuraDSP',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _InfoRow(l.aboutVersion, 'v$kAppVersion'),
          _InfoRow(l.aboutForm, PlatformProfile.formLabel),
        ],
      ),
    ),

    // 2. 开源协议与地址
    SectionCard(
      title: l.aboutLicense,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          linkRow(
            title: kAppLicenseName,
            url: '$kAppRepoUrl/blob/main/LICENSE',
            trailing: 'GPL-3.0',
          ),
          const SizedBox(height: AuraSpace.sm),
          linkRow(title: l.aboutRepo, url: kAppRepoUrl),
        ],
      ),
    ),

    // 3. 参考核心项目
    SectionCard(
      title: l.aboutRefs,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < _kRefProjects.length; i++) ...[
            if (i > 0) const SizedBox(height: AuraSpace.sm),
            linkRow(
              title: _kRefProjects[i].name,
              url: _kRefProjects[i].url,
              trailing: _kRefProjects[i].license,
            ),
          ],
        ],
      ),
    ),

    // 4. 捐赠（预留）：二维码图片资产 + 捐赠链接确定后在此追加
    //    SectionCard（标题/文案走 arb，图片走 assets）。
  ];
}
