[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-JobOverscanScale {
    $settings = $script:Job.Settings
    if ($null -eq $settings.PSObject.Properties['MotionQuality']) { return 1.1 }
    switch ([string]$settings.MotionQuality) {
        'Fast'    { return 1.0 }
        'Best'    { return 1.5 }
        default   { return 1.1 }
    }
}

function Get-JobCrossfadeSeconds {
    $settings = $script:Job.Settings
    if ($null -eq $settings.PSObject.Properties['Crossfade'] -or -not [bool]$settings.Crossfade) { return 0.0 }
    if ($null -eq $settings.PSObject.Properties['CrossfadeSeconds']) { return 0.5 }
    return [double]$settings.CrossfadeSeconds
}

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

function Step-VoiceoverEncode {
    # Encodes the normalised voiceover while the video segments render, so
    # the final join only copies streams. Measured on a 20-minute video, the
    # loudnorm pass and AAC encode took 51 seconds when they ran after the
    # last segment - a third of the whole render once motion moved to the
    # GPU - and the copy-only join takes under one. Called on every tick of
    # the segment loop; it starts the encode as soon as the loudness
    # analysis it depends on has finished, and otherwise does nothing.
    param([psobject]$State)
    if ($State.Done -or $null -ne $State.Process) { return }
    $analysisProcess = $State.Analysis.Process
    if ($null -ne $analysisProcess) {
        $analysisProcess.Refresh()
        if (-not $analysisProcess.HasExited) { return }
    }
    $State.Filter = Complete-LoudnessFilter -Analysis $State.Analysis
    # Complete-LoudnessFilter has disposed of it.
    $State.Analysis.Process = $null
    if (Test-Path -LiteralPath $State.PartialPath -PathType Leaf) { Remove-Item -LiteralPath $State.PartialPath -Force }
    # -ar 48000 after the filter matters: loudnorm resamples internally, and
    # without it the track can leave at loudnorm's own rate.
    $arguments = @('-y','-hide_banner','-loglevel','error','-nostats','-threads','1','-vn','-i',[string]$script:Job.AudioPath,'-af',$State.Filter,'-c:a','aac','-b:a',$State.Bitrate,'-ar','48000','-ac','2',$State.PartialPath)
    $State.Process = Start-Process -FilePath ([string]$script:Job.FfmpegPath) -ArgumentList (Join-Arguments $arguments) -PassThru -WindowStyle Hidden -RedirectStandardError $State.ErrorPath
    $null = $State.Process.Handle
}

function Complete-VoiceoverEncode {
    # Waits for the voiceover encode and keeps it for Resume. Returns $false
    # if it failed, in which case the join encodes the voiceover itself.
    param([psobject]$State)
    if ($State.Done) { return $true }
    if ($null -ne $State.Analysis -and $null -ne $State.Analysis.Process) { $State.Analysis.Process.WaitForExit() }
    Step-VoiceoverEncode -State $State
    if ($null -eq $State.Process) { return $false }
    $State.Process.WaitForExit()
    $State.Process.Refresh()
    $exitCode = $State.Process.ExitCode
    $State.Process.Dispose()
    $State.Process = $null
    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $State.PartialPath -PathType Leaf)) {
        Write-WorkerDiagnostic "The voiceover could not be encoded ahead of the join (FFmpeg code $exitCode); the join encodes it instead."
        return $false
    }
    Move-Item -LiteralPath $State.PartialPath -Destination $State.Path -Force
    $State.Done = $true
    return $true
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
            $rawDetails = Get-Content -LiteralPath $ErrorFile -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
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
    #
    # The list used to know only NVENC's words. FFmpeg 7 no longer prints
    # "Error initializing output stream" at all, and AMF says "encoder->Init()
    # failed" or "CreateComponent(...) failed" before FFmpeg's own "Error while
    # opening encoder" - none of which matched. On a Radeon, a lane the card
    # refused therefore stopped the whole render instead of stepping down. A
    # genuine fault that happens to match costs only the step-downs: once the
    # render is down to one lane, the same failure is reported as it stands.
    param([string]$Details)
    if ([string]::IsNullOrWhiteSpace($Details)) { return $false }
    return ($Details -match '(?i)OpenEncodeSessionEx|incompatible client key|out of memory|NV_ENC_ERR|no capable devices|Error initializing output stream|Error while opening encoder|Cannot load nvEncodeAPI|failed to create encoder|D3D11|session|encoder->Init\(\) failed|CreateComponent\(|CreateContext\(\) failed|InitDX1[01]\(\) failed|SubmitInput\(\) failed|AMF_|MFX_ERR|Error initializing an internal MFX session')
}

function Invoke-ParallelSegmentJobs {
    param(
        [object[]]$Jobs,
        [int]$CompletedFrames,
        [int]$TotalFrames,
        [int]$Fps,
        [int]$MaximumParallel = 2,
        # Run on every pass of the polling loop, for work that rides along
        # with the segments (the voiceover encode).
        [scriptblock]$OnTick = $null
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
                        $raw = Get-Content -LiteralPath ([string]$entry.Definition.ErrorFile) -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
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
                    $problem = Get-SegmentProblem -Path ([string]$entry.Definition.SegmentPath) -ExpectedSeconds ([double]$entry.Definition.ExpectedSeconds)
                    if ($problem) {
                        throw "Segment $segmentNumber did not pass validation: $problem"
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
            if ($null -ne $OnTick) { & $OnTick }
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

function Get-VideoPacketCount {
    param([string]$Path)
    try {
        $value = & ([string]$script:Job.FfprobePath) '-v' 'error' '-select_streams' 'v:0' '-count_packets' '-show_entries' 'stream=nb_read_packets' '-of' 'default=noprint_wrappers=1:nokey=1' $Path 2>$null
        if ($LASTEXITCODE -ne 0) { return -1 }
    }
    catch { return -1 }
    $count = -1
    if (-not [int]::TryParse(([string]$value).Trim(), [ref]$count)) { return -1 }
    return $count
}

function Get-SegmentProblem {
    # Returns '' for a good segment, otherwise what is wrong with it.
    #
    # This used to demand at least 50,000 bytes. The last segment of a video
    # holds whatever is left after the 30-second segments, which can be a
    # handful of frames, and a few frames of a still photograph encode to
    # about 17-22 KB. Every video whose length landed just past a 30-second
    # mark therefore failed on its last segment, every time, Resume included.
    # Counting the frames is the check the size was standing in for.
    param([string]$Path, [double]$ExpectedSeconds)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return 'the file was not written.' }
    $file = Get-Item -LiteralPath $Path
    if ($file.Length -lt 1024) { return "the file is only $($file.Length) bytes." }
    $fps = [int]$script:Job.Timeline.Fps
    $expectedFrames = [int][Math]::Round($ExpectedSeconds * $fps)
    $frames = Get-VideoPacketCount $Path
    if ($frames -lt 0) { return 'FFprobe could not read it.' }
    if ($frames -ne $expectedFrames) { return "it holds $frames frames instead of $expectedFrames." }
    $duration = Get-MediaDuration $Path
    if ($duration -le 0 -or [Math]::Abs($duration - $ExpectedSeconds) -ge 0.35) {
        return ('it lasts {0:0.000} s instead of {1:0.000} s.' -f $duration, $ExpectedSeconds)
    }
    return ''
}

function Test-Segment {
    param([string]$Path, [double]$ExpectedSeconds)
    return [string]::IsNullOrEmpty((Get-SegmentProblem -Path $Path -ExpectedSeconds $ExpectedSeconds))
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
    $source = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8
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

function New-SegmentCommand {
    # The FFmpeg command that renders frames StartFrame to StartFrame +
    # FrameCount of the timeline into SegmentPath, on one filter backend.
    # Used for the video's segments and, unchanged, for the speed test that
    # measures this machine, so the test renders exactly what a video would.
    param(
        [ValidateSet('opencl', 'vulkan', 'cpu')][string]$Backend,
        [string]$Device = '',
        [string]$SegmentDirectory,
        [string]$SegmentPath,
        [string]$Prefix,
        [int]$SegmentIndex,
        [int]$StartFrame,
        [int]$FrameCount,
        [int]$ThreadsPerLane
    )
    $segmentIndex = $SegmentIndex
    $startFrame = $StartFrame
    $frameCount = $FrameCount
    $segmentPath = $SegmentPath
    $durationSeconds = $frameCount / [double]$fps
    $slice = New-TimelineSlice -Timeline $timeline -StartFrame $startFrame -FrameCount $frameCount
    $segmentSrt = ''
    if ([string]$script:Job.CaptionMode -in @('Burned only', 'Burned + SRT')) {
        $segmentSrt = New-SegmentSubtitle -SourcePath ([string]$script:Job.CaptionPath) -StartSeconds ($startFrame / [double]$fps) -DurationSeconds $durationSeconds -DestinationPath (Join-Path $SegmentDirectory ("$Prefix-captions.srt")) -MaxWordsPerLine $captionWordsPerLine
    }
    if ($Backend -eq 'opencl') {
        $kernelPath = Join-Path $SegmentDirectory ("$Prefix-motion.cl")
        $definition = New-OpenClFilterGraph -Timeline $slice -RenderFrames $frameCount -MotionKernelPath $kernelPath -WatermarkRect $watermarkRect -WatermarkLoopFrames $watermarkLoopFrames -ZoomMaximumPercent ([double]$script:Job.Settings.ZoomMaximum) -BlurAmount ([double]$script:Job.Settings.BlurAmount) -BackgroundBrightnessPercent ([double]$script:Job.Settings.BackgroundBrightness) -SubtitlePath $segmentSrt -CaptionPreset $captionPreset -CaptionStyle $script:Job.Settings -CrossfadeSeconds (Get-JobCrossfadeSeconds) -OverscanScale (Get-JobOverscanScale) -Width 1920 -Height 1080
        [IO.File]::WriteAllText($kernelPath, $definition.KernelSource, [Text.UTF8Encoding]::new($false))
    }
    elseif ($Backend -eq 'vulkan') {
        $definition = New-VulkanFilterGraph -Timeline $slice -RenderFrames $frameCount -ZoomMaximumPercent ([double]$script:Job.Settings.ZoomMaximum) -BlurAmount ([double]$script:Job.Settings.BlurAmount) -BackgroundBrightnessPercent ([double]$script:Job.Settings.BackgroundBrightness) -SubtitlePath $segmentSrt -CaptionPreset $captionPreset -CaptionStyle $script:Job.Settings -HardwareOutputFrames ([string]$script:Job.Encoder -eq 'h264_vulkan') -CrossfadeSeconds (Get-JobCrossfadeSeconds) -OverscanScale (Get-JobOverscanScale) -Width 1920 -Height 1080
    }
    else {
        $definition = New-FilterGraph -Timeline $slice -RenderFrames $frameCount -ZoomMaximumPercent ([double]$script:Job.Settings.ZoomMaximum) -BlurAmount ([double]$script:Job.Settings.BlurAmount) -BackgroundBrightnessPercent ([double]$script:Job.Settings.BackgroundBrightness) -SubtitlePath $segmentSrt -CaptionPreset $captionPreset -CaptionStyle $script:Job.Settings -HardwareOutputFrames:([string]$script:Job.Encoder -eq 'h264_vulkan') -CrossfadeSeconds (Get-JobCrossfadeSeconds) -OverscanScale (Get-JobOverscanScale) -Width 1920 -Height 1080
    }
    $filterPath = Join-Path $SegmentDirectory ("$Prefix-filter.txt")
    [IO.File]::WriteAllText($filterPath, $definition.FilterText, [Text.UTF8Encoding]::new($false))
    $ffProgress = Join-Path $SegmentDirectory ("$Prefix-progress.txt")
    $ffError = Join-Path $SegmentDirectory ("$Prefix-error.log")
    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($value in @('-y','-hide_banner','-loglevel',$ffmpegLogLevel,'-nostats','-progress',$ffProgress,'-filter_complex_threads',[string]$ThreadsPerLane)) { $arguments.Add($value) }
    if ($Backend -eq 'opencl') {
        foreach ($value in @('-init_hw_device',"opencl=screencl:$Device",'-filter_hw_device','screencl')) { $arguments.Add($value) }
    }
    elseif ($Backend -eq 'vulkan') {
        foreach ($value in @('-init_hw_device',"vulkan=slideshowgpu:$filterVulkanDeviceIndex",'-filter_hw_device','slideshowgpu')) { $arguments.Add($value) }
    }
    elseif ([string]$script:Job.Encoder -eq 'h264_vulkan') {
        # Processor graph, Vulkan encoder: the graph's last step uploads to this device.
        foreach ($value in @('-init_hw_device',"vulkan=slideshowgpu:$([int]$script:Job.VulkanDeviceIndex)",'-filter_hw_device','slideshowgpu')) { $arguments.Add($value) }
    }
    foreach ($value in @('-f','lavfi','-i','anullsrc=r=48000:cl=stereo','-stream_loop','-1')) { $arguments.Add($value) }
    # With NVENC there is an NVIDIA card, so NVDEC decodes the watermark;
    # FFmpeg falls back to software for a codec it lacks (ProRes, PNG). Other
    # makers decode it in software: on the GPU path only one cycle of the
    # watermark is decoded per segment, so that costs little, and d3d11va
    # picks whichever adapter it likes - on a hybrid laptop the wrong one,
    # which made NVENC fail.
    if ($Backend -eq 'opencl' -and [string]$script:Job.Encoder -eq 'h264_nvenc') { $arguments.Add('-hwaccel'); $arguments.Add('cuda') }
    if ($watermarkDuration -gt 0) {
        $offset = ($startFrame / [double]$fps) % $watermarkDuration
        $arguments.Add('-ss'); $arguments.Add($offset.ToString('0.######', [Globalization.CultureInfo]::InvariantCulture))
    }
    $arguments.Add('-i'); $arguments.Add([string]$script:Job.WatermarkPath)
    foreach ($imagePath in $definition.ImageInputs) { $arguments.Add('-i'); $arguments.Add([string]$imagePath) }
    foreach ($value in @('-filter_complex_script',$filterPath,'-map','[vout]')) { $arguments.Add($value) }
    foreach ($value in (Get-EncodingArguments -Encoder ([string]$script:Job.Encoder) -Quality ([string]$script:Job.Settings.Quality) -Fps $fps)) { $arguments.Add($value) }
    # -r is what makes the segment record its true length. Without it the
    # MP4 duration is written as the last frame's timestamp rather than that
    # timestamp plus one frame, so the segment reads one frame short. The
    # concat demuxer then starts the next segment a frame early and the two
    # frames either side of every join land on the same presentation time.
    foreach ($value in @('-threads',[string]$ThreadsPerLane,'-r',[string]$fps,'-frames:v',[string]$frameCount,'-an',$segmentPath)) { $arguments.Add($value) }
    return [pscustomobject]@{
        Arguments = $arguments.ToArray()
        ProgressFile = $ffProgress
        ErrorFile = $ffError
        SegmentPath = $segmentPath
        SegmentIndex = $segmentIndex
        FrameCount = $frameCount
        ExpectedSeconds = $durationSeconds
    }
}

function New-SegmentJobs {
    # The FFmpeg command for every segment of the video not already finished
    # in SegmentDirectory, on one filter backend. Reads the job settings the
    # main block works out before calling it.
    param(
        [ValidateSet('opencl', 'vulkan', 'cpu')][string]$Backend,
        [string]$Device = '',
        [string]$SegmentDirectory,
        [int]$ThreadsPerLane
    )
    New-Item -ItemType Directory -Path $SegmentDirectory -Force | Out-Null
    $completed = 0
    $jobs = [Collections.Generic.List[object]]::new()
    for ($segmentIndex = 0; $segmentIndex -lt $segmentCount; $segmentIndex++) {
        $startFrame = $segmentIndex * $segmentFrames
        $frameCount = [Math]::Min($segmentFrames, $totalFrames - $startFrame)
        $durationSeconds = $frameCount / [double]$fps
        $segmentPath = Join-Path $SegmentDirectory ('segment-{0:D4}.mp4' -f $segmentIndex)
        if (Test-Segment -Path $segmentPath -ExpectedSeconds $durationSeconds) {
            $completed += $frameCount
            Write-WorkerProgress (($completed / [double]$totalFrames) * 94.0) "Reused completed segment $($segmentIndex + 1) of $segmentCount."
            continue
        }

        # The preview can only be dropped in whole. Cutting it to a shorter
        # segment would need a keyframe at the cut, and a stream copy that
        # silently starts at the previous keyframe would pass the duration
        # check while holding the wrong frames, so only reuse an exact match.
        if ($segmentIndex -eq 0 -and [bool]$script:Job.ReusePreview -and $previewSeconds -gt 0 -and
            [Math]::Abs($previewSeconds - $durationSeconds) -lt 0.35 -and
            (Test-Path -LiteralPath ([string]$script:Job.PreviewPath) -PathType Leaf)) {
            $copyError = Join-Path $SegmentDirectory 'preview-reuse-error.log'
            $copyArgs = @('-y','-hide_banner','-loglevel','error','-i',[string]$script:Job.PreviewPath,'-map','0:v:0','-an','-c:v','copy',$segmentPath)
            & ([string]$script:Job.FfmpegPath) @copyArgs 2> $copyError
            if ($LASTEXITCODE -eq 0 -and (Test-Segment -Path $segmentPath -ExpectedSeconds $durationSeconds)) {
                $completed += $frameCount
                Write-WorkerProgress (($completed / [double]$totalFrames) * 94.0) 'Reused the approved preview.'
                continue
            }
            if (Test-Path -LiteralPath $segmentPath -PathType Leaf) { Remove-Item -LiteralPath $segmentPath -Force }
        }

        $jobs.Add((New-SegmentCommand -Backend $Backend -Device $Device -SegmentDirectory $SegmentDirectory -SegmentPath $segmentPath -Prefix ('{0:D4}' -f $segmentIndex) -SegmentIndex $segmentIndex -StartFrame $startFrame -FrameCount $frameCount -ThreadsPerLane $ThreadsPerLane))
    }
    return [pscustomobject]@{ Jobs = $jobs.ToArray(); CompletedFrames = $completed }
}

function Measure-RenderConfiguration {
    # Renders the calibration slice Lanes times at once on one backend and
    # reports the throughput: seconds of video per second of wall time across
    # all lanes, which is what a whole video's segments achieve.
    param(
        [string]$Backend,
        [string]$Device = '',
        [int]$Lanes,
        [int]$FrameCount,
        [string]$Directory,
        [int]$LogicalCores,
        # Sample the NVIDIA card's memory while the lanes run and report the
        # peak, so a lane count is judged on what it really uses.
        [switch]$WatchNvidiaMemory
    )
    $threads = [Math]::Max(1, [int][Math]::Floor($LogicalCores / [double]$Lanes))
    $tag = "$Backend-$($Device -replace '\W', '')-$Lanes"
    $commands = for ($lane = 0; $lane -lt $Lanes; $lane++) {
        New-SegmentCommand -Backend $Backend -Device $Device -SegmentDirectory $Directory -SegmentPath (Join-Path $Directory "$tag-$lane.mp4") -Prefix "$tag-$lane" -SegmentIndex 0 -StartFrame 0 -FrameCount $FrameCount -ThreadsPerLane $threads
    }
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    $startedAt = [DateTime]::Now
    $processes = foreach ($command in $commands) {
        $process = Start-Process -FilePath ([string]$script:Job.FfmpegPath) -ArgumentList (Join-Arguments ([string[]]$command.Arguments)) -PassThru -WindowStyle Hidden -RedirectStandardError ([string]$command.ErrorFile)
        $null = $process.Handle
        $process
    }
    [IO.File]::WriteAllLines([string]$script:Job.ChildPidPath, @($processes | ForEach-Object { [string]$_.Id }), [Text.Encoding]::ASCII)
    # A broken driver can hang instead of failing. Ten seconds of video that
    # takes three minutes is slower than any processor anyway.
    $deadline = [DateTime]::UtcNow.AddMinutes(3)
    $timedOut = $false
    $peakMemoryMb = 0
    if ($WatchNvidiaMemory) {
        while (@($processes | Where-Object { -not $_.HasExited }).Count -gt 0) {
            if ([DateTime]::UtcNow -gt $deadline) { $timedOut = $true; break }
            try {
                $usedText = & nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits 2>$null | Select-Object -First 1
                $usedMb = 0
                if ([int]::TryParse(([string]$usedText).Trim(), [ref]$usedMb) -and $usedMb -gt $peakMemoryMb) { $peakMemoryMb = $usedMb }
            }
            catch {}
            Start-Sleep -Milliseconds 300
        }
    }
    else {
        foreach ($process in $processes) {
            $remaining = [int][Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
            if (-not $process.WaitForExit($remaining)) { $timedOut = $true }
        }
    }
    $stopwatch.Stop()
    $failure = ''
    if ($timedOut) {
        foreach ($process in $processes) { try { if (-not $process.HasExited) { $process.Kill() } } catch {} }
        foreach ($process in $processes) { $process.Dispose() }
        return [pscustomobject]@{ Ok = $false; Failure = 'timed out after three minutes.'; Speed = 0.0; Output = ''; PeakMemoryMb = $peakMemoryMb }
    }
    foreach ($process in $processes) { $process.WaitForExit() }
    # Timed to the last lane's exit, not to when the polling loop noticed it.
    $elapsedSeconds = $stopwatch.Elapsed.TotalSeconds
    try {
        $lastExit = ($processes | ForEach-Object { $_.ExitTime } | Measure-Object -Maximum).Maximum
        if ($null -ne $lastExit) { $elapsedSeconds = [Math]::Min($elapsedSeconds, ($lastExit - $startedAt).TotalSeconds) }
    }
    catch {}
    for ($lane = 0; $lane -lt $Lanes; $lane++) {
        $processes[$lane].Refresh()
        if ($processes[$lane].ExitCode -ne 0) {
            $details = Get-Content -LiteralPath ([string]$commands[$lane].ErrorFile) -Raw -ErrorAction SilentlyContinue
            $failure = "FFmpeg code $($processes[$lane].ExitCode). $(([string]$details).Trim())"
            break
        }
        $frames = Get-VideoPacketCount ([string]$commands[$lane].SegmentPath)
        if ($frames -ne $FrameCount) { $failure = "lane $lane wrote $frames frames instead of $FrameCount."; break }
    }
    foreach ($process in $processes) { $process.Dispose() }
    return [pscustomobject]@{
        Ok = [string]::IsNullOrEmpty($failure)
        Failure = $failure
        Speed = ($Lanes * $FrameCount / [double]$fps) / [Math]::Max(0.001, $elapsedSeconds)
        Output = [string]$commands[0].SegmentPath
        PeakMemoryMb = $peakMemoryMb
    }
}

function Get-VideoSimilarity {
    # Average and worst-frame luma PSNR of one render against another.
    param([string]$Path, [string]$ReferencePath)
    $result = Invoke-QuietFfmpeg -FfmpegPath ([string]$script:Job.FfmpegPath) -TimeoutSeconds 120 -Arguments @('-hide_banner', '-i', $Path, '-i', $ReferencePath, '-lavfi', 'psnr', '-f', 'null', '-')
    $match = [regex]::Match($result.Error, 'PSNR y:(?<y>[\d.]+|inf).*?min:(?<min>[\d.]+|inf)')
    if (-not $match.Success) { return $null }
    $toNumber = { param($text) if ($text -eq 'inf') { 99.0 } else { [double]::Parse($text, [Globalization.CultureInfo]::InvariantCulture) } }
    return [pscustomobject]@{ Average = (& $toNumber $match.Groups['y'].Value); Minimum = (& $toNumber $match.Groups['min'].Value) }
}

function Invoke-RenderCalibration {
    # Measures this machine once and picks the fastest way to render on it.
    # Every computer the tool runs on differs - NVIDIA, AMD or Intel graphics,
    # integrated or not, four cores or sixteen - and the best setup cannot be
    # read off a spec sheet: on the RTX A4000 laptop the GPU path gains
    # nothing past four lanes, while its Intel iGPU stops gaining at two and
    # still beats the i7's processor graph by a third. So each candidate
    # renders the first ten seconds of the real video - its photographs, its
    # watermark, its encoder - and the fastest is kept.
    #
    # A GPU must first pass the two-second motion test (every frame present,
    # none repeated) and then match the processor's render of the same
    # seconds: under 32 dB on average, or 25 dB on any frame, means its
    # driver drew something else, and it is not used. The processor graph is
    # the reference and the fallback; a GPU has to beat it by 5 percent to be
    # chosen.
    param([string]$Signature, [int]$ProcessorLanes, [int]$LogicalCores)

    $directory = Join-Path $resumeDirectory 'calibration'
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
    New-Item -ItemType Directory -Path $directory -Force | Out-Null
    $frames = [Math]::Min(10 * $fps, $totalFrames)
    $notes = [System.Collections.Generic.List[string]]::new()
    $title = 'Optimizing for this PC (one time)'

    Write-WorkerProgress 0 "$title - measuring the processor..."
    $cpu = Measure-RenderConfiguration -Backend 'cpu' -Lanes $ProcessorLanes -FrameCount $frames -Directory $directory -LogicalCores $LogicalCores
    $choice = [pscustomobject]@{ Backend = 'cpu'; Device = ''; DeviceName = 'Processor'; Lanes = $ProcessorLanes; Speed = $cpu.Speed }
    if (-not $cpu.Ok) {
        # Without a reference nothing can be judged; the render itself will
        # report whatever is wrong.
        $notes.Add("Processor reference failed: $($cpu.Failure)")
    }
    else {
        $notes.Add(('Processor, {0} lanes: {1:0.00}x' -f $ProcessorLanes, $cpu.Speed))
        $devices = @()
        try { $devices = @(Get-OpenClDevices -FfmpegPath ([string]$script:Job.FfmpegPath)) } catch { $notes.Add("OpenCL devices could not be listed: $($_.Exception.Message)") }
        foreach ($device in $devices) {
            Write-WorkerProgress 0 "$title - testing $($device.Name)..."
            $problem = Test-OpenClMotionDevice -FfmpegPath ([string]$script:Job.FfmpegPath) -Device $device.Device -WorkDirectory (Join-Path $directory "test-$($device.Device)")
            if ($problem) { $notes.Add("$($device.Name): failed the motion test. $problem"); continue }
            # Each lane holds its photographs, a watermark cycle and the
            # crossfade buffers in video memory. Overflowing it is what to
            # avoid: 8 lanes on an 8 GB card did, and ran at a quarter of the
            # speed. On NVIDIA the card's memory is watched during each lane
            # count and one that peaks above 80 percent is not used - the
            # margin covers a channel whose watermark is bigger than the one
            # measured (each lane took about 780 MB on the A4000). That
            # replaced a fixed one lane per 2 GB, which held a
            # 4 GB Quadro P1000 at 2 lanes while 1 -> 2 had nearly doubled its
            # speed. Other makers report no memory figure; 3 is skipped for
            # them so the test stays short.
            $memoryTotalMb = 0
            if ($device.Vendor -eq 'nvidia') {
                try {
                    $memoryText = & nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits 2>$null | Select-Object -First 1
                    [void][int]::TryParse(([string]$memoryText).Trim(), [ref]$memoryTotalMb)
                }
                catch {}
            }
            $laneSteps = if ($memoryTotalMb -gt 0) { @(1, 2, 3, 4) } else { @(1, 2, 4) }
            $previous = 0.0
            foreach ($lanes in $laneSteps) {
                Write-WorkerProgress 0 "$title - $($device.Name), $lanes at once..."
                $measured = Measure-RenderConfiguration -Backend 'opencl' -Device $device.Device -Lanes $lanes -FrameCount $frames -Directory $directory -LogicalCores $LogicalCores -WatchNvidiaMemory:($memoryTotalMb -gt 0)
                if (-not $measured.Ok) { $notes.Add("$($device.Name), $lanes lanes: failed. $($measured.Failure)"); break }
                if ($memoryTotalMb -gt 0 -and $measured.PeakMemoryMb -gt 0.80 * $memoryTotalMb) {
                    $notes.Add(('{0}, {1} lanes: {2:0.00}x but used {3} of {4} MB of video memory; not used.' -f $device.Name, $lanes, $measured.Speed, $measured.PeakMemoryMb, $memoryTotalMb))
                    break
                }
                if ($lanes -eq 1) {
                    $similarity = Get-VideoSimilarity -Path $measured.Output -ReferencePath $cpu.Output
                    if ($null -eq $similarity -or $similarity.Average -lt 32 -or $similarity.Minimum -lt 25) {
                        $shown = if ($null -eq $similarity) { 'could not be compared' } else { '{0:0.0} dB average, {1:0.0} dB worst' -f $similarity.Average, $similarity.Minimum }
                        $notes.Add("$($device.Name): rejected, its render differs from the processor's ($shown).")
                        break
                    }
                    $notes.Add(('{0}: matches the processor ({1:0.0} dB)' -f $device.Name, $similarity.Average))
                }
                $memoryNote = if ($measured.PeakMemoryMb -gt 0) { " ($($measured.PeakMemoryMb) of $memoryTotalMb MB)" } else { '' }
                $notes.Add(('{0}, {1} lanes: {2:0.00}x{3}' -f $device.Name, $lanes, $measured.Speed, $memoryNote))
                if ($measured.Speed -gt $choice.Speed * $(if ($choice.Backend -eq 'cpu') { 1.05 } else { 1.0 })) {
                    $choice = [pscustomobject]@{ Backend = 'opencl'; Device = $device.Device; DeviceName = $device.Name; Lanes = $lanes; Speed = $measured.Speed }
                }
                # Another lane that adds under 8 percent is not worth its
                # video memory and processor time.
                if ($lanes -gt 1 -and $measured.Speed -lt $previous * 1.08) { break }
                $previous = $measured.Speed
            }
        }
    }

    $profileData = [ordered]@{
        Signature = $Signature
        CreatedUtc = [DateTime]::UtcNow.ToString('o')
        Encoder = [string]$script:Job.Encoder
        Backend = $choice.Backend
        Device = $choice.Device
        DeviceName = $choice.DeviceName
        Lanes = $choice.Lanes
        Speed = [Math]::Round($choice.Speed, 2)
        Measurements = $notes.ToArray()
    }
    Write-WorkerDiagnostic ("Render calibration chose {0} ({1}, {2} lanes, {3:0.00}x). {4}" -f $choice.Backend, $choice.DeviceName, $choice.Lanes, $choice.Speed, ($notes -join ' | '))
    try { Remove-Item -LiteralPath $directory -Recurse -Force -ErrorAction SilentlyContinue } catch {}
    return [pscustomobject]$profileData
}

function Save-RenderProfile {
    param([psobject]$ProfileData)
    $path = [string]$script:RenderProfilePath
    if ([string]::IsNullOrWhiteSpace($path)) { return }
    try {
        New-Item -ItemType Directory -Path (Split-Path -Parent $path) -Force | Out-Null
        [IO.File]::WriteAllText($path, ($ProfileData | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
    }
    catch { Write-WorkerDiagnostic "Could not save the render profile: $($_.Exception.Message)" }
}

function Write-WorkerDiagnostic {
    # Into the app's own diagnostic log, when the job names it.
    param([string]$Message)
    try {
        if (-not $script:Job.PSObject.Properties['DiagnosticLogPath']) { return }
        $path = [string]$script:Job.DiagnosticLogPath
        if ([string]::IsNullOrWhiteSpace($path)) { return }
        [IO.File]::AppendAllText($path, "[$([DateTime]::Now.ToString('yyyy-MM-dd HH:mm:ss'))] Render worker: $Message`r`n", [Text.UTF8Encoding]::new($false))
    }
    catch {}
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
    $filterVulkanDeviceIndex = if ($script:Job.PSObject.Properties['FilterVulkanDeviceIndex']) { [int]$script:Job.FilterVulkanDeviceIndex } else { [int]$script:Job.VulkanDeviceIndex }
    $ffmpegLogLevel = if ($script:Job.PSObject.Properties['LogLevel']) { [string]$script:Job.LogLevel } else { 'error' }
    $captionPreset = if ($script:Job.Settings.PSObject.Properties['CaptionPreset']) { [string]$script:Job.Settings.CaptionPreset } else { '1. Clean YouTube' }
    $captionWordsPerLine = if ($script:Job.Settings.PSObject.Properties['CaptionWordsPerLine']) { [int]$script:Job.Settings.CaptionWordsPerLine } else { 8 }
    $filterBackend = if ($script:Job.PSObject.Properties['FilterBackend']) { [string]$script:Job.FilterBackend } else { 'cpu' }
    $processorLanes = if ($script:Job.PSObject.Properties['ParallelSegments']) { [int]$script:Job.ParallelSegments } else { 2 }
    if ($processorLanes -lt 1) { $processorLanes = 1 }
    # Divide the machine between the lanes explicitly. Left to itself every
    # FFmpeg process starts as many filter threads as there are cores, so four
    # lanes on an eight-core laptop ask for thirty-two threads and spend a
    # noticeable share of the render context-switching between them.
    $logicalCores = [Environment]::ProcessorCount
    if ($logicalCores -lt 1) { $logicalCores = 1 }
    $script:RenderProfilePath = if ($script:Job.PSObject.Properties['RenderProfilePath']) { [string]$script:Job.RenderProfilePath } else { '' }
    # 'auto' (and the older 'opencl') means: render on whatever this machine
    # was measured to do fastest. The Vulkan encoder takes only GPU frames of
    # its own, so it stays on the processor graph.
    $wantsGpu = $filterBackend -in @('auto', 'opencl') -and [string]$script:Job.Encoder -ne 'h264_vulkan' -and -not [string]::IsNullOrWhiteSpace($script:RenderProfilePath)

    # Measured once per video: the part of the frame the watermark touches and
    # the length of one cycle, so the GPU graph uploads only that rectangle,
    # once per segment. If the measurement fails the graph streams the whole
    # watermark, which is slower and identical.
    $watermarkRect = @()
    $watermarkLoopFrames = 0
    if ($wantsGpu) {
        try {
            $footprint = Get-WatermarkFootprint -FfmpegPath ([string]$script:Job.FfmpegPath) -WatermarkPath ([string]$script:Job.WatermarkPath) -Fps $fps
            $watermarkRect = [int[]]$footprint.Rect
            $watermarkLoopFrames = [int]$footprint.LoopFrames
        }
        catch {
            Write-WorkerDiagnostic "Could not measure the watermark; streaming it whole. $($_.Exception.Message)"
        }
    }

    # Which renderer this video uses is decided once and written into its
    # resume folder, so a resumed video carries on exactly as it started even
    # if the machine has been measured again since.
    $configPath = Join-Path $resumeDirectory 'render-config.json'
    $config = $null
    if (Test-Path -LiteralPath $configPath -PathType Leaf) {
        try { $config = [IO.File]::ReadAllText($configPath, [Text.Encoding]::UTF8) | ConvertFrom-Json } catch { $config = $null }
    }
    if ($null -eq $config) {
        $config = [pscustomobject]@{ Backend = 'cpu'; Device = ''; DeviceName = 'Processor'; Lanes = $processorLanes }
        if ($filterBackend -eq 'vulkan') {
            $config.Backend = 'vulkan'
        }
        elseif ($wantsGpu) {
            try {
                $signature = Get-RenderMachineSignature -Encoder ([string]$script:Job.Encoder) -FfmpegPath ([string]$script:Job.FfmpegPath) -PipelineVersion ([string]$script:Job.PipelineVersion)
                $profileData = Read-RenderProfile -Path $script:RenderProfilePath -Signature $signature
                if ($null -eq $profileData) {
                    $profileData = Invoke-RenderCalibration -Signature $signature -ProcessorLanes $processorLanes -LogicalCores $logicalCores
                    Save-RenderProfile -ProfileData $profileData
                }
                if ([string]$profileData.Backend -eq 'opencl' -and -not [string]::IsNullOrWhiteSpace([string]$profileData.Device)) {
                    $config = [pscustomobject]@{ Backend = 'opencl'; Device = [string]$profileData.Device; DeviceName = [string]$profileData.DeviceName; Lanes = [Math]::Max(1, [int]$profileData.Lanes) }
                }
            }
            catch {
                Write-WorkerDiagnostic "Could not measure this machine; rendering on the processor. $($_.Exception.Message)"
            }
        }
        [IO.File]::WriteAllText($configPath, ($config | ConvertTo-Json), [Text.UTF8Encoding]::new($false))
    }
    $backend = [string]$config.Backend
    $openClDevice = [string]$config.Device
    $maximumParallel = if ($backend -eq 'opencl') { [Math]::Max(1, [int]$config.Lanes) } else { $processorLanes }
    # A video whose GPU render failed is finished on the processor, in a folder
    # of its own. Mixing the two renderers' segments in one video is never
    # wanted, and the marker keeps Resume on the processor for this video.
    $segmentDirectory = $resumeDirectory
    $processorDirectory = Join-Path $resumeDirectory 'processor'
    $gpuFailureMarker = Join-Path $resumeDirectory 'gpu-failed.txt'
    if ($backend -eq 'opencl' -and (Test-Path -LiteralPath $gpuFailureMarker -PathType Leaf)) {
        $backend = 'cpu'
        $segmentDirectory = $processorDirectory
        $maximumParallel = $processorLanes
    }
    $threadsPerLane = [Math]::Max(1, [int][Math]::Floor($logicalCores / [double]$maximumParallel))
    Write-WorkerProgress 0 "Rendering with $(if ($backend -eq 'opencl') { [string]$config.DeviceName } else { 'the processor' }), $maximumParallel at a time..."
    $loudnessTarget = if ($script:Job.PSObject.Properties['LoudnessTargetLufs']) { [double]$script:Job.LoudnessTargetLufs } else { -14.0 }
    $audioBitrate = if ([string]$script:Job.Settings.Quality -eq 'YouTube') { '384k' } else { '160k' }
    # The voiceover is encoded once, alongside the segments, and kept for
    # Resume like a finished segment. Its file name carries the bitrate and
    # loudness target, so a resume under different settings encodes afresh.
    $voiceoverPath = Join-Path $resumeDirectory ("voiceover-$audioBitrate-$([int][Math]::Round(-$loudnessTarget)).m4a")
    $script:Voiceover = [pscustomobject]@{
        Analysis = $null
        Process = $null
        Filter = ''
        Bitrate = $audioBitrate
        Path = $voiceoverPath
        PartialPath = Join-Path $resumeDirectory 'voiceover.partial.m4a'
        ErrorPath = Join-Path $resumeDirectory 'voiceover-error.log'
        Done = (Test-Path -LiteralPath $voiceoverPath -PathType Leaf)
    }
    if (-not $script:Voiceover.Done) {
        $script:Voiceover.Analysis = Start-LoudnessAnalysis -AudioPath ([string]$script:Job.AudioPath) -ReportPath (Join-Path $resumeDirectory 'loudness.json') -TargetLufs $loudnessTarget
    }
    $voiceoverTick = { Step-VoiceoverEncode -State $script:Voiceover }

    $plan = New-SegmentJobs -Backend $backend -Device $openClDevice -SegmentDirectory $segmentDirectory -ThreadsPerLane $threadsPerLane
    try {
        $completedFrames = Invoke-ParallelSegmentJobs -Jobs $plan.Jobs -CompletedFrames $plan.CompletedFrames -TotalFrames $totalFrames -Fps $fps -MaximumParallel $maximumParallel -OnTick $voiceoverTick
    }
    catch {
        if ($backend -ne 'opencl') { throw }
        $reason = $_.Exception.Message
        # Pause and Cancel end this worker with taskkill /T, which can reach the
        # FFmpeg lanes a moment before it reaches this process. Wait out that
        # moment so a render being stopped is not mistaken for a GPU fault.
        Start-Sleep -Seconds 2
        [IO.File]::WriteAllText($gpuFailureMarker, "[$([DateTime]::Now.ToString('s'))] $reason", [Text.UTF8Encoding]::new($false))
        Write-WorkerDiagnostic "GPU motion effects failed; rendering this video on the processor instead. $reason"
        # Later videos on this machine go straight to the processor until it is
        # measured again (a driver or hardware change, or Optimize for this PC).
        try {
            $signature = Get-RenderMachineSignature -Encoder ([string]$script:Job.Encoder) -FfmpegPath ([string]$script:Job.FfmpegPath) -PipelineVersion ([string]$script:Job.PipelineVersion)
            Save-RenderProfile -ProfileData ([ordered]@{ Signature = $signature; CreatedUtc = [DateTime]::UtcNow.ToString('o'); Encoder = [string]$script:Job.Encoder; Backend = 'cpu'; Device = ''; DeviceName = 'Processor'; Lanes = $processorLanes; Speed = 0; Measurements = @("$([string]$config.DeviceName) failed during a render: $reason") })
        }
        catch {}
        Write-WorkerProgress 0 'GPU effects failed; rendering this video on the processor instead...'
        $backend = 'cpu'
        $segmentDirectory = $processorDirectory
        $maximumParallel = $processorLanes
        $threadsPerLane = [Math]::Max(1, [int][Math]::Floor($logicalCores / [double]$maximumParallel))
        $plan = New-SegmentJobs -Backend 'cpu' -SegmentDirectory $segmentDirectory -ThreadsPerLane $threadsPerLane
        $completedFrames = Invoke-ParallelSegmentJobs -Jobs $plan.Jobs -CompletedFrames $plan.CompletedFrames -TotalFrames $totalFrames -Fps $fps -MaximumParallel $maximumParallel -OnTick $voiceoverTick
    }

    Write-WorkerProgress 95 'Finishing the voiceover...'
    $voiceoverReady = Complete-VoiceoverEncode -State $script:Voiceover

    Write-WorkerProgress 95 'Joining segments and adding the voiceover...'
    $concatPath = Join-Path $resumeDirectory 'segments.txt'
    $concatLines = for ($index = 0; $index -lt $segmentCount; $index++) {
        $path = (Join-Path $segmentDirectory ('segment-{0:D4}.mp4' -f $index)).Replace("'", "'\''")
        "file '$($path.Replace('\','/'))'"
    }
    [IO.File]::WriteAllLines($concatPath, $concatLines, [Text.UTF8Encoding]::new($false))
    $stagingPath = [string]$script:Job.StagingPath
    $muxProgress = Join-Path $resumeDirectory 'mux-progress.txt'
    $muxError = Join-Path $resumeDirectory 'mux-error.log'
    if ($voiceoverReady) {
        $muxArguments = @('-y','-hide_banner','-loglevel','error','-nostats','-progress',$muxProgress,'-f','concat','-safe','0','-i',$concatPath,'-i',$script:Voiceover.Path,'-map','0:v:0','-map','1:a:0','-c','copy','-shortest','-movflags','+faststart',$stagingPath)
    }
    else {
        # -ar 48000 after the filter matters: loudnorm resamples internally, and
        # without it the muxed track can leave at loudnorm's own rate.
        $loudnessFilter = if ([string]::IsNullOrWhiteSpace($script:Voiceover.Filter)) { "loudnorm=I=$($loudnessTarget.ToString('0.##', [Globalization.CultureInfo]::InvariantCulture)):TP=-1.5:LRA=11" } else { $script:Voiceover.Filter }
        $muxArguments = @('-y','-hide_banner','-loglevel','error','-nostats','-progress',$muxProgress,'-f','concat','-safe','0','-i',$concatPath,'-i',[string]$script:Job.AudioPath,'-map','0:v:0','-map','1:a:0','-c:v','copy','-af',$loudnessFilter,'-c:a','aac','-b:a',$audioBitrate,'-ar','48000','-ac','2','-shortest','-movflags','+faststart',$stagingPath)
    }
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
    # The voiceover's helpers outlive this process unless stopped here.
    try {
        $voiceoverState = Get-Variable -Name Voiceover -Scope Script -ValueOnly -ErrorAction SilentlyContinue
        if ($null -ne $voiceoverState) {
            foreach ($helper in @($voiceoverState.Process, $(if ($null -ne $voiceoverState.Analysis) { $voiceoverState.Analysis.Process }))) {
                if ($null -ne $helper -and -not $helper.HasExited) { $helper.Kill() }
            }
        }
    }
    catch {}
    exit 1
}
