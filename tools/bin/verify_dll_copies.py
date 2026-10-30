# -*- coding: utf-8 -*-
"""auradsp_engine.dll 分发 + 验证（P0：单向政策）。

正式位置只剩 3 处：
  真相源  core/desktop/windows/out/Release/auradsp_engine.dll（构建产物）
  运行副本 app/auradsp_app/windows/runner/auradsp_engine.dll（随 flutter 打包）
  运行副本 test/auradsp_engine.dll（smoke 用）
其余散落副本已删除。流程：真相源 → 分发到 2 运行副本 → 功能断言全验。
不信时间戳/哈希，直接跑功能断言：eq_in_spectrum 必须非零。
这能区分「文件是旧的」和「文件是新的但进程里跑的是旧的」。
"""
import ctypes
import glob
import os
import random
import shutil
import sys

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
BANDS = 32

TRUTH = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                     "auradsp_engine.dll")
RUNTIME = [
    os.path.join(ROOT, "app", "auradsp_app", "windows", "runner",
                 "auradsp_engine.dll"),
    os.path.join(ROOT, "test", "auradsp_engine.dll"),
]


# --- VizFrame 单一来源（§7-1 ABI 镜像门禁）---
# ctypes 镜像只在 tools/bin/viz_frame.py 定义一次，这里不再手抄。
# 手抄件的危险：头文件 sizeof 改了却漏改某个脚本 → 脚本按旧尺寸申请缓冲、
# 引擎按新尺寸写 → 静默堆越界（审查 A1/A2/A3 三处即此）。viz_frame 导入时
# 自带 sizeof / ABI 版本哨兵，出错就地抛 AssertionError。
_VIZ_ROOT = os.path.dirname(os.path.abspath(__file__))
while not os.path.isfile(os.path.join(_VIZ_ROOT, 'tools', 'bin', 'viz_frame.py')):
    _VIZ_PARENT = os.path.dirname(_VIZ_ROOT)
    if _VIZ_PARENT == _VIZ_ROOT:
        raise ImportError('未找到 tools/bin/viz_frame.py（VizFrame 的唯一定义处）')
    _VIZ_ROOT = _VIZ_PARENT
if os.path.join(_VIZ_ROOT, 'tools', 'bin') not in sys.path:
    sys.path.insert(0, os.path.join(_VIZ_ROOT, 'tools', 'bin'))
from viz_frame import VizFrame  # noqa: E402


def check(path):
    dll = ctypes.CDLL(path)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_set_param.restype = ctypes.c_int
    dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_void_p, ctypes.c_uint32]
    dll.auradsp_viz_read.restype = ctypes.c_uint32
    dll.auradsp_viz_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(VizFrame),
                                     ctypes.c_uint32]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_version.restype = ctypes.c_char_p

    h = ctypes.c_void_p(dll.auradsp_create(48000.0, 1024))
    if not h:
        return None, "create 失败"
    cb = b"60:9;300:0;1000:-9;8000:0;16000:9"
    pb = (ctypes.c_char * len(cb)).from_buffer_copy(cb)
    dll.auradsp_set_param(h, b"eq.curve", pb, len(cb))
    dll.auradsp_set_param(h, b"eq.enable", ctypes.byref(ctypes.c_int32(1)), 4)
    rng = random.Random(7)
    bi = (ctypes.c_float * 2048)()
    bo = (ctypes.c_float * 2048)()
    vb = (VizFrame * 8)()
    peak_in = 0.0
    for _ in range(300):
        for i in range(2048):
            bi[i] = rng.uniform(-0.3, 0.3)
        dll.auradsp_process(h, bi, bo, 1024)
        n = dll.auradsp_viz_read(h, vb, 8)
        if n > 0:
            peak_in = max(peak_in, max(vb[n - 1].eq_in_spectrum))
    ver = dll.auradsp_version().decode(errors="replace")
    dll.auradsp_destroy(h)
    return (peak_in, ver), None


paths = sorted(glob.glob(os.path.join(ROOT, "**", "auradsp_engine.dll"),
                         recursive=True))
if not paths:
    print("没找到任何副本")
    sys.exit(1)

# P0 单向分发：真相源 → 运行副本（App 运行时锁住会跳过并报错，不静默）。
print("== 分发 ==")
for dst in RUNTIME:
    try:
        shutil.copyfile(TRUTH, dst)
        print(f"  OK {os.path.relpath(dst, ROOT)}")
    except OSError as e:
        print(f"  LOCKED（App 可能在跑，先退出再重跑） {os.path.relpath(dst, ROOT)}: {e}")
        sys.exit(2)

# Phase 4：host 必须始终与 engine DLL 同目录（客户端按 DLL 路径解析）。
HOST_TRUTH = os.path.join(os.path.dirname(TRUTH), "auradsp_plugin_host.exe")
if os.path.exists(HOST_TRUTH):
    for dst in RUNTIME:
        host_dst = os.path.join(os.path.dirname(dst), "auradsp_plugin_host.exe")
        try:
            shutil.copyfile(HOST_TRUTH, host_dst)
            print(f"  OK {os.path.relpath(host_dst, ROOT)}")
        except OSError as e:
            print(f"  LOCKED（App 可能在跑，先退出再重跑） {os.path.relpath(host_dst, ROOT)}: {e}")
            sys.exit(2)

print("%-62s %-10s %-8s %s" % ("path", "eq_in", "ver", "verdict"))
print("-" * 100)
allgood = True
for p in paths:
    res, err = check(p)
    rel = p.replace(ROOT + os.sep, "")
    if err:
        print("%-62s %-10s %-8s %s" % (rel, "-", "-", "ERR " + err))
        allgood = False
        continue
    peak_in, ver = res
    ok = peak_in > 0.05
    allgood = allgood and ok
    print("%-62s %-10.4f %-8s %s" % (rel, peak_in, ver,
                                       "NEW (含 EQ tap)" if ok else "OLD (无 EQ tap)"))

print("-" * 100)
print("全部为新版" if allgood else "存在旧版副本")

# VB 桥分发（05）：真相源 → 同 2 处运行副本；仅校验加载+导出存在，
# 功能断言归 smoke_vm_bridge.py（需 Voicemeeter 在线）。
BRIDGE_TRUTH = os.path.join(ROOT, "core", "desktop", "windows-drivers", "out",
                            "Release", "auravm_bridge.dll")
BRIDGE_RUNTIME = [
    os.path.join(ROOT, "app", "auradsp_app", "windows", "runner",
                 "auravm_bridge.dll"),
    os.path.join(ROOT, "test", "auravm_bridge.dll"),
]
print("== VB 桥分发 ==")
if os.path.exists(BRIDGE_TRUTH):
    for dst in BRIDGE_RUNTIME:
        try:
            shutil.copyfile(BRIDGE_TRUTH, dst)
            print(f"  OK {os.path.relpath(dst, ROOT)}")
        except OSError as e:
            print(f"  LOCKED（App 可能在跑，先退出再重跑） {os.path.relpath(dst, ROOT)}: {e}")
            sys.exit(2)
    try:
        b = ctypes.CDLL(BRIDGE_TRUTH)
        # a25db9e（旧前缀下线）后通用面收敛为 ab_*；vb_* 仅保留 VB 专属
        # 扩展（test_change/set_bus_mask/plugin_*）与 ABI 协商导出。
        # 此表曾漏改导致 F6 门禁恒红（vb_detect 等 12 个已删符号）。
        for sym in ("ab_detect", "ab_start", "ab_stop", "ab_status",
                    "ab_set_param", "ab_set_param_str",
                    "ab_get_param", "ab_get_param_str",
                    "ab_viz_read", "ab_bypass",
                    "ab_test_start", "ab_test_stop",
                    "vb_abi", "vb_test_change", "vb_set_bus_mask",
                    # Z12 守卫的测试注入口（smoke_vm_protect.py 用）
                    "vb_plugin_auto_protect", "vb_protect_test"):
            getattr(b, sym)
        print("  导出表 18/18 OK")
    except OSError as e:
        print(f"  桥加载失败: {e}")
        sys.exit(1)
    except AttributeError as e:
        # 缺符号抛 AttributeError（非 OSError），此前未捕获会裸 traceback。
        print(f"  桥导出缺失: {e}")
        sys.exit(1)
else:
    print("  跳过（真相源未构建）")

# ASIO 桥分发（04，Phase 3）：真相源 → 同 2 处运行副本；仅校验加载+导出存在，
# 功能断言归 smoke_asio_bridge.py（需 ASIO 驱动在线）。
ASIO_TRUTH = os.path.join(ROOT, "core", "desktop", "windows-drivers", "out",
                          "Release", "auraasio_bridge.dll")
ASIO_RUNTIME = [
    os.path.join(ROOT, "app", "auradsp_app", "windows", "runner",
                 "auraasio_bridge.dll"),
    os.path.join(ROOT, "test", "auraasio_bridge.dll"),
]
print("== ASIO 桥分发 ==")
if os.path.exists(ASIO_TRUTH):
    for dst in ASIO_RUNTIME:
        try:
            shutil.copyfile(ASIO_TRUTH, dst)
            print(f"  OK {os.path.relpath(dst, ROOT)}")
        except OSError as e:
            print(f"  LOCKED（App 可能在跑，先退出再重跑） {os.path.relpath(dst, ROOT)}: {e}")
            sys.exit(2)
    try:
        b = ctypes.CDLL(ASIO_TRUTH)
        # 同 VB 段（a25db9e 旧前缀收敛）：通用面 ab_*；asio_* 仅保留
        # 本桥专属扩展（plugin_slot_*/abi）。asio_start_ex 已随收敛删除。
        for sym in ("ab_abi_version", "ab_capabilities",
                    "ab_detect", "ab_start", "ab_stop", "ab_status",
                    "ab_set_param", "ab_set_param_str",
                    "ab_get_param", "ab_get_param_str",
                    "ab_viz_read", "ab_bypass",
                    "ab_test_start", "ab_test_stop",
                    # bridge_plugin_ffi.dart 硬 lookup 的本桥专属扩展
                    "asio_plugin_slot_set_channels",
                    "asio_plugin_slot_get_channels",
                    # §7-2（P-028）桥 ABI 协商导出
                    "asio_abi"):
            getattr(b, sym)
        print("  导出表 18/18 OK")
    except OSError as e:
        print(f"  桥加载失败: {e}")
        sys.exit(1)
    except AttributeError as e:
        print(f"  桥导出缺失: {e}")
        sys.exit(1)
else:
    print("  跳过（真相源未构建）")

sys.exit(0 if allgood else 1)