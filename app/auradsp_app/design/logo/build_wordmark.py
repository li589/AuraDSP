# -*- coding: utf-8 -*-
"""AuraDSP 字标：Bricolage Grotesque 700 转曲为 SVG 路径。

所有字形永久转为路径，不依赖目标机器安装字体。
"""
import io
import os

from fontTools.pens.svgPathPen import SVGPathPen
from fontTools.pens.transformPen import TransformPen
from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))))
SRC = os.path.join(ROOT, r"app\auradsp_app\assets\fonts\BricolageGrotesque.ttf")
OUT = os.path.join(ROOT, r"app\auradsp_app\design\logo")

CAP_PX = 100.0
# 以下字距均为 font units（upem=1000），渲染时按 cap_px 缩放。
TRACKING = -22.0
PAIR_KERN = {
    "Au": 6.0,
    "ur": 0.0,
    "ra": 2.0,
    "aD": 8.0,
    "DS": 4.0,
    "SP": 2.0,
}


def _load(weight):
    font = TTFont(SRC)
    return instantiateVariableFont(
        font, {"wght": weight, "opsz": 96, "wdth": 100},
        inplace=False, updateFontNames=False)


def build_text(text="AuraDSP", weight=700, cap_px=CAP_PX, tracking=TRACKING,
               pair_kern=None, fill="#E8EAF0"):
    pair_kern = PAIR_KERN if pair_kern is None else pair_kern
    font = _load(weight)
    cap = font["OS/2"].sCapHeight
    s = cap_px / cap
    cmap = font.getBestCmap()
    glyf = font["glyf"]
    hmtx = font["hmtx"]

    x = 0.0
    parts = []
    ink = [1e9, 1e9, -1e9, -1e9]
    for i, ch in enumerate(text):
        gname = cmap[ord(ch)]
        if i > 0:
            x += (tracking + pair_kern.get(text[i - 1] + ch, 0.0)) * s
        pen = SVGPathPen(glyf, ntos=lambda v: f"{v:.2f}")
        tpen = TransformPen(pen, (s, 0, 0, -s, x, 0))
        glyf[gname].draw(tpen, glyf)
        parts.append(pen.getCommands())
        g = glyf[gname]
        if hasattr(g, "xMin"):
            ink[0] = min(ink[0], x + g.xMin * s)
            ink[1] = min(ink[1], -g.yMax * s)
            ink[2] = max(ink[2], x + g.xMax * s)
            ink[3] = max(ink[3], -g.yMin * s)
        x += hmtx[gname][0] * s
    return {
        "d": " ".join(parts),
        "width": x,
        "ink": tuple(ink),
        "fill": fill,
        "cap": cap,
        "s": s,
    }


def wordmark_svg(fill="#E8EAF0", cap_px=CAP_PX, pad=6.0):
    r = build_text(fill=fill, cap_px=cap_px)
    x0, y0, x1, y1 = r["ink"]
    w, h = x1 - x0 + pad * 2, y1 - y0 + pad * 2
    body = (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:.2f} {h:.2f}" '
        f'width="{w:.2f}" height="{h:.2f}" role="img" aria-label="AuraDSP">\n'
        f'  <g transform="translate({-x0 + pad:.2f},{-y0 + pad:.2f})" fill="{fill}">\n'
        f'    <path d="{r["d"]}"/>\n'
        f'  </g>\n</svg>\n'
    )
    return body, r


def write_test_page():
    variants = []
    for name, tr in [("紧排 -40", -40.0), ("定稿 -22", -22.0), ("标准 -8", -8.0)]:
        r = build_text(tracking=tr, cap_px=100.0)
        x0, y0, x1, y1 = r["ink"]
        w, h = x1 - x0 + 12, y1 - y0 + 12
        svg = (
            f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w:.2f} {h:.2f}" '
            f'width="{88 * w / h:.2f}" height="88">'
            f'<g transform="translate({-x0 + 6:.2f},{-y0 + 6:.2f})">'
            f'<path d="{r["d"]}" fill="currentColor"/></g></svg>'
        )
        variants.append((name, svg))

    cards = ""
    for name, svg in variants:
        cards += f"""
        <div class="card">
          <div class="cap">{name}</div>
          <div class="dark">{svg}</div>
          <div class="light">{svg}</div>
        </div>"""

    html = f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>AuraDSP 字标测试</title>
<style>
  @font-face {{ font-family:'AuraDisplay'; src:url('../../assets/fonts/BricolageGrotesque.ttf'); font-weight:100 900; }}
  body {{ margin:0; padding:36px; background:#0b0c10; color:#e8eaf0; font-family:'AuraDisplay','Segoe UI',sans-serif; }}
  h1 {{ font-size:26px; margin:0 0 24px; }}
  .row {{ display:flex; flex-direction:column; gap:16px; }}
  .card {{ border:1px solid #2a2f3a; border-radius:12px; overflow:hidden; }}
  .cap {{ font-family:Consolas,monospace; font-size:11px; color:#9aa3b2; padding:10px 16px; letter-spacing:.06em; border-bottom:1px solid #2a2f3a; }}
  .dark, .light {{ padding:26px 32px; display:flex; align-items:center; }}
  .dark {{ background:#0e0f13; color:#e8eaf0; }}
  .light {{ background:#f4f1ea; color:#1a1a1a; }}
  .dark svg, .light svg {{ display:block; }}
</style></head><body>
<h1>AuraDSP 字标 · 字距对比</h1>
<div class="row">{cards}</div>
</body></html>"""
    io.open(os.path.join(OUT, "wordmark-test.html"), "w",
            encoding="utf-8", newline="").write(html)


def main():
    for name, fill in [("light", "#E8EAF0"), ("dark", "#1A1A1A")]:
        svg, meta = wordmark_svg(fill=fill)
        p = os.path.join(OUT, f"auradsp-wordmark-{name}.svg")
        io.open(p, "w", encoding="utf-8", newline="").write(svg)
        print(name, "width", round(meta["width"], 2), "ink", meta["ink"])
    write_test_page()


if __name__ == "__main__":
    main()
