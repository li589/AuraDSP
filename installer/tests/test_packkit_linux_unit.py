#!/usr/bin/env python3
"""packkit/linux 单测（平台无关，Windows 与 Linux 都能跑）。

与另外两个测试的分工：

- `tests/test_packkit_unit.py`   平台无关内核纯函数
- `windows/tests/test_pack_fixture.py`  Windows CLI 行为契约（真跑四模式）
- 本文件                        Linux 平台层的**纯函数与策略**：命名、档位
                                门禁、ELF 判型、权限规范化、control/changelog
                                正文、钉版表解析、换行规范化

真正的 dpkg-deb / appimagetool 打包不在单测里（需要 Linux），由
`.github/workflows/windows-installer.yml` 的 ubuntu job 端到端跑。

不引入 pytest：本仓测试一律 `python <file>` 直跑。
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

_INSTALLER = Path(__file__).resolve().parents[1]
if str(_INSTALLER) not in sys.path:
    sys.path.insert(0, str(_INSTALLER))

from packkit import naming  # noqa: E402
from packkit.linux import appimage, deb, driver_deb, modes, perms, textio  # noqa: E402
from packkit.linux.release_plan import LinuxPlan  # noqa: E402

FAILURES: list[str] = []
SKIPPED: list[str] = []

# Windows 只有「只读」一个位，os.chmod(0o755) 不产生 POSIX 权限；权限位断言
# 只在 POSIX 上跑（CI 的 ubuntu job 会真正覆盖这一段）。
POSIX = os.name == "posix"


def check(name: str, cond: bool, extra: str = "") -> None:
    print(f"  {'PASS' if cond else 'FAIL'} {name} {extra}")
    if not cond:
        FAILURES.append(name)


def check_mode(name: str, path: Path, want: int) -> None:
    """POSIX 权限断言；非 POSIX 记为 SKIP。"""
    if not POSIX:
        print(f"  SKIP {name}（非 POSIX：无 755/644 概念）")
        SKIPPED.append(name)
        return
    got = path.stat().st_mode & 0o777
    print(f"  {'PASS' if got == want else 'FAIL'} {name} 0o{got:o}")
    if got != want:
        FAILURES.append(name)


# ---------------------------------------------------------------------------
# 命名（03 §5 口径）
# ---------------------------------------------------------------------------

def test_naming() -> None:
    print("== Linux 命名 ==")
    n = naming.LinuxArtifactNames(version="0.1.0", tag="v0.1.0")
    check("deb 名", n.build("deb") == "auradsp_0.1.0_amd64.deb",
          f"→ {n.build('deb')}")
    check("driver deb 名",
          n.build("driver") == "auradsp-driver-loopback_0.1.0_all.deb")
    check("appimage 名",
          n.build("appimage") == "AuraDSP-v0.1.0-x86_64.AppImage")
    check("portable 名",
          n.build("portable") == "AuraDSP-Linux-x64-v0.1.0.tar.gz")
    check("交付名 = 构建名（不改名）",
          all(n.delivery(m) == n.build(m) for m in naming.LINUX_MODES))

    # 产物名不含档位 → 这正是「单档门禁」存在的理由
    check("产物名不含档位后缀",
          "Full" not in n.build("portable") and "Light" not in n.build("portable"))

    try:
        n.build("setup")
        check("未知模式应抛错", False)
    except ValueError:
        check("未知模式应抛错", True)


# ---------------------------------------------------------------------------
# 档位与模式门禁
# ---------------------------------------------------------------------------

def test_modes() -> None:
    print("== 模式与档位门禁 ==")
    check("parse_only 空值=全量", modes.parse_only("") == naming.LINUX_MODES)
    check("parse_only 乱序也按标准顺序",
          modes.parse_only("portable,deb") == ("deb", "portable"))
    try:
        modes.parse_only("deb,rpm")
        check("未知模式应拒绝", False)
    except SystemExit:
        check("未知模式应拒绝", True)

    check("单档通过", modes.resolve_tiers(["light"]) == "light")
    check("重复档位视作一个", modes.resolve_tiers(["full", "full"]) == "full")
    try:
        modes.resolve_tiers(["light", "full"])
        check("多档必须拒绝（否则同名覆盖）", False)
    except SystemExit:
        check("多档必须拒绝（否则同名覆盖）", True)

    plan = LinuxPlan()
    try:
        plan.normalize_tiers(["full", "light"])
        check("编排层同样拒绝多档", False)
    except SystemExit:
        check("编排层同样拒绝多档", True)
    check("默认档位 full", plan.default_tiers() == ("full",))
    check("tier_plans 四模式一次全出",
          plan.tier_plans(["full"]) == (("full", naming.LINUX_MODES),))


# ---------------------------------------------------------------------------
# ELF 判型与权限规范化
# ---------------------------------------------------------------------------

def test_perms() -> None:
    print("== ELF 判型与权限规范化 ==")
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        elf = root / "app"
        elf.write_bytes(b"\x7fELF" + b"\x02\x01\x01" + b"\x00" * 60)
        txt = root / "readme.txt"
        txt.write_text("hello\n", encoding="utf-8")
        empty = root / "empty"
        empty.write_bytes(b"")
        sub = root / "sub"
        sub.mkdir()
        inner = sub / "lib.so"
        inner.write_bytes(b"\x7fELF" + b"\x00" * 32)
        link = root / "link"
        link.symlink_to("app")

        check("ELF magic 命中", perms.is_elf(elf))
        check("文本不误判为 ELF", not perms.is_elf(txt))
        check("空文件不误判", not perms.is_elf(empty))

        # 先打乱权限，验证规范化能纠回
        for p in (elf, txt, empty, inner):
            os.chmod(p, 0o600)
        os.chmod(sub, 0o700)

        stats = perms.normalize_tree(root)
        check_mode("目录 755", sub, 0o755)
        check_mode("ELF 755", elf, 0o755)
        check_mode("文本 644", txt, 0o644)
        check_mode("空文件 644", empty, 0o644)
        check_mode("嵌套 ELF 755", inner, 0o755)
        check("符号链接保持原样", link.is_symlink())
        check("统计含 ELF 2 个", stats["elf"] == 2, f"→ {stats}")
        check("统计计入链接", stats["symlinks"] == 1, f"→ {stats}")

        # 这条是收编的核心收益：不依赖 file 命令也能正确判型
        perms.make_executable(txt)
        check_mode("显式可执行位可恢复", txt, 0o755)


# ---------------------------------------------------------------------------
# control / changelog 正文
# ---------------------------------------------------------------------------

def test_deb_meta() -> None:
    print("== deb 元数据正文 ==")
    ctl = deb.control_text("0.1.0", 12345)
    check("包名", "Package: auradsp\n" in ctl)
    check("版本带 -1 修订号", "Version: 0.1.0-1\n" in ctl)
    check("架构 amd64", "Architecture: amd64\n" in ctl)
    check("Installed-Size 用传入值", "Installed-Size: 12345\n" in ctl)
    check("t64 双写依赖", "libgtk-3-0t64 | libgtk-3-0" in ctl)
    check("Recommends 驱动包", "auradsp-driver-loopback" in ctl)
    check("Description 续行以空格缩进",
          "\n AuraDSP takes over the system audio path" in ctl)
    check("control 以换行结尾", ctl.endswith("\n"))
    check("control 不含 CR", "\r" not in ctl)

    log = deb.changelog_text("0.1.0", "Thu, 20 Nov 2026 14:00:00 +0800")
    check("changelog 首行格式",
          log.startswith("auradsp (0.1.0-1) stable; urgency=medium\n"))
    check("changelog 含签名行",
          " -- AuraDSP Project <3119317786@qq.com>  Thu, 20 Nov 2026" in log)

    dlog = driver_deb.changelog_text("0.1.0", "Thu, 20 Nov 2026 14:00:00 +0800")
    check("驱动包 changelog 版本无 -1 后缀",
          dlog.startswith("auradsp-driver-loopback (0.1.0) stable;"))

    check("postinst 只在 configure 跑",
          '"$1" = "configure"' in deb.POSTINST)
    check("postrm 处理 remove/purge",
          '"remove"' in deb.POSTRM and '"purge"' in deb.POSTRM)
    check("驱动 postinst 尽力加载 snd-aloop",
          "modprobe snd-aloop" in driver_deb.POSTINST)


# ---------------------------------------------------------------------------
# 工具钉版表
# ---------------------------------------------------------------------------

def test_tools_pins() -> None:
    print("== AppImage 钉版表 ==")
    pins = appimage.read_pins()
    check("解析出 appimagetool", "appimagetool" in pins)
    check("解析出 type2-runtime", "type2-runtime" in pins)
    check("哈希为 64 位小写",
          all(len(t.sha256) == 64 and t.sha256 == t.sha256.lower()
              for t in pins.values()))
    check("URL 为 https",
          all(t.url.startswith("https://") for t in pins.values()))

    with tempfile.TemporaryDirectory() as tmp:
        bad = Path(tmp) / "bad.pins"
        bad.write_text("onlythree columns\n", encoding="utf-8")
        try:
            appimage.read_pins(bad)
            check("坏行应报错", False)
        except SystemExit:
            check("坏行应报错", True)

        short = Path(tmp) / "short.pins"
        short.write_text("tool 1.0 deadbeef https://x/y\n", encoding="utf-8")
        try:
            appimage.read_pins(short)
            check("SHA256 长度不足应报错", False)
        except SystemExit:
            check("SHA256 长度不足应报错", True)

    blocking, notes = appimage.preflight()
    check("preflight 返回两段结构", isinstance(blocking, list) and isinstance(notes, list))


# ---------------------------------------------------------------------------
# 换行规范化（真实踩坑）
# ---------------------------------------------------------------------------

def test_textio() -> None:
    print("== 文本换行规范化 ==")
    with tempfile.TemporaryDirectory() as tmp:
        src = Path(tmp) / "a.desktop"
        src.write_bytes(b"[Desktop Entry]\r\nName=AuraDSP\r\n")
        check("读入即 LF", "\r" not in textio.read_text_lf(src))

        dest = Path(tmp) / "b.desktop"
        textio.copy_text_lf(src, dest)
        raw = dest.read_bytes()
        check("输出无 CR", b"\r" not in raw, f"→ {raw!r}")
        check("输出内容保留", b"Name=AuraDSP" in raw)

        bom = Path(tmp) / "bom.desktop"
        bom.write_bytes(b"\xef\xbb\xbf[Desktop Entry]\n")
        check("去 BOM", textio.read_text_lf(bom).startswith("[Desktop Entry]"))


def main() -> int:
    for fn in (test_naming, test_modes, test_perms, test_deb_meta,
               test_tools_pins, test_textio):
        fn()
        print()
    if SKIPPED:
        print(f"（{len(SKIPPED)} 项权限断言在非 POSIX 上跳过；CI ubuntu job 全跑）")
    print(f"{'ALL PASS' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)}")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    raise SystemExit(main())
