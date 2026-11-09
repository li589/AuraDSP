$vcvars = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" `
    -version "[17.0,19.0)" -find 'VC\Auxiliary\Build\vcvars64.bat' | Select-Object -First 1

if (-not $vcvars) {
    Write-Error "vcvars64.bat not found"
    exit 1
}

# /utf-8：vaio_probe.cpp / dlog_perm_test.cpp 都 include 了
# common/AuraVaioIpc.h（内含中文注释），不显式声明时 MSVC 按系统代码页
# (936) 解析 → C4819「该文件包含不能在当前代码页表示的字符」。
Write-Host "Building vaio_probe.exe / dlog_perm_test.exe via $vcvars..."
$cmd = "`"$vcvars`" && cl.exe /nologo /O2 /W4 /EHsc /MD /std:c++14 /utf-8 " +
       "vaio_probe.cpp /link /out:vaio_probe.exe && " +
       "cl.exe /nologo /O2 /W4 /EHsc /MD /std:c++14 /utf-8 " +
       "dlog_perm_test.cpp /link /out:dlog_perm_test.exe"

cmd.exe /c $cmd

if ($LASTEXITCODE -eq 0) {
    Write-Host "[SUCCESS] Built vaio_probe.exe and dlog_perm_test.exe"
} else {
    Write-Error "Build failed"
}
