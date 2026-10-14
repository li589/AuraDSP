# -*- coding: utf-8 -*-
"""smoke_vm_bridge.py — VB-Callback 常驻桥冒烟（需 Voicemeeter 在线）。

流程：detect → start → 跑 3s（frames 增长）→ set_param →
viz_read → test_start(tone)/stop（testKind 翻转 + 心跳文件无关）→ stop。
OUT 槽被占（rc=1）时记 note 优雅通过（泵同式让路不断言）。
"""
import ctypes
import json
import os
import sys
import time

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
CANDS = [
    os.path.join(ROOT, "test", "auravm_bridge.dll"),
    os.path.join(ROOT, "core", "desktop", "windows-drivers", "out", "Release",
                 "auravm_bridge.dll"),
]
ENV = os.environ.get("AURADSP_VB_BRIDGE_DLL")
if ENV:
    CANDS.insert(0, ENV)

path = next((p for p in CANDS if os.path.exists(p)), None)
if not path:
    print("SKIP（桥 DLL 不存在）")
    sys.exit(0)

b = ctypes.CDLL(path)
b.vb_detect.restype = ctypes.c_int
b.vb_start.restype = ctypes.c_int
b.vb_stop.restype = ctypes.c_int
b.vb_status.restype = ctypes.c_int
b.vb_set_param.restype = ctypes.c_int
b.vb_viz_read.restype = ctypes.c_int
b.vb_test_start.restype = ctypes.c_int
b.vb_test_stop.restype = ctypes.c_int
b.vb_detect.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.vb_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
b.vb_status.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.vb_set_param.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
b.vb_viz_read.argtypes = [ctypes.c_void_p, ctypes.c_int]
b.vb_test_start.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                            ctypes.c_int, ctypes.c_int]

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def get_status():
    buf = ctypes.create_string_buffer(2048)
    if b.vb_status(buf, 2048) <= 0:
        return {}
    try:
        return json.loads(buf.value.decode("utf-8", "replace"))
    except ValueError:
        return {}

buf = ctypes.create_string_buffer(2048)
rc = b.vb_detect(buf, 2048)
det = json.loads(buf.value.decode("utf-8", "replace")) if rc > 0 else {}
check("detect", det.get("found", False), det.get("editionName", ""))
if not det.get("found", False):
    print("SKIP（Voicemeeter 未安装）")
    sys.exit(0)

# 引擎走绝对路径（smoke 进程是 python，DLL 搜索序找不到引擎，必须显式给；
# app 内则由 isolate 传 loadedPath，同样显式）。
ENG = os.path.join(ROOT, "test", "auradsp_engine.dll")
rc = b.vb_start(ENG.encode("utf-8"), b"")
if rc == 1:
    print("NOTE out-slot-busy（让路，不断言）")
    sys.exit(0)
if rc != 0:
    # App 活体占槽时 register 也可能报 -3（非 1）：此时让路而非判红。
    # 判据：另有 auradsp_app.exe 进程映射了桥 DLL。
    try:
        import subprocess as _sp
        tl = _sp.run(["tasklist", "/m", "auravm_bridge.dll"],
                     capture_output=True, text=True, encoding="utf-8",
                     errors="replace").stdout
        holders = [ln for ln in tl.splitlines()
                   if "auradsp_app.exe" in ln]
        if holders:
            print(f"NOTE app Holds slot（{len(holders)} 进程），让路不断言")
            sys.exit(0)
    except OSError:
        pass
check("start rc==0", rc == 0, f"rc={rc}")
if rc != 0:
    print("VMBRIDGE FAILURES:", fails)
    sys.exit(1)

time.sleep(3)
st = get_status()
check("frames growing", st.get("frames", 0) > 0, f"frames={st.get('frames')}")
check("groups>=1", st.get("groups", 0) >= 1, f"groups={st.get('groups')}")

f = ctypes.c_float(6.0)
n = b.vb_set_param(b"tube.gain", 1, ctypes.byref(f))
check("set_param applied", n > 0, f"handles={n}")

viz = ctypes.create_string_buffer(408 * 4)
n = b.vb_viz_read(viz, 4)
check("viz_read ok", n >= 0, f"n={n}")
if (st.get("peakIn") or 0) > 1e-4:
    check("viz frames when audible", n > 0, f"n={n}")

rc = b.vb_test_start(1, None, 0, 0, 0)
check("test_start tone", rc == 0, f"rc={rc}")
time.sleep(1)
st = get_status()
check("testKind==1", st.get("testKind") == 1, f"testKind={st.get('testKind')}")
f2 = st.get("frames", 0)
check("frames keep growing in test", f2 > 0, f"frames={f2}")
check("vizGrp field plumbed",
      isinstance(st.get("vizGrp"), int) and 0 <= st["vizGrp"] < st.get("groups", 8),
      f"vizGrp={st.get('vizGrp')}")
rc = b.vb_test_stop()
check("test_stop", rc == 0, f"rc={rc}")
st = get_status()
check("testKind==0", st.get("testKind") == 0, f"testKind={st.get('testKind')}")

b.vb_bypass.restype = ctypes.c_int
b.vb_bypass.argtypes = [ctypes.c_int]
rc = b.vb_bypass(1)
check("bypass on", rc == 0, f"rc={rc}")
time.sleep(1)
st = get_status()
check("status bypass==1", st.get("bypass") == 1, f"bypass={st.get('bypass')}")
check("frames growing in bypass", st.get("frames", 0) > 0, f"frames={st.get('frames')}")
rc = b.vb_bypass(0)
check("bypass off", rc == 0, f"rc={rc}")
st = get_status()
check("status bypass==0", st.get("bypass") == 0, f"bypass={st.get('bypass')}")

rc = b.vb_stop()
check("stop", rc == 0, f"rc={rc}")
st = get_status()
check("running==false", st.get("running", True) is False)

if fails:
    print("VMBRIDGE FAILURES:", fails)
    sys.exit(1)
print("vm_bridge: all checks passed")
