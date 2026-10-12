#!/usr/bin/env python3
# tools/abi_consistency.py — C ABI / .def 导出 / Dart FFI 绑定三处一致性检查
#
# E4（docs/插件模块深度改良方案-2026-10-12.md §4.6-7）：E1 的 show_editor
# 签名漂移（Dart 3 参 vs C 2 参，标题被静默丢弃）暴露了三处清单靠人肉
# 同步的脆弱性。本脚本逐条比对：
#   1. auradsp_engine.def   —— 实际导出符号
#   2. auradsp_engine.h     —— 头文件声明（函数名 + 形参数）
#   3. auradsp_ffi.dart     —— Dart lookup 绑定（符号名 + NativeFunction 形参数）
# 任何"导出未绑定 / 绑定了不存在的符号 / 元数不一致"都判 FAIL。
#
# 用法：python tools/abi_consistency.py（退出码 0 = 一致）

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DEF_PATH = ROOT / "core/desktop/engine_api/auradsp_engine.def"
H_PATH = ROOT / "core/desktop/engine_api/auradsp_engine.h"
DART_PATH = ROOT / "app/auradsp_app/lib/engine/auradsp_ffi.dart"


def parse_def(path: Path) -> set[str]:
    """.def EXPORTS 段：每行一个导出名（可能带 @ordinal，本工程不用）。"""
    exports = set()
    in_exports = False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip()
        if s.upper() == "EXPORTS":
            in_exports = True
            continue
        if not in_exports or not s or s.startswith(";"):
            continue
        m = re.match(r"^([A-Za-z_]\w*)\s*(?:@\d+)?$", s)
        if m:
            exports.add(m.group(1))
    return exports


def parse_header(path: Path) -> dict[str, int]:
    """engine.h 声明：返回 {函数名: 形参数}。

    声明可能跨行（如 auradsp_probe_eq_response），先合并空白再匹配。
    匹配形如 `int auradsp_xxx(...);` 的整段。
    """
    text = re.sub(r"\s+", " ", path.read_text(encoding="utf-8", errors="replace"))
    decls = {}
    # 形参表内不含 ';'（本工程无函数指针形参），按此分段。
    for m in re.finditer(
        r"([A-Za-z_]\w*(?:\s*\*)?)\s+(auradsp_\w+)\s*\(([^;]*?)\)\s*;", text
    ):
        name = m.group(2)
        params = m.group(3).strip()
        if params in ("", "void"):
            arity = 0
        else:
            # 顶层逗号计数：本工程形参均为标量/指针，无模板或函数指针。
            arity = len([p for p in params.split(",") if p.strip()])
        decls[name] = arity
    return decls


def parse_ffi(path: Path) -> dict[str, int]:
    """auradsp_ffi.dart 绑定：返回 {符号名: NativeFunction 形参数}。

    lookup 调用跨多行，先折叠空白。形参表同样按顶层逗号计数
    （Pointer<Float> 等泛型不含逗号于顶层——Int32, Float 等按逗号分隔）。
    """
    text = re.sub(r"\s+", " ", path.read_text(encoding="utf-8", errors="replace"))
    binds = {}
    # 返回类型可能是泛型（Pointer<Void>/Pointer<Utf8>），用 <...> 组兼容。
    for m in re.finditer(
        r"lookup<\s*NativeFunction<\s*\w+(?:\s*<[^>]*>)?\s*\*?\s+Function\s*\(([^)]*)\)\s*>>"
        r"\s*\(\s*'(auradsp_\w+)'\s*\)",
        text,
    ):
        params = m.group(1).strip()
        arity = 0 if params in ("", "void") else len([p for p in params.split(",") if p.strip()])
        binds[m.group(2)] = arity
    return binds


def main() -> int:
    for p in (DEF_PATH, H_PATH, DART_PATH):
        if not p.exists():
            print(f"[FAIL] missing source: {p}")
            return 1

    exports = parse_def(DEF_PATH)
    header = parse_header(H_PATH)
    ffi = parse_ffi(DART_PATH)

    problems: list[str] = []

    # 1) .def 与 engine.h：每个导出必须有头声明，且元数一致
    for name in sorted(exports):
        if name not in header:
            problems.append(f".def 导出 {name} 在 auradsp_engine.h 无声明")
    for name in sorted(header):
        if name not in exports:
            problems.append(f"engine.h 声明 {name} 未列入 .def 导出")

    # 2) Dart FFI 与 .def：绑定集合必须与导出集合一一对应
    for name in sorted(exports):
        if name not in ffi:
            problems.append(f"导出 {name} 在 auradsp_ffi.dart 无绑定")
    for name in sorted(ffi):
        if name not in exports:
            problems.append(f"Dart 绑定 {name} 不是 .def 导出符号")

    # 3) 元数一致：engine.h 声明 vs Dart NativeFunction（E1 类漂移的机器防线）
    for name in sorted(set(header) & set(ffi)):
        if header[name] != ffi[name]:
            problems.append(
                f"元数不一致 {name}: engine.h {header[name]} 参 vs "
                f"ffi.dart {ffi[name]} 参"
            )

    n = len(exports)
    if problems:
        print(f"[FAIL] ABI 不一致（导出 {n} 个，问题 {len(problems)} 项）：")
        for p in problems:
            print(f"  - {p}")
        return 1
    print(f"[PASS] ABI 一致：.def/engine.h/ffi.dart 三处 {n} 个符号逐一对应，元数全部一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
