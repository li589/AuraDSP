"""smoke_platform_isolation.py — M1 平台隔离门禁（2026-10-29）。

验收标准（方案《跨平台基础框架与平台依赖剥离方案-2026-10-29》F1）：
  1. 引擎可移植核心（engine 根文件 / chain / dsp / plugins/integration）内
     零 OS 头（windows.h 等）与零 Win32 符号（_WIN32 / WINAPI / _wfopen /
     MultiByteToWideChar / OutputDebugString / GetEnvironmentVariableA）。
     排除：engine/legacy/**（上游移植）、engine/platform/**（适配层）、
     engine/plugins/{api,driver,formats,host,platform,tests}（M2 才归类）。
  2. 端口头（engine/platform/port/*.h）保持纯声明：自身不得 include OS 头。
  3. 正向断言：port 头与 Windows 实现文件必须存在（防"删了实现留下声明"）。

反向自检：脚本用一段合成违规文本证明扫描器真的会判红（非恒真门禁）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENGINE = os.path.join(ROOT, "engine")

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


OS_INCLUDE = re.compile(
    r'#\s*include\s*[<"](windows\.h|winsock2?\.h|mmdeviceapi\.h|audioclient\.h|processthreadsapi\.h)[>"]',
    re.IGNORECASE)
OS_SYMBOL = re.compile(
    r'\b_WIN32\b|\bWINAPI\b|\b_wfopen\b|\bMultiByteToWideChar\b|'
    r'\bOutputDebugString[AW]?\b|\bGetEnvironmentVariable[AW]?\b')

# 可移植核心的扫描面（相对 engine/）
SCAN_DIRS = ("", "chain", "dsp", os.path.join("plugins", "integration"))
SRC_EXTS = (".c", ".cc", ".cpp", ".h", ".hpp")

PORT_HEADERS = ("fs.h", "env.h", "log.h")
WIN_IMPLS = ("win_compat.cpp", "fs_win.cpp", "env_win.cpp", "log_win.cpp")


def iter_core_files():
    for rel in SCAN_DIRS:
        base = os.path.join(ENGINE, rel)
        if not os.path.isdir(base):
            continue
        for fn in sorted(os.listdir(base)):
            fp = os.path.join(base, fn)
            if os.path.isfile(fp) and fn.endswith(SRC_EXTS):
                yield fp


def strip_comments(src):
    # 去掉 /* */ 与 // 注释，避免注释里的示例/背景文本误判
    src = re.sub(r"/\*.*?\*/", "", src, flags=re.DOTALL)
    return "\n".join(line.split("//")[0] for line in src.splitlines())


def core_scan():
    inc_hits, sym_hits = [], []
    for fp in iter_core_files():
        rel = os.path.relpath(fp, ENGINE).replace(os.sep, "/")
        try:
            src = open(fp, encoding="utf-8", errors="replace").read()
        except OSError:
            continue
        lines = strip_comments(src).splitlines()
        for n, code in enumerate(lines, 1):
            if OS_INCLUDE.search(code):
                inc_hits.append(f"{rel}:{n}")
            if OS_SYMBOL.search(code):
                sym_hits.append(f"{rel}:{n}")
    check("核心零 OS 头（windows/winsock/mmdeviceapi/audioclient）", not inc_hits,
          "; ".join(inc_hits[:6]))
    check("核心零 Win32 符号（_WIN32/WINAPI/_wfopen/MultiByteToWideChar/...）",
          not sym_hits, "; ".join(sym_hits[:6]))


def port_purity():
    port_dir = os.path.join(ENGINE, "platform", "port")
    for name in PORT_HEADERS:
        fp = os.path.join(port_dir, name)
        if not os.path.isfile(fp):
            check(f"端口头存在: {name}", False, fp)
            continue
        src = open(fp, encoding="utf-8", errors="replace").read()
        check(f"端口头纯声明: {name}", not OS_INCLUDE.search(src), fp)


def impl_presence():
    win_dir = os.path.join(ENGINE, "platform", "windows")
    for name in WIN_IMPLS:
        fp = os.path.join(win_dir, name)
        check(f"Windows 实现存在: {name}", os.path.isfile(fp), fp)


def negative_self_test():
    bad = '#include <windows.h>\n#ifdef _WIN32\n'
    check("自检：扫描器能判红 OS 头", bool(OS_INCLUDE.search(bad)))
    check("自检：扫描器能判红 Win32 符号", bool(OS_SYMBOL.search(bad)))


if __name__ == "__main__":
    core_scan()
    port_purity()
    impl_presence()
    negative_self_test()
    if FAIL:
        print(f"\n{len(FAIL)} FAIL: {FAIL}")
        sys.exit(1)
    print("\nALL PASS")
