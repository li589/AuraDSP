#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""dist_manifest.py — 发行产物清单（build-info.txt）生成与校验。

背景（产物的规范化，2026-11-05）
--------------------------------
`dist/<产品>-<平台>/` 是绿色便携包的唯一真源目录，但此前没有任何构建
标识：拿到一个 zip 无法判断它对应哪个提交、工作区是否干净、各二进制
是否与源码一致。本工具在产物归集后写 `build-info.txt`，并在打包前
可用 `--check` 校验清单与文件是否仍然一致。

写入内容
--------
  · 产品版本（app/auradsp_app/pubspec.yaml 的 version:）
  · git 提交 / 分支 / 工作区是否脏
  · 生成时间（本地 + UTC）
  · 顶层二进制清单（SHA256 + 字节数）：exe / dll / so / plugin_host_*

用法
----
    python tools/bin/dist_manifest.py
    python tools/bin/dist_manifest.py --dist-dir dist/AuraDSP-Windows-x64
    python tools/bin/dist_manifest.py --check

退出码：0 成功（或校验一致）；1 目录/文件缺失；2 校验不一致。
"""
import argparse
import datetime as _dt
import hashlib
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
MANIFEST_NAME = "build-info.txt"

DIST_NAMES = {
    "win32": "AuraDSP-Windows-x64",
    "linux": "AuraDSP-Linux-x64",
}


def default_dist_dir() -> Path:
    key = "win32" if sys.platform.startswith("win") else "linux"
    return ROOT / "dist" / DIST_NAMES[key]


def read_version() -> str:
    pubspec = ROOT / "app" / "auradsp_app" / "pubspec.yaml"
    try:
        for line in pubspec.read_text(encoding="utf-8").splitlines():
            m = re.match(r"^version:\s*(\S+)\s*$", line)
            if m:
                return m.group(1)
    except OSError:
        pass
    return "unknown"


def git(*args: str) -> str:
    try:
        out = subprocess.run(
            ["git", *args], cwd=ROOT, capture_output=True, text=True,
            encoding="utf-8", errors="replace", check=False)
        return out.stdout.strip() if out.returncode == 0 else ""
    except OSError:
        return ""


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def is_artifact(name: str) -> bool:
    lower = name.lower()
    if lower == MANIFEST_NAME:
        return False
    if lower.endswith((".exe", ".dll", ".so")):
        return True
    if lower.startswith("plugin_host_"):
        return True
    # Linux 主程序无扩展名
    return lower == "auradsp_app"


def collect(dist_dir: Path):
    files = sorted(p for p in dist_dir.iterdir()
                   if p.is_file() and is_artifact(p.name))
    rows = []
    for p in files:
        rows.append((p.name, p.stat().st_size, sha256(p)))
    return rows


def render(dist_dir: Path, rows) -> str:
    now_local = _dt.datetime.now().astimezone()
    now_utc = _dt.datetime.now(_dt.timezone.utc)
    dirty = "yes" if git("status", "--porcelain") else "no"
    lines = [
        "AuraDSP distribution manifest",
        "generated_at_local: " + now_local.strftime("%Y-%m-%d %H:%M:%S %z"),
        "generated_at_utc:   " + now_utc.strftime("%Y-%m-%dT%H:%M:%SZ"),
        "product:            AuraDSP",
        "version:            " + read_version(),
        "platform:           " + dist_dir.name,
        "commit:             " + (git("rev-parse", "HEAD") or "unknown"),
        "branch:             " + (git("rev-parse", "--abbrev-ref", "HEAD")
                                   or "unknown"),
        "worktree_dirty:     " + dirty,
        "layout:             portable",
        "",
        "artifacts (sha256  bytes  name):",
    ]
    for name, size, digest in rows:
        lines.append(f"{digest}  {size:>10}  {name}")
    lines.append("")
    return "\n".join(lines)


def parse_manifest(text: str):
    rows = []
    for line in text.splitlines():
        m = re.match(r"^([0-9a-f]{64})\s+(\d+)\s+(.+)$", line.strip())
        if m:
            rows.append((m.group(3), int(m.group(2)), m.group(1)))
    return rows


def main() -> int:
    ap = argparse.ArgumentParser(description="AuraDSP 发行产物清单")
    ap.add_argument("--dist-dir", type=Path, default=None,
                    help="目标发行目录（缺省按当前平台选择 dist/…）")
    ap.add_argument("--check", action="store_true",
                    help="只校验现有 build-info.txt 与文件是否一致")
    args = ap.parse_args()

    dist_dir = (args.dist_dir or default_dist_dir()).resolve()
    if not dist_dir.is_dir():
        print(f"ERROR: dist dir not found: {dist_dir}")
        return 1

    rows = collect(dist_dir)
    if not rows:
        print(f"ERROR: no artifacts found in {dist_dir}")
        return 1

    manifest = dist_dir / MANIFEST_NAME
    if args.check:
        if not manifest.is_file():
            print(f"ERROR: manifest missing: {manifest}")
            return 1
        recorded = parse_manifest(manifest.read_text(encoding="utf-8"))
        current = {(n, s, d) for n, s, d in rows}
        recorded_set = {(n, s, d) for n, s, d in recorded}
        if recorded_set != current:
            print("ERROR: manifest mismatch")
            for item in sorted(recorded_set - current):
                print("  stale/missing file:", item[0])
            for item in sorted(current - recorded_set):
                print("  changed/extra file:", item[0])
            return 2
        print(f"OK: manifest matches {len(rows)} artifacts ({manifest})")
        return 0

    manifest.write_text(render(dist_dir, rows), encoding="utf-8", newline="\n")
    print(f"manifest -> {manifest} ({len(rows)} artifacts)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
