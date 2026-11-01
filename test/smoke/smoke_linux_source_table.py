"""smoke_linux_source_table.py — Linux 源表可编译闭包门禁（S2，2026-11-01）。

验收标准（ADR-012 §4.3 + 《Linux适配方案-2026-11-01》§2.1.3 / §3.2）：
  1. Linux 引擎源表闭包可复现：按 engine/core_sources.cmake 的同一规则
     展开 legacy GLOB（排除 eel2/cpthread.c）与 C++ 核心清单，再叠加
     core/desktop/linux/CMakeLists.txt 的 Linux 专属调整后断言：
       - 不含 legacy/jamesdsp.c（E4：GCC constructor 双初始化）；
       - 不含任何 platform/windows 源、plugins 的 Win32/formats 源；
       - 正向包含 4 个 Linux 端口实现与 2 个插件裁剪 stub。
  2. 闭包内全部源文件不得 include Win32 头（windows.h 等）——legacy 的
     5 处 windows.h 均在 _WIN32 守卫内或属 eel2 副本，逐点白名单豁免，
     新增无守卫引用即判红。
  3. Linux CMake 文本断言：-include stdint.h（E3）与 gcc shim 前置注入
     生效点存在；--version-script 指向 auradsp_engine.map（E2，导出集
     收口只靠 version script，不叠加 -fvisibility=hidden，见 Linux
     CMake 文件头注释的实测说明）。
  4. auradsp_engine.map 与 .def 同源一致（复用 gen_engine_map 的解析与
     渲染逻辑比对，不在此另写一份解析器）。

纯文本/源表扫描，不需要引擎产物，任意平台可跑（runner 标记 PLATFORM_ANY）。
反向自检：用一段合成违规文本证明扫描器真的会判红（非恒真门禁）。
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


WIN_INCLUDE = re.compile(
    r'#\s*include\s*[<"](windows\.h|winsock2?\.h|mmdeviceapi\.h|audioclient\.h)[>"]',
    re.IGNORECASE)

# legacy 内 windows.h 的既有落点（《Linux适配方案》§2.1.2 逐点核实：全部
# 有 _WIN32 守卫 + POSIX 回退）。以相对路径白名单豁免，新增落点不在此列。
LEGACY_WIN_HEADER_WHITELIST = {
    os.path.join("legacy", "cpthread.h"),
    os.path.join("legacy", "MemoryUsage.h"),
    os.path.join("legacy", "jdsp", "Effects", "reverb.c"),
    os.path.join("legacy", "jdsp", "Effects", "eel2", "cpthread.h"),
    os.path.join("legacy", "jdsp", "Effects", "eel2", "ns-eel.h"),
}


def linux_source_closure():
    """按 core_sources.cmake + Linux CMake 的同一规则复现 Linux 源表。"""
    legacy = glob.glob(os.path.join(ENGINE, "legacy", "**", "*.c"), recursive=True)
    legacy = [p for p in legacy if not p.replace(os.sep, "/").endswith("eel2/cpthread.c")]
    # Linux 专属调整（core/desktop/linux/CMakeLists.txt 的 FILTER，E4）
    legacy = [p for p in legacy if os.path.basename(p) != "jamesdsp.c"]

    core_cmake_text = read(CORE_SOURCES)
    cxx = re.findall(r'"\$\{CMAKE_CURRENT_LIST_DIR\}/([^"]+\.cpp)"', core_cmake_text)
    cxx = [os.path.join(ENGINE, p) for p in cxx]

    platform = [os.path.join(ENGINE, "platform", "linux", n) for n in
                ("fs_linux.cpp", "env_linux.cpp", "log_linux.cpp", "module_linux.cpp")]
    stubs = [os.path.join(ENGINE, "plugins", "integration", n) for n in
             ("plugin_chain_adapter_stub.cpp", "plugin_abi_stub.cpp")]
    return legacy + cxx + platform + stubs


def main():
    closure = linux_source_closure()
    rel = [os.path.relpath(p, ENGINE) for p in closure]

    check("闭包非空且文件真实存在", len(closure) > 50 and all(os.path.exists(p) for p in closure),
          "n=%d" % len(closure))
    check("闭包不含 jamesdsp.c（E4）", not any(os.path.basename(p) == "jamesdsp.c" for p in closure))
    check("闭包不含 eel2/cpthread.c", not any(p.replace(os.sep, "/").endswith("eel2/cpthread.c") for p in closure))
    bad_platform = [r for r in rel if r.startswith(os.path.join("platform", "windows"))]
    check("闭包不含 platform/windows 源", not bad_platform, str(bad_platform))
    bad_plugins = [r for r in rel if r.startswith(os.path.join("plugins", "platform")) or
                   r.startswith(os.path.join("plugins", "formats")) or
                   r.startswith(os.path.join("plugins", "driver"))]
    check("闭包不含 plugins 的 Win32/formats/driver 源（D-7 裁剪）", not bad_plugins, str(bad_plugins))
    for want in ("fs_linux.cpp", "env_linux.cpp", "log_linux.cpp", "module_linux.cpp",
                 "plugin_chain_adapter_stub.cpp", "plugin_abi_stub.cpp"):
        check("闭包正向包含 %s" % want, any(os.path.basename(p) == want for p in closure))

    # Win32 头扫描：白名单外的任何命中都判红。
    offenders = []
    for p, r in zip(closure, rel):
        if r in LEGACY_WIN_HEADER_WHITELIST:
            continue
        if WIN_INCLUDE.search(read(p)):
            offenders.append(r)
    check("闭包源文件零无守卫 Win32 头引用", not offenders, str(offenders))
    # 反向自检：扫描器对合成违规文本必须命中。
    check("反向自检：扫描器能识别合成违规",
          bool(WIN_INCLUDE.search('#include <windows.h>')))

    cmake_text = read(LINUX_CMAKE) if os.path.exists(LINUX_CMAKE) else ""
    check("Linux CMake 存在", bool(cmake_text))
    check("Linux CMake 含 -include stdint.h（E3）", "-include stdint.h" in cmake_text)
    check("Linux CMake 含 gcc shim 前置注入", "auradsp_gcc_shim.h" in cmake_text and "-include" in cmake_text)
    check("Linux CMake 含 --version-script=auradsp_engine.map（E2）",
          "--version-script=" in cmake_text and "auradsp_engine.map" in cmake_text)
    check("Linux CMake 含 jamesdsp.c 排除（E4）", "jamesdsp" in cmake_text and "EXCLUDE" in cmake_text)

    # .map 与 .def 同源（复用 gen_engine_map，不另写解析器）。
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
    print("PASS  smoke_linux_source_table: 全部通过（闭包 %d 文件）" % len(closure))
    return 0


if __name__ == "__main__":
    sys.exit(main())
