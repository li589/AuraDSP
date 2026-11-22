#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_projectm_bridge_runtime.py — projectM 桥运行时实证（W3/W5）

W3 起桥自持 GL 上下文（隐藏 WGL 窗口 + 专用渲染线程），宿主不再
提供上下文。本用例在真 DLL 上钉住端到端行为：

  1. has_current_gl_context 报告平台层在位；
  2. create 成功（旧契约下宿主无上下文时恒失败）；
  3. 喂入合法 PCM 返回 0、非法样本（NaN）返回 -1；
  4. 渲染线程持续产帧：render_pixels 在超时内返回 0 且帧尺寸对；
  5. load_preset 语义实证（审计遗留推论项）：合法 .milk 返回 0，
     损坏 .milk 返回 -3（projectM 失败回调口径）；
  6. resize 后新尺寸帧可取；destroy 返回 0。

产物经环境变量定位（AURADSP_PM_BRIDGE_DLL / AURADSP_PM_SDK_BIN），
未设置时自 SKIP 退出 0（仓库惯例）；开发机门禁显式设置后实跑。
仅 Windows 有意义。
"""
import ctypes
import math
import os
import sys
import tempfile
import time

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


MINIMAL_MILK = """[preset00]
fRating=3.000
fGammaAdj=1.000
fDecay=0.980
fVideoEchoZoom=1.000
fVideoEchoAlpha=0.000
nVideoEchoOrientation=0
nWaveMode=0
bAdditiveWaves=0
bWaveDots=0
bWaveThick=1
bModWaveAlphaByVolume=0
bMaximizeWaveColor=1
bTexWrap=1
bDarkenCenter=0
bRedBlueStereo=0
bBrighten=0
bDarken=0
bSolarize=0
bInvert=0
fWaveAlpha=0.800
fWaveScale=1.000
fWaveSmoothing=0.750
fWaveParam=0.000
fModWaveAlphaStart=0.750
fModWaveAlphaEnd=0.950
fWarpAnimSpeed=1.000
fWarpScale=1.000
fZoomExponent=1.000
fShader=0.000
zoom=1.000
rot=0.000
cx=0.500
cy=0.500
dx=0.000
dy=0.000
warp=0.010
sx=1.000
sy=1.000
wave_r=0.650
wave_g=0.650
wave_b=0.650
wave_a=1.000
wave_x=0.500
wave_y=0.500
ob_size=0.010
ob_r=0.000
ob_g=0.000
ob_b=0.000
ob_a=0.000
ib_size=0.010
ib_r=0.250
ib_g=0.250
ib_b=0.250
ib_a=0.000
nMotionVectorsX=12
nMotionVectorsY=9
mv_dx=0.000
mv_dy=0.000
mv_l=0.900
mv_r=1.000
mv_g=1.000
mv_b=1.000
mv_a=0.000
fCentDist=0.000
per_frame_1=zoom = 1.01;
per_frame_2=rot = 0.002;
"""


def main() -> int:
    bridge_path = os.environ.get("AURADSP_PM_BRIDGE_DLL", "")
    sdk_bin = os.environ.get("AURADSP_PM_SDK_BIN", "")
    if not bridge_path or not os.path.isfile(bridge_path):
        print("  SKIP AURADSP_PM_BRIDGE_DLL 未设置或不存在，按惯例跳过")
        return 0
    if os.name != "nt":
        print("  SKIP 仅 Windows")
        return 0
    if sdk_bin and os.path.isdir(sdk_bin):
        os.add_dll_directory(sdk_bin)
    os.add_dll_directory(os.path.dirname(os.path.abspath(bridge_path)))

    dll = ctypes.CDLL(bridge_path)
    dll.auradsp_projectm_has_current_gl_context.restype = ctypes.c_int
    dll.auradsp_projectm_create.restype = ctypes.c_void_p
    dll.auradsp_projectm_create.argtypes = [ctypes.c_int, ctypes.c_int,
                                            ctypes.c_float]
    dll.auradsp_projectm_destroy.restype = ctypes.c_int
    dll.auradsp_projectm_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_projectm_get_width.restype = ctypes.c_int
    dll.auradsp_projectm_get_width.argtypes = [ctypes.c_void_p]
    dll.auradsp_projectm_get_height.restype = ctypes.c_int
    dll.auradsp_projectm_get_height.argtypes = [ctypes.c_void_p]
    dll.auradsp_projectm_resize.restype = ctypes.c_int
    dll.auradsp_projectm_resize.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                            ctypes.c_int]
    dll.auradsp_projectm_feed_pcm.restype = ctypes.c_int
    dll.auradsp_projectm_feed_pcm.argtypes = [ctypes.c_void_p,
                                              ctypes.POINTER(ctypes.c_float),
                                              ctypes.c_int, ctypes.c_int]
    dll.auradsp_projectm_load_preset.restype = ctypes.c_int
    dll.auradsp_projectm_load_preset.argtypes = [ctypes.c_void_p,
                                                 ctypes.c_char_p]
    dll.auradsp_projectm_render_pixels.restype = ctypes.c_int
    dll.auradsp_projectm_render_pixels.argtypes = [ctypes.c_void_p,
                                                   ctypes.POINTER(ctypes.c_ubyte)]

    check(dll.auradsp_projectm_has_current_gl_context() == 1,
          "GL 平台层在位（has_current_gl_context == 1）")

    h = dll.auradsp_projectm_create(320, 180, 30.0)
    check(h is not None, "create(320x180) 成功（桥自持上下文）")
    if not h:
        return 1
    h = ctypes.c_void_p(h)
    check(dll.auradsp_projectm_get_width(h) == 320 and
          dll.auradsp_projectm_get_height(h) == 180, "尺寸回读 320x180")

    frames = 576
    pcm = (ctypes.c_float * (frames * 2))()
    for i in range(frames):
        t = i / 48000.0
        pcm[i * 2] = 0.5 * math.sin(2.0 * math.pi * 440.0 * t)
        pcm[i * 2 + 1] = 0.5 * math.sin(2.0 * math.pi * 220.0 * t)
    check(dll.auradsp_projectm_feed_pcm(h, pcm, frames, 2) == 0,
          "合法 PCM 喂入返回 0")
    bad = (ctypes.c_float * 4)(0.0, float("nan"), 0.0, 0.0)
    check(dll.auradsp_projectm_feed_pcm(h, bad, 2, 2) == -1,
          "NaN 样本喂入返回 -1")

    tmp = tempfile.mkdtemp(prefix="pm_smoke_")
    good = os.path.join(tmp, "minimal.milk")
    with open(good, "w", encoding="utf-8") as f:
        f.write(MINIMAL_MILK)
    rc = dll.auradsp_projectm_load_preset(h, good.encode("utf-8"))
    check(rc == 0, "合法 .milk 加载返回 0（实得 %d）" % rc)
    corrupt = os.path.join(tmp, "corrupt.milk")
    with open(corrupt, "wb") as f:
        f.write(b"\x89PNG not a preset \x00\x01\x02" * 16)
    rc = dll.auradsp_projectm_load_preset(h, corrupt.encode("utf-8"))
    check(rc == -3, "损坏 .milk 加载返回 -3（实得 %d）" % rc)
    rc = dll.auradsp_projectm_load_preset(h, good.encode("utf-8"))
    check(rc == 0, "损坏后重新加载合法预设返回 0（实得 %d）" % rc)

    buf = (ctypes.c_ubyte * (320 * 180 * 4))()
    got = -3
    deadline = time.time() + 5.0
    while time.time() < deadline:
        dll.auradsp_projectm_feed_pcm(h, pcm, frames, 2)
        got = dll.auradsp_projectm_render_pixels(h, buf)
        if got == 0:
            break
        time.sleep(0.05)
    check(got == 0, "渲染线程产帧，render_pixels 返回 0（实得 %d）" % got)
    if got == 0:
        nonzero = sum(1 for i in range(0, len(buf), 997) if buf[i] != 0)
        print("  NOTE 非零采样点 %d（仅记录，像素内容随驱动而异）" % nonzero)

    check(dll.auradsp_projectm_resize(h, 160, 90) == 0, "resize 返回 0")
    buf2 = (ctypes.c_ubyte * (160 * 90 * 4))()
    got = -3
    deadline = time.time() + 5.0
    while time.time() < deadline:
        got = dll.auradsp_projectm_render_pixels(h, buf2)
        if got == 0:
            break
        time.sleep(0.05)
    check(got == 0, "resize 后新尺寸帧可取（实得 %d）" % got)

    check(dll.auradsp_projectm_destroy(h) == 0, "destroy 返回 0")
    print("smoke_projectm_bridge_runtime: %s" % ("FAIL" if FAILS else "PASS"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
