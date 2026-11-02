# -*- coding: utf-8 -*-
"""smoke_linux_engine_process — Linux 引擎信号链功能门禁（S1，2026-11-01）。

口径与 tools/bin/verify_dll_copies.py 的功能断言一致：不信文件存在/时间戳，
直接跑信号链 —— EQ 曲线使能后灌 300 块噪声，viz 的 eq_in_spectrum 峰值必须
> 0.05（证明 process 真实执行而非空转），且 process 输出峰值非零。

签名注意（S2 复盘）：auradsp_process 是 **4 参** (h, in, out, frames) 且
返回 void。S2 阶段的临时验证脚本误用 3 参调用、把 frames 当 out 指针传入，
process 因 frames 寄存器为垃圾值提前返回、并未真正处理，"rc=0 PASS" 的
证据不成立；结论后由本门禁的正确口径复验通过（eq_in 峰值 0.6502）。
新写 ctypes 调用务必照 auradsp_engine.h 声明 argtypes。

产物经 test/engine_artifact.py 解析；产物缺失时按仓库惯例打印 SKIP 退出 0
（未构建不等于失败，构建由 S4 CI 顺序保证）。
"""
import ctypes
import os
import random
import sys

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
sys.path.insert(0, TEST_DIR)
sys.path.insert(0, os.path.join(ROOT, "tools", "bin"))

from engine_artifact import find_engine_lib  # noqa: E402

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def main():
    lib_path = find_engine_lib()
    if not os.path.isfile(lib_path):
        print(f"SKIP: 引擎产物不存在（{lib_path}），先构建 Linux 引擎")
        return 0
    from viz_frame import VizFrame

    dll = ctypes.CDLL(lib_path)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.restype = None
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_set_param.restype = ctypes.c_int
    dll.auradsp_set_param.argtypes = [
        ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
    dll.auradsp_viz_read.restype = ctypes.c_uint32
    dll.auradsp_viz_read.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(VizFrame), ctypes.c_uint32]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_version.restype = ctypes.c_char_p

    ver = dll.auradsp_version().decode(errors="replace")
    print(f"engine: {lib_path} (version {ver})")
    h = ctypes.c_void_p(dll.auradsp_create(48000.0, 1024))
    check(bool(h), "auradsp_create(48000, 1024) 非空")
    if not h:
        return 1
    cb = b"60:9;300:0;1000:-9;8000:0;16000:9"
    pb = (ctypes.c_char * len(cb)).from_buffer_copy(cb)
    dll.auradsp_set_param(h, b"eq.curve", pb, len(cb))
    dll.auradsp_set_param(h, b"eq.enable",
                          ctypes.byref(ctypes.c_int32(1)), 4)
    rng = random.Random(7)
    bi = (ctypes.c_float * 2048)()
    bo = (ctypes.c_float * 2048)()
    vb = (VizFrame * 8)()
    peak_in = 0.0
    out_peak = 0.0
    for _ in range(300):
        for i in range(2048):
            bi[i] = rng.uniform(-0.3, 0.3)
        dll.auradsp_process(h, bi, bo, 1024)
        out_peak = max(out_peak, max(abs(x) for x in bo))
        n = dll.auradsp_viz_read(h, vb, 8)
        if n > 0:
            peak_in = max(peak_in, max(vb[n - 1].eq_in_spectrum))
    dll.auradsp_destroy(h)
    check(peak_in > 0.05,
          f"eq_in_spectrum 峰值 {peak_in:.4f} > 0.05（信号链真实执行）")
    check(out_peak > 0.05,
          f"process 输出峰值 {out_peak:.4f} > 0.05（in→out 真实处理）")
    print("smoke_linux_engine_process:", "FAIL" if FAILS else "PASS")
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
