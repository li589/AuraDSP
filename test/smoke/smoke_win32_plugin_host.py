# -*- coding: utf-8 -*-
"""smoke_win32_plugin_host — Windows 插件双宿主与 32 位位桥门禁（2026-11-02）。

包含三大阶段验证：
  1. 架构与产物不变量：
     - core/desktop/windows/CMakeLists.txt 包含 plugin_host_x64 与 plugin_host_x86 目标；
     - 引擎输出目录及 test/ 目录下存在 64 位宿主 plugin_host_x64.exe 与 32 位桥宿主 plugin_host_x86.exe；
     - PE 头校验：plugin_host_x64.exe 为 0x8664 (AMD64)，plugin_host_x86.exe 为 0x14c (i386)；
  2. 32 位位桥活体全链（AURA_PLUGIN_HOST_MODE=process）：
     - 编译/就绪 32 位 CLAP 插件 probe_gain_x86.clap (IMAGE_FILE_MACHINE_I386)；
     - 通过 C ABI 调用 slot_load 加载 32 位插件；
     - 验证双宿主路由准确命中 plugin_host_x86.exe 子进程；
     - 验证 status 报告：remoteMode=true, is64Bit=false, isCompatible=true；
     - 跨位数音频处理验证：输入 0.8，经 32 位位桥（增益 0.5）后输出 0.4；
  3. 卸载与资源回收。
"""

import ctypes
import json
import os
import struct
import subprocess
import sys
import time

TEST_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.dirname(TEST_DIR)

sys.path.insert(0, TEST_DIR)
import engine_artifact  # noqa: E402

FAILS = []


def check(cond, msg):
    print(("  PASS " if cond else "  FAIL ") + msg)
    if not cond:
        FAILS.append(msg)


def pe_machine(path):
    if not os.path.isfile(path):
        return 0
    with open(path, "rb") as f:
        buf = f.read(1024)
    if len(buf) < 64:
        return 0
    e_lfanew = struct.unpack_from("<I", buf, 0x3C)[0]
    if len(buf) < e_lfanew + 6:
        return 0
    return struct.unpack_from("<H", buf, e_lfanew + 4)[0]


def test_invariants():
    print("=== [1] 双宿主源码与构建不变量 ===")
    cmake_path = os.path.join(ROOT, "core", "desktop", "windows", "CMakeLists.txt")
    with open(cmake_path, encoding="utf-8") as f:
        cmake = f.read()
    check("plugin_host_x64" in cmake, "CMakeLists.txt 包含 plugin_host_x64 目标")
    check("plugin_host_x86" in cmake, "CMakeLists.txt 包含 plugin_host_x86 目标")

    client_cpp = os.path.join(ROOT, "engine", "plugins", "platform", "win32", "host", "plugin_host_client.cpp")
    with open(client_cpp, encoding="utf-8") as f:
        client = f.read()
    check("plugin_host_x86.exe" in client and "plugin_host_x64.exe" in client,
          "plugin_host_client.cpp 包含 x86 与 x64 宿主路径分派")

    scanner_cpp = os.path.join(ROOT, "engine", "plugins", "driver", "plugin_scanner.cpp")
    with open(scanner_cpp, encoding="utf-8") as f:
        scanner = f.read()
    check("remoteClientFor" in scanner, "plugin_scanner.cpp 包含 remoteClientFor 位数路由")

    engine_out = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release")
    h64 = os.path.join(engine_out, "plugin_host_x64.exe")
    h86 = os.path.join(engine_out, "plugin_host_x86.exe")
    check(os.path.isfile(h64), f"64 位宿主已就绪: {h64}")
    check(os.path.isfile(h86), f"32 位桥宿主已就绪: {h86}")

    m64 = pe_machine(h64)
    m86 = pe_machine(h86)
    check(m64 == 0x8664, f"plugin_host_x64.exe 是 AMD64 PE (0x{m64:x})")
    check(m86 == 0x14c, f"plugin_host_x86.exe 是 i386 PE (0x{m86:x})")


def test_32bit_bridge():
    print("\n=== [2] 32 位位桥活体全链测试 ===")
    lib_path = engine_artifact.engine_lib_path()
    if not os.path.isfile(lib_path):
        print(f"  SKIP: 引擎动态库未就绪: {lib_path}")
        return

    # 确保 32 位 probe_gain_x86.clap 就绪
    clap_path = os.path.join(TEST_DIR, "smoke", "probe_gain_x86.clap")
    if not os.path.isfile(clap_path):
        src_c = os.path.join(TEST_DIR, "smoke", "probe_gain.c")
        cmd = (
            'cmd /c ""C:\\Program Files\\Microsoft Visual Studio\\18\\Community\\VC\\Auxiliary\\Build\\vcvarsall.bat" x86 >nul && '
            f'cl /nologo /LD /O2 /I "{os.path.join(ROOT, "vendor", "plugin-api")}" "{src_c}" '
            f'/link /OUT:"{clap_path}""'
        )
        subprocess.run(cmd, shell=True, check=True)
        # 清理多余临时文件
        for ext in (".obj", ".lib", ".exp"):
            tmp_f = os.path.join(TEST_DIR, "smoke", "probe_gain" + ext)
            if os.path.isfile(tmp_f):
                os.remove(tmp_f)

    check(os.path.isfile(clap_path), "probe_gain_x86.clap 在位")
    m_clap = pe_machine(clap_path)
    check(m_clap == 0x14c, f"probe_gain_x86.clap 是 32 位 i386 二进制 (0x{m_clap:x})")

    # 启用进程外双宿主模式
    os.environ["AURA_PLUGIN_HOST_MODE"] = "process"

    dll = ctypes.CDLL(lib_path)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int
    ]
    dll.auradsp_plugin_slot_load.restype = ctypes.c_int
    dll.auradsp_plugin_slot_load.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p
    ]
    dll.auradsp_plugin_slot_set_bypass.restype = ctypes.c_int
    dll.auradsp_plugin_slot_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    dll.auradsp_plugin_slot_get_status.restype = ctypes.c_int
    dll.auradsp_plugin_slot_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int
    ]

    h = dll.auradsp_create(48000.0, 4096)
    check(bool(h), "auradsp_create 成功")
    if not h:
        return

    try:
        # 1. 加载 32 位插件到 slot 0
        rc = dll.auradsp_plugin_slot_load(
            h, 0, clap_path.encode("utf-8"), b"com.auradsp.probe.gain")
        check(rc == 1, f"32 位插件 slot_load 成功 (rc={rc})")

        # 2. 状态断言
        buf = ctypes.create_string_buffer(65536)
        dll.auradsp_plugin_slot_get_status(h, 0, buf, 65536)
        st = json.loads(buf.value.decode("utf-8"))
        check(st.get("hasActive") is True, "status.hasActive == true")
        check(st.get("remoteMode") is True, "status.remoteMode == true")
        plug = st.get("plugin", {})
        check(plug.get("is64Bit") is False, "plugin.is64Bit == false (正确识别为 32 位)")
        check(plug.get("isCompatible") is True, "plugin.isCompatible == true (位桥支持兼容)")
        check(plug.get("name") == "Probe Gain", f"plugin.name == 'Probe Gain' (got {plug.get('name')})")

        # 3. 验证宿主进程在位且确为 plugin_host_x86.exe
        import psutil
        cur_proc = psutil.Process(os.getpid())
        children = cur_proc.children()
        host_86 = [c for c in children if c.name().lower() == "plugin_host_x86.exe"]
        check(len(host_86) >= 1, f"宿主子进程为 plugin_host_x86.exe (匹配到 {len(host_86)} 个)")

        # 4. 音频处理断言（增益 0.5）
        bp = dll.auradsp_plugin_slot_set_bypass(h, 0, 0)
        check(bp == 1, "auradsp_plugin_slot_set_bypass(0, 0) 解除旁路成功")

        frames = 256
        in_samples = [0.8] * (frames * 2)
        in_arr = (ctypes.c_float * len(in_samples))(*in_samples)
        out_arr = (ctypes.c_float * len(in_samples))()

        for _ in range(10):
            dll.auradsp_process(h, in_arr, out_arr, frames)
            time.sleep(0.005)

        out_list = list(out_arr)
        peak = max(abs(x) for x in out_list)
        check(abs(peak - 0.4) < 1e-3, f"32 位位桥音频处理输出峰值 = {peak:.4f} (期望 0.4000)")

    finally:
        dll.auradsp_destroy(h)
        time.sleep(0.1)


def test_real_32bit_plugins():
    print("\n=== [3] 真实 32 位 CLAP 与 VST3 外部插件验证 ===")
    lib_path = engine_artifact.engine_lib_path()
    clap_path = os.path.join(ROOT, "test", "clap", "3BandEQ.clap")
    vst_path = os.path.join(ROOT, "test", "vst", "3BandEQ.vst3")
    if not os.path.isfile(clap_path) and not os.path.isdir(vst_path):
        print("  SKIP: test/clap 或 test/vst 插件未就绪")
        return

    os.environ["AURA_PLUGIN_HOST_MODE"] = "process"
    dll = ctypes.CDLL(lib_path)
    dll.auradsp_create.restype = ctypes.c_void_p
    dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
    dll.auradsp_process.argtypes = [
        ctypes.c_void_p, ctypes.POINTER(ctypes.c_float),
        ctypes.POINTER(ctypes.c_float), ctypes.c_int
    ]
    dll.auradsp_plugin_slot_load.restype = ctypes.c_int
    dll.auradsp_plugin_slot_load.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_char_p
    ]
    dll.auradsp_plugin_slot_set_bypass.restype = ctypes.c_int
    dll.auradsp_plugin_slot_set_bypass.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
    dll.auradsp_plugin_slot_get_status.restype = ctypes.c_int
    dll.auradsp_plugin_slot_get_status.argtypes = [
        ctypes.c_void_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_int
    ]

    h = dll.auradsp_create(48000.0, 4096)
    try:
        if os.path.isfile(clap_path):
            rc = dll.auradsp_plugin_slot_load(h, 0, clap_path.encode("utf-8"), b"")
            check(rc == 1, f"真实 32 位 CLAP slot_load 成功 (rc={rc})")
            buf = ctypes.create_string_buffer(65536)
            dll.auradsp_plugin_slot_get_status(h, 0, buf, 65536)
            st = json.loads(buf.value.decode("utf-8"))
            plug = st.get("plugin", {})
            check(plug.get("format") == "CLAP", "CLAP 格式正确")
            check(plug.get("is64Bit") is False, "CLAP is64Bit == false")
            check(plug.get("name") == "3 Band EQ", f"CLAP name == '3 Band EQ' (got {plug.get('name')})")

        if os.path.isdir(vst_path):
            rc = dll.auradsp_plugin_slot_load(h, 1, vst_path.encode("utf-8"), b"")
            check(rc == 1, f"真实 32 位 VST3 slot_load 成功 (rc={rc})")
            buf = ctypes.create_string_buffer(65536)
            dll.auradsp_plugin_slot_get_status(h, 1, buf, 65536)
            st = json.loads(buf.value.decode("utf-8"))
            plug = st.get("plugin", {})
            check(plug.get("format") == "VST3", "VST3 格式正确")
            check(plug.get("is64Bit") is False, "VST3 is64Bit == false")
            check(plug.get("name") == "3 Band EQ", f"VST3 name == '3 Band EQ' (got {plug.get('name')})")

            dll.auradsp_plugin_slot_set_bypass(h, 1, 0)
            frames = 256
            in_samples = [0.8] * (frames * 2)
            in_arr = (ctypes.c_float * len(in_samples))(*in_samples)
            out_arr = (ctypes.c_float * len(in_samples))()
            for _ in range(10):
                dll.auradsp_process(h, in_arr, out_arr, frames)
                time.sleep(0.005)
            out_list = list(out_arr)
            peak = max(abs(x) for x in out_list)
            check(peak > 0.0, f"真实 32 位 VST3 音频输出正常 (peak={peak:.4f})")
    finally:
        dll.auradsp_destroy(h)
        time.sleep(0.1)


def main():
    test_invariants()
    test_32bit_bridge()
    test_real_32bit_plugins()
    if FAILS:
        print(f"\nFAILED: {len(FAILS)} checks failed")
        return 1
    print("\nALL PASS: Windows 插件双宿主与 32 位位桥门禁全绿")
    return 0


if __name__ == "__main__":
    sys.exit(main())

