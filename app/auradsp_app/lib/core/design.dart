/*
 * design.dart — 设计令牌的代码侧落地（间距 / 节奏 / 动效 / 排版尺度）
 *
 * 真相源：app/auradsp_app/design/tokens/aura.tokens.json（W3C Design Tokens 结构）。
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
import 'tokens.g.dart';

/* ---------- 8pt 间距网格 ---------- */

class AuraSpace {
  const AuraSpace._();
  static const xxs = TokSpace.xxs;
  static const xs = TokSpace.xs;
  static const sm = TokSpace.sm;
  static const md = TokSpace.md;
  static const lg = TokSpace.lg;
  static const xl = TokSpace.xl;
  static const xxl = TokSpace.xxl;
  static const hero = TokSpace.hero;

  /// 页面（内容区）左右留白——外框呼吸感的主要来源
  static const pageX = TokSpace.pageX;

  /// 页面顶部/底部留白
  static const pageTop = TokSpace.pageTop;
  static const pageBottom = TokSpace.pageBottom;

  /// 卡片内边距（四边统一，保证内容与外框的等距留白）
  static const cardPad = TokSpace.cardPad;

  /// 折叠态卡片内边距（P0 仅定义、P1 由 SectionCard 接入；数值沿用现状 14.0，视觉不变）
  static const cardPadCollapsed = TokSpace.cardPadCollapsed;

  /// 卡片标题 → 卡片内容
  static const cardHeadGap = TokSpace.cardHeadGap;

  /// 卡片与卡片之间
  static const cardGap = TokSpace.cardGap;

  /// 卡片内部控件行之间
  static const rowGap = TokSpace.rowGap;

  /// 内容区最大宽度：超宽屏下居中留白，避免拉伸到失焦
  static const contentMaxW = TokSpace.contentMaxW;
}

/* ---------- 组件尺寸 ---------- */

class AuraSize {
  const AuraSize._();
  static const railW = TokSize.railW;
  static const railMinW = TokSize.railMinW; // 收起态：仅图标
  static const topBarH = TokSize.topBarH;
  static const navItemH = TokSize.navItemH;
  static const navIcon = TokSize.navIcon;
  static const chipH = TokSize.chipH;
  static const switchW = TokSize.switchW;
  static const switchH = TokSize.switchH;
  static const switchThumb = TokSize.switchThumb;
  static const sliderThumb = TokSize.sliderThumb;
  static const sliderTrack = TokSize.sliderTrack;
  /// 紧凑 hero 按钮（首页引擎状态卡）的高度。
  /// 此前误用 AuraSpace.hero（间距网格里的间距量）当高度；此处按类别归位，
  /// 数值保持 48.0 不变，以免改变视觉。
  static const heroCompact = TokSize.heroCompact;
}

/* ---------- 动效节奏 ---------- */

class AuraDur {
  const AuraDur._();
  static const instant = TokDur.instant;
  static const fast = TokDur.fast;
  static const base = TokDur.base;
  static const slow = TokDur.slow;
  static const page = TokDur.page;

  /// 交错入场的单步延迟
  static const stagger = TokDur.stagger;
  static const staggerSpan = TokDur.staggerSpan;
}

class AuraCurve {
  const AuraCurve._();
  static const standard = TokCurve.standard;
  static const emphasized = TokCurve.emphasized;
  static const entrance = TokCurve.entrance;
}

/* ---------- 排版尺度 ---------- */

/// 眉标（eyebrow）：等宽小字 + 大字距，用于分区/页面的上位标签
TextStyle eyebrowOf(AuraPalette p, {Color? color}) => TextStyle(
      fontFamily: 'AuraMono',
      fontFamilyFallback: kMonoFallback,
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

  /// 逐字段插值。MaterialApp 内部是 AnimatedTheme（默认 200ms 动画），
  /// ThemeData.lerp 对 extensions 调用 `begin.lerp(end, t)`——若恒返回
  /// this（旧 palette），动画全程 palette 硬停在旧值、终点才整体跳变，
  /// 与其余 ThemeData 颜色的平滑过渡不同步。t=1 时 Tween 直接取 end
  /// （新 ThemeData），不走本函数，故终点颜色不受插值质量影响。
  @override
  _Aura lerp(_Aura? other, double t) {
    if (other == null) return this;
    Color c(Color a, Color b) => Color.lerp(a, b, t)!;
    final a = palette, b = other.palette;
    return _Aura(AuraPalette(
      bg: c(a.bg, b.bg),
      panel: c(a.panel, b.panel),
      panelRaised: c(a.panelRaised, b.panelRaised),
      hairline: c(a.hairline, b.hairline),
      text: c(a.text, b.text),
      textDim: c(a.textDim, b.textDim),
      accent: c(a.accent, b.accent),
      accentContrast: c(a.accentContrast, b.accentContrast),
      accent2: c(a.accent2, b.accent2),
      success: c(a.success, b.success),
      warning: c(a.warning, b.warning),
      error: c(a.error, b.error),
      vizSpectrum: c(a.vizSpectrum, b.vizSpectrum),
      vizGrid: c(a.vizGrid, b.vizGrid),
    ));
  }
}

/// buildAuraTheme 之后调用一次，把 palette 注入 ThemeExtension。
ThemeData withAuraExtension(ThemeData base, AuraPalette p) =>
    base.copyWith(extensions: [_Aura(p)]);

/// 页面 / 组件里取 palette 的便捷通道。
AuraPalette paletteOf(BuildContext context) =>
    Theme.of(context).extension<_Aura>()!.palette;
