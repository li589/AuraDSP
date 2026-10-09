# -*- coding: utf-8 -*-
# 截图像素断言：侧栏收起/展开 + 首页可视化置顶 + 背景模糊
from PIL import Image
import os

D = r"D:\temp_desktop\Proj\JamesDSP\docs\ui-redesign"
im05 = Image.open(os.path.join(D, "05-home-v2.png")).convert("RGB")
im06 = Image.open(os.path.join(D, "06-home-rail-collapsed.png")).convert("RGB")
im07 = Image.open(os.path.join(D, "07-home-rail-expanded.png")).convert("RGB")
im_old = Image.open(os.path.join(D, "01-home.png")).convert("RGB")

def text_pixels(img, x0, x1, y0, y1, thr=110):
    """统计区域内亮色（文本）像素数"""
    n = 0
    px = img.load()
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = px[x, y]
            if r > thr and g > thr and b > thr:
                n += 1
    return n

def accent_top(img, x0, x1, y0, y1):
    """区域内第一个 accent(黄绿) 像素的 y"""
    px = img.load()
    for y in range(y0, y1):
        for x in range(x0, x1):
            r, g, b = px[x, y]
            if r > 180 and g > 220 and b < 110:
                return y
    return None

# 1) 展开态应与初态几乎一致（收起→展开往返无损）
g5 = list(im05.resize((100, 60)).convert("RGB").getdata())
g7 = list(im07.resize((100, 60)).convert("RGB").getdata())
d0705 = sum(abs(c1[i] - c2[i]) for c1, c2 in zip(g5, g7) for i in range(3)) / (100 * 60 * 3)
print("1) expanded vs initial mean diff = %.2f (expect < 8)" % d0705)

# 2) 收起态：导航标签区（x 60..310, y 250..560 物理）文本像素应大幅减少（残量=图标）
tp05 = text_pixels(im05, 60, 310, 250, 560)
tp06 = text_pixels(im06, 60, 310, 250, 560)
print("2) nav-label text px: expanded=%d collapsed=%d (expect collapsed < expanded*0.5)" % (tp05, tp06))

# 3) 首页改版：hero（引擎总览卡）应从第一卡降为第二卡 →
#    延迟读数的 success 绿(0xFF5AD19B) 最低出现 y 应比旧版更大
def green_top(img, x0, x1, y0, y1):
    px = img.load()
    for y in range(y0, y1):
        for x in range(x0, x1, 2):
            r, g, b = px[x, y]
            if 60 < r < 140 and g > 170 and 110 < b < 190 and g - r > 60:
                return y
    return None

ht_new = green_top(im05, 340, 2050, 150, 1100)
ht_old = green_top(im_old, 340, 2050, 150, 1100)
print("3) hero latency-green top y: new=%s old=%s (expect new > old)" % (ht_new, ht_old))

# 4) 背景模糊：右缘页边距（纯氛围层区域 x 1930..2040）亮度梯度应更低
def grad_energy(img, x0, x1, y0, y1):
    px = img.load()
    tot = 0
    for y in range(y0, y1):
        for x in range(x0 + 1, x1):
            tot += abs(px[x, y][0] - px[x - 1, y][0])
    return tot / ((x1 - x0 - 1) * (y1 - y0))

ge_new = grad_energy(im05, 1930, 2040, 900, 1250)
ge_old = grad_energy(im_old, 1930, 2040, 900, 1250)
print("4) bg gradient energy (right margin): new=%.3f old=%.3f (blur => new < old)" % (ge_new, ge_old))

ok = (d0705 < 8 and tp06 < tp05 * 0.5
      and ht_new is not None and ht_old is not None and ht_new > ht_old
      and ge_new < ge_old)
print("RESULT:", "PASS" if ok else "CHECK NEEDED")
