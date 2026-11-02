@echo off
setlocal
cd /d "%~dp0..\.."

echo === AuraDSP: Build 32-bit Bit-Bridge Host (plugin_host_x86.exe) ===
if not exist core\desktop\windows\build-x86 (
    echo Configuring 32-bit build tree in core/desktop/windows/build-x86...
    cmake -S core\desktop\windows -B core\desktop\windows\build-x86 -G "Visual Studio 18 2026" -A Win32
)

echo Building plugin_host_x86 in Release mode...
cmake --build core\desktop\windows\build-x86 --config Release --target plugin_host_x86

if exist core\desktop\windows\out\Release\plugin_host_x86.exe (
    echo [SUCCESS] plugin_host_x86.exe built successfully.
) else (
    echo [ERROR] plugin_host_x86.exe build failed.
    exit /b 1
)

