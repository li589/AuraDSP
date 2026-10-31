@echo off
REM Incremental rebuild via root preset: engine + plugin host + direct/chain test exes.
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat" x64
cd /d D:\temp_desktop\Proj\JamesDSP
echo === cmake --build --preset windows-x64-release (engine + plugin_host + direct tests) ===
cmake --build --preset windows-x64-release --target auradsp_engine auradsp_plugin_host test_plugin_direct test_plugin_chain
set RC=%ERRORLEVEL%
echo BUILD_EXIT_CODE=%RC%
exit /b %RC%
