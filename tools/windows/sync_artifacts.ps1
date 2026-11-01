<#
.SYNOPSIS
  Thin wrapper (S4): implementation moved to the cross-platform
  tools/sync_artifacts.py; this file only forwards -WhatIf / -PackZip
  so existing Windows command lines keep working unchanged.
#>
param(
  [switch]$WhatIf,
  [switch]$PackZip
)

$ErrorActionPreference = 'Stop'
$Script = Join-Path $PSScriptRoot '..\sync_artifacts.py'
$PyArgs = @()
if ($WhatIf) { $PyArgs += '--what-if' }
if ($PackZip) { $PyArgs += '--pack-zip' }

if (Get-Command python3 -ErrorAction SilentlyContinue) {
  & python3 $Script @PyArgs
} elseif (Get-Command python -ErrorAction SilentlyContinue) {
  & python $Script @PyArgs
} elseif (Get-Command py -ErrorAction SilentlyContinue) {
  & py -3 $Script @PyArgs
} else {
  Write-Error 'No Python interpreter found (python3 / python / py).'
  exit 1
}
exit $LASTEXITCODE
