"""ui_verify_advanced_sections.py — 「高级」折叠区开合的像素差分验证。

Phase 2 分类改版后（4 类、无"全部"、卡片间距），锚点改为
**核心处理类第 1 卡＝动态压限器**（全折叠态位置恒定，高级区全在首屏）：

  高级折叠头 (460, 497)；高级内容带 x<1240（排除右缘 accent 开关列）。

铁律遵循：
  * 置顶前置（ui_test_kit 的 AuraAppSession 已封装 HWND_TOPMOST + SetForegroundWindow）
  * 交互前确保卡片主开关为 ON（否则卡片折叠/滑块 disabled）
  * 每步用 assert_images_differ 做区域像素差分，杜绝假通过
  * 分类下拉是 Flutter Dropdown（选中项对齐按钮），用相对位移切换
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

# 分类下拉（1400x900 实测）：按钮中心、项高、类序。
_CAT_X, _CAT_Y0, _CAT_STEP = 1280, 205, 72
_CLASSES = ['front', 'core', 'spatial', 'late']
_cur_class = 'front'

# core 类全折叠态：动态压限器（第 1 卡）开关与高级折叠头。
_COMP_SW = (1279, 350)
HEADER_X, HEADER_Y = 460, 497
# 高级内容带：x 收缩到 1240，避开右缘开关列（ON 开关的 accent 会污染计数）。
CONTENT_BOX = (380, 520, 1240, 800)
FAIL = []


def check(cond, label):
    print(('  PASS  ' if cond else '  FAIL  ') + label)
    if not cond:
        FAIL.append(label)


def select_category(app, name):
    global _cur_class
    ti = _CLASSES.index(name)
    ci = _CLASSES.index(_cur_class)
    if ti == ci:
        return
    app.click(_CAT_X, _CAT_Y0, delay=0.8)
    time.sleep(0.7)
    app.click(1265, _CAT_Y0 + (ti - ci) * _CAT_STEP, delay=1.0)
    time.sleep(0.8)
    _cur_class = name


def collapse_all(app):
    for _ in range(6):
        try:
            sw = app.find_card_switch((1240, 300, 1340, 900))
        except AssertionError:
            print("  所有卡已折叠")
            return
        app.click(sw[0], sw[1], delay=0.9)
        time.sleep(0.9)


def card_is_expanded(app):
    """高级区展开时内容带出现 accent 色控件（chip 描边/滑块/开关）。"""
    img = app.capture(SCRATCH, CONTENT_BOX)
    px = img.load()
    w, h = img.size
    n = 0
    for y in range(h):
        for x in range(w):
            r, g, b = px[x, y][:3]
            if abs(r - 212) <= 52 and abs(g - 255) <= 52 and abs(b - 63) <= 52:
                n += 1
    return n


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
        select_category(app, 'core')
        app.scroll(700, 500, clicks=8, delay=0.5)      # 回到顶部
        time.sleep(0.8)
        collapse_all(app)                              # 前卡全折叠 → 第 1 卡位置恒定
        ensure_switch_on(app, *_COMP_SW, label="动态压限器主开关")
        time.sleep(0.9)

        # 高级区默认应折叠（首屏内容带无 accent 控件）
        base_shaders = card_is_expanded(app)
        print("  初始状态：高级内容带 accent 像素 %d（%s）"
              % (base_shaders, '展开' if base_shaders > 60 else '折叠'))
        if base_shaders > 60:
            # 已展开：先点一次收起，归一为折叠基线
            app.click(HEADER_X, HEADER_Y, delay=0.7)
            time.sleep(0.6)
            base_shaders = card_is_expanded(app)
            print("  归一后折叠基线 accent 像素 %d" % base_shaders)

        before = app.capture(SCRATCH)

        # --- 展开 ---
        app.click(HEADER_X, HEADER_Y, delay=0.7)
        time.sleep(0.7)
        after_open = app.capture(SCRATCH)
        open_shaders = card_is_expanded(app)
        print("  点击折叠头后：accent 像素 %d" % open_shaders)

        d_open = app.assert_images_differ(
            before, after_open, min_diff_pixels=200, label="高级区展开")
        check(open_shaders > base_shaders,
              "展开后内容区 accent 像素增加 (%d -> %d)" % (base_shaders, open_shaders))
        check(d_open >= 200, "展开像素差分成立 (%d)" % d_open)

        app.capture(os.path.join(OUT_DIR, 'adv_01_comp_advanced_open.png'))
        time.sleep(0.3)

        # --- 折叠回去 ---
        app.click(HEADER_X, HEADER_Y, delay=0.7)
        time.sleep(0.7)
        after_close = app.capture(SCRATCH)
        close_shaders = card_is_expanded(app)
        print("  再次点击后：accent 像素 %d" % close_shaders)

        app.assert_images_differ(after_open, after_close, min_diff_pixels=200,
                                 label="高级区折叠")
        check(close_shaders == base_shaders,
              "折叠后回到初始像素分布 (%d == %d)" % (close_shaders, base_shaders))
        app.capture(os.path.join(OUT_DIR, 'adv_02_comp_advanced_closed.png'))

    print()
    if FAIL:
        print("FAILED (%d):" % len(FAIL))
        for f in FAIL:
            print("  -", f)
        return 1
    print(">>> AdvancedSection 开合验证通过 <<<")
    return 0


if __name__ == '__main__':
    sys.exit(main())
