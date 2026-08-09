@echo off
REM CreatorFlow installer.
REM
REM This is the only file you need on a new computer. Copy it anywhere, or
REM download it from the GitHub repository, and double-click it. It fetches the
REM application and the FFmpeg runtime from the latest release and installs
REM them, so nothing else has to be carried between machines.
REM
REM Edit GITHUB_OWNER below if the account name ever changes.

setlocal
set "GITHUB_OWNER=hassanmian001"
set "GITHUB_REPO=creatorflow"

echo.
echo   CreatorFlow setup
echo   -----------------
echo   Downloading from github.com/%GITHUB_OWNER%/%GITHUB_REPO%
echo.

powershell.exe -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -Command ^
  "$ErrorActionPreference='Stop';" ^
  "$owner='%GITHUB_OWNER%'; $repo='%GITHUB_REPO%';" ^
  "try {" ^
  "  [Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;" ^
  "  $work=Join-Path $env:TEMP ('CreatorFlow-setup-'+[guid]::NewGuid().ToString('N'));" ^
  "  New-Item -ItemType Directory -Path $work -Force | Out-Null;" ^
  "  $zip=Join-Path $work 'app.zip';" ^
  "  Write-Host '  Downloading application...';" ^
  "  $c=[Net.WebClient]::new(); $c.Headers.Add('User-Agent','CreatorFlow-Setup');" ^
  "  $c.DownloadFile([uri]\"https://github.com/$owner/$repo/releases/latest/download/CreatorFlow-app.zip\", $zip); $c.Dispose();" ^
  "  Add-Type -AssemblyName System.IO.Compression.FileSystem;" ^
  "  $app=Join-Path $work 'app'; [IO.Compression.ZipFile]::ExtractToDirectory($zip,$app);" ^
  "  $installer=Join-Path $app 'Install.ps1';" ^
  "  if(-not (Test-Path -LiteralPath $installer)){ throw 'The downloaded release does not contain Install.ps1.' }" ^
  "  Write-Host '  Running installer...'; Write-Host '';" ^
  "  & $installer;" ^
  "  if($LASTEXITCODE -ne 0){ throw 'The installer reported a failure.' }" ^
  "  Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue;" ^
  "} catch {" ^
  "  Write-Host '';" ^
  "  Write-Host ('  Setup failed: '+$_.Exception.Message) -ForegroundColor Red;" ^
  "  Write-Host '';" ^
  "  Write-Host '  Check that the computer is online and that a release has been' -ForegroundColor Yellow;" ^
  "  Write-Host ('  published at https://github.com/'+$owner+'/'+$repo+'/releases') -ForegroundColor Yellow;" ^
  "  Write-Host '';" ^
  "  exit 1" ^
  "}"

if errorlevel 1 (
    pause
    exit /b 1
)
exit /b 0
