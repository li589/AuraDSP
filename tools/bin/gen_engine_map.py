#!/usr/bin/env python
# -*- coding: utf-8 -*-
"""gen_engine_map.py — 由 .def 同源生成 Linux version script（S2，2026-11-01）

单一真源：engine/auradsp_engine.def（Windows 导出表）是全仓唯一的导出
符号清单。Linux 的 ELF 导出控制用 version script（engine/auradsp_engine.map），
必须与 .def 符号集恒等（ADR-012 / 《Linux适配方案》§3.5），故 .map 不手写、
由本脚本从 .def 派生：

    python tools/bin/gen_engine_map.py            # 重新生成 .map
    python tools/bin/gen_engine_map.py --check    # 只校验不一致时退出码 1（门禁）

生成的是匿名 version script：global 列全部 .def 符号，local: * 收起其余
一切符号，.so 的动态导出集由此 == .def 符号集（不叠加 -fvisibility=hidden：
本仓 ABI 头无 visibility 宏，hidden 会连 ABI 符号一并隐藏，S2 实测）。
改导出集请改 .def 后重跑本脚本，不要直接编辑 .map。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DEF_PATH = os.path.join(ROOT, "engine", "auradsp_engine.def")
MAP_PATH = os.path.join(ROOT, "engine", "auradsp_engine.map")


def parse_def_symbols(path):
    """解析 .def：EXPORTS 段之后每行首个 token 即一个导出符号。"""
    symbols = []
    in_exports = False
    with open(path, "r", encoding="utf-8") as f:
        for line in f:
            s = line.strip()
            if not s or s.startswith(";"):
                continue
            if s.upper() == "EXPORTS":
                in_exports = True
                continue
            if not in_exports:
                continue
            sym = s.split()[0]
            if sym not in symbols:
                symbols.append(sym)
    return symbols


def render_map(symbols):
    lines = [
        "/* auradsp_engine.map — Linux version script（ELF 导出控制）。",
        " * 由 tools/bin/gen_engine_map.py 从 engine/auradsp_engine.def 同源生成，",
        " * 勿手改：改导出集请改 .def 后重跑生成脚本（--check 可作门禁校验）。",
        " * 匿名版本：global = .def 全部符号；local: * 收起其余符号，",
        " * 使 .so 动态导出集与 Windows .def 恒等（ADR-012 / Linux 方案 §3.5）。 */",
        "{",
        "  global:",
    ]
    lines += ["    %s;" % s for s in symbols]
    lines += [
        "  local:",
        "    *;",
        "};",
        "",
    ]
    return "\n".join(lines)


def main():
    check_only = "--check" in sys.argv[1:]
    symbols = parse_def_symbols(DEF_PATH)
    if not symbols:
        print("FAIL  %s 未解析出任何导出符号" % DEF_PATH)
        return 1
    want = render_map(symbols)
    have = None
    if os.path.exists(MAP_PATH):
        with open(MAP_PATH, "r", encoding="utf-8") as f:
            have = f.read()
    if check_only:
        if have == want:
            print("PASS  auradsp_engine.map 与 .def 同源一致（%d 符号）" % len(symbols))
            return 0
        print("FAIL  auradsp_engine.map 与 .def 不一致，请运行 gen_engine_map.py 重新生成")
        return 1
    if have == want:
        print("OK    auradsp_engine.map 已是最新（%d 符号），未改动" % len(symbols))
        return 0
    with open(MAP_PATH, "w", encoding="utf-8", newline="\n") as f:
        f.write(want)
    print("OK    已生成 auradsp_engine.map（%d 符号）" % len(symbols))
    return 0


if __name__ == "__main__":
    sys.exit(main())
