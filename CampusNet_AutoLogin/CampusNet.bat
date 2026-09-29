@echo off
rem ============================================================
rem  CampusNet.bat - main launcher (Ethernet / Wi-Fi)
rem  - Window ALWAYS stays open (never flashes and disappears)
rem  - Full console output goes to logs\<date>\CampusNet_Launcher.log
rem    (written by the script itself via Start-Transcript)
rem  - The real exit code is passed through unchanged
rem ============================================================
setlocal
chcp 65001 >nul
title Campus Network Auto Login System
cd /d "%~dp0"

rem ------------------------------------------------------------
rem Log folder: <script dir>\logs\<yyyy-MM-dd>\
rem   The date is computed here so the "Details:" hint below can point
rem   at today's real file. NOTE: if you changed Settings.LogDir in
rem   CampusNet_Config.json, trust the log path the script prints itself
rem   at startup - it reads the config, this .bat cannot.
rem ------------------------------------------------------------
for /f "usebackq delims=" %%d in (`powershell.exe -NoProfile -Command "(Get-Date).ToString('yyyy-MM-dd')"`) do set "TODAY=%%d"
if not defined TODAY set "TODAY=%DATE%"
set "LOGF=%~dp0logs\%TODAY%\CampusNet_Launcher.log"
set "SCRIPT=%~dp0CampusNet_Login.ps1"

echo ============================================================
echo   CAMPUS NETWORK AUTO LOGIN SYSTEM
echo   Guangzhou Institute of Science and Technology
echo ============================================================
echo.

if not exist "%SCRIPT%" (
    echo [ERROR] CampusNet_Login.ps1 not found in "%cd%"
    echo         Keep all files in the same folder.
    echo.
    dir /b
    echo.
    pause
    exit /b 1
)
if not exist "%~dp0CampusNet.Common.ps1" (
    echo [ERROR] CampusNet.Common.ps1 ^(shared module^) not found.
    echo         It is required by CampusNet_Login.ps1.
    echo.
    dir /b
    echo.
    pause
    exit /b 1
)

echo Running...  full output is also saved to the log folder
echo.

rem ------------------------------------------------------------
rem IMPORTANT: do NOT pipe PowerShell into Tee-Object here.
rem   "& 'script.ps1' *>&1 | Tee-Object -File ..." collapses every
rem   non-zero "exit N" into 1, so codes 2/3/4 would be lost.
rem   The script writes CampusNet_Launcher.log by itself instead.
rem Use powershell.exe (NOT PowerShell / pwsh) so PS 5.1 is used.
rem ------------------------------------------------------------
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%"
set "RC=%ERRORLEVEL%"

echo.
if not "%RC%"=="0" (
    echo [WARN] PowerShell exited with code %RC%.
    echo        0=ok  1=no config  2=config corrupt  3=no adapter  4=login failed
    echo        Details: "%LOGF%"
) else (
    echo [INFO] Finished, exit code 0.
)
echo.
echo Press any key to close this window...
pause >nul
rem NOTE: keep %RC% on the SAME line as endlocal. After endlocal the variable
rem       is gone, so a following "exit /b %RC%" would expand to nothing -> 0.
endlocal & exit /b %RC%
