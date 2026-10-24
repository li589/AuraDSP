# -*- coding: utf-8 -*-
"""smoke_vaio_bridge.py — AuraVAIO 虚拟声卡模式持久桥冒烟（Mode 1 驱动与桥集成验证）。

流程（镜像 smoke_vm_bridge.py 与 smoke_asio_bridge.py）：
1. detect -> 检测驱动存在性与端点枚举
2. 若驱动未安装（如 Host 未装虚拟驱动），验证 detect 优雅返回 found=false
3. 若驱动安装（如 Win10/Win7 实测环境），验证：
   start(engine) -> 运行态 running=true -> 读写帧步进 -> set_param / set_param_str ->
   get_param / get_param_str -> viz_read -> test_start (tone 440) -> bypass 切换 ->
   test_stop -> stop (running=false)。
"""
import ctypes
import json
import os
import sys
import time

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
CANDS = [
    os.environ.get("AURADSP_VAIO_BRIDGE_DLL", ""),
    os.path.join(ROOT, "test", "auravaio_bridge.dll"),
    os.path.join(ROOT, "core", "desktop", "windows-drivers", "out", "Release",
                 "auravaio_bridge.dll"),
    r"C:\Users\likr\Desktop\Projects\AuraDSP\bin\auravaio_bridge.dll",
    r"C:\Users\li\Desktop\Projects\AuraDSP\bin\auravaio_bridge.dll",
]
CANDS = [p for p in CANDS if p]

path = next((p for p in CANDS if os.path.exists(p)), None)
if not path:
    print("SKIP（auravaio_bridge.dll 不存在，未构建 windows-drivers）")
    sys.exit(0)

print(f"[SMOKE_VAIO] Using bridge: {path}")

b = ctypes.CDLL(path)
b.vaio_detect.restype = ctypes.c_int
b.vaio_start.restype = ctypes.c_int
b.vaio_stop.restype = ctypes.c_int
b.vaio_status.restype = ctypes.c_int
b.vaio_set_param.restype = ctypes.c_int
b.vaio_set_param_str.restype = ctypes.c_int
b.vaio_get_param.restype = ctypes.c_int
b.vaio_get_param_str.restype = ctypes.c_int
b.vaio_viz_read.restype = ctypes.c_int
b.vaio_bypass.restype = ctypes.c_int
b.vaio_test_start.restype = ctypes.c_int
b.vaio_test_stop.restype = ctypes.c_int

b.vaio_detect.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.vaio_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p]
b.vaio_status.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.vaio_set_param.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
b.vaio_set_param_str.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
b.vaio_get_param.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
b.vaio_get_param_str.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
b.vaio_viz_read.argtypes = [ctypes.c_void_p, ctypes.c_int]
b.vaio_bypass.argtypes = [ctypes.c_int]
b.vaio_test_start.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                              ctypes.c_int, ctypes.c_int]
b.vaio_test_stop.argtypes = []

fails = []


def check(name, cond, detail=""):
    tag = "PASS  " if cond else "FAIL  "
    print(tag + name + (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def get_status():
    buf = ctypes.create_string_buffer(4096)
    rc = b.vaio_status(buf, 4096)
    if rc <= 0:
        return {}
    try:
        return json.loads(buf.value.decode("utf-8", "replace"))
    except ValueError:
        return {}


def detect():
    buf = ctypes.create_string_buffer(8192)
    rc = b.vaio_detect(buf, 8192)
    if rc <= 0:
        return {}
    try:
        return json.loads(buf.value.decode("utf-8", "replace"))
    except ValueError:
        return {}


# 1. Detect 测试
det = detect()
check("detect 返回有效字典", isinstance(det, dict) and "found" in det)
check("detect 包含 endpoints 数组", isinstance(det.get("endpoints"), list))

driver_found = det.get("found", False)
print(f"[SMOKE_VAIO] Driver found: {driver_found}, endpoints count: {len(det.get('endpoints', []))}")

# 2. 状态查询测试（未运行态）
st0 = get_status()
check("未启动状态 running==false", st0.get("running") is False)

if not driver_found:
    print("[SMOKE_VAIO] AuraVaioDriver 未安装（非虚拟驱动环境），测试冷启动失败处理契约...")
    rc_fail = b.vaio_start(b"", b"", b"")
    check("未装驱动时 start 优雅返回负值", rc_fail < 0, f"rc={rc_fail}")
    st_fail = get_status()
    check("未装驱动 start 后 running 仍为 false", st_fail.get("running") is False)
    check("未装驱动 note 包含错误原因", len(st_fail.get("note", "")) > 0, st_fail.get("note", ""))
    print("\n[SMOKE_VAIO] Host 冷启动与检测契约测试完成（无驱动分支全通）")
    if fails:
        print(f"FAILED: {fails}")
        sys.exit(1)
    sys.exit(0)

# 3. 驱动已安装环境（如 Win10 / Win7 目标机）
print("[SMOKE_VAIO] 检测到已安装驱动，启动完整端到端测试...")
ENG_CANDS = [
    os.path.join(ROOT, "test", "auradsp_engine.dll"),
    os.path.join(ROOT, "windows", "out", "Release", "auradsp_engine.dll"),
    r"C:\Users\likr\Desktop\Projects\AuraDSP\bin\auradsp_engine.dll",
    r"C:\Users\li\Desktop\Projects\AuraDSP\bin\auradsp_engine.dll",
]
eng_path = next((p for p in ENG_CANDS if os.path.exists(p)), "")
print(f"[SMOKE_VAIO] Engine path: {eng_path}")

init_params = b"tube.gain=f6.0;bass.enable=i1"
rc_start = b.vaio_start(eng_path.encode("utf-8"), init_params, b"")
check("vaio_start rc==0", rc_start == 0, f"rc={rc_start}")

if rc_start != 0:
    st_err = get_status()
    print(f"FAIL: start failed with note: {st_err.get('note')}")
    fails.append("vaio_start")
    sys.exit(1)

# 4. 稳态运行检查
time.sleep(1.5)
st1 = get_status()
check("running==true", st1.get("running") is True)
check("engineOk==true", st1.get("engineOk") is True)
check("frames 累计增长", st1.get("frames", 0) > 0, f"frames={st1.get('frames')}")
check("采样率有效", st1.get("sr", 0) > 0, f"sr={st1.get('sr')}")
check("初始参数已生效", st1.get("paramsApplied", 0) >= 2, f"applied={st1.get('paramsApplied')}")

# 5. 实时参数下发与回读
f_val = ctypes.c_float(12.5)
rc_p = b.vaio_set_param(b"tube.gain", 1, ctypes.byref(f_val))
check("set_param float rc==0", rc_p == 0, f"rc={rc_p}")

out_f = ctypes.c_float(0.0)
rc_gp = b.vaio_get_param(b"tube.gain", 1, ctypes.byref(out_f))
check("get_param float rc==0", rc_gp == 0, f"rc={rc_gp}")
check("get_param float 读回一致", abs(out_f.value - 12.5) < 0.01, f"read={out_f.value}")

# 6. LiveProg 字符串参数通道
LP_CODE = "/* vaio smoke */\n@init\nx = 1;\n@sample\nspl0 = spl0;\nspl1 = spl1;\n"
rc_sp = b.vaio_set_param_str(b"liveprog.code", LP_CODE.encode("utf-8"), len(LP_CODE.encode("utf-8")))
check("set_param_str rc==0", rc_sp == 0, f"rc={rc_sp}")

str_buf = ctypes.create_string_buffer(512)
rc_gstr = b.vaio_get_param_str(b"liveprog.code", str_buf, 512)
check("get_param_str rc>0", rc_gstr > 0, f"bytes={rc_gstr}")

# 7. 可视化帧读取
# [Phase B] 2026-10-24 ABI v2：viz 帧 536B → 1600B（桥透传引擎帧）。
viz_buf = ctypes.create_string_buffer(1600)
viz_frames = b.vaio_viz_read(viz_buf, 1)
check("viz_read 能够读取帧", viz_frames >= 0, f"frames={viz_frames}")

# 8. 测试信号注入与旁路验证
rc_test = b.vaio_test_start(1, None, 0, 0, 0) # 440Hz sine
check("test_start rc==0", rc_test == 0, f"rc={rc_test}")
time.sleep(0.5)

st_test = get_status()
check("testKind==1", st_test.get("testKind") == 1)
check("注入信号后 peakIn > 0", st_test.get("peakIn", 0.0) > 0.01, f"peakIn={st_test.get('peakIn')}")

# 旁路切换
b.vaio_bypass(1)
st_bp = get_status()
check("bypass==1 生效", st_bp.get("bypass") == 1)

b.vaio_bypass(0)
st_nbp = get_status()
check("bypass==0 恢复", st_nbp.get("bypass") == 0)

b.vaio_test_stop()
st_stop_test = get_status()
check("test_stop 后 testKind==0", st_stop_test.get("testKind") == 0)

# 9. 停止桥
rc_stop = b.vaio_stop()
check("vaio_stop rc==0", rc_stop == 0, f"rc={rc_stop}")
st_end = get_status()
check("停止后 running==false", st_end.get("running") is False)

# 幂等停止验证
rc_stop2 = b.vaio_stop()
check("二次停止幂等 rc==0", rc_stop2 == 0, f"rc={rc_stop2}")

print("\n" + "="*50)
if fails:
    print(f"FAILED ({len(fails)} failures): {fails}")
    sys.exit(1)
else:
    print("ALL PASS! AuraVAIO Bridge 冒烟测试全部通过。")
