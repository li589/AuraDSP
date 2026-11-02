# -*- coding: utf-8 -*-
"""smoke_linux_plugin_host — Linux 插件宿主门禁（二期阶段四，2026-11-02）。

两半：
  1. 源码不变量（无条件执行）：platform/posix 对应物在位、Linux
     CMake 插件默认 ON 且编入 posix 源、编辑器槽方法已归位
     manager 本体、App 侧 LinuxPluginHost 接线与 supportsPlugins
     放开、插件页扫描目录区不再被 Linux 隐藏。
  2. 活体全链（需已构建的插件版引擎 + C 编译器）：现场编译门禁
     资产 probe_gain.c（CLAP，固定增益 0.5）为 .clap，经引擎
     C ABI（现行签名：create(采样率, 块长)、slot_load(path, id)）
     完成 create→scan→get_all 元数据断言→slot_load→status
     hasActive→set_bypass→process 峰值断言（0.8×0.5=0.4）→
     unload→destroy。引擎产物缺失时活体半自 SKIP（CI 的 J3 会
     下载 J2 产物实跑；本地先构建引擎即可）。

注意：若引擎是 OFF（stub）构建，scan 返回 0 —— 活体半据此
FAIL 并提示构建口味不对（J2 默认产物为 ON 构建）。
"""
import ctypes
import json
import os
import subprocess
import sys
import tempfile

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)
APP = os.path.join(ROOT, "app", "auradsp_app")
ENGINE = os.path.join(ROOT, "engine")

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
    posix = os.path.join(ENGINE, "plugins", "platform", "posix")
    for name in ("win32_util.h", "win32_compat.h", "module_pump.h",
                 "plugin_util_posix.cpp"):
        check(os.path.isfile(os.path.join(posix, name)),
              f"platform/posix/{name} 在位")
    cmake = read(os.path.join(ROOT, "core", "desktop", "linux",
                              "CMakeLists.txt"))
    check('option(AURADSP_ENABLE_PLUGINS "Build VST3/CLAP plugin '
          'hosting subsystem" ON)' in cmake,
          "Linux CMake 插件默认 ON")
    check("platform/posix/plugin_util_posix.cpp" in cmake,
          "Linux CMake 编入 posix 平台源")
    check("AURADSP_HOST_INPROC=1" in cmake, "进程内宿主标记在位")

    mgr = read(os.path.join(ENGINE, "plugins", "driver",
                            "plugin_host_manager.cpp"))
    gui = read(os.path.join(ENGINE, "plugins", "platform", "win32",
                            "plugin_gui_win32.cpp"))
    for m in ("showEditorSlot", "closeEditorSlot", "isEditorOpenSlot"):
        check(f"PluginHostManager::{m}" in mgr, f"{m} 已归位 manager")
        check(f"PluginHostManager::{m}" not in gui,
              f"{m} 不再留在 win32 GUI 文件")

    profile = read(os.path.join(APP, "lib", "platform",
                                "platform_profile.dart"))
    check("Platform.isWindows || Platform.isLinux" in profile,
          "supportsPlugins 已放开 Linux")
    adapters = read(os.path.join(APP, "lib", "platform", "adapters.dart"))
    check("LinuxPluginHost" in adapters, "adapters 分派 LinuxPluginHost")
    host = read(os.path.join(APP, "lib", "platform", "port",
                             "plugin_host.dart"))
    check("linuxInProcess" in host and "canEdit: false" in host,
          "linuxInProcess 能力集在位（canEdit 如实 false）")
    page = read(os.path.join(APP, "lib", "features", "plugins_page.dart"))
    check("if (!PlatformProfile.isLinux)" not in page,
          "插件页扫描目录区不再对 Linux 隐藏")


def live_chain():
    lib_path = engine_artifact.find_engine_lib()
    if not lib_path or not os.path.isfile(lib_path):
        print("  SKIP 活体半：未找到已构建的引擎产物"
              "（先 cmake --preset linux-x64 构建，或 CI 下载 J2 产物）")
        return
    cc = None
    for cand in ("cc", "gcc", "clang"):
        if subprocess.run(["which", cand], capture_output=True).returncode == 0:
            cc = cand
            break
    if not cc:
        print("  SKIP 活体半：无 C 编译器可编译门禁插件资产")
        return
    tmp = tempfile.mkdtemp(prefix="auradsp_plug_gate_")
    plug_dir = os.path.join(tmp, "plugins")
    os.makedirs(plug_dir)
    out = os.path.join(plug_dir, "ProbeGain.clap")
    r = subprocess.run(
        [cc, "-shared", "-fPIC", "-O2",
         "-I", os.path.join(ROOT, "vendor", "plugin-api"),
         os.path.join(TEST_DIR, "smoke", "probe_gain.c"), "-o", out],
        capture_output=True, text=True)
    check(r.returncode == 0 and os.path.isfile(out),
          "门禁 CLAP 资产编译成功" +
          ("" if r.returncode == 0 else f"（{r.stderr.strip()[:160]}）"))
    if r.returncode != 0:
        return

    lib = ctypes.CDLL(lib_path)
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    h = lib.auradsp_create(48000.0, 4096)
    check(bool(h), "auradsp_create(48000, 4096) 成功")
    if not h:
        return
    H = ctypes.c_void_p(h)
    n = lib.auradsp_plugin_scan(H, plug_dir.encode())
    check(n >= 1, f"scan 找到门禁插件（n={n}；为 0 说明引擎是 "
                  "stub 构建，口味不对）")
    if n < 1:
        return
    buf = ctypes.create_string_buffer(262144)
    rc = lib.auradsp_plugin_get_all(H, buf, 262144)
    items = json.loads(buf.value.decode()) if rc >= 1 else []
    check(len(items) >= 1, "get_all 返回至少一条")
    if not items:
        return
    it = items[0]
    check(it.get("name") == "Probe Gain" and it.get("format") == "CLAP",
          f"元数据 name/format 正确（{it.get('name')}/{it.get('format')}）")
    check(it.get("vendor") == "AuraDSP Probe",
          f"元数据 vendor 经工厂信息得到（{it.get('vendor')}）")
    rc = lib.auradsp_plugin_slot_load(
        H, 0, it["path"].encode(), it["id"].encode())
    check(rc == 1, f"slot_load(path, id) 成功（rc={rc}）")
    if rc != 1:
        return
    sbuf = ctypes.create_string_buffer(65536)
    lib.auradsp_plugin_slot_get_status(H, 0, sbuf, 65536)
    st = json.loads(sbuf.value.decode())
    check(st.get("hasActive") is True, "status hasActive=true")
    rc = lib.auradsp_plugin_slot_set_bypass(H, 0, 0)
    check(rc == 1, f"set_bypass(0) 成功（rc={rc}）")
    src = (ctypes.c_float * 2048)()
    dst = (ctypes.c_float * 2048)()
    for i in range(2048):
        src[i] = 0.8
    lib.auradsp_process(H, src, dst, 1024)
    peak = max(abs(dst[i]) for i in range(2048))
    check(abs(peak - 0.4) < 1e-3,
          f"process 峰值 {peak:.4f} == 0.8×0.5（插件真实生效）")
    rc = lib.auradsp_plugin_slot_unload(H, 0)
    check(rc == 1, f"slot_unload 成功（rc={rc}）")
    lib.auradsp_destroy(H)


def main():
    print("smoke_linux_plugin_host:")
    source_invariants()
    live_chain()
    if FAILS:
        print(f"smoke_linux_plugin_host: FAIL ({len(FAILS)})")
        return 1
    print("smoke_linux_plugin_host: PASS")
    return 0


if __name__ == "__main__":
    sys.exit(main())
