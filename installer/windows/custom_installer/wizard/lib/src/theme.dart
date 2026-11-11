import 'package:flutter/material.dart';

/// 极光主题令牌（取自主应用 lib/core/tokens.g.dart 的 aurora 实值，
/// 与主程序视觉同源；向导自维护一份，避免跨工程依赖）。
abstract final class Aurora {
  static const bg = Color(0xFF070B14);
  static const panel = Color(0xFF0D1522);
  static const panelRaised = Color(0xFF122036);
  static const hairline = Color(0xFF1B2A44);
  static const text = Color(0xFFDCE6F5);
  static const textDim = Color(0xFF7C8CA6);
  static const accent = Color(0xFF64F0DC);
  static const accentContrast = Color(0xFF04110E);
  static const accent2 = Color(0xFFFF5EA8);
  static const success = Color(0xFF4FDE9E);
  static const warning = Color(0xFFF0C24B);
  static const error = Color(0xFFFF6B6B);

  static ThemeData theme() {
    final base = ThemeData.dark(useMaterial3: true);
    return base.copyWith(
      scaffoldBackgroundColor: bg,
      colorScheme: const ColorScheme.dark(
        surface: panel,
        primary: accent,
        onPrimary: accentContrast,
        secondary: accent2,
        error: error,
      ),
      textTheme: base.textTheme.apply(bodyColor: text, displayColor: text),
      dividerColor: hairline,
      checkboxTheme: CheckboxThemeData(
        fillColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected) ? accent : Colors.transparent,
        ),
        checkColor: const WidgetStatePropertyAll(accentContrast),
        side: const BorderSide(color: textDim),
      ),
    );
  }
}
