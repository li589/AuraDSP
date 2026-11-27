param(
    [string]$Path = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'
if (Test-Path -LiteralPath $Path -PathType Container) {
    $files = @(Get-ChildItem -LiteralPath $Path -Filter '*.ps1' -File)
} elseif (Test-Path -LiteralPath $Path -PathType Leaf) {
    $files = @(Get-Item -LiteralPath $Path)
} else {
    Write-Output "ERROR: path not found: $Path"
    exit 1
}

if ($files.Count -eq 0) {
    Write-Output "ERROR: no .ps1 files found under $Path"
    exit 1
}

$failed = $false
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        $file.FullName, [ref]$tokens, [ref]$errors) | Out-Null

    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = $bytes.Length -ge 3 -and
        $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    $isAscii = $true
    foreach ($b in $bytes) {
        if ($b -gt 0x7F) {
            $isAscii = $false
            break
        }
    }

    if ($errors.Count -gt 0) {
        Write-Output ("FAIL {0}: {1}" -f $file.Name, $errors[0].Message)
        $failed = $true
    } elseif (-not ($hasBom -or $isAscii)) {
        Write-Output ("FAIL {0}: non-ASCII content requires a UTF-8 BOM" -f $file.Name)
        $failed = $true
    } else {
        Write-Output ("PASS {0}" -f $file.Name)
    }
}

if ($failed) {
    exit 1
}
exit 0
