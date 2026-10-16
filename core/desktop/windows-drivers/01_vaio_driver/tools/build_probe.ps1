$vcvars = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
    -version "[17.0,19.0)" -find 'VC\Auxiliary\Build\vcvars64.bat' | Select-Object -First 1

if (-not $vcvars) {
    Write-Error "vcvars64.bat not found"
    exit 1
}

Write-Host "Building vaio_probe.exe via $vcvars..."
$cmd = "`"$vcvars`" && cl.exe /nologo /O2 /W4 /EHsc /MD /std:c++14 vaio_probe.cpp /link /out:vaio_probe.exe"

cmd.exe /c $cmd

if ($LASTEXITCODE -eq 0) {
    Write-Host "[SUCCESS] Built vaio_probe.exe"
} else {
    Write-Error "Build failed"
}
