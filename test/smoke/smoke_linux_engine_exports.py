# -*- coding: utf-8 -*-
"""smoke_linux_engine_exports — Linux 引擎导出集门禁（S4 后补强，2026-11-01）。

方案 §5.2 验收口径：Linux 产出 libauradsp_engine.so 的动态导出集必须
与 engine/auradsp_engine.def 的 56 符号**恒等**，且无内部符号泄漏。
S2 起靠人工 nm 核查，本门禁把它固化：纯 Python 解析 ELF64 .dynsym
（不依赖 nm/readelf 是否安装），取 DEFINED + GLOBAL/WEAK 的符号名集
与 .def 导出集逐一比对（双向差集都判 FAIL）。

产物经 test/engine_artifact.py 解析；缺失时自 SKIP 退出 0（仓库惯例）。
仅 Linux 有意义，runner 以 PLATFORM_LINUX 注册，非 Linux 不执行。
"""
import os
import struct
import sys

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
sys.path.insert(0, TEST_DIR)

from engine_artifact import find_engine_lib  # noqa: E402

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def parse_def_exports(path):
    exports = set()
    in_exports = False
    with open(path, encoding="utf-8", errors="replace") as f:
        for line in f:
            s = line.strip()
            if s.upper() == "EXPORTS":
                in_exports = True
                continue
            if not in_exports or not s or s.startswith(";"):
                continue
            name = s.split()[0].split("@")[0]
            if name:
                exports.add(name)
    return exports


def elf_dynsym_names(path):
    """ELF64 小端 .dynsym 中 DEFINED 符号名集（SHN_UNDEF 的导入不计）。"""
    with open(path, "rb") as f:
        data = f.read()
    if data[:4] != b"\x7fELF" or data[4] != 2 or data[5] != 1:
        raise ValueError("not an ELF64 little-endian file")
    (shoff,) = struct.unpack_from("<Q", data, 0x28)
    shentsize, shnum, shstrndx = struct.unpack_from("<HHH", data, 0x3A)

    def shdr(i):
        off = shoff + i * shentsize
        name, typ, flags, addr, offset, size, link, info, align, entsize = \
            struct.unpack_from("<IIQQQQIIQQ", data, off)
        return {"type": typ, "offset": offset, "size": size,
                "link": link, "entsize": entsize}

    names = set()
    for i in range(shnum):
        sh = shdr(i)
        if sh["type"] != 11:  # SHT_DYNSYM
            continue
        strtab = shdr(sh["link"])
        count = sh["size"] // sh["entsize"]
        for j in range(count):
            off = sh["offset"] + j * sh["entsize"]
            st_name, st_info, st_other, st_shndx = \
                struct.unpack_from("<IBBH", data, off)
            if st_shndx == 0 or st_name == 0:  # SHN_UNDEF / 空名
                continue
            if st_info >> 4 not in (1, 2):  # GLOBAL / WEAK
                continue
            end = data.index(b"\x00", strtab["offset"] + st_name)
            names.add(data[strtab["offset"] + st_name:end].decode())
    return names


def main():
    lib_path = find_engine_lib()
    if not os.path.isfile(lib_path):
        print(f"SKIP: 引擎产物不存在（{lib_path}），先构建 Linux 引擎")
        return 0
    expected = parse_def_exports(os.path.join(ROOT, "engine",
                                              "auradsp_engine.def"))
    actual = elf_dynsym_names(lib_path)
    check(len(expected) == 56, f".def 导出集为 56 符号（实际 {len(expected)}）")
    missing = sorted(expected - actual)
    leaked = sorted(actual - expected)
    check(not missing, f".so 缺失导出：{missing if missing else '无'}")
    check(not leaked, f".so 多余导出（内部符号泄漏）：{leaked if leaked else '无'}")
    check(actual == expected,
          f"导出集与 .def 恒等（{len(actual)} 符号）")
    print("smoke_linux_engine_exports: " + ("FAIL" if FAILS else "PASS"))
    return 1 if FAILS else 0


if __name__ == "__main__":
    sys.exit(main())
