/*
 * theme.dart — AuraDSP 三主题（真相源：design/tokens/aura.tokens.json）
 *
 * 设计原则（docs/APP-架构与设计方案.md §7）：
 *   - 扁平但有不平：层次靠明度阶梯 + 1px hairline，禁用阴影堆叠
 *   - 小圆角 6/10/14，禁止全胶囊
 *   - Display 中文用得意黑（AuraDisplayCJK），拉丁用 Bricolage Grotesque（AuraDisplay）
 *   - 正文/控件用系统黑体（雅黑/Noto），**绝不**用得意黑——斜切海报体只服务标题
 *   - 数值读数一律 AuraMono + tabular figures
 */
import 'package:flutter/material.dart';

class AuraPalette {
  final Color bg, panel, panelRaised, hairline, text, textDim;
  final Color accent, accentContrast, accent2;
  final Color success, warning, error;
  final Color vizSpectrum, vizGrid;

  const AuraPalette({
    required this.bg,
    required this.panel,
    required this.panelRaised,
    required this.hairline,
    required this.text,
    required this.textDim,
    required this.accent,
    required this.accentContrast,
    required this.accent2,
    required this.success,
    required this.warning,
    required this.error,
    required this.vizSpectrum,
    required this.vizGrid,
  });

  /// 深色底主题（用于判断氛围层强度）
  bool get isDark => bg.computeLuminance() < 0.2;
}

const auraDark = AuraPalette(
  bg: Color(0xFF0E0F13),
  panel: Color(0xFF171A21),
  panelRaised: Color(0xFF1E222B),
  hairline: Color(0xFF2A2F3A),
  text: Color(0xFFE8EAF0),
  textDim: Color(0xFF9AA3B2),
  accent: Color(0xFFD4FF3F),
  accentContrast: Color(0xFF10130A),
  accent2: Color(0xFFFF6B35),
  success: Color(0xFF5AD19B),
  warning: Color(0xFFE8B93E),
  error: Color(0xFFF05A5A),
  vizSpectrum: Color(0xFFD4FF3F),
  vizGrid: Color(0xFF232838),
);

const auraLight = AuraPalette(
  bg: Color(0xFFF4F1EA),
  panel: Color(0xFFFFFFFF),
  panelRaised: Color(0xFFFBFAF6),
  hairline: Color(0xFFE2DDCF),
  text: Color(0xFF1A1A1A),
  textDim: Color(0xFF6E6A60),
  accent: Color(0xFFE63B2E),
  accentContrast: Color(0xFFFFF7F6),
  accent2: Color(0xFF22335C),
  success: Color(0xFF1E7A4E),
  warning: Color(0xFF9A6D00),
  error: Color(0xFFC0271B),
  vizSpectrum: Color(0xFFE63B2E),
  vizGrid: Color(0xFFE7E2D6),
);

const aurora = AuraPalette(
  bg: Color(0xFF070B14),
  panel: Color(0xFF0D1522),
  panelRaised: Color(0xFF122036),
  hairline: Color(0xFF1B2A44),
  text: Color(0xFFDCE6F5),
  textDim: Color(0xFF7C8CA6),
  accent: Color(0xFF64F0DC),
  accentContrast: Color(0xFF04110E),
  accent2: Color(0xFFFF5EA8),
  success: Color(0xFF4FDE9E),
  warning: Color(0xFFF0C24B),
  error: Color(0xFFFF6B6B),
  vizSpectrum: Color(0xFF64F0DC),
  vizGrid: Color(0xFF142033),
);

enum AuraThemeId { auraDark, auraLight, aurora }

extension AuraThemeIdX on AuraThemeId {
  AuraPalette get palette {
    switch (this) {
      case AuraThemeId.auraDark:
        return auraDark;
      case AuraThemeId.auraLight:
        return auraLight;
      case AuraThemeId.aurora:
        return aurora;
    }
  }

  Brightness get brightness =>
      this == AuraThemeId.auraLight ? Brightness.light : Brightness.dark;
}

class AuraRadius {
  static const xs = 4.0, sm = 6.0, md = 10.0, lg = 14.0;
}

/* ---- 字体族分工 ---- */

/// 正文/控件的中文回退：系统黑体，可读性优先
const kBodyCjkFallback = <String>[
  'Microsoft YaHei UI',
  'Microsoft YaHei',
  'Noto Sans SC',
  'PingFang SC',
  'Segoe UI',
];

/// 标题/品牌的中文回退：得意黑（斜切海报体）
const kDisplayCjkFallback = <String>['AuraDisplayCJK', 'Microsoft YaHei UI'];

/// 等宽回退
const kMonoFallback = <String>['AuraMono', 'Consolas', 'Cascadia Mono'];

ThemeData buildAuraTheme(AuraThemeId id) {
  final p = id.palette;

  TextStyle display({double size = 26, double? height, double spacing = -0.2}) =>
      TextStyle(
        fontFamily: 'AuraDisplay',
        fontFamilyFallback: kDisplayCjkFallback,
        fontSize: size,
        height: height,
        fontWeight: FontWeight.w700,
        letterSpacing: spacing,
        color: p.text,
      );

  TextStyle text(double size, {FontWeight w = FontWeight.w400, Color? color, double? height}) =>
      TextStyle(
        fontSize: size,
        fontWeight: w,
        height: height,
        color: color ?? p.text,
      );

  return ThemeData(
    useMaterial3: true,
    brightness: id.brightness,
    scaffoldBackgroundColor: p.bg,
    canvasColor: p.bg,
    splashFactory: InkRipple.splashFactory,
    // 全局默认字体走「拉丁 Bricolage + 中文系统黑体」，保证正文可读
    fontFamily: 'AuraDisplay',
    fontFamilyFallback: kBodyCjkFallback,
    colorScheme: ColorScheme(
      brightness: id.brightness,
      primary: p.accent,
      onPrimary: p.accentContrast,
      secondary: p.accent2,
      onSecondary: p.accentContrast,
      surface: p.panel,
      onSurface: p.text,
      surfaceContainerHighest: p.panelRaised,
      error: p.error,
      onError: p.accentContrast,
    ),
    dividerColor: p.hairline,
    dividerTheme: DividerThemeData(color: p.hairline, thickness: 1, space: 1),
    textTheme: TextTheme(
      displayLarge: display(size: 40, height: 1.05, spacing: -0.6),
      displayMedium: display(size: 32, height: 1.08, spacing: -0.4),
      displaySmall: display(size: 26, height: 1.1),
      headlineMedium: display(size: 22, height: 1.15),
      titleLarge: text(17, w: FontWeight.w600),
      titleMedium: text(15, w: FontWeight.w600),
      titleSmall: text(13, w: FontWeight.w600),
      bodyLarge: text(14, height: 1.45),
      bodyMedium: text(13, height: 1.45),
      bodySmall: text(12, color: p.textDim, height: 1.5),
      labelLarge: text(13, w: FontWeight.w600, height: 1.2),
      labelMedium: text(12, w: FontWeight.w500, height: 1.2),
      labelSmall: TextStyle(
        fontFamily: 'AuraMono',
        fontFamilyFallback: kMonoFallback,
        fontSize: 11,
        letterSpacing: 1.6,
        fontWeight: FontWeight.w500,
        color: p.textDim,
      ),
    ),
    cardTheme: CardThemeData(
      color: p.panel,
      elevation: 0,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AuraRadius.md),
        side: BorderSide(color: p.hairline, width: 1),
      ),
      margin: EdgeInsets.zero,
    ),
    sliderTheme: SliderThemeData(
      trackHeight: 4,
      activeTrackColor: p.accent,
      inactiveTrackColor: p.hairline,
      secondaryActiveTrackColor: p.accent.withValues(alpha: 0.3),
      thumbColor: p.accent,
      overlayColor: p.accent.withValues(alpha: 0.12),
      thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
      overlayShape: const RoundSliderOverlayShape(overlayRadius: 16),
      trackShape: const RoundedRectSliderTrackShape(),
      showValueIndicator: ShowValueIndicator.never,
    ),
    switchTheme: SwitchThemeData(
      thumbColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? p.accentContrast : p.textDim),
      trackColor: WidgetStateProperty.resolveWith((s) =>
          s.contains(WidgetState.selected) ? p.accent : p.hairline),
      trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
    ),
    chipTheme: ChipThemeData(
      backgroundColor: Colors.transparent,
      selectedColor: p.accent,
      side: BorderSide(color: p.hairline),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(AuraRadius.sm)),
      labelStyle: text(12.5),
      secondaryLabelStyle: text(12.5, color: p.accentContrast,
          w: FontWeight.w600),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      showCheckmark: false,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: p.bg,
      indicatorColor: p.accent.withValues(alpha: 0.14),
      selectedIconTheme: IconThemeData(color: p.accent),
      unselectedIconTheme: IconThemeData(color: p.textDim),
      selectedLabelTextStyle: TextStyle(color: p.text, fontWeight: FontWeight.w600),
      unselectedLabelTextStyle: TextStyle(color: p.textDim),
    ),
    segmentedButtonTheme: SegmentedButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.sm))),
        side: WidgetStatePropertyAll(BorderSide(color: p.hairline)),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 14, vertical: 10)),
        backgroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? p.accent : Colors.transparent),
        foregroundColor: WidgetStateProperty.resolveWith((s) =>
            s.contains(WidgetState.selected) ? p.accentContrast : p.textDim),
      ),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: ButtonStyle(
        elevation: const WidgetStatePropertyAll(0),
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.md))),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 18, vertical: 14)),
        textStyle: const WidgetStatePropertyAll(
            TextStyle(fontSize: 13.5, fontWeight: FontWeight.w700, letterSpacing: 0.3)),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.sm))),
        padding: const WidgetStatePropertyAll(
            EdgeInsets.symmetric(horizontal: 12, vertical: 8)),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: ButtonStyle(
        shape: WidgetStatePropertyAll(RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AuraRadius.sm))),
        iconSize: const WidgetStatePropertyAll(18),
      ),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(8),
      radius: const Radius.circular(4),
      crossAxisMargin: 2,
      mainAxisMargin: 2,
      thumbColor: WidgetStateProperty.resolveWith((s) => s
              .contains(WidgetState.hovered)
          ? p.textDim.withValues(alpha: 0.55)
          : p.textDim.withValues(alpha: 0.26)),
      trackColor: const WidgetStatePropertyAll(Colors.transparent),
    ),
    snackBarTheme: SnackBarThemeData(
      backgroundColor: p.panelRaised,
      contentTextStyle: text(13, height: 1.5),
      behavior: SnackBarBehavior.floating,
      elevation: 0,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AuraRadius.md),
        side: BorderSide(color: p.hairline),
      ),
    ),
    tooltipTheme: TooltipThemeData(
      waitDuration: const Duration(milliseconds: 420),
      decoration: BoxDecoration(
        color: p.panelRaised,
        borderRadius: BorderRadius.circular(AuraRadius.sm),
        border: Border.all(color: p.hairline),
      ),
      textStyle: text(12),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    ),
  );
}

/* 等宽数值读数样式（tabular figures 对齐网格） */
TextStyle monoOf(AuraPalette p, {double size = 13, Color? color}) => TextStyle(
      fontFamily: 'AuraMono',
      fontFamilyFallback: kMonoFallback,
      fontSize: size,
      color: color ?? p.text,
      fontFeatures: const [FontFeature.tabularFigures()],
    );
