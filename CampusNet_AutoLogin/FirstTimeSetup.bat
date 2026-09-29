@echo off
rem ============================================================
rem  FirstTimeSetup.bat - one-time account setup wizard
rem  - Window ALWAYS stays open
rem  - Full output goes to logs\<date>\CampusNet_Launcher.log (Start-Transcript)
rem  - The real exit code is passed through unchanged
rem ============================================================
setlocal
chcp 65001 >nul
title Campus Network - First Time Setup
cd /d "%~dp0"

for /f "usebackq delims=" %%d in (`powershell.exe -NoProfile -Command "(Get-Date).ToString('yyyy-MM-dd')"`) do set "TODAY=%%d"
if not defined TODAY set "TODAY=%DATE%"
set "LOGF=%~dp0logs\%TODAY%\CampusNet_Launcher.log"
set "SCRIPT=%~dp0CampusNet_Login.ps1"

echo ============================================================
echo   CAMPUS NETWORK - FIRST TIME SETUP
echo ============================================================
echo.
echo This wizard saves your student ID and campus network password.
echo The password is encrypted with Windows DPAPI and can only be
echo decrypted on THIS PC by THIS Windows user.
echo.
echo Please connect first (Ethernet cable or campus Wi-Fi).
echo.

if not exist "%SCRIPT%" (
    echo [ERROR] CampusNet_Login.ps1 not found in "%cd%"
    echo.
    pause
    exit /b 1
)

rem NOTE: no Tee-Object pipe here on purpose - it would collapse the
rem       real exit code into 1. See the comment in CampusNet.bat.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -Setup
set "RC=%ERRORLEVEL%"

echo.
echo Done (exit code %RC%). You can now run "CampusNet.bat".
echo.
pause
rem NOTE: keep %RC% on the SAME line as endlocal. After endlocal the variable
rem       is gone, so a following "exit /b %RC%" would expand to nothing -> 0.
endlocal & exit /b %RC%
