# Thin entry kept for stable command lines (M5 platform grouping).
# Implementation lives in the cross-platform tools/sync_artifacts.py
# (S4); args forwarded verbatim.
$ErrorActionPreference = 'Stop'
& (Join-Path $PSScriptRoot 'windows\sync_artifacts.ps1') @args
exit $LASTEXITCODE
