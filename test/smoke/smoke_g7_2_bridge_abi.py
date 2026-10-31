# -*- coding: utf-8 -*-
"""smoke_g7_2_bridge_abi.py — §7-2 桥 ABI 协商冒烟（P-028）。

审查原话：「三桥增加 *_abi() 导出或给 viz_read 加 frame_bytes 入参；
桥加载引擎后校验 auradsp_abi()（当前三桥全目录无 auradsp_abi 调用）」。

分层：
  [A] 清单层：abi_consistency.py --bridges-only 全绿（.def ↔ 头 ↔ Dart 1:1
      + B4 常量联动 + B5 桥实现引用 auradsp_abi）。
  [B] 活体层：三桥真实 DLL 各自 asio_abi()/vaio_abi()/vb_abi() == 引擎
      auradsp_abi() == 2（同代际才允许解析 viz 帧）。
  [C] 行为层（核心，反向验证靶）：g++ 合成假引擎 DLL——桩 create/process/
      destroy，仅 auradsp_abi 返回值可控：
        C1 假 ABI=999 → asio_start 必须拒绝且 note 含 engine-abi-mismatch
           （pre-fix 无校验时假引擎被照单全收，此断言红）；
        C2 假 ABI=2  → 引擎门放行（rc==0 或因驱动被占 open-failed，
           但 note 绝不含 abi-mismatch——证明拒绝确实由 ABI 门触发，
           不是"假 DLL 一律拒"）。C2 若真跑起来收尾 asio_stop。
"""
import ctypes
import json
import os
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXPECTED_ABI = 2

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def note_skip(name):
    print(f"NOTE  {name}")


# ---- [A] 清单层 ----
r = subprocess.run([sys.executable, os.path.join(ROOT, "tools", "bin",
                                                  "abi_consistency.py"),
                    "--bridges-only"],
                   capture_output=True, text=True, cwd=ROOT)
check("[A] abi_consistency --bridges-only 全绿", r.returncode == 0,
      (r.stdout + r.stderr).strip().splitlines()[-1] if r.returncode else "3 桥 103 符号")

# ---- [B] 活体层 ----
BRIDGES = [
    ("asio", "auraasio_bridge.dll", "asio_abi"),
    ("vaio", "auravaio_bridge.dll", "vaio_abi"),
    ("vb", "auravm_bridge.dll", "vb_abi"),
]
engine_paths = [
    os.path.join(ROOT, "test", "auradsp_engine.dll"),
    os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                 "auradsp_engine.dll"),
]
eng_path = next((p for p in engine_paths if os.path.exists(p)), None)
if not eng_path:
    note_skip("[B] auradsp_engine.dll 不存在，活体层降级")
else:
    eng = ctypes.CDLL(eng_path)
    eng.auradsp_abi.restype = ctypes.c_uint32
    eng.auradsp_abi.argtypes = []
    check("[B] 引擎 auradsp_abi() == 2", eng.auradsp_abi() == EXPECTED_ABI,
          f"got {eng.auradsp_abi()}")

bridge_abi_seen = 0
for _prefix, dll, fn_name in BRIDGES:
    cands = [
        os.path.join(ROOT, "core", "desktop", "windows-drivers", "out",
                     "Release", dll),
        os.path.join(ROOT, "test", dll),
    ]
    p = next((c for c in cands if os.path.exists(c)), None)
    if not p:
        note_skip(f"[B] {dll} 不存在（未构建 windows-drivers）")
        continue
    b = ctypes.CDLL(p)
    try:
        fn = getattr(b, fn_name)
    except AttributeError:
        check(f"[B] {fn_name}() == 2", False, "桥 DLL 无该导出（pre-fix 桥）")
        continue
    fn.restype = ctypes.c_uint32
    fn.argtypes = []
    v = fn()
    check(f"[B] {fn_name}() == 2", v == EXPECTED_ABI, f"got {v}")
    bridge_abi_seen += 1
if bridge_abi_seen == 0:
    note_skip("[B] 三桥 DLL 全缺失，活体层不可跑")
    if fails:
        print("G7_2 FAILURES:", fails)
        sys.exit(1)
    print("g7_2: skipped (no dll)")
    sys.exit(0)

# ---- [C] 行为层：假引擎 ABI 门 ----
gcc = shutil.which("gcc") or shutil.which("cc")
if not gcc and os.path.exists(
        r"C:\FreeRulesPrograms\BasicToolkits\msys64\ucrt64\bin\gcc.exe"):
    gcc = r"C:\FreeRulesPrograms\BasicToolkits\msys64\ucrt64\bin\gcc.exe"
if not gcc:
    note_skip("[C] 无 gcc，假引擎行为层跳过")
else:
    FAKE_C = r'''
#include <stdlib.h>
__declspec(dllexport) unsigned auradsp_abi(void) { return FAKE_ABI; }
__declspec(dllexport) void* auradsp_create(float sr, int nbs) {
    (void)sr; (void)nbs; return malloc(64); }
__declspec(dllexport) void auradsp_process(void* h, const float* in,
                                           float* out, int n) {
    (void)h; (void)in; (void)out; (void)n; }
__declspec(dllexport) void auradsp_destroy(void* h) { free(h); }
__declspec(dllexport) int auradsp_set_param(void* h, const char* id,
                                            const void* v, unsigned n) {
    (void)h; (void)id; (void)v; (void)n; return 0; }
__declspec(dllexport) int auradsp_get_param(void* h, const char* id,
                                            void* out, unsigned n) {
    (void)h; (void)id; (void)out; (void)n; return -1; }
__declspec(dllexport) int auradsp_viz_read(void* h, void* out, unsigned n) {
    (void)h; (void)out; (void)n; return 0; }
'''
    tmp = tempfile.mkdtemp(prefix="g72_")
    src = os.path.join(tmp, "fake_engine.c")
    with open(src, "w", encoding="ascii") as f:
        f.write(FAKE_C)

    def build(fake_abi, out_name):
        out = os.path.join(tmp, out_name)
        # -static 防 mingw 运行时依赖；桩是纯 C，无 CRT 之外的依赖
        rr = subprocess.run(
            [gcc, "-shared", "-O0", f"-DFAKE_ABI={fake_abi}", "-static",
             "-o", out, src],
            capture_output=True, text=True)
        if rr.returncode != 0 or not os.path.exists(out):
            return None, rr.stderr.strip().splitlines()[-1:] if rr.stderr else ["cc failed"]
        return out, None

    fake_bad, err1 = build(999, "fake_bad.dll")
    fake_ok, err2 = build(EXPECTED_ABI, "fake_ok.dll")
    if not fake_bad or not fake_ok:
        note_skip(f"[C] 假引擎编译失败 {err1 or err2}")
    else:
        asio_path = next(
            (c for c in [
                os.path.join(ROOT, "core", "desktop", "windows-drivers",
                             "out", "Release", "auraasio_bridge.dll"),
                os.path.join(ROOT, "test", "auraasio_bridge.dll")]
             if os.path.exists(c)), None)
        if not asio_path:
            note_skip("[C] auraasio_bridge.dll 不存在")
        else:
            b = ctypes.CDLL(asio_path)
            sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
            from bridge_compat import alias_common, start_asio  # noqa: E402

            alias_common(b, "asio")
            b.asio_start = start_asio(b)
            b.asio_stop.restype = ctypes.c_int
            b.asio_status.restype = ctypes.c_int
            b.asio_status.argtypes = [ctypes.c_char_p, ctypes.c_int]

            def get_note():
                buf = ctypes.create_string_buffer(4096)
                if b.asio_status(buf, 4096) <= 0:
                    return ""
                try:
                    return json.loads(
                        buf.value.decode("utf-8", "replace")).get("note", "")
                except ValueError:
                    return ""

            def try_start(fake_dll):
                rc = b.asio_start(b"", fake_dll.encode("utf-8"), b"", 0, 0)
                return rc, get_note()

            # C1：假 ABI=999 必须被 ABI 门拒绝（发生在驱动 open 之前，
            # 与驱动是否被占无关——环境鲁棒）
            rc1, note1 = try_start(fake_bad)
            check("[C1] 假引擎 ABI=999 被拒（rc!=0）", rc1 != 0, f"rc={rc1}")
            check("[C1] note 含 engine-abi-mismatch",
                  "abi-mismatch" in note1, f"note={note1!r}")
            if rc1 == 0:
                b.asio_stop()  # pre-fix 容错：真跑起来了必须收尾

            # C2：假 ABI=2 引擎门必须放行（拒绝不得"殃及"同代际）
            rc2, note2 = try_start(fake_ok)
            check("[C2] 同代际假引擎不被 ABI 门拒绝",
                  "abi-mismatch" not in note2, f"rc={rc2} note={note2!r}")
            if rc2 == 0:
                check("[C2] C2 启动后收尾 stop", b.asio_stop() == 0)

    shutil.rmtree(tmp, ignore_errors=True)

if fails:
    print("G7_2 FAILURES:", fails)
    sys.exit(1)
print("g7_2: all checks passed")
