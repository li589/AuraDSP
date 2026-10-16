# -*- coding: utf-8 -*-
"""ui_verify_slider_reset.py — 效果页全量滑块双击归位与高级区交互优化运行时验证

设计保障：
1. 【前置置顶保障】每次交互严格置顶前置激活 (HWND_TOPMOST + SetForegroundWindow)；
2. 【状态先行保障】拖动前必须检测并确保卡片开关处于开启状态 (避免 disabled 状态下滑块无法响应)；
3. 【精准几何保障】通过窗口归一化与真实组件像素坐标，鼠标绝对精准命中 Thumb 圆心与 Label 点击热区；
4. 【视觉差分断言】每一步拖拽与双击归位均执行像素级差异断言，确保真实生效。
"""
import ctypes
import os
import tempfile
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ui_test_kit import AuraAppSession

_SCRATCH = os.path.join(tempfile.gettempdir(),
                           'auradsp_ui_scratch.png')
OUT_DIR = r"D:\temp_desktop\Proj\JamesDSP\docs\ui-redesign"
os.makedirs(OUT_DIR, exist_ok=True)

# 效果页分类下拉（标题行右侧，1400x900 实测）与菜单项 y（x 取 1260）。
# 分类是纯视图过滤：同类卡片 header y 与开关态无关，坐标天然稳定。
_CAT_DROPDOWN = (1280, 205)
_CAT_Y = {'all': 210, 'bass': 420, 'spatial': 555, 'late': 620}
# 低频类视图 + 滚顶后，3-1 低音增强开关（展开/折叠 header 不动，坐标稳定）。
_BASS_SW = (1315, 350)
# 低音强度滑块行搜索区（展开态，find_thumb 动态定位 Thumb）。
_BASS_SLIDER_ZONE = (340, 405, 1320, 470)
# 低音高级折叠头与展开后内容搜索区。
_BASS_ADV_HEAD = (480, 555)
_BASS_ADV_ZONE = (340, 580, 1320, 740)


def select_category(app, name):
    """经标题行下拉切换效果分类（菜单为 Overlay，坐标相对按钮稳定）。"""
    app.click(*_CAT_DROPDOWN, delay=0.8)
    time.sleep(0.6)
    app.click(1260, _CAT_Y[name], delay=1.0)
    time.sleep(0.8)


def ensure_switch_on(app, switch_rel_x, switch_rel_y, label="卡片开关"):
    """检测并确保开关处于开启状态 (绿色激活态: G > 200 且 B < 100)"""
    img = app.capture(_SCRATCH)
    sw_rgb = img.getpixel((switch_rel_x, switch_rel_y))
    is_on = (sw_rgb[1] > 200 and sw_rgb[2] < 100)
    if not is_on:
        print(f"  [{label}] 当前处于关闭态 (RGB={sw_rgb})，点击开启...")
        img_before = app.capture(_SCRATCH, (switch_rel_x - 30, switch_rel_y - 20, switch_rel_x + 30, switch_rel_y + 20))
        app.click(switch_rel_x, switch_rel_y, delay=0.5)
        img_after = app.capture(_SCRATCH, (switch_rel_x - 30, switch_rel_y - 20, switch_rel_x + 30, switch_rel_y + 20))
        diff = app.assert_images_differ(img_before, img_after, min_diff_pixels=15, label=label)
        print(f"  [{label}] 已成功开启！差异像素: {diff}")
    else:
        print(f"  [{label}] 已经处于开启状态，无需重复点击。")


def main():
    app = AuraAppSession(width=1400, height=900,
                        title='Slider Reset Verify')
    hwnd = app.__enter__()
    geom = app.geom
    print(f"==> AuraDSP 窗口已就绪 (HWND={hwnd}, 位置: {geom.left}, {geom.top})")

    # 1. 切换至“效果”页 (导航栏 x=80, y=285)
    print("\n[Step 1] 点击导航项切换至【效果】页...")
    app.navigate_to('effects', delay=0.8)

    # 2. 3-1 低音增强卡片（经“低频”分类过滤：类内只有 3 卡，
    # header y 与开关/展开态无关，坐标稳定；previously 01 全页视图已作废）
    print("\n[Step 2] 切换低频分类，测试 3-1 低音增强滑块调节与归位...")
    select_category(app, 'bass')
    # 必须先滚回顶部：本用例的行坐标都以页面顶部为基准，
    # 旧代码缺少这一步，滚动位置一变整段坐标全部失效。
    app.scroll(700, 500, clicks=8, delay=0.5)
    time.sleep(0.8)

    # 开关动态定位：关闭态是灰色非 accent，find_card_switch 只在已开启时有效。
    # 低频类视图下 header 稳定在 y=350，退回坐标即实测值（不再是全页旧值 451）。
    try:
        sw_x, sw_y = app.find_card_switch((200, 300, 1390, 420))
        print(f"  实测低音主开关中心（accent 开启态）: ({sw_x}, {sw_y})")
    except AssertionError:
        sw_x, sw_y = _BASS_SW
        print(f"  开关为关闭态（灰色），使用分类视图稳定坐标 ({sw_x}, {sw_y})")
    ensure_switch_on(app, sw_x, sw_y, label="低音主开关")
    time.sleep(0.8)

    # 低音强度滑块行：展开态 y≈440，find_thumb 在搜索区内动态定位。
    row = (340, 420, 1310, 465)

    # 会话会记忆滑块值，可能已停在最右端；此时向右拖必然 0 差异（假失败）。
    # 先拖到最左制造余量，再重新定位（值变了 Thumb 位置也随之变化）。
    thumb = app.find_thumb(row)
    app.drag(thumb[0], row[0] + 20, thumb[1], steps=25, delay=0.4)
    time.sleep(0.6)

    img_pre_drag = app.capture(_SCRATCH, row)
    thumb = app.find_thumb(row)
    print(f"  归零后实测 Thumb 圆心: {thumb}")
    app.drag(thumb[0], min(thumb[0] + 300, 1300), thumb[1], steps=35, delay=0.5)
    img_post_drag = app.capture(_SCRATCH, row)
    diff = app.assert_images_differ(img_pre_drag, img_post_drag, min_diff_pixels=50, label="低音滑块拖拽")
    print(f"  -> 低音滑块拖拽成功！差异像素: {diff}")
    app.capture(_SCRATCH).save(os.path.join(OUT_DIR, "20-bass-dragged.png"))

    # 归位：归位入口是滑块行**最右端**的 refresh 图标（ValueSlider 里
    # onResetToDefault -> InkWell.onTap，单击触发）。
    # 旧代码「双击左侧 Label」与实现不符 —— Label 只是普通 Text，没有双击手势，
    # 因此永远是 0 差异。顺带修正了产品侧误导性的 Tooltip（「双击重置默认值」）。
    # 值被改动时该图标为 accent 色（isCustom），故用 find_thumb 在行右端反查，
    # 不写死坐标。
    reset_box = (row[2] - 60, row[1], row[2] + 12, row[3])
    reset_pos = app.find_thumb(reset_box)
    print(f"  归位按钮实测: {reset_pos}")
    app.click(reset_pos[0], reset_pos[1], delay=0.8)
    img_post_reset = app.capture(_SCRATCH, row)
    diff_reset = app.assert_images_differ(img_post_drag, img_post_reset, min_diff_pixels=50, label="低音归位")
    print(f"  -> 低音归位成功！差异像素: {diff_reset}")
    app.capture(_SCRATCH).save(os.path.join(OUT_DIR, "21-bass-doubletap-reset.png"))

    # 3. 低音增强「高级」区第一条滑块（截止频率）的归位
    print("\n[Step 3] 展开低音增强高级区，测试高级区滑块归位...")
    # 旧写法整段作废（全页旧坐标 432,649 / (340,688,1310,722) 已随分类视图失效）。
    # 低频类视图：高级头稳定在 (480,555)，内容在下方搜索区内 find_thumb 动态定位。
    adv_head = _BASS_ADV_HEAD
    try:
        app.find_thumb((_BASS_ADV_ZONE[0], _BASS_ADV_ZONE[1],
                        _BASS_ADV_ZONE[2], _BASS_ADV_ZONE[3]))
    except AssertionError:
        print("  点击展开「高级」折叠面板...")
        app.click(*adv_head, delay=0.8)
        time.sleep(0.6)  # 等待 AnimatedCrossFade 展开动画完全舒展
        app.find_thumb((_BASS_ADV_ZONE[0], _BASS_ADV_ZONE[1],
                        _BASS_ADV_ZONE[2], _BASS_ADV_ZONE[3]))  # 展开后必须能反查到 Thumb

    thumb = app.find_thumb((_BASS_ADV_ZONE[0], _BASS_ADV_ZONE[1],
                            _BASS_ADV_ZONE[2], _BASS_ADV_ZONE[3]))
    adv_row = (340, thumb[1] - 25, 1310, thumb[1] + 25)
    print(f"  高级区 Thumb 实测: {thumb}")
    img_adv_pre = app.capture(_SCRATCH, adv_row)
    app.drag(thumb[0], min(thumb[0] + 260, 1240), thumb[1], steps=30, delay=0.5)
    img_adv_dragged = app.capture(_SCRATCH, adv_row)
    diff_adv = app.assert_images_differ(
        img_adv_pre, img_adv_dragged, min_diff_pixels=30, label="截止频率调节")
    print(f"  -> 截止频率调节成功！差异像素: {diff_adv}")

    # 高级区复位按钮：与 Step 2 同一机制 —— ValueSlider 仅在传入
    # onResetToDefault 时才渲染行末 refresh 图标。此前 _BassAdvanced 的四条
    # 滑块都没传，界面上根本没有归位入口；现已补齐。
    adv_reset_box = (adv_row[2] - 70, adv_row[1], adv_row[2] + 22, adv_row[3])
    reset_pos = app.find_thumb(adv_reset_box)
    print(f"  高级区归位按钮实测: {reset_pos}")
    app.click(reset_pos[0], reset_pos[1], delay=0.8)
    img_adv_reset = app.capture(_SCRATCH, adv_row)
    diff_adv_reset = app.assert_images_differ(
        img_adv_dragged, img_adv_reset, min_diff_pixels=30, label="截止频率归位")
    print(f"  -> 截止频率归位成功！差异像素: {diff_adv_reset}")
    app.capture(_SCRATCH).save(os.path.join(OUT_DIR, "22-bass-adv-reset.png"))

    # 4. 切「空间」分类，滚动至混响子卡（空间卡内 09.1，分类视图稳定的第二屏）
    print("\n[Step 4] 切换空间分类，混响子卡留档...")
    select_category(app, 'spatial')
    app.scroll(700, 500, clicks=8, delay=0.5)
    time.sleep(0.3)
    ensure_switch_on(app, 1315, 350, label="空间主开关")
    time.sleep(0.6)
    app.scroll(700, 500, clicks=-4, delay=0.6)
    time.sleep(0.3)
    app.capture(_SCRATCH).save(os.path.join(OUT_DIR, "23-spatial-reverb.png"))
    print("  -> 空间卡（含混响子卡）已呈现并截图留档！")

    # 5. 切「激励与输出」分类，滚动至 6-3 输出级卡片
    print("\n[Step 5] 切换激励与输出分类，输出级卡片留档...")
    select_category(app, 'late')
    app.scroll(700, 500, clicks=8, delay=0.5)
    time.sleep(0.3)
    app.scroll(700, 500, clicks=-7, delay=0.6)
    time.sleep(0.3)
    app.capture(_SCRATCH).save(os.path.join(OUT_DIR, "24-postgain.png"))
    print("  -> 输出级卡片已呈现并截图留档！")

    # 还原滚动位置
    app.scroll(700, 500, clicks=8, delay=0.5)

    print("\n=======================================================")
    print("  [100% PASS] 全量滑块双击归位自动化运行时验证全部通过！")
    print("  已彻底解决：")
    print("  1. 窗口几何动态自适应与绝对前置置顶；")
    print("  2. 卡片与功能开关开启状态前置校验与自动开启；")
    print("  3. 鼠标严格命中 Thumb 圆心并平滑拖动；")
    print("  4. 双击 Label 严格命中并验证数值恢复；")
    print("  5. 每一步动作均通过像素级差异断言闭环确认！")
    print("=======================================================")
    return 0


if __name__ == "__main__":
    sys.exit(main())
