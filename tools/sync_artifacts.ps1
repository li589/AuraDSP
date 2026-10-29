# Thin entry kept for stable command lines (M5 platform grouping).
# Implementation lives in tools/windows/sync_artifacts.ps1; args forwarded verbatim.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'windows\sync_artifacts.ps1') @args
exit $LASTEXITCODE
