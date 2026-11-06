#!/usr/bin/env python3
"""AuraDSP Windows 性能回归：启动空载 / 可视化静默 / 播放态 / 最小化。

只做观测与对照，不是音频正确性测试。四个场景的内存/CPU/GPU 采集口径与
2026-11-06 的性能基线一致：1400x900 客户区、bars、歌词关闭、无插件、
sysapo（非 VB）或 voicemeeter_api（VB attach）。

用法（在仓库根目录执行，路径全部由本文件推导，无硬编码绝对路径）：
    python tools/perf_regression.py                       # 四场景，sysapo
    python tools/perf_regression.py --mode vb             # 四场景，VB
    python tools/perf_regression.py --scenario play       # 只测播放态
    python tools/perf_regression.py --seconds 20 --strict # 自定义时长并判红

产物（默认 <repo>/.tmp/perf-regression/<时间戳>/，.tmp 已被 gitignore）：
    summary.json          全部场景 + 阈值 + 与参考值差值
    stages.csv            一行一场景，可直接对比历史
    proc_<scene>.json     逐秒原始样本（与 measure.py 同 schema）
    gpu_<scene>.csv       GPU 计数器原始样本
    stage_<scene>.png     场景截图（确认点击落点，--no-shot 可关）
    run.log               应用 stdout/stderr

注意：
  * 需要真实的桌面会话（会移动鼠标、最小化窗口），不能无人值守跑在 CI；
    因此放在 tools/ 而不是 test/smoke 常驻门禁。test/runner.py --perf 只是编排入口。
  * 运行前会结束已存在的 auradsp_app.exe，并备份/恢复
    %APPDATA%\\AuraDSP\\{config,session_state}.json；异常退出也会在 finally 恢复。
  * 阈值是“本机参考值 ~1.3-1.5 倍”的软门禁；未加 --strict 时只打印 WARN。
"""

from __future__ import annotations

import argparse
import csv
import ctypes
import json
import os
import shutil
import subprocess
import sys
import time
from datetime import datetime
from pathlib import Path
from ctypes import wintypes

import psutil

ROOT = Path(__file__).resolve().parents[2]
BUILD_DIR = ROOT / "app" / "auradsp_app" / "build" / "windows" / "x64" / "runner" / "Release"
APP_EXE = BUILD_DIR / "auradsp_app.exe"
GPU_PS1 = Path(__file__).resolve().parent / "gpu_sampler.ps1"
CONFIG_DIR = Path(os.environ.get("APPDATA", str(Path.home() / "AppData" / "Roaming"))) / "AuraDSP"

CLIENT_W, CLIENT_H = 1400, 900
SCENARIOS = ("startup", "viz", "play", "minimized")
LABELS = {
    "startup": "启动空载",
    "viz": "可视化静默",
    "play": "播放态",
    "minimized": "最小化",
}

# 1400x900 客户区下的固定落点（与基线测量脚本同一套，勿盲改）。
HOME_NAV = (108, 196)
VIZ_NAV = (108, 530)
SETTINGS_GEAR = (1350, 85)
SETTINGS_TEST_TAB = (1095, 832)
PINK_NOISE = (623, 369)
CLICK_OUTSIDE = (60, 200)

# 最终态参考值（2026-11-06 release 实测两次回归，15s/场景，trim 20%；
# 用于打印 Δ，不参与判定）。minimized 取两次回归中的较新口径（非 VB
# 329.8 / VB 510.6），与 P0-4 插桩构建的历史读数（480.6/486.1）不可混用。
REFERENCE = {
    ("sysapo", "startup"): {"rss_avg_mb": 273.5, "cpu_avg_pct_core": 0.5, "gpu_3d_avg": 0.0},
    ("sysapo", "viz"): {"rss_avg_mb": 332.4, "cpu_avg_pct_core": 0.8, "gpu_3d_avg": 0.0},
    ("sysapo", "play"): {"rss_avg_mb": 372.4, "cpu_avg_pct_core": 38.0, "gpu_3d_avg": 14.5},
    ("sysapo", "minimized"): {"rss_avg_mb": 329.8, "cpu_avg_pct_core": 1.9, "gpu_3d_avg": 0.0},
    ("vb", "startup"): {"rss_avg_mb": 455.6, "cpu_avg_pct_core": 169.1, "gpu_3d_avg": 36.9},
    ("vb", "viz"): {"rss_avg_mb": 470.0, "cpu_avg_pct_core": 29.6, "gpu_3d_avg": 7.9},
    ("vb", "play"): {"rss_avg_mb": 558.1, "cpu_avg_pct_core": 52.0, "gpu_3d_avg": 17.8},
    ("vb", "minimized"): {"rss_avg_mb": 510.6, "cpu_avg_pct_core": 5.2, "gpu_3d_avg": 0.0},
}

# 软门禁：RSS 均值 / CPU 单核百分比均值 / GPU 3D 均值。取参考值约 1.2-1.3 倍，
# 只拦“数量级回归”，不拦正常测量漂移（同一台机器不同时段 RSS 会差 10-20MB）。
# VB 的 CPU 由 8 路引擎泵送 + 主页 viz 事件驱动重绘主导，阈值刻意放宽；
# 它只用于“别把引擎改造搞崩”，不是 UI 指标。
THRESHOLDS = {
    ("sysapo", "startup"): {"rss_avg_mb": 330, "cpu_avg_pct_core": 20, "gpu_3d_avg": 5},
    ("sysapo", "viz"): {"rss_avg_mb": 400, "cpu_avg_pct_core": 10, "gpu_3d_avg": 5},
    ("sysapo", "play"): {"rss_avg_mb": 480, "cpu_avg_pct_core": 70, "gpu_3d_avg": 25},
    ("sysapo", "minimized"): {"rss_avg_mb": 430, "cpu_avg_pct_core": 8, "gpu_3d_avg": 5},
    ("vb", "startup"): {"rss_avg_mb": 560, "cpu_avg_pct_core": 240, "gpu_3d_avg": 50},
    ("vb", "viz"): {"rss_avg_mb": 570, "cpu_avg_pct_core": 120, "gpu_3d_avg": 15},
    ("vb", "play"): {"rss_avg_mb": 680, "cpu_avg_pct_core": 120, "gpu_3d_avg": 30},
    ("vb", "minimized"): {"rss_avg_mb": 620, "cpu_avg_pct_core": 15, "gpu_3d_avg": 5},
}

_user32 = ctypes.WinDLL("user32", use_last_error=True) if sys.platform == "win32" else None
if _user32 is not None:
    try:  # 与 ui.py 一致：per-monitor DPI aware，否则物理/逻辑坐标会错位
        ctypes.windll.shcore.SetProcessDpiAwareness(2)
    except Exception:
        pass


class RECT(ctypes.Structure):
    _fields_ = [("left", ctypes.c_long), ("top", ctypes.c_long),
                ("right", ctypes.c_long), ("bottom", ctypes.c_long)]


class POINT(ctypes.Structure):
    _fields_ = [("x", ctypes.c_long), ("y", ctypes.c_long)]


if _user32 is not None:
    WNDENUMPROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
    _user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(RECT)]
    _user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(RECT)]
    _user32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(POINT)]
    _user32.GetWindowTextW.argtypes = [wintypes.HWND, wintypes.LPWSTR, ctypes.c_int]
    _user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int,
                                     ctypes.c_int, ctypes.c_int, ctypes.c_uint]
    _user32.EnumWindows.argtypes = [WNDENUMPROC, wintypes.LPARAM]
    _user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]

SWP_NOMOVE, SWP_NOZORDER, SWP_NOACTIVATE = 0x0002, 0x0004, 0x0010
SW_MINIMIZE, SW_RESTORE = 6, 9
MOUSEEVENTF_LEFTDOWN, MOUSEEVENTF_LEFTUP = 0x0002, 0x0004


def log(msg: str) -> None:
    print(msg, flush=True)


def kill_app() -> None:
    subprocess.run(["taskkill", "/F", "/IM", "auradsp_app.exe"],
                   capture_output=True, text=True)
    time.sleep(1.0)


def find_window(pid: int) -> int | None:
    found: list[tuple[int, str]] = []

    def _cb(hwnd, _lparam):
        wpid = wintypes.DWORD()
        _user32.GetWindowThreadProcessId(hwnd, ctypes.byref(wpid))
        if wpid.value == pid and _user32.IsWindowVisible(hwnd):
            n = _user32.GetWindowTextLengthW(hwnd)
            if n:
                buf = ctypes.create_unicode_buffer(n + 1)
                _user32.GetWindowTextW(hwnd, buf, n + 1)
                found.append((hwnd, buf.value))
        return True

    _user32.EnumWindows(WNDENUMPROC(_cb), 0)
    for hwnd, title in found:
        if "auradsp" in title.lower():
            return hwnd
    return found[0][0] if found else None


def window_rect(hwnd: int) -> tuple[int, int, int, int]:
    wr = RECT()
    _user32.GetWindowRect(hwnd, ctypes.byref(wr))
    return wr.left, wr.top, wr.right, wr.bottom


def window_size(hwnd: int) -> tuple[int, int]:
    left, top, right, bottom = window_rect(hwnd)
    return right - left, bottom - top


def foreground(hwnd: int) -> None:
    """前台锁定绕过（AttachThreadInput），保证落点落在 AuraDSP 而不是终端。"""
    kernel32 = ctypes.windll.kernel32
    _user32.ShowWindow(hwnd, SW_RESTORE)
    fg = _user32.GetForegroundWindow()
    fg_tid = _user32.GetWindowThreadProcessId(fg, None)
    cur_tid = kernel32.GetCurrentThreadId()
    if fg_tid and fg_tid != cur_tid:
        _user32.AttachThreadInput(cur_tid, fg_tid, True)
    _user32.BringWindowToTop(hwnd)
    _user32.SetForegroundWindow(hwnd)
    _user32.SetFocus(hwnd)
    if fg_tid and fg_tid != cur_tid:
        _user32.AttachThreadInput(cur_tid, fg_tid, False)
    time.sleep(0.2)


def resize_window(hwnd: int, width: int, height: int, x: int = 40, y: int = 30) -> None:
    """与基线 ui.py 同口径：外层窗口 1400×900（不是客户区）。"""
    foreground(hwnd)
    _user32.SetWindowPos(hwnd, 0, x, y, width, height, SWP_NOZORDER | SWP_NOACTIVATE)
    time.sleep(0.4)
    foreground(hwnd)


def ensure_window_size(hwnd: int, width: int, height: int, tries: int = 4) -> bool:
    """窗口会从 session_state 恢复上次尺寸；必须在启动稳定后再改并复核。"""
    if _user32.IsZoomed(hwnd):
        _user32.ShowWindow(hwnd, SW_RESTORE)
        time.sleep(0.5)
    for _ in range(tries):
        resize_window(hwnd, width, height)
        time.sleep(1.0)
        if window_size(hwnd) == (width, height):
            return True
    log(f"[warn] 窗口未达到 {width}x{height}，实际 {window_size(hwnd)}")
    return False


def click(hwnd: int, xy: tuple[int, int]) -> None:
    """落点相对窗口左上角（与基线 ui.py 的 rect + 坐标同义）。"""
    x, y = xy
    foreground(hwnd)
    left, top, _, _ = window_rect(hwnd)
    _user32.SetCursorPos(left + x, top + y)
    time.sleep(0.06)
    _user32.mouse_event(MOUSEEVENTF_LEFTDOWN, 0, 0, 0, 0)
    time.sleep(0.04)
    _user32.mouse_event(MOUSEEVENTF_LEFTUP, 0, 0, 0, 0)
    time.sleep(0.2)


def set_minimized(hwnd: int, minimized: bool) -> None:
    _user32.ShowWindow(hwnd, SW_MINIMIZE if minimized else SW_RESTORE)
    if not minimized:
        _user32.SetForegroundWindow(hwnd)


def screenshot(hwnd: int, path: Path) -> None:
    try:
        from PIL import ImageGrab
        wr = RECT()
        _user32.GetWindowRect(hwnd, ctypes.byref(wr))
        ImageGrab.grab(bbox=(wr.left, wr.top, wr.right, wr.bottom)).save(path)
    except Exception as exc:  # 截图失败不影响测量
        log(f"[warn] screenshot {path.name}: {exc}")


def _walk_dicts(node):
    if isinstance(node, dict):
        yield node
        for value in node.values():
            yield from _walk_dicts(value)
    elif isinstance(node, list):
        for value in node:
            yield from _walk_dicts(value)


def patch_config(mode: str) -> dict[Path, bytes]:
    """备份并改写音频模式/可视化口径，返回原文件字节用于恢复。"""
    backups: dict[Path, bytes] = {}
    attach = mode == "voicemeeter_api"
    for name in ("config.json", "session_state.json"):
        path = CONFIG_DIR / name
        if not path.exists():
            continue
        backups[path] = path.read_bytes()
        data = json.loads(path.read_text(encoding="utf-8"))
        for d in _walk_dicts(data):
            if "audioMode" in d:
                d["audioMode"] = mode
            if "modeCategory" in d:
                d["modeCategory"] = "attach" if attach else "pipeline"
            if "attachmentMode" in d:
                d["attachmentMode"] = mode
            # 只改可视化配置字典：带 barCount 的 style 才是视效样式，
            # 避免误伤 UI 主题里的同名键。
            if "style" in d and "barCount" in d:
                d["style"] = "bars"
            if "showLyrics" in d:
                d["showLyrics"] = False
            if "showGrid" in d:
                d["showGrid"] = True
        path.write_text(json.dumps(data, ensure_ascii=False, indent=2), encoding="utf-8")
    return backups


def restore_config(backups: dict[Path, bytes]) -> None:
    for path, raw in backups.items():
        path.write_bytes(raw)
        bak = Path(str(path) + ".perfreg")
        if bak.exists():
            bak.unlink()


def start_app(log_path: Path) -> tuple[subprocess.Popen, object]:
    log_file = open(log_path, "w", encoding="utf-8")
    proc = subprocess.Popen([str(APP_EXE)], cwd=str(BUILD_DIR),
                            stdout=log_file, stderr=subprocess.STDOUT)
    return proc, log_file


def wait_window(pid: int, timeout: float = 90.0) -> int:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        hwnd = find_window(pid)
        if hwnd:
            return hwnd
        time.sleep(0.5)
    raise RuntimeError("AuraDSP 窗口在 90s 内未出现（检查 build 产物或启动日志）")


def summarize_gpu(path: Path) -> dict:
    if not path.exists() or path.stat().st_size < 20:
        return {}
    rows = []
    with path.open("r", encoding="utf-8-sig", newline="") as fh:
        reader = csv.DictReader(fh, delimiter="\t")
        for row in reader:
            try:
                rows.append({k: float(v) for k, v in row.items() if k and v not in (None, "")})
            except ValueError:
                continue
    if not rows:
        return {}
    g3 = [r.get("gpu_3d", 0.0) for r in rows]
    gt = [r.get("gpu_total", 0.0) for r in rows]
    sh = [r.get("shared", 0.0) for r in rows]
    de = [r.get("dedicated", 0.0) for r in rows]
    return {
        "n": len(rows),
        "gpu_total_avg": round(sum(gt) / len(gt), 2),
        "gpu_3d_avg": round(sum(g3) / len(g3), 2),
        "gpu_3d_max": round(max(g3), 2),
        "dedicated_avg_mb": round(sum(de) / len(de) / 1048576, 1),
        "shared_avg_mb": round(sum(sh) / len(sh) / 1048576, 1),
    }


def sample_stage(app: subprocess.Popen, label: str, seconds: float, outdir: Path,
                 shots: bool, hwnd: int) -> dict:
    proc = psutil.Process(app.pid)  # Popen 本身没有 cpu_percent，采样用 psutil
    gpu_csv = outdir / f"gpu_{label}.csv"
    gpu_proc = subprocess.Popen(
        ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File",
         str(GPU_PS1), "-TargetPid", str(app.pid), "-OutFile", str(gpu_csv)],
        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(1.5)  # 让 Get-Counter 先完成首轮

    if shots:
        screenshot(hwnd, outdir / f"stage_{label}.png")

    rows = []
    proc.cpu_percent(None)  # 重置基准
    t0 = time.monotonic()
    while time.monotonic() - t0 < seconds:
        time.sleep(1.0)
        try:
            mi = proc.memory_info()
            cpu = proc.cpu_percent(None)
            threads = proc.num_threads()
        except psutil.NoSuchProcess:
            break
        rows.append({
            "t": round(time.monotonic() - t0, 2),
            "rss_mb": round(mi.rss / 1048576, 2),
            "private_mb": round(mi.private / 1048576, 2),
            "cpu_pct_core": round(cpu, 2),
            "threads": threads,
        })

    gpu_proc.terminate()
    try:
        gpu_proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        gpu_proc.kill()

    # 去掉前 20% 的稳定段（与基线 measure.py 同口径）。
    trim = max(1, int(len(rows) * 0.2)) if len(rows) >= 5 else 0
    use = rows[trim:] or rows
    summary = {
        "rss_avg_mb": round(sum(r["rss_mb"] for r in use) / len(use), 2),
        "rss_max_mb": round(max(r["rss_mb"] for r in use), 2),
        "private_avg_mb": round(sum(r["private_mb"] for r in use) / len(use), 2),
        "private_max_mb": round(max(r["private_mb"] for r in use), 2),
        "cpu_avg_pct_core": round(sum(r["cpu_pct_core"] for r in use) / len(use), 2),
        "cpu_max_pct_core": round(max(r["cpu_pct_core"] for r in use), 2),
        "cpu_cores": psutil.cpu_count(logical=True),
        "threads_avg": round(sum(r["threads"] for r in use) / len(use), 1),
        "samples": len(rows),
        "trimmed": trim,
    }
    gpu = summarize_gpu(gpu_csv)
    payload = {
        "label": label,
        "started_at": datetime.now().isoformat(timespec="seconds"),
        "seconds": seconds,
        "summary": summary,
        "gpu": gpu,
        "rows": rows,
    }
    (outdir / f"proc_{label}.json").write_text(
        json.dumps(payload, ensure_ascii=False, indent=2), encoding="utf-8")
    return payload


def gate_result(mode: str, label: str, summary: dict, gpu: dict) -> tuple[bool, list[str]]:
    limits = THRESHOLDS[(mode, label)]
    notes = []
    ok = True
    for key, limit in limits.items():
        value = gpu.get(key) if key in gpu else summary.get(key)
        if value is None:
            notes.append(f"{key}=n/a")
            continue
        if value > limit:
            ok = False
            notes.append(f"{key}={value} > {limit}")
    return ok, notes


def run(args) -> int:
    if sys.platform != "win32":
        log("仅支持 Windows（需要真实桌面会话）。")
        return 2
    if not APP_EXE.exists():
        log(f"找不到 release 产物：{APP_EXE}\n"
            f"先执行：flutter build windows --release --no-tree-shake-icons")
        return 2

    stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    outdir = Path(args.outdir) if args.outdir else ROOT / ".tmp" / "perf-regression" / stamp
    outdir.mkdir(parents=True, exist_ok=True)

    if args.build:
        log("[build] flutter build windows --release --no-tree-shake-icons")
        subprocess.run(["flutter", "build", "windows", "--release", "--no-tree-shake-icons"],
                       cwd=str(ROOT / "app" / "auradsp_app"), check=True)

    targets = SCENARIOS if args.scenario == "all" else (args.scenario,)
    mode = args.mode
    mode_key = "vb" if mode == "voicemeeter_api" else "sysapo"
    settle = args.settle

    log(f"[env] exe={APP_EXE}")
    log(f"[env] app.so={BUILD_DIR / 'data' / 'app.so'}  "
        f"mtime={datetime.fromtimestamp((BUILD_DIR / 'data' / 'app.so').stat().st_mtime):%Y-%m-%d %H:%M}"
        if (BUILD_DIR / "data" / "app.so").exists() else "[env] app.so 缺失")
    log(f"[env] mode={mode} scenarios={','.join(targets)} seconds={args.seconds} outdir={outdir}")

    kill_app()
    backups = patch_config(mode)
    app_proc = None
    log_file = None
    results = []
    try:
        app_proc, log_file = start_app(outdir / "run.log")
        hwnd = wait_window(app_proc.pid)
        log(f"[app] pid={app_proc.pid} hwnd={hwnd}")
        # 应用会在启动后恢复 session_state 里的窗口尺寸/页面；先等它稳定，
        # 再改尺寸——立刻改会被随后的恢复覆盖（2026-11-06 首次实现实测）。
        time.sleep(args.startup_wait)
        ensure_window_size(hwnd, CLIENT_W, CLIENT_H)
        time.sleep(1.5)
        click(hwnd, HOME_NAV)          # 会话可能恢复上次页面，先强制回到主页
        time.sleep(settle)

        if "startup" in targets:
            results.append(sample_stage(app_proc, "startup", args.seconds, outdir,
                                        not args.no_shot, hwnd))
        if args.scenario == "startup":
            return finish(results, mode_key, outdir, args)

        click(hwnd, VIZ_NAV)
        time.sleep(settle)
        if "viz" in targets:
            results.append(sample_stage(app_proc, "viz", args.seconds, outdir,
                                        not args.no_shot, hwnd))
        if args.scenario == "viz":
            return finish(results, mode_key, outdir, args)

        # 设置 → 测试页 → 粉噪 → 点空白关闭 → 回可视化页
        click(hwnd, SETTINGS_GEAR)
        time.sleep(0.8)
        click(hwnd, SETTINGS_TEST_TAB)
        time.sleep(0.8)
        click(hwnd, PINK_NOISE)
        time.sleep(0.8)
        click(hwnd, CLICK_OUTSIDE)
        time.sleep(0.5)
        click(hwnd, VIZ_NAV)
        time.sleep(settle)

        if "play" in targets:
            results.append(sample_stage(app_proc, "play", args.seconds, outdir,
                                        not args.no_shot, hwnd))
        if args.scenario == "play":
            return finish(results, mode_key, outdir, args)

        set_minimized(hwnd, True)
        time.sleep(3)
        results.append(sample_stage(app_proc, "minimized", args.seconds, outdir,
                                    False, hwnd))
        set_minimized(hwnd, False)
        return finish(results, mode_key, outdir, args)
    finally:
        if app_proc is not None:
            kill_app()
        if log_file is not None:
            log_file.close()
        restore_config(backups)
        log("[cleanup] 进程已结束，config/session_state 已恢复")


def finish(results: list[dict], mode: str, outdir: Path, args) -> int:
    rows = []
    failures = 0
    print()
    header = f"{'场景':<12}{'RSS均值/峰值':>18}{'CPU均值/峰值':>16}{'GPU3D均值/峰值':>18}{'共享显存MB':>12}{'ΔRSS':>9}  判定"
    print(header)
    print("-" * len(header))
    for item in results:
        label = item["label"]
        s, g = item["summary"], item["gpu"]
        ok, notes = gate_result(mode, label, s, g)
        ref = REFERENCE.get((mode, label), {})
        drss = ""
        if ref.get("rss_avg_mb"):
            drss = f"{s['rss_avg_mb'] - ref['rss_avg_mb']:+.1f}"
        verdict = "PASS" if ok else "WARN"
        if not ok:
            failures += 1
        print(f"{LABELS[label]:<10}{s['rss_avg_mb']:>9.1f}/{s['rss_max_mb']:<8.1f}"
              f"{s['cpu_avg_pct_core']:>8.1f}/{s['cpu_max_pct_core']:<7.1f}"
              f"{g.get('gpu_3d_avg', -1):>9.2f}/{g.get('gpu_3d_max', -1):<8.2f}"
              f"{g.get('shared_avg_mb', -1):>12.1f}{drss:>9}  {verdict}")
        for n in notes:
            print(f"  ↳ {n}")
        rows.append({
            "mode": mode, "scenario": label, "seconds": item["seconds"],
            "rss_avg_mb": s["rss_avg_mb"], "rss_max_mb": s["rss_max_mb"],
            "private_avg_mb": s["private_avg_mb"],
            "cpu_avg_pct_core": s["cpu_avg_pct_core"],
            "cpu_max_pct_core": s["cpu_max_pct_core"],
            "gpu_3d_avg": g.get("gpu_3d_avg"), "gpu_3d_max": g.get("gpu_3d_max"),
            "gpu_shared_avg_mb": g.get("shared_avg_mb"),
            "gpu_dedicated_avg_mb": g.get("dedicated_avg_mb"),
            "threads_avg": s["threads_avg"], "verdict": "PASS" if ok else "WARN",
        })

    with (outdir / "stages.csv").open("w", encoding="utf-8", newline="") as fh:
        writer = csv.DictWriter(fh, fieldnames=list(rows[0].keys()) if rows else [])
        writer.writeheader()
        writer.writerows(rows)

    summary = {
        "generated_at": datetime.now().isoformat(timespec="seconds"),
        "mode": mode,
        "exe": str(APP_EXE),
        "exe_mtime": datetime.fromtimestamp(APP_EXE.stat().st_mtime).isoformat(timespec="seconds"),
        "results": rows,
        "reference": {f"{m}/{l}": v for (m, l), v in REFERENCE.items()},
        "thresholds": {f"{m}/{l}": v for (m, l), v in THRESHOLDS.items()},
        "strict": bool(args.strict),
    }
    (outdir / "summary.json").write_text(
        json.dumps(summary, ensure_ascii=False, indent=2), encoding="utf-8")
    print(f"\n产物目录：{outdir}")
    print(f"对照表：{outdir / 'stages.csv'}")

    if args.strict and failures:
        print(f"[strict] {failures} 个场景超出阈值")
        return 1
    if failures:
        print(f"[soft] {failures} 个场景超出阈值（未加 --strict，返回 0）")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(
        description="AuraDSP Windows 性能回归（内存/CPU/GPU 四场景）")
    parser.add_argument("--mode", choices=["sysapo", "voicemeeter_api"], default="sysapo",
                        help="sysapo=非 VB（默认）；voicemeeter_api=VB attach")
    parser.add_argument("--scenario", choices=["all", *SCENARIOS], default="all")
    parser.add_argument("--seconds", type=float, default=15.0, help="每场景采样秒数")
    parser.add_argument("--settle", type=float, default=10.0, help="切页/启动后的稳定等待秒数")
    parser.add_argument("--startup-wait", type=float, default=14.0,
                        help="启动后等 session_state 恢复完成的秒数（再改窗口尺寸）")
    parser.add_argument("--outdir", default=None, help="产物目录（默认 <repo>/.tmp/perf-regression/<ts>）")
    parser.add_argument("--strict", action="store_true", help="超出阈值时退出码 1")
    parser.add_argument("--build", action="store_true", help="跑前执行 release 构建")
    parser.add_argument("--no-shot", action="store_true", help="不保存场景截图")
    return run(parser.parse_args())


if __name__ == "__main__":
    raise SystemExit(main())
