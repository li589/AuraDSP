# Invoke-GuestScript.ps1 - run a Python script on the guest VM (vm-win10)
# from the dev machine, with stdout/stderr captured to local log files.
#
# Why this shape: nested interactive ssh sessions through the Tailscale
# relay have repeatedly wedged for tens of minutes. The reliable pattern
# is Start-Process ssh -Wait with redirected output to files, then read
# the files. Run this script itself via Invoke-DevTask.ps1 (schtasks)
# for long jobs so a hung ssh client cannot hold your session hostage.
#
# Usage:
#   .\Invoke-GuestScript.ps1 -Script guest_telemetry.py -Tag tele1 `
#       [-GuestHost 192.168.204.129] [-GuestUser li] [-Key C:\Users\likr\guest_key]
# The script file must sit next to this one (it is copied to the guest
# home first). Python args go in -PyArgs as ONE string (arrays do not
# survive nested ssh/powershell quoting):
#   .\Invoke-GuestScript.ps1 -Script guest_telemetry.py -Tag t -PyArgs '--samples 40 --interval 0.3'
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$GuestHost = '192.168.204.129',
    [string]$GuestUser = 'li',
    [string]$Key = 'C:\Users\likr\guest_key',
    [string]$WorkDir = 'C:\Users\likr',
    [string]$PyArgs = ''
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot $Script
if (-not (Test-Path $src)) { throw "script not found: $src" }
$resultLog = Join-Path $WorkDir ("guestrun_{0}.log" -f $Tag)
$outLog = Join-Path $WorkDir ("guestrun_{0}_out.log" -f $Tag)
$errLog = Join-Path $WorkDir ("guestrun_{0}_err.log" -f $Tag)
"start $(Get-Date -Format HH:mm:ss) script=$Script tag=$Tag" | Out-File $resultLog
& scp -i $Key -o StrictHostKeyChecking=no -o ConnectTimeout=8 $src ("{0}@{1}:C:/Users/{2}/{3}" -f $GuestUser, $GuestHost, $GuestUser, $Script)
# F-7 (review 2026-11-24): a failed scp must stop the run -- otherwise
# ssh happily executes the guest's stale copy from a previous run and
# its output is filed as this run's result.
if ($LASTEXITCODE -ne 0) { throw "scp to guest failed (rc=$LASTEXITCODE); refusing to run a possibly stale copy of $Script" }
$pyArgSuffix = ''
if ($PyArgs) { $pyArgSuffix = ' ' + $PyArgs }
$remote = "python C:\Users\$GuestUser\$Script$pyArgSuffix"
# F-7: ServerAlive bounds a wedged relay to ~60s instead of the
# tens-of-minutes hang this script's header warns about; ConnectTimeout
# alone only covers connection establishment.
$p = Start-Process ssh -ArgumentList '-i', $Key, '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=8', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4', ("{0}@{1}" -f $GuestUser, $GuestHost), $remote -Wait -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog -NoNewWindow
"ssh rc=$($p.ExitCode)" | Out-File $resultLog -Append
Get-Content $outLog -ErrorAction SilentlyContinue | Out-File $resultLog -Append
Get-Content $errLog -ErrorAction SilentlyContinue | Select-Object -First 5 | Out-File $resultLog -Append
"DONE" | Out-File $resultLog -Append
Get-Content $resultLog
