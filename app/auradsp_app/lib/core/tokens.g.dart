// GENERATED FILE — DO NOT EDIT BY HAND.
// 源: design/tokens/aura.tokens.json
// 生成: python tools/gen_theme.py（改 JSON 后必须重跑）
// 漂移防线: test/tokens_parity_test.dart（JSON vs 运行时常量逐项比对）

import 'package:flutter/material.dart';

/// 配色（3 套主题 × 14 色）。
class TokColor {
  const TokColor._();
  static const auraDarkBg = Color(0xFF0E0F13);
  static const auraDarkPanel = Color(0xFF171A21);
  static const auraDarkPanelRaised = Color(0xFF1E222B);
  static const auraDarkHairline = Color(0xFF2A2F3A);
  static const auraDarkText = Color(0xFFE8EAF0);
  static const auraDarkTextDim = Color(0xFF9AA3B2);
  static const auraDarkAccent = Color(0xFFD4FF3F);
  static const auraDarkAccentContrast = Color(0xFF10130A);
  static const auraDarkAccent2 = Color(0xFFFF6B35);
  static const auraDarkSuccess = Color(0xFF5AD19B);
  static const auraDarkWarning = Color(0xFFE8B93E);
  static const auraDarkError = Color(0xFFF05A5A);
  static const auraDarkVizSpectrum = Color(0xFFD4FF3F);
  static const auraDarkVizGrid = Color(0xFF232838);
  static const auraLightBg = Color(0xFFF4F1EA);
  static const auraLightPanel = Color(0xFFFFFFFF);
  static const auraLightPanelRaised = Color(0xFFFBFAF6);
  static const auraLightHairline = Color(0xFFE2DDCF);
  static const auraLightText = Color(0xFF1A1A1A);
  static const auraLightTextDim = Color(0xFF6E6A60);
  static const auraLightAccent = Color(0xFF5B7A00);
  static const auraLightAccentContrast = Color(0xFFFFF7F6);
  static const auraLightAccent2 = Color(0xFF22335C);
  static const auraLightSuccess = Color(0xFF1E7A4E);
  static const auraLightWarning = Color(0xFF9A6D00);
  static const auraLightError = Color(0xFFC0271B);
  static const auraLightVizSpectrum = Color(0xFF5B7A00);
  static const auraLightVizGrid = Color(0xFFE7E2D6);
  static const auroraBg = Color(0xFF070B14);
  static const auroraPanel = Color(0xFF0D1522);
  static const auroraPanelRaised = Color(0xFF122036);
  static const auroraHairline = Color(0xFF1B2A44);
  static const auroraText = Color(0xFFDCE6F5);
  static const auroraTextDim = Color(0xFF7C8CA6);
  static const auroraAccent = Color(0xFF64F0DC);
  static const auroraAccentContrast = Color(0xFF04110E);
  static const auroraAccent2 = Color(0xFFFF5EA8);
  static const auroraSuccess = Color(0xFF4FDE9E);
  static const auroraWarning = Color(0xFFF0C24B);
  static const auroraError = Color(0xFFFF6B6B);
  static const auroraVizSpectrum = Color(0xFF64F0DC);
  static const auroraVizGrid = Color(0xFF142033);
}

/// 间距（8pt 网格 + 语义留白）。
class TokSpace {
  const TokSpace._();
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const hero = 48.0;
  static const pageX = 32.0;
  static const pageTop = 26.0;
  static const pageBottom = 32.0;
  static const cardPad = 20.0;
  static const cardPadCollapsed = 14.0;
  static const cardHeadGap = 16.0;
  static const cardGap = 16.0;
  static const rowGap = 12.0;
  static const contentMaxW = 1080.0;
}

/// 组件尺寸。
class TokSize {
  const TokSize._();
  static const railW = 216.0;
  static const railMinW = 64.0;
  static const topBarH = 56.0;
  static const navItemH = 40.0;
  static const navIcon = 18.0;
  static const chipH = 30.0;
  static const switchW = 38.0;
  static const switchH = 22.0;
  static const switchThumb = 16.0;
  static const sliderThumb = 6.0;
  static const sliderTrack = 4.0;
  static const heroCompact = 48.0;
}

/// 圆角（6/10/14 三级 + xs）。
class TokRadius {
  const TokRadius._();
  static const xs = 4.0;
  static const sm = 6.0;
  static const md = 10.0;
  static const lg = 14.0;
}

/// 动效时长。
class TokDur {
  const TokDur._();
  static const instant = Duration(milliseconds: 90);
  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 380);
  static const page = Duration(milliseconds: 260);
  static const stagger = Duration(milliseconds: 55);
  static const staggerSpan = Duration(milliseconds: 620);
}

/// 动效曲线。
class TokCurve {
  const TokCurve._();
  static const standard = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const entrance = Cubic(0.16, 1.0, 0.3, 1.0);
}

/// 字号阶梯。
class TokType {
  const TokType._();
  static const hero = 40.0;
  static const display = 26.0;
  static const title = 18.0;
  static const body = 14.0;
  static const caption = 12.0;
  static const micro = 11.0;
}
