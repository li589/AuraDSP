"""probe_controls.py — 鼠标慢速巡检 + 命中控件记录。

用途：UI 测试里最耗时的排查是「点了没反应」。硬编码坐标失效时，
脚本不会报错，只是点击落在空白处，断言拿到 0 像素差异。
本工具用像素事实回答「这个位置到底是什么」：

  * 慢速移动：在两点之间分多步移动并停顿，让 Flutter 的 hover 态有机会生效，
    否则读到的颜色只是静态态；
  * 逐点记录：坐标、RGB、是否 accent、是否卡片面板、亮度分布；
  * 可选点击：点击前后取小区域差分，差分大的位置即**可交互控件**。

示例：
  python tools/probe_controls.py --region 330,120,1390,900 --step 16
  python tools/probe_controls.py --region 330,560,1390,760 --step 10 --click
  python tools/probe_controls.py --region 330,120,1390,900 --step 8 --click --out controls.csv
"""
import argparse
import csv
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), 'test', 'ui'))

import ui_test_kit as K  # noqa: E402
from PIL import ImageChops  # noqa: E402

SCRATCH = os.path.join(os.environ.get('TEMP', '.'), 'auradsp_probe_controls.png')
ACCENT = (212, 255, 63)
TOL = 52


def near(px, ref=ACCENT, tol=TOL):
    return (abs(px[0] - ref[0]) <= tol and abs(px[1] - ref[1]) <= tol
            and abs(px[2] - ref[2]) <= tol)


def slow_move(app, x0, y0, x1, y1, steps=6, step_delay=0.03):
    """从 (x0,y0) 慢速移到 (x1,y1)（窗口相对坐标）。

    慢速是必要的：一步跳过去的话 Flutter 的 hover 态来不及生效，
    读到的只是静态颜色，会把「鼠标悬停才出现的可交互区域」判成空白。"""
    app.geom.refresh()
    lx, ly = app.geom.left, app.geom.top
    K.ensure_foreground(app.hwnd)
    K.user32.SetCursorPos(lx + x0, ly + y0)
    time.sleep(0.05)
    for i in range(1, steps + 1):
        t = i / steps
        K.user32.SetCursorPos(lx + int(x0 + (x1 - x0) * t),
                              ly + int(y0 + (y1 - y0) * t))
        time.sleep(step_delay)
    time.sleep(0.10)


def classify(px):
    r, g, b = px[:3]
    lum = (r + g + b) / 3.0
    if near(px):
        return 'accent'
    if lum > 170:
        return 'light'
    if lum < 40:
        return 'dark'
    return 'mid'


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--region', default='330,120,1390,900',
                    help='x0,y0,x1,y1（窗口相对坐标）')
    ap.add_argument('--step', type=int, default=16, help='网格步长 px')
    ap.add_argument('--click', action='store_true', help='逐点点击并测量差分')
    ap.add_argument('--click-delay', type=float, default=0.25)
    ap.add_argument('--out', default='', help='导出 CSV 路径')
    ap.add_argument('--title', default='Control Probe')
    args = ap.parse_args()

    x0, y0, x1, y1 = [int(v) for v in args.region.split(',')]

    rows = []
    with K.AuraAppSession(width=1400, height=900, title=args.title) as app:
        app.navigate_to('effects', delay=1.0)
        # 正数 = 向上滚：先回到顶部，保证坐标基准一致
        app.scroll(700, 500, clicks=12, delay=0.5)
        time.sleep(0.8)

        total = 0
        for y in range(y0, y1, args.step):
            for x in range(x0, x1, args.step):
                total += 1
        print('巡检 %d 个点（步长 %d，%s点击）' % (
            total, args.step, '带' if args.click else '不带'))

        n = 0
        for y in range(y0, y1, args.step):
            for x in range(x0, x1, args.step):
                n += 1
                slow_move(app, x, y, x, y, steps=1)
                img = app.capture(SCRATCH, (x, y, x + 1, y + 1))
                px = img.load()[0, 0]
                kind = classify(px)
                diff = -1
                if args.click:
                    before = app.capture(SCRATCH, (x - 6, y - 6, x + 6, y + 6))
                    app.click(x, y, delay=args.click_delay)
                    after = app.capture(SCRATCH, (x - 6, y - 6, x + 6, y + 6))
                    d = ImageChops.difference(before, after).convert('L')
                    diff = sum(1 for p in d.getdata() if p > 15)
                rows.append((x, y, px[0], px[1], px[2], kind, diff))
                if diff > 0:
                    print('  可交互: (%4d,%4d) rgb=%s kind=%s diff=%d'
                          % (x, y, tuple(px[:3]), kind, diff))
                elif n % 25 == 0:
                    print('  ... %d/%d' % (n, total))

    acc = [r for r in rows if r[5] == 'accent']
    inter = [r for r in rows if r[6] > 0]
    print('\n--- 汇总 ---')
    print('采样点 %d，accent 色点 %d，可交互点 %d' % (len(rows), len(acc), len(inter)))

    if args.out:
        with open(args.out, 'w', newline='', encoding='utf-8') as f:
            w = csv.writer(f)
            w.writerow(['x', 'y', 'r', 'g', 'b', 'kind', 'click_diff'])
            w.writerows(rows)
        print('CSV 已导出: %s' % args.out)
    return 0


if __name__ == '__main__':
    sys.exit(main())