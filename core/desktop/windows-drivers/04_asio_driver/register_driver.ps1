<#
.SYNOPSIS
  AuraDSP 虚拟 ASIO 驱动注册 / 反注册 / 状态查询

.DESCRIPTION
  COM In-Proc Server DLL (auraasio_driver.dll) 注册管理工具：
  -Action status      只读体检（默认）：DLL 存在性、注册表 HKLM\SOFTWARE\ASIO 与 HKCR\CLSID 状态
  -Action register    注册驱动到系统（需管理员权限，非管理员会自动提示提权）
  -Action unregister  反注册驱动（需管理员权限，清理注册表条目）

.EXAMPLE
  .\register_driver.ps1 -Action status
  .\register_driver.ps1 -Action register
  .\register_driver.ps1 -Action unregister
#>
param(
    [ValidateSet('status', 'register', 'unregister')] [string]$Action = 'status',
    [ValidateSet('Release', 'Debug')] [string]$Config = 'Release'
)

$ErrorActionPreference = 'Stop'

$IsAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

$DriverRoot = $PSScriptRoot
$DllPath = Resolve-Path "$DriverRoot\..\out\$Config\auraasio_driver.dll" -ErrorAction SilentlyContinue

$Clsid = "{4B617572-6144-5350-4153-494F44727631}"
$AsioKeyPath = "HKLM:\SOFTWARE\ASIO\AuraDSP Driver"
$ClsidKeyPath = "Registry::HKEY_CLASSES_ROOT\CLSID\$Clsid"

Write-Host "========================================" -ForegroundColor Cyan
Write-Host "  AuraDSP ASIO Driver Management Tool   " -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host "DLL Target: $DllPath"

if ($Action -eq 'status') {
    Write-Host "`n[1/3] DLL 检查:" -ForegroundColor Yellow
    if ($DllPath -and (Test-Path $DllPath)) {
        Write-Host "  [OK] DLL 存在: $DllPath" -ForegroundColor Green
    } else {
        Write-Host "  [FAIL] DLL 不存在，请先编译 windows-drivers 目标 auraasio_driver" -ForegroundColor Red
    }

    Write-Host "`n[2/3] COM CLSID 注册状态 (HKCR\CLSID\$Clsid):" -ForegroundColor Yellow
    if (Test-Path $ClsidKeyPath) {
        $desc = (Get-ItemProperty -Path $ClsidKeyPath -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
        $inproc = (Get-ItemProperty -Path "$ClsidKeyPath\InprocServer32" -Name "(default)" -ErrorAction SilentlyContinue)."(default)"
        Write-Host "  [OK] CLSID 已注册: $desc" -ForegroundColor Green
        Write-Host "       InprocServer32: $inproc" -ForegroundColor Gray
    } else {
        Write-Host "  [--] 未在 HKCR\CLSID 中注册" -ForegroundColor DarkGray
    }

    Write-Host "`n[3/3] ASIO 宿主枚举注册状态 (HKLM\SOFTWARE\ASIO\AuraDSP Driver):" -ForegroundColor Yellow
    if (Test-Path $AsioKeyPath) {
        $asDesc = (Get-ItemProperty -Path $AsioKeyPath -Name "Description" -ErrorAction SilentlyContinue).Description
        $asClsid = (Get-ItemProperty -Path $AsioKeyPath -Name "CLSID" -ErrorAction SilentlyContinue).CLSID
        Write-Host "  [OK] ASIO 驱动已就绪: $asDesc" -ForegroundColor Green
        Write-Host "       CLSID: $asClsid" -ForegroundColor Gray
    } else {
        Write-Host "  [--] 未在 HKLM\SOFTWARE\ASIO 中注册" -ForegroundColor DarkGray
    }
    Write-Host ""
    exit 0
}

if (-not $DllPath -or -not (Test-Path $DllPath)) {
    Write-Error "找不到 DLL: $DllPath。请先构建项目。"
    exit 1
}

if (-not $IsAdmin) {
    Write-Host "当前不是管理员，正在请求提权执行 -Action $Action..." -ForegroundColor Yellow
    Start-Process powershell -Verb RunAs -ArgumentList "-NoExit", "-File", "`"$PSCommandPath`"", "-Action", $Action, "-Config", $Config
    exit 0
}

if ($Action -eq 'register') {
    Write-Host "正在注册 $DllPath ..." -ForegroundColor Yellow
    $proc = Start-Process "regsvr32.exe" -ArgumentList "/s", "`"$DllPath`"" -Wait -PassThru
    if ($proc.ExitCode -eq 0) {
        Write-Host "[SUCCESS] AuraDSP Driver 注册成功！" -ForegroundColor Green
        Write-Host "外部 DAW（FL Studio, Cubase, Reaper 等）现在可以直接在设备列表中选择 'AuraDSP Driver'。" -ForegroundColor Cyan
    } else {
        Write-Error "regsvr32 注册失败，退出码: $($proc.ExitCode)"
    }
} elseif ($Action -eq 'unregister') {
    Write-Host "正在反注册 $DllPath ..." -ForegroundColor Yellow
    $proc = Start-Process "regsvr32.exe" -ArgumentList "/s", "/u", "`"$DllPath`"" -Wait -PassThru
    if ($proc.ExitCode -eq 0) {
        Write-Host "[SUCCESS] AuraDSP Driver 反注册成功，已清理注册表。" -ForegroundColor Green
    } else {
        Write-Error "regsvr32 反注册失败，退出码: $($proc.ExitCode)"
    }
}
