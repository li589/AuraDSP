# Send-ToGuest.ps1 - deliver a file to the guest VM desktop from the dev
# machine and verify it landed by hashing it on the guest side.
#
# Rules baked in (learned the hard way):
#   - Direct dev->guest LAN scp with the guest key is the fast path.
#     The Tailscale-relay path needs scp -l 4096 (rate limit) and still
#     truncates randomly on big files; do not use it for installers.
#   - Never trust the scp exit code: verify size + SHA-256 read back
#     from the guest (guest_file_info.py) against the local hash.
#
# Usage:
#   .\Send-ToGuest.ps1 -File D:\temp_desktop\deliver-r66\AuraDSP-Setup.exe `
#       -GuestName AuraDSP-Setup-r66.exe -KnownHostsFile C:\path\to\known_hosts
param(
    [Parameter(Mandatory = $true)][string]$File,
    [Parameter(Mandatory = $true)][string]$GuestName,
    [string]$GuestHost = '192.168.204.129',
    [string]$GuestUser = 'li',
    [string]$Key = 'C:\Users\likr\guest_key',
    [Parameter(Mandatory = $true)][string]$KnownHostsFile,
    [string]$GuestDir = 'Desktop'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $KnownHostsFile)) { throw "known_hosts not found: $KnownHostsFile" }
if (-not (Test-Path $File)) { throw "file not found: $File" }
$local = Get-FileHash $File -Algorithm SHA256
$localSize = (Get-Item $File).Length
"local size=$localSize sha256=$($local.Hash)"
$dest = "{0}@{1}:C:/Users/{2}/{3}/{4}" -f $GuestUser, $GuestHost, $GuestUser, $GuestDir, $GuestName
& scp -i $Key -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KnownHostsFile" -o ConnectTimeout=8 $File $dest
# Verify on the guest side via guest_file_info.py (sits next to this script).
$info = Join-Path $PSScriptRoot 'guest_file_info.py'
& scp -i $Key -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KnownHostsFile" -o ConnectTimeout=8 $info ("{0}@{1}:C:/Users/{2}/guest_file_info.py" -f $GuestUser, $GuestHost, $GuestUser)
$guestPath = "C:\Users\$GuestUser\$GuestDir\$GuestName"
$out = & ssh -i $Key -o StrictHostKeyChecking=yes -o "UserKnownHostsFile=$KnownHostsFile" -o ConnectTimeout=8 ("{0}@{1}" -f $GuestUser, $GuestHost) "python C:\Users\$GuestUser\guest_file_info.py $guestPath"
$out
$guestHash = ($out | Select-String 'sha256 (\w+)').Matches.Groups[1].Value
if ($guestHash -and $guestHash.ToUpper() -eq $local.Hash) {
    "VERIFIED guest hash matches local"
} else {
    throw "guest hash mismatch or unreadable (guest=$guestHash local=$($local.Hash))"
}
