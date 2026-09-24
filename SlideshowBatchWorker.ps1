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

function Get-ChildFailureReason {
    # The render and caption workers write why they stopped - usually FFmpeg's
    # own words - to an error log in the project's run folder. The app deletes
    # that folder once the batch has stopped, so a reason not carried up into
    # the batch's own error is gone for good, and all anyone ever saw was
    # "rendering failed for project 1".
    param([string]$ErrorPath)
    if ([string]::IsNullOrWhiteSpace($ErrorPath) -or -not (Test-Path -LiteralPath $ErrorPath -PathType Leaf)) { return '' }
    $raw = ''
    try { $raw = [IO.File]::ReadAllText($ErrorPath, [Text.Encoding]::UTF8) } catch { return '' }
    if ([string]::IsNullOrWhiteSpace($raw)) { return '' }
    # The log is an exception dump: "Type: message", then the stack. Only the
    # message tells a person anything.
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($line in ($raw -split "`r?`n")) {
        if ($line -match '^\s+at ' -or $line -match '^at .+: line \d+') { break }
        if ($lines.Count -eq 0) { $line = $line -replace '^[\w.]+Exception:\s*', '' }
        if (-not [string]::IsNullOrWhiteSpace($line)) { $lines.Add($line.TrimEnd()) }
    }
    # FFmpeg can run long, and its last lines are the ones that name the fault.
    if ($lines.Count -gt 18) { return ((@($lines[0], '...') + @($lines | Select-Object -Last 16)) -join "`r`n") }
    return ($lines -join "`r`n")
}

function Invoke-ChildWorker {
    param([string]$ScriptPath, [string]$ChildJobPath, [string]$ChildProgressPath, [string]$ChildErrorPath, [int]$Index, [int]$Count, [string]$Label, [string]$Title = '')
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
    if ($process.ExitCode -ne 0) {
        $which = "project $($Index + 1) of $Count"
        if (-not [string]::IsNullOrWhiteSpace($Title)) { $which = "$which ($Title)" }
        $stage = $Label.Substring(0, 1).ToUpperInvariant() + $Label.Substring(1)
        $reason = Get-ChildFailureReason $ChildErrorPath
        if ([string]::IsNullOrWhiteSpace($reason)) { throw "$stage failed for $which. The worker left no reason behind." }
        throw "$stage failed for $($which):`r`n`r`n$reason"
    }
}

try {
    $items = @($job.Items)
    if ($items.Count -eq 0) { throw 'The batch is empty.' }
    Write-BatchProgress 0 "Starting batch of $($items.Count) projects..."
    for ($index = 0; $index -lt $items.Count; $index++) {
        $item = $items[$index]
        $title = if ($item.PSObject.Properties['DestinationPath']) { [IO.Path]::GetFileName([string]$item.DestinationPath) } else { '' }
        if ($item.PSObject.Properties['CaptionJobPath'] -and -not [string]::IsNullOrWhiteSpace([string]$item.CaptionJobPath)) {
            $captionJob = [IO.File]::ReadAllText([string]$item.CaptionJobPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
            if (-not (Test-Path -LiteralPath ([string]$captionJob.OutputSrt) -PathType Leaf)) {
                $captionErrorPath = if ($captionJob.PSObject.Properties['ErrorPath']) { [string]$captionJob.ErrorPath } else { '' }
                Invoke-ChildWorker -ScriptPath ([string]$job.CaptionWorkerPath) -ChildJobPath ([string]$item.CaptionJobPath) -ChildProgressPath ([string]$captionJob.ProgressPath) -ChildErrorPath $captionErrorPath -Index $index -Count $items.Count -Label 'captions' -Title $title
            }
        }
        $renderJob = [IO.File]::ReadAllText([string]$item.RenderJobPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
        $renderErrorPath = if ($renderJob.PSObject.Properties['ErrorPath']) { [string]$renderJob.ErrorPath } else { '' }
        Invoke-ChildWorker -ScriptPath ([string]$job.RenderWorkerPath) -ChildJobPath ([string]$item.RenderJobPath) -ChildProgressPath ([string]$renderJob.ProgressPath) -ChildErrorPath $renderErrorPath -Index $index -Count $items.Count -Label 'rendering' -Title $title
        Write-BatchProgress ((($index + 1) / [double]$items.Count) * 100.0) "Completed project $($index + 1) of $($items.Count)."
    }
    if (Test-Path -LiteralPath ([string]$job.ChildPidPath) -PathType Leaf) { Remove-Item -LiteralPath ([string]$job.ChildPidPath) -Force }
    Write-BatchProgress 100 "Batch completed: $($items.Count) videos."
    exit 0
}
catch {
    [IO.File]::WriteAllText([string]$job.ErrorPath, ($_.Exception.Message + "`r`n`r`n--- worker stack ---`r`n" + $_.Exception.GetType().FullName + "`r`n" + $_.ScriptStackTrace), [Text.UTF8Encoding]::new($false))
    try { Write-BatchProgress 0 'Batch paused. Finished videos and resumable segments were kept.' } catch {}
    exit 1
}
