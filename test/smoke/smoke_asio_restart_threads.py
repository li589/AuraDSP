# -*- coding: utf-8 -*-
"""smoke_asio_restart_threads.py — ASIO 桥跨线程 start/stop 回归（r57 P0）。

定罪背景（2026-11-19 宾机实证）：IASIO 是 Apartment 模型 COM 类且无
proxy/stub，CoCreateInstance 只能在 STA 套间线程上成功。桥旧实现直接在
调用方（Dart FFI）线程上 open：每进程首次 start 靠 SDK 单例构造在当时
线程上 CoInitialize(STA) 侥幸成功，stop 后从另一条线程（isolate 重建
换线程；新线程 COM 未初始化或 MTA）重开必失败，且旧文案误导为
「COM 步/注册表」问题。修复：桥内专设 STA 控制线程承接全部 SDK 控制面。

本冒烟以 Python 线程复刻该形态：主线程 start→stop 后，从**新建线程**
再次 start 并从另一新线程 stop——修复前第二启必失败，修复后必成功。

优雅让路（不断言）：DLL/引擎缺失、无 ASIO 驱动注册、首启即失败（驱动
被占等环境原因）→ NOTE/SKIP 退出 0。首启成功之后的跨线程重开失败才是
真回归，FAIL 退出 1。
"""
import ctypes
import json
import os
import sys
import threading
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
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
b.asio_start = start_asio(b)
b.asio_detect.restype = ctypes.c_int
b.asio_stop.restype = ctypes.c_int
b.asio_status.restype = ctypes.c_int
b.asio_detect.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.asio_status.argtypes = [ctypes.c_char_p, ctypes.c_int]

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
    if b.asio_detect(buf, 8192) <= 0:
        return []
    try:
        return json.loads(buf.value.decode("utf-8", "replace")).get("drivers", [])
    except ValueError:
        return []


def run_in_thread(fn):
    """在一条全新 OS 线程上执行 fn 并返回其返回值（复刻 FFI 换线程形态）。"""
    box = {}

    def target():
        box["rc"] = fn()

    t = threading.Thread(target=target)
    t.start()
    t.join(timeout=30)
    if t.is_alive():
        return None
    return box.get("rc")


drivers = detect()
if not drivers:
    print("SKIP（本机无 ASIO 驱动注册）")
    sys.exit(0)

ENG = os.path.join(ROOT, "test", "auradsp_engine.dll")
if not os.path.exists(ENG):
    print("SKIP（auradsp_engine.dll 不存在）")
    sys.exit(0)

PREF = ["FL Studio ASIO", "Voicemeeter Virtual ASIO"]
ordered = [d for name in PREF for d in drivers if d.get("name") == name]
ordered += [d for d in drivers if d not in ordered]

# ---- 周期 1：主线程 start（首启；失败视为环境让路）----
chosen = None
for d in ordered:
    rc = b.asio_start(d["name"].encode("utf-8"), ENG.encode("utf-8"), b"", 0, 0)
    if rc == 0:
        chosen = d
        break
    print(f"NOTE  {d['name']} 首启 rc={rc} note={get_status().get('note', '')}（换下一个候选）")
if not chosen:
    print("NOTE  全部驱动首启失败（驱动多被占或环境异常），跳过不断言")
    sys.exit(0)
print(f"NOTE  周期1 主线程 start 成功 driver={chosen['name']}")
time.sleep(1.5)
st = get_status()
check("周期1 running", st.get("running") is True)
check("周期1 switches>0", st.get("switches", 0) > 0, f"switches={st.get('switches')}")
rc = b.asio_stop()
check("周期1 主线程 stop rc==0", rc == 0, f"rc={rc}")
check("周期1 stop 后 running=false", get_status().get("running") is False)

# ---- 周期 2：全新线程 start（回归断言点）----
name_b = chosen["name"].encode("utf-8")
eng_b = ENG.encode("utf-8")
rc = run_in_thread(lambda: b.asio_start(name_b, eng_b, b"", 0, 0))
check("周期2 新线程 start rc==0", rc == 0,
      f"rc={rc} note={get_status().get('note', '')}")
if rc == 0:
    time.sleep(1.5)
    st = get_status()
    check("周期2 running", st.get("running") is True)
    check("周期2 switches>0", st.get("switches", 0) > 0,
          f"switches={st.get('switches')}")
    rc = run_in_thread(lambda: b.asio_stop())
    check("周期2 另一新线程 stop rc==0", rc == 0, f"rc={rc}")
    check("周期2 stop 后 running=false", get_status().get("running") is False)

    # ---- 周期 3：回主线程再启（全周期健全性）----
    rc = b.asio_start(name_b, eng_b, b"", 0, 0)
    check("周期3 主线程 start rc==0", rc == 0,
          f"rc={rc} note={get_status().get('note', '')}")
    if rc == 0:
        rc = b.asio_stop()
        check("周期3 stop rc==0", rc == 0, f"rc={rc}")

print("RESULT:", "FAIL " + ",".join(fails) if fails else "PASS")
sys.exit(1 if fails else 0)
