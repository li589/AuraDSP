"""probe_effects_geometry.py — 从真实像素推导效果页控件坐标。

项目铁律：严禁盲写假坐标，必须实测窗口几何与组件像素来推导。
本脚本启动 AuraDSP、进入效果页，抓图后做 accent 色连通域分析，
把开关/滑块 Thumb/高级区折叠头的真实圆心打印出来，供 UI 测试引用。

运行：与启动 app 同一条命令内
  $p = Start-Process $exe -PassThru; python tools/probe_effects_geometry.py
"""
import ctypes
import ctypes.wintypes as wt
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                '..', 'test', 'ui'))

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SHOT = os.path.join(os.environ.get('TEMP', '.'), 'auradsp_effects_probe.png')

from PIL import Image  # noqa: E402
from ui_test_kit import AuraAppSession, find_auradsp  # noqa: E402

# aura-dark 主题的 accent = #D4FF3F
ACCENT = (212, 255, 63)


def close_to(px, ref, tol=46):
    return (abs(px[0] - ref[0]) <= tol and abs(px[1] - ref[1]) <= tol
            and abs(px[2] - ref[2]) <= tol)


def blobs(img):
    """把 accent 色像素做 8 邻域连通域聚类，返回 (cx, cy, w, h, area)"""
    w, h = img.size
    px = img.load()
    mask = bytearray(w * h)
    for y in range(h):
        row = y * w
        for x in range(w):
            if close_to(px[x, y], ACCENT):
                mask[row + x] = 1
    seen = bytearray(w * h)
    out = []
    for y in range(h):
        for x in range(w):
            i = y * w + x
            if not mask[i] or seen[i]:
                continue
            stack = [i]
            seen[i] = 1
            xs, ys, n = [], [], 0
            while stack:
                j = stack.pop()
                jy, jx = divmod(j, w)
                xs.append(jx)
                ys.append(jy)
                n += 1
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        nx, ny = jx + dx, jy + dy
                        if 0 <= nx < w and 0 <= ny < h:
                            k = ny * w + nx
                            if mask[k] and not seen[k]:
                                seen[k] = 1
                                stack.append(k)
            if n >= 12:
                out.append((sum(xs) // len(xs), sum(ys) // len(ys),
                            max(xs) - min(xs) + 1, max(ys) - min(ys) + 1, n))
    return sorted(out, key=lambda b: (b[1], b[0]))


def main():
    if not find_auradsp():
        print('!! 未找到 AuraDSP 窗口 —— 请在同一命令内先 Start-Process 启动 app')
        return 2
    with AuraAppSession(width=1400, height=900, title='Geometry Probe') as app:
        app.navigate_to('effects', delay=1.0)
        img = app.capture(SHOT)
        print('captured %s  size=%s' % (SHOT, img.size))
        bs = blobs(img)
        print('\naccent 连通域 (cx, cy, w, h, area)  —— 按 y 排序：')
        print('%-6s %-6s %-5s %-5s %-7s %s' % ('cx', 'cy', 'w', 'h', 'area', '判定'))
        for cx, cy, bw, bh, n in bs:
            if bw >= 18 and bh >= 18:
                kind = 'SWITCH/大控件 (accent 实心块)'
            elif bw >= 10 and 8 <= bh <= 16:
                kind = 'Slider Thumb (圆形手柄)'
            elif 10 <= bw <= 26 and bh <= 26:
                kind = '高级区折叠箭头 / 小图标'
            else:
                kind = '细条/文本'
            print('%-6d %-6d %-5d %-5d %-7d %s' % (cx, cy, bw, bh, n, kind))

        # 纵向投影：哪些 y 行有较多 accent（帮助定位卡片内的控件带）
        print('\naccent 像素按 y 行的聚集（>=12 像素的行段）：')
        px = img.load()
        w, h = img.size
        rows = []
        for y in range(h):
            c = sum(1 for x in range(w) if close_to(px[x, y], ACCENT))
            if c >= 12:
                rows.append((y, c))
        if rows:
            start = prev = rows[0][0]
            peak = rows[0]
            for y, c in rows[1:]:
                if y != prev + 1:
                    print('  y=%-5d..%-5d peak=%-4d @%d' % (start, prev, peak[1], peak[0]))
                    start, peak = y, (y, c)
                elif c > peak[1]:
                    peak = (y, c)
                prev = y
            print('  y=%-5d..%-5d peak=%-4d @%d' % (start, prev, peak[1], peak[0]))
        else:
            print('  (无)')
    return 0


if __name__ == '__main__':
    sys.exit(main())