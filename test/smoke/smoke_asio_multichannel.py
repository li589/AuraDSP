# -*- coding: utf-8 -*-
"""smoke_asio_multichannel.py — ASIO 桥多声道传输冒烟（04_asio_client B2c）。

验证 asio_start_ex(channels=N) 的 N 声道传输：引擎 channels.count 对齐、6 声道
文件注入过链有声、bypass 直通语义、以及驱动能力不足时的自动降级（ioCh 向下取档）。

需要 in/out >= 6 的 ASIO 驱动（本机以 Voicemeeter Virtual ASIO 8ch 为准）；
无此类驱动时自动 SKIP（不断言）。FL Studio ASIO（2/2）会被 create_io 拒绝，
正好用于验证驱动能力钳制不会误启动。
"""
import ctypes
import json
import math
import os
import sys
import time

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
CANDS = [
    os.environ.get("AURADSP_ASIO_BRIDGE_DLL", ""),
    os.path.join(ROOT, "test", "auraasio_bridge.dll"),
    os.path.join(ROOT, "core", "desktop", "windows-drivers", "out", "Release",
                 "auraasio_bridge.dll"),
]
CANDS = [p for p in CANDS if p]

path = next((p for p in CANDS if os.path.exists(p)), None)
if not path:
    print("SKIP（auraasio_bridge.dll 不存在，未构建 windows-drivers）")
    sys.exit(0)

b = ctypes.CDLL(path)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bridge_compat import alias_common, start_asio  # noqa: E402

alias_common(b, "asio")
b.asio_start_ex = start_asio(b)
b.asio_detect.restype = ctypes.c_int
b.asio_stop.restype = ctypes.c_int
b.asio_status.restype = ctypes.c_int
b.asio_get_param.restype = ctypes.c_int
b.asio_test_start.restype = ctypes.c_int
b.asio_test_stop.restype = ctypes.c_int
b.asio_bypass.restype = ctypes.c_int
b.asio_detect.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.asio_status.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.asio_get_param.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
b.asio_test_start.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                              ctypes.c_int, ctypes.c_int]
b.asio_bypass.argtypes = [ctypes.c_int]

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def get_status():
    buf = ctypes.create_string_buffer(4096)
    if b.asio_status(buf, 4096) <= 0:
        return {}
    try:
        return json.loads(buf.value.decode("utf-8", "replace"))
    except ValueError:
        return {}


def get_int(pid):
    v = ctypes.c_int32(0)
    rc = b.asio_get_param(pid.encode("utf-8"), 0, ctypes.byref(v))
    return rc, v.value


def detect():
    buf = ctypes.create_string_buffer(8192)
    rc = b.asio_detect(buf, 8192)
    if rc <= 0:
        return []
    try:
        return json.loads(buf.value.decode("utf-8", "replace")).get("drivers", [])
    except ValueError:
        return []


drivers = detect()
check("detect 返回非空", len(drivers) > 0, f"n={len(drivers)}")
if not drivers:
    print("SKIP（本机无 ASIO 驱动注册）")
    sys.exit(0)

ENG = os.path.join(ROOT, "test", "auradsp_engine.dll")
if not os.path.exists(ENG):
    print("SKIP（auradsp_engine.dll 不存在）")
    sys.exit(0)

# 多声道需 in/out>=6：优先 VM Virtual ASIO（8ch）；FL Studio（2/2）作反例排在后面。
PREF = ["Voicemeeter Virtual ASIO", "Voicemeeter Virtual ASIO x64"]
ordered = [d for name in PREF for d in drivers if d.get("name") == name]
ordered += [d for d in drivers if d not in ordered]


def start_ex(drv, channels, buf_size=0, out_pair=0):
    return b.asio_start_ex(drv["name"].encode("utf-8"), ENG.encode("utf-8"),
                           b"", buf_size, out_pair, channels)


# ---- 1) 6 声道启动：找到一个能建 6 声道的驱动 ----
started = None
for d in ordered:
    rc = start_ex(d, 6)
    if rc == 0:
        started = d
        break
    st = get_status()
    print(f"NOTE  {d['name']} ch=6 start rc={rc} note={st.get('note')}（换下一个候选）")
    b.asio_stop()
if started is None:
    print("SKIP（无 in/out>=6 的 ASIO 驱动，多声道不可测）")
    sys.exit(0)

check("6ch start rc==0", True, f"driver={started['name']}")
time.sleep(2)
st = get_status()
check("running==true", st.get("running") is True, str(st.get("running")))
check("status ioCh==6", st.get("ioCh") == 6, f"ioCh={st.get('ioCh')}")
check("inCh/outCh>=6", st.get("inCh", 0) >= 6 and st.get("outCh", 0) >= 6,
      f"in={st.get('inCh')} out={st.get('outCh')}")
check("engineOk", st.get("engineOk") is True)
check("switches 增长", st.get("switches", 0) > 0, f"switches={st.get('switches')}")
rc, cc = get_int("channels.count")
check("引擎 channels.count==6", rc == 0 and cc == 6, f"rc={rc} cc={cc}")

# ---- 2) 6 声道文件注入过链 ----
rate = int(st.get("sr") or 48000)
frames = rate // 2  # 0.5s
freqs = [300, 400, 500, 600, 700, 800]
pcm = (ctypes.c_float * (frames * 6))()
for i in range(frames):
    t = i / rate
    for c in range(6):
        pcm[i * 6 + c] = 0.25 * math.sin(2 * math.pi * freqs[c] * t)
rc = b.asio_test_start(3, ctypes.cast(pcm, ctypes.c_void_p), frames, 6, rate)
check("test_start 6ch file", rc == 0, f"rc={rc}")
time.sleep(1)
st = get_status()
check("testKind==3", st.get("testKind") == 3, f"testKind={st.get('testKind')}")
check("6ch 过链有声 peakOut>0.005", st.get("peakOut", 0) > 0.005,
      f"peakOut={st.get('peakOut')}")

# ---- 3) bypass 直通：注入 0.25 幅度应≈原样到达（6 声道整块直通）----
rc = b.asio_bypass(1)
check("bypass on", rc == 0, f"rc={rc}")
time.sleep(1)
st = get_status()
peak = st.get("peakOut", 0)
check("bypass 6ch 直通峰值≈0.25±0.06", abs(peak - 0.25) <= 0.06, f"peakOut={peak}")
rc = b.asio_bypass(0)
check("bypass off", rc == 0, f"rc={rc}")
time.sleep(0.5)
st = get_status()
check("恢复过链后仍有声", st.get("peakOut", 0) > 0.005, f"peakOut={st.get('peakOut')}")
b.asio_test_stop()
check("testKind==0", get_status().get("testKind") == 0)
b.asio_stop()

# ---- 4) 驱动能力钳制：请求 4ch 但 out_pair=6（6+4>8）应降级为 2 ----
rc = start_ex(started, 4, buf_size=0, out_pair=6)
check("降级启动 rc==0", rc == 0, f"rc={rc}")
if rc == 0:
    time.sleep(1)
    st = get_status()
    check("降级后 ioCh==2", st.get("ioCh") == 2, f"ioCh={st.get('ioCh')}")
    check("降级上报 note", "ioCh" in (st.get("note") or ""),
          f"note={st.get('note')}")
    rc, cc = get_int("channels.count")
    check("降级后引擎 channels.count==2", rc == 0 and cc == 2, f"rc={rc} cc={cc}")
    b.asio_stop()

# ---- 5) 停止幂等 ----
b.asio_stop()
st = get_status()
check("running==false", st.get("running", True) is False)
check("stop 幂等 rc==0", b.asio_stop() == 0)

if fails:
    print("ASIO MULTICHANNEL FAILURES:", fails)
    sys.exit(1)
print("asio_multichannel: all checks passed")
