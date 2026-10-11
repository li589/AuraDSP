"""probe_shelf_layout.py — 取证：低音卡展开后，低频搁架卡片与高级折叠头的实际位置。

背景：ui_verify_slider_reset 的 Step 3 用硬编码坐标找低频搁架的滑块，
但低音卡展开后整个页面下移，那些坐标已失效。此脚本打印各行的 accent
连通块，供识别「卡片主开关」与「高级区折叠箭头」两类目标。
"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__))), 'test', 'ui'))

from ui_test_kit import AuraAppSession  # noqa: E402

SCRATCH = os.path.join(tempfile.gettempdir(), 'auradsp_shelf_probe.png')
ACCENT = (212, 255, 63)
TOL = 52
BOX = (330, 120, 1390, 900)


def near(px):
    return (abs(px[0] - ACCENT[0]) <= TOL and abs(px[1] - ACCENT[1]) <= TOL
            and abs(px[2] - ACCENT[2]) <= TOL)


def blobs(app, tag):
    img = app.capture(SCRATCH, BOX)
    px = img.load()
    w, h = img.size
    seen = [[False] * w for _ in range(h)]
    out = []
    for y0 in range(h):
        for x0 in range(w):
            if seen[y0][x0] or not near(px[x0, y0]):
                continue
            stack = [(x0, y0)]
            seen[y0][x0] = True
            pts = []
            while stack:
                x, y = stack.pop()
                pts.append((x, y))
                for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    nx, ny = x + dx, y + dy
                    if 0 <= nx < w and 0 <= ny < h and not seen[ny][nx] \
                            and near(px[nx, ny]):
                        seen[ny][nx] = True
                        stack.append((nx, ny))
            if len(pts) < 30:
                continue
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            bw = max(xs) - min(xs) + 1
            bh = max(ys) - min(ys) + 1
            out.append((int(sum(ys) / len(ys)) + BOX[1],
                        int(sum(xs) / len(xs)) + BOX[0], bw, bh, len(pts)))
    out.sort()
    print('\n--- %s : accent 连通块 (cy, cx, w, h, area) ---' % tag)
    for cy, cx, bw, bh, a in out:
        kind = 'SWITCH(大)' if bh >= 14 and a >= 90 else (
            'Thumb候选' if 7 <= bh <= 14 and a < 90 else '小图标')
        print('  cy=%-5d cx=%-5d %2dx%-2d area=%-5d %s' % (cy, cx, bw, bh, a, kind))


def main():
    with AuraAppSession(width=1400, height=900, title='Shelf Probe') as app:
        app.navigate_to('effects', delay=1.0)
        app.scroll(700, 500, clicks=8, delay=0.5)
        time.sleep(0.8)

        img = app.capture(SCRATCH)
        r, g, b = img.getpixel((1281, 451))[:3]
        if not (g > 180 and b < 110):
            app.click(1281, 451, delay=0.7)
            time.sleep(0.9)
        blobs(app, '低音主开关 ON（页面顶部态）')

        print('\n向下滚动 6 格后：')
        app.scroll(700, 500, clicks=-6, delay=0.5)
        time.sleep(0.9)
        blobs(app, '下滚后')
    return 0


if __name__ == '__main__':
    sys.exit(main())