# -*- coding: utf-8 -*-
"""smoke_asio_bridge.py — ASIO 常驻桥冒烟（04_asio_engine Phase 2）。

流程（镜像 smoke_vm_bridge.py，驱动优先级 FL Studio ASIO > VM Virtual > 任一）：
detect → start(引擎) → 3s（switches 增长）→ set_param → viz_read →
test_start(tone) + bypass 开（峰值≈注入幅度，直通语义）/ 关（过链仍有声）→
test_stop → stop（running=false）。

优雅让路（不断言）：DLL/引擎缺失 SKIP；驱动被占（open/buffers 失败）换下一个
候选，全部被占记 NOTE 跳过——ASIO 驱动同时只服务一个客户端（如 FL Studio 在跑）。
"""
import ctypes
import json
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
b.asio_detect.restype = ctypes.c_int
b.asio_start.restype = ctypes.c_int
b.asio_stop.restype = ctypes.c_int
b.asio_status.restype = ctypes.c_int
b.asio_set_param.restype = ctypes.c_int
b.asio_viz_read.restype = ctypes.c_int
b.asio_test_start.restype = ctypes.c_int
b.asio_test_stop.restype = ctypes.c_int
b.asio_bypass.restype = ctypes.c_int
b.asio_detect.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.asio_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                         ctypes.c_long, ctypes.c_long]
b.asio_status.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.asio_set_param.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
b.asio_viz_read.argtypes = [ctypes.c_void_p, ctypes.c_int]
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

# 驱动优先级：FL Studio ASIO（2ch/44100/512）→ VM Virtual（8ch/48000/2048）
# → 其余任一。被占（另一个客户端正用）时让路下一个。
PREF = ["FL Studio ASIO", "Voicemeeter Virtual ASIO"]
ordered = [d for name in PREF for d in drivers if d.get("name") == name]
ordered += [d for d in drivers if d not in ordered]

started = False
chosen = None
for d in ordered:
    rc = b.asio_start(d["name"].encode("utf-8"), ENG.encode("utf-8"), b"", 0, 0)
    if rc == 0:
        started = True
        chosen = d
        break
    st = get_status()
    note = st.get("note", "")
    print(f"NOTE  {d['name']} start rc={rc} note={note}（换下一个候选）")
if not started:
    print("NOTE  全部驱动 start 失败（驱动多被占或环境异常），跳过不断言")
    sys.exit(0)
check("start rc==0", True, f"driver={chosen['name']}")

time.sleep(3)
st = get_status()
check("running==true", st.get("running") is True, str(st.get("running")))
check("switches 增长", st.get("switches", 0) > 0, f"switches={st.get('switches')}")
check("sr/nbs 有效", st.get("sr", 0) > 0 and st.get("nbs", 0) > 0,
      f"sr={st.get('sr')} nbs={st.get('nbs')}")
check("engineOk", st.get("engineOk") is True)
check("inCh/outCh>=2", st.get("inCh", 0) >= 2 and st.get("outCh", 0) >= 2,
      f"in={st.get('inCh')} out={st.get('outCh')}")
# ---- Phase 4 加固字段（asioMessage 标志 + 掉线统计）----
check("status 含 resetPending/latenciesChanged/dropouts",
      "resetPending" in st and "latenciesChanged" in st and "dropouts" in st)
check("resetPending==0（无待处理重置）", st.get("resetPending") == 0,
      f"resetPending={st.get('resetPending')}")
check("dropouts==0（3s 稳态无欠载）", st.get("dropouts") == 0,
      f"dropouts={st.get('dropouts')}")

f = ctypes.c_float(6.0)
rc = b.asio_set_param(b"tube.gain", 1, ctypes.byref(f))
check("set_param rc==0", rc == 0, f"rc={rc}")

viz = ctypes.create_string_buffer(408 * 4)
n = b.asio_viz_read(viz, 4)
check("viz_read ok", n >= 0, f"n={n}")

# ---- 测试注入 + bypass 语义 ----
rc = b.asio_test_start(1, None, 0, 0, 0)  # 正弦 440Hz，FillTestSignal 幅度 0.3
check("test_start tone", rc == 0, f"rc={rc}")
time.sleep(1)
st = get_status()
check("testKind==1", st.get("testKind") == 1, f"testKind={st.get('testKind')}")
check("bypass 前 test 过链有声", st.get("peakOut", 0) > 0.005,
      f"peakOut={st.get('peakOut')}")

rc = b.asio_bypass(1)
check("bypass on", rc == 0, f"rc={rc}")
time.sleep(1)
st = get_status()
check("status bypass==1", st.get("bypass") == 1, f"bypass={st.get('bypass')}")
# 直通语义：注入 0.3 幅度的正弦应≈原样到达输出（引擎链整体略过）。
peak_bypass = st.get("peakOut", 0)
check("bypass 直通峰值≈注入幅度(0.3±0.06)", abs(peak_bypass - 0.3) <= 0.06,
      f"peakOut={peak_bypass}")
sw1 = st.get("switches", 0)
time.sleep(0.5)
check("bypass 中 switches 仍增长", get_status().get("switches", 0) > sw1)

rc = b.asio_bypass(0)
check("bypass off", rc == 0, f"rc={rc}")
time.sleep(1)
st = get_status()
check("status bypass==0", st.get("bypass") == 0, f"bypass={st.get('bypass')}")
check("恢复过链后仍有声", st.get("peakOut", 0) > 0.005, f"peakOut={st.get('peakOut')}")

rc = b.asio_test_stop()
check("test_stop", rc == 0, f"rc={rc}")
st = get_status()
check("testKind==0", st.get("testKind") == 0, f"testKind={st.get('testKind')}")

# 缓冲数学自洽：switches*nbs ≈ 运行秒数*sr（±35%）
st = get_status()
if st.get("switches") and st.get("nbs") and st.get("sr"):
    audio_s = st["switches"] * st["nbs"] / st["sr"]
    check("缓冲数学自洽(≈5.5s±35%)", abs(audio_s - 5.5) <= 5.5 * 0.35,
          f"audio={audio_s:.2f}s")

rc = b.asio_stop()
check("stop", rc == 0, f"rc={rc}")
st = get_status()
check("running==false", st.get("running", True) is False)
rc = b.asio_stop()
check("stop 幂等", rc == 0, f"rc={rc}")

if fails:
    print("ASIOBRIDGE FAILURES:", fails)
    sys.exit(1)
print("asio_bridge: all checks passed")
