"""probe_shelf_layout.py — 取证：低频搁架（位于低音卡「高级」区内）的可定位特征。

背景：ui_verify_slider_reset 的 Step 3 找不到低频搁架滑块。
此前用硬编码坐标，但实测布局会随「卡片开关记忆状态 + 滚动位置」变化，
同一份代码两次运行的坐标可以差 400px。

本脚本不猜坐标，而是先验证一种**像素特征**是否稳定：
  * 高级区折叠头 = cx≈400~460、尺寸约 10~20 x 5~12 的小 accent 块
若该特征稳定，测试即可用它定位折叠头，而不是写死 (430, 649)。
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
            if len(pts) < 25:
                continue
            xs = [p[0] for p in pts]
            ys = [p[1] for p in pts]
            bw = max(xs) - min(xs) + 1
            bh = max(ys) - min(ys) + 1
            out.append((int(sum(ys) / len(ys)) + BOX[1],
                        int(sum(xs) / len(xs)) + BOX[0], bw, bh, len(pts)))
    out.sort()
    print('\n--- %s ---' % tag)
    for cy, cx, bw, bh, a in out:
        fold = '  << 折叠头候选' if (8 <= bw <= 24 and 5 <= bh <= 14
                                    and 390 <= cx <= 470) else ''
        print('  cy=%-5d cx=%-5d %2dx%-2d area=%-5d%s' % (cy, cx, bw, bh, a, fold))
    return out


def main():
    with AuraAppSession(width=1400, height=900, title='Shelf Probe') as app:
        app.navigate_to('effects', delay=1.0)
        # 正数 = 向上滚；必须先回到顶部，否则所有坐标都无意义
        app.scroll(700, 500, clicks=12, delay=0.5)
        time.sleep(0.9)

        img = app.capture(SCRATCH)
        r, g, b = img.getpixel((1281, 451))[:3]
        if not (g > 180 and b < 110):
            print('低音主开关为关，点击开启...')
            app.click(1281, 451, delay=0.7)
            time.sleep(0.9)
        before = blobs(app, '展开高级区之前')

        cand = [b for b in before if 12 <= b[2] <= 24 and 5 <= b[3] <= 14
                and 390 <= b[1] <= 470]
        if not cand:
            print('\n未找到折叠头候选特征，无法继续。')
            return 1
        cy, cx = cand[0][0], cand[0][1]
        print('\n点击折叠头候选 (%d, %d)...' % (cx, cy))
        app.click(cx, cy, delay=0.8)
        time.sleep(1.1)
        blobs(app, '展开高级区之后')
    return 0


if __name__ == '__main__':
    sys.exit(main())