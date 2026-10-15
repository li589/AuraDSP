<#
.SYNOPSIS
  Dual-track AuraVAIO driver build harness (core/desktop/windows-drivers/01_vaio_driver/).
.DESCRIPTION
  -Track modern (default): VS2026 + WDK 28000, Win10 1809+/Win11 x64.
  -Track legacy           : EWDK 19041 + KMDF 1.11, Win7 SP1/8/8.1.

  Both tracks compile the SAME sources from ../src/ -- the single source of truth.
  Each track has its own project and its own output directory, so they never
  overwrite each other's AuraVaioDriver.sys / .inf / .cat.

  Examples (run from this directory, or pass the absolute path):
    .\build_drivers.ps1                      # modern Debug x64
    .\build_drivers.ps1 -Config Release      # modern Release
    .\build_drivers.ps1 -Track legacy -Config Release

  Kernel driver uses MSBuild, not the parent CMake (that one only builds the
  user-mode 02/03/04/bridge targets).
#>
param([string]$Track="modern", [string]$Config="Debug", [string]$Platform="x64")

# Fix MSB6001: the inherited process environment can contain BOTH 'Path' and 'PATH'
# (case-different). MSBuild's CL.exe task builds a case-insensitive env dictionary and
# throws "已添加项。字典中的关键字:'PATH'所添加的关键字:'Path'" on the duplicate. Collapse
# them to a single entry before launching MSBuild.
# NOTE: the restore must NOT live inside a try block -- once the first spelling is
# removed, Remove-Item on the second throws "path-not-found", and a plain catch would
# skip the restore and leave PATH empty (which breaks any bare-command invocation).
$cleanPath = [string]$env:Path
Remove-Item env:PATH -ErrorAction SilentlyContinue
Remove-Item env:Path -ErrorAction SilentlyContinue
if ($cleanPath) { $env:Path = $cleanPath }

function Find-MsBuild {
    # WDK 28000 pairs with VS2026 (v18); prefer it, then fall back to VS2022.
    $vspath = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
        -version "[18.0,19.0)" -products * -requires Microsoft.Component.MSBuild `
        -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
    if (-not $vspath) {
        $vspath = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
            -version "[17.0,19.0)" -products * -requires Microsoft.Component.MSBuild `
            -find 'MSBuild\**\Bin\MSBuild.exe' 2>$null | Select-Object -First 1
    }
    if (-not $vspath) { Write-Error 'MSBuild not found (VS2026/2022 with Desktop C++ workload).'; exit 1 }
    return $vspath
}

switch ($Track) {
    'modern' {
        $msb  = Find-MsBuild
        $proj = Join-Path $PSScriptRoot 'modern\AuraVaioDriver.vcxproj'
        Write-Host "[modern] msbuild: $msb"
        Write-Host "[modern] project: $proj"
        # SkipPackageVerification=true: InfVerif.dll is absent from WDK 28000.28000 bin;
        # INF verification is a validation step, not required to produce the .sys.
        # DDKPlatform=x64 is passed as a GLOBAL property so WindowsDriver.Shared.Props
        # resolves the ApiValidator universalDDIs\x64 path correctly (the WDK VS
        # integration normally sets DDKPlatform; we supply it for the hand-authored toolset).
        & $msb $proj /p:Configuration=$Config /p:Platform=$Platform /p:DDKPlatform=x64 /p:SkipPackageVerification=true
    }
    'legacy' {
        & (Join-Path $PSScriptRoot 'legacy\build_legacy.ps1') -Config $Config -Platform $Platform
    }
    default { Write-Error "Unknown Track: $Track (use modern | legacy)"; exit 1 }
}
