@echo off
set PYTHON="C:\Program Files\Python\Python312\python.exe"
cd /d D:\temp_desktop\Proj\JamesDSP
echo === smoke_plugin_host.py ===
%PYTHON% test\smoke\smoke_plugin_host.py
echo EXIT_HOST=%ERRORLEVEL%
echo.
echo === smoke_plugin_bypass_lifecycle.py ===
%PYTHON% test\smoke\smoke_plugin_bypass_lifecycle.py
echo EXIT_BYPASS=%ERRORLEVEL%
