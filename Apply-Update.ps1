[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ArchivePath,
    [Parameter(Mandatory = $true)][string]$InstallDirectory,
    [Parameter(Mandatory = $true)][int]$WaitForProcessId,
    [Parameter(Mandatory = $true)][string]$Version,
    [switch]$NoRelaunch
)

# Replaces the installed application files with the contents of a verified
# update archive, then starts the tool again.
#
# This runs as its own process because the files being replaced belong to the
# process that asked for the update. It waits for that process to exit first,
# keeps a copy of the previous version, and puts that copy back if anything
# fails part way through, so a broken download can never leave a half-updated
# installation behind.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$logPath = Join-Path $env:LOCALAPPDATA 'SlideshowVideoTool\update.log'
function Write-UpdateLog {
    param([string]$Message)
    try {
        $directory = Split-Path -Parent $logPath
        if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
            New-Item -ItemType Directory -Path $directory -Force | Out-Null
        }
        $line = '{0}  {1}{2}' -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $Message, [Environment]::NewLine
        [IO.File]::AppendAllText($logPath, $line, [Text.UTF8Encoding]::new($false))
    }
    catch {}
}

# Files that belong to the machine rather than the release. The runtime is
# hundreds of megabytes and changes only when it is deliberately replaced, so
# updates never carry it and it must survive the swap.
$preserve = @('Tools', 'VERSION.local')

$backupDirectory = ''
$extractDirectory = ''
try {
    Write-UpdateLog "Applying update $Version to $InstallDirectory"

    if (-not (Test-Path -LiteralPath $ArchivePath -PathType Leaf)) {
        throw "The update archive is missing: $ArchivePath"
    }
    if (-not (Test-Path -LiteralPath $InstallDirectory -PathType Container)) {
        throw "The installation folder is missing: $InstallDirectory"
    }

    # Wait for the running tool to close so its files are no longer locked.
    try {
        $process = Get-Process -Id $WaitForProcessId -ErrorAction Stop
        Write-UpdateLog "Waiting for process $WaitForProcessId to exit"
        if (-not $process.WaitForExit(120000)) {
            throw 'The application did not close within two minutes, so the update was cancelled.'
        }
    }
    catch [Microsoft.PowerShell.Commands.ProcessCommandException] {
        # Already gone, which is the normal case.
    }
    Start-Sleep -Milliseconds 700

    $extractDirectory = Join-Path (Split-Path -Parent $ArchivePath) 'extracted'
    if (Test-Path -LiteralPath $extractDirectory -PathType Container) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force
    }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($ArchivePath, $extractDirectory)

    # A release that does not carry the main script is not a release.
    $entryScript = Join-Path $extractDirectory 'SlideshowVideoTool.ps1'
    if (-not (Test-Path -LiteralPath $entryScript -PathType Leaf)) {
        throw 'The update archive does not contain SlideshowVideoTool.ps1 and was rejected.'
    }

    $backupDirectory = Join-Path $env:TEMP ('CreatorFlow-previous-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $backupDirectory -Force | Out-Null

    # Move the old files aside rather than deleting them, so a failure part way
    # through can still be undone.
    foreach ($item in (Get-ChildItem -LiteralPath $InstallDirectory -Force)) {
        if ($preserve -contains $item.Name) { continue }
        Move-Item -LiteralPath $item.FullName -Destination (Join-Path $backupDirectory $item.Name) -Force
    }

    foreach ($item in (Get-ChildItem -LiteralPath $extractDirectory -Force)) {
        if ($preserve -contains $item.Name) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $InstallDirectory $item.Name) -Recurse -Force
    }

    # Carry the runtime back over if the previous installation had one and the
    # release did not include it, which is the normal arrangement.
    foreach ($name in $preserve) {
        $restored = Join-Path $backupDirectory $name
        $target = Join-Path $InstallDirectory $name
        if ((Test-Path -LiteralPath $restored) -and -not (Test-Path -LiteralPath $target)) {
            Move-Item -LiteralPath $restored -Destination $target -Force
        }
    }

    [IO.File]::WriteAllText((Join-Path $InstallDirectory 'VERSION'), "$Version`r`n", [Text.UTF8Encoding]::new($false))

    # Keep the Add/Remove Programs entry showing the version that is installed.
    $registryPath = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\CreatorFlow'
    if (Test-Path -LiteralPath $registryPath) {
        Set-ItemProperty -LiteralPath $registryPath -Name 'DisplayVersion' -Value $Version
    }

    Write-UpdateLog "Update to $Version applied"

    if (-not $NoRelaunch) {
        $launcher = Join-Path $InstallDirectory 'SlideshowVideoTool.ps1'
        Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$launcher`"") `
            -WorkingDirectory $InstallDirectory | Out-Null
    }

    # Only discard the previous version once the new one is in place.
    if (Test-Path -LiteralPath $backupDirectory -PathType Container) {
        Remove-Item -LiteralPath $backupDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
    exit 0
}
catch {
    Write-UpdateLog "FAILED: $($_.Exception.Message)"

    # Put the previous version back so the tool still starts.
    if ($backupDirectory -and (Test-Path -LiteralPath $backupDirectory -PathType Container)) {
        try {
            foreach ($item in (Get-ChildItem -LiteralPath $backupDirectory -Force)) {
                $target = Join-Path $InstallDirectory $item.Name
                if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
                Move-Item -LiteralPath $item.FullName -Destination $target -Force
            }
            Write-UpdateLog 'Previous version restored'
        }
        catch {
            Write-UpdateLog "Restore also failed: $($_.Exception.Message)"
        }
    }

    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show(
            "The update could not be installed, so the previous version was kept.`r`n`r`n$($_.Exception.Message)`r`n`r`nDetails: $logPath",
            'CreatorFlow update', 'OK', 'Warning')
    }
    catch {}
    exit 1
}
finally {
    if ($extractDirectory -and (Test-Path -LiteralPath $extractDirectory -PathType Container)) {
        Remove-Item -LiteralPath $extractDirectory -Recurse -Force -ErrorAction SilentlyContinue
    }
}
