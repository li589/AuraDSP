<#
.SYNOPSIS
  LEGACY 线构建脚本：在 EWDK 19041 环境内构建 AuraVAIO 驱动（Win7 SP1/8/8.1 兼容，KMDF 1.11）。
.DESCRIPTION
  复用 modern 主线的同一份源代码（driver.cpp / device.cpp）。
  前置：
    1) 下载 EWDK 19041 ISO（learn.microsoft.com → Other WDK Downloads → Windows 10 2004 (VB) 19041.5738 → EWDK）。
    2) 挂载 ISO（或解压）到某目录，并设置环境变量：
         $env:AURA_EWDK19041 = "<挂载盘符或解压目录>"   # 该目录需含 LaunchBuildEnv.cmd
  说明：
    - WindowsTargetPlatformVersion 覆盖为 10.0.19041.0（与 EWDK 自带 SDK/WDK build 号一致）。
    - KMDF 目标版本 1.11：在 VS/msbuild 的 Driver Model Settings 中将
      “KMDF Version Minor (Target Version)” 设为 11；也可在 vcxproj 的 Driver 配置里写
      <KmdfVersionMinorTarget>11</KmdfVersionMinorTarget>。Win7 上限即 1.11。
    - 已知坑：EWDK/VS2019 Build Tools 上 WDK 的 MSBuild targets 若报
      MSB8020 "WindowsKernelModeDriver10.0 cannot be found"，需把
      %KitsRoot10%\Vsix\VS2019\WDK.vsix 内 $MSBuild\Microsoft 解包进
      BuildTools\MSBuild\Microsoft（OSR 社区 workaround）。EWDK 自带 Build Tools 一般已含。
#>
param([string]$Config="Release", [string]$Platform="x64")

$ewdk = $env:AURA_EWDK19041
if (-not $ewdk) {
    Write-Error '请先挂载 EWDK 19041 并设置 $env:AURA_EWDK19041 = "<挂载盘符或解压目录>"'
    exit 1
}
$launch = Join-Path $ewdk 'LaunchBuildEnv.cmd'
if (-not (Test-Path $launch)) { Write-Error "找不到 $launch"; exit 1 }

$proj = Join-Path $PSScriptRoot '..\01_vaio_driver\AuraVaioDriver.vcxproj'
if (-not (Test-Path $proj)) { Write-Error "找不到 $proj"; exit 1 }

# 在 EWDK 环境内执行 msbuild（覆盖目标平台版本为 19041）
$cmd = "call `"$launch`" && msbuild `"$proj`" /p:Configuration=$Config /p:Platform=$Platform /p:WindowsTargetPlatformVersion=10.0.19041.0 /p:TargetVersion=Windows10"
Write-Host "[legacy] 在 EWDK 19041 环境构建：$cmd" -ForegroundColor Cyan
cmd /c $cmd
