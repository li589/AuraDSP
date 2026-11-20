"""便携包 `AuraDSP-Linux-x64-v<ver>.tar.gz`（AppImage 的补充形态）。

解压即用：`./auradsp` 启动。内容为 Flutter bundle 原样加一个启动脚本，
不做 AppDir 化——它要解决的是「目标机没有 FUSE、又不想装 deb」这个场景。

条目按名排序写入（`tar --sort=name`）：与 Windows 的 zip_dir 保持同一
不可复现性口径。老 tar 不支持该选项时回退到目录序并告警，不因此失败。
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from pathlib import Path

from ..common import die, log, warn
from ..paths import LINUX_PORTABLE_README
from . import perms, textio

TOP_DIR = "AuraDSP-Linux-x64"

LAUNCHER = """\
#!/bin/bash
HERE="$(dirname "$(readlink -f "${0}")")"
exec "${HERE}/auradsp_app" "$@"
"""


def _tar_supports_sort() -> bool:
    try:
        r = subprocess.run(["tar", "--help"], capture_output=True, text=True)
    except OSError:
        return False
    return "--sort" in (r.stdout + r.stderr)


def build(bundle: Path, version: str, out_dir: Path) -> Path:
    if shutil.which("tar") is None:
        raise die("缺少 tar（便携包需要）")

    work = Path(tempfile.mkdtemp())
    try:
        top = work / TOP_DIR
        top.mkdir()
        for item in bundle.iterdir():
            target = top / item.name
            if item.is_dir() and not item.is_symlink():
                shutil.copytree(item, target, symlinks=True)
            else:
                shutil.copy2(item, target, follow_symlinks=False)

        launcher = top / "auradsp"
        launcher.write_text(LAUNCHER, encoding="utf-8")
        if LINUX_PORTABLE_README.is_file():
            textio.copy_text_lf(LINUX_PORTABLE_README, top / "README.md")

        stats = perms.normalize_tree(top)
        log(f"权限规范化: {perms.describe(stats)}")
        perms.make_executable(launcher)

        out_dir.mkdir(parents=True, exist_ok=True)
        tar_path = out_dir / f"AuraDSP-Linux-x64-v{version}.tar.gz"

        cmd = ["tar", "-czf", str(tar_path)]
        if _tar_supports_sort():
            cmd.append("--sort=name")
        else:
            warn("tar 不支持 --sort=name，条目顺序随目录序（不影响可用性）")
        cmd += ["-C", str(work), TOP_DIR]

        r = subprocess.run(cmd, capture_output=True, text=True)
        if r.returncode != 0:
            raise die(f"tar 失败（rc={r.returncode}）：{r.stderr.strip()[:400]}")
        log(f"built: {tar_path}")
        return tar_path
    finally:
        shutil.rmtree(work, ignore_errors=True)
