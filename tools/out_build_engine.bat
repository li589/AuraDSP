@echo off
REM Thin entry kept for stable command lines (M5 platform grouping).
call "%~dp0windows\out_build_engine.bat" %*
exit /b %ERRORLEVEL%
