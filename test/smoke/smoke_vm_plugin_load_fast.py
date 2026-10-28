# -*- coding: utf-8 -*-
"""smoke_vm_plugin_load_fast.py — 桥挂载提速门禁（需 Voicemeeter 在线）。

背景（2026-10-23 用户实测：Ozone 12 挂载 ~10s vs FL Studio 2-3s）：
`vb_plugin_slot_load` 曾把插件**逐组同步实例化**——实测 Ozone 12 每实例
~2.4s（模块已映射后），4 组 9.7s / 8 组近 20s。FL 只有单实例。

修复：eng[0] 同步加载（主监听总线立即可用）→ 其余组按代际后台补齐；
补齐后回放镜像状态（bypass/Ch/阶段）与已请求预设；掩码位 0 的组不加载；
掩码新使能的组后台补挂。

判据：
1. load 返回后 eng[0] 就绪、其余组尚未就绪（异步已生效）；
2. 限时内全部「掩码内」组就绪（后台补齐完成）；
3. 掩码 0x01 时只加载组 0（掩码跳过生效）；
4. 掩码恢复后新使能组自动补挂（无需重新 mount）；
5. unload 后全部组清零。

用法：python test/smoke/smoke_vm_plugin_load_fast.py
"""
import ctypes
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
BRIDGE_CANDS = [
    os.environ.get("AURADSP_VB_BRIDGE_DLL"),
    os.path.join(ROOT, "core", "desktop", "windows-drivers", "out", "Release",
                 "auravm_bridge.dll"),
    os.path.join(ROOT, "test", "auravm_bridge.dll"),
]
PLUGIN_CANDS = [
    r"C:\Program Files\Common Files\VST3\iZotope\Ozone 12.vst3",
]
BACKFILL_TIMEOUT_S = 40.0

bpath = next((p for p in BRIDGE_CANDS if p and os.path.exists(p)), None)
if not bpath:
    print("SKIP（桥 DLL 不存在）")
    sys.exit(0)
ppath = next((p for p in PLUGIN_CANDS if os.path.exists(p)), None)
if not ppath:
    print("SKIP（Ozone 12 未安装）")
    sys.exit(0)

b = ctypes.CDLL(bpath)
b.vb_detect.restype = ctypes.c_int
b.vb_detect.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.vb_start.restype = ctypes.c_int
b.vb_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
b.vb_stop.restype = ctypes.c_int
b.vb_status.restype = ctypes.c_int
b.vb_status.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.vb_plugin_slot_load.restype = ctypes.c_int
b.vb_plugin_slot_load.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p]
b.vb_plugin_slot_unload.restype = ctypes.c_int
b.vb_plugin_slot_unload.argtypes = [ctypes.c_int]
b.vb_plugin_slot_group_ready.restype = ctypes.c_int
b.vb_plugin_slot_group_ready.argtypes = [ctypes.c_int, ctypes.c_int]
b.vb_plugin_slot_get_status.restype = ctypes.c_int
b.vb_plugin_slot_get_status.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int]
b.vb_plugin_slot_set_bypass.restype = ctypes.c_int
b.vb_plugin_slot_set_bypass.argtypes = [ctypes.c_int, ctypes.c_int]
b.vb_plugin_group_enable.restype = ctypes.c_int
b.vb_plugin_group_enable.argtypes = [ctypes.c_int]
b.vb_plugin_group_mask.restype = ctypes.c_int
b.vb_test_start.restype = ctypes.c_int
b.vb_test_start.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                            ctypes.c_int, ctypes.c_int]
b.vb_test_stop.restype = ctypes.c_int

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def status():
    buf = ctypes.create_string_buffer(2048)
    if b.vb_status(buf, 2048) <= 0:
        return {}
    try:
        return json.loads(buf.value.decode("utf-8", "replace"))
    except ValueError:
        return {}


def ready_map(slot, n):
    return [b.vb_plugin_slot_group_ready(slot, g) for g in range(n)]


def slot_status(slot=0):
    buf = ctypes.create_string_buffer(2048)
    if b.vb_plugin_slot_get_status(slot, buf, 2048) <= 0:
        return {}
    try:
        return json.loads(buf.value.decode("utf-8", "replace"))
    except ValueError:
        return {}


buf = ctypes.create_string_buffer(2048)
rc = b.vb_detect(buf, 2048)
det = json.loads(buf.value.decode("utf-8", "replace")) if rc > 0 else {}
if not det.get("found", False):
    print("SKIP（Voicemeeter 未安装）")
    sys.exit(0)

ENG = os.path.join(ROOT, "test", "auradsp_engine.dll")
if not os.path.exists(ENG):
    ENG = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release",
                       "auradsp_engine.dll")
rc = b.vb_start(ENG.encode("utf-8"), b"")
if rc == 1:
    print("NOTE out-slot-busy（让路，不断言）")
    sys.exit(0)
if rc != 0:
    st = status()
    note = st.get("note", "")
    if "out-slot-busy" in note or "register-failed" in note:
        print(f"NOTE Voicemeeter 注册让路（rc={rc}, note={note}），跳过")
        sys.exit(0)
    check("start rc==0", False, f"rc={rc}")
    print("VMBRIDGE FAILURES:", fails)
    sys.exit(1)

try:
    time.sleep(0.6)
    n = status().get("groups", 0)
    print(f"[0] bridge up, groups={n}")
    if n <= 1:
        print("SKIP（单组版面，无后台补齐可验）")
        b.vb_stop()
        sys.exit(0)

    # 测试音注入（2026-10-27）：无声时组被判 idle 而跳过 process，
    # 下面的 processCalls 恢复断言会误判。先注入 tone 再挂载。
    tone_rc = b.vb_test_start(1, None, 0, 0, 0)
    print(f"[0] test tone rc={tone_rc}")

    # ---- [1] 掩码 0x01：只加载组 0，其余组被跳过 ----
    b.vb_plugin_group_enable(1)
    t0 = time.time()
    rc = b.vb_plugin_slot_load(0, ppath.encode("utf-8"), b"")
    t_first = time.time() - t0
    check("load rc==1", rc == 1, f"rc={rc}")
    r = ready_map(0, n)
    check("eng[0] 立即可用（同步）", r[0] == 1, f"ready={r}")
    check("掩码外组未加载（跳过生效）", all(v == 0 for v in r[1:]), f"ready={r}")
    print(f"[1] mask=0x01: load={t_first:.2f}s ready={r}")
    check("同步段不含逐组扇出（< 8s）", t_first < 8.0, f"load={t_first:.2f}s")
    # P-041 挂载即旁路（2026-10-28）：挂载后槽必须处于旁路态——这正是
    # 「假旁路」修复的回归线（旧引擎 commit 出厂激活，UI 旁路形同虚设）。
    st1 = slot_status(0)
    check("挂载即旁路（P-041 mount-bypass）", st1.get("bypassed") is True,
          f"bypassed={st1.get('bypassed')}")

    # ---- [2] 掩码全开：新使能组后台补挂（无需重新 mount）----
    b.vb_plugin_group_enable(0xFF)
    t0 = time.time()
    saw_suspend = False
    while time.time() - t0 < BACKFILL_TIMEOUT_S:
        r = ready_map(0, n)
        if status().get("loadSuspend") == 1:
            saw_suspend = True
        if all(v == 1 for v in r):
            break
        time.sleep(0.5)
    t_fill = time.time() - t0
    r = ready_map(0, n)
    check("后台补齐完成（掩码全开）", all(v == 1 for v in r), f"ready={r}")
    st = status()
    check("补挂结束旁路已撤（loadSuspend==0）", st.get("loadSuspend") == 0,
          f"loadSuspend={st.get('loadSuspend')}")
    budget_us = st.get("budgetUs", 0)
    if budget_us and budget_us < 8000:
        check("预算紧张时旁路曾启用（loadSuspend 曾见 1）", saw_suspend,
              f"budgetUs={budget_us}")
    else:
        print(f"NOTE 预算 {budget_us}µs ≥ 8ms：加载旁路门不启用（本机 "
              f"2048 帧常态），suspend_seen={saw_suspend} 仅记录")
    print(f"[2] backfill {n - 1} groups: {t_fill:.2f}s "
          f"(total≈{t_first + t_fill:.2f}s) suspend_seen={saw_suspend} "
          f"stuckG={st.get('stuckG')} fanTimeouts={st.get('fanTimeouts')}")
    if st.get("frames", 0) > 0:
        # P-041：挂载即旁路 → 先显式解旁路（用户「打开」语义），插件链
        # 才会恢复处理；补挂组的 bypass 一致性也在此一并验证（解旁路对
        # 全组生效，此前镜像被 SlotLoad 回写出厂值覆盖的 bug 已修）。
        assert b.vb_plugin_slot_set_bypass(0, 0) == 1, "set_bypass(0) failed"
        time.sleep(0.3)
        st_ub = slot_status(0)
        check("解旁路后槽激活（bypassed==false）", st_ub.get("bypassed") is False,
              f"bypassed={st_ub.get('bypassed')}")
        c0 = slot_status(0).get("processCalls", 0)
        time.sleep(1.5)
        c1 = slot_status(0).get("processCalls", 0)
        check("补挂后插件链恢复处理（processCalls 增长）", c1 > c0,
              f"calls {c0}->{c1} frames={st.get('frames')}")
    else:
        print("NOTE 回调未跑（frames=0），processCalls 恢复不断言")

    # ---- [3] unload 清零 ----
    check("unload rc==1", b.vb_plugin_slot_unload(0) == 1)
    r = ready_map(0, n)
    check("unload 后全部清零", all(v == 0 for v in r), f"ready={r}")
    print(f"[3] unload cleared: ready={r}")
finally:
    try:
        b.vb_test_stop()
    except Exception:
        pass
    b.vb_plugin_group_enable(0xFF)
    b.vb_stop()

print("VMBRIDGE FAILURES:", fails if fails else "none")
sys.exit(1 if fails else 0)
