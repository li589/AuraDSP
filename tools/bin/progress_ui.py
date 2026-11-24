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
- 关闭开关：环境变量 `AURADSP_NO_UI=1` 全局禁用；release/pack/runner
  均有 `--no-progress-ui` 命令行开关（等效）。非 Windows 平台默认
  不拉起（`AURADSP_PROGRESS_UI=1` 可强制尝试，失败照样静默）。
- **非交互会话中继**：脚本被计划任务/服务拉起时不在活动桌面会话，
  窗口建了也看不见——此时改走文件模式：事件写临时目录的
  events.jsonl，再用一次性 /IT 计划任务把查看器投到活动会话 tail
  显示；取消走同目录 cancel.flag；宿主退出落 closed.flag 并删任务，
  查看器退出时自清目录。中继搭不起来自动退回管道模式。
  `AURADSP_UI_RELAY=0` 可关中继。中继模式下宿主把 events 路径经
  `AURADSP_PROGRESS_EVENTS` 传给子进程，build_windows.ps1 的步骤
  横幅会 append 进同一窗口。

协议（宿主→窗口，一行一个 JSON，UTF-8，经 stdin）：
  {"t":"title","text":...}            窗口标题（首行）
  {"t":"step","text":...}             当前步骤文案
  {"t":"prog","done":n,"total":m}     进度（total 可后补）
  {"t":"log","text":...}              日志行（窗口只留最近 300 行）
  {"t":"done","ok":true/false,"text":...}  终局：成功停 4s、失败停 15s 后自关

交互（窗口→宿主，经子进程 stdout 文本行）：
  CANCEL                              用户点了「取消运行」：宿主在下一个
                                      检查点查 ui.cancelled() 并自行停下
                                      （runner 每条 smoke 前、pack 每个
                                      模式前、release 每个档位前各一处）。
  关窗（X 或「关闭窗口」）不发任何信号：管道断裂后宿主自动卸下 UI，
  脚本照常跑完——关窗永远不等于取消。

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
import threading
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


def _in_active_console_session() -> bool:
    """当前进程是否就在活动桌面会话里（窗口能被用户看见）。

    计划任务/服务方式启动的进程在非交互会话，窗口建了也看不见——这类
    情况改走文件事件 + /IT 计划任务把查看器投到活动会话（见 _start_relay）。
    判读失败一律按「在交互会话」处理（退回管道模式，最坏是看不见，
    不影响脚本本身）。
    """
    if sys.platform != "win32":
        return True
    try:
        import ctypes

        kernel32 = ctypes.windll.kernel32  # type: ignore[attr-defined]
        active = kernel32.WTSGetActiveConsoleSessionId()
        mine = ctypes.c_ulong(0)
        kernel32.ProcessIdToSessionId(kernel32.GetCurrentProcessId(),
                                      ctypes.byref(mine))
        return active == mine.value
    except Exception:
        return True


class ProgressUI:
    """宿主侧句柄。构造即尝试拉起子进程；失败后所有方法为空操作。"""

    def __init__(self, title: str, total: int | None = None) -> None:
        self._proc: subprocess.Popen | None = None
        self._done_sent = False
        self._dead = False
        self._count = 0
        self._total = total
        self._cancel = threading.Event()
        # 文件中继模式状态（非交互会话时用）：事件写 JSONL 文件，查看器
        # 由 /IT 计划任务在活动桌面会话里 tail 显示；取消走同目录 flag。
        self._fh = None
        self.events_path: str | None = None
        self._relay_dir: str | None = None
        self._task_name: str | None = None
        self._cancel_check_at = 0.0
        self._cancel_flag_hit = False
        if not _should_spawn():
            return
        relay_ok = False
        if (sys.platform == "win32"
                and os.environ.get("AURADSP_UI_RELAY", "").strip() != "0"
                and not _in_active_console_session()):
            relay_ok = self._start_relay()
        if not relay_ok:
            try:
                proc = subprocess.Popen(
                    [_child_executable(), os.path.abspath(__file__), "--serve"],
                    stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.DEVNULL,
                )
            except Exception:
                return
            self._attach(proc)
        self._send({"t": "title", "text": title})
        if total:
            self._send({"t": "prog", "done": 0, "total": total})
        try:
            atexit.register(self._at_exit)
        except Exception:
            pass

    def _start_relay(self) -> bool:
        """非交互会话：建事件文件并用 /IT 一次性任务在桌面会话开查看器。"""
        try:
            import tempfile

            relay_dir = tempfile.mkdtemp(prefix="auradsp_ui_")
            events_path = os.path.join(relay_dir, "events.jsonl")
            with open(events_path, "w", encoding="utf-8"):
                pass
            self._fh = open(events_path, "a", encoding="utf-8")
            self._relay_dir = relay_dir
            self.events_path = events_path
            task = f"AuraDSP-ProgressUI-{os.getpid()}"
            tr = (f'"{_child_executable()}" "{os.path.abspath(__file__)}" '
                  f'--serve-file "{events_path}"')
            kw = dict(stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                      timeout=20)
            r1 = subprocess.run(
                ["schtasks", "/Create", "/TN", task, "/TR", tr,
                 "/SC", "ONCE", "/ST", "23:59", "/IT", "/F"], **kw)
            if r1.returncode != 0:
                raise OSError("schtasks create failed")
            self._task_name = task
            r2 = subprocess.run(["schtasks", "/Run", "/TN", task], **kw)
            if r2.returncode != 0:
                raise OSError("schtasks run failed")
            return True
        except Exception:
            # 中继搭不起来：清掉半成品，退回管道模式（看不见但无害）。
            try:
                if self._fh is not None:
                    self._fh.close()
            except Exception:
                pass
            self._fh = None
            self.events_path = None
            self._relay_dir = None
            self._task_name = None
            return False

    def _attach(self, proc) -> None:
        """挂上子进程并起取消信号读线程（窗口 stdout 出现 CANCEL 即置位）。"""
        self._proc = proc

        def _reader() -> None:
            try:
                for raw in proc.stdout:  # type: ignore[union-attr]
                    if raw.strip() == b"CANCEL":
                        self._cancel.set()
            except Exception:
                pass

        try:
            threading.Thread(target=_reader, daemon=True).start()
        except Exception:
            pass

    def cancelled(self) -> bool:
        """用户是否点了「取消运行」。宿主在检查点轮询，永不抛。"""
        try:
            if self._cancel.is_set():
                return True
            if self._relay_dir and not self._cancel_flag_hit:
                now = time.monotonic()
                if now - self._cancel_check_at > 0.25:
                    self._cancel_check_at = now
                    self._cancel_flag_hit = os.path.exists(
                        os.path.join(self._relay_dir, "cancel.flag"))
                return self._cancel_flag_hit
            return False
        except Exception:
            return False

    # -- 内部 ------------------------------------------------------------
    def _drop_pipe(self, proc) -> None:
        """管道断裂收尾：显式 close 并摘掉 stdin 引用。

        只把 self._proc 置 None 不够——Popen.stdin 是 BufferedWriter，
        解释器退出时它还会析构 flush 一次已关闭的 fd，CPython 就此打印
        `Exception ignored in: <_io.BufferedWriter name=N>` + OSError 22
        （构建/打包日志里出现的正是这一条）。显式 close 会把内部 ok 置 0，
        析构不再重试；`proc.stdin = None` 再断一层引用，双保险。
        """
        try:
            stdin = getattr(proc, "stdin", None)
        except Exception:
            stdin = None
        if stdin is None:
            return
        try:
            stdin.close()
        except Exception:
            pass
        try:
            proc.stdin = None
        except Exception:
            pass

    def _send(self, event: dict) -> None:
        if self._done_sent or self._dead:
            return
        if self._fh is None and self._proc is None:
            return
        try:
            line = json.dumps(event, ensure_ascii=False) + "\n"
            if self._fh is not None:
                self._fh.write(line)
                self._fh.flush()
            else:
                proc = self._proc
                proc.stdin.write(line.encode("utf-8"))  # type: ignore[union-attr]
                proc.stdin.flush()  # type: ignore[union-attr]
        except Exception:
            # 管道/文件断裂 = UI 已死：永久静默，宿主照常跑。
            # 注意 proc 只在管道分支里赋值，文件分支失败时未绑定，
            # 必须从 self._proc 现取（rebase 合并 1ccdc1ce 时的坑）。
            self._dead = True
            proc, self._proc = self._proc, None
            if proc is not None:
                self._drop_pipe(proc)

    def _at_exit(self) -> None:
        # 管道模式关写端（子进程读 EOF 自收尾）；中继模式落 closed.flag
        # 并删一次性任务（删任务不杀已在跑的查看器），事件目录留给
        # 查看器退出时自清。
        proc, self._proc = self._proc, None
        if proc is not None:
            self._drop_pipe(proc)
        if self._fh is not None:
            try:
                self._fh.close()
            except Exception:
                pass
            self._fh = None
        if self._relay_dir:
            try:
                with open(os.path.join(self._relay_dir, "closed.flag"),
                          "w", encoding="utf-8") as f:
                    f.write("1")
            except Exception:
                pass
            if self._task_name:
                try:
                    subprocess.run(
                        ["schtasks", "/Delete", "/TN", self._task_name, "/F"],
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                        timeout=15)
                except Exception:
                    pass
                self._task_name = None

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

def _serve_window(events, cancel_action, cleanup=None) -> int:
    """小窗本体：从 events 队列消费事件；cancel_action 为取消按钮回调。

    events 队列元素为事件 dict，None = 事件源已结束（EOF/宿主退出）。
    cleanup 在窗口关闭时调用（文件模式下清中继目录），可为 None。
    """
    try:
        import tkinter as tk
        from tkinter import ttk
    except Exception:
        return 3

    import queue  # noqa: F401  （events 由调用方建好传入，此处仅类型语义）

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

    keep_open = tk.BooleanVar(value=False)
    btn_row = ttk.Frame(frm)
    btn_row.pack(fill="x", pady=(8, 0))
    cancel_btn = ttk.Button(btn_row, text="取消运行")
    cancel_btn.pack(side="left")
    ttk.Button(btn_row, text="关闭窗口", command=lambda: _close()).pack(
        side="left", padx=(8, 0))
    ttk.Checkbutton(btn_row, text="完成后保持打开",
                    variable=keep_open).pack(side="left", padx=(12, 0))
    ttk.Label(btn_row, text="关窗不中断脚本").pack(side="right")

    def _on_cancel() -> None:
        try:
            cancel_action()
        except Exception:
            pass
        cancel_btn.configure(state="disabled")
        status_var.set("正在取消…（当前步骤结束后停下）")

    cancel_btn.configure(command=_on_cancel)

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
        try:
            cancel_btn.configure(state="disabled")
        except Exception:
            pass
        if not keep_open.get():
            root.after(linger, _close)

    def _close() -> None:
        if cleanup is not None:
            try:
                cleanup()
            except Exception:
                pass
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


def _serve() -> int:
    """管道模式：stdin 读事件，取消写 stdout（宿主与查看器同会话时用）。"""
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

    threading.Thread(target=_reader, daemon=True).start()

    def _cancel() -> None:
        sys.stdout.write("CANCEL\n")
        sys.stdout.flush()

    return _serve_window(events, _cancel)


def _serve_file(events_path: str) -> int:
    """文件模式（非交互会话中继）：tail events.jsonl，取消落 cancel.flag。

    结束条件：读到 done 事件（窗口自行按终局收尾）、closed.flag 出现
    （宿主已退）或事件文件被删。退出时清掉整个中继目录。
    """
    import queue

    events: "queue.Queue[dict | None]" = queue.Queue()
    relay_dir = os.path.dirname(os.path.abspath(events_path))
    closed_flag = os.path.join(relay_dir, "closed.flag")
    cancel_flag = os.path.join(relay_dir, "cancel.flag")

    def _tail() -> None:
        buf = b""
        pos = 0
        saw_done = False
        while True:
            try:
                if os.path.exists(closed_flag) or not os.path.exists(events_path):
                    break
                with open(events_path, "rb") as f:
                    f.seek(pos)
                    chunk = f.read()
                    pos = f.tell()
                if chunk:
                    buf += chunk
                    while b"\n" in buf:
                        line, buf = buf.split(b"\n", 1)
                        line = line.strip().lstrip(b"\xef\xbb\xbf")
                        if not line:
                            continue
                        try:
                            ev = json.loads(line.decode("utf-8", "replace"))
                        except Exception:
                            continue
                        events.put(ev)
                        if ev.get("t") == "done":
                            saw_done = True
                if saw_done:
                    # 终局已投递，窗口自会按 linger 收尾；再等 closed.flag
                    # 兜底即可，不必继续 tail。
                    while not os.path.exists(closed_flag):
                        time.sleep(0.25)
                    break
            except Exception:
                pass
            time.sleep(0.1)
        events.put(None)

    threading.Thread(target=_tail, daemon=True).start()

    def _cancel() -> None:
        with open(cancel_flag, "w", encoding="utf-8") as f:
            f.write("1")

    def _cleanup() -> None:
        for name in ("events.jsonl", "cancel.flag", "closed.flag"):
            try:
                os.remove(os.path.join(relay_dir, name))
            except Exception:
                pass
        try:
            os.rmdir(relay_dir)
        except Exception:
            pass

    return _serve_window(events, _cancel, cleanup=_cleanup)


def _demo() -> int:
    """人工自检：喂一段假进度，肉眼确认窗口出现与自动关闭。

    步骤拉长到 10 步、每步 1.2s，留足点「取消运行」的时间：点后 demo
    应在当前步结束即停下并显示失败终局；不点则走完显示完成。
    """
    ui = ProgressUI("AuraDSP 进度窗自检 demo", total=10)
    for i in range(1, 11):
        if ui.cancelled():
            ui.done(ok=False, text=f"已在第 {i} 步前取消")
            return 2
        ui.step(f"假步骤 {i}/10")
        ui.log(f"demo log line {i}")
        ui.advance()
        time.sleep(1.2)
    ui.done(ok=True, text="demo 完成，应在约 4 秒后自动关闭")
    return 0


if __name__ == "__main__":
    if "--serve" in sys.argv:
        raise SystemExit(_serve())
    if "--serve-file" in sys.argv:
        idx = sys.argv.index("--serve-file")
        raise SystemExit(_serve_file(sys.argv[idx + 1]))
    if "--demo" in sys.argv:
        raise SystemExit(_demo())
    print(__doc__)
