<#
.SYNOPSIS
    Times each stage of the render pipeline on this machine.

.DESCRIPTION
    The renderer is portable, so the slow stage is not the same everywhere. A
    laptop with integrated graphics, a workstation with a discrete card, and a
    four-core office PC each spend their time somewhere different, and there is
    no way to tell which by reading the filter graph.

    This renders one short segment repeatedly, each time with a single stage
    switched off, and reports what that stage cost. It then renders the same
    segment at a range of lane counts to find the concurrency this machine
    actually likes, which is frequently not the one the formula predicts.

    Nothing here changes the renderer. It writes only into its own output
    folder and can be run on any machine the tool is installed on.

.PARAMETER ImageFolder
    Photographs to render. Real photographs matter: decode and scaling cost
    depend on their pixel dimensions. When omitted, synthetic 4000x3000 images
    are generated so the script still runs on a machine with none to hand.

.PARAMETER Seconds
    Length of the timed segment. The default matches the length the renderer
    actually cuts segments to, so the measurements carry over directly. Shorten
    it for a quicker but less representative answer.

.PARAMETER SkipLaneScaling
    Skip the concurrency sweep and report only the per-stage costs.

.EXAMPLE
    .\Measure-RenderPerformance.ps1 -ImageFolder 'D:\Photos\Set A'
#>
[CmdletBinding()]
param(
    [string]$ImageFolder = '',
    [int]$Seconds = 30,
    [ValidateSet('', 'h264_nvenc', 'h264_amf', 'h264_qsv', 'h264_vulkan', 'libx264')]
    [string]$Encoder = '',
    [ValidateRange(1, 10)]
    [int]$Repeat = 2,
    [switch]$SkipLaneScaling,
    [switch]$SkipGpuComparison
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'SlideshowEngine.psm1') -Force

$script:Fps = 24
$script:Width = 1920
$script:Height = 1080

function Find-Ffmpeg {
    $bundled = Join-Path $root 'Tools\FFmpeg-7.1.1\ffmpeg-7.1.1-full_build\bin\ffmpeg.exe'
    if (Test-Path -LiteralPath $bundled -PathType Leaf) { return $bundled }
    $command = Get-Command ffmpeg.exe -ErrorAction SilentlyContinue
    if ($null -ne $command) { return $command.Source }
    throw 'FFmpeg was not found. Run this from the installed tool folder, or put ffmpeg.exe on PATH.'
}

function Join-Arguments {
    param([string[]]$Arguments)
    return (($Arguments | ForEach-Object {
        if ($_ -notmatch '[\s"]') { $_ } else { '"' + $_.Replace('"', '\"') + '"' }
    }) -join ' ')
}

function Invoke-Ffmpeg {
    # Returns the wall time in seconds, or $null when FFmpeg refused the graph.
    # A variant that fails is reported rather than silently scoring zero.
    param([string[]]$Arguments, [string]$ErrorFile)
    $process = $null
    try {
        $startInfo = [Diagnostics.ProcessStartInfo]::new()
        $startInfo.FileName = $script:FfmpegPath
        $startInfo.Arguments = Join-Arguments $Arguments
        $startInfo.UseShellExecute = $false
        $startInfo.CreateNoWindow = $true
        $startInfo.RedirectStandardOutput = $true
        $startInfo.RedirectStandardError = $true
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $startInfo
        $clock = [Diagnostics.Stopwatch]::StartNew()
        if (-not $process.Start()) { return $null }
        [void]$process.StandardOutput.ReadToEnd()
        $errorText = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        $clock.Stop()
        if ($process.ExitCode -ne 0) {
            if ($ErrorFile) { [IO.File]::WriteAllText($ErrorFile, $errorText, [Text.UTF8Encoding]::new($false)) }
            return $null
        }
        return $clock.Elapsed.TotalSeconds
    }
    finally {
        if ($null -ne $process) { $process.Dispose() }
    }
}

function Select-Encoder {
    if (-not [string]::IsNullOrWhiteSpace($Encoder)) { return $Encoder }
    foreach ($candidate in @('h264_nvenc', 'h264_amf', 'h264_qsv')) {
        # Probe at delivery resolution, matching Test-VideoEncoder in the tool.
        # A thumbnail-sized probe sits below NVENC's minimum frame width on
        # Turing and later, so it would report the wrong encoder here and
        # measure a pipeline the renderer would never actually use.
        $arguments = @(
            '-hide_banner', '-loglevel', 'error',
            '-f', 'lavfi', '-i', "color=c=black:s=$($script:Width)x$($script:Height):r=$($script:Fps)",
            '-frames:v', '1', '-c:v', $candidate, '-f', 'null', 'NUL'
        )
        if ($null -ne (Invoke-Ffmpeg -Arguments $arguments -ErrorFile '')) { return $candidate }
    }
    return 'libx264'
}

function New-SyntheticImages {
    # Detailed noise rather than a flat colour: a flat image compresses and
    # scales unrealistically fast and would understate every stage.
    param([string]$Destination, [int]$Count)
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $created = [Collections.Generic.List[string]]::new()
    for ($index = 0; $index -lt $Count; $index++) {
        $path = Join-Path $Destination ("sample-{0:D2}.jpg" -f $index)
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
            # A different noise seed per image keeps them genuinely distinct, so
            # the decode and scale costs are not flattered by caching.
            $errorPath = [IO.Path]::ChangeExtension($path, '.log')
            $arguments = @(
                '-y', '-hide_banner', '-loglevel', 'error',
                '-f', 'lavfi', '-i', 'testsrc2=s=4000x3000:r=1',
                '-vf', "noise=alls=48:allf=t+u:all_seed=$(1000 + $index),format=yuv420p",
                '-frames:v', '1', '-q:v', '3', $path
            )
            if ($null -eq (Invoke-Ffmpeg -Arguments $arguments -ErrorFile $errorPath)) {
                throw "Could not generate the synthetic photograph $path. See $errorPath."
            }
        }
        $created.Add($path)
    }
    return $created.ToArray()
}

# --- Filter graph variants -------------------------------------------------
#
# Each variant removes exactly one stage from the graph the renderer would
# normally emit. The substitutions below match text that New-FilterGraph
# produces verbatim; if a variant stops matching after an engine change it
# reports "graph unchanged" rather than quietly timing the full graph again.

function Remove-MotionBlur {
    # Undo the doubled frame rate and the temporal blend that consumes it, so
    # the difference is the true cost of generating motion at 48 FPS.
    param([string]$Text)
    $result = [regex]::Replace($Text, "d=(\d+):s=$($script:Width)x$($script:Height):fps=$($script:Fps * 2)", {
        param($match)
        $halved = [int]([int]$match.Groups[1].Value / 2)
        "d=$halved`:s=$($script:Width)x$($script:Height):fps=$($script:Fps)"
    })
    return $result.Replace("tmix=frames=3:weights='1 2 1',", '')
}

function Remove-BackgroundBlur {
    param([string]$Text)
    return [regex]::Replace($Text, 'gblur=sigma=[0-9.]+,', '')
}

function Remove-OverscanCanvas {
    # Drop the 2x working canvas to 1.25x. This is the measurement that says
    # whether the steady-pan canvas is affordable, not a suggestion to ship it.
    param([string]$Text)
    $narrow = [int]([Math]::Ceiling(($script:Width * 1.25) / 2.0) * 2)
    $short = [int]([Math]::Ceiling(($script:Height * 1.25) / 2.0) * 2)
    $wide = [int]($script:Width * 2)
    $tall = [int]($script:Height * 2)
    return $Text.Replace("$wide`:$tall", "$narrow`:$short")
}

function Remove-WatermarkBlend {
    # Strip the watermark decode, the two RGB conversions and the screen blend.
    # The [1:v] input simply stops being referenced, which FFmpeg accepts.
    param([string]$Text)
    $lines = $Text -split ";`r`n|;`n" | Where-Object {
        $_ -notmatch '^\[1:v\]' -and $_ -notmatch '^\[vseq\]format=gbrp' -and $_ -notmatch '^\[watermark\]format=gbrp'
    }
    $rebuilt = [Collections.Generic.List[string]]::new()
    foreach ($line in $lines) {
        if ($line -match 'blend=all_mode=screen') {
            $rebuilt.Add('[vseq]format=yuv420p[composited]')
        }
        else { $rebuilt.Add($line) }
    }
    return (($rebuilt | Where-Object { $_.Trim() }) -join ";`r`n") + "`r`n"
}

function Measure-Variant {
    param(
        [string]$Name,
        [string]$FilterText,
        [string]$BaselineFilterText,
        [string]$WorkingDirectory,
        [string]$WatermarkPath,
        [string[]]$ImageInputs,
        [int]$FrameCount,
        [switch]$NullEncode,
        [string]$VulkanDevice = ''
    )

    if ($Name -ne 'Everything on' -and $FilterText -eq $BaselineFilterText -and -not $NullEncode) {
        return [pscustomobject]@{ Name = $Name; Seconds = $null; Note = 'graph unchanged - engine text moved' }
    }

    $filterPath = Join-Path $WorkingDirectory ('filter-' + ($Name -replace '[^A-Za-z0-9]', '-') + '.txt')
    [IO.File]::WriteAllText($filterPath, $FilterText, [Text.UTF8Encoding]::new($false))
    $errorPath = [IO.Path]::ChangeExtension($filterPath, '.log')
    $outputPath = Join-Path $WorkingDirectory 'measure.mp4'

    $arguments = [Collections.Generic.List[string]]::new()
    foreach ($value in @('-y', '-hide_banner', '-loglevel', 'error', '-nostats')) { $arguments.Add($value) }
    if (-not [string]::IsNullOrWhiteSpace($VulkanDevice)) {
        foreach ($value in @('-init_hw_device', "vulkan=benchgpu:$VulkanDevice", '-filter_hw_device', 'benchgpu')) { $arguments.Add($value) }
    }
    foreach ($value in @('-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-stream_loop', '-1', '-i', $WatermarkPath)) { $arguments.Add($value) }
    foreach ($imagePath in $ImageInputs) { $arguments.Add('-i'); $arguments.Add($imagePath) }
    foreach ($value in @('-filter_complex_script', $filterPath, '-map', '[vout]')) { $arguments.Add($value) }
    if ($NullEncode) {
        foreach ($value in @('-f', 'null', 'NUL')) { $arguments.Add($value) }
    }
    else {
        foreach ($value in (Get-EncodingArguments -Encoder $script:ChosenEncoder -Quality 'YouTube')) { $arguments.Add($value) }
        foreach ($value in @('-r', [string]$script:Fps, '-frames:v', [string]$FrameCount, '-an', $outputPath)) { $arguments.Add($value) }
    }

    # Take the fastest of several runs rather than an average. Anything that
    # slows a run down - a background process, thermal throttling, the disk -
    # only ever adds time, so the minimum is the closest reading to the real
    # cost of the work. Averaging let interference make a strictly cheaper
    # graph score slower than the full one.
    $seconds = $null
    for ($attempt = 0; $attempt -lt $Repeat; $attempt++) {
        $elapsed = Invoke-Ffmpeg -Arguments $arguments.ToArray() -ErrorFile $errorPath
        if ($null -eq $elapsed) { $seconds = $null; break }
        if ($null -eq $seconds -or $elapsed -lt $seconds) { $seconds = $elapsed }
    }
    $note = if ($null -eq $seconds) { "failed - see $(Split-Path -Leaf $errorPath)" } else { '' }
    return [pscustomobject]@{ Name = $Name; Seconds = $seconds; Note = $note }
}

# --- Setup -----------------------------------------------------------------

$script:FfmpegPath = Find-Ffmpeg
$script:ChosenEncoder = Select-Encoder

$outputRoot = Join-Path $root 'benchmark'
New-Item -ItemType Directory -Path $outputRoot -Force | Out-Null

if ([string]::IsNullOrWhiteSpace($ImageFolder)) {
    Write-Host 'No image folder given; generating synthetic 4000x3000 photographs...' -ForegroundColor DarkGray
    $images = New-SyntheticImages -Destination (Join-Path $outputRoot 'images') -Count 8
}
else {
    $images = @(Get-SupportedImageFiles -Folder $ImageFolder)
    if ($images.Count -lt 3) { throw "Found only $($images.Count) usable images in $ImageFolder. At least three are needed." }
    if ($images.Count -gt 12) { $images = $images[0..11] }
}

# A short looping watermark so the screen-blend stage is measured against
# something realistic rather than a still frame.
$watermarkPath = Join-Path $outputRoot 'watermark.mp4'
if (-not (Test-Path -LiteralPath $watermarkPath -PathType Leaf)) {
    $watermarkArguments = @(
        '-y', '-hide_banner', '-loglevel', 'error',
        '-f', 'lavfi', '-i', "life=s=320x180:mold=10:r=$($script:Fps):ratio=0.1:death_color=#101010:life_color=#303030",
        '-t', '4', '-c:v', 'libx264', '-preset', 'veryfast', '-pix_fmt', 'yuv420p', $watermarkPath
    )
    if ($null -eq (Invoke-Ffmpeg -Arguments $watermarkArguments -ErrorFile '')) {
        throw 'Could not generate the benchmark watermark clip.'
    }
}

$frameCount = $Seconds * $script:Fps
$plan = New-TimelinePlan `
    -ImagePaths $images `
    -AudioDurationSeconds ([double]$Seconds) `
    -MinimumDurationSeconds 5.0 `
    -MaximumDurationSeconds 7.0 `
    -Fps $script:Fps `
    -Seed 20260810

$graph = New-FilterGraph `
    -Timeline $plan `
    -RenderFrames ([Math]::Min($frameCount, [int]$plan.TotalFrames)) `
    -ZoomMaximumPercent 110 `
    -BlurAmount 40 `
    -BackgroundBrightnessPercent 65 `
    -Width $script:Width -Height $script:Height

$frameCount = [int]$graph.RenderFrames
$baseline = [string]$graph.FilterText

Write-Host ''
Write-Host "Machine    : $([Environment]::ProcessorCount) logical cores" -ForegroundColor Cyan
Write-Host "Encoder    : $($script:ChosenEncoder)" -ForegroundColor Cyan
Write-Host "Segment    : $frameCount frames ($([Math]::Round($frameCount / $script:Fps, 1))s), $($graph.ImageInputs.Count) unique images" -ForegroundColor Cyan
if ($graph.ImageInputs.Count -lt 3) {
    Write-Host 'Note       : too few images per segment to represent a real render. Raise -Seconds.' -ForegroundColor Yellow
}
Write-Host ''

$variants = @(
    @{ Name = 'Everything on'; Text = $baseline }
    @{ Name = 'No motion blur (24 fps generation)'; Text = (Remove-MotionBlur $baseline) }
    @{ Name = 'No background blur'; Text = (Remove-BackgroundBlur $baseline) }
    @{ Name = 'Overscan canvas 1.25x not 2x'; Text = (Remove-OverscanCanvas $baseline) }
    @{ Name = 'No watermark screen blend'; Text = (Remove-WatermarkBlend $baseline) }
)

$results = [Collections.Generic.List[object]]::new()
foreach ($variant in $variants) {
    Write-Host "  timing: $($variant.Name) ..." -NoNewline
    $measurement = Measure-Variant -Name $variant.Name -FilterText $variant.Text -BaselineFilterText $baseline `
        -WorkingDirectory $outputRoot -WatermarkPath $watermarkPath -ImageInputs $graph.ImageInputs -FrameCount $frameCount
    $results.Add($measurement)
    if ($null -eq $measurement.Seconds) { Write-Host " $($measurement.Note)" -ForegroundColor Yellow }
    else { Write-Host (" {0:0.0}s" -f $measurement.Seconds) -ForegroundColor Gray }
}

Write-Host '  timing: Filters only (no encode) ...' -NoNewline
$nullEncode = Measure-Variant -Name 'Filters only (no encode)' -FilterText $baseline -BaselineFilterText $baseline `
    -WorkingDirectory $outputRoot -WatermarkPath $watermarkPath -ImageInputs $graph.ImageInputs -FrameCount $frameCount -NullEncode
$results.Add($nullEncode)
if ($null -eq $nullEncode.Seconds) { Write-Host " $($nullEncode.Note)" -ForegroundColor Yellow }
else { Write-Host (" {0:0.0}s" -f $nullEncode.Seconds) -ForegroundColor Gray }

$full = ($results | Where-Object { $_.Name -eq 'Everything on' }).Seconds
if ($null -eq $full) { throw 'The full graph did not render, so there is nothing to compare against. Check benchmark\filter-Everything-on.log.' }

Write-Host ''
Write-Host 'Stage costs' -ForegroundColor White
Write-Host '-----------' -ForegroundColor White
$report = foreach ($result in $results) {
    if ($null -eq $result.Seconds) {
        [pscustomobject]@{ Variant = $result.Name; Seconds = 'n/a'; 'Share of render' = $result.Note }
    }
    elseif ($result.Name -eq 'Everything on') {
        [pscustomobject]@{ Variant = $result.Name; Seconds = ('{0:0.0}' -f $result.Seconds); 'Share of render' = ('{0:0.0}x realtime' -f (($frameCount / $script:Fps) / $result.Seconds)) }
    }
    else {
        $saved = (($full - $result.Seconds) / $full) * 100.0
        [pscustomobject]@{ Variant = $result.Name; Seconds = ('{0:0.0}' -f $result.Seconds); 'Share of render' = ('{0:0}%' -f [Math]::Max(0.0, $saved)) }
    }
}
$report | Format-Table -AutoSize | Out-String | Write-Host

# --- CPU against GPU filtering ---------------------------------------------
#
# Whether it is worth moving the animated crop onto the graphics card is not a
# question with one answer. On the machine this was written on the discrete
# card won by about six percent and the integrated one lost by half, so the
# renderer stayed on the CPU. A machine with a weak processor and a strong card
# could easily come out the other way, and this is how to find out.

if (-not $SkipGpuComparison) {
    Write-Host 'CPU against GPU filtering' -ForegroundColor White
    Write-Host '-------------------------' -ForegroundColor White

    $devices = [Collections.Generic.List[object]]::new()
    for ($deviceIndex = 0; $deviceIndex -lt 4; $deviceIndex++) {
        $probe = @(
            '-hide_banner', '-loglevel', 'error',
            '-init_hw_device', "vulkan=probe:$deviceIndex", '-filter_hw_device', 'probe',
            '-f', 'lavfi', '-i', 'color=c=red:s=320x240:r=1',
            '-vf', 'format=nv12,hwupload,libplacebo=w=160:h=120,hwdownload,format=nv12',
            '-frames:v', '1', '-f', 'null', 'NUL'
        )
        if ($null -ne (Invoke-Ffmpeg -Arguments $probe -ErrorFile '')) { $devices.Add($deviceIndex) }
    }

    if ($devices.Count -eq 0) {
        Write-Host 'No usable Vulkan device, so GPU filtering is not an option here.' -ForegroundColor DarkGray
    }
    else {
        $gpuGraph = New-VulkanFilterGraph `
            -Timeline $plan `
            -RenderFrames $frameCount `
            -ZoomMaximumPercent 110 `
            -BlurAmount 40 `
            -BackgroundBrightnessPercent 65 `
            -Width $script:Width -Height $script:Height `
            -HardwareOutputFrames $false

        $gpuRows = [Collections.Generic.List[object]]::new()
        $gpuRows.Add([pscustomobject]@{ 'Filtering runs on' = 'The processor (what ships)'; Seconds = ('{0:0.0}' -f $full); 'Against CPU' = 'reference' })
        foreach ($deviceIndex in $devices) {
            Write-Host "  timing: Vulkan device $deviceIndex ..." -NoNewline
            $measurement = Measure-Variant -Name "GPU device $deviceIndex" -FilterText ([string]$gpuGraph.FilterText) -BaselineFilterText $baseline `
                -WorkingDirectory $outputRoot -WatermarkPath $watermarkPath -ImageInputs $gpuGraph.ImageInputs `
                -FrameCount $frameCount -VulkanDevice ([string]$deviceIndex)
            if ($null -eq $measurement.Seconds) {
                Write-Host " $($measurement.Note)" -ForegroundColor Yellow
                $gpuRows.Add([pscustomobject]@{ 'Filtering runs on' = "Vulkan device $deviceIndex"; Seconds = 'n/a'; 'Against CPU' = $measurement.Note })
                continue
            }
            Write-Host (" {0:0.0}s" -f $measurement.Seconds) -ForegroundColor Gray
            $change = (($full - $measurement.Seconds) / $full) * 100.0
            $verdict = if ($change -ge 0) { '{0:0}% faster' -f $change } else { '{0:0}% slower' -f [Math]::Abs($change) }
            $gpuRows.Add([pscustomobject]@{ 'Filtering runs on' = "Vulkan device $deviceIndex"; Seconds = ('{0:0.0}' -f $measurement.Seconds); 'Against CPU' = $verdict })
        }

        Write-Host ''
        $gpuRows | Format-Table -AutoSize | Out-String | Write-Host
        Write-Host 'The application performs a shorter version of this comparison once per' -ForegroundColor DarkGray
        Write-Host 'machine and uses Vulkan motion effects only when they win by at least 8%.' -ForegroundColor DarkGray
        Write-Host ''
    }
}

# --- Concurrency sweep -----------------------------------------------------

if (-not $SkipLaneScaling) {
    Write-Host 'Lane scaling' -ForegroundColor White
    Write-Host '------------' -ForegroundColor White
    Write-Host 'Rendering the same segment side by side to find this machine''s best lane count.' -ForegroundColor DarkGray

    $filterPath = Join-Path $outputRoot 'filter-lanes.txt'
    [IO.File]::WriteAllText($filterPath, $baseline, [Text.UTF8Encoding]::new($false))
    $logicalCores = [Math]::Max(1, [Environment]::ProcessorCount)
    $candidates = @(1, 2, 3, 4, 6, 8) | Where-Object { $_ -le [Math]::Max(2, $logicalCores) } | Select-Object -Unique

    $laneRows = [Collections.Generic.List[object]]::new()
    foreach ($lanes in $candidates) {
        Write-Host "  timing: $lanes at once ..." -NoNewline
        $threads = [Math]::Max(1, [int][Math]::Floor($logicalCores / [double]$lanes))
        $processes = [Collections.Generic.List[object]]::new()
        $clock = [Diagnostics.Stopwatch]::StartNew()
        $failed = $false
        try {
            for ($lane = 0; $lane -lt $lanes; $lane++) {
                $arguments = [Collections.Generic.List[string]]::new()
                foreach ($value in @('-y', '-hide_banner', '-loglevel', 'error', '-nostats', '-filter_complex_threads', [string]$threads)) { $arguments.Add($value) }
                foreach ($value in @('-f', 'lavfi', '-i', 'anullsrc=r=48000:cl=stereo', '-stream_loop', '-1', '-i', $watermarkPath)) { $arguments.Add($value) }
                foreach ($imagePath in $graph.ImageInputs) { $arguments.Add('-i'); $arguments.Add([string]$imagePath) }
                foreach ($value in @('-filter_complex_script', $filterPath, '-map', '[vout]')) { $arguments.Add($value) }
                foreach ($value in (Get-EncodingArguments -Encoder $script:ChosenEncoder -Quality 'YouTube')) { $arguments.Add($value) }
                foreach ($value in @('-threads', [string]$threads, '-r', [string]$script:Fps, '-frames:v', [string]$frameCount, '-an', (Join-Path $outputRoot "lane-$lane.mp4"))) { $arguments.Add($value) }

                $startInfo = [Diagnostics.ProcessStartInfo]::new()
                $startInfo.FileName = $script:FfmpegPath
                $startInfo.Arguments = Join-Arguments $arguments.ToArray()
                $startInfo.UseShellExecute = $false
                $startInfo.CreateNoWindow = $true
                $startInfo.RedirectStandardOutput = $true
                $startInfo.RedirectStandardError = $true
                $process = [Diagnostics.Process]::new()
                $process.StartInfo = $startInfo
                [void]$process.Start()
                $null = $process.Handle
                $processes.Add($process)
            }
            foreach ($process in $processes) {
                [void]$process.StandardOutput.ReadToEnd()
                [void]$process.StandardError.ReadToEnd()
                $process.WaitForExit()
                if ($process.ExitCode -ne 0) { $failed = $true }
            }
        }
        finally {
            foreach ($process in $processes) {
                try { if (-not $process.HasExited) { $process.Kill() } } catch {}
                try { $process.Dispose() } catch {}
            }
        }
        $clock.Stop()

        if ($failed) {
            Write-Host ' refused' -ForegroundColor Yellow
            $laneRows.Add([pscustomobject]@{ Lanes = $lanes; 'Wall time' = 'n/a'; 'Segments per minute' = 'refused - encoder session limit' })
            # Past this point the encoder will refuse every larger count too.
            break
        }
        $perMinute = ($lanes / $clock.Elapsed.TotalSeconds) * 60.0
        Write-Host (" {0:0.0}s for {1} segments" -f $clock.Elapsed.TotalSeconds, $lanes) -ForegroundColor Gray
        $laneRows.Add([pscustomobject]@{ Lanes = $lanes; 'Wall time' = ('{0:0.0}s' -f $clock.Elapsed.TotalSeconds); 'Segments per minute' = ('{0:0.0}' -f $perMinute) })
    }

    Write-Host ''
    $laneRows | Format-Table -AutoSize | Out-String | Write-Host

    $best = $laneRows | Where-Object { $_.'Wall time' -ne 'n/a' } | Sort-Object { [double]($_.'Segments per minute') } -Descending | Select-Object -First 1
    if ($null -ne $best) {
        Write-Host "Fastest on this machine: $($best.Lanes) lanes at $($best.'Segments per minute') segments per minute." -ForegroundColor Green
    }
}

Get-ChildItem -LiteralPath $outputRoot -Filter '*.mp4' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -ne 'watermark.mp4' } |
    Remove-Item -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "Filter graphs and any failure logs were kept in $outputRoot" -ForegroundColor DarkGray
