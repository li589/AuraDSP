"""随包 `driver/` 目录组装（driver zip / portable / setup / staging 共用）。

这个目录是「装不上驱动」类事故的集中地，因此有若干硬约束，改动前请先读：

- **devcon.exe 必须自 WDK 补齐**：它不是驱动构建产物，历史上靠手工放进
  构建目录；干净重编即丢失，而丢失时打包不报错、装机时 install_vaio.ps1
  才以退出码 7 失败（2026-11-14 宾机实测：r31/r32 两批包均缺）。
- **`.ps1` 一律带 UTF-8 BOM**：PowerShell 5.1 对无 BOM 的 .ps1 按系统
  ANSI（中文 Windows = GBK）解码，中文串字节错位可吞引号导致解析期
  ParserError、脚本永不执行（register_asio.ps1 实测中招）。
- **模板不得含 CR 字节**：模板是普通（非 raw）Python 字符串，注释/路径里
  的单反斜杠 + r 会被转义成真 CR，把注释行劈开、后半截被 PS 当命令执行
  （2026-11-13 实测：随包脚本三处 \\r 事故，BOM 完好但脚本整体失效）。
- **签名门验 dest 而不是源目录**：发出去的是 dest 的内容。
"""

from __future__ import annotations

from pathlib import Path

from ..common import die, log
from ..paths import DRIVER_TEMPLATE_DIR
from .driver import DRIVER_PAYLOAD_SUFFIXES
from .signing import check_driver_payload_signed
from .toolchain import ApoAssets, ASIO_DLL_NAME

# 随包手动安装资产（入库模板；driver zip 与 Setup 载荷共用同一组装函数）。
# 用户取消勾选驱动时这些文件仍留在 安装目录/driver/，供事后手动补装。
DRIVER_TEMPLATE_FILES = ("install_vaio.ps1", "README.txt")

BOM = b"\xef\xbb\xbf"

REGISTER_ASIO_PS1 = """\
# AuraDSP ASIO 驱动注册/反注册（pack.py 生成，随驱动包分发）
# 用法（管理员 PowerShell）：
#   .\\register_asio.ps1            注册 auraasio_driver.dll
#   .\\register_asio.ps1 -Unregister 反注册
# -ResultFile：把成败 JSON 写回指定文件（提权进程的输出
# 跨不过 UAC 边界，App 靠此文件读真实失败原因）。
param([switch]$Unregister, [string]$ResultFile = "")
$ErrorActionPreference = "Stop"
function Write-AsioResult([bool]$Ok, [string]$Message) {
  if ($ResultFile) {
    @{ ok = $Ok; message = $Message } | ConvertTo-Json -Compress |
      Set-Content -LiteralPath $ResultFile -Encoding UTF8
  }
}
try {
  $dll = Join-Path $PSScriptRoot "auraasio_driver.dll"
  if (-not (Test-Path $dll)) {
    $alt = Join-Path (Split-Path -Parent $PSScriptRoot) "auraasio_driver.dll"
    if (Test-Path $alt) { $dll = $alt }
  }
  if (-not (Test-Path $dll)) { throw "auraasio_driver.dll 不在脚本目录或其上级目录" }
  $regsvr = "$env:SystemRoot\\System32\\regsvr32.exe"
  # DLL 路径必须带引号（第六轮项 2 实证）：Start-Process 的
  # -ArgumentList 数组以空格拼接、不自动加引号，安装路径含
  # 空格（默认 Program Files）时路径被拆断、regsvr32 必败。
  $args = if ($Unregister) { @("/s", "/u", "`"$dll`"") } else { @("/s", "`"$dll`"") }
  $p = Start-Process $regsvr -ArgumentList $args -Wait -PassThru
  if ($p.ExitCode -ne 0) { throw "regsvr32 退出码 $($p.ExitCode)" }
  $done = "AuraASIO $(if ($Unregister) { '反注册' } else { '注册' })完成: $dll"
  Write-AsioResult $true $done
  Write-Host $done
} catch {
  Write-AsioResult $false $_.Exception.Message
  throw
}
"""


def copy2_overwrite(src: Path, dst: Path) -> None:
    """覆盖拷贝到可能已存在的目标。

    build_windows.ps1 Step 5 会先用本模块补齐 dist 的 driver/；随后
    portable/setup 复制 staging 再组装时，目标里的 devcon.exe 带 ReadOnly
    （copy2 保留源属性），裸 open(dst,'wb') 会 PermissionError。这里先清
    只读再删除，保证重复补齐幂等。
    """
    if dst.exists():
        try:
            dst.chmod(0o666)
        except OSError:
            pass
        dst.unlink()
    import shutil

    shutil.copy2(src, dst)


def find_wdk_devcon() -> Path | None:
    """WDK 的 x64 devcon.exe（版本目录取最高）。

    随包 driver/ 创建 VAIO 设备节点的必需工具。找不到返回 None，由调用方
    die——不许产出装不了 VAIO 的包。
    """
    kits = Path(r"C:\Program Files (x86)\Windows Kits\10\Tools")
    if not kits.is_dir():
        return None
    candidates = sorted(kits.glob("*/x64/devcon.exe"), reverse=True)
    return candidates[0] if candidates else None


def _copy_driver_binaries(dest: Path, driver_dir: Path) -> int:
    copied = 0
    for f in sorted(driver_dir.iterdir()):
        if not f.is_file():
            continue
        if f.suffix.lower() in DRIVER_PAYLOAD_SUFFIXES or f.name.lower() == "devcon.exe":
            copy2_overwrite(f, dest / f.name)
            copied += 1
    return copied


def _ensure_devcon(dest: Path) -> None:
    if (dest / "devcon.exe").exists():
        return
    wdk_devcon = find_wdk_devcon()
    if wdk_devcon is None:
        raise die("随包 driver/ 缺 devcon.exe：驱动构建目录与 WDK Tools "
                  "均未找到，VAIO 安装将无法创建设备节点（退出码 7）；"
                  "请安装 WDK，或将 x64 devcon.exe 放进驱动构建目录后重打")
    copy2_overwrite(wdk_devcon, dest / "devcon.exe")
    log(f"driver: devcon.exe 自 WDK 补齐（{wdk_devcon}）")


def _write_register_asio_ps1(dest: Path) -> None:
    raw = REGISTER_ASIO_PS1.encode("utf-8")
    if b"\r" in raw:
        raise die("register_asio.ps1 模板含 CR 字节（\\r 转义事故），拒绝打包")
    (dest / "register_asio.ps1").write_bytes(BOM + raw)


def _copy_templates(dest: Path) -> None:
    for name in DRIVER_TEMPLATE_FILES:
        src = DRIVER_TEMPLATE_DIR / name
        if not src.is_file():
            raise die(f"缺随包驱动模板: {src}")
        if name.lower().endswith(".txt"):
            # README 以 UTF-8 BOM 落盘，兼容旧版记事本读取中文。
            (dest / name).write_text(
                src.read_text(encoding="utf-8"), encoding="utf-8-sig")
        elif name.lower().endswith(".ps1"):
            raw = src.read_bytes()
            (dest / name).write_bytes(raw if raw.startswith(BOM) else BOM + raw)
        else:
            copy2_overwrite(src, dest / name)


def stage_driver_files(
    dest: Path,
    driver_dir: Path,
    asio: Path,
    install_ps1: Path,
    apo: ApoAssets,
    *,
    include_asio_dll: bool,
    sign_warn_only: bool = False,
) -> int:
    """组装随包 driver/：驱动产物 + 证书 + devcon + 手动脚本 + APO 四件。

    返回拷贝的驱动产物数；缺模板直接失败（避免产出不可手动安装的包）。
    """
    if not install_ps1.is_file():
        raise die(f"缺 install_driver.ps1: {install_ps1}")

    dest.mkdir(parents=True, exist_ok=True)
    copied = _copy_driver_binaries(dest, driver_dir)
    if copied == 0:
        raise die(f"驱动目录没有任何 .sys/.inf/.cat/.cer: {driver_dir}")
    _ensure_devcon(dest)

    # 签名门在组装点验实际载荷（dest 里的 .cat/.cer）。
    check_driver_payload_signed(dest, warn_only=sign_warn_only)

    copy2_overwrite(install_ps1, dest / install_ps1.name)
    # APO 运维资产：附加/状态工具 + APO 本体 + 端点刷新，与手动安装资产同组。
    copy2_overwrite(apo.config_exe, dest / apo.config_exe.name)
    copy2_overwrite(apo.apo_dll, dest / apo.apo_dll.name)
    copy2_overwrite(apo.inspect, dest / apo.inspect.name)
    # 真处理引擎与 AuraApo.dll 同级落位（APO 的 D1 搜索首选）。
    copy2_overwrite(apo.engine_dll, dest / apo.engine_dll.name)

    if include_asio_dll:
        copy2_overwrite(asio, dest / ASIO_DLL_NAME)

    _write_register_asio_ps1(dest)
    _copy_templates(dest)
    return copied
