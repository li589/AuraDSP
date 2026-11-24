# -*- coding: utf-8 -*-
"""smoke_progress_ui.py — 进度小窗隔离纪律门禁（纯源码 + 本地行为，任意平台）。

背景（2026-11-24，user 提议）：release.py / pack.py / runner.py 长跑时拉起
Tk 进度小窗旁观进度。立身之本是**UI 异常绝不带崩脚本**，本 smoke 钉住：

1. AURADSP_NO_UI=1 时构造不拉起子进程、全部方法可安全调用；
2. 子进程可执行文件不存在（模拟 UI 侧彻底损坏）时构造不抛、方法静默；
3. 管道写端一写就炸（模拟窗口中途崩溃）时发送不抛、自动失效；
4. AURADSP_UI_NESTED=1 时不另开窗（release 编排的子进程抑制）；
5. 事件协议为逐行 JSON，形状与 progress_ui.py 文档一致；
6. --serve 子进程喂垃圾行 + EOF 后能自行终止（不留孤儿），退出码不限
   （无显示环境下 Tk 建窗失败即退，有显示时 EOF 后自关）；
7. 接线在位：runner / packkit.common / release / packkit cli 四处引用。

用法：python test/smoke/smoke_progress_ui.py
"""
import io
import json
import os
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
UI_PATH = os.path.join(ROOT, "tools", "bin", "progress_ui.py")

fails = []


def check(name, cond, detail=""):
    print(("PASS  " if cond else "FAIL  ") + name + (f" ({detail})" if detail else ""))
    if not cond:
        fails.append(name)


def load_mod():
    import importlib.util

    spec = importlib.util.spec_from_file_location("auradsp_progress_ui", UI_PATH)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# --- 1. NO_UI：不拉起、方法可调 -------------------------------------------
os.environ["AURADSP_NO_UI"] = "1"
mod = load_mod()
ui = mod.ProgressUI("t", total=3)
check("NO_UI 时不拉起子进程", ui._proc is None)
try:
    ui.step("s")
    ui.log("line1\nline2")
    ui.advance()
    ui.set_total(9)
    ui.done(ok=True, text="x")
    check("NO_UI 时全部方法不抛", True)
except Exception as e:  # noqa: BLE001
    check("NO_UI 时全部方法不抛", False, repr(e))
del os.environ["AURADSP_NO_UI"]

# --- 2. 子进程可执行文件不存在 ---------------------------------------------
mod2 = load_mod()
mod2._child_executable = lambda: os.path.join(ROOT, "no_such_pythonw.exe")
os.environ.pop("AURADSP_NO_UI", None)
try:
    ui2 = mod2.ProgressUI("t")
    ui2.step("s")
    ui2.done()
    check("坏可执行文件时构造/方法不抛", True)
except Exception as e:  # noqa: BLE001
    check("坏可执行文件时构造/方法不抛", False, repr(e))

# --- 3. 管道一写就炸 ---------------------------------------------------------
mod3 = load_mod()
os.environ["AURADSP_NO_UI"] = "1"
ui3 = mod3.ProgressUI("t", total=2)
del os.environ["AURADSP_NO_UI"]


class _BoomStdin:
    def write(self, _b):
        raise BrokenPipeError("boom")

    def flush(self):
        raise BrokenPipeError("boom")

    def close(self):
        raise BrokenPipeError("boom")


class _FakeProc:
    stdin = _BoomStdin()


ui3._proc = _FakeProc()  # type: ignore[assignment]
try:
    ui3.step("s")
    ui3.log("x")
    ui3.advance()
    ui3.done(ok=False, text="y")
    check("管道炸裂时发送不抛", True)
except Exception as e:  # noqa: BLE001
    check("管道炸裂时发送不抛", False, repr(e))
check("管道炸裂后自动失效", ui3._proc is None)

# --- 4. 嵌套抑制 -------------------------------------------------------------
os.environ["AURADSP_UI_NESTED"] = "1"
check("AURADSP_UI_NESTED 时不拉起", mod._should_spawn() is False)
del os.environ["AURADSP_UI_NESTED"]

# --- 5. 事件协议形状 -----------------------------------------------------------
mod5 = load_mod()
os.environ["AURADSP_NO_UI"] = "1"
ui5 = mod5.ProgressUI("标题", total=4)
del os.environ["AURADSP_NO_UI"]
buf = io.BytesIO()


class _MemStdin:
    def write(self, b):
        buf.write(b)
        return len(b)

    def flush(self):
        pass

    def close(self):
        pass


class _MemProc:
    stdin = _MemStdin()


ui5._proc = _MemProc()  # type: ignore[assignment]
ui5.step("步骤一")
ui5.log("日志行")
ui5.advance(2)
ui5.done(ok=True, text="完成")
events = [json.loads(l) for l in buf.getvalue().decode("utf-8").splitlines() if l]
kinds = [e.get("t") for e in events]
check("事件序列含 step/log/prog/done",
      kinds == ["step", "log", "prog", "done"], str(kinds))
prog = events[2]
check("prog 事件带 done/total", prog.get("done") == 2 and prog.get("total") == 4,
      json.dumps(prog, ensure_ascii=False))
check("done 事件带 ok/text", events[3].get("ok") is True
      and events[3].get("text") == "完成")

# --- 6. --serve 喂垃圾 + EOF 后自终止 -----------------------------------------
try:
    p = subprocess.run(
        [sys.executable, UI_PATH, "--serve"],
        input=b"not json at all\n{\"t\":\"step\",\"text\":\"x\"}\n",
        capture_output=True, timeout=25)
    check("--serve 在 EOF 后自行终止", True, f"rc={p.returncode}")
except subprocess.TimeoutExpired:
    check("--serve 在 EOF 后自行终止", False, "25s 未退出（孤儿窗风险）")

# --- 7. 接线在位 ---------------------------------------------------------------
def _has(relpath, needle):
    with open(os.path.join(ROOT, relpath), encoding="utf-8") as f:
        return needle in f.read()


check("runner 接线", _has("test/runner.py", "progress_ui"))
check("packkit.common 日志镜像", _has("installer/packkit/common.py", "open_progress_ui"))
check("release 接线", _has("installer/release.py", "open_progress_ui"))
check("pack cli 接线", _has("installer/packkit/windows/cli.py", "open_progress_ui"))

# --- 8. 取消回传通道 -----------------------------------------------------------
import time as _time

mod8 = load_mod()
os.environ["AURADSP_NO_UI"] = "1"
ui8 = mod8.ProgressUI("t")
del os.environ["AURADSP_NO_UI"]
check("未点取消时 cancelled() 为 False", ui8.cancelled() is False)


class _CancelProc:
    stdin = _MemStdin()
    stdout = io.BytesIO(b"noise line\nCANCEL\n")


ui8._attach(_CancelProc())
deadline = _time.monotonic() + 5.0
while _time.monotonic() < deadline and not ui8.cancelled():
    _time.sleep(0.05)
check("子进程发 CANCEL 后 cancelled() 置位", ui8.cancelled() is True)
ui8._proc = None

# --- 9. 取消检查点在位 -----------------------------------------------------------
check("runner 取消检查点", _has("test/runner.py", "ui.cancelled()"))
check("pack cli 取消检查点",
      _has("installer/packkit/windows/cli.py", "ui_cancelled()"))
check("release 取消检查点", _has("installer/release.py", "ui_cancelled()"))
check("窗口侧有取消按钮", _has("tools/bin/progress_ui.py", "取消运行"))

# --- 10. 非交互会话中继 + 命令行开关（2026-11-24 user 报「UI 似乎不会打开」）---
check("会话判读函数在位且返回 bool",
      isinstance(mod._in_active_console_session(), bool))
check("中继模式在位", _has("tools/bin/progress_ui.py", "--serve-file")
      and _has("tools/bin/progress_ui.py", "AURADSP_UI_RELAY"))
check("release --no-progress-ui", _has("installer/release.py", "--no-progress-ui"))
check("pack --no-progress-ui",
      _has("installer/packkit/windows/cli.py", "--no-progress-ui"))
check("runner --no-progress-ui", _has("test/runner.py", "--no-progress-ui"))
check("release 传事件路径给构建子进程",
      _has("installer/release.py", "AURADSP_PROGRESS_EVENTS"))
check("build_windows.ps1 步骤镜像",
      _has("tools/windows/build_windows.ps1", "AURADSP_PROGRESS_EVENTS")
      and _has("tools/windows/build_windows.ps1", "Send-UiStep"))

# --- 11. --serve-file 喂 done 后自终止 ------------------------------------------
import tempfile

relay_dir = tempfile.mkdtemp(prefix="auradsp_ui_smoke_")
events_path = os.path.join(relay_dir, "events.jsonl")
with open(events_path, "w", encoding="utf-8") as f:
    f.write('{"t":"title","text":"smoke"}\n{"t":"done","ok":true,"text":"x"}\n')
try:
    p = subprocess.run([sys.executable, UI_PATH, "--serve-file", events_path],
                       capture_output=True, timeout=25)
    check("--serve-file 在 done 后自行终止", True, f"rc={p.returncode}")
except subprocess.TimeoutExpired:
    check("--serve-file 在 done 后自行终止", False, "25s 未退出")

print()
if fails:
    print(f"FAILURES: {fails}")
    sys.exit(1)
print("smoke_progress_ui: all checks passed")
