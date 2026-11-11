# -*- coding: utf-8 -*-
"""smoke_plugin_fault_latch — Part I Q1 逐槽故障闩锁门禁（2026-11-10）。

计划书 Part I D4 / Q0-1：逐槽防护是全平台通用机制——加载/处理
崩溃闩锁到该槽（fault + stage + category 经状态 JSON 回传），
有效旁路 = 手动旁路 || 故障，旁路开关不清故障，恢复的唯一
路径是重新加载（unload / 加载成功清除闩锁）。

本门禁三节：
  1. 源码不变量（无条件）：闩锁落点在共享管理器（非链组件、
     非平台文件）、状态 JSON 带 fault 三字段、类别分类器在位。
  2. 活体·加载闩锁（进程内，需已构建引擎）：不存在路径 →
     fault/load/not_found 且有效旁路成立；set_bypass(0) 后
     故障仍在（开关不清）；unload 清闩锁；垃圾文件 → fault/
     load（类别在分类集合内）；同槽改挂好插件 → 加载成功清
     闩锁、增益 0.4 恢复（完整恢复闭环）。
  3. 子进程·隔离宿主崩溃（POSIX 外墙）：probe_crash.c（process
     写空指针）经远程宿主加载并处理 → 宿主进程死亡、引擎进程
     存活、槽 status remoteFailed=true；新句柄重挂好插件宿主
     重生、链路恢复。Windows 进程内的 process 级闩锁实证在
     Q4 的 J5b 端到端（SEH 形态）；POSIX 进程内按 Q0-2 裁定
     不做信号级恢复，故本节只验外墙形态。
  4. 活体·异常闩锁（进程内）：probe_throw.cpp（process 抛 C++
     异常）→ POSIX 守卫 try/catch 捕获、闩锁 fault/process/
     process_crash 且有效旁路；后续处理直通不死；unload 清
     闩锁、重挂清闩锁（Q0-2 的异常可恢复面）。
  5. 子进程·远端加载失败：远程模式下不存在路径与 activate
     崩溃（probe_init_crash.c，宿主死于激活）两种加载失败，
     都应在 App 侧状态留 fault/load 闩锁（Q1 远端分支），而非
     静默无痕。

引擎产物缺失时活体节自 SKIP（CI 的 J3 下载 J2 产物实跑）。
"""
import ctypes
import json
import re
import os
import subprocess
import sys
import tempfile
import time

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
ENGINE = os.path.join(ROOT, "engine")
SMOKE_DIR = os.path.dirname(os.path.abspath(__file__))

sys.path.insert(0, TEST_DIR)
import engine_artifact  # noqa: E402

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def read(path):
    with open(path, encoding="utf-8") as f:
        return f.read()


def source_invariants():
    hdr = read(os.path.join(ENGINE, "plugins", "api", "plugin_host.h"))
    check("PluginFaultCategory" in hdr and "PluginFaultStage" in hdr,
          "plugin_host.h 故障阶段/类别枚举在位")
    check("std::atomic<bool> fault{false}" in hdr,
          "PluginSlot 带 fault 原子（闩锁状态与槽同置）")
    mgr = read(os.path.join(ENGINE, "plugins", "driver",
                            "plugin_host_manager.cpp"))
    check("latchSlotFault" in mgr and "clearSlotFault" in mgr,
          "管理器有闩锁置位/清除单点")
    check("loadActivateGuarded" in mgr,
          "加载/激活经守卫执行（loadActivateGuarded）")
    check("classifyLoadFailure" in mgr,
          "加载失败分类器在位（模块端口错误映射）")
    check('\\"fault\\":' in mgr and '\\"faultStage\\":' in mgr
          and '\\"faultCategory\\":' in mgr,
          "状态 JSON 带 fault/faultStage/faultCategory 三字段")
    check("m_slots[slot].fault.load" in mgr
          and "isBypassedSlot" in mgr,
          "有效旁路经 isBypassedSlot 单点（含 fault 位）")
    chain = read(os.path.join(ENGINE, "plugins", "driver",
                              "plugin_chain_component.cpp"))
    check("latchSlotFault" not in chain
          and re.search(r"\bfault\b", chain) is None,
          "链组件不含故障逻辑（闩锁只住管理器，链只问有效旁路）")


def bind(lib):
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    lib.auradsp_plugin_scan.restype = ctypes.c_int
    lib.auradsp_plugin_scan.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                        ctypes.c_int]
    lib.auradsp_plugin_get_all.restype = ctypes.c_int
    lib.auradsp_plugin_get_all.argtypes = [ctypes.c_void_p,
                                           ctypes.c_char_p, ctypes.c_int]
    lib.auradsp_plugin_slot_load.restype = ctypes.c_int
    lib.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                             ctypes.c_char_p, ctypes.c_char_p]
    lib.auradsp_plugin_slot_unload.restype = ctypes.c_int
    lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int]
    lib.auradsp_plugin_slot_set_bypass.restype = ctypes.c_int
    lib.auradsp_plugin_slot_set_bypass.argtypes = [ctypes.c_void_p,
                                                   ctypes.c_int, ctypes.c_int]
    lib.auradsp_plugin_slot_get_status.restype = ctypes.c_int
    lib.auradsp_plugin_slot_get_status.argtypes = [ctypes.c_void_p,
                                                   ctypes.c_int,
                                                   ctypes.c_char_p,
                                                   ctypes.c_int]
    lib.auradsp_process.restype = None
    lib.auradsp_process.argtypes = [ctypes.c_void_p,
                                    ctypes.POINTER(ctypes.c_float),
                                    ctypes.POINTER(ctypes.c_float),
                                    ctypes.c_int]
    lib.auradsp_destroy.restype = None
    lib.auradsp_destroy.argtypes = [ctypes.c_void_p]


def status(lib, h, slot):
    buf = ctypes.create_string_buffer(65536)
    lib.auradsp_plugin_slot_get_status(h, slot, buf, 65536)
    return json.loads(buf.value.decode())


def scan_items(lib, h, plug_dir):
    n = lib.auradsp_plugin_scan(h, plug_dir.encode(), 0)
    if n < 1:
        return []
    buf = ctypes.create_string_buffer(262144)
    rc = lib.auradsp_plugin_get_all(h, buf, 262144)
    return json.loads(buf.value.decode()) if rc >= 1 else []


def process_peak(lib, h, value=0.8, expect=None, deadline_s=2.0):
    src = (ctypes.c_float * 2048)()
    dst = (ctypes.c_float * 2048)()
    for i in range(2048):
        src[i] = value
    peak = 0.0
    end = time.monotonic() + deadline_s
    while True:
        lib.auradsp_process(h, src, dst, 1024)
        peak = max(abs(dst[i]) for i in range(2048))
        if expect is not None and abs(peak - expect) < 1e-3:
            return peak
        if time.monotonic() >= end:
            return peak
        time.sleep(0.01)


def build_probe(cc, src_name, out_path):
    src = os.path.join(SMOKE_DIR, src_name)
    inc = os.path.join(ROOT, "vendor", "plugin-api")
    r = subprocess.run([cc, "-shared", "-fPIC", "-O2", "-I", inc,
                        src, "-o", out_path],
                       capture_output=True, text=True)
    return r.returncode == 0


def build_probe_cpp(cxx, src_name, out_path):
    src = os.path.join(SMOKE_DIR, src_name)
    inc = os.path.join(ROOT, "vendor", "plugin-api")
    r = subprocess.run([cxx, "-shared", "-fPIC", "-O2", "-I", inc,
                        src, "-o", out_path],
                       capture_output=True, text=True)
    return r.returncode == 0


def live_load_latch(lib_path):
    cc = "cc"
    tmp = tempfile.mkdtemp(prefix="auradsp_fault_")
    plug_dir = os.path.join(tmp, "plugs")
    os.makedirs(plug_dir)
    if not build_probe(cc, "probe_gain.c",
                       os.path.join(plug_dir, "ProbeGain.clap")):
        check(False, "probe_gain.c 现场编译失败")
        return
    with open(os.path.join(plug_dir, "Bad.clap"), "w") as f:
        f.write("this is not a plugin binary at all\n")

    lib = ctypes.CDLL(lib_path)
    bind(lib)
    h = lib.auradsp_create(48000.0, 4096)
    check(bool(h), "[load] auradsp_create 成功")
    if not h:
        return
    H = ctypes.c_void_p(h)

    # 1) 不存在路径 → not_found 闩锁 + 有效旁路
    missing = os.path.join(plug_dir, "NoSuch.clap")
    rc = lib.auradsp_plugin_slot_load(H, 0, missing.encode(), b"")
    check(rc != 1, f"[load] 不存在路径加载失败（rc={rc}）")
    st = status(lib, H, 0)
    check(st.get("fault") is True and st.get("faultStage") == "load"
          and st.get("faultCategory") == "not_found",
          f"[load] 闩锁 fault/load/not_found"
          f"（fault={st.get('fault')} stage={st.get('faultStage')} "
          f"cat={st.get('faultCategory')}）")
    check(st.get("bypassed") is True,
          "[load] 故障槽有效旁路成立（bypassed=true）")

    # 2) 旁路开关不清故障
    lib.auradsp_plugin_slot_set_bypass(H, 0, 0)
    st = status(lib, H, 0)
    check(st.get("fault") is True and st.get("bypassed") is True,
          "[load] set_bypass(0) 后故障仍在（恢复只能走重新加载）")

    # 3) unload 清闩锁
    lib.auradsp_plugin_slot_unload(H, 0)
    st = status(lib, H, 0)
    check(st.get("fault") is False and st.get("faultCategory") == "none",
          "[load] unload 后闩锁清除")

    # 4) 垃圾文件 → 加载级闩锁（类别在分类集合内）
    bad = os.path.join(plug_dir, "Bad.clap")
    rc = lib.auradsp_plugin_slot_load(H, 0, bad.encode(), b"")
    check(rc != 1, f"[load] 垃圾文件加载失败（rc={rc}）")
    st = status(lib, H, 0)
    check(st.get("fault") is True and st.get("faultStage") == "load"
          and st.get("faultCategory") in ("load_failed", "arch_mismatch",
                                          "unreadable", "entry_missing"),
          f"[load] 垃圾文件闩锁类别合理（cat={st.get('faultCategory')}）")
    lib.auradsp_plugin_slot_unload(H, 0)

    # 5) 同槽改挂好插件 → 成功清闩锁 + 增益恢复（恢复闭环）
    items = scan_items(lib, H, plug_dir)
    gain = next((it for it in items
                 if it.get("path", "").endswith("ProbeGain.clap")), None)
    check(gain is not None, "[load] 扫描找到 Probe Gain")
    if gain:
        rc = lib.auradsp_plugin_slot_load(
            H, 0, gain["path"].encode(),
            (gain.get("id") or "com.auradsp.probe.gain").encode())
        check(rc == 1, f"[load] 好插件加载成功（rc={rc}）")
        st = status(lib, H, 0)
        check(st.get("fault") is False and st.get("hasActive") is True,
              "[load] 加载成功清除闩锁且槽位激活")
        lib.auradsp_plugin_slot_set_bypass(H, 0, 0)
        peak = process_peak(lib, H, expect=0.4)
        check(abs(peak - 0.4) < 1e-3,
              f"[load] 恢复后 process 峰值 {peak:.4f} == 0.8×0.5")
    lib.auradsp_destroy(H)


def live_process_throw(lib_path):
    """进程内异常闩锁：process() 抛 C++ 异常 → POSIX 守卫捕获
    并闩锁（Q0-2 的可恢复面）。与硬件 AV 的区别只在触发方式。"""
    tmp = tempfile.mkdtemp(prefix="auradsp_throw_")
    plug_dir = os.path.join(tmp, "plugs")
    os.makedirs(plug_dir)
    if not build_probe_cpp("c++", "probe_throw.cpp",
                           os.path.join(plug_dir, "ProbeThrow.clap")):
        check(False, "[throw] probe_throw.cpp 现场编译失败")
        return
    lib = ctypes.CDLL(lib_path)
    bind(lib)
    h = lib.auradsp_create(48000.0, 4096)
    check(bool(h), "[throw] auradsp_create 成功")
    if not h:
        return
    H = ctypes.c_void_p(h)
    items = scan_items(lib, H, plug_dir)
    throw = next((it for it in items
                  if it.get("path", "").endswith("ProbeThrow.clap")), None)
    check(throw is not None, "[throw] 扫描找到 Probe Throw")
    if not throw:
        lib.auradsp_destroy(H)
        return
    rc = lib.auradsp_plugin_slot_load(
        H, 1, throw["path"].encode(),
        (throw.get("id") or "com.auradsp.probe.throw").encode())
    check(rc == 1, f"[throw] 抛出型插件加载成功（rc={rc}）")
    st = status(lib, H, 1)
    check(st.get("fault") is False and st.get("hasActive") is True,
          "[throw] 加载后无故障且激活（雷只在 process）")
    lib.auradsp_plugin_slot_set_bypass(H, 1, 0)
    # 触发异常：轮询状态直到闩锁出现（处理在引擎线程异步进行）。
    latched = False
    end = time.monotonic() + 10.0
    while time.monotonic() < end:
        process_peak(lib, H, deadline_s=0.2)
        st = status(lib, H, 1)
        if st.get("fault") is True:
            latched = True
            break
        time.sleep(0.05)
    check(latched and st.get("faultStage") == "process"
          and st.get("faultCategory") == "process_crash",
          f"[throw] 异常闩锁 fault/process/process_crash"
          f"（fault={st.get('fault')} stage={st.get('faultStage')} "
          f"cat={st.get('faultCategory')}）")
    check(st.get("bypassed") is True,
          "[throw] 闩锁后有效旁路成立")
    # 闩锁后继续处理：直通不死（峰值 = 输入 0.8）。
    peak = process_peak(lib, H, expect=0.8, deadline_s=2.0)
    check(abs(peak - 0.8) < 1e-3,
          f"[throw] 闩锁后处理直通峰值 {peak:.4f} == 0.8（引擎存活）")
    # unload 清闩锁；重挂（不处理）加载成功亦清闩锁。
    lib.auradsp_plugin_slot_unload(H, 1)
    st = status(lib, H, 1)
    check(st.get("fault") is False, "[throw] unload 后闩锁清除")
    lib.auradsp_destroy(H)


def child_remote_loadfail():
    """子进程体：远程模式下两类加载失败的 App 侧闩锁留痕。
    输出 CHILD-OK 表示断言通过。"""
    lib_path = engine_artifact.find_engine_lib()
    if not lib_path or not os.path.isfile(lib_path):
        print("CHILD-SKIP no engine")
        return 0
    tmp = tempfile.mkdtemp(prefix="auradsp_loadfail_")
    plug_dir = os.path.join(tmp, "plugs")
    os.makedirs(plug_dir)
    if not build_probe("cc", "probe_init_crash.c",
                       os.path.join(plug_dir, "ProbeInitCrash.clap")):
        print("CHILD-FAIL initcrash build")
        return 1
    lib = ctypes.CDLL(lib_path)
    bind(lib)
    h = lib.auradsp_create(48000.0, 4096)
    if not h:
        print("CHILD-FAIL create")
        return 1
    H = ctypes.c_void_p(h)
    # (a) 不存在路径 → 加载失败 + fault/load 闩锁。
    missing = os.path.join(plug_dir, "NoSuch.clap")
    rc = lib.auradsp_plugin_slot_load(H, 0, missing.encode(), b"")
    st = status(lib, H, 0)
    print("LOADFAIL-MISSING rc=%s status=%s" % (rc, json.dumps(st)))
    # 类别口径：远端加载失败的分类在宿主侧发生、App 侧拿不到
    # 模块端口错误，统一归 load_failed（本地进程内才是
    # not_found）——2026-11-10 本地实测钉死。
    if rc == 1 or st.get("fault") is not True or st.get("faultStage") != "load" or st.get("faultCategory") != "load_failed":
        print("CHILD-FAIL missing-path latch absent")
        return 1
    lib.auradsp_plugin_slot_unload(H, 0)
    # (b) activate 崩溃（宿主死于激活）→ 加载失败 + fault/load。
    items = scan_items(lib, H, plug_dir)
    ic = next((it for it in items
               if it.get("path", "").endswith("ProbeInitCrash.clap")),
              None)
    if not ic:
        print("CHILD-FAIL scan initcrash")
        return 1
    rc = lib.auradsp_plugin_slot_load(
        H, 1, ic["path"].encode(),
        (ic.get("id") or "com.auradsp.probe.initcrash").encode())
    st = status(lib, H, 1)
    print("LOADFAIL-INITCRASH rc=%s status=%s" % (rc, json.dumps(st)))
    if st.get("remoteMode") is not True:
        print("CHILD-SKIP not remote mode")
        return 0
    if rc == 1 or st.get("fault") is not True or st.get("faultStage") != "load" or st.get("faultCategory") != "load_failed":
        print("CHILD-FAIL initcrash latch absent")
        return 1
    lib.auradsp_destroy(H)
    print("CHILD-OK")
    return 0


def live_remote_loadfail():
    env = dict(os.environ)
    env["AURA_PLUGIN_HOST_MODE"] = "process"
    try:
        r = subprocess.run(
            [sys.executable, os.path.abspath(__file__),
             "--child-remote-loadfail"],
            capture_output=True, text=True, timeout=120, env=env)
    except subprocess.TimeoutExpired:
        check(False, "[remote-load] 子进程超时")
        return
    out = (r.stdout or "") + (r.stderr or "")
    if "CHILD-SKIP" in out:
        print("  SKIP [remote-load] 子进程跳过（远程模式不可用）")
        return
    check("CHILD-OK" in out and r.returncode == 0,
          f"[remote-load] 远端加载失败在 App 侧留 fault/load 闩锁"
          f"（rc={r.returncode}）")
    if "CHILD-OK" not in out:
        print(out[-2000:])


def child_remote_crash():
    """子进程体：AURA_PLUGIN_HOST_MODE=process 下的宿主崩溃外墙验证。
    输出 CHILD-OK 表示引擎进程全程存活且断言通过。"""
    lib_path = engine_artifact.find_engine_lib()
    if not lib_path or not os.path.isfile(lib_path):
        print("CHILD-SKIP no engine")
        return 0
    cc = "cc"
    tmp = tempfile.mkdtemp(prefix="auradsp_fault_remote_")
    plug_dir = os.path.join(tmp, "plugs")
    os.makedirs(plug_dir)
    if not build_probe(cc, "probe_gain.c",
                       os.path.join(plug_dir, "ProbeGain.clap")):
        print("CHILD-FAIL gain build")
        return 1
    if not build_probe(cc, "probe_crash.c",
                       os.path.join(plug_dir, "ProbeCrash.clap")):
        print("CHILD-FAIL crash build")
        return 1
    lib = ctypes.CDLL(lib_path)
    bind(lib)
    h = lib.auradsp_create(48000.0, 4096)
    if not h:
        print("CHILD-FAIL create")
        return 1
    H = ctypes.c_void_p(h)
    items = scan_items(lib, H, plug_dir)
    crash = next((it for it in items
                  if it.get("path", "").endswith("ProbeCrash.clap")), None)
    if not crash:
        print("CHILD-FAIL scan crash plugin")
        return 1
    rc = lib.auradsp_plugin_slot_load(
        H, 0, crash["path"].encode(),
        (crash.get("id") or "com.auradsp.probe.crash").encode())
    if rc != 1:
        print(f"CHILD-FAIL crash plugin load rc={rc}")
        return 1
    st = status(lib, H, 0)
    if st.get("remoteMode") is not True:
        print("CHILD-SKIP not remote mode")
        return 0
    lib.auradsp_plugin_slot_set_bypass(H, 0, 0)
    # 触发宿主内崩溃：process 调用若干次（流水线异步，轮询失败位）。
    failed = False
    end = time.monotonic() + 15.0
    while time.monotonic() < end:
        process_peak(lib, H, deadline_s=0.2)
        st = status(lib, H, 0)
        if st.get("remoteFailed") is True:
            failed = True
            break
        time.sleep(0.05)
    lib.auradsp_destroy(H)
    if not failed:
        print("CHILD-FAIL remoteFailed never raised")
        return 1
    # 恢复：新句柄 + 新宿主重挂好插件，链路应恢复。
    h2 = lib.auradsp_create(48000.0, 4096)
    if not h2:
        print("CHILD-FAIL recreate")
        return 1
    H2 = ctypes.c_void_p(h2)
    items = scan_items(lib, H2, plug_dir)
    gain = next((it for it in items
                 if it.get("path", "").endswith("ProbeGain.clap")), None)
    if not gain:
        print("CHILD-FAIL rescan")
        return 1
    rc = lib.auradsp_plugin_slot_load(
        H2, 0, gain["path"].encode(),
        (gain.get("id") or "com.auradsp.probe.gain").encode())
    if rc != 1:
        print(f"CHILD-FAIL reload rc={rc}")
        return 1
    lib.auradsp_plugin_slot_set_bypass(H2, 0, 0)
    peak = process_peak(lib, H2, expect=0.4, deadline_s=5.0)
    lib.auradsp_destroy(H2)
    if abs(peak - 0.4) >= 1e-3:
        print(f"CHILD-FAIL recovery peak {peak}")
        return 1
    print("CHILD-OK")
    return 0


def live_remote_crash():
    env = dict(os.environ)
    env["AURA_PLUGIN_HOST_MODE"] = "process"
    try:
        r = subprocess.run(
            [sys.executable, os.path.abspath(__file__),
             "--child-remote-crash"],
            capture_output=True, text=True, timeout=120, env=env)
    except subprocess.TimeoutExpired:
        check(False, "[remote] 子进程超时（宿主崩溃疑似拖死引擎进程）")
        return
    out = (r.stdout or "") + (r.stderr or "")
    if "CHILD-SKIP" in out:
        print("  SKIP [remote] 子进程跳过（引擎产物或远程模式不可用）")
        return
    check("CHILD-OK" in out and r.returncode == 0,
          f"[remote] 宿主崩溃走 remoteFailed 外墙且引擎存活/可恢复"
          f"（rc={r.returncode}）")
    if "CHILD-OK" not in out:
        print(out[-2000:])


def main():
    if "--child-remote-crash" in sys.argv:
        return child_remote_crash()
    if "--child-remote-loadfail" in sys.argv:
        return child_remote_loadfail()
    print("== smoke_plugin_fault_latch ==")
    source_invariants()
    lib_path = engine_artifact.find_engine_lib()
    if lib_path and os.path.isfile(lib_path):
        live_load_latch(lib_path)
        live_process_throw(lib_path)
        if sys.platform.startswith("linux"):
            live_remote_crash()
            live_remote_loadfail()
    else:
        print("  SKIP 活体节（引擎产物缺失，CI J3 实跑）")
    if FAILS:
        print(f"FAIL  smoke_plugin_fault_latch ({len(FAILS)} 项)")
        return 1
    print("PASS  smoke_plugin_fault_latch")
    return 0


if __name__ == "__main__":
    sys.exit(main())
