"""Authenticode 校验与 signtool 签名钩子。

两类门禁，语义不同，别混：

- **载荷签名门**（`check_driver_payload_signed`）：验的是要发出去的
  `driver/` 目录里实际那份 `.cat`。r52 事故就是壳层验过源目录、载荷里
  却是 Inf2Cat 重生成的裸 `.cat`，宾机 testsigning 开着仍报 Code 52。
  发行路径必须拒绝，staging 便利路径只警告。
- **产物签名钩子**（`sign_file`）：给 setup/portable 包做可选代码签名，
  证书未配置时跳过而不是失败。
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path

from ..common import die, log


def _run_ps(ps: str) -> subprocess.CompletedProcess[str]:
    """跨 PowerShell 版本安全运行命令（pwsh 优先，Windows PowerShell 则隔离 PSModulePath）。"""
    exe = shutil.which("pwsh") or shutil.which("powershell") or "powershell"
    env = None
    if exe.lower().endswith("powershell.exe") or exe.lower() == "powershell":
        env = os.environ.copy()
        # 避免 Windows PowerShell 5.1 误加载 PS7 模块导致 FormatXmlUpdateException
        paths = [p for p in env.get("PSModulePath", "").split(";") if "powershell\\7" not in p.lower()]
        env["PSModulePath"] = ";".join(paths)
    return subprocess.run(
        [exe, "-NoProfile", "-Command", ps],
        capture_output=True, text=True, errors="replace", timeout=60, env=env)


def authenticode_info(path: Path) -> tuple[str, str]:
    """经 PowerShell 读 Authenticode 状态与签名者指纹。

    返回 (Status, 指纹)；无签名者时指纹为空串。状态/指纹均为 ASCII，
    中文 Windows 的控制台编码不影响解析。
    """
    ps_path = str(path).replace("'", "''")
    ps = (
        f"$s = Get-AuthenticodeSignature -LiteralPath '{ps_path}'; "
        "if ($s.SignerCertificate) { Write-Output "
        "($s.Status.ToString() + '|' + $s.SignerCertificate.Thumbprint) } "
        "else { Write-Output ($s.Status.ToString() + '|') }"
    )
    r = _run_ps(ps)
    out = (r.stdout or "").strip().splitlines()
    if r.returncode != 0 or not out or "|" not in out[0]:
        raise RuntimeError(f"Get-AuthenticodeSignature 失败: {path}")
    status, _, thumb = out[0].partition("|")
    return status.strip(), thumb.strip()


def cert_thumbprint(path: Path) -> str:
    """读 .cer（DER/PEM 证书文件）的指纹。"""
    ps_path = str(path).replace("'", "''")
    ps = (
        "Write-Output ([System.Security.Cryptography.X509Certificates."
        f"X509Certificate2]::new('{ps_path}').Thumbprint)"
    )
    r = _run_ps(ps)
    out = (r.stdout or "").strip()
    if r.returncode != 0 or not out:
        raise RuntimeError(f"无法读取随包证书指纹: {path}")
    return out.splitlines()[0].strip()


def check_driver_payload_signed(dest: Path, *, warn_only: bool) -> None:
    """随包 driver/ 签名门（r52 事故，2026-11-19）。

    载荷 `.cat` 必须 Authenticode Valid 且有签名者；随包 `.cer` 若在场，
    其指纹必须与签名者一致（装错证书等于没装）；`.cer` 缺失只警告
    （与 install_vaio.ps1 的 WARN 口径一致，官方 sign_drivers.ps1 本就
    不导出 .cer）。

    `warn_only` 仅用于 staging 便利路径与 `--allow-unsigned-driver`
    的 fixture 测试；发行打包严禁降级。
    """
    problems: list[str] = []
    cats = sorted(f for f in dest.iterdir()
                  if f.is_file() and f.suffix.lower() == ".cat")
    vaio_cats = [f for f in cats if "auravaio" in f.name.lower()]
    cat = vaio_cats[0] if vaio_cats else (cats[0] if cats else None)
    signer_thumb = ""

    if cat is None:
        problems.append("随包 driver/ 缺 .cat 目录文件")
    elif sys.platform != "win32":
        log(f"警告: 非 Windows 平台无法验证 .cat 签名，跳过签名门: {cat}")
        return
    else:
        try:
            status, signer_thumb = authenticode_info(cat)
            if status != "Valid" or not signer_thumb:
                problems.append(
                    f"随包 .cat 未签名或签名无效（Status={status}）: {cat.name}"
                    "——Inf2Cat 后必须跑 sign_drivers.ps1 签名，或打包时加 "
                    "--build-driver；未签名的包在目标机报 Code 52、VAIO 不启动")
        except RuntimeError as e:
            problems.append(f"随包 .cat 签名无法验证（{e}）: {cat.name}")

    if not problems and signer_thumb:
        cer = dest / "AuraDSP_TestSign.cer"
        if cer.is_file():
            try:
                cer_thumb = cert_thumbprint(cer)
            except RuntimeError as e:
                cer_thumb = ""
                problems.append(f"随包 AuraDSP_TestSign.cer 指纹无法读取（{e}）")
            if cer_thumb and cer_thumb.upper() != signer_thumb.upper():
                problems.append(
                    "随包 AuraDSP_TestSign.cer 与 .cat 签名者指纹不一致，"
                    "装机导入的证书验不了驱动签名")
        else:
            log("警告: 随包 driver/ 缺 AuraDSP_TestSign.cer，"
                "装机时 PnP 可能提示发布者不受信任（install_vaio 同口径 WARN）")

    if problems:
        if warn_only:
            for p in problems:
                log(f"警告: {p}（staging 不拦截；发行打包仍会拒绝）")
            return
        raise die("VAIO 驱动签名门未通过，拒绝打包:\n  - "
                  + "\n  - ".join(problems))
    if signer_thumb:
        log(f"驱动签名门通过: {cat.name} 签名者 {signer_thumb[:8]}…")


def sign_file(args, path: Path) -> None:
    """可选产物签名：证书未配置时跳过（不阻断打包）。"""
    if not args.sign:
        return
    if os.name != "nt":
        log(f"sign: 非 Windows 平台跳过 {path.name}（钩子仅在 Windows 生效）")
        return
    thumb = args.cert_thumbprint or os.environ.get("AURADSP_CERT_THUMBPRINT", "")
    pfx = os.environ.get("AURADSP_SIGN_PFX", "")
    if not thumb and not pfx:
        log(f"sign: 未配置证书（--cert-thumbprint 或 AURADSP_SIGN_PFX），"
            f"跳过 {path.name}")
        return
    cmd = [args.signtool, "sign", "/fd", "SHA256", "/tr",
           "http://timestamp.digicert.com", "/td", "SHA256"]
    if thumb:
        cmd += ["/sha1", thumb]
    else:
        cmd += ["/f", pfx, "/p", os.environ.get("AURADSP_SIGN_PASS", "")]
    cmd.append(str(path))
    log(f"sign: {path.name}")
    subprocess.run(cmd, check=True)
