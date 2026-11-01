param(
  [string]$Exe = (Join-Path $PSScriptRoot '..\..\app\auradsp_app\build\windows\x64\runner\Release\auradsp_app.exe'),
  [string]$Log = (Join-Path $env:TEMP 'auradsp_debug_trace.jsonl'),
  [switch]$Tail,
  [switch]$Console
)

# Keep this file ASCII-only: Windows PowerShell 5.1 decodes BOM-less files as
# ANSI, where a multi-byte comment can swallow the following newline and merge
# the next statement into the comment.
$ErrorActionPreference = 'Stop'
if (-not (Test-Path -LiteralPath $Exe)) {
  Write-Error "Not found: $Exe. Build first: cd app/auradsp_app; flutter build windows --release --no-tree-shake-icons"
  exit 1
}

$Log = [System.IO.Path]::GetFullPath($Log)

$existing = Get-Process -Name 'auradsp_app' -ErrorAction SilentlyContinue
if ($existing) {
  Write-Warning 'AuraDSP is already running; single-instance will focus it without --debug. Exit it first.'
}

# One argument string: Start-Process re-splits an array without quoting, so a
# log path containing spaces would break. Quotes here keep the path intact.
$argText = '--debug --debug-log="' + $Log + '"'
if ($Console) { $argText += ' --debug-console' }

Write-Host "Launch: $Exe"
Write-Host "Trace:  $Log"
Write-Host "Operate pages; HUD shows UI/ACK counts. Ctrl+C stops tail."
Write-Host "Args:   $argText"
Start-Process -FilePath $Exe -ArgumentList $argText | Out-Null

if ($Tail) {
  if (-not (Test-Path -LiteralPath $Log)) {
    New-Item -ItemType File -Path $Log -Force | Out-Null
  }
  Get-Content -LiteralPath $Log -Wait -Tail 20
}
