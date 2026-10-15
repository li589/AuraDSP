<#
.SYNOPSIS
  双轨驱动构建 harness（位于 core/desktop/windows-drivers/）。
.DESCRIPTION
  -Track modern（默认）：VS2026 + WDK 28000，Win10 1809+/Win11 x64，日常开发主战场。
  -Track legacy        ：EWDK 19041 + KMDF 1.11，Win7 SP1/8/8.1（见 01_vaio_driver_legacy/build_legacy.ps1）。
  例：
    .\build_drivers.ps1                       # modern Debug x64
    .\build_drivers.ps1 -Config Release        # modern Release
    .\build_drivers.ps1 -Track legacy -Config Release
  注意：内核驱动（01_vaio_driver）走 MSBuild，不并入父级 CMake；用户态 02/03/04/05 仍走 CMake。
#>
param([string]$Track="modern", [string]$Config="Debug", [string]$Platform="x64")

function Find-MsBuild {
    $vspath = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
        -version "[17.0,19.0)" -products * -requires Microsoft.Component.MSBuild `
        -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
    if (-not $vspath) { Write-Error '未找到 VS2022/2026 的 MSBuild，请确认 VS2026 已装且含“使用 C++ 的桌面开发”工作负载。'; exit 1 }
    return $vspath
}

switch ($Track) {
    'modern' {
        $msb  = Find-MsBuild
        $proj = Join-Path $PSScriptRoot '01_vaio_driver\AuraVaioDriver.vcxproj'
        Write-Host "[modern] msbuild: $msb" -ForegroundColor Cyan
        & $msb $proj /p:Configuration=$Config /p:Platform=$Platform
    }
    'legacy' {
        & (Join-Path $PSScriptRoot '01_vaio_driver_legacy\build_legacy.ps1') -Config $Config -Platform $Platform
    }
    default { Write-Error "未知 Track: $Track（应为 modern | legacy）"; exit 1 }
}
