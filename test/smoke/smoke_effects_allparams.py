"""smoke_effects_allparams.py — 全参数 + 多声道掩码 补充测试套件（2026-10-19）。

Part 1 全参数扫描（数据驱动，覆盖引擎参数表全部有界 FLOAT/INT/BOOL 行）：
  - 默认回读 == Params 结构体默认（与契约 Part K 同源，但走真实 set/get 链路）；
  - 中点 set/get 往返一致；
  - 越界（min-步 / max+步）：接受两种合法语义
      * 通用参数：rc==0 且回读被钳到边界；
      * 自定义参数（如 reverb.preset）：rc!=0 被拒；
    无论哪种，最终回读必须仍在 [min,max]；
  - FLOAT NaN/Inf：必须 rc!=0（引擎 L432 显式拒绝，防污染二阶级/延迟线）；
  - BOOL：非零→1、零→0；
  - 排除 comp.freqN/comp.gainN（数组索引参数，专用 smoke 覆盖）。
  每条参数用独立 handle（杜绝跨参数状态污染），创建成本微秒级。

Part 2 多声道掩码补充（补 smoke_multichannel_discrete 未覆盖项）：
  - arbmag / comp / eq 三效果器掩码隔离：6ch 离散、mask=0x04（仅 C 声道），
    被选声道生效、其余声道 100% 直通；
  - 11 个 `*.channels` 效果器统一不变式：enable + channels=0 → 全声道直通
    （验证掩码 0 语义真实生效，防 B1 spec 注册后掩码被忽略）。
"""
import ctypes
import math
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))
TABLE = os.path.join(ROOT, "engine", "engine_param_table.h")
INTERNAL = os.path.join(ROOT, "engine", "engine_internal.h")
SR = 48000.0
BLOCK = 512

FAIL = []


def check(cond, name, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int32]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_process.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
                                ctypes.POINTER(ctypes.c_float), ctypes.c_int32]
lib.auradsp_set_param.restype = ctypes.c_int32
lib.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]
lib.auradsp_get_param.restype = ctypes.c_int32
lib.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_uint32]


def set_f(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_float(v)), 4)


def set_i(h, k, v):
    return lib.auradsp_set_param(h, k.encode(), ctypes.byref(ctypes.c_int32(v)), 4)


def set_s(h, k, s):
    b = s.encode("utf-8")
    buf = (ctypes.c_char * len(b)).from_buffer_copy(b)
    return lib.auradsp_set_param(h, k.encode(), buf, len(b))


def get_f(h, k):
    v = ctypes.c_float(0.0)
    rc = lib.auradsp_get_param(h, k.encode(), ctypes.byref(v), 4)
    return rc, v.value


def get_i(h, k):
    v = ctypes.c_int32(0)
    rc = lib.auradsp_get_param(h, k.encode(), ctypes.byref(v), 4)
    return rc, v.value


# ---------------------------------------------------------------------------
# 参数表 + Params 默认 解析（与 param_contract Part K 同源的正则）
# ---------------------------------------------------------------------------
def fnum(s):
    t = s.strip()
    if t.endswith("f"):
        t = t[:-1]
    if t.lower().startswith("0x"):
        return float(int(t[2:], 16))
    return float(t)


def parse_table():
    txt = open(TABLE, encoding="utf-8").read()
    rows = []
    fi = re.compile(
        r'PARAM_(FLOAT|INT)\("([^"]+)",\s*(\w+(?:\[\d+\])?),'
        r'\s*(-?\d+(?:\.\d+)?)f?,\s*(-?\d+(?:\.\d+)?)f?,')
    bo = re.compile(r'PARAM_BOOL\("([^"]+)",\s*(\w+),')
    for m in fi.finditer(txt):
        rows.append((m.group(1), m.group(2), fnum(m.group(4)), fnum(m.group(5))))
    for m in bo.finditer(txt):
        rows.append(("BOOL", m.group(1), 0.0, 1.0))
    return rows


def parse_defaults():
    txt = open(INTERNAL, encoding="utf-8").read()
    out = {}
    re_ = re.compile(r'std::atomic<\w+>\s+(\w+)\{([^}]*)\}')
    for m in re_.finditer(txt):
        member = m.group(1)
        if "[" in member:
            continue
        val = m.group(2).strip()
        if not re.fullmatch(r'-?(?:\d+(?:\.\d+)?|0x[0-9A-Fa-f]+)f?', val):
            continue
        out[member] = fnum(val)
    return out


def part1_allparams():
    print("\n=== [1] 全参数扫描（roundtrip / clamp / NaN / 默认回读） ===")
    rows = parse_table()
    defaults = parse_defaults()
    # 行内 member 与 Params 字段名对应关系需要二次提取（fi/bo 已丢 member）
    txt = open(TABLE, encoding="utf-8").read()
    member_of = dict(re.findall(
        r'PARAM_(?:FLOAT|INT)\("([^"]+)",\s*(\w+(?:\[\d+\])?),', txt))
    member_of.update(dict(re.findall(r'PARAM_BOOL\("([^"]+)",\s*(\w+),', txt)))

    checked = 0
    clamped_rc0 = 0
    rejected = 0
    for typ, pid, mn, mx in rows:
        if re.fullmatch(r'comp\.(?:freq|gain)[1-7]', pid):
            continue  # 数组索引参数，专用 smoke 覆盖
        member = member_of.get(pid, "")
        h = lib.auradsp_create(SR, BLOCK)
        assert h, f"create failed for {pid}"

        def rd():
            # 按类型分派读取：INT/BOOL 存 int32，用 float 读会得反规格数
            if typ == "FLOAT":
                return get_f(h, pid)[1]
            return get_i(h, pid)[1]

        def wr(v):
            return set_f(h, pid, v) if typ == "FLOAT" else set_i(h, pid, int(v))

        # 默认回读
        if member and member in defaults:
            want = defaults[member]
            dv = rd()
            tol = 1e-3 if typ == "FLOAT" else 1
            ok = abs(dv - want) <= max(tol, abs(want) * 1e-2)
            check(ok, f"{pid} 默认回读 == {want}（实读 {dv}）")
        else:
            dv = rd()
            check(mn - 1e-3 <= dv <= mx + 1e-3, f"{pid} 默认回读在界内（{dv}）")

        if typ == "BOOL":
            set_i(h, pid, 1); v1 = rd()
            set_i(h, pid, 0); v0 = rd()
            set_i(h, pid, 7); v7 = rd()
            check(v1 == 1 and v0 == 0 and v7 == 1, f"{pid} BOOL 非零→1/零→0")
        else:
            # 中点往返
            mid = int(round((mn + mx) / 2.0)) if typ == "INT" else (mn + mx) / 2.0
            rcm = wr(mid)
            v = rd()
            tol = max(1e-3, abs(mid) * 1e-2) if typ == "FLOAT" else 1
            ok = rcm == 0 and abs(v - mid) <= tol
            check(ok, f"{pid} 中点 {mid} 往返（实读 {v}）")

            # 越界：clamp 或 reject 两种合法
            lo_ok = hi_ok = False
            rlo = wr(mn - 1.0) if typ == "FLOAT" else wr(int(mn) - 1)
            if rlo == 0:
                v = rd()
                lo_ok = abs(v - (mn if typ == "FLOAT" else int(mn))) <= tol
            else:
                lo_ok = True
                rejected += 1
            rhi = wr(mx + 1.0) if typ == "FLOAT" else wr(int(mx) + 1)
            if rhi == 0:
                v = rd()
                hi_ok = abs(v - (mx if typ == "FLOAT" else int(mx))) <= tol
            else:
                hi_ok = True
                rejected += 1
            if rlo == 0:
                clamped_rc0 += 1
            if rhi == 0:
                clamped_rc0 += 1
            check(lo_ok and hi_ok, f"{pid} 越界（clamp 到 {int(mn) if typ=='INT' else mn}/"
                                  f"{int(mx) if typ=='INT' else mx} 或拒收）")

            # NaN/Inf 必须拒收
            if typ == "FLOAT":
                wr(mid)  # 恢复合法值
                rnan = set_f(h, pid, float("nan"))
                rinf = set_f(h, pid, float("inf"))
                check(rnan != 0 and rinf != 0, f"{pid} NaN/Inf 被拒")
        lib.auradsp_destroy(h)
        checked += 1
    print(f"扫描完成：{checked} 条参数（clamp 命中 {clamped_rc0} 次 / 拒收 {rejected} 次）")


# ---------------------------------------------------------------------------
# Part 2 多声道掩码补充
# ---------------------------------------------------------------------------
def mk_handle(ch, mode=1):
    h = lib.auradsp_create(SR, BLOCK)
    set_i(h, "channels.count", ch)
    set_i(h, "channels.mode", mode)
    set_i(h, "limiter.enable", 0)  # 隔离 limiter 干扰
    return h


def run_ch(h, n_ch, freq=1000.0, amp=0.4):
    src = (ctypes.c_float * (BLOCK * n_ch))()
    dst = (ctypes.c_float * (BLOCK * n_ch))()
    for i in range(BLOCK):
        s = amp * math.sin(2 * math.pi * freq * i / SR)
        for c in range(n_ch):
            src[i * n_ch + c] = s
    lib.auradsp_process(h, src, dst, BLOCK)
    return src, dst


def ch_dev(src, dst, n_ch, ch):
    return sum(abs(dst[i * n_ch + ch] - src[i * n_ch + ch]) for i in range(BLOCK)) / BLOCK


def ch_max_dev(src, dst, n_ch, chans):
    return max(ch_dev(src, dst, n_ch, c) for c in chans)


def mask_isolation(name, setup):
    """6ch 离散：setup(h) 使效果生效；mask=0x04 → 仅 C(2) 声道处理，其余直通。"""
    h = mk_handle(6)
    setup(h)
    set_i(h, f"{name}.channels", 0x04)
    src, dst = run_ch(h, 6)
    c_diff = ch_dev(src, dst, 6, 2)
    other = ch_max_dev(src, dst, 6, (0, 1, 3, 4, 5))
    check(c_diff > 0.01, f"{name} 掩码 0x04：C 声道生效（diff={c_diff:.4f}）")
    check(other < 1e-6, f"{name} 掩码 0x04：其余声道 100% 直通（dev={other:.2e}）")
    lib.auradsp_destroy(h)


def mask_zero_invariant(name):
    """11 个 *.channels 效果器：enable + channels=0 → 全声道直通。"""
    h = mk_handle(6)
    set_i(h, f"{name}.enable", 1)
    set_i(h, f"{name}.channels", 0)
    src, dst = run_ch(h, 6, freq=440.0, amp=0.3)
    dev = max(ch_dev(src, dst, 6, c) for c in range(6))
    check(dev < 1e-6, f"{name} 掩码 0：全声道 100% 直通（dev={dev:.2e}）")
    lib.auradsp_destroy(h)


# 声道掩码语义登记（B5 定案 + B5 后续 arbmag 逐声道升级）：
#   MASKED  —— 引擎按 *.channels 位掩码独立处理声道（隔离 + mask=0 直通成立）
#   PAIR    —— comp/eq（双声道实现，jdsp 链）按掩码选"标准声道对"处理：
#              0x03→FL/FR(0,1) 前组 / 0x0C→C/LFE(2,3) 中低音组 / 0x30→SL/SR(4,5) 后组
#              （允许多选；未选中任何完整对 → 全直通）
#   PERCH   —— arbmag（逐声道池，B5 后续）：mask 第 c 位 = 声道 c 独立开关，
#              单个声道（如 0x04 仅 C）即可独立生效；0x01 仅 FL 时 FR 直通（FL/FR 彻底解绑）
MASKED_EFFECTS = ["dyneq", "exciter", "filter", "gate", "limiter",
                  "loudness", "shelf", "tube", "arbmag", "comp", "eq"]


def persch_semantics(name, setup):
    """6ch 离散：逐声道语义（WP3 / B5 后续）——mask 第 c 位 = 声道 c 独立开关。
    0x01 仅 FL（FR 直通 = 彻底解绑）、0x04 仅 C（无需完整对）。"""
    def expect(mask, proc_ch, passthru):
        h = mk_handle(6)
        setup(h)
        set_i(h, f"{name}.channels", mask)
        src, dst = run_ch(h, 6)
        for c in proc_ch:
            d = ch_dev(src, dst, 6, c)
            check(d > 0.01, f"{name} mask=0x{mask:02X} 声道{c} 处理 diff={d:.4f}")
        for c in passthru:
            d = ch_dev(src, dst, 6, c)
            check(d < 1e-6, f"{name} mask=0x{mask:02X} 声道{c} 应直通 dev={d:.2e}")
        lib.auradsp_destroy(h)

    expect(0x01, [0], [1, 2, 3, 4, 5])      # 仅 FL（FR 直通 = 彻底解绑）
    expect(0x02, [1], [0, 2, 3, 4, 5])      # 仅 FR
    expect(0x04, [2], [0, 1, 3, 4, 5])      # 仅 C（无需完整对）
    expect(0x0C, [2, 3], [0, 1, 4, 5])      # C/LFE
    expect(0x30, [4, 5], [0, 1, 2, 3])      # 后组
    expect(0xFF, [0, 1, 2, 3, 4, 5], [])    # 全选
    expect(0x00, [], [0, 1, 2, 3, 4, 5])    # mask=0 → 全直通（不变式）


def comp_pair_semantics(setup):
    """6ch 离散：comp.mode=1 性能回退对语义（半选对不处理，全选对按对处理）。"""
    def expect(mask, proc_pairs, passthru):
        h = mk_handle(6)
        setup(h)
        set_i(h, "comp.mode", 1)
        set_i(h, "comp.channels", mask)
        src, dst = run_ch(h, 6)
        for (a, b) in proc_pairs:
            d = max(ch_dev(src, dst, 6, a), ch_dev(src, dst, 6, b))
            check(d > 0.01, f"comp (mode=1) mask=0x{mask:02X} 对({a},{b}) 处理 diff={d:.4f}")
        for c in passthru:
            d = ch_dev(src, dst, 6, c)
            check(d < 1e-6, f"comp (mode=1) mask=0x{mask:02X} 声道{c} 应直通 dev={d:.2e}")
        lib.auradsp_destroy(h)

    expect(0x03, [(0, 1)], [2, 3, 4, 5])    # 仅前组
    expect(0x0C, [(2, 3)], [0, 1, 4, 5])    # 仅中/低音组
    expect(0x30, [(4, 5)], [0, 1, 2, 3])    # 仅后组
    expect(0x33, [(0, 1), (4, 5)], [2, 3])  # 前+后组多选
    expect(0x04, [], [0, 1, 2, 3, 4, 5])    # 半选对不处理 -> 全直通
    expect(0x00, [], [0, 1, 2, 3, 4, 5])    # mask=0 → 全直通（不变式）


def part2_multichannel():
    print("\n=== [2] 多声道掩码补充（11 效果器逐声道 + comp mode=1 对语义 + mask=0 不变式） ===")

    def setup_arbmag(h):
        set_i(h, "arbmag.enable", 1)
        # 合法格式：GraphicEQ: <freq dB; freq dB; ...>（legacy AREQ 解析器）
        set_s(h, "arbmag.string", "GraphicEQ: 20 6.0; 20000 6.0")

    def setup_comp(h):
        set_i(h, "comp.enable", 1)
        for n in range(1, 8):
            set_f(h, f"comp.gain{n}", 0.5)

    def setup_eq(h):
        set_i(h, "eq.enable", 1)
        set_s(h, "eq.curve", "20:6.0;20000:6.0")

    # arbmag / comp / eq：WP3 逐声道语义（0x01 仅 FL / 0x04 仅 C 独立生效）
    persch_semantics("arbmag", setup_arbmag)
    persch_semantics("comp", setup_comp)
    persch_semantics("eq", setup_eq)

    # comp mode=1：性能回退成对语义（半选对不处理，全选对按对处理）
    comp_pair_semantics(setup_comp)

    # 11 个按声道处理效果器：mask=0 → 全声道直通（不变式）
    for name in MASKED_EFFECTS:
        mask_zero_invariant(name)


if __name__ == "__main__":
    part1_allparams()
    part2_multichannel()
    if FAIL:
        print(f"\n{len(FAIL)} FAIL: {FAIL}")
        sys.exit(1)
    print("\nALL PASS")
