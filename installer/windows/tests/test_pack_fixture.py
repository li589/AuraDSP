#!/usr/bin/env python3
"""pack.py 逻辑层 fixture 自测（平台无关，CI 与本地共用）。

用假 staging / 驱动 / ASIO / installer 构建目录跑 pack.py 全模式，
断言产物结构、资源合并语义、Setup 单体格式与错误路径。
真实文件（install_driver.ps1）从仓库本体取，与生产口径一致。
"""

from __future__ import annotations

import hashlib
import os
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path

# 同 pack.py：Windows 旧代码页下 print 中文会崩，先重配标准流。
for _stream in (sys.stdout, sys.stderr):
    try:
        _stream.reconfigure(encoding="utf-8", errors="replace")
    except (AttributeError, ValueError):
        pass

ROOT = Path(__file__).resolve().parents[3]
PACK = ROOT / "installer" / "windows" / "pack.py"
FAILURES: list[str] = []


def check(name: str, cond: bool, extra: str = "") -> None:
    print(f"  {'PASS' if cond else 'FAIL'} {name} {extra}")
    if not cond:
        FAILURES.append(name)


def run_pack(*argv: str) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(PACK), *argv],
                          capture_output=True, text=True,
                          encoding="utf-8", errors="replace")


def make_zip(path: Path, entries: dict[str, bytes]) -> None:
    with zipfile.ZipFile(path, "w", zipfile.ZIP_DEFLATED) as zf:
        for name, data in entries.items():
            zf.writestr(name, data)


def read_zip(path: Path) -> tuple[list[str], dict[str, bytes]]:
    """读 zip 条目名与内容快照并立即关闭句柄。

    Windows 上未关闭的 ZipFile 句柄会让 TemporaryDirectory 清理
    撞 WinError 32（文件被占用删不掉）；Linux 允许删除打开中的
    文件，本地不暴露——CI annotation 实锤过一次。
    """
    with zipfile.ZipFile(path) as zf:
        names = zf.namelist()
        return names, {n: zf.read(n) for n in names}


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
                 {"convolver/space.irs": b"irs", "user_data/secret.txt": b"no",
                  "USER_DATA/case.txt": b"no2"})

        # 产物名必须与 WDK 工程实际输出一致（modern/x64/Release/AuraVaioDriver/）：
        # pack.py 的新鲜度闸门按 AuraVaioDriver.sys + auravaiodriver.cat 判定，
        # 旧名 AuraVaio.* 会让闸门误报"产物缺失"（2026-11-09 CI 实锤）。
        drv = base / "driver"
        drv.mkdir()
        for name in ("AuraVaioDriver.sys", "AuraVaioDriver.inf",
                     "auravaiodriver.cat"):
            (drv / name).write_bytes(b"drv")
        asio = base / "auraasio_driver.dll"
        asio.write_bytes(b"MZ-asio")
        apo_inspect = base / "apo_inspect.exe"
        apo_inspect.write_bytes(b"MZ-inspect")

        inst = base / "installer"
        (inst / "wizard" / "data").mkdir(parents=True)
        (inst / "bootstrapper.exe").write_bytes(b"MZ-shell" + b"\0" * 64)
        (inst / "wizard" / "auradsp_setup.exe").write_bytes(b"MZ-wizard")
        (inst / "wizard" / "flutter_windows.dll").write_bytes(b"MZ-fl")
        (inst / "wizard" / "data" / "app.so").write_bytes(b"so")

        out = base / "out"
        common = ["--staging", str(staging), "--driver-dir", str(drv),
                  "--asio-driver", str(asio), "--apo-inspect", str(apo_inspect),
                  "--installer-build-dir", str(inst),
                  "--packs-dir", str(packs), "--out", str(out)]

        print("== driver 模式 ==")
        r = run_pack("--mode", "driver", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        dz = out / "AuraDSP-Driver-x64-v0.1.0.zip"
        names = read_zip(dz)[0] if dz.exists() else []
        for want in ("AuraVaioDriver.sys", "AuraVaioDriver.inf",
                     "auravaiodriver.cat",
                     "install_driver.ps1", "auraasio_driver.dll",
                     "register_asio.ps1", "install_vaio.ps1", "README.txt",
                     # APO 运维资产随包（2026-11-09 V-03/F4 起）
                     "apo_config.py", "apo_inspect.exe"):
            check(f"含 {want}", want in names)
        check("驱动包含签名教程",
              b"Win7" in read_zip(dz)[1]["README.txt"]
              and b"testsigning" in read_zip(dz)[1]["README.txt"])

        print("== driver 新鲜度闸门（c968a42） ==")
        stale = base / "driver-stale"
        stale.mkdir()
        for name in ("AuraVaioDriver.sys", "auravaiodriver.cat"):
            p = stale / name
            p.write_bytes(b"drv")
            os.utime(p, (0, 0))  # 产物停在 epoch → 必然早于源码
        r = run_pack("--mode", "driver", *common, "--driver-dir", str(stale))
        check("产物比源码旧时拒绝打包", r.returncode != 0
              and "拒绝打包" in (r.stderr or r.stdout))
        part = base / "driver-partial"
        part.mkdir()
        (part / "AuraVaioDriver.sys").write_bytes(b"drv")
        r = run_pack("--mode", "driver", *common, "--driver-dir", str(part))
        check("产物缺失时拒绝打包", r.returncode != 0
              and "产物缺失" in (r.stderr or r.stdout))

        print("== portable core ==")
        r = run_pack("--mode", "portable", "--resources", "core", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        names, contents = read_zip(out / "AuraDSP-Windows-x64-v0.1.0.zip")
        check("含主程序", "auradsp_app.exe" in names)
        check("含核心资源", "resources/liveprog/a.eel" in names)
        check("build-info 有 pack 记录",
              b"pack.resources: core" in contents["build-info.txt"])

        print("== portable addons（合并语义） ==")
        r = run_pack("--mode", "portable", "--resources", "addons", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        names, contents = read_zip(out / "AuraDSP-Windows-x64-v0.1.0.zip")
        check("full 包文件已合并", "resources/liveprog/full.eel" in names)
        check("addon 包文件已合并", "resources/convolver/space.irs" in names)
        check("同名以 full 覆盖", contents["resources/ddc/core.vdc"] == b"full-override")
        check("user_data 被隔离（含大小写变体）",
              not any("user_data" in n.lower() for n in names))

        print("== SHA256SUMS 对账（2026-11-08 审计·预设低3） ==")
        sums = packs / "SHA256SUMS.txt"
        good_lines = []
        for zp in sorted(packs.glob("auradsp-*.zip")):
            digest = hashlib.sha256(zp.read_bytes()).hexdigest()
            good_lines.append(f"{digest}  {zp.name}")
        sums.write_text("\n".join(good_lines) + "\n", encoding="utf-8")
        r = run_pack("--mode", "portable", "--resources", "addons", *common)
        check("哈希相符时合并放行", r.returncode == 0,
              r.stderr.strip()[-200:])
        bad_lines = [ln.replace(ln[:64], "0" * 64, 1)
                     if "auradsp-resource-full" in ln else ln
                     for ln in good_lines]
        sums.write_text("\n".join(bad_lines) + "\n", encoding="utf-8")
        r = run_pack("--mode", "portable", "--resources", "addons", *common)
        check("哈希不符时拒绝合并", r.returncode != 0)
        sums.unlink()

        print("== 资源条目上限（2026-11-08 审计 F5） ==")
        packs2 = base / "packs2"
        packs2.mkdir()
        with zipfile.ZipFile(packs2 / "auradsp-resource-full.zip", "w",
                             zipfile.ZIP_DEFLATED) as zf:
            with zf.open("huge/zeros.bin", mode="w",
                         force_zip64=True) as fh:
                chunk = b"\0" * (64 * 1024 * 1024)
                for _ in range(9):  # 576MiB > 512MiB 单条目上限
                    fh.write(chunk)
        common2 = ["--staging", str(staging), "--driver-dir", str(drv),
                   "--asio-driver", str(asio),
                   "--installer-build-dir", str(inst),
                   "--packs-dir", str(packs2), "--out", str(out)]
        r = run_pack("--mode", "portable", "--resources", "full", *common2)
        check("单条目超 512MiB 时拒绝合并", r.returncode != 0)

        print("== portable none ==")
        r = run_pack("--mode", "portable", "--resources", "none", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        names, _contents = read_zip(out / "AuraDSP-Windows-x64-v0.1.0.zip")
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
        payload_names = pz2.namelist()
        check("ZIP-P 含 payload/auraasio_driver.dll（规范名）",
              "payload/auraasio_driver.dll" in payload_names)
        # 取消勾选驱动也不能过滤 driver/：手动脚本与驱动必须随包保留。
        for rel in ("install_vaio.ps1", "README.txt", "register_asio.ps1",
                    "auraasio_driver.dll", "AuraVaioDriver.inf",
                    "apo_config.py", "apo_inspect.exe"):
            check(f"ZIP-P 恒保留 driver/{rel}",
                  f"payload/driver/{rel}" in payload_names)

        print("== SHA256SUMS 换行钉死 LF（2026-11-09 F4） ==")
        r = run_pack("--mode", "driver", "--sha256sums", *common)
        check("exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        raw = (out / "SHA256SUMS.txt").read_bytes()
        check("SHA256SUMS.txt 无 CR 字节", b"\r" not in raw)
        check("SHA256SUMS.txt 登记 driver 包",
              b"AuraDSP-Driver-x64-v0.1.0.zip" in raw)

        print("== ASIO 别名归一化 ==")
        alias = base / "AuraAsioDriver.dll"
        alias.write_bytes(b"MZ-asio-alias")
        r = run_pack("--mode", "driver", *common,
                     "--asio-driver", str(alias))  # 后置覆盖
        check("别名输入 exit 0", r.returncode == 0, r.stderr.strip()[-200:])
        names = read_zip(dz)[0]
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
