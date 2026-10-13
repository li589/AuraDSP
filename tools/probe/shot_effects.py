"""shot_effects.py — 在与 UI 测试完全相同的条件下截取效果页，供肉眼定位控件。

之所以不靠坐标推断：自动化跑在深色主题（config.json 被隔离 → 回落默认值），
而用户实际操作可能用浅色主题，两者配色与控件配色完全不同，看 RGB 猜不出
哪个是开关、哪个是滑轨。直接看图最快。

用法：
  python tools/probe/shot_effects.py --out shot.png --scroll 0
  python tools/probe/shot_effects.py --out shot.png --scroll -3   # 向上滚
"""
import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.abspath(__file__)))), 'test', 'ui'))

import ui_test_kit as K  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='shot.png')
    ap.add_argument('--scroll', type=int, default=0,
                    help='正数=向下滚(clicks>0)，负数=向上滚(clicks<0)')
    ap.add_argument('--after', default='',
                    help='截图后追加的检查动作，如 click:430,649')
    args = ap.parse_args()

    out = os.path.abspath(args.out)
    with K.AuraAppSession(width=1400, height=900, title='Effects Shot') as app:
        app.navigate_to('effects', delay=1.2)
        if args.scroll:
            # 约定：正数向下滚(clicks>0)，负数向上滚(clicks<0)
            app.scroll(700, 500, clicks=args.scroll, delay=0.6)
        time.sleep(0.8)
        for spec in filter(None, (s.strip() for s in args.after.split(';'))):
            kind, _, coord = spec.partition(':')
            x, y = [int(v) for v in coord.split(',')]
            app.click(x, y, delay=0.5)
            print('已点击 (%d,%d) [%s]' % (x, y, kind))
        img = app.capture(out, (0, 0, 1400, 900))
        print('截图已保存: %s  %dx%d' % (out, img.width, img.height))
    return 0


if __name__ == '__main__':
    sys.exit(main())