Set-StrictMode -Version Latest

# Where this installation looks for new versions.
#
# Fill in the GitHub account and repository that holds the releases, then
# publish with Publish-Release.ps1. While the owner is left blank the whole
# update system stays quiet: no checks, no errors, no prompts.
$script:UpdateOwner = 'hassanmian001'
$script:UpdateRepo = 'creatorflow'

# GitHub serves the newest release's assets from a fixed address, so a released
# build never has to be discovered through the API. That keeps update checks off
# the API rate limit and means an old installation still finds new versions.
$script:UpdateManifestName = 'update.json'
$script:UpdatePackageName = 'CreatorFlow-app.zip'

# FFmpeg is published as a release asset rather than committed, because a single
# 141 MB executable is past GitHub's 100 MB file limit while release assets allow
# up to 2 GB. It is uploaded once and only rebuilt when the runtime is replaced,
# so the installer can be a few kilobytes and still set up a computer from
# nothing.
#
# It lives under its own fixed tag rather than with the newest release. Pointing
# at "latest" would break every fresh install the moment an application-only
# release was published, because that release does not carry the runtime.
$script:UpdateRuntimeName = 'CreatorFlow-runtime.zip'
$script:UpdateRuntimeTag = 'runtime-7.1.1'

function Get-CurlPath {
    $curl = Join-Path $env:SystemRoot 'System32\curl.exe'
    if (Test-Path -LiteralPath $curl -PathType Leaf) { return $curl }
    return ''
}

function Receive-UpdateText {
    <#
        Fetches a small document and returns it as text, or '' on any failure.

        WebClient's task-returning methods hand their completion back through
        the captured SynchronizationContext. On the window's own thread that is
        the dispatcher, so waiting on the task blocks the very thread the
        completion needs, and the call never returns. curl is a separate
        process and has no such relationship with the caller.
    #>
    param([string]$Url, [int]$TimeoutSeconds = 15)

    $curl = Get-CurlPath
    if ($curl) {
        try {
            $text = & $curl --location --fail --silent --max-time $TimeoutSeconds $Url
            if ($LASTEXITCODE -eq 0 -and $text) { return ($text -join "`n") }
            return ''
        }
        catch { return '' }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $client = [Net.WebClient]::new()
        try {
            $client.Headers.Add('User-Agent', 'CreatorFlow-Updater')
            # DownloadString, not DownloadStringTaskAsync: the synchronous call
            # simply blocks and cannot deadlock against the dispatcher.
            return $client.DownloadString($Url)
        }
        finally { $client.Dispose() }
    }
    catch { return '' }
}

function Receive-UpdateFile {
    param([string]$Url, [string]$Destination, [int]$TimeoutSeconds = 600)

    $curl = Get-CurlPath
    if ($curl) {
        & $curl --location --fail --silent --show-error --retry 2 --max-time $TimeoutSeconds --output $Destination $Url
        if ($LASTEXITCODE -ne 0) {
            throw "The download failed (curl error $LASTEXITCODE). Check the connection and try again."
        }
        return
    }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $client = [Net.WebClient]::new()
    try {
        $client.Headers.Add('User-Agent', 'CreatorFlow-Updater')
        $client.DownloadFile($Url, $Destination)
    }
    finally { $client.Dispose() }
}

function Get-AppVersion {
    [CmdletBinding()]
    param([Parameter(Mandatory = $true)][string]$AppRoot)

    $versionFile = Join-Path $AppRoot 'VERSION'
    if (Test-Path -LiteralPath $versionFile -PathType Leaf) {
        $raw = (Get-Content -LiteralPath $versionFile -Raw -ErrorAction SilentlyContinue)
        if ($null -ne $raw) {
            $text = $raw.Trim()
            $parsed = [version]'0.0.0'
            if ([version]::TryParse($text, [ref]$parsed)) { return $parsed }
        }
    }
    return [version]'0.0.0'
}

function Test-UpdateConfigured {
    return -not [string]::IsNullOrWhiteSpace($script:UpdateOwner)
}

function Get-UpdateManifestUrl {
    return "https://github.com/$script:UpdateOwner/$script:UpdateRepo/releases/latest/download/$script:UpdateManifestName"
}

function Get-UpdatePackageUrl {
    return "https://github.com/$script:UpdateOwner/$script:UpdateRepo/releases/latest/download/$script:UpdatePackageName"
}

function Get-UpdateRuntimeUrl {
    return "https://github.com/$script:UpdateOwner/$script:UpdateRepo/releases/download/$script:UpdateRuntimeTag/$script:UpdateRuntimeName"
}

function Get-UpdateRuntimeTag {
    return $script:UpdateRuntimeTag
}

function Get-AvailableUpdate {
    <#
        Returns $null when the installation is current, unreachable, or not
        configured. A machine with no internet must not be told anything is
        wrong, so every failure here is silent by design.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][version]$CurrentVersion,
        [int]$TimeoutSeconds = 10
    )

    if (-not (Test-UpdateConfigured)) { return $null }

    try {
        $json = Receive-UpdateText -Url (Get-UpdateManifestUrl) -TimeoutSeconds $TimeoutSeconds
        if ([string]::IsNullOrWhiteSpace($json)) { return $null }
        $manifest = $json | ConvertFrom-Json

        $latest = [version]'0.0.0'
        if (-not [version]::TryParse([string]$manifest.version, [ref]$latest)) { return $null }
        if ($latest -le $CurrentVersion) { return $null }

        $sha = ''
        if ($manifest.PSObject.Properties['sha256']) { $sha = ([string]$manifest.sha256).Trim() }
        if ($sha -notmatch '^[0-9a-fA-F]{64}$') { return $null }

        $notes = ''
        if ($manifest.PSObject.Properties['notes']) { $notes = [string]$manifest.notes }
        $url = Get-UpdatePackageUrl
        if ($manifest.PSObject.Properties['url'] -and -not [string]::IsNullOrWhiteSpace([string]$manifest.url)) {
            $url = [string]$manifest.url
        }

        return [pscustomobject]@{
            Version = $latest
            Sha256 = $sha.ToLowerInvariant()
            Notes = $notes
            Url = $url
        }
    }
    catch {
        return $null
    }
}

function Save-UpdatePackage {
    <#
        Downloads the release archive and refuses it unless the hash matches the
        manifest. Returns the archive path, or throws with a message meant to be
        shown to the person running the tool.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][psobject]$Update,
        [Parameter(Mandatory = $true)][string]$StagingDirectory,
        [int]$TimeoutSeconds = 300
    )

    if (Test-Path -LiteralPath $StagingDirectory -PathType Container) {
        Remove-Item -LiteralPath $StagingDirectory -Recurse -Force
    }
    New-Item -ItemType Directory -Path $StagingDirectory -Force | Out-Null
    $archivePath = Join-Path $StagingDirectory 'update.zip'

    try {
        Receive-UpdateFile -Url $Update.Url -Destination $archivePath -TimeoutSeconds $TimeoutSeconds
    }
    catch {
        throw "The update could not be downloaded. $($_.Exception.Message)"
    }

    if (-not (Test-Path -LiteralPath $archivePath -PathType Leaf)) {
        throw 'The update download did not produce a file.'
    }

    $actual = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($actual -ne $Update.Sha256) {
        Remove-Item -LiteralPath $archivePath -Force -ErrorAction SilentlyContinue
        throw 'The downloaded update did not match its published checksum and was discarded.'
    }

    return $archivePath
}

function Start-UpdateInstall {
    <#
        Hands the archive to a detached updater and returns. Files cannot be
        replaced while this process has them open, so the updater waits for this
        process to exit before it swaps anything, then relaunches the tool.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)][string]$AppRoot,
        [Parameter(Mandatory = $true)][string]$ArchivePath,
        [Parameter(Mandatory = $true)][version]$Version
    )

    $applyScript = Join-Path $AppRoot 'Apply-Update.ps1'
    if (-not (Test-Path -LiteralPath $applyScript -PathType Leaf)) {
        throw 'Apply-Update.ps1 is missing from the installation, so the update cannot be applied.'
    }

    $arguments = @(
        '-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden',
        '-File', "`"$applyScript`"",
        '-ArchivePath', "`"$ArchivePath`"",
        '-InstallDirectory', "`"$AppRoot`"",
        '-WaitForProcessId', $PID,
        '-Version', $Version.ToString()
    )
    Start-Process -FilePath 'powershell.exe' -ArgumentList ($arguments -join ' ') -WindowStyle Hidden | Out-Null
}

Export-ModuleMember -Function @(
    'Get-AppVersion',
    'Test-UpdateConfigured',
    'Get-UpdateManifestUrl',
    'Get-UpdatePackageUrl',
    'Get-UpdateRuntimeUrl',
    'Get-UpdateRuntimeTag',
    'Get-AvailableUpdate',
    'Save-UpdatePackage',
    'Start-UpdateInstall'
)
