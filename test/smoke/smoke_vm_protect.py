# -*- coding: utf-8 -*-
"""smoke_vm_protect.py — VM 桥超预算自动保护（Z12）冒烟（需 Voicemeeter 在线）。

能证明什么：守卫状态机端到端——注入超预算观测值 → 保护激活（status.protect=1、
用户掩码 plugMask 不被改写）→ 观测回落 6s → 自动恢复；用户手动改掩码立即取消
保护；关闭自动保护后不再进入。
不能证明什么：真实 Ozone 过载下的音频连续性（那需要真实重插件 + 监听，人工验证）。

测试注入口：vb_protect_test(emaUs, overStreak)——protectTestMode 下 RT 停更
观测值，streak<0 退出测试模式并清零。守卫执行者 = 后台补齐线程（500ms 轮询），
故进入延迟 ~0.5-1s、恢复延迟 ~6-7s。
"""
import ctypes
import json
import os
import sys
import time

ROOT = r"D:\temp_desktop\Proj\JamesDSP"
CANDS = [
    os.path.join(ROOT, "test", "auravm_bridge.dll"),
    os.path.join(ROOT, "core", "desktop", "windows-drivers", "out", "Release",
                 "auravm_bridge.dll"),
]
ENV = os.environ.get("AURADSP_VB_BRIDGE_DLL")
if ENV:
    CANDS.insert(0, ENV)

path = next((p for p in CANDS if os.path.exists(p)), None)
if not path:
    print("SKIP（桥 DLL 不存在）")
    sys.exit(0)

b = ctypes.CDLL(path)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bridge_compat import alias_common, start_vm  # noqa: E402

alias_common(b, "vb")
b.vb_start = start_vm(b)
b.vb_detect.restype = ctypes.c_int
b.vb_stop.restype = ctypes.c_int
b.vb_status.restype = ctypes.c_int
b.vb_plugin_group_enable.restype = ctypes.c_int
b.vb_plugin_group_enable.argtypes = [ctypes.c_int]
b.vb_plugin_group_mask.restype = ctypes.c_int
b.vb_plugin_auto_protect.restype = ctypes.c_int
b.vb_plugin_auto_protect.argtypes = [ctypes.c_int]
b.vb_protect_test.restype = ctypes.c_int
b.vb_protect_test.argtypes = [ctypes.c_int, ctypes.c_int]
b.vb_detect.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.vb_status.argtypes = [ctypes.c_char_p, ctypes.c_int]

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def note(msg):
    print(f"NOTE  {msg}")


def get_status():
    buf = ctypes.create_string_buffer(2048)
    if b.vb_status(buf, 2048) <= 0:
        return {}
    try:
        return json.loads(buf.value.decode("utf-8", "replace"))
    except ValueError:
        return {}


def wait_protect(target, timeout):
    deadline = time.time() + timeout
    while time.time() < deadline:
        if get_status().get("protect", -1) == target:
            return True
        time.sleep(0.2)
    return get_status().get("protect", -1) == target


buf = ctypes.create_string_buffer(2048)
rc = b.vb_detect(buf, 2048)
det = json.loads(buf.value.decode("utf-8", "replace")) if rc > 0 else {}
if not det.get("found", False):
    print("SKIP（Voicemeeter 未安装）")
    sys.exit(0)

ENG = os.path.join(ROOT, "test", "auradsp_engine.dll")
rc = b.vb_start(ENG.encode("utf-8"), b"")
if rc != 0:
    note(f"vb_start rc={rc}（让路/被占，优雅跳过）")
    sys.exit(0)

started = True
try:
    # ---- 前置：守卫测试导出存在（红：旧 DLL 无此导出）----
    try:
        have_test_export = b.vb_protect_test is not None
    except AttributeError:
        have_test_export = False
    check("protect test export exists", have_test_export)
    if not have_test_export:
        print("VMPROTECT FAILURES:", fails)
        sys.exit(1)

    # ---- 环境复位：保护开 + 用户掩码全开 + 观测清零 ----
    check("auto_protect on", b.vb_plugin_auto_protect(1) == 1)
    check("group_enable(0xFF)", b.vb_plugin_group_enable(0xFF) == 0xFF)
    b.vb_protect_test(0, -1)  # 退出测试模式 + 清零
    time.sleep(0.8)  # 让一次守卫轮询消化干净状态

    st = get_status()
    n_eng = st.get("handles", 0)
    budget = st.get("budgetUs", 0)
    check("budgetUs>0", budget > 0, f"budgetUs={budget} nbs={st.get('nbs')} sr={st.get('sr')}")

    if n_eng < 2:
        note(f"handles={n_eng}（单组版面），收窄无从谈起——仅验证字段与关闭路径")
        check("auto_protect query", b.vb_plugin_auto_protect(-1) == 1)
        b.vb_protect_test(0, -1)
        print("VMPROTECT FAILURES:", fails)
        sys.exit(1 if fails else 0)

    # ---- ① 注入超预算 → 保护激活（延迟 ~0.5-1s）----
    check("inject over-budget", b.vb_protect_test(budget * 2, 200) == 1)
    ok = wait_protect(1, 3.0)
    st = get_status()
    check("protect enters", ok, f"protect={st.get('protect')} ema={st.get('cbEmaUs')} budget={st.get('budgetUs')}")
    check("user mask preserved", st.get("plugMask") == 0xFF, f"plugMask={st.get('plugMask')}")
    hot = st.get("hotGrp", -1)
    check("hotGrp valid", isinstance(hot, int) and 0 <= hot < n_eng, f"hotGrp={hot} handles={n_eng}")

    # ---- ② 观测回落 → 6s 后自动恢复 ----
    check("under-feed exits test mode", b.vb_protect_test(100, -1) == 1)
    ok = wait_protect(0, 9.0)
    st = get_status()
    check("protect auto-recovers", ok, f"protect={st.get('protect')} ema={st.get('cbEmaUs')}")

    # ---- ③ 保护激活期手动改掩码 → 立即取消保护（用户接管）----
    check("re-enter", b.vb_protect_test(budget * 2, 200) == 1 and wait_protect(1, 3.0))
    check("manual override cancels", b.vb_plugin_group_enable(0x01) == 0x01)
    ok = wait_protect(0, 2.0)
    st = get_status()
    check("protect cancelled by manual mask", ok, f"protect={st.get('protect')} plugMask={st.get('plugMask')}")
    check("user mask applied", st.get("plugMask") == 0x01, f"plugMask={st.get('plugMask')}")
    b.vb_plugin_group_enable(0xFF)
    time.sleep(0.8)  # 消化 60s 手动冷却前先恢复观测
    b.vb_protect_test(0, -1)

    # ---- ④ 关闭自动保护 → 不再进入 ----
    # 注意：③ 留下 60s 手动冷却；先验证冷却本身也阻止进入（语义即如此），
    # 再关自动保护验证双保险。冷却期注入超预算不得进入。
    check("cooldown blocks entry", b.vb_protect_test(budget * 2, 200) == 1)
    time.sleep(1.2)
    st = get_status()
    check("no entry during cooldown", st.get("protect", -1) == 0, f"protect={st.get('protect')}")
    check("auto_protect off", b.vb_plugin_auto_protect(0) == 0)
    b.vb_plugin_group_enable(0xFF)  # 刷新手动时间戳（冷却重置）——此时保护已关
    time.sleep(0.8)
    check("inject while off", b.vb_protect_test(budget * 2, 200) == 1)
    time.sleep(1.2)
    st = get_status()
    check("no entry when auto-protect off", st.get("protect", -1) == 0, f"protect={st.get('protect')}")

    # ---- 清理 ----
    check("auto_protect on(restore)", b.vb_plugin_auto_protect(1) == 1)
    b.vb_plugin_group_enable(0xFF)
    b.vb_protect_test(0, -1)
finally:
    if started:
        b.vb_stop()

print("VMPROTECT FAILURES:", fails)
sys.exit(1 if fails else 0)
