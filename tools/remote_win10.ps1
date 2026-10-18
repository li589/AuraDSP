param(
    [Parameter(Mandatory=$true)]
    [string]$Command
)
$bytes = [System.Text.Encoding]::Unicode.GetBytes($Command)
$enc = [Convert]::ToBase64String($bytes)
ssh li@192.168.204.129 powershell -NoProfile -EncodedCommand $enc
