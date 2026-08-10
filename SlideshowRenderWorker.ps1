[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-WorkerProgress {
    param([double]$Percent, [string]$Message)
    $text = "percent=$($Percent.ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))`r`nmessage=$Message`r`n"
    [IO.File]::WriteAllText([string]$script:Job.ProgressPath, $text, [Text.UTF8Encoding]::new($false))
}

function Quote-Argument {
    param([string]$Value)
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + $Value.Replace('\','\').Replace('"','\"') + '"'
}

function Join-Arguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object { Quote-Argument $_ }) -join ' ')
}

function Get-FfmpegSeconds {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 0.0 }
    try {
        $text = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $match = [regex]::Match($text, '(?m)^out_time=(\d+):(\d+):(\d+(?:\.\d+)?)')
        if ($match.Success) {
            return ([double]$match.Groups[1].Value * 3600.0) + ([double]$match.Groups[2].Value * 60.0) + [double]::Parse($match.Groups[3].Value, [Globalization.CultureInfo]::InvariantCulture)
        }
        $us = [regex]::Matches($text, '(?m)^out_time_us=(\d+)')
        if ($us.Count -gt 0) { return [double]$us[$us.Count - 1].Groups[1].Value / 1000000.0 }
    }
    catch {}
    return 0.0
}

function Start-LoudnessAnalysis {
    # YouTube plays everything back at roughly -14 LUFS, and it only turns loud
    # uploads down: a quiet one is never raised. Normalising here keeps the
    # channel level with everything beside it in the sidebar.
    #
    # This runs loudnorm's analysis pass first and feeds the measurements back
    # into the real pass. Single-pass loudnorm has to guess as it goes, which
    # makes speech breathe audibly; with measured values it applies one constant
    # gain instead. If the analysis fails for any reason, the single pass is
    # still far better than leaving the audio 11 dB down, so fall back to it.
    #
    # The measurement is started before the first segment renders and collected
    # once the last one finishes. It has to decode the whole voiceover, and
    # doing that after the video was finished left the machine idle on a single
    # core for that whole time with nothing else to do.
    param(
        [string]$AudioPath,
        [string]$ReportPath,
        [double]$TargetLufs = -14.0,
        [double]$TruePeak = -1.5,
        [double]$Range = 11.0
    )

    $culture = [Globalization.CultureInfo]::InvariantCulture
    $target = $TargetLufs.ToString('0.##', $culture)
    $peak = $TruePeak.ToString('0.##', $culture)
    $range = $Range.ToString('0.##', $culture)
    $singlePass = "loudnorm=I=$target`:TP=$peak`:LRA=$range"
    $analysis = [pscustomobject]@{
        Process = $null
        ReportPath = $ReportPath
        SinglePass = $singlePass
    }

    try {
        if ([string]::IsNullOrWhiteSpace($AudioPath) -or -not (Test-Path -LiteralPath $AudioPath -PathType Leaf)) {
            return $analysis
        }
        if (Test-Path -LiteralPath $ReportPath -PathType Leaf) { Remove-Item -LiteralPath $ReportPath -Force }
        # -vn keeps this to the audio stream. The voiceover is normally an M4A,
        # but measuring a file that also carries video would otherwise decode
        # every frame just to read its loudness. One thread is plenty and keeps
        # the measurement out of the render lanes' way.
        $arguments = @(
            '-hide_banner', '-nostats', '-threads', '1', '-vn', '-i', $AudioPath,
            '-af', "$singlePass`:print_format=json", '-f', 'null', '-'
        )
        $analysis.Process = Start-Process -FilePath ([string]$script:Job.FfmpegPath) -ArgumentList (Join-Arguments $arguments) -PassThru -WindowStyle Hidden -RedirectStandardError $ReportPath
        $null = $analysis.Process.Handle
    }
    catch {
        $analysis.Process = $null
    }
    return $analysis
}

function Complete-LoudnessFilter {
    param([psobject]$Analysis)

    $singlePass = [string]$Analysis.SinglePass
    $process = $Analysis.Process
    if ($null -eq $process) { return $singlePass }

    try {
        $process.WaitForExit()
        $process.Refresh()
        if ($process.ExitCode -ne 0) { return $singlePass }
        if (-not (Test-Path -LiteralPath ([string]$Analysis.ReportPath) -PathType Leaf)) { return $singlePass }
        $measured = Get-Content -LiteralPath ([string]$Analysis.ReportPath) -Raw -ErrorAction Stop

        # loudnorm prints its JSON report as the last block on stderr.
        $match = [regex]::Match($measured, '(?s)\{[^{}]*"input_i".*?\}')
        if (-not $match.Success) { return $singlePass }
        $report = $match.Value | ConvertFrom-Json

        $culture = [Globalization.CultureInfo]::InvariantCulture
        foreach ($field in @('input_i', 'input_tp', 'input_lra', 'input_thresh', 'target_offset')) {
            $value = [double]0
            if (-not [double]::TryParse([string]$report.$field, [Globalization.NumberStyles]::Float, $culture, [ref]$value)) {
                return $singlePass
            }
            # A silent or unreadable track reports -inf and cannot be normalised.
            if ([double]::IsNaN($value) -or [double]::IsInfinity($value)) { return $singlePass }
        }

        return ($singlePass +
            ":measured_I=$($report.input_i)" +
            ":measured_TP=$($report.input_tp)" +
            ":measured_LRA=$($report.input_lra)" +
            ":measured_thresh=$($report.input_thresh)" +
            ":offset=$($report.target_offset)" +
            ':linear=true')
    }
    catch {
        return $singlePass
    }
    finally {
        try { $process.Dispose() } catch {}
    }
}

function Invoke-TrackedFfmpeg {
    param(
        [string[]]$Arguments,
        [string]$ProgressFile,
        [string]$ErrorFile,
        [int]$CompletedFrames,
        [int]$CurrentFrames,
        [int]$TotalFrames,
        [string]$Message
    )
    if (Test-Path -LiteralPath $ProgressFile -PathType Leaf) { Remove-Item -LiteralPath $ProgressFile -Force }
    $argumentLine = Join-Arguments $Arguments
    $process = Start-Process -FilePath ([string]$script:Job.FfmpegPath) -ArgumentList $argumentLine -PassThru -WindowStyle Hidden -RedirectStandardError $ErrorFile
    # Windows PowerShell 5 can lose ExitCode unless the native process handle
    # is materialized before HasExited is polled.
    $null = $process.Handle
    [IO.File]::WriteAllText([string]$script:Job.ChildPidPath, [string]$process.Id, [Text.Encoding]::ASCII)
    while (-not $process.HasExited) {
        $seconds = Get-FfmpegSeconds $ProgressFile
        $current = [Math]::Min($CurrentFrames, [Math]::Max(0, [int][Math]::Floor($seconds * 24.0)))
        $percent = (($CompletedFrames + $current) / [double]$TotalFrames) * 94.0
        Write-WorkerProgress -Percent $percent -Message $Message
        Start-Sleep -Milliseconds 350
        $process.Refresh()
    }
    $process.WaitForExit()
    $process.Refresh()
    if (Test-Path -LiteralPath ([string]$script:Job.ChildPidPath) -PathType Leaf) { Remove-Item -LiteralPath ([string]$script:Job.ChildPidPath) -Force }
    if ($process.ExitCode -ne 0) {
        $details = ''
        if (Test-Path -LiteralPath $ErrorFile -PathType Leaf) {
            $rawDetails = Get-Content -LiteralPath $ErrorFile -Raw -ErrorAction SilentlyContinue
            if ($null -ne $rawDetails) { $details = $rawDetails.Trim() }
        }
        throw "FFmpeg failed with code $($process.ExitCode). $details"
    }
}

function Test-EncoderSessionFailure {
    # A hardware encoder refuses to open beyond its concurrent session limit
    # rather than queueing, so the lane dies immediately instead of running
    # slowly. GeForce drivers historically allowed only two or three NVENC
    # sessions at once; AMF and QSV have their own ceilings. The text below is
    # what each one prints when it runs out.
    param([string]$Details)
    if ([string]::IsNullOrWhiteSpace($Details)) { return $false }
    return ($Details -match '(?i)OpenEncodeSessionEx|incompatible client key|out of memory|NV_ENC_ERR|no capable devices|Error initializing output stream|Cannot load nvEncodeAPI|failed to create encoder|D3D11|session')
}

function Invoke-ParallelSegmentJobs {
    param(
        [object[]]$Jobs,
        [int]$CompletedFrames,
        [int]$TotalFrames,
        [int]$Fps,
        [int]$MaximumParallel = 2
    )
    if ($Jobs.Count -eq 0) { return $CompletedFrames }
    # Honour the per-machine lane count worked out by the caller. This used to
    # be clamped to two no matter what was passed in, so a sixteen-core
    # workstation rendered with the same concurrency as a four-core laptop and
    # left most of its cores idle for the whole job.
    $maximum = [Math]::Max(1, $MaximumParallel)
    $pending = [Collections.Generic.Queue[object]]::new()
    foreach ($jobItem in $Jobs) { $pending.Enqueue($jobItem) }
    $active = [Collections.Generic.List[object]]::new()
    $finishedFrames = $CompletedFrames
    # Lanes that die because the hardware encoder ran out of sessions are
    # retried at a lower concurrency instead of failing the render. Each
    # segment gets a limited number of attempts so a genuine, repeatable fault
    # still surfaces as an error rather than looping forever.
    $attempts = @{}
    $maximumAttempts = 3

    try {
        while ($pending.Count -gt 0 -or $active.Count -gt 0) {
            while ($pending.Count -gt 0 -and $active.Count -lt $maximum) {
                $item = $pending.Dequeue()
                if (Test-Path -LiteralPath ([string]$item.ProgressFile) -PathType Leaf) { Remove-Item -LiteralPath ([string]$item.ProgressFile) -Force }
                if (Test-Path -LiteralPath ([string]$item.ErrorFile) -PathType Leaf) { Remove-Item -LiteralPath ([string]$item.ErrorFile) -Force }
                $process = Start-Process -FilePath ([string]$script:Job.FfmpegPath) -ArgumentList (Join-Arguments ([string[]]$item.Arguments)) -PassThru -WindowStyle Hidden -RedirectStandardError ([string]$item.ErrorFile)
                $null = $process.Handle
                $active.Add([pscustomobject]@{ Definition = $item; Process = $process })
            }

            if ($active.Count -gt 0) {
                [IO.File]::WriteAllLines([string]$script:Job.ChildPidPath, @($active | ForEach-Object { [string]$_.Process.Id }), [Text.Encoding]::ASCII)
            }

            $runningFrames = 0
            for ($index = $active.Count - 1; $index -ge 0; $index--) {
                $entry = $active[$index]
                $entry.Process.Refresh()
                if ($entry.Process.HasExited) {
                    $entry.Process.WaitForExit()
                    $entry.Process.Refresh()
                    $exitCode = $entry.Process.ExitCode
                    $segmentNumber = [int]$entry.Definition.SegmentIndex + 1
                    $details = ''
                    if ($exitCode -ne 0 -and (Test-Path -LiteralPath ([string]$entry.Definition.ErrorFile) -PathType Leaf)) {
                        $raw = Get-Content -LiteralPath ([string]$entry.Definition.ErrorFile) -Raw -ErrorAction SilentlyContinue
                        if ($null -ne $raw) { $details = $raw.Trim() }
                    }
                    $entry.Process.Dispose()
                    $active.RemoveAt($index)

                    if ($exitCode -ne 0) {
                        $key = [string]$entry.Definition.SegmentIndex
                        $used = if ($attempts.ContainsKey($key)) { [int]$attempts[$key] } else { 0 }
                        $used++
                        $attempts[$key] = $used
                        # Only back off for the failure that concurrency can
                        # actually cause. Anything else is a real fault and is
                        # reported straight away.
                        if ($maximum -gt 1 -and $used -lt $maximumAttempts -and (Test-EncoderSessionFailure -Details $details)) {
                            $maximum = [Math]::Max(1, $maximum - 1)
                            Write-WorkerProgress -Percent ([Math]::Min(94.0, (($finishedFrames + $runningFrames) / [double]$TotalFrames) * 94.0)) -Message "The graphics card refused another simultaneous encode. Continuing with $maximum at a time..."
                            $pending.Enqueue($entry.Definition)
                            continue
                        }
                        throw "Segment $segmentNumber failed with FFmpeg code $exitCode. $details"
                    }
                    if (-not (Test-Segment -Path ([string]$entry.Definition.SegmentPath) -ExpectedSeconds ([double]$entry.Definition.ExpectedSeconds))) {
                        throw "Segment $segmentNumber did not pass validation."
                    }
                    $finishedFrames += [int]$entry.Definition.FrameCount
                }
                else {
                    $seconds = Get-FfmpegSeconds ([string]$entry.Definition.ProgressFile)
                    $runningFrames += [Math]::Min([int]$entry.Definition.FrameCount, [Math]::Max(0, [int][Math]::Floor($seconds * $Fps)))
                }
            }

            $percent = (($finishedFrames + $runningFrames) / [double]$TotalFrames) * 94.0
            $activeNumbers = @($active | ForEach-Object { ([int]$_.Definition.SegmentIndex + 1) }) -join ' and '
            $message = if ($activeNumbers) { "Rendering segments $activeNumbers simultaneously..." } else { 'Preparing the next render segments...' }
            Write-WorkerProgress -Percent ([Math]::Min(94.0, $percent)) -Message $message
            if ($active.Count -gt 0) { Start-Sleep -Milliseconds 350 }
        }
    }
    catch {
        foreach ($entry in @($active)) {
            try { if (-not $entry.Process.HasExited) { $entry.Process.Kill() } } catch {}
            try { $entry.Process.Dispose() } catch {}
        }
        throw
    }
    finally {
        if (Test-Path -LiteralPath ([string]$script:Job.ChildPidPath) -PathType Leaf) { Remove-Item -LiteralPath ([string]$script:Job.ChildPidPath) -Force }
    }
    return $finishedFrames
}

function Get-MediaDuration {
    param([string]$Path)
    try {
        $value = & ([string]$script:Job.FfprobePath) '-v' 'error' '-show_entries' 'format=duration' '-of' 'default=noprint_wrappers=1:nokey=1' $Path 2>$null
        if ($LASTEXITCODE -ne 0) { return 0.0 }
    }
    catch { return 0.0 }
    $duration = 0.0
    [void][double]::TryParse(([string]$value).Trim(), [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$duration)
    return $duration
}

function Test-Segment {
    param([string]$Path, [double]$ExpectedSeconds)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -lt 50000) { return $false }
    $duration = Get-MediaDuration $Path
    return ($duration -gt 0 -and [Math]::Abs($duration - $ExpectedSeconds) -lt 0.35)
}

function ConvertTo-SrtTime {
    param([TimeSpan]$Time)
    if ($Time.TotalMilliseconds -lt 0) { $Time = [TimeSpan]::Zero }
    $hours = [int][Math]::Floor($Time.TotalHours)
    return ('{0:00}:{1:00}:{2:00},{3:000}' -f $hours, $Time.Minutes, $Time.Seconds, $Time.Milliseconds)
}

function New-SegmentSubtitle {
    param([string]$SourcePath, [double]$StartSeconds, [double]$DurationSeconds, [string]$DestinationPath, [int]$MaxWordsPerLine = 8)
    if ([string]::IsNullOrWhiteSpace($SourcePath) -or -not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) { return '' }
    $source = Get-Content -LiteralPath $SourcePath -Raw
    $pattern = '(?ms)^\s*\d+\s*\r?\n(?<start>\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(?<end>\d{2}:\d{2}:\d{2},\d{3})[^\r\n]*\r?\n(?<text>.*?)(?=\r?\n\s*\r?\n|\z)'
    $blocks = [regex]::Matches($source, $pattern)
    $segmentStart = [TimeSpan]::FromSeconds($StartSeconds)
    $segmentEnd = [TimeSpan]::FromSeconds($StartSeconds + $DurationSeconds)
    $output = [Text.StringBuilder]::new()
    $index = 1
    foreach ($block in $blocks) {
        $start = [TimeSpan]::ParseExact($block.Groups['start'].Value, 'hh\:mm\:ss\,fff', [Globalization.CultureInfo]::InvariantCulture)
        $end = [TimeSpan]::ParseExact($block.Groups['end'].Value, 'hh\:mm\:ss\,fff', [Globalization.CultureInfo]::InvariantCulture)
        if ($end -le $segmentStart -or $start -ge $segmentEnd) { continue }
        $localStart = if ($start -lt $segmentStart) { [TimeSpan]::Zero } else { $start - $segmentStart }
        $localEnd = if ($end -gt $segmentEnd) { [TimeSpan]::FromSeconds($DurationSeconds) } else { $end - $segmentStart }
        [void]$output.AppendLine([string]$index)
        [void]$output.AppendLine("$(ConvertTo-SrtTime $localStart) --> $(ConvertTo-SrtTime $localEnd)")
        [void]$output.AppendLine((Format-CaptionText -Text $block.Groups['text'].Value -MaxWordsPerLine $MaxWordsPerLine))
        [void]$output.AppendLine()
        $index++
    }
    if ($index -eq 1) { return '' }
    [IO.File]::WriteAllText($DestinationPath, $output.ToString(), [Text.UTF8Encoding]::new($true))
    return $DestinationPath
}

try {
    # Job files are written as UTF-8 without a BOM. Windows PowerShell 5 reads
    # BOM-less Get-Content input using the system ANSI code page, corrupting
    # Unicode output names (for example an em dash becomes "â€”").
    $script:Job = [IO.File]::ReadAllText($JobPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
    if (Test-Path -LiteralPath ([string]$script:Job.ErrorPath) -PathType Leaf) { Remove-Item -LiteralPath ([string]$script:Job.ErrorPath) -Force }
    Import-Module ([string]$script:Job.EngineModulePath) -Force
    $timeline = $script:Job.Timeline
    $totalFrames = [int]$timeline.TotalFrames
    $fps = [int]$timeline.Fps
    # Shorter segments pack more evenly across the parallel render lanes and
    # make Resume finer-grained. The concat step costs the same either way.
    $segmentSeconds = if ($script:Job.PSObject.Properties['SegmentSeconds']) { [int]$script:Job.SegmentSeconds } else { 30 }
    if ($segmentSeconds -lt 10) { $segmentSeconds = 10 }
    $segmentFrames = $segmentSeconds * $fps
    $segmentCount = [int][Math]::Ceiling($totalFrames / [double]$segmentFrames)
    $resumeDirectory = [string]$script:Job.ResumeDirectory
    New-Item -ItemType Directory -Path $resumeDirectory -Force | Out-Null
    Write-WorkerProgress 0 'Checking resumable render segments...'

    $watermarkDuration = Get-MediaDuration ([string]$script:Job.WatermarkPath)
    $previewSeconds = 0.0
    if ([bool]$script:Job.ReusePreview -and (Test-Path -LiteralPath ([string]$script:Job.PreviewPath) -PathType Leaf)) {
        $previewSeconds = Get-MediaDuration ([string]$script:Job.PreviewPath)
    }
    $completedFrames = 0
    $segmentJobs = [Collections.Generic.List[object]]::new()
    $openClDevice = if ($script:Job.PSObject.Properties['OpenClDevice']) { [string]$script:Job.OpenClDevice } else { '' }
    $screenKernelPath = if ($script:Job.PSObject.Properties['ScreenKernelPath']) { [string]$script:Job.ScreenKernelPath } else { '' }
    $ffmpegLogLevel = if ($script:Job.PSObject.Properties['LogLevel']) { [string]$script:Job.LogLevel } else { 'error' }
    $captionPreset = if ($script:Job.Settings.PSObject.Properties['CaptionPreset']) { [string]$script:Job.Settings.CaptionPreset } else { '1. Clean YouTube' }
    $captionWordsPerLine = if ($script:Job.Settings.PSObject.Properties['CaptionWordsPerLine']) { [int]$script:Job.Settings.CaptionWordsPerLine } else { 8 }
    $useOpenClEffects = ([string]$script:Job.Encoder -eq 'h264_nvenc') -and -not [string]::IsNullOrWhiteSpace($openClDevice) -and (Test-Path -LiteralPath $screenKernelPath -PathType Leaf)
    $maximumParallel = if ($script:Job.PSObject.Properties['ParallelSegments']) { [int]$script:Job.ParallelSegments } else { 2 }
    if ($maximumParallel -lt 1) { $maximumParallel = 1 }
    # Divide the machine between the lanes explicitly. Left to itself every
    # FFmpeg process starts as many filter threads as there are cores, so four
    # lanes on an eight-core laptop ask for thirty-two threads and spend a
    # noticeable share of the render context-switching between them.
    $logicalCores = [Environment]::ProcessorCount
    if ($logicalCores -lt 1) { $logicalCores = 1 }
    $threadsPerLane = [Math]::Max(1, [int][Math]::Floor($logicalCores / [double]$maximumParallel))
    for ($segmentIndex = 0; $segmentIndex -lt $segmentCount; $segmentIndex++) {
        $startFrame = $segmentIndex * $segmentFrames
        $frameCount = [Math]::Min($segmentFrames, $totalFrames - $startFrame)
        $durationSeconds = $frameCount / [double]$fps
        $segmentPath = Join-Path $resumeDirectory ('segment-{0:D4}.mp4' -f $segmentIndex)
        if (Test-Segment -Path $segmentPath -ExpectedSeconds $durationSeconds) {
            $completedFrames += $frameCount
            Write-WorkerProgress (($completedFrames / [double]$totalFrames) * 94.0) "Reused completed segment $($segmentIndex + 1) of $segmentCount."
            continue
        }

        # The preview can only be dropped in whole. Cutting it to a shorter
        # segment would need a keyframe at the cut, and a stream copy that
        # silently starts at the previous keyframe would pass the duration
        # check while holding the wrong frames, so only reuse an exact match.
        if ($segmentIndex -eq 0 -and [bool]$script:Job.ReusePreview -and $previewSeconds -gt 0 -and
            [Math]::Abs($previewSeconds - $durationSeconds) -lt 0.35 -and
            (Test-Path -LiteralPath ([string]$script:Job.PreviewPath) -PathType Leaf)) {
            $copyError = Join-Path $resumeDirectory 'preview-reuse-error.log'
            $copyArgs = @('-y','-hide_banner','-loglevel','error','-i',[string]$script:Job.PreviewPath,'-map','0:v:0','-an','-c:v','copy',$segmentPath)
            & ([string]$script:Job.FfmpegPath) @copyArgs 2> $copyError
            if ($LASTEXITCODE -eq 0 -and (Test-Segment -Path $segmentPath -ExpectedSeconds $durationSeconds)) {
                $completedFrames += $frameCount
                Write-WorkerProgress (($completedFrames / [double]$totalFrames) * 94.0) 'Reused the approved preview.'
                continue
            }
            if (Test-Path -LiteralPath $segmentPath -PathType Leaf) { Remove-Item -LiteralPath $segmentPath -Force }
        }

        $slice = New-TimelineSlice -Timeline $timeline -StartFrame $startFrame -FrameCount $frameCount
        $segmentSrt = ''
        if ([string]$script:Job.CaptionMode -in @('Burned only', 'Burned + SRT')) {
            $segmentSrt = New-SegmentSubtitle -SourcePath ([string]$script:Job.CaptionPath) -StartSeconds ($startFrame / [double]$fps) -DurationSeconds $durationSeconds -DestinationPath (Join-Path $resumeDirectory ('captions-{0:D4}.srt' -f $segmentIndex)) -MaxWordsPerLine $captionWordsPerLine
        }
        if ($useOpenClEffects) {
            $definition = New-FilterGraph -Timeline $slice -RenderFrames $frameCount -ZoomMaximumPercent ([double]$script:Job.Settings.ZoomMaximum) -BlurAmount ([double]$script:Job.Settings.BlurAmount) -BackgroundBrightnessPercent ([double]$script:Job.Settings.BackgroundBrightness) -SubtitlePath $segmentSrt -CaptionPreset $captionPreset -CaptionStyle $script:Job.Settings -OpenClScreenKernelPath $screenKernelPath -Width 1920 -Height 1080
        }
        elseif ([string]$script:Job.Encoder -eq 'h264_vulkan') {
            $definition = New-VulkanFilterGraph -Timeline $slice -RenderFrames $frameCount -ZoomMaximumPercent ([double]$script:Job.Settings.ZoomMaximum) -BlurAmount ([double]$script:Job.Settings.BlurAmount) -BackgroundBrightnessPercent ([double]$script:Job.Settings.BackgroundBrightness) -SubtitlePath $segmentSrt -CaptionPreset $captionPreset -CaptionStyle $script:Job.Settings -Width 1920 -Height 1080
        }
        else {
            $definition = New-FilterGraph -Timeline $slice -RenderFrames $frameCount -ZoomMaximumPercent ([double]$script:Job.Settings.ZoomMaximum) -BlurAmount ([double]$script:Job.Settings.BlurAmount) -BackgroundBrightnessPercent ([double]$script:Job.Settings.BackgroundBrightness) -SubtitlePath $segmentSrt -CaptionPreset $captionPreset -CaptionStyle $script:Job.Settings -Width 1920 -Height 1080
        }
        $filterPath = Join-Path $resumeDirectory ('filter-{0:D4}.txt' -f $segmentIndex)
        [IO.File]::WriteAllText($filterPath, $definition.FilterText, [Text.UTF8Encoding]::new($false))
        $ffProgress = Join-Path $resumeDirectory ('progress-{0:D4}.txt' -f $segmentIndex)
        $ffError = Join-Path $resumeDirectory ('error-{0:D4}.log' -f $segmentIndex)
        $arguments = [Collections.Generic.List[string]]::new()
        foreach ($value in @('-y','-hide_banner','-loglevel',$ffmpegLogLevel,'-nostats','-progress',$ffProgress,'-filter_complex_threads',[string]$threadsPerLane)) { $arguments.Add($value) }
        if ($useOpenClEffects) {
            foreach ($value in @('-init_hw_device',"opencl=screencl:$openClDevice",'-filter_hw_device','screencl')) { $arguments.Add($value) }
        }
        elseif ([string]$script:Job.Encoder -eq 'h264_vulkan') {
            foreach ($value in @('-init_hw_device',"vulkan=slideshowgpu:$([int]$script:Job.VulkanDeviceIndex)",'-filter_hw_device','slideshowgpu')) { $arguments.Add($value) }
        }
        foreach ($value in @('-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-stream_loop','-1')) { $arguments.Add($value) }
        if ($watermarkDuration -gt 0) {
            $offset = ($startFrame / [double]$fps) % $watermarkDuration
            $arguments.Add('-ss'); $arguments.Add($offset.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture))
        }
        $arguments.Add('-i'); $arguments.Add([string]$script:Job.WatermarkPath)
        foreach ($imagePath in $definition.ImageInputs) { $arguments.Add('-i'); $arguments.Add([string]$imagePath) }
        foreach ($value in @('-filter_complex_script',$filterPath,'-map','[vout]')) { $arguments.Add($value) }
        foreach ($value in (Get-EncodingArguments -Encoder ([string]$script:Job.Encoder) -Quality ([string]$script:Job.Settings.Quality))) { $arguments.Add($value) }
        # -r is what makes the segment record its true length. Without it the
        # MP4 duration is written as the last frame's timestamp rather than that
        # timestamp plus one frame, so the segment reads one frame short. The
        # concat demuxer then starts the next segment a frame early and the two
        # frames either side of every join land on the same presentation time.
        foreach ($value in @('-threads',[string]$threadsPerLane,'-r',[string]$fps,'-frames:v',[string]$frameCount,'-an',$segmentPath)) { $arguments.Add($value) }
        $segmentJobs.Add([pscustomobject]@{
            Arguments = $arguments.ToArray()
            ProgressFile = $ffProgress
            ErrorFile = $ffError
            SegmentPath = $segmentPath
            SegmentIndex = $segmentIndex
            FrameCount = $frameCount
            ExpectedSeconds = $durationSeconds
        })
    }

    $loudnessTarget = if ($script:Job.PSObject.Properties['LoudnessTargetLufs']) { [double]$script:Job.LoudnessTargetLufs } else { -14.0 }
    $loudnessAnalysis = Start-LoudnessAnalysis -AudioPath ([string]$script:Job.AudioPath) -ReportPath (Join-Path $resumeDirectory 'loudness.json') -TargetLufs $loudnessTarget

    $completedFrames = Invoke-ParallelSegmentJobs -Jobs $segmentJobs.ToArray() -CompletedFrames $completedFrames -TotalFrames $totalFrames -Fps $fps -MaximumParallel $maximumParallel

    Write-WorkerProgress 95 'Measuring voiceover loudness...'
    $loudnessFilter = Complete-LoudnessFilter -Analysis $loudnessAnalysis

    Write-WorkerProgress 95 'Joining segments and adding the voiceover...'
    $concatPath = Join-Path $resumeDirectory 'segments.txt'
    $concatLines = for ($index = 0; $index -lt $segmentCount; $index++) {
        $path = (Join-Path $resumeDirectory ('segment-{0:D4}.mp4' -f $index)).Replace("'", "'\''")
        "file '$($path.Replace('\','/'))'"
    }
    [IO.File]::WriteAllLines($concatPath, $concatLines, [Text.UTF8Encoding]::new($false))
    $stagingPath = [string]$script:Job.StagingPath
    $audioBitrate = if ([string]$script:Job.Settings.Quality -eq 'YouTube') { '384k' } else { '160k' }
    $muxProgress = Join-Path $resumeDirectory 'mux-progress.txt'
    $muxError = Join-Path $resumeDirectory 'mux-error.log'
    # -ar 48000 after the filter matters: loudnorm resamples internally, and
    # without it the muxed track can leave at loudnorm's own rate.
    $muxArguments = @('-y','-hide_banner','-loglevel','error','-nostats','-progress',$muxProgress,'-f','concat','-safe','0','-i',$concatPath,'-i',[string]$script:Job.AudioPath,'-map','0:v:0','-map','1:a:0','-c:v','copy','-af',$loudnessFilter,'-c:a','aac','-b:a',$audioBitrate,'-ar','48000','-ac','2','-shortest','-movflags','+faststart',$stagingPath)
    Invoke-TrackedFfmpeg -Arguments $muxArguments -ProgressFile $muxProgress -ErrorFile $muxError -CompletedFrames $totalFrames -CurrentFrames 0 -TotalFrames $totalFrames -Message 'Joining segments and adding the voiceover...'
    if (-not (Test-Path -LiteralPath $stagingPath -PathType Leaf)) { throw 'The final staging video was not created.' }
    if (Test-Path -LiteralPath ([string]$script:Job.DestinationPath) -PathType Leaf) { Remove-Item -LiteralPath ([string]$script:Job.DestinationPath) -Force }
    Move-Item -LiteralPath $stagingPath -Destination ([string]$script:Job.DestinationPath) -Force
    if ([string]$script:Job.CaptionMode -in @('SRT only', 'Burned + SRT') -and (Test-Path -LiteralPath ([string]$script:Job.CaptionPath) -PathType Leaf)) {
        [void](Copy-SrtWithWordWrapping -SourcePath ([string]$script:Job.CaptionPath) -DestinationPath ([IO.Path]::ChangeExtension([string]$script:Job.DestinationPath, '.srt')) -MaxWordsPerLine $captionWordsPerLine)
    }
    Write-WorkerProgress 100 'Final video completed.'
    if (Test-Path -LiteralPath $resumeDirectory -PathType Container) { Remove-Item -LiteralPath $resumeDirectory -Recurse -Force }
    exit 0
}
catch {
    $message = $_.Exception.ToString() + "`r`n" + $_.ScriptStackTrace
    [IO.File]::WriteAllText([string]$script:Job.ErrorPath, $message, [Text.UTF8Encoding]::new($false))
    try { Write-WorkerProgress 0 'Rendering paused. Completed segments were kept for Resume.' } catch {}
    exit 1
}
