[CmdletBinding()]
param(
    [string]$InstallDirectory = (Join-Path $env:LOCALAPPDATA 'Programs\CreatorFlow'),
    [switch]$Quiet
)

# Installs CreatorFlow for the current user.
#
# Everything goes under the user's own profile, so this never needs an
# administrator and never touches another account. That also means the
# Add/Remove Programs entry is written to HKCU rather than HKLM, which is where
# Windows looks for per-user applications.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$sourceRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$appName = 'CreatorFlow'
$publisher = 'NYC Power Watch'
$registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appName"

function Write-Step {
    param([string]$Message)
    if (-not $Quiet) { Write-Host "  $Message" }
}

function Show-Result {
    param([string]$Message, [string]$Title = 'CreatorFlow', [string]$Icon = 'Information')
    if ($Quiet) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($Message, $Title, 'OK', $Icon)
    }
    catch { Write-Host $Message }
}

# Files that make up the application. The runtime is handled separately because
# it is hundreds of megabytes and does not change between releases.
$appItems = @(
    'SlideshowVideoTool.ps1',
    'SlideshowEngine.psm1',
    'SlideshowAnalysis.psm1',
    'SlideshowUpdate.psm1',
    'CaptionWorker.ps1',
    'SlideshowRenderWorker.ps1',
    'SlideshowBatchWorker.ps1',
    'Apply-Update.ps1',
    'Install.ps1',
    'Install.bat',
    'Uninstall.ps1',
    'Start Tool.bat',
    'VERSION',
    'README.md',
    'Shaders'
)

try {
    if (-not $Quiet) {
        Write-Host ''
        Write-Host "Installing $appName" -ForegroundColor Cyan
        Write-Host ''
    }

    $version = '1.0.0'
    $versionFile = Join-Path $sourceRoot 'VERSION'
    if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
        $version = (Get-Content -LiteralPath $versionFile -Raw).Trim()
    }

    # Refuse to install over itself, which would delete the source mid-copy.
    $normalisedSource = [IO.Path]::GetFullPath($sourceRoot).TrimEnd('\')
    $normalisedTarget = [IO.Path]::GetFullPath($InstallDirectory).TrimEnd('\')
    if ($normalisedSource -eq $normalisedTarget) {
        throw "This folder is already the installation folder. Run Install.ps1 from the copy you downloaded instead."
    }

    Write-Step "Version $version"
    Write-Step "Target  $InstallDirectory"

    if (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $InstallDirectory -Force | Out-Null
    }

    Write-Step 'Copying application files...'
    foreach ($name in $appItems) {
        $source = Join-Path $sourceRoot $name
        if (-not (Test-Path -LiteralPath $source)) { continue }
        Copy-Item -LiteralPath $source -Destination (Join-Path $InstallDirectory $name) -Recurse -Force
    }

    # The runtime is handled in three ways, cheapest first: keep one that is
    # already installed, copy one sitting beside the installer, or download the
    # published one. That last case is what lets a few-kilobyte installer set up
    # a computer that has never seen this tool.
    $sourceTools = Join-Path $sourceRoot 'Tools'
    $targetTools = Join-Path $InstallDirectory 'Tools'
    $ffmpegProbe = 'FFmpeg-7.1.1\ffmpeg-7.1.1-full_build\bin\ffmpeg.exe'
    if (Test-Path -LiteralPath (Join-Path $targetTools $ffmpegProbe) -PathType Leaf) {
        Write-Step 'Runtime already installed, keeping it.'
    }
    elseif (Test-Path -LiteralPath (Join-Path $sourceTools $ffmpegProbe) -PathType Leaf) {
        Write-Step 'Copying FFmpeg runtime (about 283 MB, one time)...'
        Copy-Item -LiteralPath $sourceTools -Destination $targetTools -Recurse -Force
    }
    else {
        $runtimeUrl = ''
        try {
            Import-Module (Join-Path $InstallDirectory 'SlideshowUpdate.psm1') -Force -ErrorAction Stop
            if (Test-UpdateConfigured) { $runtimeUrl = Get-UpdateRuntimeUrl }
        }
        catch {}

        if ([string]::IsNullOrWhiteSpace($runtimeUrl)) {
            throw @"
No FFmpeg runtime was found and none could be downloaded.

Either run this installer from a folder that contains the Tools directory, or
publish the runtime once with:

    .\Publish-Release.ps1 -Version <version> -IncludeRuntime
"@
        }

        Write-Step 'Downloading FFmpeg runtime (about 116 MB, one time)...'
        $runtimeZip = Join-Path $env:TEMP ('CreatorFlow-runtime-' + [guid]::NewGuid().ToString('N') + '.zip')
        try {
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $client = [Net.WebClient]::new()
            try {
                $client.Headers.Add('User-Agent', 'CreatorFlow-Installer')
                $client.DownloadFile([uri]$runtimeUrl, $runtimeZip)
            }
            finally { $client.Dispose() }

            Write-Step 'Extracting runtime...'
            New-Item -ItemType Directory -Path $targetTools -Force | Out-Null
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            [IO.Compression.ZipFile]::ExtractToDirectory($runtimeZip, $targetTools)

            if (-not (Test-Path -LiteralPath (Join-Path $targetTools $ffmpegProbe) -PathType Leaf)) {
                throw 'The downloaded runtime did not contain ffmpeg.exe where it was expected.'
            }
        }
        catch {
            throw "The FFmpeg runtime could not be downloaded from $runtimeUrl. $($_.Exception.Message)"
        }
        finally {
            if (Test-Path -LiteralPath $runtimeZip -PathType Leaf) {
                Remove-Item -LiteralPath $runtimeZip -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Shortcuts. WScript.Shell is present on every Windows install.
    Write-Step 'Creating shortcuts...'
    $launcher = Join-Path $InstallDirectory 'SlideshowVideoTool.ps1'
    $iconSource = Join-Path $InstallDirectory 'Shaders\app.ico'
    $shell = New-Object -ComObject WScript.Shell
    try {
        $startMenu = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
        $shortcutPath = Join-Path $startMenu "$appName.lnk"
        $shortcut = $shell.CreateShortcut($shortcutPath)
        $shortcut.TargetPath = 'powershell.exe'
        $shortcut.Arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
        $shortcut.WorkingDirectory = $InstallDirectory
        $shortcut.Description = 'Turn a folder of images and a voiceover into a 1080p video'
        if (Test-Path -LiteralPath $iconSource -PathType Leaf) { $shortcut.IconLocation = $iconSource }
        $shortcut.Save()
        Write-Step "Start Menu: $shortcutPath"

        $desktopPath = Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk"
        $desktopShortcut = $shell.CreateShortcut($desktopPath)
        $desktopShortcut.TargetPath = 'powershell.exe'
        $desktopShortcut.Arguments = "-NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcher`""
        $desktopShortcut.WorkingDirectory = $InstallDirectory
        if (Test-Path -LiteralPath $iconSource -PathType Leaf) { $desktopShortcut.IconLocation = $iconSource }
        $desktopShortcut.Save()
    }
    finally {
        [void][Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
    }

    # Add/Remove Programs. Windows reads these values straight out of the key.
    Write-Step 'Registering with Add/Remove Programs...'
    if (-not (Test-Path -LiteralPath $registryPath)) {
        New-Item -Path $registryPath -Force | Out-Null
    }
    $uninstallScript = Join-Path $InstallDirectory 'Uninstall.ps1'
    $sizeKb = 0
    try {
        $sizeKb = [int](((Get-ChildItem -LiteralPath $InstallDirectory -Recurse -File -ErrorAction SilentlyContinue |
            Measure-Object -Property Length -Sum).Sum) / 1KB)
    }
    catch {}

    $values = @{
        DisplayName     = $appName
        DisplayVersion  = $version
        Publisher       = $publisher
        InstallLocation = $InstallDirectory
        UninstallString = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`""
        QuietUninstallString = "powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File `"$uninstallScript`" -Quiet"
        NoModify        = 1
        NoRepair        = 1
        EstimatedSize   = $sizeKb
        InstallDate     = (Get-Date).ToString('yyyyMMdd')
    }
    if (Test-Path -LiteralPath $iconSource -PathType Leaf) { $values['DisplayIcon'] = $iconSource }
    foreach ($key in $values.Keys) {
        $type = if ($values[$key] -is [int]) { 'DWord' } else { 'String' }
        New-ItemProperty -LiteralPath $registryPath -Name $key -Value $values[$key] -PropertyType $type -Force | Out-Null
    }

    if (-not $Quiet) {
        Write-Host ''
        Write-Host "$appName $version installed." -ForegroundColor Green
        Write-Host ''
    }
    Show-Result "$appName $version is installed.`r`n`r`nStart it from the Start Menu or the desktop shortcut.`r`n`r`nIt appears in Add/Remove Programs and will offer updates automatically."
    exit 0
}
catch {
    $message = "The installation did not complete.`r`n`r`n$($_.Exception.Message)"
    if (-not $Quiet) { Write-Host $message -ForegroundColor Red }
    Show-Result $message 'CreatorFlow installation' 'Error'
    exit 1
}
