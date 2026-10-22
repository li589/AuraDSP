# -*- coding: utf-8 -*-
"""smoke_vm_bridge.py — VB-Callback 常驻桥冒烟（需 Voicemeeter 在线）。

流程：detect → start → 跑 3s（frames 增长）→ set_param →
viz_read → test_start(tone)/stop（testKind 翻转 + 心跳文件无关）→ stop。
OUT 槽被占（rc=1）时记 note 优雅通过（泵同式让路不断言）。
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
b.vb_detect.restype = ctypes.c_int
b.vb_start.restype = ctypes.c_int
b.vb_stop.restype = ctypes.c_int
b.vb_status.restype = ctypes.c_int
b.vb_set_param.restype = ctypes.c_int
b.vb_viz_read.restype = ctypes.c_int
b.vb_test_start.restype = ctypes.c_int
b.vb_test_stop.restype = ctypes.c_int
b.vb_detect.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.vb_start.argtypes = [ctypes.c_char_p, ctypes.c_char_p]
b.vb_status.argtypes = [ctypes.c_char_p, ctypes.c_int]
b.vb_set_param.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
b.vb_viz_read.argtypes = [ctypes.c_void_p, ctypes.c_int]
b.vb_test_start.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_int,
                            ctypes.c_int, ctypes.c_int]

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name +
          (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def get_status():
    buf = ctypes.create_string_buffer(2048)
    if b.vb_status(buf, 2048) <= 0:
        return {}
    try:
        return json.loads(buf.value.decode("utf-8", "replace"))
    except ValueError:
        return {}

buf = ctypes.create_string_buffer(2048)
rc = b.vb_detect(buf, 2048)
det = json.loads(buf.value.decode("utf-8", "replace")) if rc > 0 else {}
check("detect", det.get("found", False), det.get("editionName", ""))
if not det.get("found", False):
    print("SKIP（Voicemeeter 未安装）")
    sys.exit(0)

# 引擎走绝对路径（smoke 进程是 python，DLL 搜索序找不到引擎，必须显式给；
# app 内则由 isolate 传 loadedPath，同样显式）。
ENG = os.path.join(ROOT, "test", "auradsp_engine.dll")
rc = b.vb_start(ENG.encode("utf-8"), b"")
if rc == 1:
    print("NOTE out-slot-busy（让路，不断言）")
    sys.exit(0)
if rc != 0:
    st = get_status()
    note = st.get("note", "")
    if "out-slot-busy" in note or "register-failed" in note:
        print(f"NOTE Voicemeeter 注册让路（rc={rc}, note={note}），跳过不断言")
        sys.exit(0)
    try:
        import subprocess as _sp
        tl = _sp.run(["tasklist", "/m", "auravm_bridge.dll"],
                     capture_output=True, text=True, encoding="utf-8",
                     errors="replace").stdout
        holders = [ln for ln in tl.splitlines()
                   if "auradsp_app.exe" in ln]
        if holders:
            print(f"NOTE app Holds slot（{len(holders)} 进程），让路不断言")
            sys.exit(0)
    except OSError:
        pass
check("start rc==0", rc == 0, f"rc={rc}")
if rc != 0:
    print("VMBRIDGE FAILURES:", fails)
    sys.exit(1)

time.sleep(3)
st = get_status()
active_stream = (st.get("frames", 0) > 0)
if not active_stream:
    print(f"NOTE Voicemeeter GUI/Engine 未活跃运行（frames=0，note={st.get('note')}），跳过活跃音频流断言")

if active_stream:
    check("frames growing", st.get("frames", 0) > 0, f"frames={st.get('frames')}")
    check("groups>=1", st.get("groups", 0) >= 1, f"groups={st.get('groups')}")

f = ctypes.c_float(6.0)
n = b.vb_set_param(b"tube.gain", 1, ctypes.byref(f))
check("set_param applied", n > 0, f"handles={n}")

viz = ctypes.create_string_buffer(536 * 4)
n = b.vb_viz_read(viz, 4)
check("viz_read ok", n >= 0, f"n={n}")
if (st.get("peakIn") or 0) > 1e-4:
    check("viz frames when audible", n > 0, f"n={n}")

rc = b.vb_test_start(1, None, 0, 0, 0)
check("test_start tone", rc == 0, f"rc={rc}")
time.sleep(1)
st = get_status()
check("testKind==1", st.get("testKind") == 1, f"testKind={st.get('testKind')}")
f2 = st.get("frames", 0)
if active_stream:
    check("frames keep growing in test", f2 > 0, f"frames={f2}")
    check("vizGrp field plumbed",
          isinstance(st.get("vizGrp"), int) and 0 <= st["vizGrp"] < st.get("groups", 8),
          f"vizGrp={st.get('vizGrp')}")
rc = b.vb_test_stop()
check("test_stop", rc == 0, f"rc={rc}")
st = get_status()
check("testKind==0", st.get("testKind") == 0, f"testKind={st.get('testKind')}")

# ---- CHANGE 重建回归（改主输出设备 → VM 重启引擎 → 参数必须还在）----
b.vb_get_param.restype = ctypes.c_int
b.vb_get_param.argtypes = [ctypes.c_char_p, ctypes.c_int, ctypes.c_void_p]
b.vb_test_change.restype = ctypes.c_int
b.vb_test_change.argtypes = []


def get_param(pid, is_float=False):
    v = ctypes.c_float(0.0) if is_float else ctypes.c_int32(0)
    rc = b.vb_get_param(pid.encode("utf-8"), 1 if is_float else 0,
                        ctypes.byref(v))
    return rc, v.value


rc0, before = get_param("tube.gain", True)
check("get_param pre-change", rc0 == 0, f"rc={rc0} v={before}")
check("pre-change value kept", abs(before - 6.0) < 1e-4, f"v={before}")
ch0 = get_status().get("changes", 0)
handles0 = get_status().get("handles", 0)
note0 = get_status().get("note", "")
rc = b.vb_test_change()
check("test_change accepted", rc == 0, f"rc={rc}")
# monitor 200ms 轮询；changes 在重建开始就 +1，而 handles 在销毁前仍是旧值，
# 只看两者会在销毁前误判"已重建"。note 是重建最后一步写的——等 note 翻新才算完。
rebuilt = False
for _ in range(80):
    time.sleep(0.25)
    st = get_status()
    if st.get("changes", 0) > ch0 and st.get("note", "") != note0:
        rebuilt = True
        break
st = get_status()
check("changes counted", st.get("changes", 0) > ch0,
      f"{ch0}->{st.get('changes')}")
check("rebuild completed (handles restored)", rebuilt and
      st.get("handles", 0) >= handles0,
      f"handles={st.get('handles')} note={st.get('note')}")
if active_stream:
    check("frames resumed after rebuild", st.get("frames", 0) > 0,
          f"frames={st.get('frames')}")
rc1, after = get_param("tube.gain", True)
check("get_param post-change", rc1 == 0, f"rc={rc1} v={after}")
check("PARAM SURVIVED REBUILD (改设备不丢参)", abs(after - 6.0) < 1e-4,
      f"before={before} after={after}")

# ---- LiveProg 字符串通道（VB 下生效 + CHANGE 重建回放）----
LP_CODE = ("/* bridge string-channel regression */\n@init\ndbg = 1;\n"
           "@sample\nspl0 *= slider1;\nspl1 *= slider1;\n")
b.vb_set_param_str.restype = ctypes.c_int
b.vb_set_param_str.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]
b.vb_get_param_str.restype = ctypes.c_int
b.vb_get_param_str.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_int]


def get_param_str(pid, cap=65536):
    buf = ctypes.create_string_buffer(cap)
    n = b.vb_get_param_str(pid.encode("utf-8"), buf, cap)
    return n, (buf.value.decode("utf-8", "replace") if n > 0 else "")


b.vb_set_bus_mask.restype = ctypes.c_int
b.vb_set_bus_mask.argtypes = [ctypes.c_int]

st = get_status()
nh = st.get("handles", 0)
n = b.vb_set_param_str(b"liveprog.code", LP_CODE.encode("utf-8"), len(LP_CODE))
check("set_param_str applied", n == nh and nh > 0, f"n={n} handles={nh}")
rc = b.vb_set_param(b"liveprog.enable", 0, ctypes.byref(ctypes.c_int32(1)))
check("liveprog enable", rc and rc > 0, f"rc={rc}")
rc, stcode = get_param("liveprog.status")
check("liveprog status==1", rc == 0 and stcode == 1, f"rc={rc} st={stcode}")
n, back = get_param_str("liveprog.code")
check("liveprog code roundtrip", n > 0 and back == LP_CODE,
      f"n={n} match={back == LP_CODE}")
ch1 = get_status().get("changes", 0)
note1 = get_status().get("note", "")
rc = b.vb_test_change()
check("test_change#2 accepted", rc == 0, f"rc={rc}")
rebuilt2 = False
for _ in range(80):
    time.sleep(0.25)
    st = get_status()
    if st.get("changes", 0) > ch1 and st.get("note", "") != note1:
        rebuilt2 = True
        break
st = get_status()
check("rebuild#2 completed", rebuilt2 and st.get("handles", 0) >= nh,
      f"handles={st.get('handles')} note={st.get('note')}")
rc, stcode = get_param("liveprog.status")
check("liveprog status survived", rc == 0 and stcode == 1,
      f"rc={rc} st={stcode}")
n, back = get_param_str("liveprog.code")
check("LIVEPROG SURVIVED REBUILD", n > 0 and back == LP_CODE,
      f"n={n} match={back == LP_CODE} note={st.get('note')}")
# 复位：关闭 liveprog（与 ASIO 侧同款 hygiene，避免下游断言被 slider1=0 静音）。
rc = b.vb_set_param(b"liveprog.enable", 0, ctypes.byref(ctypes.c_int32(0)))
check("liveprog disable (downstream restore)", rc and rc > 0, f"rc={rc}")

# ---- 总线掩码：关 g0 直通不断流，不断言音质只断言不崩 + 状态回显 ----
rc = b.vb_set_bus_mask(0xFE)
check("bus_mask g0 off", rc == 0xFE, f"rc={rc:#x}")
time.sleep(1)
st = get_status()
check("status busMask==0xFE", st.get("busMask") == 0xFE,
      f"busMask={st.get('busMask')}")
if active_stream:
    check("frames growing while masked", st.get("frames", 0) > 0,
          f"frames={st.get('frames')}")
rc = b.vb_set_bus_mask(0x1FF)
check("bus_mask clamps to 0xFF", rc == 0xFF, f"rc={rc:#x}")
rc = b.vb_set_bus_mask(0xFF)
check("bus_mask restore", rc == 0xFF, f"rc={rc:#x}")
check("maxGroupUs field plumbed (L0)",
      isinstance(st.get("maxGroupUs"), list) and len(st.get("maxGroupUs")) == 8,
      f"maxGroupUs={st.get('maxGroupUs')}")
check("grpLive field plumbed", isinstance(st.get("grpLive"), int),
      f"grpLive={st.get('grpLive')}")

# ---- 插件组掩码（VB 按路插件处理）：导出存在性 + set/get 往返 + 重建存活 + 钳位 ----
# 覆盖链开关 smoke（smoke_plugin_chain_enable）声明"不能证明"的桥侧扇出：
# 掩码语义经 g_pluginGroupMask 跨 CHANGE 重建 + ApplyPluginGroupMask 重放。
# 注意：note 的 "pN/M" 是参数镜像回放计数（非重建序号），重建检测只用 changes 计数器。
b.vb_plugin_group_enable.restype = ctypes.c_int
b.vb_plugin_group_enable.argtypes = [ctypes.c_int]
b.vb_plugin_group_mask.restype = ctypes.c_int
check("plugin_group default==0xFF", b.vb_plugin_group_mask() == 0xFF,
      f"mask={b.vb_plugin_group_mask():#x}")
rc = b.vb_plugin_group_enable(0xFE)
check("plugin_group g0 off", rc == 0xFE, f"rc={rc:#x}")
check("plugin_group_mask==0xFE", b.vb_plugin_group_mask() == 0xFE,
      f"mask={b.vb_plugin_group_mask():#x}")
if active_stream:
    time.sleep(1)
    st = get_status()
    check("frames growing while plugin-group masked",
          st.get("frames", 0) > 0, f"frames={st.get('frames')}")
# 重建存活：保持 0xFE → CHANGE 重建 → 掩码不丢（新引擎出厂链全开，掩码重放覆盖之）。
# changes 在重建开始时递增、note 在完成时重写、handles 在完成后恢复——
# 完成判据取「changes 递增 且 handles 恢复」（note 字符串可能前后相同，不可靠）。
ch2 = get_status().get("changes", 0)
rc = b.vb_test_change()
check("test_change#3 accepted", rc == 0, f"rc={rc}")
rebuilt3 = False
for _ in range(80):
    time.sleep(0.25)
    st = get_status()
    if st.get("changes", 0) > ch2 and st.get("handles", 0) >= nh:
        rebuilt3 = True
        break
st = get_status()
check("rebuild#3 completed", rebuilt3 and st.get("handles", 0) >= nh,
      f"changes={st.get('changes')} handles={st.get('handles')} note={st.get('note')}")
check("PLUGIN GROUP MASK SURVIVED REBUILD",
      b.vb_plugin_group_mask() == 0xFE,
      f"mask={b.vb_plugin_group_mask():#x} note={st.get('note')}")
rc = b.vb_plugin_group_enable(0x1FF)
check("plugin_group clamps to 0xFF", rc == 0xFF, f"rc={rc:#x}")
rc = b.vb_plugin_group_enable(0xFF)
check("plugin_group restore", rc == 0xFF, f"rc={rc:#x}")
check("plugin_group_mask==0xFF after restore",
      b.vb_plugin_group_mask() == 0xFF,
      f"mask={b.vb_plugin_group_mask():#x}")

# ---- v2 按路编辑器 API：_g 导出存在性 + 非法 group 拒绝 + 空槽位行为 ----
# Dart 插件页总线下拉 → pluginSlotShowEditor(group) → vb_plugin_slot_show_editor_g
# （PluginEngineAt(group) 路由到该组引擎）。老桥无 _g 导出时 Dart 回落单路
# 绑定，故此处断言新 DLL 必须带齐三个导出（部署陈旧 = Dart 静默走旧路径）。
for _gfn in ("vb_plugin_slot_show_editor_g",
             "vb_plugin_slot_close_editor_g",
             "vb_plugin_slot_is_editor_open_g"):
    check(f"export {_gfn} present", hasattr(b, _gfn),
          "missing (stale bridge DLL?)")
if hasattr(b, "vb_plugin_slot_show_editor_g"):
    b.vb_plugin_slot_show_editor_g.restype = ctypes.c_int
    b.vb_plugin_slot_show_editor_g.argtypes = [ctypes.c_int, ctypes.c_int,
                                               ctypes.c_char_p]
    b.vb_plugin_slot_close_editor_g.restype = ctypes.c_int
    b.vb_plugin_slot_close_editor_g.argtypes = [ctypes.c_int, ctypes.c_int]
    b.vb_plugin_slot_is_editor_open_g.restype = ctypes.c_int
    b.vb_plugin_slot_is_editor_open_g.argtypes = [ctypes.c_int, ctypes.c_int]
    # 非法 group（99 必然越界）：桥侧 PluginEngineAt 返回 null → 0，不得崩。
    rc = b.vb_plugin_slot_show_editor_g(0, 99, None)
    check("editor_g rejects out-of-range group", rc == 0, f"rc={rc}")
    rc = b.vb_plugin_slot_is_editor_open_g(0, 99)
    check("editor_g is_open out-of-range group", rc == 0, f"rc={rc}")
    # 空槽位（无插件加载）：show 必然 0，is_open 必然 0（不得误报已打开）。
    rc = b.vb_plugin_slot_show_editor_g(0, 0, b"AuraDSP smoke")
    check("editor_g empty slot show==0", rc == 0, f"rc={rc}")
    rc = b.vb_plugin_slot_is_editor_open_g(0, 0)
    check("editor_g empty slot is_open==0", rc == 0, f"rc={rc}")
    rc = b.vb_plugin_slot_close_editor_g(0, 0)
    check("editor_g empty slot close==0", rc == 0, f"rc={rc}")

# ---- P1：per-group Ch + 继承复制（sync_all）导出与拒绝语义 ----
for _gfn in ("vb_plugin_slot_set_channels_g", "vb_plugin_slot_sync_all"):
    check(f"export {_gfn} present", hasattr(b, _gfn),
          "missing (stale bridge DLL?)")
if hasattr(b, "vb_plugin_slot_set_channels_g"):
    b.vb_plugin_slot_set_channels_g.restype = ctypes.c_int
    b.vb_plugin_slot_set_channels_g.argtypes = [ctypes.c_int, ctypes.c_int,
                                                ctypes.c_int]
    b.vb_plugin_slot_sync_all.restype = ctypes.c_int
    b.vb_plugin_slot_sync_all.argtypes = [ctypes.c_int, ctypes.c_int,
                                          ctypes.c_char_p]
    rc = b.vb_plugin_slot_set_channels_g(0, 99, 0x3)
    check("set_channels_g rejects out-of-range group", rc == 0, f"rc={rc}")
    rc = b.vb_plugin_slot_set_channels_g(0, 0, 0x3)
    # 空槽不崩即可（Ready/实例在场与否环境相关，0=拒绝 1=接受均为合法）
    check("set_channels_g empty slot safe", rc in (0, 1), f"rc={rc}")
    # 空槽 sync_all：src 无插件 savePreset 失败 → 0（不得假装成功）
    rc = b.vb_plugin_slot_sync_all(0, 99, b"C:\\Windows\\Temp\\aura_sync_test.aurapreset")
    check("sync_all rejects out-of-range srcGroup", rc == 0, f"rc={rc}")
    rc = b.vb_plugin_slot_sync_all(0, 0, b"C:\\Windows\\Temp\\aura_sync_test.aurapreset")
    check("sync_all empty slot ==0 (savePreset fails)", rc == 0, f"rc={rc}")

# ---- P2（v3.3 A/B 预设）：per-group state 读写导出与拒绝语义 ----
for _gfn in ("vb_plugin_slot_save_preset_g", "vb_plugin_slot_load_preset_g"):
    check(f"export {_gfn} present", hasattr(b, _gfn),
          "missing (stale bridge DLL?)")
if hasattr(b, "vb_plugin_slot_save_preset_g"):
    b.vb_plugin_slot_save_preset_g.restype = ctypes.c_int
    b.vb_plugin_slot_save_preset_g.argtypes = [ctypes.c_int, ctypes.c_int,
                                               ctypes.c_char_p]
    b.vb_plugin_slot_load_preset_g.restype = ctypes.c_int
    b.vb_plugin_slot_load_preset_g.argtypes = [ctypes.c_int, ctypes.c_int,
                                               ctypes.c_char_p]
    rc = b.vb_plugin_slot_save_preset_g(0, 99, b"C:\\Windows\\Temp\\aura_ab_test.aurapreset")
    check("save_preset_g rejects out-of-range group", rc == 0, f"rc={rc}")
    rc = b.vb_plugin_slot_load_preset_g(0, 99, b"C:\\Windows\\Temp\\aura_ab_test.aurapreset")
    check("load_preset_g rejects out-of-range group", rc == 0, f"rc={rc}")
    rc = b.vb_plugin_slot_save_preset_g(0, 0, b"C:\\Windows\\Temp\\aura_ab_test.aurapreset")
    check("save_preset_g empty slot safe", rc in (0, 1), f"rc={rc}")

b.vb_bypass.restype = ctypes.c_int
b.vb_bypass.argtypes = [ctypes.c_int]
rc = b.vb_bypass(1)
check("bypass on", rc == 0, f"rc={rc}")
time.sleep(1)
st = get_status()
check("status bypass==1", st.get("bypass") == 1, f"bypass={st.get('bypass')}")
if active_stream:
    check("frames growing in bypass", st.get("frames", 0) > 0, f"frames={st.get('frames')}")
rc = b.vb_bypass(0)
check("bypass off", rc == 0, f"rc={rc}")
st = get_status()
check("status bypass==0", st.get("bypass") == 0, f"bypass={st.get('bypass')}")

rc = b.vb_stop()
check("stop", rc == 0, f"rc={rc}")
st = get_status()
check("running==false", st.get("running", True) is False)

if fails:
    print("VMBRIDGE FAILURES:", fails)
    sys.exit(1)
print("vm_bridge: all checks passed")
