# -*- coding: utf-8 -*-
"""Local safety checks for the maintained remote and emergency tooling."""
import builtins
import hashlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
REMOTE = ROOT / "tools" / "remote"
FAILURES = []


def check(ok, label):
    print(("PASS " if ok else "FAIL ") + label)
    if not ok:
        FAILURES.append(label)


def load_guest_file_info():
    path = REMOTE / "guest_file_info.py"
    spec = importlib.util.spec_from_file_location("guest_file_info", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_chunked_hash():
    module = load_guest_file_info()
    payload = bytes(range(256)) * 9000

    class ChunkOnlyReader(io.BytesIO):
        def read(self, size=-1):
            if size is None or size < 0:
                raise AssertionError("whole-file read is not allowed")
            return super().read(size)

    reader = ChunkOnlyReader(payload)
    with mock.patch.object(builtins, "open", return_value=reader):
        try:
            size, digest = module.sha256_file("fixture.bin")
        except (AttributeError, AssertionError) as exc:
            check(False, f"guest_file_info hashes in bounded chunks ({exc})")
            return
    check(size == len(payload), "guest_file_info reports streamed size")
    check(digest == hashlib.sha256(payload).hexdigest(),
          "guest_file_info streamed SHA-256 matches")


def test_parse_check():
    script = REMOTE / "parse_check.ps1"
    if not script.is_file():
        check(False, "canonical parse_check.ps1 exists")
        return
    if os.name != "nt":
        print("SKIP PowerShell execution on non-Windows")
        return
    with tempfile.TemporaryDirectory(prefix="auradsp_parse_check_") as td:
        target = Path(td) / "parse_check.ps1"
        shutil.copyfile(script, target)
        (Path(td) / "good.ps1").write_text("Write-Output 'ok'\n", encoding="ascii")
        command = ["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass",
                   "-File", str(target)]
        good = subprocess.run(command, capture_output=True, text=True, timeout=30)
        check(good.returncode == 0,
              f"parse_check accepts valid local scripts (rc={good.returncode})")
        (Path(td) / "bad.ps1").write_text("function {\n", encoding="ascii")
        bad = subprocess.run(command, capture_output=True, text=True, timeout=30)
        check(bad.returncode != 0,
              f"parse_check rejects invalid scripts (rc={bad.returncode})")
        check("bad.ps1" in (bad.stdout + bad.stderr),
              "parse_check names the invalid script")


def test_emergency_guards():
    path = ROOT / "tools" / "Emergency_Fix_Audio.cmd"
    src = path.read_text(encoding="ascii").lower()
    check("net session" in src, "emergency script requires administrator rights")
    check("choice " in src, "emergency script requires explicit confirmation")
    check("sc query audiosrv" in src and "running" in src,
          "emergency script verifies the audio service is running")
    check("exit /b 1" in src, "emergency script returns a failure exit code")
    check("--no-pause" in src, "emergency script supports noninteractive pause control")
    success_at = src.find("audio subsystem restarted")
    verify_at = src.find("sc query audiosrv")
    check(success_at >= 0 and verify_at >= 0 and verify_at < success_at,
          "emergency script does not claim success before service verification")


def test_old_snapshot_removed():
    check(not (ROOT / "tools" / "remote_tools").exists(),
          "obsolete tools/remote_tools snapshot is removed")


test_chunked_hash()
test_parse_check()
test_emergency_guards()
test_old_snapshot_removed()

if FAILURES:
    print("FAILED:", *FAILURES, sep="\n  ")
    sys.exit(1)
print("ALL OK")
