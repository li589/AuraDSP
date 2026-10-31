#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""prefix_toggle.py — 反向验证工具：在「修复版」与「pre-fix 还原版」之间切换。

用途：P-047 专项的反向验证（临时还原 pre-fix 行为重建 DLL，核心断言须转红）。
本脚本只做**精确字节替换**，不做任何模糊匹配；任一替换未命中即整体失败并退出，
避免出现「半还原」的中间态被当成有效验证。

用法：
    python tools/probe/prefix_toggle.py revert    # 还原 pre-fix 行为
    python tools/probe/prefix_toggle.py restore   # 还原修复版行为
    python tools/probe/prefix_toggle.py status    # 打印当前处于哪种状态
    python tools/probe/prefix_toggle.py verify    # 校验当前 == 修复版（比对内嵌 SHA256）

警告：本脚本会**改写仓库源文件**。`revert` 之后必须重建引擎才能让改动生效；
验证完务必 `restore` 并再次重建，且用 `verify` 确认已回到修复版。
"""
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

EDITS = {
    "engine/chain/engine_chain.cpp": [
        # 1) eq 池：直接重装活动槽（与 RT 的 Process 竞争 ⇒ UAF）
        (
            "    const double deadline = pool_now_ms() + kPoolSlotWaitMs;\n"
            "    const int shadow = pool_pick_shadow(h->eq_pool.bank, h->eq_pool.active,\n"
            "                                        h->eq_pool.proc_count, h->eq_pool.in_flight,\n"
            "                                        deadline);\n",
            "    const double deadline = pool_now_ms() + kPoolSlotWaitMs;\n"
            "    /* PRE-FIX */\n"
            "    const int shadow = h->eq_pool.active.load(std::memory_order_acquire);\n"
            "    (void)deadline;\n",
        ),
        # 2) arbmag 池：同上
        (
            "    const double deadline = pool_now_ms() + kPoolSlotWaitMs;\n"
            "    const int shadow = pool_pick_shadow(h->arbmag_pool.bank, h->arbmag_pool.active,\n"
            "                                        h->arbmag_pool.proc_count, h->arbmag_pool.in_flight,\n"
            "                                        deadline);\n",
            "    const double deadline = pool_now_ms() + kPoolSlotWaitMs;\n"
            "    /* PRE-FIX */\n"
            "    const int shadow = h->arbmag_pool.active.load(std::memory_order_acquire);\n"
            "    (void)deadline;\n",
        ),
        # 3) L-02：控制线程直清 RT 状态
        (
            "    /* 5. 请求 RT 侧清理独占状态（RT 在 auradsp_process 入口消费） */\n"
            "    h->reset_req.store(1, std::memory_order_release);\n",
            "    /* 5. PRE-FIX */\n"
            "    reset_channel_state_rt(h);\n",
        ),
    ],
    "engine/engine_param_table.h": [
        # 4) L-03 主卷积：刷新时不持 jdsp_lock
        (
            "static void arbmag_refresh_vendor_conv(auradsp_handle h, char* curve) {\n"
            "    jdsp_lock(&h->jdsp);\n"
            "    ArbitraryResponseEqualizerStringParser(&h->jdsp, curve);\n"
            "    jdsp_unlock(&h->jdsp);\n"
            "}\n",
            "static void arbmag_refresh_vendor_conv(auradsp_handle h, char* curve) {\n"
            "    /* PRE-FIX */\n"
            "    ArbitraryResponseEqualizerStringParser(&h->jdsp, curve);\n"
            "}\n",
        ),
    ],
    "engine/legacy/jdsp/jdspController.c": [
        # 5) arbmag stage 不取 jdsp_lock
        (
            '\t{"arbmag", stage_arbmag, 1},\n',
            '\t{"arbmag", stage_arbmag, 0},\t/* PRE-FIX */\n',
        ),
    ],
}


# 修复版状态的 SHA256（revert 前的实测值）。restore 之后必须与此一致，
# 否则说明还原不完整 —— 用哈希而不是肉眼比对，避免「以为还原了其实没还原」。
EXPECTED_SHA256 = {
    "engine/chain/engine_chain.cpp":
        "FE1B7C48CA2AE97CA08924B69A5C7F959F4CA91656ABF9B47CCDAD70B983A859",
    "engine/legacy/jdsp/jdspController.c":
        "2F02FE04D14AE054EDAE5D75B8D56AF17DCAA352859BCB0ACA7A70A3351C20DB",
    "engine/engine_param_table.h":
        "A4139A257E4713525994CB1E293A0255C90604CA954C93717F68935FCA0A2166",
}


def sha256_of(rel):
    import hashlib
    path = os.path.join(ROOT, rel.replace("/", os.sep))
    with open(path, "rb") as f:
        return hashlib.sha256(f.read()).hexdigest().upper()


def apply(direction):
    """direction: 'revert' 固定版→pre-fix；'restore' pre-fix→固定版。"""
    ok = True
    for rel, pairs in EDITS.items():
        path = os.path.join(ROOT, rel.replace("/", os.sep))
        with open(path, "rb") as f:
            data = f.read()
        crlf = b"\r\n" in data
        for old, new in pairs:
            if direction == "revert":
                src, dst = old, new
            else:
                src, dst = new, old
            src_b = src.encode("utf-8")
            dst_b = dst.encode("utf-8")
            if crlf:
                # 源文件是 CRLF：把模式里的 LF 换成 CRLF 后再匹配
                src_b = src_b.replace(b"\n", b"\r\n")
                dst_b = dst_b.replace(b"\n", b"\r\n")
            n = data.count(src_b)
            if n != 1:
                print("ABORT: %s: pattern count=%d (expected 1) for %r"
                      % (rel, n, src[:60]))
                ok = False
                continue
            data = data.replace(src_b, dst_b, 1)
            print("OK  %s: %s" % (rel, src[:48].encode("unicode_escape").decode()))
        if ok:
            with open(path, "wb") as f:
                f.write(data)
    if not ok:
        print("FAILED: some patterns did not match; no conclusion may be drawn.")
        sys.exit(2)
    print("DONE: %s" % direction)


def status():
    for rel in EDITS:
        path = os.path.join(ROOT, rel.replace("/", os.sep))
        with open(path, "rb") as f:
            data = f.read()
        print("%-40s PRE-FIX markers=%d" % (rel, data.count(b"PRE-FIX")))


def verify():
    """校验三个目标文件与修复版逐字节一致。"""
    ok = True
    for rel, want in EXPECTED_SHA256.items():
        got = sha256_of(rel)
        same = (got == want)
        ok = ok and same
        print("%-40s %s" % (rel, "MATCH" if same else "MISMATCH"))
        if not same:
            print("    expected %s" % want)
            print("    actual   %s" % got)
    print("VERIFY: %s" % ("OK（当前 == 修复版）" if ok else "FAILED（当前 != 修复版）"))
    sys.exit(0 if ok else 2)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "status"
    if cmd in ("revert", "restore"):
        apply(cmd)
    elif cmd == "status":
        status()
    elif cmd == "verify":
        verify()
    else:
        print(__doc__)
        sys.exit(1)
