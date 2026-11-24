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
# home first). Extra args after -- are passed to the Python script:
#   .\Invoke-GuestScript.ps1 -Script guest_telemetry.py -Tag t -- --samples 40 --interval 0.3
param(
    [Parameter(Mandatory = $true)][string]$Script,
    [Parameter(Mandatory = $true)][string]$Tag,
    [string]$GuestHost = '192.168.204.129',
    [string]$GuestUser = 'li',
    [string]$Key = 'C:\Users\likr\guest_key',
    [string]$WorkDir = 'C:\Users\likr',
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest
)
$ErrorActionPreference = 'Stop'
$src = Join-Path $PSScriptRoot $Script
if (-not (Test-Path $src)) { throw "script not found: $src" }
$resultLog = Join-Path $WorkDir ("guestrun_{0}.log" -f $Tag)
$outLog = Join-Path $WorkDir ("guestrun_{0}_out.log" -f $Tag)
$errLog = Join-Path $WorkDir ("guestrun_{0}_err.log" -f $Tag)
"start $(Get-Date -Format HH:mm:ss) script=$Script tag=$Tag" | Out-File $resultLog
& scp -i $Key -o StrictHostKeyChecking=no -o ConnectTimeout=8 $src ("{0}@{1}:C:/Users/{2}/{3}" -f $GuestUser, $GuestHost, $GuestUser, $Script)
$pyArgs = ''
if ($Rest) { $pyArgs = ' ' + ($Rest -join ' ') }
$remote = "python C:\Users\$GuestUser\$Script$pyArgs"
$p = Start-Process ssh -ArgumentList '-i', $Key, '-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=8', ("{0}@{1}" -f $GuestUser, $GuestHost), $remote -Wait -PassThru -RedirectStandardOutput $outLog -RedirectStandardError $errLog -NoNewWindow
"ssh rc=$($p.ExitCode)" | Out-File $resultLog -Append
Get-Content $outLog -ErrorAction SilentlyContinue | Out-File $resultLog -Append
Get-Content $errLog -ErrorAction SilentlyContinue | Select-Object -First 5 | Out-File $resultLog -Append
"DONE" | Out-File $resultLog -Append
Get-Content $resultLog
