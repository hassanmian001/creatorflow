[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$job = [IO.File]::ReadAllText($JobPath, [Text.Encoding]::UTF8) | ConvertFrom-Json

function Write-BatchProgress {
    param([double]$Percent, [string]$Message)
    $text = "percent=$($Percent.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))`r`nmessage=$Message`r`n"
    [IO.File]::WriteAllText([string]$job.ProgressPath, $text, [Text.UTF8Encoding]::new($false))
}

function Read-ChildProgress {
    param([string]$Path)
    $result = [pscustomobject]@{ Percent = 0.0; Message = 'Starting...' }
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $result }
    try {
        $text = Get-Content -LiteralPath $Path -Raw
        $percent = [regex]::Match($text, '(?m)^percent=([0-9.]+)')
        $message = [regex]::Match($text, '(?m)^message=(.*)$')
        if ($percent.Success) { $result.Percent = [double]::Parse($percent.Groups[1].Value, [Globalization.CultureInfo]::InvariantCulture) }
        if ($message.Success) { $result.Message = $message.Groups[1].Value.Trim() }
    }
    catch {}
    return $result
}

function Quote-Argument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('"', '\"') + '"'
}

function Invoke-ChildWorker {
    param([string]$ScriptPath, [string]$ChildJobPath, [string]$ChildProgressPath, [int]$Index, [int]$Count, [string]$Label)
    $args = @('-NoProfile','-ExecutionPolicy','Bypass','-File',$ScriptPath,'-JobPath',$ChildJobPath)
    $line = (($args | ForEach-Object { Quote-Argument $_ }) -join ' ')
    $process = Start-Process -FilePath 'powershell.exe' -ArgumentList $line -PassThru -WindowStyle Hidden
    $null = $process.Handle
    [IO.File]::WriteAllText([string]$job.ChildPidPath, [string]$process.Id, [Text.Encoding]::ASCII)
    while (-not $process.HasExited) {
        $child = Read-ChildProgress $ChildProgressPath
        $overall = (($Index + ($child.Percent / 100.0)) / [double]$Count) * 100.0
        Write-BatchProgress $overall "Project $($Index + 1) of $Count - $Label - $($child.Message)"
        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }
    $process.WaitForExit(); $process.Refresh()
    if ($process.ExitCode -ne 0) { throw "$Label failed for project $($Index + 1)." }
}

try {
    $items = @($job.Items)
    if ($items.Count -eq 0) { throw 'The batch is empty.' }
    Write-BatchProgress 0 "Starting batch of $($items.Count) projects..."
    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        if ($item.PSObject.Properties['CaptionJobPath'] -and -not [string]::IsNullOrWhiteSpace([string]$item.CaptionJobPath)) {
            $captionJob = [IO.File]::ReadAllText([string]$item.CaptionJobPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if (-not (Test-Path -LiteralPath ([string]$captionJob.OutputSrt) -PathType Leaf)) {
                Invoke-ChildWorker -ScriptPath ([string]$job.CaptionWorkerPath) -ChildJobPath ([string]$item.CaptionJobPath) -ChildProgressPath ([string]$captionJob.ProgressPath) -Index $index -Count $items.Count -Label 'captions'
            }
        }
        $renderJob = [IO.File]::ReadAllText([string]$item.RenderJobPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        Invoke-ChildWorker -ScriptPath ([string]$job.RenderWorkerPath) -ChildJobPath ([string]$item.RenderJobPath) -ChildProgressPath ([string]$renderJob.ProgressPath) -Index $index -Count $items.Count -Label 'rendering'
        Write-BatchProgress ((($index + 1) / [double]$items.Count) * 100.0) "Completed project $($index + 1) of $($items.Count)."
    }
    if (Test-Path -LiteralPath ([string]$job.ChildPidPath) -PathType Leaf) { Remove-Item -LiteralPath ([string]$job.ChildPidPath) -Force }
    Write-BatchProgress 100 "Batch completed: $($items.Count) videos."
    exit 0
}
catch {
    [IO.File]::WriteAllText([string]$job.ErrorPath, ($_.Exception.ToString() + "`r`n" + $_.ScriptStackTrace), [Text.UTF8Encoding]::new($false))
    try { Write-BatchProgress 0 'Batch paused. Finished videos and resumable segments were kept.' } catch {}
    exit 1
}
