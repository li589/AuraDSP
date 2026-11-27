#!/usr/bin/env python3
"""packkit 内核单测（平台无关，CI 与本地共用）。

与 `windows/tests/test_pack_fixture.py` 分工：
- fixture 测的是**CLI 行为契约**（真跑四种模式、断言产物结构）；
- 本文件测的是**内核纯函数**（命名、轮次、哈希清单、交付归集、Setup 尾块），
  跑得快、失败点精确，改内核先跑这个。

不引入 pytest：本仓测试一律 `python <file>` 直跑，CI 亦同。
"""

from __future__ import annotations

import io
import json
import os
import struct
import sys
import tempfile
import zipfile
from pathlib import Path
from unittest import mock

_INSTALLER = Path(__file__).resolve().parents[1]
if str(_INSTALLER) not in sys.path:
    sys.path.insert(0, str(_INSTALLER))

from packkit import hashing, naming, resources  # noqa: E402
from packkit.archives import zip_dir  # noqa: E402
from packkit.deliver import (  # noqa: E402
    DeliveryItem,
    DeliveryResult,
    make_dir,
    materialize,
    write_sums,
)
from packkit.resources import resource_pack_paths  # noqa: E402
from packkit.version import resolve_version  # noqa: E402
from packkit.windows import installer_build, setup_image, signing  # noqa: E402

FAILURES: list[str] = []


def check(name: str, cond: bool, extra: str = "") -> None:
    print(f"  {'PASS' if cond else 'FAIL'} {name} {extra}")
    if not cond:
        FAILURES.append(name)


# ---------------------------------------------------------------------------
# 命名
# ---------------------------------------------------------------------------

def test_naming() -> None:
    print("== 命名单一真相源 ==")
    n = naming.ArtifactNames("v0.1.0")
    check("driver 构建名", n.build("driver") == "AuraDSP-Driver-x64-v0.1.0.zip")
    check("portable 构建名", n.build("portable") == "AuraDSP-Windows-x64-v0.1.0.zip")
    check("setup 构建名", n.build("setup") == "AuraDSP-Setup-x64-v0.1.0.exe")
    check("driver 交付名",
          n.delivery("driver") == "AuraDSP-Driver-Windows-x64.zip")
    check("setup 交付名", n.delivery("setup") == "AuraDSP-Setup.exe")
    check("full 交付名",
          n.delivery("portable", "full") == "AuraDSP-Windows-x64-Full-v0.1.0.zip")
    check("light 交付名",
          n.delivery("portable", "light") == "AuraDSP-Windows-x64-Light-v0.1.0.zip")
    check("core 交付名退回构建名",
          n.delivery("portable", "core") == n.build("portable"))
    check("交付清单名（带轮次）", naming.ArtifactNames.sums(59) == "SHA256SUMS-r59.txt")
    check("交付清单名（无轮次）", naming.ArtifactNames.sums() == "SHA256SUMS.txt")
    check("full 与 light 交付名不同",
          n.delivery("portable", "full") != n.delivery("portable", "light"),
          "——同名会互相覆盖（r52 教训）")


def test_round() -> None:
    print("== 交付轮次推导 ==")
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        check("空目录从 r1 起", naming.next_round(base) == 1)
        for name in ("deliver-r58", "deliver-r59", "deliver-r54b", "other"):
            (base / name).mkdir()
        check("取最大轮次 +1（忽略 r54b 临时目录）", naming.next_round(base) == 60)
        check("显式轮次优先", naming.next_round(base, 70) == 70)
        check("轮次解析", naming.round_of("deliver-r58") == 58
              and naming.round_of("deliver-r54b") is None)
        check("目录名生成", naming.delivery_dirname(60) == "deliver-r60")


# ---------------------------------------------------------------------------
# 哈希清单
# ---------------------------------------------------------------------------

def test_hashing() -> None:
    print("== 哈希清单（LF / 大小写分域） ==")
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        a = base / "a.bin"
        a.write_bytes(b"alpha")
        b = base / "b.bin"
        b.write_bytes(b"beta")

        sums = base / "SHA256SUMS.txt"
        n = hashing.merge_sha256sums(sums, [a])
        raw = sums.read_bytes()
        check("pack 清单条数", n == 1)
        check("pack 清单无 CR", b"\r" not in raw)
        check("pack 清单小写", hashing.sha256_file(a) in raw.decode())
        n = hashing.merge_sha256sums(sums, [b])
        text = sums.read_text(encoding="utf-8")
        check("合并保留旧条目", n == 2 and "a.bin" in text and "b.bin" in text)
        check("合并后仍无 CR", b"\r" not in sums.read_bytes())
        check("按文件名排序", text.index("a.bin") < text.index("b.bin"))

        delivery = base / "SHA256SUMS-r60.txt"
        hashing.write_delivery_sums(delivery, {"b.bin": hashing.sha256_file(b),
                                               "a.bin": hashing.sha256_file(a)})
        dtext = delivery.read_text(encoding="utf-8")
        first = dtext.splitlines()[0]
        check("交付清单大写", first.split()[0].isupper())
        check("交付清单保持给定顺序", dtext.splitlines()[0].endswith("b.bin"))
        check("交付清单无 CR", b"\r" not in delivery.read_bytes())
        check("read_sha256sums 可回读", hashing.read_sha256sums(delivery)["a.bin"]
              == hashing.sha256_file(a))


# ---------------------------------------------------------------------------
# 交付归集
# ---------------------------------------------------------------------------

def test_delivery() -> None:
    print("== 交付归集 ==")
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        src = base / "src"
        src.mkdir()
        names = naming.ArtifactNames("v0.1.0")
        plans = [(naming.ArtifactNames("v0.1.0").build("setup"), "setup"),
                 (names.build("driver"), "driver"),
                 (names.build("portable"), "portable")]
        items = []
        for build_name, kind in plans:
            p = src / build_name
            p.write_bytes(kind.encode())
            items.append(DeliveryItem(p, names.delivery(kind, "full")))

        dest = make_dir(base, 60)
        files = materialize(dest, items)
        check("四件按交付名落位", [f.name for f in files] == [
            "AuraDSP-Setup.exe",
            "AuraDSP-Driver-Windows-x64.zip",
            "AuraDSP-Windows-x64-Full-v0.1.0.zip",
        ])
        check("来源保留（拷贝非移动）", (src / names.build("setup")).is_file())

        sums = write_sums(dest, 60, files)
        check("清单落盘", sums.is_file() and sums.name == "SHA256SUMS-r60.txt")
        check("清单条数", len(sums.read_text(encoding="utf-8").splitlines()) == 3)

        result = DeliveryResult(dir=dest, files=files, sums=sums)
        check("总字节数", result.total_bytes == sum(f.stat().st_size for f in files))
        check("摘要可复算", result.digests()["AuraDSP-Setup.exe"]
              == hashing.sha256_file(dest / "AuraDSP-Setup.exe"))


# ---------------------------------------------------------------------------
# 资源档位顺序
# ---------------------------------------------------------------------------

def test_resources_order() -> None:
    print("== 资源档位顺序 ==")
    with tempfile.TemporaryDirectory() as td:
        packs = Path(td)
        for name in ("auradsp-resource-core.zip",
                     "auradsp-resource-full.zip",
                     "auradsp-addon-headphone-ddc.zip",
                     "auradsp-addon-community-tuning.zip"):
            (packs / name).write_bytes(b"z")
        light = [p.name for p in resource_pack_paths("light", packs)]
        check("light = core + headphone-ddc", light == [
            "auradsp-resource-core.zip", "auradsp-addon-headphone-ddc.zip"])
        full = [p.name for p in resource_pack_paths("full", packs)]
        check("full 只有 full 包（自足）", full == ["auradsp-resource-full.zip"])
        addons = [p.name for p in resource_pack_paths("addons", packs)]
        check("addons 先 core 后 full 再 addon",
              addons[:2] == ["auradsp-resource-core.zip",
                             "auradsp-resource-full.zip"]
              and addons[-1] == "auradsp-addon-headphone-ddc.zip")
        check("core 无包", resource_pack_paths("core", packs) == [])
        check("none 无包", resource_pack_paths("none", packs) == [])


def _light_validation_result(pack_names: tuple[str, ...]) -> str:
    with tempfile.TemporaryDirectory() as td:
        packs = Path(td)
        for name in pack_names:
            (packs / name).write_bytes(b"z")
        try:
            resources.validate_resource_tier("light", packs)
        except SystemExit:
            return "rejected"
        except AttributeError:
            return "missing-validator"
        return "accepted"


def test_light_resource_completeness() -> None:
    print("== light 资源完整性 ==")
    core = "auradsp-resource-core.zip"
    headphone_ddc = "auradsp-addon-headphone-ddc.zip"
    check("light 缺 headphone-ddc 必须失败",
          _light_validation_result((core,)) == "rejected")
    check("light 缺 core 必须失败",
          _light_validation_result((headphone_ddc,)) == "rejected")
    check("light 两件都缺必须失败",
          _light_validation_result(()) == "rejected")
    check("light 两件齐全必须通过",
          _light_validation_result((core, headphone_ddc)) == "accepted")


# ---------------------------------------------------------------------------
# Setup 尾块
# ---------------------------------------------------------------------------

def _stored_zip(entries: dict[str, bytes]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_STORED) as zf:
        for name, data in entries.items():
            zf.writestr(name, data)
    return buf.getvalue()


def test_setup_image() -> None:
    print("== Setup 尾块与自检 ==")
    check("尾块 80 字节", setup_image.FOOTER_SIZE == 80)
    with tempfile.TemporaryDirectory() as td:
        base = Path(td)
        payload = _stored_zip({"payload/auradsp_app.exe": b"MZ-app"})
        payload_sha = hashing.sha256_bytes(payload)
        wizard = _stored_zip({
            "auradsp_setup.exe": b"MZ-wizard",
            "wizard_manifest.json": json.dumps({
                "payloadSha256": payload_sha,
                "payloadFiles": setup_image.payload_file_manifest(payload),
            }).encode(),
        })
        shell = b"MZ-shell" + b"\0" * 64

        exe = base / "AuraDSP-Setup.exe"
        meta = setup_image.assemble(exe, shell, wizard, payload)
        check("拼装返回载荷哈希", meta["payload_sha256"] == payload_sha)
        check("尾块在文件末尾", exe.read_bytes()[-80:-72] == setup_image.FOOTER_MAGIC)

        ok = setup_image.verify(exe)
        check("自检通过", ok)

        wizard_src = base / "wizard-src"
        wizard_src.mkdir()
        (wizard_src / "auradsp_setup.exe").write_bytes(b"MZ-wizard")
        setup_image.build_wizard_zip(
            wizard_src, base / "built-wizard.zip",
            {"AURADSP_VERSION": "0.1.0",
             "AURADSP_FULL_VERSION": "0.1.0.1"}, payload)
        with zipfile.ZipFile(base / "built-wizard.zip") as built:
            built_manifest = json.loads(built.read("wizard_manifest.json"))
        check("构建器写入真实 ZIP-P 完整清单",
              built_manifest["payloadFiles"] ==
              setup_image.payload_file_manifest(payload))

        bad_wizard = _stored_zip({
            "auradsp_setup.exe": b"MZ-wizard",
            "wizard_manifest.json": json.dumps({
                "payloadSha256": payload_sha, "payloadFiles": [],
            }).encode(),
        })
        bad_manifest = base / "bad-manifest.exe"
        setup_image.assemble(bad_manifest, shell, bad_wizard, payload)
        check("可信清单缺失条目则自检失败", not setup_image.verify(bad_manifest))

        blob = bytearray(exe.read_bytes())
        blob[exe.stat().st_size - 80 - 1] ^= 0xFF  # 改载荷最后一字节
        broken = base / "broken.exe"
        broken.write_bytes(bytes(blob))
        check("载荷被改则自检失败", not setup_image.verify(broken))


def test_version() -> None:
    print("== 版本真相源 ==")
    ver = resolve_version()
    check("四个变量齐备", set(ver) == {"AURADSP_VERSION", "AURADSP_BUILD",
                                       "AURADSP_FULL_VERSION", "AURADSP_TAG"})
    check("tag 与版本一致", ver["AURADSP_TAG"] == f"v{ver['AURADSP_VERSION']}")
    check("full version 含 build",
          ver["AURADSP_FULL_VERSION"] == f"{ver['AURADSP_VERSION']}.{ver['AURADSP_BUILD']}")


def test_installer_unsigned_test_mode() -> None:
    print("== 安装器未签名测试模式 ==")
    args = mock.Mock(cert_thumbprint="")
    with mock.patch.object(installer_build, "resolve_signer_thumbprint",
                           return_value=""), \
            mock.patch.dict(os.environ, {}, clear=True):
        configure = installer_build.installer_configure_args(args)
        check("生产默认显式关闭未签名放行（清除测试缓存）",
              "-DAURADSP_SETUP_UNSIGNED_TEST_ONLY=OFF" in configure)
    with mock.patch.object(installer_build, "resolve_signer_thumbprint",
                           return_value=""), \
            mock.patch.dict(os.environ,
                            {"AURADSP_SETUP_UNSIGNED_TEST_ONLY": "1"},
                            clear=True):
        configure = installer_build.installer_configure_args(args)
        check("显式测试环境启用未签名放行",
              "-DAURADSP_SETUP_UNSIGNED_TEST_ONLY=ON" in configure)
    with mock.patch.object(installer_build, "resolve_signer_thumbprint",
                           return_value="00112233445566778899AABBCCDDEEFF00112233"), \
            mock.patch.dict(os.environ,
                            {"AURADSP_SETUP_UNSIGNED_TEST_ONLY": "1"},
                            clear=True):
        try:
            installer_build.installer_configure_args(args)
        except SystemExit:
            check("测试放行不得与发布者指纹同时启用", True)
        else:
            check("测试放行不得与发布者指纹同时启用", False)


def test_driver_signature_gate() -> None:
    print("== Windows 驱动载荷签名门 ==")
    with tempfile.TemporaryDirectory() as td:
        dest = Path(td)
        cat = dest / "auravaiodriver.cat"
        cat.write_bytes(b"fixture")

        with mock.patch.object(signing.sys, "platform", "linux"), \
                mock.patch.object(signing, "authenticode_info",
                                  side_effect=AssertionError("不得执行真实签名验证")):
            try:
                signing.check_driver_payload_signed(dest, warn_only=False)
            except SystemExit:
                check("非 Windows 正式签名门失败关闭", True)
            else:
                check("非 Windows 正式签名门失败关闭", False)

            try:
                signing.check_driver_payload_signed(dest, warn_only=True)
            except (SystemExit, AssertionError) as e:
                check("非 Windows fixture 仅 warn-only 可绕过", False, f"→ {e}")
            else:
                check("非 Windows fixture 仅 warn-only 可绕过", True)

        cat.unlink()
        try:
            signing.check_driver_payload_signed(dest, warn_only=False)
        except SystemExit:
            check("缺 .cat 正式签名门仍拒绝", True)
        else:
            check("缺 .cat 正式签名门仍拒绝", False)
        try:
            signing.check_driver_payload_signed(dest, warn_only=True)
        except SystemExit as e:
            check("缺 .cat staging 仍只警告", False, f"→ {e}")
        else:
            check("缺 .cat staging 仍只警告", True)

        cat.write_bytes(b"fixture")
        with mock.patch.object(signing.sys, "platform", "win32"), \
                mock.patch.object(signing, "authenticode_info",
                                  return_value=("Valid", "A" * 40)):
            try:
                signing.check_driver_payload_signed(dest, warn_only=False)
            except SystemExit as e:
                check("Windows 有效签名行为保持", False, f"→ {e}")
            else:
                check("Windows 有效签名行为保持", True)


def main() -> int:
    for fn in (test_naming, test_round, test_hashing, test_delivery,
               test_resources_order, test_light_resource_completeness,
               test_setup_image, test_version, test_installer_unsigned_test_mode,
               test_driver_signature_gate):
        fn()
        print()
    print(f"{'ALL PASS' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)}")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    raise SystemExit(main())
