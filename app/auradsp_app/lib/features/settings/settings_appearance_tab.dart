part of '../settings_page.dart';

/*
 * settings_appearance_tab.dart — 外观设置页
 * 包含：主题配色选择、界面语言切换
 */

List<Widget> buildAppearanceTab(BuildContext context, AppModel model) {
  final l = l10nOf(context);

  return [
    // 1. 配色
    SectionCard(
      title: l.theme,
      child: Row(
        children: [
          Expanded(
            child: _ThemeCard(
              name: l.themeAuraDark,
              selected: model.themeId == AuraThemeId.auraDark,
              swatch: const [
                Color(0xFF0E0F13),
                Color(0xFF171A21),
                Color(0xFFD4FF3F),
              ],
              onTap: () => model.setTheme(AuraThemeId.auraDark),
            ),
          ),
          const SizedBox(width: AuraSpace.md),
          Expanded(
            child: _ThemeCard(
              name: l.themeAuraLight,
              selected: model.themeId == AuraThemeId.auraLight,
              swatch: const [
                Color(0xFFF4F1EA),
                Color(0xFFFFFFFF),
                Color(0xFFE63B2E),
              ],
              onTap: () => model.setTheme(AuraThemeId.auraLight),
            ),
          ),
          const SizedBox(width: AuraSpace.md),
          Expanded(
            child: _ThemeCard(
              name: l.themeAurora,
              selected: model.themeId == AuraThemeId.aurora,
              swatch: const [
                Color(0xFF070B14),
                Color(0xFF0D1522),
                Color(0xFF64F0DC),
              ],
              onTap: () => model.setTheme(AuraThemeId.aurora),
            ),
          ),
        ],
      ),
    ),

    // 2. 语言
    SectionCard(
      title: l.language,
      child: AuraSegmented<String>(
        segments: const [
          // l10n-ignore: 语言自称不翻译（各语言显示自己的名字）
          AuraSegment('zh', '简体中文'),
          AuraSegment('en', 'English'),
          // l10n-ignore: 语言自称不翻译
          AuraSegment('ja', '日本語'),
        ],
        selected: model.locale.languageCode,
        onChanged: (v) => model.setLocale(Locale(v)),
      ),
    ),
  ];
}
