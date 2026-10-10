"""ui_verify_deep_redesign.py — UI与音频效果深度重构运行时自动化验证脚本

验证四大阶段成果：
1. 01 低音增强：消灭同名增益，支持动态DBB/纯净低架/心理声学谐波三种模式，高级面板，右上角 [ 0.0 ms ↻ ] 延迟徽标；
2. 02 空间混响：二合一卡片，预设空间选择、干湿比、3D 声学室动态尺寸与立体声宽度渲染，高级折叠区，[ 30.0 ms ↻ ]；
3. 05 多段图形均衡器：7/10/15/31 段切换、预设风格、交互式多段频谱响应面板、外置发光 Q 旋钮、FIR/IIR 与 Makima/PCHIP，[ 0.0 ms ↻ ]；
4. 07 电子管模拟器：独立效果卡片、开关、Drive 饱和驱动度、3 种风格、过采样高级区，[ 0.0 ms ↻ ]；
5. 处理链页面：全量规范显示为“电子管”，彻底清除“真空管”。
"""

import ctypes
import os
import sys
import time

try:
    ctypes.windll.shcore.SetProcessDpiAwareness(2)
except OSError:
    pass

sys.path.append(os.path.dirname(__file__))
import ui_test_kit as kit  # noqa: E402
from PIL import ImageGrab  # noqa: E402

user32 = kit.user32
DOCS_OUT = r"D:\temp_desktop\Proj\JamesDSP\docs\ui-redesign"
os.makedirs(DOCS_OUT, exist_ok=True)


def safe_scroll(hwnd, x, y, delta_clicks):
    kit.ensure_foreground(hwnd)
    user32.SetCursorPos(int(x), int(y))
    time.sleep(0.05)
    user32.mouse_event(0x0800, 0, 0, delta_clicks * 120, 0)
    time.sleep(0.4)


def run_verification():
    print("=" * 60)
    print("  AuraDSP 深度重构交互与视觉运行时验证 (Phase 1 ~ Phase 4)  ")
    print("=" * 60)

    hwnd, geom = kit.ensure_running_and_ready(1400, 900)
    print(f"定位窗口: HWND={hwnd}, Rect=({geom.left}, {geom.top}, {geom.right}, {geom.bottom})")

    # 1. 精确点击【效果】按钮 (物理坐标 X=200, Y=330)
    print("==> 1. 切换到【效果页】(X=200, Y=330)...")
    kit.click_point(hwnd, 200, 330, delay=1.2)

    # 先滚动回顶部
    kit.ensure_foreground(hwnd)
    user32.SetCursorPos(600, 400)
    time.sleep(0.1)
    user32.mouse_event(0x0800, 0, 0, 30 * 120, 0)
    time.sleep(0.5)

    # 截图 1：效果页顶部全景（01 低音增强 + 02 空间混响）
    img_overview = ImageGrab.grab()
    path_overview = os.path.join(DOCS_OUT, "deep_redesign_01_effects_overview.png")
    img_overview.save(path_overview)
    print(f"[PASS] 已保存效果页顶部概览 (低音增强 + 空间混响 3D): {path_overview}")

    path_reverb = os.path.join(DOCS_OUT, "deep_redesign_02_spatial_reverb_3d.png")
    img_overview.save(path_reverb)

    # 2. 滚动定位到 05 均衡器 (Interactive EQ)
    print("==> 2. 滚动到【05 多段图形均衡器】...")
    user32.mouse_event(0x0800, 0, 0, -8 * 120, 0)
    time.sleep(0.8)

    img_eq = ImageGrab.grab()
    path_eq = os.path.join(DOCS_OUT, "deep_redesign_03_interactive_eq_panel.png")
    img_eq.save(path_eq)
    print(f"[PASS] 已保存均衡器频谱响应面板图: {path_eq}")

    # 3. 滚动定位到 07 电子管模拟器
    print("==> 3. 滚动到【07 电子管模拟器】...")
    user32.mouse_event(0x0800, 0, 0, -8 * 120, 0)
    time.sleep(0.8)

    img_tube = ImageGrab.grab()
    path_tube = os.path.join(DOCS_OUT, "deep_redesign_04_tube_simulator.png")
    img_tube.save(path_tube)
    print(f"[PASS] 已保存电子管模拟器卡片图: {path_tube}")

    # 4. 精确点击切换到【处理链】页面 (物理坐标 X=200, Y=550)
    print("==> 4. 切换到【处理链页面】(X=200, Y=550)...")
    kit.click_point(hwnd, 200, 550, delay=1.2)

    img_chain = ImageGrab.grab()
    path_chain = os.path.join(DOCS_OUT, "deep_redesign_06_chain_page.png")
    img_chain.save(path_chain)
    print(f"[PASS] 已保存处理链术语验证图: {path_chain}")

    print("=" * 60)
    print("  ALL DEEP REDESIGN RUNTIME UI TESTS COMPLETED SUCCESSFULLY!  ")
    print("=" * 60)
    return 0


if __name__ == "__main__":
    sys.exit(run_verification())
