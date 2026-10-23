@echo off
set PYTHON="C:\Program Files\Python\Python312\python.exe"
cd /d D:\temp_desktop\Proj\JamesDSP
echo === smoke_plugin_host_process.py ===
%PYTHON% test\smoke\smoke_plugin_host_process.py
echo EXIT_PROCESS=%ERRORLEVEL%
