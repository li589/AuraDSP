"""smoke_platform_isolation.py — M1/M2 平台隔离门禁（2026-10-29）。

验收标准（方案《跨平台基础框架与平台依赖剥离方案-2026-10-29》F1 + M2）：
  1. 引擎可移植核心（engine 根文件 / chain / dsp / plugins/integration）内
     零 OS 头（windows.h 等）与零 Win32 符号（_WIN32 / WINAPI / _wfopen /
     MultiByteToWideChar / OutputDebugString / GetEnvironmentVariableA）。
     排除：engine/legacy/**（上游移植）、engine/platform/**（适配层）、
     engine/plugins/{api,driver,formats,platform,tests}（M2 已按平台归类）。
  2. 端口头（engine/platform/port/*.h）保持纯声明：自身不得 include OS 头。
  3. 正向断言：port 头与 Windows 实现文件必须存在（防"删了实现留下声明"）。
  4. M2 结构断言：远程宿主只在 plugins/platform/win32/host/；Win32 模块泵
     只在 platform/win32/；formats 不再直接 LoadLibrary/GetProcAddress/FreeLibrary。
  5. R6（M6 审查遗留，2026-10-30）CMake 分层文本断言：auradsp_core 源表零
     platform/ 源；engine 目标编入全部 4 个 Windows 端口实现（经
     auradsp_wincompat + fs/env/log）；AURADSP_PLUGIN_HOST_SOURCES 含模块
     实现且 engine/宿主/插件测试目标均引用该源表；
     AURADSP_PLUGIN_HOST_REMOTE=OFF 分支自洽（清空 remote 源 + INPROC 门控）。
  6. CP-12/CP-16（2026-11-01）：`plugins/driver/` 不得直接包含 OS 头
     （Win32 入口须经 `plugins/platform/win32` 或 `platform/port`）；
     `port/time.h` 纳入端口头纯声明检查。

反向自检：脚本用一段合成违规文本证明扫描器真的会判红（非恒真门禁）。
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENGINE = os.path.join(ROOT, "engine")
CMAKE_FILE = os.path.join(ROOT, "core", "desktop", "windows", "CMakeLists.txt")

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

PORT_HEADERS = ("fs.h", "env.h", "log.h", "module.h", "time.h")
WIN_IMPLS = ("win_compat.cpp", "fs_win.cpp", "env_win.cpp", "log_win.cpp")

# M2：远程宿主与 Win32 模块加载的唯一归属地（相对 engine/）
M2_HOST_DIR = os.path.join("plugins", "platform", "win32", "host")
M2_HOST_FILES = (
    "auradsp_plugin_host_main.cpp",
    "plugin_host_client.cpp",
    "plugin_host_client.h",
    "plugin_ipc_protocol.h",
    "plugin_shared_region.cpp",
    "plugin_shared_region.h",
    "process_plugin_proxy.cpp",
    "process_plugin_proxy.h",
)
DIRECT_MODULE_LOAD = re.compile(
    r"\bLoadLibrary(?:ExW|ExA|W|A)?\s*\(|\bGetProcAddress\s*\(|\bFreeLibrary\s*\(")


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


def m2_layout():
    legacy_host = os.path.join(ENGINE, "plugins", "host")
    check("M2 远程宿主已迁出 plugins/host", not os.path.isdir(legacy_host), legacy_host)
    host_dir = os.path.join(ENGINE, M2_HOST_DIR)
    for name in M2_HOST_FILES:
        fp = os.path.join(host_dir, name)
        check(f"M2 远程宿主文件位于 platform/win32/host: {name}", os.path.isfile(fp), fp)
    check("M2 模块泵位于 platform/win32",
          os.path.isfile(os.path.join(ENGINE, "plugins", "platform", "win32", "module_pump.h")),
          "plugins/platform/win32/module_pump.h")
    check("M2 模块泵已从 driver 移除",
          not os.path.isfile(os.path.join(ENGINE, "plugins", "driver", "module_pump.h")),
          "plugins/driver/module_pump.h")
    module_impl = os.path.join(ENGINE, "plugins", "platform", "win32", "plugin_module.cpp")
    check("M2 模块加载端口 Windows 实现存在", os.path.isfile(module_impl), module_impl)

    # formats 的模块加载必须走 port/module.h，不得直接调 Win32 模块 API
    hits = []
    fmt_root = os.path.join(ENGINE, "plugins", "formats")
    for dirpath, _dirnames, filenames in os.walk(fmt_root):
        for fn in sorted(filenames):
            if not fn.endswith(SRC_EXTS):
                continue
            fp = os.path.join(dirpath, fn)
            rel = os.path.relpath(fp, ENGINE).replace(os.sep, "/")
            src = strip_comments(open(fp, encoding="utf-8", errors="replace").read())
            for n, code in enumerate(src.splitlines(), 1):
                if DIRECT_MODULE_LOAD.search(code):
                    hits.append(f"{rel}:{n}")
    check("M2 formats 零直接模块加载 API（LoadLibrary/GetProcAddress/FreeLibrary）",
          not hits, "; ".join(hits[:6]))


def driver_os_isolation():
    """CP-12/CP-16：driver 层不得直接包含 OS 头（Win32 入口须经 platform/win32）。
    历史上 windows.h 藏在 plugin_host_manager.cpp，F1 因扫描面排除 driver 而漏检；
    该文件已改走 port/time.h，此断言防回潮。"""
    driver_dir = os.path.join(ENGINE, "plugins", "driver")
    hits = []
    if os.path.isdir(driver_dir):
        for dirpath, _dirnames, filenames in os.walk(driver_dir):
            for fn in sorted(filenames):
                if not fn.endswith(SRC_EXTS):
                    continue
                fp = os.path.join(dirpath, fn)
                rel = os.path.relpath(fp, ENGINE).replace(os.sep, "/")
                src = strip_comments(open(fp, encoding="utf-8", errors="replace").read())
                for n, code in enumerate(src.splitlines(), 1):
                    if OS_INCLUDE.search(code):
                        hits.append(f"{rel}:{n}")
    check("CP-12 driver 零直接 OS 头（Win32 入口须经 platform/win32/port）",
          not hits, "; ".join(hits[:6]))


def negative_self_test():
    bad = '#include <windows.h>\n#ifdef _WIN32\n'
    check("自检：扫描器能判红 OS 头", bool(OS_INCLUDE.search(bad)))
    check("自检：扫描器能判红 Win32 符号", bool(OS_SYMBOL.search(bad)))


def _cmake_call_block(src, start_pat):
    """取 start_pat 起的 CMake 调用块（如 add_library(...) / set(...)，
    自首个 '(' 起深度配对到 ')'）。入参 src 应已去 # 注释。"""
    m = re.search(start_pat, src)
    if not m:
        return ""
    op = src.find("(", m.start())
    if op < 0:
        return ""
    depth = 0
    for i in range(op, len(src)):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                return src[op:i + 1]
    return ""


_IF_TOKEN = re.compile(r"\bif\s*\(|\bendif\b", re.IGNORECASE)


def _cmake_if_blocks(src, cond_pat):
    """返回所有匹配 cond_pat 的 if 条件块（条件头 + 嵌套体到配对 endif）。
    同一条件可能出现多次（如 NOT AURADSP_PLUGIN_HOST_REMOTE），全部返回。"""
    blocks = []
    for m in re.finditer(cond_pat, src):
        # 跳过条件头本身的 '(' ... ')'，进入块体。
        op = src.find("(", m.start())
        depth = 0
        i = op
        header_end = -1
        while i < len(src):
            if src[i] == "(":
                depth += 1
            elif src[i] == ")":
                depth -= 1
                if depth == 0:
                    header_end = i + 1
                    break
            i += 1
        if header_end < 0:
            continue
        body_depth = 1
        end = -1
        for tok in _IF_TOKEN.finditer(src, header_end):
            if tok.group(0).lower().startswith("if"):
                body_depth += 1
            else:
                body_depth -= 1
                if body_depth == 0:
                    end = tok.end()
                    break
        blocks.append(src[m.start():end if end > 0 else len(src)])
    return blocks


def cmake_layering():
    """R6：F1 门禁补 CMake 分层文本断言（M3 分层回归防护）。"""
    if not os.path.isfile(CMAKE_FILE):
        check("R6 CMakeLists 存在", False, CMAKE_FILE)
        return
    raw = open(CMAKE_FILE, encoding="utf-8", errors="replace").read()
    src = re.sub(r"#[^\n]*", "", raw)

    # 1. auradsp_core 源表零 platform/ 源（可移植核心不编任何平台适配）。
    core_block = _cmake_call_block(src, r"add_library\s*\(\s*auradsp_core\b")
    check("R6 auradsp_core 源表存在", bool(core_block))
    check("R6 auradsp_core 零 platform/ 源",
          "platform/" not in core_block,
          "core 源表出现 platform/ 路径")

    # 2. engine 目标编入全部 4 个 Windows 端口实现：
    #    win_compat 经 auradsp_wincompat（OBJECT 库）+ fs/env/log 直编。
    engine_block = _cmake_call_block(src, r"add_library\s*\(\s*auradsp_engine\b")
    check("R6 auradsp_engine 源表存在", bool(engine_block))
    check("R6 engine 链入 auradsp_wincompat（CreateFile2 回退）",
          "auradsp_wincompat" in engine_block
          or "auradsp_wincompat" in _cmake_call_block(
              src, r"target_link_libraries\s*\(\s*auradsp_engine\b"),
          "auradsp_engine 未引用 auradsp_wincompat")
    for impl in ("fs_win.cpp", "env_win.cpp", "log_win.cpp"):
        check(f"R6 engine 编入 {impl}", impl in engine_block)

    # 3. 模块实现唯一归属 win32 且进入共享源表（engine/宿主/测试复用）；
    #    各目标定义块内必须显式出现 ${AURADSP_PLUGIN_HOST_SOURCES}。
    host_sources = _cmake_call_block(src, r"set\s*\(\s*AURADSP_PLUGIN_HOST_SOURCES\b")
    check("R6 AURADSP_PLUGIN_HOST_SOURCES 含 plugin_module.cpp",
          "plugin_module.cpp" in host_sources)
    targets_with_host_src = (
        "auradsp_engine", "auradsp_plugin_host",
        "test_plugin_direct", "test_plugin_chain", "test_host_quarantine",
    )
    for tgt in targets_with_host_src:
        call = _cmake_call_block(
            src, rf"(?:add_library|add_executable)\s*\(\s*{re.escape(tgt)}\b")
        check(f"R6 {tgt} 编入 AURADSP_PLUGIN_HOST_SOURCES",
              "${AURADSP_PLUGIN_HOST_SOURCES}" in call,
              f"{tgt} 目标定义块未引用插件共享源表")

    # 4. REMOTE=OFF 分支自洽：清空 remote 源（源表级）+ 引擎 INPROC 门控，
    #    两处 NOT 分支都要覆盖；ON 块内构建宿主且仅在块内定义。
    off_blocks = _cmake_if_blocks(src, r"if\s*\(\s*NOT\s+AURADSP_PLUGIN_HOST_REMOTE\b")
    check("R6 REMOTE=OFF 分支存在（≥1）", len(off_blocks) >= 1)
    check("R6 REMOTE=OFF 清空 AURADSP_PLUGIN_REMOTE_SOURCES",
          any(re.search(r'set\s*\(\s*AURADSP_PLUGIN_REMOTE_SOURCES\s+""\s*\)', b)
              for b in off_blocks),
          "所有 OFF 分支均未清空 remote 源")
    check("R6 REMOTE=OFF 引擎置 AURADSP_HOST_INPROC",
          any("AURADSP_HOST_INPROC" in b for b in off_blocks),
          "OFF 分支未门控 AURADSP_HOST_INPROC")
    on_blocks = _cmake_if_blocks(src, r"if\s*\(\s*AURADSP_PLUGIN_HOST_REMOTE\b")
    on_body = "\n".join(on_blocks)
    check("R6 REMOTE=ON 块构建 auradsp_plugin_host",
          "add_executable" in on_body and "auradsp_plugin_host" in on_body)
    # 宿主目标的 add_executable 必须落在 ON 块内（块外不得再定义同名目标）。
    outside_def = _cmake_call_block(
        src.replace(on_body, ""), r"add_executable\s*\(\s*auradsp_plugin_host\b")
    check("R6 auradsp_plugin_host 仅在 REMOTE=ON 块内定义",
          not outside_def,
          "ON 块外存在 add_executable(auradsp_plugin_host")


if __name__ == "__main__":
    core_scan()
    port_purity()
    impl_presence()
    m2_layout()
    driver_os_isolation()
    cmake_layering()
    negative_self_test()
    if FAIL:
        print(f"\n{len(FAIL)} FAIL: {FAIL}")
        sys.exit(1)
    print("\nALL PASS")
