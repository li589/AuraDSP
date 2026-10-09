/*
 * design.dart — 设计令牌的代码侧落地（间距 / 节奏 / 动效 / 排版尺度）
 *
 * 真相源：design/tokens/aura.tokens.json（W3C Design Tokens 结构）。
 * 本文件只放常量与样式构造函数，不持有任何 widget，供 features/ 统一取用。
 *
 * 铁律：
 *   - 间距一律走 8pt 网格（4 / 8 / 12 / 16 / 24 / 32 / 48），禁止散落魔法数
 *   - 字号阶梯固定 6 级（hero 40 / display 26 / title 18 / body 14 / caption 12 / micro 11）
 *   - 数值读数走等宽 + tabular figures（见 theme.dart monoOf）
 *   - 正文绝不用得意黑（AuraDisplayCJK）——那是斜切海报体，只服务标题/品牌
 */
import 'package:flutter/material.dart';

import 'theme.dart';

/* ---------- 8pt 间距网格 ---------- */

class AuraSpace {
  const AuraSpace._();
  static const xxs = 2.0;
  static const xs = 4.0;
  static const sm = 8.0;
  static const md = 12.0;
  static const lg = 16.0;
  static const xl = 24.0;
  static const xxl = 32.0;
  static const hero = 48.0;

  /// 页面（内容区）左右留白——外框呼吸感的主要来源
  static const pageX = 32.0;

  /// 页面顶部/底部留白
  static const pageTop = 26.0;
  static const pageBottom = 32.0;

  /// 卡片内边距（四边统一，保证内容与外框的等距留白）
  static const cardPad = 20.0;

  /// 卡片标题 → 卡片内容
  static const cardHeadGap = 16.0;

  /// 卡片与卡片之间
  static const cardGap = 16.0;

  /// 卡片内部控件行之间
  static const rowGap = 12.0;

  /// 内容区最大宽度：超宽屏下居中留白，避免拉伸到失焦
  static const contentMaxW = 1080.0;
}

/* ---------- 组件尺寸 ---------- */

class AuraSize {
  const AuraSize._();
  static const railW = 216.0;
  static const railMinW = 64.0; // 收起态：仅图标
  static const topBarH = 56.0;
  static const navItemH = 40.0;
  static const navIcon = 18.0;
  static const chipH = 30.0;
  static const switchW = 38.0;
  static const switchH = 22.0;
  static const switchThumb = 16.0;
  static const sliderThumb = 6.0;
  static const sliderTrack = 4.0;
  static const heroH = 156.0;
}

/* ---------- 动效节奏 ---------- */

class AuraDur {
  const AuraDur._();
  static const instant = Duration(milliseconds: 90);
  static const fast = Duration(milliseconds: 140);
  static const base = Duration(milliseconds: 220);
  static const slow = Duration(milliseconds: 380);
  static const page = Duration(milliseconds: 260);

  /// 交错入场的单步延迟
  static const stagger = Duration(milliseconds: 55);
  static const staggerSpan = Duration(milliseconds: 620);
}

class AuraCurve {
  const AuraCurve._();
  static const standard = Curves.easeOutCubic;
  static const emphasized = Cubic(0.2, 0.0, 0.0, 1.0);
  static const entrance = Cubic(0.16, 1.0, 0.3, 1.0);
}

/* ---------- 排版尺度 ---------- */

/// 眉标（eyebrow）：等宽小字 + 大字距，用于分区/页面的上位标签
TextStyle eyebrowOf(AuraPalette p, {Color? color}) => TextStyle(
      fontFamily: 'AuraMono',
      fontSize: 11,
      height: 1.0,
      letterSpacing: 1.8,
      fontWeight: FontWeight.w500,
      color: color ?? p.textDim,
    );

/// 展示标题：品牌 / 页面主标题（Bricolage + 得意黑）
TextStyle displayOf(AuraPalette p, {double size = 26, Color? color}) => TextStyle(
      fontFamily: 'AuraDisplay',
      fontFamilyFallback: const ['AuraDisplayCJK'],
      fontSize: size,
      height: 1.1,
      fontWeight: FontWeight.w700,
      letterSpacing: -0.2,
      color: color ?? p.text,
    );

/// 卡片分区标题
TextStyle sectionOf(AuraPalette p, {Color? color}) => TextStyle(
      fontSize: 14,
      height: 1.2,
      fontWeight: FontWeight.w600,
      letterSpacing: 0.2,
      color: color ?? p.text,
    );

/// 正文 / 控件标签
TextStyle labelOf(AuraPalette p, {Color? color, double size = 13}) => TextStyle(
      fontSize: size,
      height: 1.3,
      color: color ?? p.text,
    );

/// 辅助说明
TextStyle captionOf(AuraPalette p, {Color? color}) => TextStyle(
      fontSize: 12,
      height: 1.5,
      color: color ?? p.textDim,
    );

/* ---------- 颜色派生（避免给 palette 加字段，保持令牌单一真相） ---------- */

/// 面板 hover 底色：在面板色上叠一层文本色微透明
Color hoverOn(AuraPalette p, {double alpha = 0.05}) =>
    Color.alphaBlend(p.text.withValues(alpha: alpha), p.panel);

/// 强调色的低存在感填充（选中底、氛围光）
Color accentWash(AuraPalette p, double alpha) => p.accent.withValues(alpha: alpha);

/* ---------- 主题扩展：从 BuildContext 取回 palette ---------- */

/// 把 AuraPalette 挂进 ThemeData.extensions。
///
/// 放在 design.dart（而非 features/widgets.dart）是有意的：chrome.dart 与
/// widgets.dart 都需要 paletteOf，放在两者共用的底层可避免互相 import 成环。
class _Aura extends ThemeExtension<_Aura> {
  final AuraPalette palette;
  const _Aura(this.palette);

  @override
  _Aura copyWith() => this;

  @override
  _Aura lerp(_Aura? other, double t) => this;
}

/// buildAuraTheme 之后调用一次，把 palette 注入 ThemeExtension。
ThemeData withAuraExtension(ThemeData base, AuraPalette p) =>
    base.copyWith(extensions: [_Aura(p)]);

/// 页面 / 组件里取 palette 的便捷通道。
AuraPalette paletteOf(BuildContext context) =>
    Theme.of(context).extension<_Aura>()!.palette;
