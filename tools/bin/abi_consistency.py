#!/usr/bin/env python3
# tools/bin/abi_consistency.py — C ABI / .def 导出 / Dart FFI 绑定 / viz 帧布局一致性检查
#
# E4（docs/插件模块深度改良方案-2026-10-12.md §4.6-7）：E1 的 show_editor
# 签名漂移（Dart 3 参 vs C 2 参，标题被静默丢弃）暴露了三处清单靠人肉
# 同步的脆弱性。本脚本逐条比对：
#   1. auradsp_engine.def   —— 实际导出符号
#   2. auradsp_engine.h     —— 头文件声明（函数名 + 形参数）
#   3. auradsp_ffi.dart     —— Dart lookup 绑定（符号名 + NativeFunction 形参数）
# 任何"导出未绑定 / 绑定了不存在的符号 / 元数不一致"都判 FAIL。
#
# §7-1（全量审查 2026-10-24）：补 viz 帧布局的门禁。审查的 A1/A2/A3 三处缓冲
# 越界全部来自同一条通道——`auradsp_viz_frame` 的 Python 镜像在 tools/ 与 test/
# 下有 8 份彼此独立的手抄件，改头文件时漏改一份，那个脚本就按旧尺寸申请缓冲、
# 引擎按新尺寸写，静默堆越界。三项检查：
#   M1 镜像单源：tools/ 与 test/ 下不许再出现第二份 VizFrame 定义
#   M2 字段级对齐：解析 auradsp_engine.h 的结构体，用 ctypes 重建期望布局，
#      与 tools/bin/viz_frame.py 逐字段比对 **名称 / 偏移 / 尺寸**
#      （只查 sizeof 不够：字段顺序错但总长凑巧相同仍会读到错位数据）
#   M3 版本联动：头文件的尺寸哨兵仍在，且 AURADSP_ABI 与 Python 侧一致
#
# §7-5（全量审查 2026-10-24）：补三座桥（asio/vaio/vb）的清单一致性。
#   每座桥有三处清单靠人肉同步——.def 导出、头文件声明、Dart lookup——实测
#   三桥全漂且方向不同（asio/vaio 少导出 slot_{set,get}_channels，Dart 硬
#   lookup 会抛；vb 的 auto_protect/protect_test 只在 .def 里，头文件没声明）。
#   B1 .def ↔ 头文件 1:1（双向都查）/ B2 Dart 硬绑定符号必须真的导出 /
#   B3 Dart typedef 元数 vs C 声明元数
#
# 用法：python tools/bin/abi_consistency.py（退出码 0 = 一致）
#      python tools/bin/abi_consistency.py --viz-only（只跑 §7-1 三项）
#      python tools/bin/abi_consistency.py --bridges-only（只跑 §7-5 三项）

import ctypes
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
DEF_PATH = ROOT / "engine/auradsp_engine.def"
H_PATH = ROOT / "engine/auradsp_engine.h"
INTERNAL_H = ROOT / "engine/engine_internal.h"
DART_PATH = ROOT / "app/auradsp_app/lib/engine/auradsp_ffi.dart"
VIZ_MIRROR = ROOT / "tools/bin/viz_frame.py"

# ctypes 类型映射（本工程结构体只用这几类定长整数/浮点）
C_TYPE_MAP = {
    "uint64_t": ctypes.c_uint64, "uint32_t": ctypes.c_uint32,
    "uint16_t": ctypes.c_uint16, "uint8_t": ctypes.c_uint8,
    "int64_t": ctypes.c_int64, "int32_t": ctypes.c_int32,
    "int16_t": ctypes.c_int16, "int8_t": ctypes.c_int8,
    "double": ctypes.c_double, "float": ctypes.c_float,
    "int": ctypes.c_int, "unsigned": ctypes.c_uint, "char": ctypes.c_char,
}


def parse_def(path: Path) -> set[str]:
    """.def EXPORTS 段：每行一个导出名（可能带 @ordinal / PRIVATE，本工程不用 ordinal）。"""
    exports = set()
    in_exports = False
    for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
        s = line.strip()
        if s.upper() == "EXPORTS":
            in_exports = True
            continue
        if not in_exports or not s or s.startswith(";"):
            continue
        m = re.match(r"^([A-Za-z_]\w*)\s*(?:@\d+)?(?:\s+(?:PRIVATE|DATA))?\s*$", s)
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


# ------------------------------------------------------------------ §7-1 viz 布局


def strip_c_comments(text: str) -> str:
    """去掉 // 与 /* */ 注释，保留字符串（结构体里没有字符串，但求稳）。"""
    out, i, n = [], 0, len(text)
    while i < n:
        two = text[i:i + 2]
        if two == "//":
            j = text.find("\n", i)
            i = n if j < 0 else j
        elif two == "/*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
        elif text[i] in "\"'":
            q = text[i]
            while i < n:
                out.append(text[i])
                if text[i] == "\\" and i + 1 < n:
                    out.append(text[i + 1])
                    i += 2
                    continue
                i += 1
                if i <= n and out[-1] == q:
                    break
        else:
            out.append(text[i])
            i += 1
    return "".join(out)


def parse_defines(text: str) -> dict[str, int]:
    return {m.group(1): int(m.group(2))
            for m in re.finditer(r"^\s*#\s*define\s+([A-Z_]\w*)\s+(\d+)\b", text, re.M)}


def parse_c_struct(text: str, name: str):
    """解析 `typedef struct <name> { ... } <name>;` 的字段表。

    返回 [(字段名, ctypes 类型)]，数组维度里的宏已解析。
    解析不了的一律抛 ValueError——宁可门禁报错，也不要静默跳过一段字段。
    """
    defines = parse_defines(text)
    cleaned = strip_c_comments(text)
    m = re.search(r"typedef\s+struct\s+" + name + r"\s*\{(.*?)\}\s*" + name + r"\s*;",
                  cleaned, re.S)
    if not m:
        raise ValueError("找不到结构体定义：%s" % name)
    body = m.group(1)
    fields = []
    for raw in body.split(";"):
        decl = " ".join(raw.split())
        if not decl:
            continue
        dm = re.match(r"^([A-Za-z_]\w*(?:\s+(?:int|long|char))?)\s+([A-Za-z_]\w*)"
                      r"((?:\s*\[\s*[A-Za-z_0-9]+\s*\])*)$", decl)
        if not dm:
            raise ValueError("无法解析字段声明：%r" % decl)
        ctype_name, field, dims = dm.group(1), dm.group(2), dm.group(3)
        if ctype_name not in C_TYPE_MAP:
            raise ValueError("未知 C 类型 %r（字段 %s）——请在 C_TYPE_MAP 里登记"
                             % (ctype_name, field))
        ctype = C_TYPE_MAP[ctype_name]
        for d in re.findall(r"\[\s*([A-Za-z_0-9]+)\s*\]", dims):
            n = int(d) if d.isdigit() else defines.get(d)
            if n is None:
                raise ValueError("数组维度 %r 未定义（字段 %s）" % (d, field))
            ctype = ctype * n
        fields.append((field, ctype))
    if not fields:
        raise ValueError("结构体 %s 解析出 0 个字段" % name)
    return fields


def layout_of(fields):
    """用 ctypes 重建布局，返回 [(字段名, 偏移, 尺寸)] 与总尺寸。"""
    T = type("ExpectedFrame", (ctypes.Structure,), {"_fields_": fields})
    return [(n, getattr(T, n).offset, ctypes.sizeof(t)) for n, t in fields], ctypes.sizeof(T)


def load_viz_mirror():
    """导入 tools/bin/viz_frame.py（唯一 Python 镜像）。

    返回 (模块, 字段表[(名, 尺寸)], 总尺寸, ABI)。
    """
    sys.path.insert(0, str(VIZ_MIRROR.parent))
    import viz_frame  # noqa: E402
    fields = [(n, ctypes.sizeof(t)) for n, t in viz_frame.VizFrame._fields_]
    return viz_frame, fields, ctypes.sizeof(viz_frame.VizFrame), viz_frame.AURADSP_ABI


def _bracket_region(text: str, start: int, open_ch: str = "[", close_ch: str = "]"):
    """从 text[start] 处的开括号起，返回配对闭括号之后的下标；失败返回 -1。"""
    depth = 0
    for i in range(start, len(text)):
        if text[i] == open_ch:
            depth += 1
        elif text[i] == close_ch:
            depth -= 1
            if depth == 0:
                return i + 1
    return -1


# 判据用的字段元组：`("stage_ch_levels", ...)`。取最后追加的这个字段是因为它
# 只在 ABI v2 之后存在——v1 的镜像即使存在也不会有它，而我们要抓的正是「还在
# 按旧尺寸/旧形状定义」的那些。
VIZ_FIELD_TUPLE = re.compile(r"\(\s*[\"']stage_ch_levels[\"']\s*,")


def defines_viz_frame(text: str) -> bool:
    """纯判据：这段 Python 源码是否手抄了 VizFrame 的字段表。

    只在 `_fields_ = [...]` 的方括号区域内匹配，而不是全文匹配——否则解释判据
    的说明文字（不得不引用这个字段名）会自己命中自己，门禁一出生就是红的。
    抽成纯函数是为了可单测、可反向验证（smoke_g7_1_viz_mirror.py 的 A/D 层直接
    喂合成片段，不必造真文件）。
    """
    if "ctypes.Structure" not in text:
        return False
    for m in re.finditer(r"_fields_\s*=\s*\[", text):
        start = m.end() - 1
        end = _bracket_region(text, start)
        if end < 0:
            continue
        if VIZ_FIELD_TUPLE.search(text[start:end]):
            return True
    return False


def find_duplicate_mirrors() -> list[str]:
    """M1：扫描 tools/ 与 test/ 下是否还有第二份 VizFrame 定义。

    改造前这里有 8 份彼此独立的手抄件，A1/A2/A3 三处缓冲越界全部源于漏改其中
    一份——头文件 sizeof 变了，漏改的脚本仍按旧尺寸申请缓冲、引擎按新尺寸写。
    """
    hits = []
    for base in ("tools", "test"):
        for p in (ROOT / base).rglob("*.py"):
            if p.resolve() == VIZ_MIRROR.resolve():
                continue
            t = p.read_text(encoding="utf-8", errors="replace")
            if defines_viz_frame(t):
                hits.append(str(p.relative_to(ROOT)).replace("\\", "/"))
    return sorted(set(hits))


def check_viz(problems: list[str]) -> tuple[int, int]:
    """§7-1 三项。返回 (帧字节数, 字段数)；失败时往 problems 里追加。"""
    if not H_PATH.exists():
        problems.append("[M1] 缺少 %s" % H_PATH)
        return 0, 0
    header_text = H_PATH.read_text(encoding="utf-8", errors="replace")

    # ---- M1 镜像单源 ----
    dup = find_duplicate_mirrors()
    for d in dup:
        problems.append("[M1] 发现第二份 VizFrame 定义：%s（应改为 "
                        "from viz_frame import VizFrame）" % d)
    if not VIZ_MIRROR.exists():
        problems.append("[M1] 缺少唯一镜像 %s" % VIZ_MIRROR)

    # ---- M2 字段级对齐 ----
    try:
        c_fields = parse_c_struct(header_text, "auradsp_viz_frame")
    except ValueError as e:
        problems.append("[M2] 解析 C 结构体失败：%s" % e)
        return 0, 0
    c_layout, c_size = layout_of(c_fields)

    py_mod, py_fields, py_size, py_abi = None, None, None, None
    try:
        py_mod, py_fields, py_size, py_abi = load_viz_mirror()
    except Exception as e:
        # 镜像自己带 import 期 sizeof 哨兵。它先炸说明镜像已经错了——这时不能
        # 让门禁带着 traceback 崩掉（崩溃也算红，但看不出是"哪一项"错的）。
        problems.append("[M2] 导入 Python 镜像失败：%s: %s" % (type(e).__name__, e))
        return c_size, len(c_fields)

    c_names = [n for n, _off, _sz in c_layout]
    py_names = [n for n, _ in py_fields]
    if c_names != py_names:
        # 逐位指出第一个不一致处，便于定位
        for i, (a, b) in enumerate(zip(c_names, py_names)):
            if a != b:
                problems.append("[M2] 字段顺序/名称在第 %d 项分叉：C 是 %r，"
                                "Python 镜像 %r" % (i, a, b))
                break
        if len(c_names) != len(py_names):
            problems.append("[M2] 字段数不一致：C %d 个，Python %d 个"
                            % (len(c_names), len(py_names)))
    else:
        # 名称对齐后逐字段比 尺寸 与 偏移（只比总长不够：字段顺序错但总长
        # 凑巧相同，仍然会读到错位数据）
        # 注意：循环变量不能叫 c_size——Python 的 for 变量泄漏到函数作用域，
        # 会把外层的总尺寸覆盖掉（第一版就是这么错的，门禁报出 "C 1024 字节"）。
        for (name, c_off, c_fsize), (_pyname, py_fsize) in zip(c_layout, py_fields):
            if c_fsize != py_fsize:
                problems.append("[M2] 字段 %s 尺寸不一致：C %d 字节，Python %d 字节"
                                % (name, c_fsize, py_fsize))
            py_off = getattr(py_mod.VizFrame, name).offset
            if py_off != c_off:
                problems.append("[M2] 字段 %s 偏移不一致：C %d，Python %d"
                                % (name, c_off, py_off))

    if c_size != py_size:
        problems.append("[M2] 总尺寸不一致：C %d 字节，Python %d 字节"
                        % (c_size, py_size))

    # ---- M3 版本/尺寸联动 ----
    if not re.search(r"sizeof\s*\(\s*auradsp_viz_frame\s*\)\s*==\s*%d" % c_size, header_text):
        problems.append("[M3] 头文件缺少 `sizeof(auradsp_viz_frame) == %d` 编译期哨兵"
                        % c_size)
    if py_mod.VIZ_FRAME_SIZE != c_size:
        problems.append("[M3] viz_frame.VIZ_FRAME_SIZE=%d 与 C 实际 %d 不一致"
                        % (py_mod.VIZ_FRAME_SIZE, c_size))
    if INTERNAL_H.exists():
        t = INTERNAL_H.read_text(encoding="utf-8", errors="replace")
        m = re.search(r"^\s*#\s*define\s+AURADSP_ABI\s+(\d+)\b", t, re.M)
        if not m:
            problems.append("[M3] engine_internal.h 找不到 AURADSP_ABI 定义")
        elif int(m.group(1)) != py_abi:
            problems.append("[M3] ABI 版本不一致：engine_internal.h=%s，"
                            "viz_frame.py=%d" % (m.group(1), py_abi))
    else:
        problems.append("[M3] 缺少 %s" % INTERNAL_H)

    return c_size, len(c_fields)


# ------------------------------------------------------------------ §7-5 桥导出
#
# 审查 §7-5（原报告只点了 asio/vaio 各漏 2 项，这里把三座桥一并纳管）：
#   三座桥 DLL（auraasio_bridge / auravaio_bridge / auravm_bridge）各有三处清单
#   需要彼此对应——.def 导出、头文件声明、Dart lookup——靠人肉同步。实测三座桥
#   全部漂移，且漂移方向不同：
#     asio  头文件 28 项 / .def 26 项 → 少导出 slot_{set,get}_channels
#     vaio  头文件 27 项 / .def 25 项 → 同上
#     vb    .def 40 项 / 头文件 38 项  → 多导出 vb_plugin_auto_protect、
#            vb_protect_test（cpp 里都有实现，唯独头文件没声明）
#
# 前两座桥的漏导出**不是"少个功能"，而是会抛异常**：bridge_plugin_ffi.dart 的
# 构造函数对 *_plugin_slot_{set,get}_channels 做的是硬 lookup（不像 _g 系列那
# 6 个走 try/catch 置 null），asio/vaio 后端下一碰插件槽就 ArgumentError，再被
# 上层 catch 静默吞掉 → 插件功能整块不可用且无痕。

BRIDGE_DIR = ROOT / "core/desktop/windows-drivers/bridge"
BRIDGE_FFI = ROOT / "app/auradsp_app/lib/engine/bridge_plugin_ffi.dart"

BRIDGES = [
    ("asio", BRIDGE_DIR / "asio_bridge/AsioBridge.h",
     BRIDGE_DIR / "asio_bridge/AsioBridge.def"),
    ("vaio", BRIDGE_DIR / "vaio_bridge/VaioBridge.h",
     BRIDGE_DIR / "vaio_bridge/VaioBridge.def"),
    ("vb", BRIDGE_DIR / "vm_bridge/VmBridge.h",
     BRIDGE_DIR / "vm_bridge/VmBridge.def"),
]


def _arity(params: str) -> int:
    params = params.strip()
    return 0 if params in ("", "void") else len([p for p in params.split(",") if p.strip()])


def parse_bridge_header(path: Path) -> dict[str, int]:
    """桥头文件的导出声明 → {符号: 形参数}。

    先剥注释：三座桥的头文件里有大段带引号的 JSON 示例注释，不剥会误匹配。
    只认 `(asio|vaio|vb)_xxx(...);` 形式，宏（ASB_API 等）不参与匹配。
    """
    text = strip_c_comments(path.read_text(encoding="utf-8", errors="replace"))
    decls = {}
    for m in re.finditer(r"\b((?:asio|vaio|vb)_\w+)\s*\(([^;{}]*)\)\s*;", text):
        name, ar = m.group(1), _arity(m.group(2))
        if name in decls and decls[name] != ar:
            raise ValueError("同一符号两种元数：%s %d/%d" % (name, decls[name], ar))
        decls[name] = ar
    return decls


def parse_bridge_ffi(path: Path) -> tuple[dict[str, int], dict[str, int]]:
    """bridge_plugin_ffi.dart 的 `${prefix}<suffix>` 绑定。

    返 (必需, 可选)。判据：
      · 字段声明为 `late final X? _f;`（可空）+ 走 `_lookupYyy(...)` 帮助函数
        → 可选：老桥 DLL 没这个导出时 lookup 抛 ArgumentError 被 helper 吃掉，
        调用方回落。`_g` 系列 6 个属于这一类。
      · 其余 `late final X _f;` + 直接 `dylib.lookupFunction<...>` → 必需，
        少一个符号构造就抛。
    元数取自对应的 C 侧 typedef（`typedef _XxxC = Int32 Function(...)`），
    这样能和头文件声明直接比——Dart 签名漂移（E1 那类）也能被抓到。
    """
    raw = path.read_text(encoding="utf-8", errors="replace")
    flat = re.sub(r"\s+", " ", raw)

    arity_of = {}
    for m in re.finditer(r"typedef\s+(\w+)C\s*=\s*\w+(?:\s*<[^>]*>)?\s+Function\s*\(([^)]*)\)\s*;",
                         flat):
        arity_of[m.group(1)] = _arity(m.group(2))

    optional_fields = set(re.findall(r"late final[\w<>,\s]*?\?\s+(_\w+)\s*;", raw))

    required, optional = {}, {}
    # 直接 lookup：_f = dylib.lookupFunction<_SlotLoadC, _SlotLoadDart>('${prefix}xxx');
    for m in re.finditer(
            r"(_\w+)\s*=\s*dylib\.lookupFunction\s*<\s*(\w+)C\s*,\s*(\w+)Dart\s*>\s*"
            r"\(\s*'\$\{prefix\}([A-Za-z_0-9]+)'\s*\)", flat):
        field, ctype, suffix = m.group(1), m.group(2), m.group(4)
        target = optional if field in optional_fields else required
        target[suffix] = arity_of.get(ctype, -1)
    # 帮助函数形式：_f = _lookupXxx('${prefix}xxx');（一律可空）
    for m in re.finditer(r"(_\w+)\s*=\s*_lookup\w+\s*\(\s*'\$\{prefix\}([A-Za-z_0-9]+)'\s*\)",
                         flat):
        suffix = m.group(2)
        optional[suffix] = -1     # 帮助函数未暴露 C typedef，元数另比对
    return required, optional


def check_bridges(problems: list[str]) -> tuple[int, int]:
    """§7-5 三项：.def ↔ 头文件 1:1、Dart 必需符号齐全、元数一致。

    返回 (桥数, 总符号数)。失败时往 problems 里追加。
    """
    for p in (BRIDGE_FFI,):
        if not p.exists():
            problems.append("[B0] 缺少 %s" % p)
            return 0, 0
    required, optional = parse_bridge_ffi(BRIDGE_FFI)
    total = 0

    for prefix, h_path, def_path in BRIDGES:
        if not h_path.exists() or not def_path.exists():
            problems.append("[B1] %s 桥缺少 %s 或 %s"
                            % (prefix, h_path.name, def_path.name))
            continue
        try:
            header = parse_bridge_header(h_path)
        except ValueError as e:
            problems.append("[B1] %s 桥头文件解析失败：%s" % (prefix, e))
            continue
        exports = parse_def(def_path)
        total += len(exports)

        # B1：.def ↔ 头文件 1:1，双向都查（两个方向的漏法表现完全不同）
        for name in sorted(header.keys() - exports):
            problems.append("[B1] %s.def 漏导出 %s（头文件已声明，Dart 可能已在调用）"
                            % (prefix, name))
        for name in sorted(exports - header.keys()):
            problems.append("[B1] %s.def 导出了 %s，但头文件没有声明"
                            "（调用方 include 本头拿不到原型）" % (prefix, name))

        # B2：Dart 硬绑定的符号必须真的导出（少一个 → 构造抛 ArgumentError）
        for suffix, dart_ar in sorted(required.items()):
            sym = prefix + suffix
            if sym not in exports:
                problems.append("[B2] Dart 硬绑定 %s 在 %s.def 里没有导出"
                                "（asio/vaio 这类桥下插件槽会直接抛 ArgumentError）"
                                % (sym, prefix))
                continue
            # B3：元数一致（Dart typedef vs C 声明）
            if sym in header and dart_ar >= 0 and header[sym] != dart_ar:
                problems.append("[B3] 元数不一致 %s：头文件 %d 参 vs Dart %d 参"
                                % (sym, header[sym], dart_ar))

        # 可选符号（_g 系列）不存在不算错——那正是 ABI 协商的回落路径；
        # 存在性/元数已由 B1 的 1:1 检查覆盖，这里不再单查。

    return len(BRIDGES), total


def main() -> int:
    viz_only = "--viz-only" in sys.argv
    bridges_only = "--bridges-only" in sys.argv
    problems: list[str] = []
    n_exports = 0

    if not viz_only and not bridges_only:
        for p in (DEF_PATH, H_PATH, DART_PATH):
            if not p.exists():
                print(f"[FAIL] missing source: {p}")
                return 1

        exports = parse_def(DEF_PATH)
        header = parse_header(H_PATH)
        ffi = parse_ffi(DART_PATH)
        n_exports = len(exports)

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

    # 4) §7-1 viz 帧布局
    frame_size, n_fields = 0, 0
    if not bridges_only:
        frame_size, n_fields = check_viz(problems)

    # 5) §7-5 三座桥：.def ↔ 头文件 ↔ Dart 必需/可选符号
    n_bridges, n_bridge_syms = 0, 0
    if not viz_only:
        n_bridges, n_bridge_syms = check_bridges(problems)

    if problems:
        if viz_only:
            scope = "viz 帧"
        elif bridges_only:
            scope = "三座桥 %d 个符号" % n_bridge_syms
        else:
            scope = f"导出 {n_exports} 个 + viz 帧 + 三座桥 {n_bridge_syms} 个符号"
        print(f"[FAIL] ABI 不一致（{scope}，问题 {len(problems)} 项）：")
        for p in problems:
            print(f"  - {p}")
        return 1

    if bridges_only:
        print(f"[PASS] 三座桥 ABI 一致：{n_bridge_syms} 个导出与头文件声明 1:1，"
              f"Dart 硬绑定符号齐全、元数一致")
        return 0
    print(f"[PASS] ABI 一致：.def/engine.h/ffi.dart 三处 {n_exports} 个符号逐一对应，"
          f"元数全部一致")
    print(f"[PASS] viz 帧布局一致：{n_fields} 字段 / {frame_size} 字节，"
          f"C 头 ↔ Python 镜像逐字段对齐，无重复镜像")
    print(f"[PASS] 三座桥 ABI 一致：{n_bridges} 座桥共 {n_bridge_syms} 个导出与头文件"
          f"声明 1:1，Dart 硬绑定符号齐全、元数一致")
    return 0


if __name__ == "__main__":
    sys.exit(main())
