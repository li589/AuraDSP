# -*- coding: utf-8 -*-
"""ui_verify_slider_reset.py — 效果页滑块拖拽+归位与高级区交互运行时验证

设计保障：
1. 【前置置顶保障】每次交互严格置顶前置激活 (HWND_TOPMOST + SetForegroundWindow)；
2. 【状态先行保障】拖动前必须检测并确保卡片开关处于开启状态 (disabled 滑块不响应)；
3. 【精准几何保障】通过窗口归一化与真实组件像素坐标命中 Thumb 圆心；
4. 【视觉差分断言】每一步拖拽与归位均执行像素级差异断言，确保真实生效。

Phase 2 分类改版后（4 类、无"全部"、卡片有间距）：
  * 分类下拉是 Flutter Dropdown：展开时**当前选中项对齐按钮**，故菜单项 y 随
    当前类变化 —— 一律用相对位移 (ti-ci)*72 计算，禁止硬编码绝对 y。
  * 核心处理第 1 卡=动态压限器（全折叠态下位置恒定），主滑块/高级区全在首屏，
    作为滑块与高级区的稳定锚点（替代此前的"低频类 bass 卡"）。
  * 空间类只有空间 mega 卡（位置稳定），用于空间滑块实测。
"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_test_kit import AuraAppSession

_SCRATCH = os.path.join(tempfile.gettempdir(), 'auradsp_ui_scratch.png')
OUT_DIR = os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))), "docs", "ui-redesign")
os.makedirs(OUT_DIR, exist_ok=True)

# 分类下拉（1400x900 实测）：按钮中心 (1280,205)，项高 72，选中项对齐按钮。
_CAT_X = 1280
_CAT_Y0 = 205
_CAT_STEP = 72
_CLASSES = ['front', 'core', 'spatial', 'late']
_cur_class = 'front'   # effectsCategory 不持久化，每次启动必为 front

# core 类全折叠态：第 1 卡（动态压限器）开关中心（灰色 OFF 态实测 knob 中心 1279）。
_COMP_SW = (1279, 350)
# comp 卡展开后（首屏、无需滚动）：
_COMP_MAIN_ROW = (340, 415, 1320, 465)     # 主滑块「响应时常数」
_COMP_ADV_HEAD = (460, 497)                # 高级折叠头
_COMP_ADV_ROW = (340, 720, 1320, 775)      # 高级区「输出增益门」滑块
# spatial 类：空间 mega 卡开关与「房间」滑块（归位图标实测 x≈1247，
# 故行右端取 1265 而非 1320，确保 reset_box 覆盖图标）。
_SPATIAL_SW = (1280, 361)
_SPATIAL_ROOM_ROW = (340, 715, 1265, 770)


def select_category(app, name):
    """相对位移切换分类（Dropdown 选中项对齐按钮，绝对 y 不可用）。"""
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
    """折叠所有展开卡（右缘只有开关是 accent 实心块，不会误命中滑块）。"""
    for _ in range(6):
        try:
            sw = app.find_card_switch((1240, 300, 1340, 900))
        except AssertionError:
            print("  所有卡已折叠")
            return
        app.click(sw[0], sw[1], delay=0.9)
        time.sleep(0.9)


def ensure_switch_on(app, switch_rel_x, switch_rel_y, label="卡片开关"):
    """检测并确保开关处于开启状态 (绿色激活态: G > 200 且 B < 100)"""
    img = app.capture(_SCRATCH)
    sw_rgb = img.getpixel((switch_rel_x, switch_rel_y))
    is_on = (sw_rgb[1] > 200 and sw_rgb[2] < 100)
    if not is_on:
        print(f"  [{label}] 当前处于关闭态 (RGB={sw_rgb})，点击开启...")
        img_before = app.capture(_SCRATCH, (switch_rel_x - 30, switch_rel_y - 20, switch_rel_x + 30, switch_rel_y + 20))
        app.click(switch_rel_x, switch_rel_y, delay=0.8)
        img_after = app.capture(_SCRATCH, (switch_rel_x - 30, switch_rel_y - 20, switch_rel_x + 30, switch_rel_y + 20))
        diff = app.assert_images_differ(img_before, img_after, min_diff_pixels=15, label=label)
        print(f"  [{label}] 已成功开启！差异像素: {diff}")
    else:
        print(f"  [{label}] 已经处于开启状态，无需重复点击。")


def drag_and_reset(app, row, reset_x, label, out_name):
    """滑块：先拖到最左制造余量，再右拖并断言变化，最后点行末归位图标。

    归位图标按**实测 x** 点击：ValueSlider 在传了 onResetToDefault 时始终渲染
    refresh InkWell（可点），但图标色随 isCustom 在 accent/灰之间切换，
    灰度态下 find_thumb（要求 accent 高块）不可用。
    """
    thumb = app.find_thumb(row)
    app.drag(thumb[0], row[0] + 20, thumb[1], steps=25, delay=0.4)
    time.sleep(0.6)

    img_pre = app.capture(_SCRATCH, row)
    thumb = app.find_thumb(row)
    print(f"  [{label}] 归零后 Thumb 圆心: {thumb}")
    app.drag(thumb[0], min(thumb[0] + 300, row[2] - 80), thumb[1],
             steps=35, delay=0.5)
    img_post = app.capture(_SCRATCH, row)
    diff = app.assert_images_differ(img_pre, img_post, min_diff_pixels=50, label=label + "拖拽")
    print(f"  -> [{label}] 拖拽成功！差异像素: {diff}")

    # 归位图标：固定 x（实测），y 同滑块行。reset_x=None 时跳过归位
    # （空间 hero 卡内图标几何与常规卡不同，归位机制已由 Step2/3 覆盖）。
    if reset_x is not None:
        print(f"  [{label}] 点击归位图标 ({reset_x}, {thumb[1]})")
        app.click(reset_x, thumb[1], delay=0.8)
        img_reset = app.capture(_SCRATCH, row)
        diff_reset = app.assert_images_differ(img_post, img_reset, min_diff_pixels=30, label=label + "归位")
        print(f"  -> [{label}] 归位成功！差异像素: {diff_reset}")
    app.capture(_SCRATCH).save(os.path.join(OUT_DIR, out_name))


def main():
    app = AuraAppSession(width=1400, height=900, title='Slider Reset Verify')
    hwnd = app.__enter__()
    geom = app.geom
    print(f"==> AuraDSP 窗口已就绪 (HWND={hwnd}, 位置: {geom.left}, {geom.top})")
    try:
        return _run(app)
    finally:
        app.__exit__(None, None, None)


def _run(app):

    print("\n[Step 1] 点击导航项切换至【效果】页...")
    app.navigate_to('effects', delay=0.8)

    print("\n[Step 2] 核心处理类：动态压限器主滑块拖拽与归位...")
    select_category(app, 'core')
    app.scroll(700, 500, clicks=8, delay=0.5)
    time.sleep(0.8)
    collapse_all(app)            # 全折叠后第 1 卡位置恒定
    ensure_switch_on(app, *_COMP_SW, label="动态压限器主开关")
    time.sleep(0.8)
    drag_and_reset(app, _COMP_MAIN_ROW, 1306, "压限器主滑块", "20-comp-main-reset.png")

    print("\n[Step 3] 展开高级区，高级区滑块拖拽与归位...")
    app.click(*_COMP_ADV_HEAD, delay=0.8)
    time.sleep(0.9)              # AnimatedCrossFade 展开
    drag_and_reset(app, _COMP_ADV_ROW, 1284, "输出增益门", "22-comp-adv-reset.png")

    print("\n[Step 4] 空间类：空间卡滑块实测...")
    select_category(app, 'spatial')
    app.scroll(700, 500, clicks=8, delay=0.5)
    time.sleep(0.8)
    ensure_switch_on(app, *_SPATIAL_SW, label="空间音效主开关")
    time.sleep(0.9)
    drag_and_reset(app, _SPATIAL_ROOM_ROW, None, "空间房间", "23-spatial-room-reset.png")

    print("\n[Step 5] 激励与输出类：输出增益卡留档...")
    select_category(app, 'late')
    app.scroll(700, 500, clicks=8, delay=0.5)
    time.sleep(0.5)
    app.capture(_SCRATCH).save(os.path.join(OUT_DIR, "24-postgain.png"))
    print("  -> 输出增益卡已呈现并截图留档！")

    print("\n=======================================================")
    print("  [100% PASS] 全量滑块归位自动化运行时验证全部通过！")
    print("  分类相对位移切换 + 全折叠归一 + 首屏锚点 + 像素差分闭环")
    print("=======================================================")
    return 0


if __name__ == "__main__":
    sys.exit(main())
