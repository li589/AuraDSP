# -*- coding: utf-8 -*-
"""EEL2 矩阵安全、合法 @init 预计算与 RT 拒绝回归（Task 1 / C1 + Task 5 / H3）。

每个用例在独立子进程中加载引擎，并在子进程内独立 create/destroy；即使
当前实现在某个病理形状上访问违例，父进程仍能继续执行后续用例并汇总失败。
子进程断言输出有限；RT 用例另断言 EEL_MATRIX_RT_FORBIDDEN 与固定墙钟上限。
父进程拒绝 ASan/UBSan 报告与超时。

用法：python test/smoke/smoke_eel_matrix_safety.py（退出码 0 = 全绿）
"""
import ctypes
import math
import os
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
CANDS = [
    os.environ.get("AURADSP_ENGINE_DLL", ""),
    os.path.join(ROOT, "test", "auradsp_engine.dll"),
    os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                 "auradsp_engine.dll"),
]
DLL = next((p for p in CANDS if p and os.path.exists(p)), None)
SR, N = 48000.0, 256
EEL_MATRIX_RT_FORBIDDEN = -10.0
RT_PROCESS_LIMIT_SECONDS = 3.0

# P-057/P-058 的形状/分配失败契约在合法 @init 路径验证；@sample 只回读结果。
NEGATIVE_TRANSPOSE = """@init
sink = 0;
transpose(0, -2, -8, 16);
@sample
spl0 = spl0;
spl1 = spl1;
"""

NEGATIVE_INV = """@init
sink = 0;
inv(0, -2, -2, 16);
@sample
spl0 = spl0;
spl1 = spl1;
"""

MISMATCHED_DIVIDE = """@init
sink = 0;
mldivide(0, 2, 2, 16, 3, 1, 32, 48);
@sample
spl0 = spl0;
spl1 = spl1;
"""

ZERO_RANK = """@init
sink = 0;
rank(0, 0, 0);
@sample
spl0 = spl0;
spl1 = spl1;
"""

MISMATCHED_DIVIDE_ZERO_INFO = """@init
gmem[48] = 7;
gmem[49] = 7;
mldivide(0, 2, 2, 16, 3, 1, 32, 48);
@sample
spl0 = gmem[48];
spl1 = gmem[49];
"""


def zero_info_script(call):
    """预置合法 outputInfo，钉住所有后续失败出口必须发布 {0,0}。"""
    return """@init
gmem[48] = 7;
gmem[49] = 7;
%s;
@sample
spl0 = gmem[48];
spl1 = gmem[49];
""" % call


RT_MATRIX = """@init
sink = 0;
@sample
det(0, 64, 64);
spl0 = spl0;
spl1 = spl1;
"""


def rt_det_script(section):
    if section == "sample":
        return """@init
sink = 0;
@sample
sink = det(0, 64, 64);
spl0 = sink;
spl1 = 0;
"""
    return """@init
sink = 0;
@%s
sink = det(0, 64, 64);
@sample
spl0 = sink;
spl1 = 0;
""" % section


LEGAL_INIT_MATRIX = """@init
gmem[0] = 1;
gmem[1] = 0;
gmem[2] = 0;
gmem[3] = 1;
value = det(0, 2, 2);
@sample
spl0 = value;
spl1 = value;
"""


def rt_call_script(call):
    return """@init
sink = 0;
@sample
sink = %s;
spl0 = sink;
spl1 = 0;
""" % call


# 编译路径会额外执行一次 @slider。该次执行也属于 @slider 语义，必须拒绝；
# transpose 的写回副作用用于观察编译初跑是否越过 guard（正常 RT 每块还会再跑）。
SLIDER_INIT_MATRIX = """@init
gmem[16] = 7;
@slider
transpose(0, 2, 2, 16);
@sample
spl0 = gmem[16] == 7 ? -10 : 0;
spl1 = 0;
"""


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

def make_case(name, script, *, channels=2, expect_zero=False,
              expect_forbidden=False, expect_value=None, geometry=False,
              restore=False, limit=None):
    return {
        "name": name,
        "script": script,
        "channels": channels,
        "expect_zero": expect_zero,
        "expect_forbidden": expect_forbidden,
        "expect_value": expect_value,
        "geometry": geometry,
        "restore": restore,
        "limit": limit,
    }


SAFETY_CASES = [
    make_case("negative_transpose", NEGATIVE_TRANSPOSE),
    make_case("negative_inv", NEGATIVE_INV),
    make_case("mismatched_divide", MISMATCHED_DIVIDE),
    make_case("zero_rank", ZERO_RANK),
    make_case("mismatched_divide_zero_info", MISMATCHED_DIVIDE_ZERO_INFO,
              expect_zero=True),
] + [make_case(name, zero_info_script(call), expect_zero=True)
     for name, call in EARLY_FAILURE_ZERO_INFO_CASES]

CASES = SAFETY_CASES + [
    make_case("rt_matrix_required_fixture", RT_MATRIX,
              limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_det_sample_stereo", rt_det_script("sample"),
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_det_block_stereo", rt_det_script("block"),
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_det_slider_stereo", rt_det_script("slider"),
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("slider_compile_stereo", SLIDER_INIT_MATRIX,
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("slider_compile_mc8", SLIDER_INIT_MATRIX, channels=8,
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_det_geometry_stereo", rt_det_script("sample"),
              expect_forbidden=True, geometry=True,
              limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_det_sample_mc8", rt_det_script("sample"), channels=8,
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_det_block_mc8", rt_det_script("block"), channels=8,
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_transpose_sample", rt_call_script("transpose(0, 2, 2, 16)"),
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_unwrap_sample", rt_call_script("unwrap(0, 4, 3.14159265)"),
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_mldivide_sample",
              rt_call_script("mldivide(0, 2, 2, 16, 2, 1, 32, 48)"),
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_linspace_sample", rt_call_script("linspace(0, 1, 4, 16)"),
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("rt_peakfinder_sample",
              rt_call_script("peakFinder(0, 4, 0, 0, 16)"),
              expect_forbidden=True, limit=RT_PROCESS_LIMIT_SECONDS),
    make_case("legal_init_matrix_stereo", LEGAL_INIT_MATRIX, expect_value=1.0),
    make_case("legal_init_matrix_mc8", LEGAL_INIT_MATRIX, channels=8,
              expect_value=1.0),
    make_case("rt_guard_restore_after_process", rt_det_script("sample"),
              restore=True, expect_value=1.0,
              limit=RT_PROCESS_LIMIT_SECONDS),
]


def run_case(case):
    name = case["name"]
    script = case["script"]
    channels = case["channels"]
    if not DLL:
        print("SKIP（auradsp_engine.dll 不存在）")
        return 0

    class Geometry(ctypes.Structure):
        _fields_ = [("generation", ctypes.c_uint64),
                    ("channels", ctypes.c_int32),
                    ("mode", ctypes.c_int32)]

    dll = ctypes.CDLL(DLL)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_process_geometry.restype = ctypes.c_int
    dll.auradsp_process_geometry.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int, ctypes.POINTER(Geometry)]
    dll.auradsp_get_active_geometry.restype = ctypes.c_int
    dll.auradsp_get_active_geometry.argtypes = [ctypes.c_void_p,
                                                ctypes.POINTER(Geometry)]
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
        # 隔离链尾限幅器，直接观察 EEL 返回值与合法 @init 预计算值。
        if set_i(handle, "limiter.enable", 0) != 0:
            print("FAIL  %s: limiter.enable rejected" % name)
            return 1
        if channels != 2:
            if set_i(handle, "channels.count", channels) != 0:
                print("FAIL  %s: channels.count rejected" % name)
                return 1
            if set_i(handle, "channels.mode", 1) != 0:
                print("FAIL  %s: channels.mode rejected" % name)
                return 1
        prefix = "liveprogmc" if channels > 2 else "liveprog"

        def compile_and_enable(code):
            rc = set_str(handle, prefix + ".code", code)
            status = get_i(handle, prefix + ".status")
            if rc != 0 or status != 1:
                error = dll.auradsp_last_error(handle)
                detail = error.decode("utf-8", "replace") if error else ""
                print("FAIL  %s: compile rc=%d status=%d error=%r" %
                      (name, rc, status, detail))
                return False
            if set_i(handle, prefix + ".enable", 1) != 0:
                print("FAIL  %s: %s.enable rejected" % (name, prefix))
                return False
            return True

        if not compile_and_enable(script):
            return 1

        expected = Geometry()
        if case["geometry"]:
            if dll.auradsp_get_active_geometry(handle, ctypes.byref(expected)) != 0:
                print("FAIL  %s: active geometry query failed" % name)
                return 1

        total = N * channels
        buf = (ctypes.c_float * total)()
        out = (ctypes.c_float * total)()
        for i in range(N):
            sample = 0.1 * math.sin(2 * math.pi * 1000.0 * i / SR)
            for c in range(channels):
                buf[i * channels + c] = sample

        def process_blocks():
            started = time.monotonic()
            for _ in range(2):
                if case["geometry"]:
                    rc = dll.auradsp_process_geometry(
                        handle, buf, out, N, ctypes.byref(expected))
                    if rc != 0:
                        print("FAIL  %s: process_geometry rc=%d" % (name, rc))
                        return None
                else:
                    dll.auradsp_process(handle, buf, out, N)
            return time.monotonic() - started

        def check_finite():
            if not all(math.isfinite(out[i]) for i in range(total)):
                print("FAIL  %s: non-finite audio output" % name)
                return False
            return True

        def check_first_channels(want, label):
            for i in range(N):
                if not math.isclose(out[i * channels], want, rel_tol=0.0,
                                    abs_tol=1e-6):
                    print("FAIL  %s: %s got %r, want %r" %
                          (name, label, out[i * channels], want))
                    return False
                if out[i * channels + 1] != 0.0:
                    print("FAIL  %s: %s second channel not zero" % (name, label))
                    return False
            return True

        elapsed = process_blocks()
        if elapsed is None:
            return 1
        if case["restore"]:
            if not check_finite() or not check_first_channels(
                    EEL_MATRIX_RT_FORBIDDEN, "RT rejection"):
                return 1
            if not compile_and_enable(LEGAL_INIT_MATRIX):
                return 1
            restored_elapsed = process_blocks()
            if restored_elapsed is None:
                return 1
            elapsed += restored_elapsed

        if not check_finite():
            return 1
        if case["expect_zero"] and any(out[i] != 0.0 for i in range(total)):
            print("FAIL  %s: numerical failure did not publish Y_size={0,0}" % name)
            return 1
        if case["expect_forbidden"] and not check_first_channels(
                EEL_MATRIX_RT_FORBIDDEN, "RT rejection"):
            return 1
        if case["expect_value"] is not None:
            # 合法 @init 用例两个声道都回读预计算结果；RT 用例第二声道固定为 0。
            if case["expect_value"] == 0.0:
                ok = check_first_channels(0.0, "zero output")
            else:
                ok = True
                for i in range(N):
                    for c in range(min(2, channels)):
                        if not math.isclose(out[i * channels + c],
                                            case["expect_value"], rel_tol=0.0,
                                            abs_tol=1e-6):
                            print("FAIL  %s: @init value got %r, want %r" %
                                  (name, out[i * channels + c],
                                   case["expect_value"]))
                            ok = False
                            break
                    if not ok:
                        break
            if not ok:
                return 1
        if case["limit"] is not None and elapsed > case["limit"]:
            print("FAIL  %s: process took %.3fs, limit %.3fs" %
                  (name, elapsed, case["limit"]))
            return 1
        print("PASS  %s" % name)
        return 0
    finally:
        dll.auradsp_destroy(handle)


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "--run-case":
        name = sys.argv[2]
        index = int(sys.argv[3])
        if index < 0 or index >= len(CASES):
            print("FAIL  invalid case selector")
            return 2
        case = CASES[index]
        if name != case["name"]:
            print("FAIL  invalid case selector")
            return 2
        return run_case(case)
    if len(sys.argv) != 1:
        print("usage: %s" % os.path.basename(__file__))
        return 2
    if not DLL:
        print("SKIP（auradsp_engine.dll 不存在）")
        return 0

    failures = []
    env = os.environ.copy()
    env["PYTHONIOENCODING"] = "utf-8"
    for index, case in enumerate(CASES):
        name = case["name"]
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
    print("ALL PASS：EEL2 matrix safety, @init precompute and RT rejection")
    return 0


if __name__ == "__main__":
    sys.exit(main())
