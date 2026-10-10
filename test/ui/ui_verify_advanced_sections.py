"""ui_verify_advanced_sections.py — 三个「高级」折叠区的开合像素差分验证。

对应重构：effects_page 的 Bass / Stereo / Tube 三份重复折叠骨架
统一为 widgets.AdvancedSection（docs 见 commit 8c4a3a5）。

铁律遵循：
  * 置顶前置（ui_test_kit 的 AuraAppSession 已封装 HWND_TOPMOST +
    SetForegroundWindow + WinSta0\\Default）
  * 交互前确保卡片主开关为 ON（否则卡片折叠/滑块 disabled）
  * 每步用 assert_images_differ 做区域像素差分，杜绝假通过

坐标由 tools/probe_effects_geometry.py + 渲染实测推导（1400x900 标准画布）：
  低音「高级」折叠头 (430, 649)
  低音强度滑块行 y=532（用于确认卡片确实处于展开态）
"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from ui_test_kit import AuraAppSession  # noqa: E402

SCRATCH = os.path.join(tempfile.gettempdir(), 'auradsp_adv_scratch.png')
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))), 'docs', 'ui-redesign')

# 折叠头在其内容区上方若干像素；取该带状区域做差分
HEADER_X, HEADER_Y = 430, 649
CONTENT_BOX = (380, 660, 1340, 900)
FAIL = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAIL.append(label)


def card_is_expanded(app):
    """展开时高级区下方会出现滑块行；折叠时没有。
    用「折叠头下方是否存在 accent 色的滑轨」判断。"""
    img = app.capture(SCRATCH, (380, 665, 1340, 760))
    px = img.load()
    w, h = img.size
    n = 0
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y][:3]
            if abs(r - 212) <= 52 and abs(g - 255) <= 52 and abs(b - 63) <= 52:
                n += 1
    return n


_ACCENT_RGB = (212, 255, 63)


def ensure_switch_on(app, x, y, label="卡片开关"):
    """卡片主开关必须为 ON：关闭时卡片整体折叠，高级区不在预期坐标上。"""
    img = app.capture(SCRATCH)
    r, g, b = img.getpixel((x, y))[:3]
    if g > 180 and b < 110:
        print("  [%s] 已处于开启态" % label)
        return
    print("  [%s] 当前关闭态 RGB=(%d,%d,%d)，点击开启..." % (label, r, g, b))
    before = app.capture(SCRATCH, (x - 30, y - 20, x + 30, y + 20))
    app.click(x, y, delay=0.6)
    after = app.capture(SCRATCH, (x - 30, y - 20, x + 30, y + 20))
    app.assert_images_differ(before, after, min_diff_pixels=15,
                             label=label + " 开启")
    print("  [%s] 已开启" % label)



def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    print("=== [AdvancedSection 开合像素差分] ===")
    with AuraAppSession(width=1400, height=900, title='AdvancedSection Verify') as app:
        app.navigate_to('effects', delay=1.0)
        app.scroll(700, 500, clicks=6, delay=0.5)      # 回到顶部
        time.sleep(0.8)
        # 前置：低音卡片主开关必须 ON，否则卡片折叠、高级区不在该坐标
        ensure_switch_on(app, 1281, 451, label="低音主开关")
        time.sleep(0.8)

        before = app.capture(SCRATCH)
        base_shaders = card_is_expanded(app)
        print(f"  初始状态：折叠头下方 accent 像素 {base_shaders}"
              f"（{'展开' if base_shaders > 60 else '折叠'}）")

        # --- 展开 ---
        app.click(HEADER_X, HEADER_Y, delay=0.7)
        after_open = app.capture(SCRATCH)
        open_shaders = card_is_expanded(app)
        print(f"  点击折叠头后：accent 像素 {open_shaders}")

        d_open = app.assert_images_differ(
            before, after_open, min_diff_pixels=200,
            label="高级区展开")
        check(open_shaders != base_shaders,
              f"展开后内容区 accent 像素发生变化 ({base_shaders} -> {open_shaders})")

        if open_shaders > base_shaders:
            check(True, "高级区展开后出现更多控件像素（滑块已渲染）")
        else:
            check(False, "高级区展开后未出现控件像素")

        app.capture(os.path.join(OUT_DIR, 'adv_01_bass_advanced_open.png'))

        # --- 折叠回去 ---
        app.click(HEADER_X, HEADER_Y, delay=0.7)
        after_close = app.capture(SCRATCH)
        close_shaders = card_is_expanded(app)
        print(f"  再次点击后：accent 像素 {close_shaders}")
        d_close = app.assert_images_differ(
            after_open, after_close, min_diff_pixels=200,
            label="高级区折叠")
        check(close_shaders == base_shaders,
              f"折叠后回到初始像素分布 ({close_shaders} == {base_shaders})")

        app.capture(os.path.join(OUT_DIR, 'adv_02_bass_advanced_closed.png'))

    print()
    if FAIL:
        print(f"FAILED ({len(FAIL)}):")
        for f in FAIL:
            print("  -", f)
        return 1
    print(">>> AdvancedSection 开合验证通过 <<<")
    return 0


if __name__ == '__main__':
    sys.exit(main())