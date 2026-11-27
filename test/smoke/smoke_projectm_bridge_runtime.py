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
  6. 异步 request/readback ABI：请求 ID、pending/ready/failure、当前路径回读、
     快速请求合并/旧请求 superseded 均符合契约；
  7. 无已提交预设的新实例在慢加载被腐蚀请求取代后，保留初始完成帧与空路径；
  8. resize 后新尺寸帧可取；destroy 返回 0。

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


def _variant(base: str, **repl) -> str:
    out = base
    for k, v in repl.items():
        import re as _re
        out = _re.sub(rf"^{k}=.*$", f"{k}={v}", out, flags=_re.M)
    return out


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
    dll.auradsp_projectm_request_preset_load.restype = ctypes.c_uint64
    dll.auradsp_projectm_request_preset_load.argtypes = [ctypes.c_void_p,
                                                          ctypes.c_char_p]
    dll.auradsp_projectm_read_preset_load.restype = ctypes.c_int
    dll.auradsp_projectm_read_preset_load.argtypes = [
        ctypes.c_void_p, ctypes.c_uint64, ctypes.POINTER(ctypes.c_char),
        ctypes.c_size_t]
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

    def request(path, handle=h):
        return dll.auradsp_projectm_request_preset_load(
            handle, path.encode("utf-8"))

    def wait_read(request_id, timeout=5.0, handle=h):
        current = ctypes.create_string_buffer(32768)
        deadline = time.time() + timeout
        while True:
            status = dll.auradsp_projectm_read_preset_load(
                handle, request_id, current, len(current))
            value = current.value.decode("utf-8", "replace") or None
            if status != 1 or time.time() >= deadline:
                return status, value
            time.sleep(0.01)

    alt_path = os.path.join(tmp, "async_variant.milk")
    with open(alt_path, "w", encoding="utf-8") as f:
        f.write(_variant(MINIMAL_MILK, **{"fDecay": "0.910"}))
    first = request(good)
    second = request(alt_path)
    check(first != 0 and second != 0 and first != second,
          "异步请求返回递增非零 ID")
    stale_status, _ = wait_read(first)
    check(stale_status == -4,
          "被后续请求取代的旧请求返回 -4（实得 %d）" % stale_status)
    status, current = wait_read(second)
    check(status == 0 and current == alt_path,
          "最新异步请求 ready 且回读当前路径（status=%d path=%s）" %
          (status, current))

    bad_request = request(corrupt)
    status, current = wait_read(bad_request)
    check(status == -3 and current == alt_path,
          "异步坏预设失败且保留上一当前路径（status=%d path=%s）" %
          (status, current))

    # Force a valid parse to remain in flight while a newer corrupt request
    # arrives. A superseded successful parse must not replace the previously
    # committed current path when the newer request fails.
    slow_path = os.path.join(tmp, "slow_valid.milk")
    with open(slow_path, "w", encoding="utf-8") as f:
        f.write(MINIMAL_MILK)
        for i in range(1, 20001):
            f.write("per_frame_%d=zoom=zoom+0.000001;\n" % i)
    stale_request = request(slow_path)
    time.sleep(0.1)
    race_started = time.time()
    newer_bad_request = request(corrupt)
    status, current = wait_read(newer_bad_request)
    race_elapsed = time.time() - race_started
    check(race_elapsed > 0.1,
          "竞态夹具确实重叠（新请求等待 %.3fs）" % race_elapsed)
    check(status == -3 and current == alt_path,
          "飞行中被取代的成功加载不回写当前路径"
          "（status=%d path=%s expected=%s）" %
          (status, current, alt_path))

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

    # 预设切换判别（2026-11-23，宾机报「只有第一个预设能显示」）：
    # 桥以 smooth transition 加载，疑过渡期后续加载被静默吞。
    # A/B 两预设运动与配色差异显著：加载 B 并持续喂流渲染后，
    # 帧内容必须实质变化；再切回 A 必须再次变化。
    def grab(seconds: float) -> bytes:
        bb = (ctypes.c_ubyte * (320 * 180 * 4))()
        end = time.time() + seconds
        last = -3
        while time.time() < end:
            dll.auradsp_projectm_feed_pcm(h, pcm, frames, 2)
            last = dll.auradsp_projectm_render_pixels(h, bb)
            time.sleep(0.05)
        return bytes(bb) if last == 0 else b""

    def mean_diff(a: bytes, b: bytes) -> float:
        if not a or not b or len(a) != len(b):
            return -1.0
        step = 401
        tot = 0
        cnt = 0
        for i in range(0, len(a), step):
            tot += abs(a[i] - b[i])
            cnt += 1
        return tot / max(cnt, 1)

    frame_a = grab(1.2)
    alt = os.path.join(tmp, "variant.milk")
    with open(alt, "w", encoding="utf-8") as f:
        f.write(_variant(MINIMAL_MILK,
                         **{"fDecay": "0.900", "zoom": "1.300",
                            "wave_r": "1.000", "wave_g": "0.050",
                            "wave_b": "0.050",
                            "per_frame_1": "zoom = 1.30;",
                            "per_frame_2": "rot = 0.05;"}))
    rc = dll.auradsp_projectm_load_preset(h, alt.encode("utf-8"))
    check(rc == 0, "第二个预设加载返回 0（实得 %d）" % rc)
    frame_b = grab(1.5)
    d_ab = mean_diff(frame_a, frame_b)
    check(d_ab > 1.0,
          "切换预设后帧内容实质变化（A/B 采样平均差 %.3f）" % d_ab)
    rc = dll.auradsp_projectm_load_preset(h, good.encode("utf-8"))
    check(rc == 0, "切回第一个预设返回 0（实得 %d）" % rc)
    frame_a2 = grab(1.5)
    d_ba = mean_diff(frame_b, frame_a2)
    check(d_ba > 1.0,
          "切回后帧内容再次变化（B/A2 采样平均差 %.3f）" % d_ba)

    # 内置预设真文件判别（r65）：随包三只 .milk 必须各自可加载
    # 且渲染互异——r64 时三只内置是 'builtin:' 伪路径，桥恒拒
    # 绝、UI 恒显示同一默认画面（宾机报「只能开第一个」）。
    repo_root = os.path.dirname(os.path.dirname(
        os.path.dirname(os.path.abspath(__file__))))
    builtin_dir = os.path.join(
        repo_root, "app", "auradsp_app", "assets", "milkdrop")
    builtin_frames = {}
    for name in ("cosmic_warp", "bio_pulsar", "neon_vortex"):
        p = os.path.join(builtin_dir, name + ".milk")
        check(os.path.isfile(p), "内置预设文件在仓：%s" % name)
        if not os.path.isfile(p):
            continue
        rc = dll.auradsp_projectm_load_preset(h, p.encode("utf-8"))
        check(rc == 0, "内置预设 %s 加载返回 0（实得 %d）" % (name, rc))
        builtin_frames[name] = grab(1.5)
    names = sorted(builtin_frames)
    for i in range(len(names)):
        for j in range(i + 1, len(names)):
            d = mean_diff(builtin_frames[names[i]],
                          builtin_frames[names[j]])
            check(d > 1.0,
                  "内置预设 %s 与 %s 帧内容互异（采样平均差 %.3f）"
                  % (names[i], names[j], d))

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

    # Fresh-handle contamination regression: no preset has ever been committed.
    # A slow valid load enters projectM, then a newer corrupt request supersedes
    # it. The failed latest request must not publish the contaminating preset or
    # replace the initial completed frame with an unrequested visualization.
    fresh = dll.auradsp_projectm_create(320, 180, 30.0)
    check(fresh is not None, "新实例 create 成功（无已提交预设）")
    if not fresh:
        print("smoke_projectm_bridge_runtime: %s" % ("FAIL" if FAILS else "PASS"))
        return 1 if FAILS else 0
    fresh = ctypes.c_void_p(fresh)
    initial_buf = (ctypes.c_ubyte * (320 * 180 * 4))()
    got = -3
    deadline = time.time() + 5.0
    while time.time() < deadline:
        dll.auradsp_projectm_feed_pcm(fresh, pcm, frames, 2)
        got = dll.auradsp_projectm_render_pixels(fresh, initial_buf)
        if got == 0:
            break
        time.sleep(0.02)
    check(got == 0, "新实例初始完成帧可取（实得 %d）" % got)
    initial_frame = bytes(initial_buf) if got == 0 else None
    if initial_frame is not None:
        stale_request = request(slow_path, fresh)
        time.sleep(0.1)
        pending_path = ctypes.create_string_buffer(32768)
        pending_status = dll.auradsp_projectm_read_preset_load(
            fresh, stale_request, pending_path, len(pending_path))
        check(pending_status == 1 and
              not pending_path.value.decode("utf-8", "replace"),
              "慢合法请求已进入飞行且尚未提交路径")
        race_started = time.time()
        newer_bad_request = request(corrupt, fresh)
        status, current = wait_read(newer_bad_request, handle=fresh)
        race_elapsed = time.time() - race_started
        check(race_elapsed > 0.1,
              "新实例竞态夹具确实重叠（新请求等待 %.3fs）" % race_elapsed)
        check(status == -3,
              "新实例最新腐蚀请求失败（status=%d）" % status)
        check(current is None,
              "新实例无已提交预设时当前路径保持为空"
              "（path=%s）" % current)

        # Allow any erroneous resumed rendering to publish before inspecting.
        # A correct transaction stays render-blocked, so every snapshot remains
        # byte-identical to the initial completed frame.
        published_buf = (ctypes.c_ubyte * (320 * 180 * 4))()
        unchanged = True
        snapshots = 0
        deadline = time.time() + 0.3
        while time.time() < deadline:
            dll.auradsp_projectm_feed_pcm(fresh, pcm, frames, 2)
            rc = dll.auradsp_projectm_render_pixels(fresh, published_buf)
            if rc == 0:
                snapshots += 1
                if bytes(published_buf) != initial_frame:
                    unchanged = False
                    break
            time.sleep(0.02)
        check(unchanged and snapshots > 0,
              "污染后未发布新帧，保留初始完成帧"
              "（snapshots=%d unchanged=%s）" % (snapshots, unchanged))

    check(dll.auradsp_projectm_destroy(fresh) == 0, "新实例 destroy 返回 0")
    print("smoke_projectm_bridge_runtime: %s" % ("FAIL" if FAILS else "PASS"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
