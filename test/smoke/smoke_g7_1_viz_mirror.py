# -*- coding: utf-8 -*-
"""smoke_g7_1_viz_mirror.py — §7-1 门禁：`auradsp_viz_frame` 的 Python 镜像单源。

缺陷（全量审查 2026-10-24 / A1、A2、A3）：
    `auradsp_viz_frame` 的 ctypes 镜像在 `tools/` 与 `test/` 下**各有 8 份彼此
    独立的手抄件**（`tools/bin/verify_dll_copies.py`、`tools/probe/probe_viz_cost.py`
    和 6 个 `test/smoke/*.py`）。它们靠人肉同步。ABI v1→v2 让帧从 536B 长到
    1600B 时漏改了其中几份，那些脚本就按旧尺寸申请缓冲、引擎按新尺寸写 ——
    **堆越界，而且是静默的**（Python 不检查 ctypes 缓冲长度）。

    审查列出的三处缓冲越界（A1/A2/A3）全部出自这条通道，不是三个独立 bug，
    而是同一个 bug 的三个副本。只修副本不关门禁，下次改 ABI 会再生三个。

修法两层（缺一不可）：
    1. 单源：`tools/bin/viz_frame.py` 是唯一 Python 镜像，其余一律 `from viz_frame
       import VizFrame`；全仓再出现第二份定义就判红（M1）。
    2. 逐字段：光有 `sizeof == 1600` 不够 —— 字段顺序错但总长凑巧相同，仍然会
       读到错位数据。M2 解析 `engine/auradsp_engine.h` 的结构体，按 **名称 /
       偏移 / 尺寸** 逐字段比对。

本测试五层：
  [A] 判据单元：`defines_viz_frame` 的 8 个正反例（含"说明文字不得自命中"，
      以及本测试文件自身必须不被判红 —— 否则门禁一出生就是红的）
  [B] 全仓：0 份重复镜像 + 原 8 处已改为导入（精确集合，不是"看起来没违规"）
  [C] 字段级独立期望：11 字段的名称/偏移/尺寸硬编码表，同时比对 C 头解析结果、
      Python 镜像与 FIELD_OFFSETS —— 三方互证，不靠某一方自证
  [D] 反向判红：临时造第二份定义 / 篡改镜像字段 / 篡改 sizeof 哨兵 / 篡改 ABI
      版本，四项都必须被门禁抓到（改的是临时副本，不碰真相源）
  [E] 运行期活体：用真实 DLL 读帧，并用 0xCD 哨兵字节包裹缓冲 —— 引擎若越界
      写，哨兵必被踩（这才是 A1/A2/A3 的直接回归守卫）
"""
import ctypes
import io
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent.parent
BIN = ROOT / "tools" / "bin"
H_PATH = ROOT / "engine" / "auradsp_engine.h"
INTERNAL_H = ROOT / "engine" / "engine_internal.h"
MIRROR = BIN / "viz_frame.py"
DLL_PATH = ROOT / "core" / "desktop" / "windows" / "out" / "Release" / "auradsp_engine.dll"

sys.path.insert(0, str(BIN))
import abi_consistency as A  # noqa: E402
import viz_frame as VF  # noqa: E402

fails = []
passes = 0


def check(name, ok, note=""):
    global passes
    if ok:
        passes += 1
        print("PASS  %s%s" % (name, ("  (%s)" % note) if note else ""))
    else:
        fails.append(name)
        print("FAIL  %s%s" % (name, ("  (%s)" % note) if note else ""))


def read(p):
    with io.open(str(p), "r", encoding="utf-8", errors="replace") as f:
        return f.read()


# 期望布局（独立期望，手工从 auradsp_engine.h 抄下来的，不由任何一方的解析器生成）
#   字段名, 偏移, 尺寸
EXPECT_LAYOUT = [
    ("seq", 0, 8),
    ("timestamp_ms", 8, 8),
    ("spectrum", 16, 128),          # float[32]
    ("eq_in_spectrum", 144, 128),   # float[32]
    ("level_l_dbfs", 272, 4),
    ("level_r_dbfs", 276, 4),
    ("stage_levels_l", 280, 128),   # float[32]
    ("stage_levels_r", 408, 128),   # float[32]
    ("channel_count", 536, 4),      # ---- ABI v2 追加段起点 ----
    ("channel_levels", 540, 32),    # float[8]
    ("stage_ch_levels", 572, 1024),  # float[32*8]
]
EXPECT_SIZE = 1600                 # 1596 + 4 字节尾填充（结构含 uint64/double）

# 已知的手抄定义改导入方（验收对象：必须全部走 import，且全仓不许多出）。
# 原 8 处是 §7-1 改造对象；smoke_e4_stage16_crossmode.py 是其后第一个新增
# 消费方——它必须一开始就走导入，而不是再长出第 9 份手抄件。
KNOWN_IMPORTERS = [
    "test/smoke/smoke_block1056.py",
    "test/smoke/smoke_chain_meter.py",
    "test/smoke/smoke_dynamic_gr_and_gate.py",
    "test/smoke/smoke_eq_viz_tap.py",
    "test/smoke/smoke_mc_channel_levels.py",
    "test/smoke/smoke_viz_lowfreq.py",
    "tools/bin/verify_dll_copies.py",
    "tools/probe/probe_viz_cost.py",
    "test/smoke/smoke_e4_stage16_crossmode.py",
]

# ---------------------------------------------------------------------------
# 合成片段的拼装纪律
# ---------------------------------------------------------------------------
# 这些片段**不能写成字面量**：M1 扫描读的是 raw text，本文件里的字面量会被
# 自己命中（字段表的方括号字面量与 stage_ch_levels 元组挨在一起就成立），门禁一出
# 生就是红的 —— 正是 §7-1 要消灭的那类"自己命中自己"。所以下面的模板都靠
# 字符串拼接把相邻 token 拆开。[A0] 专门守着这条纪律：将来谁把它"顺手"改回
# 字面量，[A0] 会立刻判红并把原因写在断言名里。
_CLS = "class VizFrame(ctypes.Structure):"
_FIELDS_OPEN = "_fields_ =" + " ["
_FIELDS_CLOSE = "]"
_STAGE_ROW_DQ = '    ("stage_' + 'ch_levels", ctypes.c_float * (32 * 8)),'
_STAGE_ROW_SQ = "    ('stage_" + "ch_levels', ctypes.c_float * (32 * 8)),"
_STAGE_TALK = "# 说明：历史上这里还有 stage_" + "ch_levels 字段，已迁出"


def s_full_mirror():
    return "\n".join([
        _CLS,
        "    " + _FIELDS_OPEN,
        '        ("seq", ctypes.c_uint64),',
        _STAGE_ROW_DQ,
        "    " + _FIELDS_CLOSE,
    ])


def s_single_quotes():
    return "\n".join([_CLS, "    " + _FIELDS_OPEN, _STAGE_ROW_SQ, "    " + _FIELDS_CLOSE])


def s_talk_only():
    """只有说明文字提到字段名，没有 _fields_ 区域 —— 不得判红。"""
    return "\n".join([_CLS, "    " + _STAGE_TALK, '    ("seq", ctypes.c_uint64),'])


def s_v1_shape():
    """有 _fields_ 但没有 v2 才有的字段（v1 老镜像）—— 不得判红。"""
    return "\n".join([
        _CLS,
        "    " + _FIELDS_OPEN,
        '        ("seq", ctypes.c_uint64),',
        '        ("spectrum", ctypes.c_float * 32),',
        "    " + _FIELDS_CLOSE,
    ])


def s_import_form():
    return "from viz_frame import VizFrame"


def s_broken_brackets():
    """畸形文本（方括号没闭合）—— 不得抛异常，返回 False。"""
    return _CLS + "\n    " + _FIELDS_OPEN + "\n        " + _STAGE_ROW_DQ.strip()


# ------------------------------------------------------------------ [A] 判据单元
print("== [A] defines_viz_frame 判据单元 ==")

# [A0] 守纪律：本文件自身不得被判红
SELF = read(Path(__file__))
check("[A0] 本测试文件自身不被 M1 判红（拼装纪律仍有效）",
      not A.defines_viz_frame(SELF),
      "若失败：说明上方合成片段被改成了字面量，见「拼装纪律」注释")

A_CASES = [
    ("[A1] 完整手抄件 → True", s_full_mirror(), True),
    ("[A2] 只有说明文字提到字段名 → False", s_talk_only(), False),
    ("[A3] v1 老形状（无 v2 字段）→ False", s_v1_shape(), False),
    ("[A4] 已是导入形式 → False", s_import_form(), False),
    ("[A5] 单引号字段元组 → True（不因引号风格漏网）", s_single_quotes(), True),
    ("[A6] 无 ctypes.Structure 的普通脚本 → False",
     "x = 1\n" + _STAGE_ROW_DQ, False),
    ("[A7] 方括号未闭合的畸形文本 → False 且不抛异常", s_broken_brackets(), False),
]
for name, src, want in A_CASES:
    try:
        got = A.defines_viz_frame(src)
        err = ""
    except Exception as e:            # 判据自己崩了也是失败，不许当 False 糊过去
        got, err = True, "抛了 %s" % type(e).__name__
    check(name, got == want, err or ("got %r want %r" % (got, want)))

# ------------------------------------------------------------------ [B] 全仓
print("== [B] 全仓镜像单源 ==")

dup = A.find_duplicate_mirrors()
check("[B1] 全仓 0 份重复 VizFrame 定义", dup == [], ",".join(dup))

importers = []
IMPORT_LINE = re.compile(r"^\s*from viz_frame import VizFrame\b", re.M)
for base in ("tools", "test"):
    for p in (ROOT / base).rglob("*.py"):
        if IMPORT_LINE.search(read(p)):
            importers.append(str(p.relative_to(ROOT)).replace("\\", "/"))
importers = sorted(set(importers))
check("[B2] 导入 `from viz_frame import VizFrame` 的文件恰为已知 %d 处"
      % len(KNOWN_IMPORTERS),
      importers == sorted(KNOWN_IMPORTERS),
      "差异=" + json.dumps({"missing": sorted(set(KNOWN_IMPORTERS) - set(importers)),
                           "extra": sorted(set(importers) - set(KNOWN_IMPORTERS))},
                          ensure_ascii=False))

still_handwritten = [f for f in KNOWN_IMPORTERS
                     if A.defines_viz_frame(read(ROOT / f))]
check("[B3] 原 8 个文件均已不再手抄字段表", still_handwritten == [],
      ",".join(still_handwritten))

missing_files = [f for f in KNOWN_IMPORTERS if not (ROOT / f).exists()]
check("[B4] 已知导入方文件全部存在（防清单漂移）", missing_files == [],
      ",".join(missing_files))

r = subprocess.run([sys.executable, str(BIN / "abi_consistency.py"), "--viz-only"],
                   capture_output=True, text=True, encoding="utf-8", errors="replace",
                   cwd=str(ROOT))
check("[B5] CLI --viz-only 退出码 0", r.returncode == 0,
      (r.stdout or "") + (r.stderr or ""))
check("[B6] CLI 报告 11 字段 / 1600 字节",
      "11 字段 / 1600 字节" in r.stdout, r.stdout.strip()[-160:])

# ------------------------------------------------------------------ [C] 字段级
print("== [C] 字段级独立期望（C 头 / 镜像 / FIELD_OFFSETS 三方互证）==")

header_text = read(H_PATH)
try:
    c_fields = A.parse_c_struct(header_text, "auradsp_viz_frame")
    c_layout, c_size = A.layout_of(c_fields)
    c_err = ""
except ValueError as e:
    c_layout, c_size, c_err = [], 0, str(e)

check("[C1] C 头解析成功", not c_err, c_err)
check("[C2] C 侧布局 == 手工期望表（名称/偏移/尺寸）",
      c_layout == EXPECT_LAYOUT,
      "got=%r" % (c_layout,))
check("[C3] C 侧总尺寸 == 1600", c_size == EXPECT_SIZE, "got %d" % c_size)

py_layout = [(n, getattr(VF.VizFrame, n).offset, ctypes.sizeof(t))
             for n, t in VF.VizFrame._fields_]
check("[C4] Python 镜像布局 == 同一张期望表",
      py_layout == EXPECT_LAYOUT, "got=%r" % (py_layout,))
check("[C5] VIZ_FRAME_SIZE == 1600", VF.VIZ_FRAME_SIZE == EXPECT_SIZE,
      "got %d" % VF.VIZ_FRAME_SIZE)
check("[C6] FIELD_OFFSETS 与期望表逐项一致",
      VF.FIELD_OFFSETS == {n: off for n, off, _sz in EXPECT_LAYOUT},
      "got=%r" % (VF.FIELD_OFFSETS,))

# 尾填充：最后一字段止于 1596，sizeof 取到 1600（8 字节对齐，含 uint64/double）
last_end = EXPECT_LAYOUT[-1][1] + EXPECT_LAYOUT[-1][2]
check("[C7] 末字段止于 1596，尾填充 4 字节凑齐 1600",
      last_end == 1596 and EXPECT_SIZE - last_end == 4, "last_end=%d" % last_end)

# ------------------------------------------------------------------ [D] 反向判红
print("== [D] 反向判红（改临时副本，不碰真相源）==")

tmpdir = Path(tempfile.mkdtemp(prefix="auradsp_viz_"))
saved = (A.VIZ_MIRROR, A.H_PATH, A.INTERNAL_H)
probe_file = ROOT / "test" / "_tmp_dup_mirror_probe.py"
try:
    # D1：往 test/ 里放一份手抄件 → M1 必须点名它
    probe_file.write_text(s_full_mirror(), encoding="utf-8")
    dup2 = A.find_duplicate_mirrors()
    check("[D1] 临时新增手抄件被 M1 点名",
          "test/_tmp_dup_mirror_probe.py" in dup2, ",".join(dup2))
    probe_file.unlink()
    check("[D1b] 删除后恢复 0 违规", A.find_duplicate_mirrors() == [])

    # D2：镜像字段尺寸篡改（spectrum 32 → 16）。分两级：
    #   ① 只改字段、哨兵不动 → 镜像 import 期自带断言先炸，门禁须给出
    #      "[M2] 导入 Python 镜像失败"，而不是带 traceback 崩掉
    #   ② 连哨兵一起改成 1536 → import 能过，此时必须由逐字段比对抓住错位
    #      （只比 sizeof 的那套检查在这里会放行：1536 自成一致）
    src = read(MIRROR)
    tampered = src.replace('("spectrum", ctypes.c_float * 32)',
                           '("spectrum", ctypes.c_float * 16)')
    check("[D2-prep] 字段篡改确实改到了文本", tampered != src)

    def check_viz_with_mirror(text):
        (tmpdir / "viz_frame.py").write_text(text, encoding="utf-8")
        A.VIZ_MIRROR = tmpdir / "viz_frame.py"
        sys.modules.pop("viz_frame", None)
        sys.path.insert(0, str(tmpdir))
        probs = []
        try:
            A.check_viz(probs)
        finally:
            A.VIZ_MIRROR = saved[0]
            sys.modules.pop("viz_frame", None)
            if str(tmpdir) in sys.path:
                sys.path.remove(str(tmpdir))
        return probs

    p2a = check_viz_with_mirror(tampered)
    check("[D2a] 镜像尺寸错但哨兵未改 → 报导入失败（不崩）",
          any("导入 Python 镜像失败" in x for x in p2a), " | ".join(p2a)[:300])

    tampered_synced = tampered.replace("VIZ_FRAME_SIZE = 1600", "VIZ_FRAME_SIZE = 1536")
    check("[D2b-prep] 哨兵同步篡改", tampered_synced != tampered)
    p2b = check_viz_with_mirror(tampered_synced)
    check("[D2b] 绕过哨兵后由逐字段比对抓住 spectrum 错位",
          any("spectrum" in x for x in p2b) and any("不一致" in x for x in p2b),
          " | ".join(p2b)[:300])

    # D3：sizeof 哨兵改错（1600 → 1536）→ M3 必须报缺哨兵
    h2 = tmpdir / "auradsp_engine.h"
    h2.write_text(header_text.replace(
        "sizeof(auradsp_viz_frame) == 1600", "sizeof(auradsp_viz_frame) == 1536"),
        encoding="utf-8")
    check("[D3-prep] 哨兵篡改确实改到了文本", read(h2) != header_text)
    A.H_PATH = h2
    p3 = []
    try:
        A.check_viz(p3)
    finally:
        A.H_PATH = saved[1]
    check("[D3] sizeof 哨兵丢失 → M3 判红",
          any("编译期哨兵" in x for x in p3), " | ".join(p3)[:300])

    # D4：ABI 版本改错（AURADSP_ABI 2 → 3）→ M3 必须报版本不一致
    it2 = tmpdir / "engine_internal.h"
    it2.write_text(
        read(INTERNAL_H).replace("#define AURADSP_ABI 2", "#define AURADSP_ABI 3"),
        encoding="utf-8")
    check("[D4-prep] ABI 篡改确实改到了文本", read(it2) != read(INTERNAL_H))
    A.INTERNAL_H = it2
    p4 = []
    try:
        A.check_viz(p4)
    finally:
        A.INTERNAL_H = saved[2]
    check("[D4] ABI 版本不一致 → M3 判红",
          any("ABI 版本不一致" in x for x in p4), " | ".join(p4)[:300])

    # D5：还原后必须重新全绿（否则 D 层自己把真相源改坏了还不知道）
    p5 = []
    A.check_viz(p5)
    check("[D5] 还原后门禁重新 0 违规", p5 == [], " | ".join(p5)[:300])
finally:
    A.VIZ_MIRROR, A.H_PATH, A.INTERNAL_H = saved
    sys.modules.pop("viz_frame", None)
    if probe_file.exists():
        probe_file.unlink()
    shutil.rmtree(str(tmpdir), ignore_errors=True)

# ------------------------------------------------------------------ [E] 活体
print("== [E] 运行期活体：真实 DLL 读帧 + 越界哨兵 ==")

if not DLL_PATH.exists():
    print("SKIP  [E] 找不到 %s" % DLL_PATH)
else:
    dll = ctypes.CDLL(str(DLL_PATH))
    dll.auradsp_abi.restype = ctypes.c_int
    dll.auradsp_abi.argtypes = []
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float), ctypes.c_int]
    dll.auradsp_viz_read.argtypes = [ctypes.c_void_p, ctypes.POINTER(VF.VizFrame),
                                     ctypes.c_uint32]
    dll.auradsp_viz_read.restype = ctypes.c_uint32
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]

    check("[E1] 引擎 auradsp_abi() == 镜像 AURADSP_ABI",
          dll.auradsp_abi() == VF.AURADSP_ABI,
          "dll=%d mirror=%d" % (dll.auradsp_abi(), VF.AURADSP_ABI))

    N = 1024
    h = ctypes.c_void_p(dll.auradsp_create(48000.0, N))
    try:
        buf = (ctypes.c_float * (N * 2))()
        out = (ctypes.c_float * (N * 2))()
        for i in range(N):
            v = 0.5 * ((i * 440 * 2) % 48000) / 24000.0 - 0.5
            buf[i * 2] = v
            buf[i * 2 + 1] = v
        for _ in range(12):
            dll.auradsp_process(h, buf, out, N)

        # 关键：缓冲尾部留 256 字节 0xCD 哨兵。引擎若按比镜像更大的尺寸写，
        # 哨兵必被踩 —— 这正是 A1/A2/A3 三处静默堆越界的直接回归守卫。
        GUARD = 256
        n_frames = 8
        span = ctypes.sizeof(VF.VizFrame) * n_frames
        raw = ctypes.create_string_buffer(span + GUARD)
        ctypes.memset(raw, 0xCD, span + GUARD)
        got = dll.auradsp_viz_read(h, ctypes.cast(raw, ctypes.POINTER(VF.VizFrame)),
                                   n_frames)
        guard_ok = raw.raw[span:] == b"\xcd" * GUARD
        check("[E2] viz_read 返回 >=1 帧", got >= 1, "got %d" % got)
        check("[E2b] 引擎写入未越过镜像帧尺寸（256B 哨兵完好）", guard_ok,
              "越界 %d 字节" % sum(1 for b in raw.raw[span:] if b != 0xCD))

        frames = (VF.VizFrame * n_frames).from_buffer_copy(raw.raw[:span])
        seqs = [frames[i].seq for i in range(min(got, n_frames))]
        check("[E3] 读到的帧 seq 全非零", seqs and all(s > 0 for s in seqs), str(seqs))
        check("[E3b] seq 严格单调递增（同一通道顺序读）",
              all(b > a for a, b in zip(seqs, seqs[1:])), str(seqs))
        # 单声道输入 → 引擎应报 1..2 声道；越界值说明 channel_count 偏移读错了
        cc = frames[0].channel_count
        check("[E3c] channel_count 落在合理区间（1..8）", 1 <= cc <= 8, "got %d" % cc)
    finally:
        dll.auradsp_destroy(h)

print("\n" + "=" * 46)
if fails:
    print("FAILED %d / %d" % (len(fails), passes + len(fails)))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL PASS: %d 项断言，§7-1 viz 镜像单源门禁全绿" % passes)
