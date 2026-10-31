@echo off
REM Thin entry kept for stable command lines (M5 platform grouping).
call "%~dp0windows\run_smoke_process.bat" %*
exit /b %ERRORLEVEL%
