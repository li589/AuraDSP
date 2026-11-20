"""主安装包 `auradsp_<ver>_amd64.deb`（规格：installer/docs/03 §2）。

布局口径（2026-11-06 起未变）：Flutter runner 要求 binary 与 `lib/`、`data/`
保持 bundle 原生相对结构，所以整包原样落 `/usr/lib/auradsp/`，`/usr/bin/auradsp`
是指向主程序的符号链接。不按 03 §2.1 的示意树拆平——拆了 runner 就找不到
自己的 `data/`。

control 的 `Depends` 是 t64 双写（`libgtk-3-0t64 | libgtk-3-0`）：Ubuntu
24.04 起 time64 重命名，只写旧名在 24.04+ 装不上，只写新名在 22.04 装不上。

外部命令只剩 `dpkg-deb` / `gzip` / `du`——三者都是 dpkg 构建环境的必备件
（原实现额外依赖 `file`，见 perms.py 的说明）。
"""

from __future__ import annotations

import shutil
import subprocess
import tempfile
from email.utils import formatdate
from pathlib import Path

from ..common import die, log
from ..paths import ICON_SVG, ICONS_DIR, LINUX_SHARED
from . import perms, textio

PKG_NAME = "auradsp"
MAINTAINER = "AuraDSP Project <3119317786@qq.com>"
ICON_SIZES = (16, 24, 32, 48, 64, 128, 256, 512)

COPYRIGHT = """\
AuraDSP — cross-platform global audio effects system.
Copyright (c) AuraDSP contributors. All rights reserved.
Bundled third-party components remain under their respective licenses;
see the repository LICENSE and vendor notices for details.
"""

POSTINST = """\
#!/bin/sh
set -e
if [ "$1" = "configure" ]; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
fi
exit 0
"""

POSTRM = """\
#!/bin/sh
set -e
if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
    update-desktop-database -q /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -q -t -f /usr/share/icons/hicolor 2>/dev/null || true
fi
exit 0
"""

DESCRIPTION = """\
 AuraDSP takes over the system audio path and applies a real-time DSP
 chain: 23 effect units, convolution / DDC headphone correction,
 Liveprog scripting, and VST3 / CLAP / VST2 plugin hosting (in-process
 64-bit, isolated hosts, 32-bit bridge). On Linux it runs on PulseAudio
 (system / virtual sink / snd-aloop driver modes) with an ALSA expert
 mode. The driver mode needs the snd-aloop kernel module; install the
 auradsp-driver-loopback package to enable it at boot. The bundled
 32-bit plugin bridge (plugin_host_x86) needs 32-bit system libraries
 (multilib) on the target machine.
"""

DEPENDS = ("libc6 (>= 2.35), libgtk-3-0t64 | libgtk-3-0 (>= 3.24), "
           "libstdc++6 (>= 11), libpulse0, libasound2t64 | libasound2")
RECOMMENDS = "pulseaudio | pipewire-pulse, auradsp-driver-loopback"


def control_text(version: str, installed_size_kb: int) -> str:
    """DEBIAN/control 全文（字段顺序与历史产物一致，diff 才有意义）。"""
    return (
        f"Package: {PKG_NAME}\n"
        f"Version: {version}-1\n"
        "Section: sound\n"
        "Priority: optional\n"
        "Architecture: amd64\n"
        f"Maintainer: {MAINTAINER}\n"
        f"Installed-Size: {installed_size_kb}\n"
        f"Depends: {DEPENDS}\n"
        f"Recommends: {RECOMMENDS}\n"
        "Description: Cross-platform global audio effects system\n"
        f"{DESCRIPTION}"
    )


def changelog_text(version: str, when: str | None = None) -> str:
    """deb changelog（RFC 2822 日期，与 `date -R` 同形）。"""
    stamp = when or formatdate(localtime=True)
    return (
        f"{PKG_NAME} ({version}-1) stable; urgency=medium\n"
        "\n"
        f"  * Release {version} (see repository RELEASE_NOTES / git tag).\n"
        "\n"
        f" -- {MAINTAINER}  {stamp}\n"
    )


def _require(cmd: str) -> str:
    path = shutil.which(cmd)
    if path is None:
        raise die(f"缺少 {cmd}（deb 打包需要 dpkg-deb / gzip / du）")
    return path


def _installed_size_kb(pkg: Path) -> int:
    """`du -sk <pkg>/usr` 的 1K 块数。

    刻意用 du 而不是自己按 st_size 求和：dpkg 的 Installed-Size 是**磁盘
    占用**（含块对齐），自己算会与历史产物出现稳定偏差，用户侧 `dpkg -s`
    对不上。
    """
    r = subprocess.run(["du", "-sk", str(pkg / "usr")],
                       capture_output=True, text=True, check=True)
    return int(r.stdout.split("\t")[0].strip())


def _gzip_changelog(path: Path) -> None:
    """`gzip -9 -n -f`：-n 不存原名与时间戳，保证同一输入字节可复现。

    用系统 gzip 而不是 Python 的 gzip 模块：两者的 deflate 实现与头部 OS
    字节不同，换实现会让 changelog.gz 的哈希无故变化。
    """
    _require("gzip")
    subprocess.run(["gzip", "-9", "-n", "-f", str(path)], check=True)


def build(bundle: Path, version: str, out_dir: Path) -> Path:
    """组装 deb 并调用 dpkg-deb。返回产物路径。"""
    _require("dpkg-deb")
    if not (bundle / "auradsp_app").is_file():
        raise die(f"bundle 缺 auradsp_app: {bundle}")

    stage = Path(tempfile.mkdtemp())
    try:
        pkg = stage / "pkg"
        for sub in ("usr/lib", "usr/bin", "usr/share/applications",
                    "usr/share/doc/auradsp", "DEBIAN"):
            (pkg / sub).mkdir(parents=True, exist_ok=True)

        # --- 主体：bundle 原样进 /usr/lib/auradsp ---
        shutil.copytree(bundle, pkg / "usr/lib/auradsp", symlinks=True)
        (pkg / "usr/bin/auradsp").symlink_to("../lib/auradsp/auradsp_app")

        # --- 桌面入口与图标 ---
        # desktop entry 按规范必须是 LF；工作区可能是 CRLF（见 textio 注释）
        textio.copy_text_lf(LINUX_SHARED / "auradsp.desktop",
                            pkg / "usr/share/applications/auradsp.desktop")
        for size in ICON_SIZES:
            src = ICONS_DIR / f"auradsp-app-{size}.png"
            if not src.is_file():
                continue
            dest = pkg / f"usr/share/icons/hicolor/{size}x{size}/apps"
            dest.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(src, dest / "auradsp.png")
        if ICON_SVG.is_file():
            dest = pkg / "usr/share/icons/hicolor/scalable/apps"
            dest.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ICON_SVG, dest / "auradsp.svg")

        # --- 文档 ---
        doc = pkg / "usr/share/doc/auradsp"
        (doc / "copyright").write_text(COPYRIGHT, encoding="utf-8")
        (doc / "changelog").write_text(changelog_text(version), encoding="utf-8")
        _gzip_changelog(doc / "changelog")

        # --- 权限规范化（必须先于 control 写入，才能让 du 读到最终尺寸）---
        stats = perms.normalize_tree(pkg)
        log(f"权限规范化: {perms.describe(stats)}")

        # --- 控制文件 ---
        (pkg / "DEBIAN/control").write_text(
            control_text(version, _installed_size_kb(pkg)), encoding="utf-8")
        (pkg / "DEBIAN/postinst").write_text(POSTINST, encoding="utf-8")
        (pkg / "DEBIAN/postrm").write_text(POSTRM, encoding="utf-8")
        perms.make_executable(pkg / "DEBIAN/postinst")
        perms.make_executable(pkg / "DEBIAN/postrm")

        out_dir.mkdir(parents=True, exist_ok=True)
        deb = out_dir / f"{PKG_NAME}_{version}_amd64.deb"
        r = subprocess.run(["dpkg-deb", "--build", "--root-owner-group",
                            str(pkg), str(deb)],
                           capture_output=True, text=True)
        if r.returncode != 0:
            raise die(f"dpkg-deb 失败（rc={r.returncode}）：{r.stderr.strip()[:400]}")
        log(f"built: {deb}")
        return deb
    finally:
        shutil.rmtree(stage, ignore_errors=True)
