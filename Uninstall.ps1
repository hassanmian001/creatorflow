[CmdletBinding()]
param(
    [switch]$Quiet,
    [switch]$KeepSettings
)

# Removes CreatorFlow for the current user.
#
# Settings, caption models, and render history live outside the installation
# folder, so they are removed separately and only when asked. Leaving them in
# place by default means reinstalling picks up where the last version left off.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$appName = 'CreatorFlow'
$registryPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\$appName"
$installDirectory = Split-Path -Parent $MyInvocation.MyCommand.Path
$dataDirectory = Join-Path $env:LOCALAPPDATA 'SlideshowVideoTool'

function Show-Message {
    param([string]$Text, [string]$Icon = 'Information')
    if ($Quiet) { return }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($Text, "$appName uninstall", 'OK', $Icon)
    }
    catch { Write-Host $Text }
}

try {
    if (-not $Quiet) {
        Add-Type -AssemblyName System.Windows.Forms
        $prompt = "Remove $appName from this computer?"
        if (-not $KeepSettings) {
            $prompt += "`r`n`r`nSaved settings, generated captions, and the downloaded speech model will be kept, so reinstalling restores them."
        }
        $answer = [Windows.Forms.MessageBox]::Show($prompt, "$appName uninstall", 'YesNo', 'Question')
        if ($answer -ne 'Yes') { exit 0 }
    }

    # Shortcuts first: they are the visible part.
    foreach ($shortcut in @(
        (Join-Path $env:APPDATA "Microsoft\Windows\Start Menu\Programs\$appName.lnk"),
        (Join-Path ([Environment]::GetFolderPath('Desktop')) "$appName.lnk")
    )) {
        if (Test-Path -LiteralPath $shortcut -PathType Leaf) {
            Remove-Item -LiteralPath $shortcut -Force -ErrorAction SilentlyContinue
        }
    }

    if (Test-Path -LiteralPath $registryPath) {
        Remove-Item -LiteralPath $registryPath -Recurse -Force -ErrorAction SilentlyContinue
    }

    if (-not $KeepSettings) {
        # Renders in progress hold file handles; stop them before deleting.
        Get-Process -Name 'ffmpeg' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path.StartsWith($installDirectory, [StringComparison]::OrdinalIgnoreCase) } |
            ForEach-Object { $_.Kill() }
    }

    # This script lives inside the folder it is deleting, so the removal is
    # handed to a detached process that waits for this one to exit first.
    $command = @"
Start-Sleep -Seconds 2
`$target = '$($installDirectory.Replace("'", "''"))'
for (`$attempt = 0; `$attempt -lt 10; `$attempt++) {
    try {
        if (Test-Path -LiteralPath `$target) { Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction Stop }
        break
    }
    catch { Start-Sleep -Seconds 1 }
}
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    Start-Process -FilePath 'powershell.exe' `
        -ArgumentList @('-NoLogo', '-NoProfile', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded) `
        -WindowStyle Hidden | Out-Null

    $note = "$appName has been removed."
    if (-not $KeepSettings -and (Test-Path -LiteralPath $dataDirectory -PathType Container)) {
        $note += "`r`n`r`nSettings and the downloaded speech model were kept at:`r`n$dataDirectory`r`n`r`nDelete that folder by hand if you want them gone too."
    }
    Show-Message $note
    exit 0
}
catch {
    Show-Message "The uninstall did not finish.`r`n`r`n$($_.Exception.Message)" 'Error'
    exit 1
}
