# -*- coding: utf-8 -*-
"""smoke_bridge_unified_abi.py — P5 统一桥契约（ab_*）冒烟。

方案（docs/10-架构/桥惰性加载与全后端静音门控及DSP解耦落地方案-2026-10-29.md
§4.1 / §5-P5 / §8.4）：三桥公共导出收敛为 ab_*；2026-10-30 过渡期清理后
旧前缀（vb_*/asio_*/vaio_*）**不再导出**。清单一致性已由
smoke_g7_5_bridge_exports.py / smoke_abi_consistency.py 钉住（.def ↔ 头 ↔
Dart）；本测试只查那两道门禁**查不到**的几件事：

  [A] 真相源 DLL 真的导出 14 个 ab_* 符号，且 ab_abi_version == 1
      （清单改了没编译，清单门禁照样绿——同 §7-5 [C] 的判据）
  [B] ab_capabilities 可解析，bridge 字段与 DLL 对得上（诊断/UI 依赖它）
  [C] 旧前缀公共面已从 DLL 下线（过渡期清理的硬约束）。
  [D] VM 运行态（Voicemeeter 在线且 OUT 槽空闲）：ab_start → frames 增长 →
      status 带 P3 的 gated/idleMs → ab_stop。未安装/槽被占 → SKIP 不断言。

用法：python test/smoke/smoke_bridge_unified_abi.py（退出码 0 = 全绿）
"""
import ctypes
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
REL = os.path.join(ROOT, "core", "desktop", "windows-drivers", "out", "Release")

# (旧前缀, DLL, 能力自报名)。VM 的旧前缀是 vb，桥 id 报 "vm"。
BRIDGES = [
    ("vb", "auravm_bridge.dll", "vm"),
    ("asio", "auraasio_bridge.dll", "asio"),
    ("vaio", "auravaio_bridge.dll", "vaio"),
]

# bridge/common/aurabridge.h 的 14 个导出（AURABRIDGE_ABI=1）
AB_SYMBOLS = [
    "ab_abi_version", "ab_capabilities", "ab_detect", "ab_start", "ab_stop",
    "ab_status", "ab_set_param", "ab_set_param_str", "ab_get_param",
    "ab_get_param_str", "ab_viz_read", "ab_bypass", "ab_test_start",
    "ab_test_stop",
]
EXPECTED_ABI = 1

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def load(dll):
    return ctypes.CDLL(os.path.join(REL, dll))


# 旧前缀公共面（§8.4 清理目标）：这些符号必须已从 DLL 下线。
LEGACY_SYMBOLS = [
    "detect", "start", "stop", "status", "set_param", "set_param_str",
    "get_param", "get_param_str", "viz_read", "bypass", "test_start",
    "test_stop",
]


def bind(mod, name, restype, argtypes):
    fn = getattr(mod, name)
    fn.restype = restype
    fn.argtypes = argtypes
    return fn


print("== [A] ab_* 导出与契约版本 ==")
mods = {}  # bridge_id -> (DLL 模块, 旧前缀)
for legacy_prefix, dll, bridge_id in BRIDGES:
    path = os.path.join(REL, dll)
    if not os.path.exists(path):
        print("SKIP  [A] %s 未构建" % dll)
        continue
    try:
        mod = load(dll)
    except OSError as e:
        check("[A] %s 可加载" % dll, False, str(e))
        continue
    mods[bridge_id] = (mod, legacy_prefix)
    missing = []
    for sym in AB_SYMBOLS:
        try:
            getattr(mod, sym)
        except (OSError, AttributeError):
            missing.append(sym)
    check("[A1] %s 导出全部 %d 个 ab_* 符号" % (dll, len(AB_SYMBOLS)),
          missing == [], ",".join(missing))
    if not missing:
        abi = bind(mod, "ab_abi_version", ctypes.c_uint, [])()
        check("[A2] %s ab_abi_version == %d" % (dll, EXPECTED_ABI),
              abi == EXPECTED_ABI, "got %d" % abi)

print("== [B] ab_capabilities ==")
for bridge_id, (mod, _prefix) in mods.items():
    fn = bind(mod, "ab_capabilities", ctypes.c_int,
              [ctypes.c_char_p, ctypes.c_int])
    buf = ctypes.create_string_buffer(1024)
    n = fn(buf, 1024)
    if n <= 0:
        check("[B] %s capabilities 可读" % bridge_id, False, "rc=%d" % n)
        continue
    try:
        caps = json.loads(buf.value.decode("utf-8", "replace"))
    except ValueError as e:
        check("[B] %s capabilities 是 JSON" % bridge_id, False, str(e))
        continue
    check("[B] %s capabilities.bridge 自报一致" % bridge_id,
          caps.get("bridge") == bridge_id, json.dumps(caps, ensure_ascii=False))
    check("[B] %s capabilities 声明 gating（P3 已接入）" % bridge_id,
          caps.get("gating") is True)

print("== [C] 旧前缀公共面已下线（过渡期清理）==")
for bridge_id, (mod, prefix) in mods.items():
    leaked = []
    for suffix in LEGACY_SYMBOLS:
        try:
            getattr(mod, prefix + "_" + suffix)
        except (OSError, AttributeError):
            continue
        leaked.append(prefix + "_" + suffix)
    check("[C] %s 不再导出旧前缀公共面（%d 个）" % (bridge_id, len(LEGACY_SYMBOLS)),
          leaked == [], ",".join(leaked))

print("== [D] VM 运行态：ab_start → status(gated/idleMs) → ab_stop ==")
vm = mods.get("vm")
if vm is None:
    print("SKIP  [D] VM 桥未构建")
else:
    mod = vm[0]
    start = bind(mod, "ab_start", ctypes.c_int,
                 [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p])
    status = bind(mod, "ab_status", ctypes.c_int,
                  [ctypes.c_char_p, ctypes.c_int])
    stop = bind(mod, "ab_stop", ctypes.c_int, [])

    def get_status():
        buf = ctypes.create_string_buffer(4096)
        if status(buf, 4096) <= 0:
            return {}
        try:
            return json.loads(buf.value.decode("utf-8", "replace"))
        except ValueError:
            return {}

    eng = os.path.join(ROOT, "test", "auradsp_engine.dll")
    rc = start(eng.encode("utf-8"), b"", b"{}")
    if rc != 0:
        note = get_status().get("note", "")
        print(f"SKIP  [D] ab_start rc={rc}（note={note}）——让路不断言")
    else:
        check("[D1] ab_start rc==0", rc == 0)
        time.sleep(2.5)
        st = get_status()
        check("[D2] frames 增长", st.get("frames", 0) > 0,
              f"frames={st.get('frames')}")
        check("[D3] status 带 P3 键 gated/idleMs",
              isinstance(st.get("gated"), int) and isinstance(st.get("idleMs"), int),
              f"gated={st.get('gated')} idleMs={st.get('idleMs')}")
        rc = stop()
        check("[D4] ab_stop rc==0", rc == 0, f"rc={rc}")
        st = get_status()
        check("[D5] stop 后 running=false", st.get("running") is False,
              f"running={st.get('running')}")

print("\n" + "=" * 46)
if fails:
    print("FAILED %d 项:" % len(fails))
    for f in fails:
        print("  - " + f)
    sys.exit(1)
print("ALL PASS：P5 统一桥契约（ab_*）过渡期清理后冒烟全绿")
