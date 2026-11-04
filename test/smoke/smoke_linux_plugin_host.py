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
     unload→destroy。引擎旁有 plugin_host_x64 时追加 remote 半：
     AURA_PLUGIN_HOST_MODE=process 下同链重跑，断言 status 的
     remoteMode=true、宿主进程在位、经共享内存环的 process 峰值
     同为 0.4。引擎产物缺失时活体半自 SKIP（CI 的 J3 会下载
     J2 产物实跑；本地先构建引擎即可）。

注意：若引擎是 OFF（stub）构建，scan 返回 0 —— 活体半据此
FAIL 并提示构建口味不对（J2 默认产物为 ON 构建）。
"""
import ctypes
import json
import os
import shutil
import subprocess
import sys
import time
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

    # 安全审查（2026-11-02）：IPC 对端认证与边界钳制不变量。
    host_dir = os.path.join(posix, "host")
    hm = read(os.path.join(host_dir, "plugin_host_main_posix.cpp"))
    hc = read(os.path.join(host_dir, "plugin_host_client_posix.cpp"))
    sr = read(os.path.join(host_dir, "plugin_shared_region_posix.cpp"))
    check("SO_PEERCRED" in hm and "cred.uid" in hm,
          "[sec] 宿主 accept 后校验对端 uid")
    check("chmod(options.pipeName" in hm and "0600" in hm,
          "[sec] 宿主 socket 文件 chmod 0600")
    check("SO_PEERCRED" in hc and "cred.uid" in hc,
          "[sec] 客户端 connect 后校验宿主 uid")
    check("unpackTransportChannels(in.reserved)," in hm
          and "kChannels)" in hm,
          "[sec] 宿主音频线程声道数钳制到 kChannels")
    check("fstat" in sr and "st_size" in sr,
          "[sec] SharedRegion::open 映射前校验对象尺寸")
    check("S_ISDIR" in hc and "::stat(xdg" in hc,
          "[sec] socketBaseDir 校验 XDG 目录存在性（死目录回落 /tmp）")

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

    # 双宿主路由不变量（阶段五）
    scanner_cpp = read(os.path.join(ENGINE, "plugins", "driver",
                                    "plugin_scanner.cpp"))
    check("remoteClientFor" in scanner_cpp and
          "pluginBinaryBitness" in scanner_cpp and
          "HostArch::X86" in scanner_cpp,
          "manager 双宿主分派在位（位数探测 + x86 客户端）")
    client_posix = read(os.path.join(ENGINE, "plugins", "platform",
                                     "posix", "host",
                                     "plugin_host_client_posix.cpp"))
    check('"/plugin_host_x86"' in client_posix and
          '"/plugin_host_x64"' in client_posix,
          "POSIX 客户端按位数定位双宿主")
    check("AURADSP_BUILD_HOST_X86" in cmake and
          "plugin_host_x86" in cmake,
          "Linux CMake 含 x86 桥宿主目标（multilib 开关）")


def process_peak(lib, H, src, dst, expect=0.4, deadline_s=2.0):
    """反复喂块直到输出峰值收敛到期望值，或截止时间到。

    远程路径是流水线语义（E15）：处理结果在后续回调才回到输出，
    宿主音频线程在繁忙的 CI runner 上可能晚于固定窗口苏醒——
    原固定 6 次 x 10ms 窗口曾在 CI 上等不到首个回块、误报直通
    值 0.8（run 41449998675 J3；同源码本机不复现）。改为轮询
    至收敛（上限 2s）：真故障仍会以截止时的峰值如实失败。
    进程内路径同步生效，首轮即收敛。"""
    peak = 0.0
    end = time.monotonic() + deadline_s
    while True:
        lib.auradsp_process(H, src, dst, 1024)
        peak = max(abs(dst[i]) for i in range(2048))
        if abs(peak - expect) < 1e-3 or time.monotonic() >= end:
            return peak
        time.sleep(0.01)


def run_chain(lib, plug_dir, mode):
    """一条完整的 C ABI 插件链（现行签名）。mode: inproc/remote。
    remote 模式下音频经共享内存环传输，结果按 E15 流水语义在
    后续回调到达，故连跑数次取末次峰值；inproc 首调即断言。"""
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    h = lib.auradsp_create(48000.0, 4096)
    check(bool(h), f"[{mode}] auradsp_create(48000, 4096) 成功")
    if not h:
        return
    H = ctypes.c_void_p(h)
    n = lib.auradsp_plugin_scan(H, plug_dir.encode())
    check(n >= 1, f"[{mode}] scan 找到门禁插件（n={n}；为 0 说明引擎是 "
                  "stub 构建，口味不对）")
    if n < 1:
        return
    buf = ctypes.create_string_buffer(262144)
    rc = lib.auradsp_plugin_get_all(H, buf, 262144)
    items = json.loads(buf.value.decode()) if rc >= 1 else []
    check(len(items) >= 1, f"[{mode}] get_all 返回至少一条")
    if not items:
        return
    it = items[0]
    check(it.get("name") == "Probe Gain" and it.get("format") == "CLAP",
          f"[{mode}] 元数据 name/format 正确"
          f"（{it.get('name')}/{it.get('format')}）")
    check(it.get("vendor") == "AuraDSP Probe",
          f"[{mode}] 元数据 vendor 经工厂信息得到（{it.get('vendor')}）")
    rc = lib.auradsp_plugin_slot_load(
        H, 0, it["path"].encode(), it["id"].encode())
    check(rc == 1, f"[{mode}] slot_load(path, id) 成功（rc={rc}）")
    if rc != 1:
        return
    sbuf = ctypes.create_string_buffer(65536)
    lib.auradsp_plugin_slot_get_status(H, 0, sbuf, 65536)
    st = json.loads(sbuf.value.decode())
    check(st.get("hasActive") is True, f"[{mode}] status hasActive=true")
    if mode == "remote":
        check(st.get("remoteMode") is True,
              "[remote] status remoteMode=true（确实走了隔离宿主）")
        hosts = subprocess.run(["pgrep", "-c", "-x", "plugin_host_x64"],
                               capture_output=True, text=True).stdout.strip()
        check(hosts.isdigit() and int(hosts) >= 1,
              f"[remote] plugin_host_x64 进程在位（{hosts}）")
    rc = lib.auradsp_plugin_slot_set_bypass(H, 0, 0)
    check(rc == 1, f"[{mode}] set_bypass(0) 成功（rc={rc}）")
    src = (ctypes.c_float * 2048)()
    dst = (ctypes.c_float * 2048)()
    for i in range(2048):
        src[i] = 0.8
    peak = process_peak(lib, H, src, dst)
    check(abs(peak - 0.4) < 1e-3,
          f"[{mode}] process 峰值 {peak:.4f} == 0.8×0.5（插件真实生效）")
    rc = lib.auradsp_plugin_slot_unload(H, 0)
    check(rc == 1, f"[{mode}] slot_unload 成功（rc={rc}）")
    lib.auradsp_destroy(H)



def run_bundle_scan(lib, tmp, cc):
    """VST3 bundle 的 Linux 布局解析（2026-11-03，32 位对等）：
    plugin_bundle.cpp 此前只有 Windows 架构目录，Linux 下目录型
    VST3 扫描不可见。用 CLAP 探针二进制拼 Contents/<arch>-linux
    布局做扫描级断言——验的是 bundle 发现/解析/位数判定/偏好序，
    不是 VST3 格式本身（内层是 CLAP 二进制，64 位条目走快速元
    数据兜底、不会真加载）。32 位半需 multilib 编探针，缺失即
    SKIP 该半。"""
    def build(args, out):
        r = subprocess.run(
            [cc, *args, "-shared", "-fPIC", "-O2",
             "-I", os.path.join(ROOT, "vendor", "plugin-api"),
             os.path.join(TEST_DIR, "smoke", "probe_gain.c"), "-o", out],
            capture_output=True, text=True)
        return r.returncode == 0

    bdir = os.path.join(tmp, "bundles")
    p64 = os.path.join(tmp, "probe64.so")
    if not build([], p64):
        print("  SKIP bundle 节：64 位探针编译失败")
        return
    def bundle(name, arch, src):
        d = os.path.join(bdir, name + ".vst3", "Contents", arch)
        os.makedirs(d)
        shutil.copy(src, os.path.join(d, name + ".so"))

    bundle("BundleA", "x86_64-linux", p64)
    bundle("BundleC", "x86_64-linux", p64)
    p32 = os.path.join(tmp, "probe32.so")
    have32 = build(["-m32"], p32)
    if have32:
        bundle("BundleB", "x86-linux", p32)
        bundle("BundleC", "x86-linux", p32)
    else:
        print("  SKIP bundle 32 位半：-m32 编译不可用（缺 multilib）")

    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    h = lib.auradsp_create(48000.0, 4096)
    check(bool(h), "[bundle] auradsp_create 成功")
    if not h:
        return
    H = ctypes.c_void_p(h)
    n = lib.auradsp_plugin_scan(H, bdir.encode())
    buf = ctypes.create_string_buffer(262144)
    rc = lib.auradsp_plugin_get_all(H, buf, 262144)
    items = json.loads(buf.value.decode()) if rc >= 1 else []
    by_name = {it.get("name"): it for it in items}
    a = by_name.get("BundleA")
    check(a is not None and a.get("format") == "VST3"
          and a.get("is64Bit") is True,
          f"[bundle] x86_64-linux bundle 可见且判 64 位（n={n}）")
    c = by_name.get("BundleC")
    check(c is not None and c.get("is64Bit") is True,
          "[bundle] 双架构 bundle 优先取 64 位二进制")
    if have32:
        b = by_name.get("BundleB")
        # 契约（2026-11-04 扫描归属重构起）：32 位条目的兼容性按位桥
        # 可用性判定——位桥在位 isCompatible=true 且无错误文案；缺失
        # 则 false 且文案指明缺 plugin_host_x86。旧口径「一律不兼容 +
        # 请安装 64 位版本」已退役，不得再现。
        err = (b.get("errorMessage") or "") if b else ""
        compat_ok = b is not None and (
            (b.get("isCompatible") is True and err == "")
            or (b.get("isCompatible") is False
                and "plugin_host_x86" in err))
        check(b is not None and b.get("is64Bit") is False and compat_ok
              and "请安装 64 位版本" not in err,
              "[bundle] 仅 x86-linux 的 bundle 可发现且兼容性随位桥可用性")
    lib.auradsp_destroy(H)


def run_deep_scan(lib, lib_path, tmp, cc):
    """深扫断言（2026-11-04，扫描归属重构 996eeef + D-8 的 Linux 验收）：
    重构后扫描由引擎本地承载、深扫按位数分派宿主代查，此前只有
    Windows 口径的 arch/metadata 冒烟覆盖该行为（Linux 上 SKIP）。
    本节按实测契约断言：
    - 快扫（deep=0）全格式纯文件头：name=文件 stem、id 为空（D-8）；
    - 深扫 64 位：默认（宿主分派）与 AURA_PLUGIN_DEEP_SCAN=inproc
      两路都给出工厂真值（name/vendor/id 与 CLAP 探针描述符一致）；
    - 深扫 32 位：IA32 可执行的平台（CI/真机）经 x86 宿主给工厂
      真值且 compatible；IA32 不可执行的平台（本 VM）回落浅层条目
      （name=stem），兼容性仍随位桥在位为 true；
    - 位桥缺失态：临时移走 plugin_host_x86 后，32 位条目（快扫与
      深扫）必须 compatible=false 且文案指明缺 plugin_host_x86，
      64 位真值不受影响（finally 中恢复工件）。"""
    ddir = os.path.join(tmp, "deepscan")
    os.makedirs(ddir)
    src = os.path.join(TEST_DIR, "smoke", "probe_gain.c")
    inc = os.path.join(ROOT, "vendor", "plugin-api")

    def build(args, out):
        r = subprocess.run([cc, *args, "-shared", "-fPIC", "-O2",
                            "-I", inc, src, "-o", out],
                           capture_output=True, text=True)
        return r.returncode == 0

    p64 = os.path.join(ddir, "probe64.clap")
    if not build([], p64):
        print("  SKIP 深扫节：64 位探针编译失败")
        return
    p32 = os.path.join(ddir, "probe32.clap")
    have32 = build(["-m32"], p32)
    if not have32:
        print("  SKIP 深扫 32 位半：-m32 编译不可用（缺 multilib）")

    # IA32 执行能力探测：决定 32 位深扫断言走真值路还是回落路。
    ia32_exec = False
    if have32:
        hello = os.path.join(tmp, "hello32")
        r = subprocess.run([cc, "-m32", "-xc", "-", "-o", hello],
                           input="int main(){return 42;}",
                           capture_output=True, text=True)
        if r.returncode == 0:
            try:
                ia32_exec = subprocess.run(
                    [hello], capture_output=True).returncode == 42
            except OSError:
                ia32_exec = False

    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]

    def scan(deep):
        h = lib.auradsp_create(48000.0, 4096)
        if not h:
            return {}
        H = ctypes.c_void_p(h)
        n = lib.auradsp_plugin_scan(H, ddir.encode(), deep)
        buf = ctypes.create_string_buffer(262144)
        rc = lib.auradsp_plugin_get_all(H, buf, 262144)
        items = json.loads(buf.value.decode()) if rc >= 1 else []
        lib.auradsp_destroy(H)
        return {os.path.basename(it.get("path", "")): it for it in items}

    def factory_ok(it):
        return (it is not None and it.get("name") == "Probe Gain"
                and it.get("vendor") == "AuraDSP Probe"
                and it.get("id") == "com.auradsp.probe.gain")

    saved = {k: os.environ.get(k)
             for k in ("AURA_PLUGIN_HOST_MODE", "AURA_PLUGIN_DEEP_SCAN")}
    try:
        os.environ.pop("AURA_PLUGIN_HOST_MODE", None)
        os.environ.pop("AURA_PLUGIN_DEEP_SCAN", None)

        m = scan(0)
        q = m.get("probe64.clap")
        check(q is not None and q.get("name") == "probe64"
              and q.get("id") == "",
              "[deep] 快扫纯文件头：name=stem 且 id 空（D-8）")
        m = scan(1)
        check(factory_ok(m.get("probe64.clap")),
              "[deep] 深扫 64 位（默认宿主分派）给出工厂真值")
        os.environ["AURA_PLUGIN_DEEP_SCAN"] = "inproc"
        m = scan(1)
        check(factory_ok(m.get("probe64.clap")),
              "[deep] 深扫 64 位（inproc 回退）给出工厂真值")
        os.environ.pop("AURA_PLUGIN_DEEP_SCAN", None)

        if have32:
            m = scan(1)
            d32 = m.get("probe32.clap")
            if ia32_exec:
                check(factory_ok(d32)
                      and d32.get("isCompatible") is True,
                      "[deep] 深扫 32 位经 x86 宿主给出工厂真值")
            else:
                check(d32 is not None and d32.get("name") == "probe32"
                      and d32.get("is64Bit") is False
                      and d32.get("isCompatible") is True,
                      "[deep] 深扫 32 位（IA32 不可执行）回落浅层且随位桥兼容")

        # 位桥缺失态：移走 x86 宿主后 32 位必须明确不可兼容。
        x86_exe = os.path.join(os.path.dirname(lib_path), "plugin_host_x86")
        hidden = x86_exe + ".gate_hidden"
        had_exe = os.path.isfile(x86_exe)
        if had_exe:
            os.rename(x86_exe, hidden)
        try:
            if have32:
                for deep in (0, 1):
                    m = scan(deep)
                    d32 = m.get("probe32.clap")
                    check(d32 is not None
                          and d32.get("isCompatible") is False
                          and "plugin_host_x86" in (
                              d32.get("errorMessage") or ""),
                          f"[deep] 位桥缺失时 32 位明确不兼容（deep={deep}）")
            m = scan(1)
            check(factory_ok(m.get("probe64.clap")),
                  "[deep] 位桥缺失不影响 64 位深扫真值")
        finally:
            if had_exe:
                os.rename(hidden, x86_exe)
    finally:
        for k, v in saved.items():
            if v is None:
                os.environ.pop(k, None)
            else:
                os.environ[k] = v


def run_x86_bridge(lib, lib_path, cc):
    """32 位桥活体：直调 slot_load（不经扫描——深扫的工厂探测在
    x64 宿主内无法加载 32 位模块，那是扫描路由的后续议题；本节
    验证加载路由 + 跨位数 IPC/环传输）。本机不可执行 32 位二进
    制时自 SKIP（CI 的 ubuntu-latest 可实跑）。"""
    host86 = os.path.join(os.path.dirname(lib_path), "plugin_host_x86")
    if not os.path.isfile(host86):
        print("  SKIP x86 桥半：引擎旁无 plugin_host_x86"
              "（AURADSP_BUILD_HOST_X86=OFF 时预期内）")
        return
    with open(host86, "rb") as f:
        ident = f.read(5)
    check(len(ident) == 5 and ident[4] == 1,
          "[x86] plugin_host_x86 是 ELFCLASS32 二进制")
    # 32 位可执行性探测：无参运行应以参数校验 rc=1 退出；
    # 段错误（如 VM 禁用 IA32 仿真）则本节活体半跳过。
    try:
        probe = subprocess.run([host86], capture_output=True)
    except OSError as e:
        print(f"  SKIP x86 桥活体半：plugin_host_x86 不可执行（{e}；"
              f"工件流转丢失 +x 时的预期形态，客户端已按缺失回落）")
        return
    if probe.returncode != 1:
        print(f"  SKIP x86 桥活体半：本机不可执行 32 位二进制"
              f"（探测 rc={probe.returncode}；真机/CI 另行验证）")
        return
    tmp = tempfile.mkdtemp(prefix="auradsp_plug_gate32_")
    plug_dir = os.path.join(tmp, "plugins")
    os.makedirs(plug_dir)
    out = os.path.join(plug_dir, "ProbeGain32.clap")
    r = subprocess.run(
        [cc, "-m32", "-shared", "-fPIC", "-O2",
         "-I", os.path.join(ROOT, "vendor", "plugin-api"),
         os.path.join(TEST_DIR, "smoke", "probe_gain.c"), "-o", out],
        capture_output=True, text=True)
    if r.returncode != 0:
        print("  SKIP x86 桥活体半：-m32 编译不可用（缺 multilib）")
        return
    lib.auradsp_create.restype = ctypes.c_void_p
    lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
    os.environ["AURA_PLUGIN_HOST_MODE"] = "process"
    try:
        h = lib.auradsp_create(48000.0, 4096)
        check(bool(h), "[x86] auradsp_create 成功")
        if not h:
            return
        H = ctypes.c_void_p(h)
        rc = lib.auradsp_plugin_slot_load(
            H, 0, out.encode(), b"com.auradsp.probe.gain")
        check(rc == 1, f"[x86] 32 位插件 slot_load 成功（rc={rc}）")
        if rc != 1:
            return
        sbuf = ctypes.create_string_buffer(65536)
        lib.auradsp_plugin_slot_get_status(H, 0, sbuf, 65536)
        st = json.loads(sbuf.value.decode())
        check(st.get("remoteMode") is True, "[x86] status remoteMode=true")
        n86 = subprocess.run(["pgrep", "-c", "-x", "plugin_host_x86"],
                             capture_output=True, text=True).stdout.strip()
        check(n86.isdigit() and int(n86) >= 1,
              f"[x86] plugin_host_x86 进程在位（{n86}，路由命中桥宿主）")
        assert lib.auradsp_plugin_slot_set_bypass(H, 0, 0) == 1
        src = (ctypes.c_float * 2048)()
        dst = (ctypes.c_float * 2048)()
        for i in range(2048):
            src[i] = 0.8
        peak = process_peak(lib, H, src, dst)
        check(abs(peak - 0.4) < 1e-3,
              f"[x86] 跨位数环传输 process 峰值 {peak:.4f} == 0.4")
        assert lib.auradsp_plugin_slot_unload(H, 0) == 1
        lib.auradsp_destroy(H)
    finally:
        os.environ.pop("AURA_PLUGIN_HOST_MODE", None)


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
    os.environ.pop("AURA_PLUGIN_HOST_MODE", None)
    run_chain(lib, plug_dir, "inproc")
    run_bundle_scan(lib, tmp, cc)
    run_deep_scan(lib, lib_path, tmp, cc)

    host_exe = os.path.join(os.path.dirname(lib_path), "plugin_host_x64")
    # 引擎口味判定：REMOTE 构建的 .so 内嵌宿主名文字（客户端定位
    # 用）；INPROC 裁剪构建没有。混合状态（裁剪引擎 + 残留宿主）
    # 下 remote 半无从成立，按 SKIP 处理而非误红。
    with open(lib_path, "rb") as f:
        engine_remote = b"plugin_host_x64" in f.read()
    if os.path.isfile(host_exe) and engine_remote:
        os.environ["AURA_PLUGIN_HOST_MODE"] = "process"
        try:
            run_chain(lib, plug_dir, "remote")
        finally:
            os.environ.pop("AURA_PLUGIN_HOST_MODE", None)
    else:
        print("  SKIP remote 半：引擎旁无 plugin_host_x64 或引擎为"
              "进程内裁剪构建（REMOTE=OFF 时预期内）")
    run_x86_bridge(lib, lib_path, cc)


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
