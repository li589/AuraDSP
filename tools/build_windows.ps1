# Thin entry kept for stable command lines (M5 platform grouping).
# Implementation lives in tools/windows/build_windows.ps1; args forwarded verbatim.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'windows\build_windows.ps1') @args
exit $LASTEXITCODE
