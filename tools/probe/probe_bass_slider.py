"""probe_bass_slider.py — 临时取证：低音卡开关 ON + 高级区展开后的滑块行坐标。

用途：为 ui_verify_slider_reset 的动态行发现提供实测数据。
"""
import os
import sys
import tempfile
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), 'test', 'ui'))

from ui_test_kit import AuraAppSession  # noqa: E402

SCRATCH = os.path.join(tempfile.gettempdir(), 'auradsp_bass_probe.png')
ACCENT = (212, 255, 63)
TOL = 52


def near(px):
    return (abs(px[0] - ACCENT[0]) <= TOL and abs(px[1] - ACCENT[1]) <= TOL
            and abs(px[2] - ACCENT[2]) <= TOL)


def dump(app, tag, box=(340, 380, 1350, 900)):
    img = app.capture(SCRATCH, box)
    px = img.load()
    w, h = img.size
    rows = {}
    for y in range(h):
        run = 0
        best = 0
        bx = 0
        for x in range(w):
            if near(px[x, y]):
                run += 1
                if run > best:
                    best = run
                    bx = x
            else:
                run = 0
        if best >= 7:
            rows[y] = (best, bx + box[0])
    print('\n--- %s : accent 竖向连续 >=7px 的行 ---' % tag)
    for y in sorted(rows):
        n, x = rows[y]
        print('  y=%-5d (abs %-5d) 宽=%-4d 末端x=%d' % (y, y + box[1], n, x))


def main():
    with AuraAppSession(width=1400, height=900, title='Bass Probe') as app:
        app.navigate_to('effects', delay=1.0)
        app.scroll(700, 500, clicks=8, delay=0.5)
        time.sleep(0.8)
        dump(app, '初始（开关未开）')

        img = app.capture(SCRATCH)
        r, g, b = img.getpixel((1281, 451))[:3]
        if not (g > 180 and b < 110):
            print('\n低音主开关为关，点击开启...')
            app.click(1281, 451, delay=0.7)
            time.sleep(0.8)
        dump(app, '低音主开关 ON')

        print('\n点击高级区折叠头 (430, 649)...')
        app.click(430, 649, delay=0.7)
        time.sleep(0.9)
        dump(app, '高级区展开后')
    return 0


if __name__ == '__main__':
    sys.exit(main())