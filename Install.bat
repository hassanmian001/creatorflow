@echo off
REM Installs CreatorFlow from this folder. Double-click it.
REM
REM Use this when you have the whole folder, including Tools. If you only have
REM Setup.bat, run that instead and it will fetch everything from GitHub.

cd /d "%~dp0"
echo.
echo Installing CreatorFlow...
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install.ps1"
if errorlevel 1 (
    echo.
    echo The installation did not complete. See the message above.
    echo.
    pause
    exit /b 1
)
exit /b 0
