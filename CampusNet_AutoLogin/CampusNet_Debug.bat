@echo off
rem ============================================================
rem  CampusNet_Debug.bat - debug launcher
rem  Starts PowerShell with -NoExit so the window never closes,
rem  even when the script fails. Read the error, then close it.
rem ============================================================
setlocal
chcp 65001 >nul
title CampusNet DEBUG (window stays open)
cd /d "%~dp0"

echo DEBUG mode: the PowerShell window will stay open even after the
echo script finishes or fails. Read the error above, then close it.
echo.

powershell.exe -NoProfile -ExecutionPolicy Bypass -NoExit -File "%~dp0CampusNet_Login.ps1"

endlocal
exit /b 0
