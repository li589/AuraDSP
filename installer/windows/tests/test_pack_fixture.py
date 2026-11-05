#!/usr/bin/env python3
"""pack.py 逻辑层 fixture 自测（平台无关，CI 与本地共用）。

用假 staging / 驱动 / ASIO / installer 构建目录跑 pack.py 全模式，
断言产物结构、资源合并语义、Setup 单体格式与错误路径。
真实文件（install_driver.ps1）从仓库本体取，与生产口径一致。
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
PACK = ROOT / "installer" / "windows" / "pack.py"
FAILURES: list[str] = []


def check(name: str, cond: bool, extra: str = "") -> None:
    print(f"  {'PASS' if cond else 'FAIL'} {name} {extra}")
    if not cond:
        FAILURES.append(name)


def run_pack(*argv: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(PACK), *argv],
                          capture_output=True, text=True)


def make_zip(path: Path, entries: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries.items():
            zf.writestr(name, data)


def main() -> int:
    with tempfile.TemporaryDirectory(prefix="auradsp-packtest-") as td:
        base = Path(td)
        # ---- fixture 输入 ----
        staging = base / "staging"
        (staging / "data").mkdir(parents=True)
        (staging / "resources" / "liveprog").mkdir(parents=True)
        (staging / "resources" / "ddc").mkdir(parents=True)
        (staging / "auradsp_app.exe").write_bytes(b"MZ-app")
        (staging / "auradsp_engine.dll").write_bytes(b"MZ-engine")
        (staging / "data" / "x.txt").write_text("x")
        (staging / "resources" / "manifest.json").write_text("{}")
        (staging / "resources" / "liveprog" / "a.eel").write_text("core")
        (staging / "resources" / "ddc" / "core.vdc").write_bytes(b"core")

        packs = base / "packs"
        packs.mkdir()
        make_zip(packs / "auradsp-resource-full.zip",
                 {"liveprog/full.eel": b"full", "ddc/core.vdc": b"full-override"})
        make_zip(packs / "auradsp-addon-test.zip",
                 {"convolver/space.irs": b"irs", "user_data/secret.txt": b"no"})

        drv = base / "driver"
        drv.mkdir()
        for ext in ("sys", "inf", "cat"):
            (drv / f"AuraVaio.{ext}").write_bytes(b"drv")
        asio = base / "auraasio_driver.dll"
        asio.write_bytes(b"MZ-asio")

        inst = base / "installer"
        (inst / "wizard" / "data").mkdir(parents=True)
        (inst / "bootstrapper.exe").write_bytes(b"MZ-shell" + b"\0" * 64)
        (inst / "wizard" / "auradsp_setup.exe").write_bytes(b"MZ-wizard")
        (inst / "wizard" / "flutter_windows.dll").write_bytes(b"MZ-fl")
        (inst / "wizard" / "data" / "app.so").write_bytes(b"so")

        out = base / "out"
        common = ["--staging", str(staging), "--driver-dir", str(drv),
                  "--asio-driver", str(asio), "--installer-build-dir", str(inst),
                  "--packs-dir", str(packs), "--out", str(out)]

        print("== driver 模式 ==")
        r = run_pack("--mode", "driver", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        dz = out / "AuraDSP-Driver-x64-v0.1.0.zip"
        names = zipfile.ZipFile(dz).namelist() if dz.exists() else []
        for want in ("AuraVaio.sys", "AuraVaio.inf", "AuraVaio.cat",
                     "install_driver.ps1", "auraasio_driver.dll",
                     "register_asio.ps1"):
            check(f"含 {want}", want in names)

        print("== portable core ==")
        r = run_pack("--mode", "portable", "--resources", "core", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        pz = zipfile.ZipFile(out / "AuraDSP-Windows-x64-v0.1.0.zip")
        names = pz.namelist()
        check("含主程序", "auradsp_app.exe" in names)
        check("含核心资源", "resources/liveprog/a.eel" in names)
        check("build-info 有 pack 记录",
              b"pack.resources: core" in pz.read("build-info.txt"))

        print("== portable addons（合并语义） ==")
        r = run_pack("--mode", "portable", "--resources", "addons", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        pz = zipfile.ZipFile(out / "AuraDSP-Windows-x64-v0.1.0.zip")
        names = pz.namelist()
        check("full 包文件已合并", "resources/liveprog/full.eel" in names)
        check("addon 包文件已合并", "resources/convolver/space.irs" in names)
        check("同名以 full 覆盖", pz.read("resources/ddc/core.vdc") == b"full-override")
        check("user_data 被隔离", not any("user_data" in n for n in names))

        print("== portable none ==")
        r = run_pack("--mode", "portable", "--resources", "none", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        pz = zipfile.ZipFile(out / "AuraDSP-Windows-x64-v0.1.0.zip")
        names = pz.namelist()
        check("资源已剔除", "resources/liveprog/a.eel" not in names)
        check("manifest 保留", "resources/manifest.json" in names)

        print("== setup 模式 + verify ==")
        r = run_pack("--mode", "setup", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        setup = out / "AuraDSP-Setup-x64-v0.1.0.exe"
        check("setup exe 存在", setup.is_file())
        r = run_pack("--verify", str(setup))
        check("--verify 通过", r.returncode == 0, r.stdout.strip()[-200:])
        import io as _io, struct as _st
        blob = setup.read_bytes()
        magic, fmt, _fl, ow, lw, op, lp, _sha = _st.unpack(
            "<8sIIQQQQ32s", blob[-80:])
        wz = zipfile.ZipFile(_io.BytesIO(blob[ow:ow + lw]))
        check("ZIP-W 全条目 STORED（引导壳零依赖解包）",
              all(i.compress_type == zipfile.ZIP_STORED
                  for i in wz.infolist()))
        pz2 = zipfile.ZipFile(_io.BytesIO(blob[op:op + lp]))
        check("ZIP-P 含 payload/auraasio_driver.dll（规范名）",
              "payload/auraasio_driver.dll" in pz2.namelist())

        print("== ASIO 别名归一化 ==")
        alias = base / "AuraAsioDriver.dll"
        alias.write_bytes(b"MZ-asio-alias")
        r = run_pack("--mode", "driver", *common,
                     "--asio-driver", str(alias))  # 后置覆盖
        check("别名输入 exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        names = zipfile.ZipFile(dz).namelist()
        check("驱动包内归一化为规范名",
              "auraasio_driver.dll" in names
              and "AuraAsioDriver.dll" not in names)

        print("== 错误路径 ==")
        r = run_pack("--mode", "setup", *common,
                     "--asio-driver", str(base / "missing.dll"))  # 后置覆盖取最后值
        check("缺 ASIO 时 setup 报错", r.returncode != 0)
        r = run_pack("--mode", "portable", "--version", "100.1.1", *common)
        check("非法版本被拒", r.returncode != 0)
        r = run_pack("--mode", "portable", "--version", "9.9.9", *common)
        check("版本覆盖生效", r.returncode == 0
              and (out / "AuraDSP-Windows-x64-v9.9.9.zip").exists())

    print(f"\n{'ALL PASS' if not FAILURES else 'FAILURES: ' + ', '.join(FAILURES)}")
    return 0 if not FAILURES else 1


if __name__ == "__main__":
    raise SystemExit(main())
