#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""gen_theme.py — 设计令牌生成器（P2-1，2026-10-23）

真相源：app/auradsp_app/design/tokens/aura.tokens.json（W3C Design Tokens）
产出：  app/auradsp_app/lib/core/tokens.g.dart（**生成物，勿手改**）

用法：
    python tools/gen_theme.py            # 生成
    python tools/gen_theme.py --check    # 只校验生成物是否最新（不写盘，CI/测试用）

漂移防线：app/auradsp_app/test/tokens_parity_test.dart 把运行时常量与 JSON
逐项比对——改了 JSON 忘了重跑本脚本，测试会红。
"""
import io
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "app", "auradsp_app", "design", "tokens", "aura.tokens.json")
OUT = os.path.join(ROOT, "app", "auradsp_app", "lib", "core", "tokens.g.dart")

PALETTES = {"aura-dark": "auraDark", "aura-light": "auraLight", "aurora": "aurora"}
COLOR_KEYS = {
    "bg": "bg", "panel": "panel", "panel-raised": "panelRaised",
    "hairline": "hairline", "text": "text", "text-dim": "textDim",
    "accent": "accent", "accent-contrast": "accentContrast",
    "accent-2": "accent2", "success": "success", "warning": "warning",
    "error": "error", "viz-spectrum": "vizSpectrum", "viz-grid": "vizGrid",
}
SPACE_KEYS = {"xxs": "xxs", "xs": "xs", "sm": "sm", "md": "md",
              "lg": "lg", "xl": "xl", "xxl": "xxl", "hero": "hero"}
SPACE_SEMANTIC = {
    "page-x": "pageX", "page-top": "pageTop", "page-bottom": "pageBottom",
    "card-pad": "cardPad", "card-pad-collapsed": "cardPadCollapsed",
    "card-head-gap": "cardHeadGap", "card-gap": "cardGap",
    "row-gap": "rowGap", "content-max-w": "contentMaxW",
}
SIZE_KEYS = {
    "rail-w": "railW", "rail-min-w": "railMinW", "top-bar-h": "topBarH",
    "nav-item-h": "navItemH", "nav-icon": "navIcon", "chip-h": "chipH",
    "switch-w": "switchW", "switch-h": "switchH",
    "switch-thumb": "switchThumb", "slider-thumb": "sliderThumb",
    "slider-track": "sliderTrack", "hero-compact": "heroCompact",
}
RADIUS_KEYS = {"xs": "xs", "sm": "sm", "md": "md", "lg": "lg"}
DUR_KEYS = {"instant": "instant", "fast": "fast", "base": "base",
            "slow": "slow", "page": "page", "stagger-step": "stagger",
            "stagger-span": "staggerSpan"}
CURVE_KEYS = {"standard": "standard", "emphasized": "emphasized",
              "entrance": "entrance"}
TYPE_KEYS = {"hero": "hero", "display": "display", "title": "title",
             "body": "body", "caption": "caption", "micro": "micro"}


def px(v):
    """数值令牌 → float：兼容 2px / 90ms / 1080px。"""
    s = str(v).strip()
    for unit in ("px", "ms"):
        if s.endswith(unit):
            s = s[: -len(unit)]
    return float(s)


def hex_color(v):
    h = str(v).strip().lstrip("#")
    if len(h) == 3:
        h = "".join(c * 2 for c in h)
    return "0xFF%s" % h.upper()


def curve_expr(name, v):
    v = str(v).strip()
    if v.startswith("cubic-bezier("):
        parts = [float(x) for x in v[len("cubic-bezier("):-1].split(",")]
        return "Cubic(%s)" % ", ".join("0.0" if p == 0 else repr(p) for p in parts)
    if v == "easeOutCubic":
        return "Curves.easeOutCubic"
    if v == "easeInOutCubic":
        return "Curves.easeInOutCubic"
    if v == "linear":
        return "Curves.linear"
    raise SystemExit("未知曲线 %s=%s（在 gen_theme.py 里补映射）" % (name, v))


def build(tokens):
    L = []
    L.append("// GENERATED FILE — DO NOT EDIT BY HAND.")
    L.append("// 源: app/auradsp_app/design/tokens/aura.tokens.json")
    L.append("// 生成: python tools/gen_theme.py（改 JSON 后必须重跑）")
    L.append("// 漂移防线: test/tokens_parity_test.dart（JSON vs 运行时常量逐项比对）")
    L.append("")
    L.append("import 'package:flutter/material.dart';")
    L.append("")
    L.append("/// 配色（3 套主题 × 14 色）。")
    L.append("class TokColor {")
    L.append("  const TokColor._();")
    for pk, pv in PALETTES.items():
        for ck, cv in COLOR_KEYS.items():
            val = tokens["color"][pk][ck]["value"]
            L.append("  static const %s%s = Color(%s);" % (pv, cv[0].upper() + cv[1:], hex_color(val)))
    L.append("}")
    L.append("")
    L.append("/// 间距（8pt 网格 + 语义留白）。")
    L.append("class TokSpace {")
    L.append("  const TokSpace._();")
    for k, name in SPACE_KEYS.items():
        L.append("  static const %s = %s;" % (name, repr(px(tokens["spacing"][k]["value"]))))
    for k, name in SPACE_SEMANTIC.items():
        L.append("  static const %s = %s;" % (name, repr(px(tokens["spacing"]["semantic"][k]["value"]))))
    L.append("}")
    L.append("")
    L.append("/// 组件尺寸。")
    L.append("class TokSize {")
    L.append("  const TokSize._();")
    for k, name in SIZE_KEYS.items():
        L.append("  static const %s = %s;" % (name, repr(px(tokens["size"][k]["value"]))))
    L.append("}")
    L.append("")
    L.append("/// 圆角（6/10/14 三级 + xs）。")
    L.append("class TokRadius {")
    L.append("  const TokRadius._();")
    for k, name in RADIUS_KEYS.items():
        L.append("  static const %s = %s;" % (name, repr(px(tokens["radius"][k]["value"]))))
    L.append("}")
    L.append("")
    L.append("/// 动效时长。")
    L.append("class TokDur {")
    L.append("  const TokDur._();")
    for k, name in DUR_KEYS.items():
        ms = int(round(px(tokens["motion"]["duration"][k]["value"])))
        L.append("  static const %s = Duration(milliseconds: %d);" % (name, ms))
    L.append("}")
    L.append("")
    L.append("/// 动效曲线。")
    L.append("class TokCurve {")
    L.append("  const TokCurve._();")
    for k, name in CURVE_KEYS.items():
        L.append("  static const %s = %s;" % (name, curve_expr(k, tokens["motion"]["curve"][k]["value"])))
    L.append("}")
    L.append("")
    L.append("/// 字号阶梯。")
    L.append("class TokType {")
    L.append("  const TokType._();")
    for k, name in TYPE_KEYS.items():
        L.append("  static const %s = %s;" % (name, repr(px(tokens["typography"]["scale"][k]["value"]))))
    L.append("}")
    L.append("")
    return "\n".join(L)


def main():
    tokens = json.load(io.open(SRC, encoding="utf-8"))
    text = build(tokens)
    check = "--check" in sys.argv
    old = io.open(OUT, encoding="utf-8").read() if os.path.exists(OUT) else ""
    if check:
        if old != text:
            print("DRIFT: tokens.g.dart 与 JSON 不一致，请运行 python tools/gen_theme.py")
            return 1
        print("OK: tokens.g.dart 与 JSON 一致")
        return 0
    io.open(OUT, "w", encoding="utf-8", newline="\n").write(text)
    print("wrote %s (%d bytes)" % (OUT, len(text.encode("utf-8"))))
    return 0


if __name__ == "__main__":
    sys.exit(main())
