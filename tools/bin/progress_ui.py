#!/usr/bin/env python3
"""progress_ui.py — 打包/测试脚本的进度小窗（2026-11-24，user 提议）。

定位：**只旁观，不参与**。release.py / pack.py / test/runner.py 这类长跑
脚本启动时拉起一个独立子进程显示进度（当前步骤、进度条、已用时、最近
日志），脚本结束窗口自动关。命令行与日志输出一字不变，UI 只是镜像。

隔离纪律（本模块的立身之本）：
- UI 是**独立子进程**（pythonw + Tkinter，标准库零新依赖），与宿主脚本
  只通过 stdin 管道以 JSON 行通信；子进程崩了/没桌面/Tk 不可用，宿主侧
  第一次发送失败即永久静默退化为纯命令行模式。
- 宿主侧所有公开方法**永不抛异常**：内部全包 try/except，发送失败只把
  自己置为失效。调用方不需要任何防御代码。
- 子进程读到管道 EOF（宿主退出或被杀）即自行收尾退出，不留孤儿窗。
- 关闭开关：环境变量 `AURADSP_NO_UI=1` 全局禁用；非 Windows 平台默认
  不拉起（`AURADSP_PROGRESS_UI=1` 可强制尝试，失败照样静默）。

协议（一行一个 JSON，UTF-8）：
  {"t":"title","text":...}            窗口标题（首行）
  {"t":"step","text":...}             当前步骤文案
  {"t":"prog","done":n,"total":m}     进度（total 可后补）
  {"t":"log","text":...}              日志行（窗口只留最近 300 行）
  {"t":"done","ok":true/false,"text":...}  终局：成功停 4s、失败停 15s 后自关

用法（宿主侧）：
  from progress_ui import ProgressUI   # 按路径加载，见各入口的加载器
  ui = ProgressUI("AuraDSP 发布 r67", total=180)
  ui.step("预检门禁"); ui.log("..."); ui.advance()
  ui.done(ok=True, text="PASS 180 | FAIL 0")
也支持 with 语句（退出时按有无异常自动 done）。
"""

from __future__ import annotations

import atexit
import json
import os
import subprocess
import sys
import time

_DONE_OK_LINGER_MS = 4000
_DONE_FAIL_LINGER_MS = 15000
_EOF_LINGER_MS = 2500
_LOG_KEEP_LINES = 300


def _disabled_by_env() -> bool:
    v = os.environ.get("AURADSP_NO_UI", "").strip().lower()
    return v in ("1", "true", "yes", "on")


def _should_spawn() -> bool:
    if _disabled_by_env():
        return False
    # 嵌套抑制：release 编排已开窗时，其子进程（pack 等）不再另开窗，
    # 由编排层在拉起子进程前置 AURADSP_UI_NESTED=1。
    if os.environ.get("AURADSP_UI_NESTED", "").strip():
        return False
    if sys.platform == "win32":
        return True
    return os.environ.get("AURADSP_PROGRESS_UI", "").strip() == "1"


def _child_executable() -> str:
    """优先 pythonw（无控制台闪窗）；不存在时退回当前解释器。"""
    exe = sys.executable or "python"
    if sys.platform == "win32":
        cand = os.path.join(os.path.dirname(exe), "pythonw.exe")
        if os.path.exists(cand):
            return cand
    return exe


class ProgressUI:
    """宿主侧句柄。构造即尝试拉起子进程；失败后所有方法为空操作。"""

    def __init__(self, title: str, total: int | None = None) -> None:
        self._proc: subprocess.Popen | None = None
        self._done_sent = False
        self._count = 0
        self._total = total
        if not _should_spawn():
            return
        try:
            self._proc = subprocess.Popen(
                [_child_executable(), os.path.abspath(__file__), "--serve"],
                stdin=subprocess.PIPE,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
            )
        except Exception:
            self._proc = None
            return
        self._send({"t": "title", "text": title})
        if total:
            self._send({"t": "prog", "done": 0, "total": total})
        try:
            atexit.register(self._at_exit)
        except Exception:
            pass

    # -- 内部 ------------------------------------------------------------
    def _send(self, event: dict) -> None:
        proc = self._proc
        if proc is None or self._done_sent:
            return
        try:
            line = json.dumps(event, ensure_ascii=False) + "\n"
            proc.stdin.write(line.encode("utf-8"))  # type: ignore[union-attr]
            proc.stdin.flush()  # type: ignore[union-attr]
        except Exception:
            # 管道断裂 = UI 已死：永久静默，宿主照常跑。
            self._proc = None

    def _at_exit(self) -> None:
        # 没显式 done 就关管道：子进程读到 EOF 会自己收尾。
        proc, self._proc = self._proc, None
        if proc is not None:
            try:
                proc.stdin.close()  # type: ignore[union-attr]
            except Exception:
                pass

    # -- 公开 API（永不抛） ------------------------------------------------
    def step(self, text: str) -> None:
        self._send({"t": "step", "text": str(text)})

    def log(self, text: str) -> None:
        for line in str(text).splitlines() or [""]:
            self._send({"t": "log", "text": line})

    def advance(self, n: int = 1) -> None:
        self._count += n
        event: dict = {"t": "prog", "done": self._count}
        if self._total:
            event["total"] = self._total
        self._send(event)

    def set_total(self, total: int) -> None:
        self._total = total
        self._send({"t": "prog", "done": self._count, "total": total})

    def done(self, ok: bool = True, text: str = "") -> None:
        if self._done_sent:
            return
        self._send({"t": "done", "ok": bool(ok), "text": str(text)})
        self._done_sent = True
        # 给子进程留出读完管道的时间再关写端；关早了终局事件会丢。
        try:
            time.sleep(0.15)
        except Exception:
            pass
        self._at_exit()

    def __enter__(self) -> "ProgressUI":
        return self

    def __exit__(self, exc_type, exc, tb) -> bool:
        self.done(ok=exc_type is None,
                  text="" if exc_type is None else f"{exc_type.__name__}: {exc}")
        return False


# ---------------------------------------------------------------------------
# 子进程侧：Tk 小窗。只在被以 --serve 拉起时运行；任何异常都只死自己。
# ---------------------------------------------------------------------------

def _serve() -> int:
    try:
        import tkinter as tk
        from tkinter import ttk
    except Exception:
        return 3

    import queue

    events: "queue.Queue[dict | None]" = queue.Queue()

    def _reader() -> None:
        try:
            for raw in sys.stdin.buffer:
                try:
                    events.put(json.loads(raw.decode("utf-8", "replace")))
                except Exception:
                    continue
        except Exception:
            pass
        events.put(None)  # EOF 哨兵

    import threading
    threading.Thread(target=_reader, daemon=True).start()

    try:
        root = tk.Tk()
    except Exception:
        return 4  # 无桌面/显示环境：只死自己，宿主无感
    root.title("AuraDSP 进度")
    root.geometry("560x380")
    root.minsize(420, 260)

    started = time.monotonic()
    state = {"done": 0, "total": 0, "finished": False}

    frm = ttk.Frame(root, padding=10)
    frm.pack(fill="both", expand=True)
    step_var = tk.StringVar(value="启动中…")
    ttk.Label(frm, textvariable=step_var, font=("", 11, "bold"),
              wraplength=530).pack(anchor="w", fill="x")
    bar = ttk.Progressbar(frm, mode="determinate", maximum=100)
    bar.pack(fill="x", pady=(8, 2))
    meta_var = tk.StringVar(value="")
    ttk.Label(frm, textvariable=meta_var).pack(anchor="w")
    status_var = tk.StringVar(value="")
    status_lbl = ttk.Label(frm, textvariable=status_var, font=("", 10, "bold"))
    status_lbl.pack(anchor="w", pady=(2, 6))
    log_box = tk.Text(frm, height=12, state="disabled", wrap="word",
                      font=("Consolas", 9))
    log_box.pack(fill="both", expand=True)

    def _append_log(text: str) -> None:
        log_box.configure(state="normal")
        log_box.insert("end", text + "\n")
        lines = int(log_box.index("end-1c").split(".")[0])
        if lines > _LOG_KEEP_LINES:
            log_box.delete("1.0", f"{lines - _LOG_KEEP_LINES}.0")
        log_box.see("end")
        log_box.configure(state="disabled")

    def _update_meta() -> None:
        elapsed = int(time.monotonic() - started)
        mm, ss = divmod(elapsed, 60)
        prog = ""
        if state["total"]:
            prog = f"{state['done']}/{state['total']} · "
        meta_var.set(f"{prog}已用 {mm:02d}:{ss:02d}")
        if not state["finished"]:
            root.after(500, _update_meta)

    def _finish(ok: bool | None, text: str) -> None:
        if state["finished"]:
            return
        state["finished"] = True
        if ok is True:
            status_var.set(f"✓ 完成{text and ' — ' + text}")
            status_lbl.configure(foreground="#1a7f37")
            linger = _DONE_OK_LINGER_MS
        elif ok is False:
            status_var.set(f"✗ 失败{text and ' — ' + text}")
            status_lbl.configure(foreground="#cf222e")
            linger = _DONE_FAIL_LINGER_MS
        else:
            status_var.set("（进程已结束）")
            linger = _EOF_LINGER_MS
        if state["total"]:
            bar.configure(value=state["done"], maximum=state["total"])
        root.after(linger, _close)

    def _close() -> None:
        try:
            root.destroy()
        except Exception:
            pass

    def _drain() -> None:
        try:
            while True:
                ev = events.get_nowait()
                if ev is None:
                    _finish(None, "")
                    continue
                kind = ev.get("t")
                if kind == "title":
                    root.title(str(ev.get("text", "AuraDSP 进度")))
                elif kind == "step":
                    step_var.set(str(ev.get("text", "")))
                elif kind == "log":
                    _append_log(str(ev.get("text", "")))
                elif kind == "prog":
                    if ev.get("total"):
                        state["total"] = int(ev["total"])
                    if ev.get("done") is not None:
                        state["done"] = int(ev["done"])
                    if state["total"]:
                        bar.configure(maximum=state["total"],
                                      value=state["done"])
                elif kind == "done":
                    _finish(bool(ev.get("ok")), str(ev.get("text", "")))
        except queue.Empty:
            pass
        except Exception:
            pass
        if not state["finished"] or True:
            try:
                root.after(80, _drain)
            except Exception:
                pass

    root.protocol("WM_DELETE_WINDOW", _close)
    _update_meta()
    _drain()
    try:
        root.mainloop()
    except Exception:
        pass
    return 0


def _demo() -> int:
    """人工自检：喂一段假进度，肉眼确认窗口出现与自动关闭。"""
    ui = ProgressUI("AuraDSP 进度窗自检 demo", total=5)
    for i in range(1, 6):
        ui.step(f"假步骤 {i}/5")
        ui.log(f"demo log line {i}")
        ui.advance()
        time.sleep(0.7)
    ui.done(ok=True, text="demo 完成，应在约 4 秒后自动关闭")
    return 0


if __name__ == "__main__":
    if "--serve" in sys.argv:
        raise SystemExit(_serve())
    if "--demo" in sys.argv:
        raise SystemExit(_demo())
    print(__doc__)
