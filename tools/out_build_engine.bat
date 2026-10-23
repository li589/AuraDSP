@echo off
REM Incremental rebuild: engine + plugin host + direct/chain test exes (no stale test_plugin_impulse target).
call "C:\Program Files\Microsoft Visual Studio\18\Community\VC\Auxiliary\Build\vcvarsall.bat" x64
cd /d D:\temp_desktop\Proj\JamesDSP\core\desktop\windows
echo === cmake --build (engine + plugin_host + direct tests) ===
cmake --build out --config Release --target auradsp_engine auradsp_plugin_host test_plugin_direct test_plugin_chain
echo BUILD_EXIT_CODE=%ERRORLEVEL%
