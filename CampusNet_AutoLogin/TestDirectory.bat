@echo off
rem ---- Helper: show current / script directory (troubleshooting) ----
chcp 65001 >nul
title Directory Test
echo Current directory : %cd%
echo Script directory  : %~dp0
echo.
echo Switching to script directory...
cd /d "%~dp0"
echo New current dir   : %cd%
echo.
echo Files here:
dir /b
echo.
pause
