"""smoke_release_strings.py — B-1 调试串门禁（计划 D1 §3.3）。

验收标准：
  1. 源码不变量：engine/ 树零 `std::cout << "[DBG`（调试输出必须走
     AURADSP_DBG*/AURADSP_WARN* 宏），零 `[TEMP-DIAG`；`[DBG` 字面量仅允许出现
     在 AURADSP_DBG*/WARN* 调用行（宏编译期剥离的源码侧实证）。
  2. Release DLL 字节扫描：不含 `[DBG ` 与 `[TEMP-DIAG`（二进制侧实证）。
  3. 反向开关断言：仅当 AURADSP_EXPECT_DBG=1 且 AURADSP_DLL 指向
     -DAURADSP_DBG_LOG=ON 构建产物时，断言含 `[DBG `（证明开关真实生效，
     防"宏写了没接线"）。

环境变量：AURADSP_DLL 覆盖被测 DLL 路径（C4 探针约定，已有）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENGINE = os.path.join(ROOT, "engine")
DLL_DEFAULT = os.path.join(ROOT, "core", "desktop", "windows", "out",
                           "Release", "auradsp_engine.dll")

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


DBG_COUT = re.compile(r'std::cout\s*<<\s*"\[DBG')
MACRO_CALL = re.compile(r"AURADSP_(DBG|WARN)(_S)?\s*\(")
SRC_EXTS = (".c", ".cpp", ".h", ".hpp", ".cc")


def source_invariant():
    bad_cout, tempdiag, unguarded = [], [], []
    dbg_hits = 0
    for dirpath, _, files in os.walk(ENGINE):
        for fn in sorted(files):
            if not fn.endswith(SRC_EXTS):
                continue
            fp = os.path.join(dirpath, fn)
            try:
                lines = open(fp, encoding="utf-8", errors="replace").read().splitlines()
            except OSError:
                continue
            rel = os.path.relpath(fp, ENGINE).replace(os.sep, "/")
            for n, line in enumerate(lines, 1):
                if "TEMP-DIAG" in line:
                    tempdiag.append(f"{rel}:{n}")
                if DBG_COUT.search(line):
                    bad_cout.append(f"{rel}:{n}")
                if "[DBG" in line:
                    dbg_hits += 1
                    if not MACRO_CALL.search(line):
                        unguarded.append(f"{rel}:{n}")
    check("源码零 std::cout [DBG", not bad_cout, "; ".join(bad_cout[:5]))
    check("源码零 TEMP-DIAG", not tempdiag, "; ".join(tempdiag[:5]))
    check("源码 [DBG 仅在宏调用行（%d 处有字面量）" % dbg_hits,
          not unguarded and dbg_hits > 0, "; ".join(unguarded[:5]))


def dll_scan():
    dll = os.environ.get("AURADSP_DLL", DLL_DEFAULT)
    if not os.path.exists(dll):
        check("DLL 存在: " + dll, False)
        return
    with open(dll, "rb") as f:
        data = f.read()
    if os.environ.get("AURADSP_EXPECT_DBG") == "1":
        check("反向断言：开关构建含 [DBG ", b"[DBG " in data, dll)
    else:
        check("Release DLL 无 [DBG ", b"[DBG " not in data, dll)
        check("Release DLL 无 TEMP-DIAG", b"TEMP-DIAG" not in data, dll)


if __name__ == "__main__":
    source_invariant()
    dll_scan()
    if FAIL:
        print(f"\n{len(FAIL)} FAIL: {FAIL}")
        sys.exit(1)
    print("\nALL PASS")
