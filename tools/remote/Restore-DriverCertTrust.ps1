# Restore-DriverCertTrust.ps1 - re-trust the driver catalog's embedded
# signer certificate on the dev (build) machine.
#
# Incident (2026-11-23, r66): the legacy test cert vanished from every
# store on the dev machine; signtool /a then had no selectable cert,
# signing silently no-opped, and the pack signature gate rejected the
# staged .cat with Status=UnknownError. The public cert is embedded in
# the signed .cat itself, so trust can be restored from it: extract the
# signer certificate and import it into LocalMachine Root +
# TrustedPublisher. Must run ELEVATED (use Invoke-DevTask.ps1 with an
# /RL HIGHEST task, or an admin shell). The guest trusts both project
# certs already and has testsigning on; this is a build-machine fix.
#
# Usage:
#   .\Restore-DriverCertTrust.ps1 -CatPath D:\path\to\auravaiodriver.cat
param(
    [Parameter(Mandatory = $true)][string]$CatPath,
    [string]$Log = 'C:\Users\likr\restore_cert_trust.log'
)
$ErrorActionPreference = 'Stop'
if (-not (Test-Path $CatPath)) { throw "cat not found: $CatPath" }
$sig = Get-AuthenticodeSignature $CatPath
$cert = $sig.SignerCertificate
if (-not $cert) { "no signer cert embedded in $CatPath" | Out-File $Log; exit 1 }
"embedded signer: $($cert.Thumbprint) $($cert.Subject)" | Out-File $Log
$tmp = Join-Path $env:TEMP 'signer_from_cat.cer'
Export-Certificate -Cert $cert -FilePath $tmp -Force | Out-Null
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\Root | Out-Null
Import-Certificate -FilePath $tmp -CertStoreLocation Cert:\LocalMachine\TrustedPublisher | Out-Null
"imported into LocalMachine Root + TrustedPublisher" | Out-File $Log -Append
$s2 = Get-AuthenticodeSignature $CatPath
"cat now Status=$($s2.Status) Signer=$($s2.SignerCertificate.Thumbprint)" | Out-File $Log -Append
"DONE" | Out-File $Log -Append
Get-Content $Log
