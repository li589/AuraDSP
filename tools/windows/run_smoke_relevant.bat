@echo off
set PYTHON="C:\Program Files\Python\Python312\python.exe"
cd /d D:\temp_desktop\Proj\JamesDSP
echo === smoke_plugin_host.py ===
%PYTHON% test\smoke\smoke_plugin_host.py
set RC_HOST=%ERRORLEVEL%
echo EXIT_HOST=%RC_HOST%
echo.
echo === smoke_plugin_bypass_lifecycle.py ===
%PYTHON% test\smoke\smoke_plugin_bypass_lifecycle.py
set RC_BYPASS=%ERRORLEVEL%
echo EXIT_BYPASS=%RC_BYPASS%
if not "%RC_HOST%"=="0" exit /b %RC_HOST%
exit /b %RC_BYPASS%
