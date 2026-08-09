[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Version,
    [string]$Notes = '',
    [string]$Token = $env:GITHUB_TOKEN,
    [switch]$ArtifactsOnly
)

# Publishes a new CreatorFlow release.
#
# Run this on the computer where the code is edited. It builds the update
# archive, writes the manifest every installation reads, and creates the GitHub
# release. Installed copies pick the new version up on their next start.
#
#   .\Publish-Release.ps1 -Version 1.1.0 -Notes "Fixed the audio level."
#
# The archive holds only the application files. FFmpeg is left out on purpose:
# it is 283 MB, it changes only when it is deliberately replaced, and every
# installation already has it, so updates stay a fraction of a megabyte.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$outputRoot = Join-Path $root 'dist'

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
    'Uninstall.ps1',
    'Start Tool.bat',
    'VERSION',
    'README.md',
    'Shaders'
)

function Get-UpdateSetting {
    param([string]$Name)
    $modulePath = Join-Path $root 'SlideshowUpdate.psm1'
    $text = [IO.File]::ReadAllText($modulePath)
    $match = [regex]::Match($text, "\`$script:$Name\s*=\s*'([^']*)'")
    if (-not $match.Success) { return '' }
    return $match.Groups[1].Value
}

try {
    $parsed = [version]'0.0.0'
    if (-not [version]::TryParse($Version, [ref]$parsed)) {
        throw "Version must look like 1.2.3, not '$Version'."
    }

    $owner = Get-UpdateSetting 'UpdateOwner'
    $repo = Get-UpdateSetting 'UpdateRepo'
    if ([string]::IsNullOrWhiteSpace($owner)) {
        throw "Open SlideshowUpdate.psm1 and set `$script:UpdateOwner to your GitHub account name first. Installed copies read releases from that account, so it has to be set before the first release."
    }

    Write-Host ''
    Write-Host "Publishing CreatorFlow $parsed to $owner/$repo" -ForegroundColor Cyan
    Write-Host ''

    # 1. Stamp the version so the built archive reports itself correctly.
    [IO.File]::WriteAllText((Join-Path $root 'VERSION'), "$parsed`r`n", [Text.UTF8Encoding]::new($false))
    Write-Host "  VERSION set to $parsed"

    # 2. Stage only the application files.
    if (Test-Path -LiteralPath $outputRoot -PathType Container) {
        Remove-Item -LiteralPath $outputRoot -Recurse -Force
    }
    $stage = Join-Path $outputRoot 'CreatorFlow'
    New-Item -ItemType Directory -Path $stage -Force | Out-Null
    foreach ($name in $appItems) {
        $source = Join-Path $root $name
        if (-not (Test-Path -LiteralPath $source)) {
            Write-Host "  skipped (missing): $name" -ForegroundColor DarkYellow
            continue
        }
        Copy-Item -LiteralPath $source -Destination (Join-Path $stage $name) -Recurse -Force
    }

    # 3. Build the archive with its contents at the root, which is what
    #    Apply-Update.ps1 expects when it copies over an installation.
    $archivePath = Join-Path $outputRoot 'CreatorFlow-app.zip'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::CreateFromDirectory($stage, $archivePath, [IO.Compression.CompressionLevel]::Optimal, $false)
    $sizeKb = [math]::Round((Get-Item -LiteralPath $archivePath).Length / 1KB, 1)
    Write-Host "  built CreatorFlow-app.zip ($sizeKb KB)"

    # 4. The manifest every installed copy reads.
    $sha = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    $manifest = [ordered]@{
        version = $parsed.ToString()
        sha256  = $sha
        notes   = $Notes
        url     = "https://github.com/$owner/$repo/releases/latest/download/CreatorFlow-app.zip"
    }
    $manifestPath = Join-Path $outputRoot 'update.json'
    [IO.File]::WriteAllText($manifestPath, ($manifest | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    Write-Host "  sha256 $sha"

    if ($ArtifactsOnly) {
        Write-Host ''
        Write-Host "Artifacts are in $outputRoot" -ForegroundColor Green
        Write-Host 'Upload CreatorFlow-app.zip and update.json to a GitHub release tagged ' -NoNewline
        Write-Host "v$parsed" -ForegroundColor Yellow
        exit 0
    }

    if ([string]::IsNullOrWhiteSpace($Token)) {
        throw @"
No GitHub token was supplied, so the release cannot be created automatically.

Either set one for this session:
    `$env:GITHUB_TOKEN = 'ghp_yourtokenhere'

Create it at https://github.com/settings/tokens with 'Contents: read and write'
permission on the $repo repository.

Or run with -ArtifactsOnly and upload dist\CreatorFlow-app.zip and dist\update.json
to a release tagged v$parsed by hand.
"@
    }

    # 5. Create the release and attach both assets.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $headers = @{
        Authorization = "Bearer $Token"
        'User-Agent'  = 'CreatorFlow-Publisher'
        Accept        = 'application/vnd.github+json'
    }
    $tag = "v$parsed"

    Write-Host "  creating release $tag..."
    $body = @{ tag_name = $tag; name = $tag; body = $Notes; draft = $false; prerelease = $false } | ConvertTo-Json
    try {
        $release = Invoke-RestMethod -Method Post -Uri "https://api.github.com/repos/$owner/$repo/releases" `
            -Headers $headers -Body $body -ContentType 'application/json'
    }
    catch {
        throw "GitHub refused to create the release. $($_.Exception.Message)`r`n`r`nCheck that the repository $owner/$repo exists, that the token can write to it, and that tag $tag is not already used."
    }

    $uploadRoot = ($release.upload_url -replace '\{.*$', '')
    foreach ($asset in @(
        @{ Path = $archivePath;  Name = 'CreatorFlow-app.zip'; Type = 'application/zip' },
        @{ Path = $manifestPath; Name = 'update.json';         Type = 'application/json' }
    )) {
        Write-Host "  uploading $($asset.Name)..."
        $bytes = [IO.File]::ReadAllBytes($asset.Path)
        $assetHeaders = $headers.Clone()
        $assetHeaders['Content-Type'] = $asset.Type
        [void](Invoke-RestMethod -Method Post -Uri "$uploadRoot`?name=$($asset.Name)" -Headers $assetHeaders -Body $bytes)
    }

    Write-Host ''
    Write-Host "CreatorFlow $parsed published." -ForegroundColor Green
    Write-Host "Installed copies will offer it the next time they start." -ForegroundColor Green
    Write-Host ''
    exit 0
}
catch {
    Write-Host ''
    Write-Host "Publish failed: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host ''
    exit 1
}
