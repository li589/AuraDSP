"""smoke_linux_source_table.py — Linux 编译闭包门禁。

初版 2026-11-01（S2，ADR-012 §4.3）；**2026-11-20 重校**。

重校原因（实测，非推测）：初版按 ADR-012 D-7「一期沿用
AURADSP_ENABLE_PLUGINS=OFF 整体裁掉」建模闭包，只含 2 个 stub。
但《Linux插件宿主实施方案-2026-11-02》立项后，Linux 目标的
`AURADSP_ENABLE_PLUGINS` 默认已改为 **ON**（VST3 + CLAP + VST2 +
进程内/外双宿主 + posix 平台层），真实编译闭包比初版模型多出
20 余个插件源。初版因此是**假绿**：它断言的闭包与实际构建不符，
且真实插件源从未被 Win32 头扫描覆盖——5 处
`#if defined(_WIN32)` 守卫（clap_instance / clap_metadata /
vst2_instance / vst3_instance / vst3_metadata）一旦被抹掉，
本门禁不会红（只有 Linux CI 的编译 job 会）。

重校后本门禁的契约：
  1. **源表从 CMake 派生，不硬编码模型**——解析
     core/desktop/linux/CMakeLists.txt 与 engine/core_sources.cmake
     得到实际编译源集。CMake 改了，门禁自动跟随，杜绝模型漂移
     （初版漂移的根因）。
  2. **插件子系统默认 ON**（2026-11-02 立项口径），ON 分支须含
     driver / formats(clap,vst3,vst2) / integration / posix 平台层；
     OFF 分支须恰为 2 个 stub。
  3. **Win32 头零泄漏**：对真实闭包的 TU 及其**可达本地头**做
    **守卫感知**扫描——`_WIN32` 守卫内的 include 合规，守卫外命中
    即红。可达性按「不被 _WIN32 守卫遮蔽的引号 include」推进，
    故 eel2/dirent.h（仅 Windows 分支包含）不会被误判。
  4. **平台隔离**：闭包不含 engine/platform/windows/**（OS 适配层）；
    plugins/platform/win32/** 只允许 process_plugin_proxy.cpp 一个
    可移植 IPC 代理（须含非 Win32 分支）。
  5. **沿用初版的构建口径断言**：jamesdsp.c 排除（E4）、
    eel2/cpthread.c 排除、-include stdint.h（E3）、gcc shim 前置注入、
    --version-script=auradsp_engine.map（E2）、.map 与 .def 同源。

纯文本/源表扫描，不需要引擎产物，任意平台可跑（runner 标记 PLATFORM_ANY）。
反向自检：用合成违规文本证明扫描器真的会判红、且不会把守卫内的
include 误判（非恒真门禁）。
"""
import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
ENGINE = os.path.join(ROOT, "engine")
LINUX_CMAKE = os.path.join(ROOT, "core", "desktop", "linux", "CMakeLists.txt")
CORE_SOURCES = os.path.join(ENGINE, "core_sources.cmake")

sys.path.insert(0, os.path.join(ROOT, "tools", "bin"))
import gen_engine_map  # noqa: E402  复用其 .def 解析 / .map 渲染（单一真源）

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


def read(path):
    with open(path, "r", encoding="utf-8", errors="replace") as f:
        return f.read()


# --------------------------------------------------------------------------
# 预处理守卫感知：判定某行是否处于「仅 Windows 编译」的分支内
# --------------------------------------------------------------------------

IF_RE = re.compile(r"^\s*#\s*(if|ifdef|ifndef)\b\s*(.*)$")
ELIF_RE = re.compile(r"^\s*#\s*elif\b\s*(.*)$")
ELSE_RE = re.compile(r"^\s*#\s*else\b")
ENDIF_RE = re.compile(r"^\s*#\s*endif\b")
INCLUDE_RE = re.compile(r'#\s*include\s*(<|")([^">]+)[">]')

WIN_HEADERS = {
    "windows.h", "winsock.h", "winsock2.h", "mswsock.h",
    "mmdeviceapi.h", "audioclient.h", "objbase.h", "comdef.h",
    "winreg.h", "shlobj.h", "knownfolders.h", "psapi.h",
    "intrin.h", "direct.h",
}


def _is_win32_cond(cond):
    """仅当条件恰为 _WIN32 / defined(_WIN32) 时才算「Windows 专属分支」。

    复合条件（如 `defined(_WIN32) && !defined(__EMSCRIPTEN__)`）不算——
    那样的分支在 Linux 上仍会编译，其中的 include 是真实泄漏。
    """
    c = re.sub(r"\s+", "", cond)
    return c in ("defined(_WIN32)", "_WIN32")


def win32_region_flags(text):
    """逐行返回 (行号, 是否处于 Windows 专属分支内)。"""
    stack = []
    for i, line in enumerate(text.split("\n"), 1):
        s = line.strip()
        m = IF_RE.match(s)
        if m:
            kind, rest = m.group(1), m.group(2)
            if kind == "if":
                stack.append(_is_win32_cond(rest))
            elif kind == "ifdef":
                stack.append(_is_win32_cond(rest))
            else:  # ifndef
                stack.append(not _is_win32_cond(rest))
            continue
        m = ELIF_RE.match(s)
        if m:
            if stack:
                stack[-1] = _is_win32_cond(m.group(1))
            continue
        if ELSE_RE.match(s):
            if stack:
                stack[-1] = not stack[-1]
            continue
        if ENDIF_RE.match(s):
            if stack:
                stack.pop()
            continue
        yield i, any(stack)


def unguarded_win_includes(text):
    """返回守卫外的 Win32 头 include：[(行号, 片段)]。"""
    lines = text.split("\n")
    out = []
    for i, guarded in win32_region_flags(text):
        if guarded:
            continue
        m = INCLUDE_RE.search(lines[i - 1])
        if m and m.group(2).lower() in WIN_HEADERS:
            out.append((i, m.group(0)))
    return out


def local_includes(text):
    """不被 _WIN32 守卫遮蔽的引号 include（本地头可达性用）。"""
    lines = text.split("\n")
    out = []
    for i, guarded in win32_region_flags(text):
        if guarded:
            continue
        m = INCLUDE_RE.search(lines[i - 1])
        if m and m.group(1) == '"':
            out.append(m.group(2))
    return out


# --------------------------------------------------------------------------
# 源表派生（从 CMake 解析，不硬编码）
# --------------------------------------------------------------------------

INCLUDE_DIRS = [
    "", "chain", "legacy", "legacy/jdsp", "plugins/api", "plugins/driver",
]


def parse_linux_cmake(text):
    """从 core/desktop/linux/CMakeLists.txt 派生实际源集。

    返回 dict：
      all      —— CMake 引用的全部 ${API}/ 源（ON + OFF + 宿主 + 平台层）
      plugin_on  / plugin_off —— AURADSP_PLUGIN_SOURCES 的两个分支
    """
    all_rel = set(re.findall(r'"\$\{API\}/([^"]+\.(?:c|cpp))"', text))
    blocks = re.findall(r"set\(AURADSP_PLUGIN_SOURCES\s*(.*?)\n\s*\)", text, re.S)
    plugin_on = set(re.findall(r'"\$\{API\}/([^"]+\.(?:c|cpp))"', blocks[0])) if blocks else set()
    plugin_off = set(re.findall(r'"\$\{API\}/([^"]+\.(?:c|cpp))"', blocks[1])) if len(blocks) > 1 else set()
    return {"all": all_rel, "plugin_on": plugin_on, "plugin_off": plugin_off}


def parse_core_cmake(text):
    """core_sources.cmake：可移植核心 CXX 清单（engine 相对路径）。"""
    return set(re.findall(r'"\$\{CMAKE_CURRENT_LIST_DIR\}/([^"]+\.cpp)"', text))


def legacy_sources(exclude_patterns=()):
    """legacy C 全集（GLOB 语义），套用 core_sources.cmake 与 Linux CMake 的
    FILTER 排除规则（eel2/cpthread.c + jamesdsp.c）。"""
    out = []
    for p in glob.glob(os.path.join(ENGINE, "legacy", "**", "*.c"), recursive=True):
        rel = os.path.relpath(p, ENGINE).replace(os.sep, "/")
        if any(re.search(pat, rel) for pat in exclude_patterns):
            continue
        out.append(rel)
    return set(out)


def resolve_local_header(name, from_rel):
    """按 include 目录顺序解析本地头；找不到返回 None。"""
    base_dirs = [os.path.dirname(from_rel)] + [d for d in INCLUDE_DIRS if d]
    for d in base_dirs:
        cand = os.path.normpath(os.path.join(d, name)).replace(os.sep, "/")
        full = os.path.join(ENGINE, cand.replace("/", os.sep))
        if os.path.isfile(full):
            return cand
    return None


def reachable_headers(tu_rel):
    """从 TU 出发沿未被守卫遮蔽的引号 include 求本地头可达集（限 engine/ 内）。"""
    seen = set()
    stack = [tu_rel]
    while stack:
        cur = stack.pop()
        full = os.path.join(ENGINE, cur.replace("/", os.sep))
        if not os.path.isfile(full):
            continue
        for name in local_includes(read(full)):
            tgt = resolve_local_header(name, cur)
            if tgt and tgt not in seen:
                seen.add(tgt)
                stack.append(tgt)
    return seen


def main():
    cmake_text = read(LINUX_CMAKE) if os.path.exists(LINUX_CMAKE) else ""
    core_text = read(CORE_SOURCES) if os.path.exists(CORE_SOURCES) else ""

    check("Linux CMake 存在且可解析", bool(cmake_text))
    check("core_sources.cmake 存在且可解析", bool(core_text))
    if not (cmake_text and core_text):
        print("----")
        print("FAIL  smoke_linux_source_table: 源表文件缺失")
        return 1

    parsed = parse_linux_cmake(cmake_text)
    plugin_on = parsed["plugin_on"]
    plugin_off = parsed["plugin_off"]
    cmake_all = parsed["all"]
    core_cxx = parse_core_cmake(core_text)

    # legacy 排除规则从两份 CMake 的 FILTER 行派生（CMake 的 "..." 内 \\ 转义还原）。
    exclude_patterns = []
    for text in (core_text, cmake_text):
        for raw in re.findall(r'FILTER\s+\w+\s+EXCLUDE\s+REGEX\s+"([^"]+)"', text):
            exclude_patterns.append(raw.replace("\\\\", "\\"))
    legacy = legacy_sources(exclude_patterns)

    # ---- A. 源表建模 ----
    check("plugin ON 分支已解析（%d 源）" % len(plugin_on), len(plugin_on) > 0)
    check("plugin OFF 分支已解析（%d 源）" % len(plugin_off), len(plugin_off) > 0)

    # A2：插件子系统默认 ON（2026-11-02 立项：Linux 插件宿主转正）。
    opt = re.search(r"option\(AURADSP_ENABLE_PLUGINS\s+\"[^\"]*\"\s+(ON|OFF)\)", cmake_text)
    check("Linux 目标 AURADSP_ENABLE_PLUGINS 默认 ON（2026-11-02 立项口径）",
          bool(opt) and opt.group(1) == "ON",
          "实际=%s" % (opt.group(1) if opt else "未找到 option"))

    # A3：ON 分支须含各插件层（driver / formats / integration / posix 平台层）。
    for prefix in ("plugins/driver/", "plugins/formats/clap/", "plugins/formats/vst3/",
                   "plugins/formats/vst2/", "plugins/integration/", "plugins/platform/posix/"):
        check("ON 分支含 %s*" % prefix,
              any(p.startswith(prefix) for p in plugin_on))

    # A4：OFF 分支恰为 2 个 stub。
    check("OFF 分支恰为 2 个 stub（plugin_chain_adapter_stub / plugin_abi_stub）",
          plugin_off == {"plugins/integration/plugin_chain_adapter_stub.cpp",
                         "plugins/integration/plugin_abi_stub.cpp"},
          str(sorted(plugin_off)))

    # A5：4 个 Linux 端口实现。
    for want in ("platform/linux/fs_linux.cpp", "platform/linux/env_linux.cpp",
                 "platform/linux/log_linux.cpp", "platform/linux/module_linux.cpp"):
        check("闭包含 %s" % want, want in cmake_all)

    # 实际编译闭包（插件默认 ON）：core 源表 + legacy + CMake 引用的全部源
    # （去掉 OFF 分支 stub——它们在 ON 下不参与编译）。
    closure = set(core_cxx) | set(legacy) | (cmake_all - plugin_off)
    check("闭包非空（%d 文件）" % len(closure), len(closure) > 50)
    missing = [p for p in sorted(closure)
               if not os.path.isfile(os.path.join(ENGINE, p.replace("/", os.sep)))]
    check("闭包内全部源文件真实存在", not missing, str(missing[:8]))

    # A7：jamesdsp.c 排除（E4）——既要在实际闭包里不在，也要 CMake 有过滤。
    check("闭包不含 jamesdsp.c（E4）",
          not any(p.endswith("legacy/jamesdsp.c") for p in closure))
    check("Linux CMake 含 jamesdsp.c 排除（E4）",
          "jamesdsp" in cmake_text and "EXCLUDE" in cmake_text)

    # A8：eel2/cpthread.c 排除。
    check("闭包不含 eel2/cpthread.c",
          not any(p.endswith("eel2/cpthread.c") for p in closure))

    # A9：不含 OS 适配层的 Windows 实现。
    bad_platform = [p for p in sorted(closure) if p.startswith("platform/windows/")]
    check("闭包不含 platform/windows 源（OS 适配层）", not bad_platform, str(bad_platform))

    # A10：plugins/platform/win32/** 只允许可移植 IPC 代理。
    win32_plugin = [p for p in sorted(closure) if p.startswith("plugins/platform/win32/")]
    allowed_win32 = {"plugins/platform/win32/host/process_plugin_proxy.cpp"}
    check("plugins/platform/win32 仅含 process_plugin_proxy（可移植 IPC 代理）",
          set(win32_plugin) == allowed_win32, str(win32_plugin))
    proxy_rel = "plugins/platform/win32/host/process_plugin_proxy.cpp"
    proxy_ok = False
    if proxy_rel in closure:
        ptext = read(os.path.join(ENGINE, proxy_rel.replace("/", os.sep)))
        proxy_ok = ("#else" in ptext or "!defined(_WIN32)" in ptext)
    check("process_plugin_proxy 含非 Win32 分支（POSIX 可移植）", proxy_ok)

    # ---- B. Win32 头零泄漏（真实闭包）----
    tu_violations = []
    for rel in sorted(closure):
        full = os.path.join(ENGINE, rel.replace("/", os.sep))
        if not os.path.isfile(full):
            continue
        for ln, frag in unguarded_win_includes(read(full)):
            tu_violations.append("%s:%d %s" % (rel, ln, frag))
    check("真实闭包 TU 零无守卫 Win32 头引用", not tu_violations,
          "; ".join(tu_violations[:6]))

    # 可达本地头同样不得有守卫外的 Win32 头 include。
    hdrs = set()
    for rel in sorted(closure):
        hdrs |= reachable_headers(rel)
    hdr_violations = []
    for rel in sorted(hdrs):
        full = os.path.join(ENGINE, rel.replace("/", os.sep))
        if not os.path.isfile(full):
            continue
        for ln, frag in unguarded_win_includes(read(full)):
            hdr_violations.append("%s:%d %s" % (rel, ln, frag))
    check("可达本地头零无守卫 Win32 头引用（%d 头）" % len(hdrs),
          not hdr_violations, "; ".join(hdr_violations[:6]))

    # 反向自检：守卫外必判红、守卫内必放行。
    bad_sample = "#include <windows.h>\nint main(){return 0;}\n"
    good_sample = "#if defined(_WIN32)\n#include <windows.h>\n#endif\n"
    check("反向自检：守卫外 windows.h 必被识别",
          bool(unguarded_win_includes(bad_sample)))
    check("反向自检：_WIN32 守卫内 windows.h 必放行",
          not unguarded_win_includes(good_sample))
    check("反向自检：#ifdef _WIN32 守卫放行",
          not unguarded_win_includes("#ifdef _WIN32\n#include <windows.h>\n#endif\n"))
    check("反向自检：#ifndef _WIN32 内的 windows.h 判红",
          bool(unguarded_win_includes("#ifndef _WIN32\n#include <windows.h>\n#endif\n")))

    # ---- C. 构建口径（沿用初版）----
    check("Linux CMake 含 -include stdint.h（E3）", "-include stdint.h" in cmake_text)
    check("Linux CMake 含 gcc shim 前置注入",
          "auradsp_gcc_shim.h" in cmake_text and "-include" in cmake_text)
    check("Linux CMake 含 --version-script=auradsp_engine.map（E2）",
          "--version-script=" in cmake_text and "auradsp_engine.map" in cmake_text)

    symbols = gen_engine_map.parse_def_symbols(gen_engine_map.DEF_PATH)
    map_path = gen_engine_map.MAP_PATH
    have = read(map_path) if os.path.exists(map_path) else None
    check("auradsp_engine.map 存在且与 .def 同源一致（%d 符号）" % len(symbols),
          have == gen_engine_map.render_map(symbols))
    check("gcc shim 头存在", os.path.exists(os.path.join(ENGINE, "auradsp_gcc_shim.h")))

    print("----")
    if FAIL:
        print("FAIL  smoke_linux_source_table: %d 项未过" % len(FAIL))
        return 1
    print("PASS  smoke_linux_source_table: 全部通过（闭包 %d 文件 / 可达头 %d）"
          % (len(closure), len(hdrs)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
