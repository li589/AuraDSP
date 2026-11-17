#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""smoke_spatial_fdn_removed.py — WP1 旧 spatial FDN 退役验收。

背景（工程文档 D6 / §4.2）：
  - `spatial.fdn` / `spatial.late` 的晚期混响职责已由 MC 混响接管；
  - UI/语义移除这两个开关，但引擎保留 deprecated 写别名至少一个发布周期，
    否则旧会话/旧 AIDL 配置会在加载时整段失败；
  - UI 不再读回这两个 id，避免“设置页没有、回读却把它改回去”。

覆盖：
  1. 别名迁移语义：fdn=1 且混响关闭 → preset 5；已开预设不受影响；
     late 仅在 freeverb.wet 仍为默认 0.35 时迁移到 wet。
  2. 越界/NaN 仍按参数表拒绝，不能污染状态。
  3. 源码不变式：Dart UI 不再出现这两个 id/字段，ARB 不再有对应文案。
  4. 引擎仍注册两个 id（旧配置可写），但只作为写别名存在。

范围修正（2026-11-17，r44 收口后 user 指令彻查本门禁长红）：
  §3 的全仓 token 扫描曾误伤 `lib/engine/apo_param_index.dart`——该文件
  由 tools/gen_apo_param_layout.py 自 engine_param_table.h 生成，是 APO
  参数块 ABI 的 Dart 镜像（槽位与 C 侧 ApoParamIndex.h 逐项同序），
  必须包含这两个 deprecated 别名，旧会话在 sysapo 模式下才能经参数块
  写达引擎迁移别名；它不是 UI、也不做回读（发布者仅写镜像）。此前多轮
  收口记「既存观察项」的红即此误伤。现口径：扫描排除该生成文件，改以
  正向 ABI 断言守住它（Dart 序号表与 C 表全序相等，含两别名同槽）。
"""
import ctypes
import math
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL", os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release", "auradsp_engine.dll"))

SR = 48000.0
BLOCK = 512
FAIL = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          ("  " + detail if detail and not cond else ""))
    if not cond:
        FAIL.append(name)


if not os.path.exists(DLL):
    print("SKIP（auradsp_engine.dll 不存在：%s）" % DLL)
    sys.exit(0)

dll = ctypes.CDLL(DLL)
dll.auradsp_create.restype = ctypes.c_void_p
dll.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
dll.auradsp_set_param.restype = ctypes.c_int
dll.auradsp_set_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_get_param.restype = ctypes.c_int
dll.auradsp_get_param.argtypes = [ctypes.c_void_p, ctypes.c_char_p,
                                  ctypes.c_void_p, ctypes.c_uint32]
dll.auradsp_destroy.argtypes = [ctypes.c_void_p]
dll.auradsp_get_latency_ms.restype = ctypes.c_double
dll.auradsp_get_latency_ms.argtypes = [ctypes.c_void_p]
dll.auradsp_last_error.restype = ctypes.c_char_p
dll.auradsp_last_error.argtypes = [ctypes.c_void_p]


def i32(v):
    return ctypes.c_int32(v)


def f32(v):
    return ctypes.c_float(v)


class Engine:
    def __init__(self):
        self.h = dll.auradsp_create(SR, BLOCK)
        assert self.h, "auradsp_create failed"

    def close(self):
        if self.h:
            dll.auradsp_destroy(self.h)
            self.h = None

    def set_i(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(i32(v)), 4)

    def set_f(self, pid, v):
        return dll.auradsp_set_param(self.h, pid.encode(), ctypes.byref(f32(v)), 4)

    def get_i(self, pid):
        v = i32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value

    def get_f(self, pid):
        v = f32(0)
        rc = dll.auradsp_get_param(self.h, pid.encode(), ctypes.byref(v), 4)
        return rc, v.value

    def last_error(self):
        p = dll.auradsp_last_error(self.h)
        return p.decode("utf-8", "replace") if p else ""


OFF_LIST = [
    ("limiter.enable", 0), ("gate.enable", 0), ("filter.enable", 0),
    ("shelf.enable", 0), ("dyneq.enable", 0), ("tube.enable", 0),
    ("exciter.enable", 0), ("loudness.enable", 0), ("haas.enable", 0),
    ("spatial.enable", 0), ("spatial.binaural", 0),
    ("bassmono.enable", 0), ("bass.enable", 0),
    ("convolver.enable", 0), ("ddc.enable", 0), ("liveprog.enable", 0),
    ("arbmag.enable", 0), ("comp.enable", 0), ("eq.enable", 0),
    ("crossfeed.enable", 0), ("reverb.preset", -1),
]


def new_engine(ch=8, mode=1):
    e = Engine()
    for k, v in OFF_LIST:
        assert e.set_i(k, v) == 0, k
    assert e.set_i("channels.count", ch) == 0
    assert e.set_i("channels.mode", mode) == 0
    return e


# ---------------------------------------------------------------------------
# 1. spatial.fdn 写别名
# ---------------------------------------------------------------------------
print("=== [1] spatial.fdn 写别名 ===")
e = new_engine(8, 1)
check("discrete 8ch preset=-1 -> engine -1", e.get_i("reverb.engine") == (0, -1))
check("spatial.fdn default readback 0", e.get_i("spatial.fdn") == (0, 0))

rc = e.set_i("spatial.fdn", 1)
check("fdn=1 accepted (deprecated alias)", rc == 0, "rc=%d err=%s" % (rc, e.last_error()))
check("fdn=1 while reverb off migrates to preset 5",
      e.get_i("reverb.preset") == (0, 5), str(e.get_i("reverb.preset")))
check("fdn=1 opens MC FDN on discrete path",
      e.get_i("reverb.engine") == (0, 1) and abs(dll.auradsp_get_latency_ms(e.h)) < 0.01,
      "kind=%r lat=%.2f" % (e.get_i("reverb.engine"), dll.auradsp_get_latency_ms(e.h)))

check("fdn=0 does not turn reverb off",
      e.set_i("spatial.fdn", 0) == 0 and e.get_i("reverb.preset") == (0, 5),
      str(e.get_i("reverb.preset")))

# 已经开着别的预设：fdn 只记录开关，不改用户选择
assert e.set_i("reverb.preset", 3) == 0
check("fdn=1 keeps existing preset 3",
      e.set_i("spatial.fdn", 1) == 0 and e.get_i("reverb.preset") == (0, 3),
      str(e.get_i("reverb.preset")))

# matrix 路径同样迁移到 vendor preset 5
e2 = new_engine(2, 0)
assert e2.set_i("reverb.preset", -1) == 0
base = dll.auradsp_get_latency_ms(e2.h)
check("fdn=1 on matrix path migrates to vendor preset 5",
      e2.set_i("spatial.fdn", 1) == 0 and e2.get_i("reverb.preset") == (0, 5) and
      e2.get_i("reverb.engine") == (0, 0),
      "preset=%r kind=%r" % (e2.get_i("reverb.preset"), e2.get_i("reverb.engine")))
check("fdn=1 on matrix path enables vendor (+30ms)",
      abs(dll.auradsp_get_latency_ms(e2.h) - base - 30.0) < 0.01,
      "lat=%.2f" % dll.auradsp_get_latency_ms(e2.h))

# ---------------------------------------------------------------------------
# 2. spatial.late 写别名
# ---------------------------------------------------------------------------
print("=== [2] spatial.late 写别名 ===")
e3 = new_engine(8, 1)
check("freeverb.wet default 0.35", abs(e3.get_f("freeverb.wet")[1] - 0.35) < 1e-6,
      str(e3.get_f("freeverb.wet")))
rc = e3.set_f("spatial.late", 0.7)
check("late=0.7 accepted", rc == 0, "rc=%d err=%s" % (rc, e3.last_error()))
check("late migrates into freeverb.wet when wet is default",
      abs(e3.get_f("freeverb.wet")[1] - 0.7) < 1e-6,
      str(e3.get_f("freeverb.wet")))
check("late readback still works for old configs",
      abs(e3.get_f("spatial.late")[1] - 0.7) < 1e-6)

# 用户已调过 wet：late 不得覆盖
assert e3.set_f("freeverb.wet", 0.4) == 0
assert e3.set_f("spatial.late", 0.2) == 0
check("late does not overwrite user-adjusted wet",
      abs(e3.get_f("freeverb.wet")[1] - 0.4) < 1e-6,
      str(e3.get_f("freeverb.wet")))

# 恢复默认 wet 后，下一次 late 写入仍可迁移
assert e3.set_f("freeverb.wet", 0.35) == 0
assert e3.set_f("spatial.late", 0.9) == 0
check("late migrates again after wet reset to default",
      abs(e3.get_f("freeverb.wet")[1] - 0.9) < 1e-6,
      str(e3.get_f("freeverb.wet")))

before = e3.get_f("freeverb.wet")[1]
rc = e3.set_f("spatial.late", float("nan"))
check("late NaN rejected", rc != 0, "rc=%d" % rc)
check("late NaN does not pollute wet",
      e3.get_f("freeverb.wet")[1] == before,
      "wet=%r" % (e3.get_f("freeverb.wet")[1],))
# 越界仍按 0..1 钳位（旧配置里的 >1 不应把 wet 推出界）
assert e3.set_f("freeverb.wet", 0.35) == 0
assert e3.set_f("spatial.late", 9.0) == 0
check("late 9.0 clamps to 1.0",
      abs(e3.get_f("spatial.late")[1] - 1.0) < 1e-6 and
      abs(e3.get_f("freeverb.wet")[1] - 1.0) < 1e-6,
      "late=%r wet=%r" % (e3.get_f("spatial.late")[1], e3.get_f("freeverb.wet")[1]))

# ---------------------------------------------------------------------------
# 3. UI/ARB 源码不变式：UI 不再出现旧开关
# ---------------------------------------------------------------------------
print("=== [3] UI/ARB 源码不变式 ===")
lib_dir = os.path.join(ROOT, "app", "auradsp_app", "lib")
arb_files = [
    os.path.join(lib_dir, "l10n", "app_zh.arb"),
    os.path.join(lib_dir, "l10n", "app_en.arb"),
    os.path.join(lib_dir, "l10n", "app_ja.arb"),
]

dart_hits = []
# 生成文件豁免（见文件头范围修正）：APO 参数块 ABI 镜像，必须含
# deprecated 别名以便旧会话经参数块写达迁移别名；其正确性由下方
# Dart↔C 全序相等断言正向守住，不走本 UI token 扫描。
ABI_INDEX_DART = os.path.join(lib_dir, "engine", "apo_param_index.dart")
for root, _dirs, files in os.walk(lib_dir):
    for name in files:
        if not name.endswith(".dart"):
            continue
        path = os.path.join(root, name)
        if os.path.abspath(path) == os.path.abspath(ABI_INDEX_DART):
            continue
        text = open(path, encoding="utf-8", errors="replace").read()
        for token in ("spatialFdn", "spatialLate", "spatial.fdn", "spatial.late"):
            if token in text:
                dart_hits.append("%s: %s" % (os.path.relpath(path, ROOT), token))
check("Dart UI has no spatialFdn/spatialLate identifiers", not dart_hits,
      "; ".join(dart_hits[:8]))

# 正向 ABI 断言：豁免文件的存在理由本身受检——生成横幅在、且 Dart
# 序号表与 C 侧 kApoNumParamIds 全序相等（两别名必然同槽在册）。
import re as _re
dart_idx_text = open(ABI_INDEX_DART, encoding="utf-8").read()
check("apo_param_index.dart is the generated ABI mirror",
      dart_idx_text.startswith("// GENERATED by tools/gen_apo_param_layout.py"))
_m = _re.search(r"kApoNumParamIndex\s*=\s*\{(.*?)\};", dart_idx_text, _re.S)
_pairs = _re.findall(r"'([^']+)':\s*(\d+)", _m.group(1)) if _m else []
dart_ids = [k for k, _v in sorted(_pairs, key=lambda kv: int(kv[1]))]
c_idx_path = os.path.join(
    ROOT, "core", "desktop", "windows-drivers", "03_system_apo",
    "ApoParamIndex.h")
c_idx_text = open(c_idx_path, encoding="utf-8").read()
_mc = _re.search(r"kApoNumParamIds\[[^\]]*\]\s*=\s*\{(.*?)\};", c_idx_text, _re.S)
c_ids = _re.findall(r'"([^"]+)"', _mc.group(1)) if _mc else []
check("APO param index Dart==C full sequence (ABI)",
      bool(dart_ids) and dart_ids == c_ids,
      "dart=%d c=%d" % (len(dart_ids), len(c_ids)))
check("deprecated aliases pinned at same slots both sides",
      "spatial.fdn" in dart_ids and "spatial.late" in dart_ids and
      dart_ids.index("spatial.fdn") == c_ids.index("spatial.fdn") and
      dart_ids.index("spatial.late") == c_ids.index("spatial.late"))

arb_hits = []
for path in arb_files:
    text = open(path, encoding="utf-8", errors="replace").read()
    for token in ('"spatialFdn"', '"spatialFdnInfo"',
                  '"spatialLate"', '"spatialLateInfo"'):
        if token in text:
            arb_hits.append("%s: %s" % (os.path.basename(path), token))
check("zh/en/ja ARB no spatialFdn/spatialLate keys", not arb_hits,
      "; ".join(arb_hits))

reverb_card = os.path.join(lib_dir, "features", "effects", "reverb_card.dart")
audio_isolate = os.path.join(lib_dir, "engine", "audio_isolate.dart")
if os.path.exists(reverb_card):
    card = open(reverb_card, encoding="utf-8").read()
    check("reverb card uses curated preset table", "kReverbCuratedPresets" in card)
    check("reverb card shows engine badge", "reverbEngine" in card)
    check("reverb card no longer claims FL/FR-only", "flfrOnlyHint" not in card)
if os.path.exists(audio_isolate):
    iso = open(audio_isolate, encoding="utf-8").read()
    check("audio isolate no longer reads back spatial fdn/late",
          "spatialFdn" not in iso and "spatialLate" not in iso)

# 引擎仍注册两个 deprecated 写别名（否则旧会话加载直接报错）
e4 = new_engine(8, 1)
check("engine still registers spatial.fdn", e4.get_i("spatial.fdn")[0] == 0)
check("engine still registers spatial.late", e4.get_f("spatial.late")[0] == 0)
check("engine still accepts spatial.fdn write", e4.set_i("spatial.fdn", 0) == 0)
check("engine still accepts spatial.late write", e4.set_f("spatial.late", 0.25) == 0)

for x in (e, e2, e3, e4):
    x.close()

print()
if FAIL:
    print("SPATIAL FDN REMOVED FAILURES:", FAIL)
    sys.exit(1)
print("spatial_fdn_removed: all checks passed")
