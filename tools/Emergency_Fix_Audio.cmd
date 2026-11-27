@echo off
setlocal EnableExtensions
title Emergency Audio Subsystem Restart

net session >nul 2>&1
if errorlevel 1 (
    echo ERROR: Administrator privileges are required.
    exit /b 1
)

echo ==================================================
echo [Emergency Audio Subsystem Restart]
echo This will stop the audio service and terminate audio processes.
echo Unsaved audio work in other applications may be lost.
echo ==================================================
choice /c YN /n /m "Continue? [Y/N]: "
if errorlevel 2 exit /b 2
if errorlevel 1 goto restart_audio

:restart_audio
set "stop_rc=0"
net stop audiosrv /y
set "stop_rc=%errorlevel%"
if not "%stop_rc%"=="0" (
    echo WARNING: audiosrv stop returned %stop_rc%; attempting recovery anyway.
)

taskkill /f /im audiodg.exe >nul 2>&1
taskkill /f /im auravm_bridge.exe >nul 2>&1
taskkill /f /im vaio_bridge_test.exe >nul 2>&1

net start audiosrv
if errorlevel 1 (
    echo ERROR: audiosrv failed to start.
    exit /b 1
)

sc query audiosrv | findstr /i "RUNNING" >nul
if errorlevel 1 (
    echo ERROR: audiosrv is not running after the restart attempt.
    exit /b 1
)

echo.
echo Audio subsystem restarted.
if /i "%~1"=="--no-pause" exit /b 0
pause
exit /b 0
