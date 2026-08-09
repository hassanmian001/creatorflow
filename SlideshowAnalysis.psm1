Set-StrictMode -Version Latest

function Get-CaptionFingerprint {
    param([Parameter(Mandatory = $true)][string]$AudioPath)
    $file = Get-Item -LiteralPath $AudioPath
    $raw = "$($file.FullName.ToLowerInvariant())|$($file.Length)|$($file.LastWriteTimeUtc.Ticks)"
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [Text.Encoding]::UTF8.GetBytes($raw)
        return ([BitConverter]::ToString($sha.ComputeHash($bytes))).Replace('-', '').ToLowerInvariant()
    }
    finally { $sha.Dispose() }
}

function Get-CaptionCachePath {
    param(
        [Parameter(Mandatory = $true)][string]$AudioPath,
        [Parameter(Mandatory = $true)][string]$DataRoot
    )
    $fingerprint = Get-CaptionFingerprint -AudioPath $AudioPath
    return Join-Path (Join-Path $DataRoot 'captions') "$fingerprint.srt"
}

Export-ModuleMember -Function @(
    'Get-CaptionFingerprint',
    'Get-CaptionCachePath'
)
