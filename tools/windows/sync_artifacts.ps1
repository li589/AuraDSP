<#
.SYNOPSIS
  AuraDSP artifact one-shot sync/cover script.
  Replaces the manual "cp engine dll to 3 places" shortcut after an incremental
  engine/bridge build.

  Propagates truth-source binaries to three consumer endpoints:
    - test/                                 (Python smoke sandbox; process mode spawns host from here)
    - app\auradsp_app\build\windows\x64\runner\Release   (Flutter build output / runtime)
    - dist\AuraDSP-Windows-x64              (green portable release package)

  Truth sources:
    - core\desktop\windows\out\Release                  auradsp_engine.dll + auradsp_plugin_host.exe
    - core\desktop\windows-drivers\out\Release          auravm/auraasio/auravaio_bridge.dll

  Behavior:
    - Any missing target dir or any single-file copy failure => Write-Warning and skip,
      WITHOUT aborting the rest ("cover a location fails -> warn + skip").
    - Missing source file => skip that file (no abort).
    - Does NOT compile. Compilation is build_engine.sh / build_windows.ps1.

.PARAMETER WhatIf
  Print the plan only; do not write.

.PARAMETER PackZip
  After sync, re-pack dist\AuraDSP-Windows-x64.zip (off by default; the zip is owned by build_windows.ps1 Step6).
#>
param(
  [switch]$WhatIf,
  [switch]$PackZip
)

$ErrorActionPreference = 'Stop'

# Locate repo root（M5：脚本位于 tools/windows/，仓库根为两级父目录）
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Definition
$ProjectRoot = (Resolve-Path (Join-Path $ScriptDir '..\..')).Path

$EngineSrc  = Join-Path $ProjectRoot 'core\desktop\windows\out\Release'
$DriversSrc = Join-Path $ProjectRoot 'core\desktop\windows-drivers\out\Release'

# Truth-source files: (source dir, file name)
$SrcFiles = @(
  @($EngineSrc,  'auradsp_engine.dll'),
  @($EngineSrc,  'auradsp_plugin_host.exe'),
  @($DriversSrc, 'auravm_bridge.dll'),
  @($DriversSrc, 'auraasio_bridge.dll'),
  @($DriversSrc, 'auravaio_bridge.dll')
)

# Consumer endpoints
$Targets = @(
  (Join-Path $ProjectRoot 'test'),
  (Join-Path $ProjectRoot 'app\auradsp_app\build\windows\x64\runner\Release'),
  (Join-Path $ProjectRoot 'dist\AuraDSP-Windows-x64')
)

Write-Host "ProjectRoot: $ProjectRoot"
Write-Host ("Source files: {0} | Target endpoints: {1}" -f $SrcFiles.Count, $Targets.Count)

# Pre-check: report missing sources
foreach ($f in $SrcFiles) {
  $p = Join-Path $f[0] $f[1]
  if (-not (Test-Path $p)) {
    Write-Warning ("Source missing (will skip): {0}" -f $p)
  }
}

$totalPlanned = 0
$okFiles = 0
$skipFiles = 0

foreach ($tgt in $Targets) {
  Write-Host ("`n--- Target: {0}" -f $tgt)
  try {
    if (-not (Test-Path $tgt)) {
      throw ("Target dir missing, skip whole target: {0}" -f $tgt)
    }
    foreach ($f in $SrcFiles) {
      $totalPlanned++
      $src = Join-Path $f[0] $f[1]
      $dst = Join-Path $tgt $f[1]
      if (-not (Test-Path $src)) {
        $skipFiles++
        Write-Warning ("  skip (source missing): {0}" -f $f[1])
        continue
      }
      try {
        if ($WhatIf) {
          Write-Host ("  [WhatIf] {0} -> {1}" -f $src, $dst)
        } else {
          Copy-Item -Path $src -Destination $dst -Force
        }
        $okFiles++
        Write-Host ("  OK  {0}" -f $f[1])
      } catch {
        $skipFiles++
        Write-Warning ("  copy failed (skip this file): {0} -> {1}" -f $f[1], $_)
      }
    }
  } catch {
    Write-Warning ("Target failed (skipped): {0} -> {1}" -f $tgt, $_)
  }
}

Write-Host ("`n=== Sync result ===")
Write-Host ("Planned {0} files | OK {1} | Skipped {2}" -f $totalPlanned, $okFiles, $skipFiles)

# Dedicated: engine -> windows-drivers\out\Release (driver tools/probes load the
# engine from alongside; 2026-10-24 VM test caught this copy silently staying at
# the 10-17 ABI-1 build while the truth source had moved to ABI 2).
$DriversEngDst = Join-Path $DriversSrc 'auradsp_engine.dll'
$EngineDllSrc = Join-Path $EngineSrc 'auradsp_engine.dll'
if ((Test-Path $EngineDllSrc) -and (Test-Path $DriversSrc)) {
  $totalPlanned++
  try {
    Copy-Item -Path $EngineDllSrc -Destination $DriversEngDst -Force
    $okFiles++
    Write-Host ("  OK  auradsp_engine.dll -> windows-drivers\out\Release")
  } catch {
    $skipFiles++
    Write-Warning ("  copy failed (engine -> drivers out): {0}" -f $_)
  }
}

if ($PackZip -and -not $WhatIf) {
  $folder = Join-Path $ProjectRoot 'dist\AuraDSP-Windows-x64'
  $zip = Join-Path $ProjectRoot 'dist\AuraDSP-Windows-x64.zip'
  if (Test-Path $folder) {
    Write-Host ("`nRe-packing release zip: {0}" -f $zip)
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Compress-Archive -Path (Join-Path $folder '*') -DestinationPath $zip -Force
    Write-Host 'Done'
  } else {
    Write-Warning ('Release dir missing, skip packing: {0}' -f $folder)
  }
}

if ($skipFiles -gt 0) {
  Write-Warning ('Some items were skipped; review the warnings above.')
  exit 2
}
exit 0
