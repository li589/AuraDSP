# -*- coding: utf-8 -*-
"""AuraDSP 定稿资产生成：标记 / 字标 / 横排锁定 / App 图标 / 托盘图标。

用法：python build_assets.py
输出 SVG、PNG（16–1024）与多尺寸 .ico 到 design/logo 及其 icons/ 子目录。
"""
import io
import os
import struct
import subprocess
import tempfile
import time

import numpy as np
from PIL import Image

import build_wordmark as W

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
OUT = os.path.join(ROOT, r"app\auradsp_app\design\logo")
ICONS = os.path.join(OUT, "icons")
EDGE = r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe"

DARK_STOPS = [("0", "#D4FF3F"), ("0.55", "#9BF873"), ("1", "#64F0DC")]
LIGHT_STOPS = [("0", "#5B7A00"), ("0.55", "#2F7D46"), ("1", "#0E7C6B")]

# ---- 几何（256 网格）------------------------------------------------------
# A：双脚放宽到 58/198，笔画 23，内腔足以容纳波形横杠。
A_PATH = "M58 198 128 52 198 198"
A_STROKE = 23
#  waveform crossbar: flat tails merge into both legs, one smooth cycle.
#  baseline y=150, peak y=140, trough y=160, ends x=94/162.
WAVE_PATH = (
    "M94 150H104C109 150 112 140 116 140C120 140 124 145 128 150"
    "C132 155 136 160 140 160C144 160 148 150 152 150H162")
WAVE_STROKE = 11


def a_body(stroke):
    return (
        f'<path d="{A_PATH}" fill="none" stroke="{stroke}" '
        f'stroke-width="{A_STROKE}" stroke-linecap="round" stroke-linejoin="round"/>'
        f'<path d="{WAVE_PATH}" fill="none" stroke="{stroke}" '
        f'stroke-width="{WAVE_STROKE}" stroke-linecap="round" stroke-linejoin="round"/>')


def gradient(stops, gid="auraGrad"):
    s = "".join(
        f'<stop offset="{o}" stop-color="{c}"/>' for o, c in stops)
    return (
        f'<linearGradient id="{gid}" x1="52" y1="44" x2="204" y2="212" '
        f'gradientUnits="userSpaceOnUse">{s}</linearGradient>')


def mark_inner(stroke="url(#auraGrad)", halo=True):
    out = []
    if halo:
        out.append(
            f'<circle cx="128" cy="128" r="104" fill="none" stroke="{stroke}" '
            f'stroke-width="3" opacity="0.14"/>')
        out.append(
            f'<circle cx="128" cy="128" r="94" fill="none" stroke="{stroke}" '
            f'stroke-width="6" opacity="0.32"/>')
    out.append(a_body(stroke))
    return "\n  ".join(out)


def svg_mark(kind="dark"):
    if kind == "mono":
        defs, stroke = "", "currentColor"
    else:
        stops = LIGHT_STOPS if kind == "light" else DARK_STOPS
        defs, stroke = f"<defs>{gradient(stops)}</defs>", "url(#auraGrad)"
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" '
        f'width="256" height="256" role="img" aria-label="AuraDSP">\n'
        f'  {defs}\n  {mark_inner(stroke)}\n</svg>\n')


def svg_lockup(kind="dark"):
    text_fill = "#E8EAF0" if kind == "dark" else "#1A1A1A"
    stops = LIGHT_STOPS if kind == "light" else DARK_STOPS
    word = W.build_text(cap_px=40.0, fill=text_fill)
    x0, y0, x1, y1 = word["ink"]
    mark_size, gap, baseline = 72.0, 22.0, 56.0
    scale = mark_size / 256.0
    wx = mark_size + gap - x0
    width = wx + (x1 - x0) + 8.0
    height = 72.0
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {width:.2f} {height:.2f}" '
        f'width="{width:.2f}" height="{height:.2f}" role="img" aria-label="AuraDSP">\n'
        f'  <defs>{gradient(stops)}</defs>\n'
        f'  <g transform="scale({scale:.6f})">{mark_inner()}</g>\n'
        f'  <g transform="translate({wx:.2f},{baseline:.2f})" fill="{text_fill}">'
        f'<path d="{word["d"]}"/></g>\n</svg>\n'), width, height


def svg_app_icon():
    scale, off = 0.9, 128.0 * (1.0 - 0.9)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" '
        f'width="256" height="256" role="img" aria-label="AuraDSP">\n'
        f'  <defs>{gradient(DARK_STOPS)}</defs>\n'
        f'  <rect width="256" height="256" rx="56" fill="#0E0F13"/>\n'
        f'  <rect x="0.5" y="0.5" width="255" height="255" rx="55.5" '
        f'fill="none" stroke="#FFFFFF" stroke-opacity="0.06"/>\n'
        f'  <g transform="translate({off:.2f},{off:.2f}) scale({scale})">'
        f'{mark_inner()}</g>\n</svg>\n')


def svg_app_icon_small():
    """16/20px 专用：去光环，A 放大，避免细环在低分辨率变噪点。"""
    scale, off = 1.18, 128.0 * (1.0 - 1.18)
    body = a_body("url(#auraGrad)")
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" '
        f'width="256" height="256" role="img" aria-label="AuraDSP">\n'
        f'  <defs>{gradient(DARK_STOPS)}</defs>\n'
        f'  <rect width="256" height="256" rx="56" fill="#0E0F13"/>\n'
        f'  <rect x="0.5" y="0.5" width="255" height="255" rx="55.5" '
        f'fill="none" stroke="#FFFFFF" stroke-opacity="0.06"/>\n'
        f'  <g transform="translate({off:.2f},{off:.2f}) scale({scale})">{body}</g>\n'
        f'</svg>\n')


def svg_tray(kind="gradient"):
    """托盘/小尺寸：去掉光环，A 放大到画布 ~92%，16px 仍清晰。"""
    stops = DARK_STOPS if kind == "gradient" else None
    if kind == "gradient":
        defs, stroke = f"<defs>{gradient(stops)}</defs>", "url(#auraGrad)"
    elif kind == "light":
        defs, stroke = "", "#F2F4F8"
    else:
        defs, stroke = "", "#14161A"
    body = a_body(stroke)
    return (
        f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 256 256" '
        f'width="256" height="256" role="img" aria-label="AuraDSP">\n'
        f'  {defs}\n'
        f'  <g transform="translate(128,128) scale(1.32) translate(-128,-128)">'
        f'{body}</g>\n</svg>\n')


def write(path, text):
    io.open(path, "w", encoding="utf-8", newline="").write(text)


# ---------------------------------------------------------------- rendering
def render_svg(svg_path, out_png, width, height, dsf=1):
    """用 Edge 无头渲染 SVG。HTML 与 SVG 同目录，避免 file:// 跨目录取图限制。"""
    html_path = os.path.join(OUT, "_render_tmp.html")
    slug = os.path.basename(svg_path)
    write(html_path, (
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><style>"
        "html,body{margin:0;padding:0;background:transparent;overflow:hidden}"
        "img{display:block;width:100vw;height:100vh;object-fit:contain}"
        "</style></head><body><img src=\"" + slug + "\"></body></html>"))
    for attempt in range(4):
        args = [
            EDGE, "--headless=new", "--disable-gpu", "--no-sandbox",
            "--no-first-run", "--no-default-browser-check",
            f"--user-data-dir={os.path.join(tempfile.gettempdir(), 'aura_edge_' + str(os.getpid()))}",
            "--hide-scrollbars", f"--force-device-scale-factor={dsf}",
            "--default-background-color=00000000",
            f"--window-size={width},{height}", "--virtual-time-budget=4000",
            f"--screenshot={out_png}", "file:///" + html_path.replace("\\", "/"),
        ]
        if os.path.exists(out_png):
            os.remove(out_png)
        p = subprocess.run(args, timeout=90, capture_output=True,
                           creationflags=0x08000000)
        for _ in range(60):
            if os.path.exists(out_png) and os.path.getsize(out_png) > 0:
                return out_png
            time.sleep(0.25)
        print("edge retry", attempt, p.returncode,
              p.stderr.decode("utf-8", "replace")[-400:])
    raise RuntimeError("render failed: " + svg_path)


def resize_rgba(im, w, h):
    arr = np.asarray(im.convert("RGBA"), dtype=np.float32)
    a = arr[..., 3:4] / 255.0
    pm = np.concatenate([arr[..., :3] * a, arr[..., 3:4]], axis=2).astype(np.uint8)
    out = Image.fromarray(pm, "RGBA").resize((w, h), Image.LANCZOS)
    o = np.asarray(out, dtype=np.float32)
    ao = o[..., 3:4] / 255.0
    rgb = np.where(ao > 1e-6, o[..., :3] / np.maximum(ao, 1e-6), 0.0)
    rgb = np.clip(rgb, 0, 255)
    return Image.fromarray(
        np.concatenate([rgb, o[..., 3:4]], axis=2).astype(np.uint8), "RGBA")


def trim(im, pad=12):
    bbox = im.getchannel("A").getbbox()
    if not bbox:
        return im
    im = im.crop(bbox)
    canvas = Image.new("RGBA", (im.width + pad * 2, im.height + pad * 2), (0, 0, 0, 0))
    canvas.paste(im, (pad, pad))
    return canvas


def write_png(im, path, size=None):
    if size:
        im = resize_rgba(im, size, size)
    im.save(path, "PNG", optimize=True)


def write_ico(images, path):
    entries = []
    for size, im in images:
        buf = io.BytesIO()
        im.save(buf, "PNG", optimize=True)
        entries.append((size, buf.getvalue()))
    entries.sort(key=lambda x: x[0])
    head = struct.pack("<HHH", 0, 1, len(entries))
    off = 6 + 16 * len(entries)
    dirs, blobs = b"", []
    for size, data in entries:
        b = 0 if size >= 256 else size
        dirs += struct.pack("<BBBBHHII", b, b, 0, 0, 1, 32, len(data), off)
        off += len(data)
        blobs.append(data)
    io.open(path, "wb").write(head + dirs + b"".join(blobs))


# ---------------------------------------------------------------- preview
def build_preview(app_png="icons/auradsp-app-256.png", tray_png="icons/auradsp-tray-256.png"):
    return f"""<!DOCTYPE html>
<html lang="zh-CN"><head><meta charset="utf-8">
<title>AuraDSP · 品牌定稿</title>
<style>
  @font-face {{ font-family:'AuraDisplay'; src:url('../../assets/fonts/BricolageGrotesque.ttf'); font-weight:100 900; }}
  :root {{ --bg:#0b0c10; --tile:#0e0f13; --line:#2a2f3a; --text:#e8eaf0; --dim:#9aa3b2; --lime:#d4ff3f; --cyan:#64f0dc; }}
  * {{ box-sizing:border-box; }}
  body {{ margin:0; padding:44px 40px 64px; background:var(--bg); color:var(--text); font-family:'AuraDisplay','Segoe UI',sans-serif; }}
  h1 {{ font-size:30px; font-weight:700; margin:0 0 6px; letter-spacing:-.01em; }}
  h1 .g {{ background:linear-gradient(100deg,var(--lime),var(--cyan)); -webkit-background-clip:text; background-clip:text; color:transparent; }}
  .sub {{ color:var(--dim); font-family:Consolas,monospace; font-size:12px; letter-spacing:.04em; margin-bottom:34px; }}
  .card {{ background:#111319; border:1px solid var(--line); border-radius:14px; padding:26px; margin-bottom:18px; }}
  .label {{ font-family:Consolas,monospace; font-size:10px; letter-spacing:.08em; color:var(--dim); margin-bottom:18px; }}
  .hero {{ display:flex; align-items:center; justify-content:center; padding:52px 24px; border-radius:12px; background:var(--tile); border:1px solid rgba(255,255,255,.05); }}
  .hero img {{ width:min(560px,86%); }}
  .lighthero {{ background:#f4f1ea; border-color:#e2ddcf; }}
  .grid2 {{ display:grid; grid-template-columns:1fr 1fr; gap:18px; }}
  .row {{ display:flex; align-items:flex-end; gap:22px; flex-wrap:wrap; }}
  .sz {{ display:flex; flex-direction:column; align-items:center; gap:8px; }}
  .sz .tile {{ background:var(--tile); border:1px solid rgba(255,255,255,.06); display:grid; place-items:center; }}
  .sz span {{ font-family:Consolas,monospace; font-size:10px; color:var(--dim); }}
  .t256 {{ width:256px; height:256px; border-radius:56px; }}
  .t128 {{ width:128px; height:128px; border-radius:28px; }}
  .t64 {{ width:64px; height:64px; border-radius:17px; }}
  .t48 {{ width:48px; height:48px; border-radius:13px; }}
  .t32 {{ width:32px; height:32px; border-radius:9px; }}
  .t24 {{ width:24px; height:24px; border-radius:7px; }}
  .t20 {{ width:20px; height:20px; border-radius:6px; }}
  .t16 {{ width:16px; height:16px; border-radius:5px; }}
  .tile img {{ width:100%; height:100%; display:block; }}
  .lightbg {{ background:#f4f1ea !important; border-color:#e2ddcf !important; }}
  .taskbar {{ display:flex; align-items:center; gap:20px; padding:10px 18px; border-radius:10px; background:#202020; }}
  .taskbar.light {{ background:#f0f0f0; margin-top:10px; }}
  .taskbar img {{ display:block; }}
  .taskbar .cap {{ font-family:Consolas,monospace; font-size:10px; color:#9aa3b2; margin-right:6px; }}
  .taskbar.light .cap {{ color:#6e6a60; }}
  .colors {{ display:grid; grid-template-columns:repeat(6,1fr); gap:10px; }}
  .sw {{ border-radius:8px; height:74px; border:1px solid rgba(255,255,255,.07); padding:9px 10px; display:flex; flex-direction:column; justify-content:flex-end; font-family:Consolas,monospace; font-size:10px; }}
  .sw b {{ font-weight:600; letter-spacing:.02em; }}
  .specs {{ display:grid; grid-template-columns:repeat(3,1fr); gap:18px; color:var(--dim); font-size:13px; line-height:1.65; }}
  .specs b {{ color:var(--text); display:block; font-size:12px; letter-spacing:.02em; margin-bottom:3px; font-family:Consolas,monospace; }}
  .foot {{ color:var(--dim); font-size:12px; line-height:1.7; }}
  code {{ font-family:Consolas,monospace; color:#c7ff5e; }}
  @media (max-width:900px) {{ .grid2 {{ grid-template-columns:1fr; }} .colors {{ grid-template-columns:repeat(3,1fr); }} .specs {{ grid-template-columns:1fr; }} }}
</style></head><body>
  <h1>AuraDSP <span class="g">Brand Mark</span></h1>
  <div class="sub">FINAL v1 · AURA A · LIME → CYAN · 2026-10-28</div>

  <div class="card">
    <div class="label">01 / PRIMARY LOCKUP · DARK</div>
    <div class="hero"><img src="auradsp-lockup-dark.svg" alt="AuraDSP"></div>
  </div>

  <div class="card">
    <div class="label">02 / LIGHT THEME LOCKUP</div>
    <div class="hero lighthero"><img src="auradsp-lockup-light.svg" alt="AuraDSP"></div>
  </div>

  <div class="grid2">
    <div class="card">
      <div class="label">03 / APP ICON</div>
      <div class="row">
        <div class="sz"><div class="tile t256"><img src="icons/auradsp-app-256.png" alt=""></div><span>256</span></div>
        <div class="sz"><div class="tile t64"><img src="icons/auradsp-app-64.png" alt=""></div><span>64</span></div>
        <div class="sz"><div class="tile t32"><img src="icons/auradsp-app-32.png" alt=""></div><span>32</span></div>
        <div class="sz"><div class="tile t16"><img src="icons/auradsp-app-16.png" alt=""></div><span>16</span></div>
      </div>
    </div>
    <div class="card">
      <div class="label">04 / LIGHT BACKGROUND</div>
      <div class="row">
        <div class="sz"><div class="tile t128 lightbg"><img src="icons/auradsp-app-128.png" alt=""></div><span>128</span></div>
        <div class="sz"><div class="tile t64 lightbg"><img src="icons/auradsp-app-64.png" alt=""></div><span>64</span></div>
        <div class="sz"><div class="tile t32 lightbg"><img src="icons/auradsp-app-32.png" alt=""></div><span>32</span></div>
        <div class="sz"><div class="tile t16 lightbg"><img src="icons/auradsp-app-16.png" alt=""></div><span>16</span></div>
      </div>
    </div>
  </div>

  <div class="card">
    <div class="label">05 / TRAY · 16–40 PX</div>
    <div class="taskbar">
      <span class="cap">DARK</span>
      <img src="icons/auradsp-tray-40.png" width="40" alt=""><img src="icons/auradsp-tray-32.png" width="32" alt="">
      <img src="icons/auradsp-tray-24.png" width="24" alt=""><img src="icons/auradsp-tray-20.png" width="20" alt="">
      <img src="icons/auradsp-tray-16.png" width="16" alt="">
    </div>
    <div class="taskbar light">
      <span class="cap">LIGHT</span>
      <img src="icons/auradsp-tray-dark-40.png" width="40" alt=""><img src="icons/auradsp-tray-dark-32.png" width="32" alt="">
      <img src="icons/auradsp-tray-dark-24.png" width="24" alt=""><img src="icons/auradsp-tray-dark-20.png" width="20" alt="">
      <img src="icons/auradsp-tray-dark-16.png" width="16" alt="">
    </div>
  </div>

  <div class="card">
    <div class="label">06 / SYMBOL &amp; WORDMARK</div>
    <div class="row" style="align-items:center">
      <img src="auradsp-mark.svg" width="120" alt="">
      <img src="auradsp-wordmark-light.svg" width="360" alt="">
    </div>
  </div>

  <div class="card">
    <div class="label">07 / COLOR</div>
    <div class="colors">
      <div class="sw" style="background:#D4FF3F;color:#10130A"><b>#D4FF3F</b><span>gradient 0</span></div>
      <div class="sw" style="background:#9BF873;color:#10130A"><b>#9BF873</b><span>gradient 55</span></div>
      <div class="sw" style="background:#64F0DC;color:#04110E"><b>#64F0DC</b><span>gradient 1</span></div>
      <div class="sw" style="background:#0E0F13;color:#E8EAF0"><b>#0E0F13</b><span>icon tile</span></div>
      <div class="sw" style="background:#5B7A00;color:#fff"><b>#5B7A00</b><span>light 0</span></div>
      <div class="sw" style="background:#0E7C6B;color:#fff"><b>#0E7C6B</b><span>light 1</span></div>
    </div>
  </div>

  <div class="card">
    <div class="label">08 / SPECS</div>
    <div class="specs">
      <div><b>CONSTRUCTION</b>256 单位网格；A 顶点 (128,52)，双脚 (58,198)/(198,198)，笔画 23；横杠为平滑波形，基线 y=150、振幅 ±10、笔画 11，两端与腿内缘相接；光环 r=94/104。</div>
      <div><b>CLEAR SPACE</b>横排锁定的最小留白 = 字标大写高度的 50%；图标四周至少保留圆角半径的 1/2。</div>
      <div><b>MINIMUM SIZE</b>符号单独使用 ≥16px；横排锁定 ≥96px 宽。16/20/24px App 图标与所有托盘图标使用去光环简化版。</div>
    </div>
  </div>

  <p class="foot">字标已转曲（Bricolage Grotesque 700），不依赖字体。<br>
  全套导出：<code>icons/auradsp-app-*.png</code>（16–1024）、<code>icons/auradsp.ico</code>、<code>icons/auradsp-tray.ico</code>。<br>
  深色版用于 App 默认主题；浅色版使用设计令牌 olive/teal 渐变，保证浅底对比度。</p>
</body></html>"""


def main():
    os.makedirs(ICONS, exist_ok=True)
    for kind in ("dark", "light", "mono"):
        write(os.path.join(OUT, f"auradsp-mark-{kind}.svg" if kind != "dark" else "auradsp-mark.svg"),
              svg_mark(kind))
    for kind in ("dark", "light"):
        svg, w, h = svg_lockup(kind)
        write(os.path.join(OUT, f"auradsp-lockup-{kind}.svg"), svg)
    write(os.path.join(OUT, "auradsp-app-icon.svg"), svg_app_icon())
    write(os.path.join(OUT, "auradsp-app-icon-small.svg"), svg_app_icon_small())
    for kind in ("gradient", "dark", "light"):
        name = "auradsp-tray.svg" if kind == "gradient" else f"auradsp-tray-{kind}.svg"
        write(os.path.join(OUT, name), svg_tray(kind))
    W.main()

    # ---- render masters
    tmp = os.path.join(tempfile.gettempdir(), "auradsp_logo_masters")
    os.makedirs(tmp, exist_ok=True)
    app_master = render_svg(os.path.join(OUT, "auradsp-app-icon.svg"),
                            os.path.join(tmp, "app.png"), 1024, 1024)
    app_small_master = render_svg(os.path.join(OUT, "auradsp-app-icon-small.svg"),
                                  os.path.join(tmp, "app-small.png"), 1024, 1024)
    tray_master = render_svg(os.path.join(OUT, "auradsp-tray.svg"),
                             os.path.join(tmp, "tray.png"), 1024, 1024)
    mark_master = render_svg(os.path.join(OUT, "auradsp-mark.svg"),
                             os.path.join(tmp, "mark.png"), 1024, 1024)
    lock_dark = render_svg(os.path.join(OUT, "auradsp-lockup-dark.svg"),
                           os.path.join(tmp, "lock-dark.png"), 2000, 480)
    lock_light = render_svg(os.path.join(OUT, "auradsp-lockup-light.svg"),
                            os.path.join(tmp, "lock-light.png"), 2000, 480)

    app = Image.open(app_master).convert("RGBA")
    app_small = Image.open(app_small_master).convert("RGBA")
    tray = Image.open(tray_master).convert("RGBA")
    mark = Image.open(mark_master).convert("RGBA")

    app_sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256, 512, 1024]
    tray_sizes = [16, 20, 24, 32, 40, 48, 64, 128, 256]
    for s in app_sizes:
        src = app_small if s <= 24 else app
        write_png(src, os.path.join(ICONS, f"auradsp-app-{s}.png"), s)
    for s in tray_sizes:
        write_png(tray, os.path.join(ICONS, f"auradsp-tray-{s}.png"), s)
    write_png(mark, os.path.join(ICONS, "auradsp-mark-512.png"), 512)
    write_png(mark, os.path.join(ICONS, "auradsp-mark-1024.png"), 1024)

    # tray dark/light PNGs for the light-taskbar preview
    tray_dark_master = render_svg(os.path.join(OUT, "auradsp-tray-dark.svg"),
                                  os.path.join(tmp, "tray-dark.png"), 1024, 1024)
    tray_dark = Image.open(tray_dark_master).convert("RGBA")
    for s in (16, 20, 24, 32, 40):
        write_png(tray_dark, os.path.join(ICONS, f"auradsp-tray-dark-{s}.png"), s)

    def ico_images(base, sizes):
        return [(s, resize_rgba(base, s, s)) for s in sizes]

    write_ico(
        [(16, resize_rgba(app_small, 16, 16)),
         (20, resize_rgba(app_small, 20, 20)),
         (24, resize_rgba(app_small, 24, 24)),
         (32, resize_rgba(app, 32, 32)),
         (40, resize_rgba(app, 40, 40)),
         (48, resize_rgba(app, 48, 48)),
         (64, resize_rgba(app, 64, 64)),
         (128, resize_rgba(app, 128, 128)),
         (256, resize_rgba(app, 256, 256))],
        os.path.join(ICONS, "auradsp.ico"))
    write_ico(ico_images(tray, [16, 20, 24, 32, 40, 48, 64]),
              os.path.join(ICONS, "auradsp-tray.ico"))

    # lockup PNG for docs (trimmed, transparent)
    for name, src in (("dark", lock_dark), ("light", lock_light)):
        im = trim(Image.open(src).convert("RGBA"), 24)
        im.save(os.path.join(ICONS, f"auradsp-lockup-{name}.png"), "PNG", optimize=True)

    write(os.path.join(OUT, "final.html"), build_preview())
    print("assets:", OUT)
    print("icons:", ICONS)


if __name__ == "__main__":
    main()
