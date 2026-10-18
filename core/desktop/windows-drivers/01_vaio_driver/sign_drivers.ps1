$thumbModern = "F999F91D3A55AA507C512CB5B0AE89B7E4D23D2E"
$thumbLegacy = "0C46E21397FBA2D75BFADA8DE4D7D52FF0B8B645"

$signtool = "C:\Program Files (x86)\Windows Kits\10\bin\10.0.28000.0\x64\signtool.exe"
if (-not (Test-Path $signtool)) {
    $signtool = (Get-ChildItem "C:\Program Files (x86)\Windows Kits\10\bin" -Filter "signtool.exe" -Recurse | Where-Object { $_.FullName -like "*x64*" } | Select-Object -First 1).FullName
}
Write-Host "Using SignTool: $signtool"

$modernTargets = @(
    "core\desktop\windows-drivers\01_vaio_driver\modern\x64\Release\AuraVaioDriver\AuraVaioDriver.sys",
    "core\desktop\windows-drivers\01_vaio_driver\modern\x64\Release\AuraVaioDriver\auravaiodriver.cat"
)

$legacyTargets = @(
    "core\desktop\windows-drivers\01_vaio_driver\legacy\x64\Release\AuraVaioDriverLegacy\AuraVaioDriver.sys",
    "core\desktop\windows-drivers\01_vaio_driver\legacy\x64\Release\AuraVaioDriverLegacy\auravaiodriver.cat"
)

foreach ($t in $modernTargets) {
    if (Test-Path $t) {
        Write-Host "Signing (Modern) $t ..."
        & $signtool sign /v /sm /s My /fd SHA256 /sha1 $thumbModern $t
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to sign $t"
            exit 1
        }
    }
}

foreach ($t in $legacyTargets) {
    if (Test-Path $t) {
        Write-Host "Signing (Legacy) $t ..."
        & $signtool sign /v /s My /fd SHA1 /sha1 $thumbLegacy $t
        if ($LASTEXITCODE -ne 0) {
            Write-Error "Failed to sign $t"
            exit 1
        }
    }
}
Write-Host "All targets signed successfully!"
