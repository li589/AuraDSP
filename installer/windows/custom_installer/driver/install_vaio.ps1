<#
.SYNOPSIS
  AuraDSP bundled AuraVAIO driver installer (self-contained, flat layout).

.DESCRIPTION
  Unlike the repository's development script install_driver.ps1 (which expects
  the source-tree layout modern/x64/<Config>/AuraVaioDriver and a WDK signtool),
  this script works on the shipped flat driver/ folder next to this file.

  Exit codes:
    0  success / status OK
    2  administrator required
    3  test-signing mode required (see README.txt)  <- wizard surfaces a warning
    4  driver package files missing
    5  pnputil failed
    6  devcon failed
    7  devcon.exe missing (DriverStore staged, device node not created)

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install_vaio.ps1 -Action status
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install_vaio.ps1 -Action install
  powershell -NoProfile -ExecutionPolicy Bypass -File .\install_vaio.ps1 -Action uninstall
#>
param(
    [ValidateSet('status', 'install', 'uninstall')] [string]$Action = 'status',
    [switch]$SkipSignCheck,
    [switch]$RemoveTestCert
)

$ErrorActionPreference = 'Stop'
$Root     = $PSScriptRoot
$Inf      = Join-Path $Root 'AuraVaioDriver.inf'
$Cat      = Join-Path $Root 'auravaiodriver.cat'
$Sys      = Join-Path $Root 'AuraVaioDriver.sys'
$Cert     = Join-Path $Root 'AuraDSP_TestSign.cer'
$Devcon   = Join-Path $Root 'devcon.exe'
$Log      = Join-Path $env:TEMP 'auradsp-vaio-install.log'
$HwId     = 'Root\AuraVAIO'
$HwIdAlt  = 'Root\AuraVaioDriver'
$BcdEdit  = "$env:SystemRoot\System32\bcdedit.exe"
$PnpUtil  = "$env:SystemRoot\System32\pnputil.exe"

function Write-Log {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
    try { Add-Content -Path $Log -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Test-Admin {
    return ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
           ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-TestSigning {
    $out = & $BcdEdit /enum '{current}' 2>&1
    return [bool]($out | Select-String -Pattern '^\s*testsigning\s+Yes')
}

function Show-SignGuide {
    Write-Log 'AuraVAIO is TEST-SIGNED. 64-bit Windows (Win7/8.1/10/11) refuses'
    Write-Log 'test-signed kernel drivers unless test-signing is enabled.'
    Write-Log 'Option A (persistent): elevated cmd -> bcdedit /set testsigning on, reboot.'
    Write-Log '  If blocked by Secure Boot: disable Secure Boot in BIOS (suspend BitLocker).'
    Write-Log '  Windows 11: also turn off Core isolation / Memory Integrity if it still fails.'
    Write-Log 'Option B (one boot only): Advanced startup -> Startup Settings -> F7.'
    Write-Log 'See README.txt in this folder for the full guide.'
}

function Install-TestCertificate {
    if (-not (Test-Path $Cert)) {
        Write-Log 'WARN: AuraDSP_TestSign.cer not found; PnP may prompt for publisher trust.'
        return
    }
    & "$env:SystemRoot\System32\certutil.exe" -addstore -f 'Root' $Cert | Out-Null
    & "$env:SystemRoot\System32\certutil.exe" -addstore -f 'TrustedPublisher' $Cert | Out-Null
    Write-Log 'Test certificate imported into Root + TrustedPublisher stores.'
}

function Remove-DevconDevices {
    if (-not (Test-Path $Devcon)) { return }
    foreach ($id in @($HwId, $HwIdAlt)) {
        & $Devcon remove $id 2>&1 | ForEach-Object { Write-Log "  devcon: $_" }
    }
}

function Test-DriverFiles {
    foreach ($p in @($Inf, $Cat, $Sys)) {
        if (-not (Test-Path $p)) {
            Write-Log "ERROR: missing driver file: $p"
            return $false
        }
    }
    return $true
}

Write-Log "AuraVAIO $Action | $Root"

if ($Action -eq 'status') {
    Write-Log "  INF/CAT/SYS present : $(Test-DriverFiles)"
    Write-Log "  devcon.exe present  : $(Test-Path $Devcon)"
    Write-Log "  administrator       : $(Test-Admin)"
    Write-Log "  testsigning         : $(Get-TestSigning)"
    $devs = @(Get-PnpDevice -ErrorAction SilentlyContinue |
              Where-Object { $_.InstanceId -match 'AuraVAIO|AuraVaioDriver' })
    Write-Log "  installed devices   : $($devs.Count)"
    exit 0
}

if (-not (Test-Admin)) {
    Write-Log 'ERROR: run this script as Administrator (install/uninstall).'
    exit 2
}
if (-not (Test-DriverFiles)) { exit 4 }

if ($Action -eq 'install') {
    if (-not $SkipSignCheck -and -not (Get-TestSigning)) {
        Show-SignGuide
        Write-Log 'Stopped: enable test-signing mode and reboot, then run -Action install again.'
        exit 3
    }
    Install-TestCertificate
    Remove-DevconDevices   # clean stale node, matches the DRV convention

    & $PnpUtil /add-driver $Inf /install 2>&1 | ForEach-Object { Write-Log "  pnputil: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: pnputil failed (exit $LASTEXITCODE)."
        exit 5
    }
    if (-not (Test-Path $Devcon)) {
        Write-Log 'WARN: devcon.exe missing. The package is in DriverStore but the'
        Write-Log '      root-enumerated device node was NOT created. Put the WDK'
        Write-Log '      devcon.exe into this folder and re-run -Action install.'
        exit 7
    }
    & $Devcon install $Inf $HwId 2>&1 | ForEach-Object { Write-Log "  devcon: $_" }
    if ($LASTEXITCODE -ne 0) {
        Write-Log "ERROR: devcon install failed (exit $LASTEXITCODE)."
        exit 6
    }
    Write-Log 'Done. Check Device Manager / Windows Sound settings for AuraVAIO.'
    exit 0
}

if ($Action -eq 'uninstall') {
    Remove-DevconDevices
    # Resolve the published oemXX.inf names instead of guessing:
    # pnputil /delete-driver needs published names, not the original
    # INF name. Parse /enum-drivers in per-driver blocks, tolerant of
    # localized (zh-CN / en-US) pnputil key names. The previous
    # English-only line parse silently resolved nothing on Chinese
    # Windows, and the delete-by-original-name fallback is rejected
    # by pnputil -- the package (and its endpoints) survived
    # uninstall (real-machine report 2026-11-09). Same block-parse
    # approach as the dev script's Get-AuraDriverPackages.
    $enumOut = & $PnpUtil /enum-drivers 2>&1 | Out-String
    $drvBlocks = [regex]::Split($enumOut, "(?=发布名称\s*:|Published Name\s*:)")
    $oemNames = @()
    foreach ($b in $drvBlocks) {
        if ($b -notmatch 'auravaiodriver\.inf') { continue }
        $pub = ([regex]::Match($b, '(?:发布名称|Published Name)\s*:\s*(\S+)')).Groups[1].Value
        if ($pub) { $oemNames += $pub }
    }
    # Deletion results are checked per package (review R-D
    # L1): previously $LASTEXITCODE was never read and the
    # final line claimed success unconditionally -- the log
    # now tells the truth per package and in the summary.
    $pkgDeleteFailed = $false
    if ($oemNames.Count -eq 0) {
        Write-Log 'WARN: no published AuraVaioDriver package found in DriverStore (already removed?).'
    } else {
        foreach ($oem in ($oemNames | Select-Object -Unique)) {
            $delOut = & $PnpUtil /delete-driver $oem /uninstall /force 2>&1
            $delCode = $LASTEXITCODE
            $delOut | ForEach-Object { Write-Log "  pnputil($oem): $_" }
            if ($delCode -ne 0) {
                Write-Log "WARN: pnputil /delete-driver $oem failed (exit $delCode)."
                $pkgDeleteFailed = $true
            }
        }
    }

    if ($RemoveTestCert) {
        $thumb = $null
        if (Test-Path $Cert) {
            try {
                $x = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2
                $x.Import($Cert)
                $thumb = $x.Thumbprint
            } catch {
                Write-Log "WARN: cannot read test certificate: $_"
            }
        }
        if ($thumb) {
            foreach ($store in @('Root', 'TrustedPublisher', 'My')) {
                & "$env:SystemRoot\System32\certutil.exe" -delstore $store $thumb 2>&1 |
                    ForEach-Object { Write-Log "  certutil($store): $_" }
            }
            Write-Log 'Test certificate removed from Root / TrustedPublisher / My.'
        } else {
            Write-Log 'WARN: no certificate thumbprint available; skipped cert cleanup.'
        }
    }
    if ($pkgDeleteFailed) {
        Write-Log 'Done with warnings: device node removed, but one or more DriverStore packages could not be deleted (see WARN lines above).'
    } else {
        Write-Log 'Done. Device node and DriverStore package removed.'
    }
    exit 0
}
