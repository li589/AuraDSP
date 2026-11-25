# -*- coding: utf-8 -*-
"""EEL2 矩阵内建的形状、维度失败与进程存活回归（Task 1 / C1）。

每个用例在独立子进程中加载引擎，并在子进程内独立 create/destroy；即使
当前实现在某个病理形状上访问违例，父进程仍能继续执行后续用例并汇总失败。
子进程另断言全部输出样本有限，父进程拒绝 ASan/UBSan 报告与超时。

用法：python test/smoke/smoke_eel_matrix_safety.py（退出码 0 = 全绿）
"""
import ctypes
import math
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CANDS = [
    os.environ.get("AURADSP_ENGINE_DLL", ""),
    os.path.join(ROOT, "test", "auradsp_engine.dll"),
    os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                 "auradsp_engine.dll"),
]
DLL = next((p for p in CANDS if p and os.path.exists(p)), None)
SR, N = 48000.0, 256

NEGATIVE_TRANSPOSE = """@init
sink = 0;
@sample
transpose(0, -2, -8, 16);
spl0 = spl0;
spl1 = spl1;
"""

NEGATIVE_INV = """@init
sink = 0;
@sample
inv(0, -2, -2, 16);
spl0 = spl0;
spl1 = spl1;
"""

MISMATCHED_DIVIDE = """@init
sink = 0;
@sample
mldivide(0, 2, 2, 16, 3, 1, 32, 48);
spl0 = spl0;
spl1 = spl1;
"""

ZERO_RANK = """@init
sink = 0;
@sample
rank(0, 0, 0);
spl0 = spl0;
spl1 = spl1;
"""

MISMATCHED_DIVIDE_ZERO_INFO = """@init
gmem[48] = 7;
gmem[49] = 7;
@sample
mldivide(0, 2, 2, 16, 3, 1, 32, 48);
spl0 = gmem[48];
spl1 = gmem[49];
"""


def zero_info_script(call):
    """预置合法 outputInfo，钉住所有后续失败出口必须发布 {0,0}。"""
    return """@init
gmem[48] = 7;
gmem[49] = 7;
@sample
%s;
spl0 = gmem[48];
spl1 = gmem[49];
""" % call


# 2^24-1 是池内最后一个元素；多元素矩阵从该基址开始必触发 P-057 跨度拒绝，
# 但独立的 gmem[48:50] 输出信息仍合法，因此必须清零。
EARLY_FAILURE_ZERO_INFO_CASES = [
    ("negative_pinv_zero_info", "pinv_svd(0, -2, 2, 16, 48)"),
    ("pinv_input_span_zero_info", "pinv_svd(16777215, 2, 2, 16, 48)"),
    ("pinv_output_span_zero_info", "pinv_svd(0, 2, 2, 16777215, 48)"),
    ("negative_pinv_fast_zero_info", "pinv_fast(0, -2, 2, 16, 48)"),
    ("pinv_fast_input_span_zero_info", "pinv_fast(16777215, 2, 2, 16, 48)"),
    ("pinv_fast_output_span_zero_info", "pinv_fast(0, 2, 2, 16777215, 48)"),
    ("negative_mldivide_zero_info", "mldivide(0, -2, 2, 16, 2, 1, 32, 48)"),
    ("mldivide_lhs_span_zero_info", "mldivide(16777215, 2, 2, 16, 2, 1, 32, 48)"),
    ("mldivide_rhs_span_zero_info", "mldivide(0, 2, 2, 16777215, 2, 1, 32, 48)"),
    ("mldivide_output_span_zero_info", "mldivide(0, 2, 2, 16, 2, 1, 16777215, 48)"),
    ("negative_mrdivide_zero_info", "mrdivide(0, -1, 2, 16, 2, 2, 32, 48)"),
    ("mrdivide_lhs_span_zero_info", "mrdivide(16777215, 1, 2, 16, 2, 2, 32, 48)"),
    ("mrdivide_rhs_span_zero_info", "mrdivide(0, 1, 2, 16777215, 2, 2, 32, 48)"),
    ("mrdivide_output_span_zero_info", "mrdivide(0, 1, 2, 16, 2, 2, 16777215, 48)"),
]

CASES = [
    ("negative_transpose", NEGATIVE_TRANSPOSE, False),
    ("negative_inv", NEGATIVE_INV, False),
    ("mismatched_divide", MISMATCHED_DIVIDE, False),
    ("zero_rank", ZERO_RANK, False),
    ("mismatched_divide_zero_info", MISMATCHED_DIVIDE_ZERO_INFO, True),
] + [(name, zero_info_script(call), True)
     for name, call in EARLY_FAILURE_ZERO_INFO_CASES]


def run_case(name, script, expect_zero_output):
    if not DLL:
        print("SKIP（auradsp_engine.dll 不存在）")
        return 0

    dll = ctypes.CDLL(DLL)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_set_param.restype = ctypes.c_int
    dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_void_p, ctypes.c_uint32]
    dll.auradsp_get_param.restype = ctypes.c_int
    dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                      ctypes.c_void_p, ctypes.c_uint32]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_last_error.restype = ctypes.c_char_p
    dll.auradsp_last_error.argtypes = [ctypes.c_void_p]

    def set_i(handle, pid, value):
        return dll.auradsp_set_param(handle, pid.encode(),
                                     ctypes.byref(ctypes.c_int32(value)), 4)

    def set_str(handle, pid, value):
        raw = value.encode("utf-8")
        return dll.auradsp_set_param(handle, pid.encode(),
                                     (ctypes.c_char * len(raw)).from_buffer_copy(raw),
                                     len(raw))

    def get_i(handle, pid):
        value = ctypes.c_int32()
        dll.auradsp_get_param(handle, pid.encode(), ctypes.byref(value), 4)
        return value.value

    handle = dll.auradsp_create(SR, N)
    if not handle:
        print("FAIL  %s: auradsp_create returned NULL" % name)
        return 1
    try:
        rc = set_str(handle, "liveprog.code", script)
        status = get_i(handle, "liveprog.status")
        if rc != 0 or status != 1:
            error = dll.auradsp_last_error(handle)
            detail = error.decode("utf-8", "replace") if error else ""
            print("FAIL  %s: compile rc=%d status=%d error=%r" %
                  (name, rc, status, detail))
            return 1
        if set_i(handle, "liveprog.enable", 1) != 0:
            print("FAIL  %s: liveprog.enable rejected" % name)
            return 1

        buf = (ctypes.c_float * (N * 2))()
        out = (ctypes.c_float * (N * 2))()
        for i in range(N):
            sample = 0.1 * math.sin(2 * math.pi * 1000.0 * i / SR)
            buf[i * 2] = sample
            buf[i * 2 + 1] = sample
        for _ in range(2):
            dll.auradsp_process(handle, buf, out, N)
        if not all(math.isfinite(out[i]) for i in range(N * 2)):
            print("FAIL  %s: non-finite audio output" % name)
            return 1
        if expect_zero_output and any(out[i] != 0.0 for i in range(N * 2)):
            print("FAIL  %s: numerical failure did not publish Y_size={0,0}" % name)
            return 1
        print("PASS  %s" % name)
        return 0
    finally:
        dll.auradsp_destroy(handle)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--run-case":
        name = sys.argv[2]
        index = int(sys.argv[3])
        case_name, script, expect_zero = CASES[index]
        if name != case_name:
            print("FAIL  invalid case selector")
            return 2
        return run_case(case_name, script, expect_zero)
    if len(sys.argv) != 1:
        print("usage: %s" % os.path.basename(__file__))
        return 2
    if not DLL:
        print("SKIP（auradsp_engine.dll 不存在）")
        return 0

    failures = []
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    for index, (name, _, _) in enumerate(CASES):
        try:
            result = subprocess.run(
                [sys.executable, os.path.abspath(__file__), "--run-case", name, str(index)],
                cwd=ROOT, env=env, capture_output=True, text=True, timeout=30,
                check=False)
            output = (result.stdout or "") + (result.stderr or "")
            bounded = output if len(output) <= 4000 else output[:4000] + "\n[truncated]"
            lowered = output.lower()
            sanitizer = any(token in lowered for token in (
                "addresssanitizer", "undefinedbehaviorsanitizer", "asan:", "ubsan:",
                "runtime error:"))
            if result.returncode == 0 and not sanitizer:
                print("PASS  %s" % name)
            else:
                failures.append(name)
                print("FAIL  %s: rc=%d sanitizer=%s" % (name, result.returncode, sanitizer))
                if bounded.strip():
                    print(bounded.rstrip())
        except subprocess.TimeoutExpired as exc:
            failures.append(name)
            print("FAIL  %s: timeout after 30s" % name)
            output = (exc.stdout or b"")
            if isinstance(output, bytes):
                output = output.decode("utf-8", errors="replace")
            if output:
                print(output[:4000])

    print("=" * 46)
    if failures:
        print("FAILURES: %s" % failures)
        return 1
    print("ALL PASS：EEL2 matrix shape and failure contracts")
    return 0


if __name__ == "__main__":
    sys.exit(main())
