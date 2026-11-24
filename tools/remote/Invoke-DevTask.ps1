# Invoke-DevTask.ps1 - run a PowerShell script on the dev machine via a
# one-shot scheduled task, the reliable channel for long jobs.
#
# Why: an ssh session dying kills its whole child process tree, and
# Start-Process -Wait from an interactive session can hang on inherited
# redirected handles after the child finished. A scheduled task is
# detached from the ssh session; the script writes its own progress /
# result log, which you poll afterwards.
#
# Usage:
#   .\Invoke-DevTask.ps1 -Script C:\Users\likr\gate.ps1 -TaskName gate1
# Then poll the result log your script writes (convention:
# C:\Users\likr\<name>_result.log or a progress file the script owns).
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$TaskName
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Script)) { throw "script not found: $Script" }
$tr = "powershell -NoProfile -ExecutionPolicy Bypass -File $Script"
schtasks /Create /TN $TaskName /TR $tr /SC ONCE /ST 23:59 /F | Out-Null
if ($LASTEXITCODE -ne 0) { throw "schtasks create failed rc=$LASTEXITCODE" }
schtasks /Run /TN $TaskName | Out-Null
if ($LASTEXITCODE -ne 0) { throw "schtasks run failed rc=$LASTEXITCODE" }
"task $TaskName started for $Script"
