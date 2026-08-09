@echo off
REM CreatorFlow installer.
REM
REM This is the only file you need on a new computer. Copy it anywhere, or
REM download it from the GitHub repository, and double-click it. It fetches the
REM application and the FFmpeg runtime from the latest release and installs
REM them, so nothing else has to be carried between machines.
REM
REM Downloading and unpacking are done with curl and tar, which ship with
REM Windows 10 and 11. PowerShell is only ever asked to run a script file that
REM is already on disk. An earlier version passed the download and the install
REM to PowerShell as one inline command, and Microsoft Defender correctly
REM stopped it: fetching code from the internet and running it in a single
REM PowerShell line is exactly the shape of the ClickFix malware family, so it
REM is blocked on sight no matter what the code actually does.
REM
REM Edit GITHUB_OWNER below if the account name ever changes.

setlocal EnableExtensions
set "GITHUB_OWNER=hassanmian001"
set "GITHUB_REPO=creatorflow"
set "ASSET_URL=https://github.com/%GITHUB_OWNER%/%GITHUB_REPO%/releases/latest/download/CreatorFlow-app.zip"
set "WORK=%TEMP%\CreatorFlow-setup"

echo.
echo   CreatorFlow setup
echo   -----------------
echo   Source: github.com/%GITHUB_OWNER%/%GITHUB_REPO%
echo.

if exist "%WORK%" rd /s /q "%WORK%" 2>nul
mkdir "%WORK%" 2>nul
if not exist "%WORK%" (
    echo   Could not create a temporary folder at:
    echo     %WORK%
    goto :failed
)

echo   Downloading application...
curl.exe --location --fail --silent --show-error --retry 2 --output "%WORK%\app.zip" "%ASSET_URL%"
if errorlevel 1 (
    echo.
    echo   The download failed.
    echo.
    echo   The usual causes are that no release has been published yet, or that
    echo   the repository is private. Releases are listed at:
    echo     https://github.com/%GITHUB_OWNER%/%GITHUB_REPO%/releases
    goto :failed
)

echo   Unpacking...
mkdir "%WORK%\app" 2>nul
tar.exe -x -f "%WORK%\app.zip" -C "%WORK%\app"
if errorlevel 1 (
    echo   The downloaded file could not be unpacked; it may be incomplete.
    goto :failed
)

if not exist "%WORK%\app\Install.ps1" (
    echo   The downloaded release does not contain Install.ps1.
    goto :failed
)

echo   Running installer...
echo.
powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -File "%WORK%\app\Install.ps1"
if errorlevel 1 goto :failed

rd /s /q "%WORK%" 2>nul
exit /b 0

:failed
echo.
if exist "%WORK%" rd /s /q "%WORK%" 2>nul
pause
exit /b 1
