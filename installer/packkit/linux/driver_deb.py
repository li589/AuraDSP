"""驱动配置包 `auradsp-driver-loopback_<ver>_all.deb`（规格：03 §6）。

纯配置包，零二进制：固化 snd-aloop 的开机加载与模块参数，并附自检脚本。
`Architecture: all` 与 `Depends: kmod` 是刻意的——它可以在任何架构上装，
且只需要 kmod 提供 modprobe。
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from email.utils import formatdate
from pathlib import Path

from ..common import die, log
from . import perms

PKG_NAME = "auradsp-driver-loopback"
MAINTAINER = "AuraDSP Project <3119317786@qq.com>"

CHECK_SCRIPT = """\
#!/bin/bash
# AuraDSP 回环驱动自检：snd-aloop 模块与 Loopback 声卡可见性报告。
set -u
fail=0
if grep -q '^snd_aloop ' /proc/modules; then
    echo "OK   snd_aloop module is loaded"
else
    echo "MISS snd_aloop module is not loaded (try: sudo modprobe snd-aloop)"
    fail=1
fi
if [ -d /proc/asound/Loopback ]; then
    echo "OK   Loopback card is present (/proc/asound/Loopback)"
else
    echo "MISS Loopback card not found in /proc/asound"
    fail=1
fi
if command -v aplay >/dev/null 2>&1; then
    if aplay -l 2>/dev/null | grep -qi 'loopback'; then
        echo "OK   aplay -l lists the Loopback card"
    else
        echo "MISS aplay -l does not list a Loopback card"
        fail=1
    fi
fi
if [ "$fail" -eq 0 ]; then
    echo "auradsp-loopback: ready — AuraDSP driver mode can use hw:Loopback"
else
    echo "auradsp-loopback: not ready (see MISS lines above)"
fi
exit "$fail"
"""

COPYRIGHT = """\
AuraDSP loopback driver configuration package.
Copyright (c) AuraDSP contributors. All rights reserved.
Configuration-only package for the in-tree snd-aloop kernel module.
"""

POSTINST = """\
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    # Best effort: make driver mode usable immediately; on restricted
    # systems the config still takes effect at next boot.
    modprobe snd-aloop 2>/dev/null || true
fi
exit 0
"""

CONTROL = f"""\
Package: {PKG_NAME}
Version: {{version}}
Section: sound
Priority: optional
Architecture: all
Maintainer: {MAINTAINER}
Depends: kmod
Recommends: alsa-utils
Description: snd-aloop loopback configuration for AuraDSP driver mode
 AuraDSP's Linux driver mode captures from the snd-aloop loopback card
 (hw:Loopback). This package enables the module at boot
 (/etc/modules-load.d), pins its options (/etc/modprobe.d), and ships
 a self-check tool:
 .
   /usr/lib/auradsp-driver-loopback/auradsp-loopback-check
 .
 It contains no binaries and can be installed or removed independently
 of the main auradsp package.
"""

MODULES_LOAD = "snd-aloop\n"

MODPROBE_CONF = """\
# AuraDSP driver mode (snd-aloop loopback sound card, hw:Loopback).
# enable=1 keeps the module loadable on demand; the card appears as "Loopback".
options snd-aloop enable=1
"""


def changelog_text(version: str, when: str | None = None) -> str:
    stamp = when or formatdate(localtime=True)
    return (
        f"{PKG_NAME} ({version}) stable; urgency=medium\n"
        "\n"
        f"  * Release {version}.\n"
        "\n"
        f" -- {MAINTAINER}  {stamp}\n"
    )


def build(version: str, out_dir: Path) -> Path:
    if shutil.which("dpkg-deb") is None:
        raise die("缺少 dpkg-deb（deb 打包需要）")

    stage = Path(tempfile.mkdtemp())
    try:
        pkg = stage / "pkg"
        for sub in ("etc/modules-load.d", "etc/modprobe.d",
                    f"usr/lib/{PKG_NAME}", f"usr/share/doc/{PKG_NAME}", "DEBIAN"):
            (pkg / sub).mkdir(parents=True, exist_ok=True)

        (pkg / "etc/modules-load.d/auradsp-loopback.conf").write_text(
            MODULES_LOAD, encoding="utf-8")
        (pkg / "etc/modprobe.d/auradsp-loopback.conf").write_text(
            MODPROBE_CONF, encoding="utf-8")

        check = pkg / f"usr/lib/{PKG_NAME}/auradsp-loopback-check"
        check.write_text(CHECK_SCRIPT, encoding="utf-8")

        doc = pkg / f"usr/share/doc/{PKG_NAME}"
        (doc / "copyright").write_text(COPYRIGHT, encoding="utf-8")
        (doc / "changelog").write_text(changelog_text(version), encoding="utf-8")
        # 与原脚本同一调用（-n 保证字节可复现）
        subprocess.run(["gzip", "-9", "-n", "-f", str(doc / "changelog")],
                       check=True)

        stats = perms.normalize_tree(pkg)
        log(f"权限规范化: {perms.describe(stats)}")
        perms.make_executable(check)

        (pkg / "DEBIAN/control").write_text(
            CONTROL.format(version=version), encoding="utf-8")
        (pkg / "DEBIAN/postinst").write_text(POSTINST, encoding="utf-8")
        perms.make_executable(pkg / "DEBIAN/postinst")

        out_dir.mkdir(parents=True, exist_ok=True)
        deb = out_dir / f"{PKG_NAME}_{version}_all.deb"
        r = subprocess.run(["dpkg-deb", "--build", "--root-owner-group",
                            str(pkg), str(deb)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise die(f"dpkg-deb 失败（rc={r.returncode}）：{r.stderr.strip()[:400]}")
        log(f"built: {deb}")
        return deb
    finally:
        shutil.rmtree(stage, ignore_errors=True)
