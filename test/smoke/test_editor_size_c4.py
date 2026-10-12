#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""test_editor_size_c4.py — C4 回归：编辑器容器与插件子窗口尺寸必须一致、且可随容器拉伸

C4 根因（docs/插件模块深度改良方案-2026-10-12.md §17）：
  EditorHostWindowProc 原先只处理 WM_CLOSE，**完全没有 WM_SIZE**。
  插件子窗口（VST3 由 view->attached 创建、CLAP 由 gui->set_parent 创建）
  一旦创建就固定在其原始尺寸 → 容器放大只多出空白，内容仍被裁剪；
  而部分插件（iZotope RX 系列为代表）在 attached/set_parent 之后才**异步
  布局**出真实尺寸，真实尺寸到达时容器没跟着改 → "一打开只有一点点"。

修复要点（按格式分派，不能统一处理）：
  * VST3 —— 规范要求宿主在 WM_SIZE 时调 view->onSize(newSize)，由插件自己
            改子窗口；容器尺寸由 plugFrame->resizeView 跟随 view->getSize。
  * CLAP —— 规范要求宿主**直接 resize 子窗口**到客户区（ResizeDirectChildren）。
  * 两者都要挂一个尺寸稳定化定时器（100ms × 6 = 600ms），反复取插件自报
    尺寸并同步容器，覆盖异步布局。

断言（每个可用插件）：
  1. slot_load 返回 1
  2. show_editor 返回 1
  3. 本进程内找得到容器窗口
  4. 容器客户区 >= 100x80（pollEditorSize 的合理性下限，插件自报尺寸已同步）
  5. 存在插件子窗口，其客户区尺寸 == 容器客户区尺寸（±2px，DPI 亚像素容差）
  6. 改变容器尺寸后，插件子窗口跟随变化到新的客户区尺寸（±2px）
     —— 这是用户报障"拉大框发现多出来的是空白"的直接断言

插件缺失时判 [SKIP]（smoke 必须在没有这些插件的机器上也能过）。
"""
import ctypes
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DLL = os.environ.get("AURADSP_DLL") or os.path.join(
    ROOT, "core", "desktop", "windows", "out", "Release",
    "auradsp_engine.dll")
if not os.path.exists(DLL):
    DLL = (r"D:\temp_desktop\Proj\JamesDSP\core\desktop\windows\out\Release"
           r"\auradsp_engine.dll")

CPF = os.environ.get("CommonProgramFiles", r"C:\Program Files\Common Files")
VST3_DIR = os.path.join(CPF, "VST3")
CLAP_DIR = os.path.join(CPF, "CLAP")

# 尺寸一致容差（像素）。DPI 缩放可能带来亚像素误差。
TOL = 2
# 覆盖 100ms x 6 次 = 600ms 的尺寸稳定化窗口，留 0.4s 余量
SETTLE_WAIT_S = 1.0
# 目标外框 = 当前外框 x 2，避免固定目标小于插件自报尺寸（KV-Element-FX
# 自报 1230x730，固定 900x600 会变成"缩小"而非"拉大"）
GROW_FACTOR = 2
# 屏幕工作区内留白，防止被系统 clamp 到边界导致"拉大"退化
WORKAREA_PAD = 24

CASES = [
    # (名称, 容器窗口类名, bundle 路径)
    ("iZotope RX 12 De-hum（VST3，C4 主角：异步布局 + 裁剪）",
     "AuraDSP_VST3_Host_Window",
     os.path.join(VST3_DIR, "iZotope", "RX 12 De-hum.vst3")),
    ("iZotope RX 12 De-ess（VST3，RX 系列第二个样本）",
     "AuraDSP_VST3_Host_Window",
     os.path.join(VST3_DIR, "iZotope", "RX 12 De-ess.vst3")),
    ("KV-Element-FX（CLAP，对照组：另一条子窗口 resize 路径）",
     "AuraDSP_CLAP_Host_Window",
     os.path.join(CLAP_DIR, "KV-Element-FX.clap")),
]

fails = []
skips = []


def check(cond, msg):
    print(f"  [{'PASS' if cond else 'FAIL'}] {msg}")
    if not cond:
        fails.append(msg)


def skip(msg):
    print(f"  [SKIP] {msg}")
    skips.append(msg)


# ---------------------------------------------------------------- Win32 绑定
class RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


user32 = ctypes.WinDLL("user32", use_last_error=True)
user32.GetWindowThreadProcessId.argtypes = [ctypes.c_void_p,
                                            ctypes.POINTER(ctypes.c_ulong)]
user32.GetWindowThreadProcessId.restype = ctypes.c_ulong
user32.GetClassNameW.argtypes = [ctypes.c_void_p, ctypes.c_wchar_p, ctypes.c_int]
user32.GetClassNameW.restype = ctypes.c_int
user32.EnumChildWindows.argtypes = [
    ctypes.c_void_p,
    ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_long),
    ctypes.c_long]
user32.FindWindowW.argtypes = [ctypes.c_wchar_p, ctypes.c_wchar_p]
user32.FindWindowW.restype = ctypes.c_void_p
user32.FindWindowExW.argtypes = [ctypes.c_void_p, ctypes.c_void_p,
                                 ctypes.c_wchar_p, ctypes.c_wchar_p]
user32.FindWindowExW.restype = ctypes.c_void_p
user32.GetClientRect.argtypes = [ctypes.c_void_p, ctypes.POINTER(RECT)]
user32.GetClientRect.restype = ctypes.c_bool
user32.GetWindowRect.argtypes = [ctypes.c_void_p, ctypes.POINTER(RECT)]
user32.GetWindowRect.restype = ctypes.c_bool
user32.SystemParametersInfoW.argtypes = [ctypes.c_uint, ctypes.c_uint,
                                         ctypes.c_void_p, ctypes.c_uint]
user32.SystemParametersInfoW.restype = ctypes.c_bool
user32.SetWindowPos.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int,
                                ctypes.c_int, ctypes.c_int, ctypes.c_int,
                                ctypes.c_uint]
user32.SetWindowPos.restype = ctypes.c_bool

SWP_NOACTIVATE = 0x0010


def cls_of(hwnd):
    b = ctypes.create_unicode_buffer(256)
    user32.GetClassNameW(ctypes.c_void_p(hwnd), b, 256)
    return b.value


def client_size(hwnd):
    """返回 (宽, 高) 客户区尺寸；窗口无效返回 (0, 0)。"""
    rc = RECT()
    if not user32.GetClientRect(ctypes.c_void_p(hwnd), ctypes.byref(rc)):
        return 0, 0
    return rc.right - rc.left, rc.bottom - rc.top


def direct_children(hwnd):
    out = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, ctypes.c_void_p, ctypes.c_long)
    def cb(h, lp):
        out.append(h)
        return True

    user32.EnumChildWindows(ctypes.c_void_p(hwnd), cb, 0)
    return out


def largest_child(container):
    """直接子窗口里客户区面积最大的那个 —— 插件 GUI 的主窗口。

    JUCE 系插件（RX / KV）通常会产生多个子窗口（f11_Window / Win32Window /
    JUCE_xxx），尺寸互为镜像；取最大者即可，避免依赖具体类名。
    """
    best, best_area = None, -1
    for c in direct_children(container):
        w, h = client_size(c)
        area = w * h
        if area > best_area:
            best, best_area = c, area
    return best


def find_own_container(container_class, my_pid, timeout_s=2.0):
    """在本进程内找容器窗口。

    FindWindowW 是全桌面搜索，可能撞上用户正开着的 app 实例的同类窗口，
    故按 PID 过滤 + FindWindowExW 链式枚举。
    """
    deadline = time.time() + timeout_s
    while time.time() < deadline:
        cand = user32.FindWindowW(container_class, None)
        while cand:
            pid = ctypes.c_ulong(0)
            user32.GetWindowThreadProcessId(ctypes.c_void_p(cand),
                                            ctypes.byref(pid))
            if pid.value == my_pid:
                return cand
            cand = user32.FindWindowExW(ctypes.c_void_p(0), ctypes.c_void_p(cand),
                                        container_class, None)
        time.sleep(0.1)
    return None


def grow_target_size(hwnd):
    """计算"拉大后的窗口外框尺寸"：当前外框 x2，上限为屏幕工作区。

    不能用固定目标（如 900x600）——KV-Element-FX 自报 1230x730，固定目标
    会让"拉大"退化成"缩小"。也不能无上限翻倍——超出工作区会被系统 clamp，
    实测值与请求值不符。
    """
    wr = RECT()
    user32.GetWindowRect(ctypes.c_void_p(hwnd), ctypes.byref(wr))
    cw = wr.right - wr.left
    ch = wr.bottom - wr.top

    wa = RECT()
    if not user32.SystemParametersInfoW(0x0030, 0, ctypes.byref(wa), 0):
        return cw * GROW_FACTOR, ch * GROW_FACTOR
    avail_w = wa.right - wa.left
    avail_h = wa.bottom - wa.top

    return (min(cw * GROW_FACTOR, max(200, avail_w - WORKAREA_PAD)),
            min(ch * GROW_FACTOR, max(200, avail_h - WORKAREA_PAD)))


# ---------------------------------------------------------------- 引擎绑定
lib = ctypes.CDLL(DLL)
lib.auradsp_create.restype = ctypes.c_void_p
lib.auradsp_create.argtypes = [ctypes.c_float, ctypes.c_int]
lib.auradsp_destroy.argtypes = [ctypes.c_void_p]
lib.auradsp_plugin_slot_load.restype = ctypes.c_int
lib.auradsp_plugin_slot_load.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                         ctypes.c_char_p, ctypes.c_char_p]
lib.auradsp_plugin_slot_show_editor.restype = ctypes.c_int
lib.auradsp_plugin_slot_show_editor.argtypes = [ctypes.c_void_p, ctypes.c_int,
                                                ctypes.c_char_p]
lib.auradsp_plugin_slot_close_editor.restype = ctypes.c_int
lib.auradsp_plugin_slot_close_editor.argtypes = [ctypes.c_void_p, ctypes.c_int]
lib.auradsp_plugin_slot_unload.restype = ctypes.c_int
lib.auradsp_plugin_slot_unload.argtypes = [ctypes.c_void_p, ctypes.c_int]

k32 = ctypes.WinDLL("kernel32", use_last_error=True)
MY_PID = k32.GetCurrentProcessId()

print(f"DLL: {DLL}  ({os.path.getsize(DLL)} bytes)")

h = lib.auradsp_create(48000.0, 1024)
try:
    for name, container_class, path in CASES:
        print(f"\n=== {name} ===")
        if not os.path.exists(path):
            skip(f"{name}: 插件不存在（{path}）")
            continue

        rc = lib.auradsp_plugin_slot_load(h, 0, path.encode("utf-8"), None)
        print(f"  load rc={rc}")
        check(rc == 1, f"{name}: slot_load 返回 1")
        if rc != 1:
            continue

        t0 = time.time()
        rc = lib.auradsp_plugin_slot_show_editor(
            h, 0, f"C4 size test - {name}".encode("utf-8"))
        show_ms = (time.time() - t0) * 1000.0
        print(f"  showEditor rc={rc} ({show_ms:.1f} ms)")
        check(rc == 1, f"{name}: show_editor 返回 1")
        if rc != 1:
            lib.auradsp_plugin_slot_unload(h, 0)
            time.sleep(0.3)
            continue

        time.sleep(SETTLE_WAIT_S)  # 等 600ms 尺寸稳定化窗口结束

        cont = find_own_container(container_class, MY_PID)
        if not cont:
            check(False,
                  f"{name}: 本进程内找不到容器窗口（class={container_class}）")
            lib.auradsp_plugin_slot_close_editor(h, 0)
            time.sleep(0.3)
            lib.auradsp_plugin_slot_unload(h, 0)
            time.sleep(0.3)
            continue

        cw, ch = client_size(cont)
        print(f"  容器 client=({cw}x{ch})")
        check(cw >= 100 and ch >= 80,
              f"{name}: 容器客户区 >= 100x80（插件自报尺寸已同步到容器，"
              f"而非停在创建时的默认尺寸）——实际 {cw}x{ch}")

        child = largest_child(cont)
        if not child:
            check(False, f"{name}: 容器下没有子窗口（插件 GUI 未挂载）")
        else:
            sw, sh = client_size(child)
            print(f"  子窗口 client=({sw}x{sh})  class={cls_of(child)!r}")
            check(abs(sw - cw) <= TOL and abs(sh - ch) <= TOL,
                  f"{name}: 初始尺寸 容器({cw}x{ch}) ≈ 子窗口({sw}x{sh})"
                  f"（±{TOL}px）")

            # 改变容器尺寸 —— 这条路径原先完全没有 WM_SIZE 处理（C4 根因）
            gw, gh = grow_target_size(cont)
            user32.SetWindowPos(ctypes.c_void_p(cont), None, 200, 200,
                                gw, gh, SWP_NOACTIVATE)
            time.sleep(0.4)  # 等 WM_SIZE 经泵线程分发给子窗口

            cw2, ch2 = client_size(cont)
            child = largest_child(cont)
            sw2, sh2 = client_size(child) if child else (0, 0)
            print(f"  [INFO] 请求外框 {gw}x{gh}；实测 容器 client=({cw2}x{ch2})"
                  f"（原 {cw}x{ch}）")
            print(f"  改变后 子窗口 client=({sw2}x{sh2})")
            check((cw2, ch2) != (cw, ch),
                  f"{name}: 容器尺寸已改变（{cw}x{ch} -> {cw2}x{ch2}）")
            check(abs(sw2 - cw2) <= TOL and abs(sh2 - ch2) <= TOL,
                  f"{name}: 改变后 容器({cw2}x{ch2}) ≈ 子窗口({sw2}x{sh2})"
                  f"（±{TOL}px）—— 子窗口跟随容器，不再留空白或仍被裁剪")

        lib.auradsp_plugin_slot_close_editor(h, 0)
        time.sleep(0.3)
        lib.auradsp_plugin_slot_unload(h, 0)
        time.sleep(0.3)
finally:
    lib.auradsp_destroy(h)

print()
if fails:
    print(f"EDITOR SIZE TEST FAILED（{len(fails)} 项失败，{len(skips)} 项跳过）")
    sys.exit(1)
print(f"EDITOR SIZE TEST PASSED（{len(skips)} 项跳过）")
sys.exit(0)
