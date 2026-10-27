# -*- coding: utf-8 -*-
"""smoke_dll_dirs.py — F1 验收：插件依赖 DLL 搜索目录通用化 + cookie 回收。

背景（审查 F1，P1→边界 P0）：原实现只服务 iZotope——路径含 izotope|ozone 时
加 6 条 `C:\\Program Files\\iZotope\\Ozone 12\\...` 字面量目录；AddDllDirectory
返回的 cookie 直接丢弃、showEditor 每次都再调一次 → 进程搜索路径单调增长，
后续插件解析同名 DLL 可能绑到别人的私有副本（ABI 不匹配 → 崩溃）。

本门禁：
  [1] 驱动 test_dll_dirs.exe（临时目录树，不依赖真插件）：通用化登记 /
      幂等（200 次 setup 不增长）/ 引用计数（共用父目录不误摘）/ 回收
      （全卸载回基线）/ 环境变量 AURADSP_PLUGIN_DLL_DIRS（进程级不回收）。
  [2] 源码不变式：win32_util.cpp 内不得出现厂商名与硬编码安装路径。
  [3] 源码不变式：两个格式的 unload 必须调用 releasePluginDllDirectories
      （只加不收 = 搜索路径泄漏）。
"""
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
EXE = os.path.join(ROOT, "core", "desktop", "windows", "out", "Release", "test_dll_dirs.exe")
WIN32_UTIL = os.path.join(ROOT, "engine", "plugins", "platform", "win32", "win32_util.cpp")
INSTANCES = [
    os.path.join(ROOT, "engine", "plugins", "formats", "vst3", "vst3_instance.cpp"),
    os.path.join(ROOT, "engine", "plugins", "formats", "clap", "clap_instance.cpp"),
]

FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


# ---------------------------------------------------------------- [1] 单元测试
print("=== [1] test_dll_dirs.exe（登记/幂等/引用计数/回收/环境变量） ===")
check("test_dll_dirs.exe exists", os.path.exists(EXE), EXE)
if not os.path.exists(EXE):
    print("DLLDIRS FAILURES:", FAIL)
    sys.exit(1)
try:
    r = subprocess.run([EXE], capture_output=True, text=True, timeout=120)
except subprocess.TimeoutExpired:
    check("exe finished", False, "timeout 120s")
    print("DLLDIRS FAILURES:", FAIL)
    sys.exit(1)
check("exit code 0", r.returncode == 0, "rc=%d err=%s" % (r.returncode, r.stderr.strip()[:200]))
try:
    d = json.loads(r.stdout.strip().splitlines()[-1])
    check("valid JSON dict", isinstance(d, dict))
except (ValueError, IndexError) as ex:
    check("valid JSON dict", False, str(ex)[:120])
    d = {}
check("all C++ assertions ok", d.get("ok") is True, "note=%s" % (d.get("note", ""),))
check("idempotent dir count (afterA==6, 200 calls stable)", d.get("afterA") == 6,
      "afterA=%s" % (d.get("afterA"),))
check("second plugin adds only own dir", d.get("afterA2") == 6 + 1, "afterA2=%s" % (d.get("afterA2"),))
check("recovers to env-only baseline", d.get("afterRelease") == 1, "afterRelease=%s" % (d.get("afterRelease"),))
check("refs baseline restored", d.get("refsAfterRelease") == 1, "refs=%s" % (d.get("refsAfterRelease"),))

# ---------------------------------------------------------------- [2] 源码不应认识厂商
print("=== [2] 源码不变式：不识别任何厂商名 / 无硬编码安装路径 ===")
def strip_comments(src):
    """去掉 // 与 /* */ 注释。注释里写历史厂商名是允许的（patched 留痕需要
    写清"原来特判谁"），代码里出现才是硬置入。"""
    out = []
    i, n = 0, len(src)
    while i < n:
        if src.startswith("//", i):
            j = src.find("\n", i)
            i = n if j < 0 else j
        elif src.startswith("/*", i):
            j = src.find("*/", i + 2)
            i = n if j < 0 else j + 2
        else:
            out.append(src[i])
            i += 1
    return "".join(out)


txt = open(WIN32_UTIL, encoding="utf-8", errors="replace").read()
code = strip_comments(txt).lower()
banned = ["izotope", "ozone"]
hit = [b for b in banned if b in code]
check("win32_util.cpp 代码内无厂商名", not hit, str(hit))
check("不再有 6 条字面量目录表", "izDirs" not in strip_comments(txt), "仍存在 izDirs")

# ---------------------------------------------------------------- [3] 成对回收
print("=== [3] 源码不变式：卸载路径必须回收 cookie ===")
for p in INSTANCES:
    src = open(p, encoding="utf-8", errors="replace").read()
    name = os.path.basename(p)
    check("%s 调用 releasePluginDllDirectories" % name, "releasePluginDllDirectories" in src)
    i_setup = src.find("setupPluginDllDirectories")
    i_rel = src.find("releasePluginDllDirectories")
    check("%s setup/release 均在实例内（加载/卸载成对）" % name, i_setup > 0 and i_rel > 0,
          "setup@%d release@%d" % (i_setup, i_rel))

if FAIL:
    print("DLLDIRS FAILURES:", FAIL)
    sys.exit(1)
print("DLLDIRS ALL PASSED")
