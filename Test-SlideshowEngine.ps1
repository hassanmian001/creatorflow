Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
Import-Module (Join-Path $root 'SlideshowEngine.psm1') -Force

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) {
        throw "Assertion failed: $Message"
    }
}

$images = 1..20 | ForEach-Object { "C:\example-images\image-$_.jpg" }
$durations = @(480.0, 1156.0, 1800.0, 2400.0)

foreach ($duration in $durations) {
    foreach ($seed in @(1, 17, 12345)) {
        $plan = New-TimelinePlan `
            -ImagePaths $images `
            -AudioDurationSeconds $duration `
            -MinimumDurationSeconds 5.0 `
            -MaximumDurationSeconds 7.0 `
            -Fps 24 `
            -Seed $seed

        $frameSum = ($plan.Items | Measure-Object Frames -Sum).Sum
        Assert-True ($frameSum -eq $plan.TotalFrames) "Timeline frame sum for $duration seconds"

        foreach ($item in $plan.Items) {
            Assert-True ($item.DurationTenths -ge 50 -and $item.DurationTenths -le 70) 'Duration remains within range'
            Assert-True ($item.ZoomDirection -in @('In', 'Out')) 'Zoom direction is valid'
            Assert-True ($item.PanDirection -in @('Left', 'Right', 'Up', 'Down')) 'Pan direction is valid'
        }

        for ($index = 1; $index -lt $plan.Items.Count; $index++) {
            Assert-True ($plan.Items[$index - 1].ImagePath -ne $plan.Items[$index].ImagePath) 'No adjacent duplicates'
        }

        $previewFrames = [Math]::Min(1440, $plan.TotalFrames)
        $graph = New-FilterGraph `
            -Timeline $plan `
            -RenderFrames $previewFrames `
            -ZoomMaximumPercent 110 `
            -BlurAmount 40 `
            -BackgroundBrightnessPercent 65

        Assert-True ($graph.RenderFrames -eq $previewFrames) 'Preview frame count'
        Assert-True ($graph.FilterText -match 'blend=all_mode=screen:shortest=0:repeatlast=1') 'Screen watermark blend and exact-length behavior'
        Assert-True ($graph.FilterText -match 'format=gbrp') 'Screen blend is performed in RGB color space'
        Assert-True ($graph.FilterText -match 'perspective=') 'Zoom animation filter'
        Assert-True (-not ($graph.FilterText -match 'zoompan=')) 'CPU zoom does not use whole-pixel cropping'
        Assert-True ($graph.FilterText -match 'sense=source:eval=frame') 'CPU crop is re-evaluated every frame in source coordinates'
        Assert-True ($graph.FilterText -match 'interpolation=cubic') 'CPU crop samples between pixels rather than snapping to them'
        Assert-True ($graph.FilterText -match 'fps=24') 'CPU zoom is generated once per delivered frame'
        Assert-True (-not ($graph.FilterText -match 'tmix=')) 'CPU zoom carries no temporal blend'
        Assert-True ($graph.FilterText -match 'gblur=') 'Blurred background filter'
        Assert-True (-not $graph.FilterText.TrimEnd().EndsWith(';')) 'Filter graph has no empty trailing chain'

        $gpuGraph = New-VulkanFilterGraph `
            -Timeline $plan `
            -RenderFrames $previewFrames `
            -ZoomMaximumPercent 110 `
            -BlurAmount 40 `
            -BackgroundBrightnessPercent 65

        Assert-True ($gpuGraph.RenderFrames -eq $previewFrames) 'Vulkan preview frame count'
        Assert-True ($gpuGraph.FilterText -match 'libplacebo=') 'Vulkan zoom animation filter'
        Assert-True ($gpuGraph.FilterText -match 'hwupload') 'Vulkan upload stage'
        Assert-True ($gpuGraph.FilterText -match 'hwdownload') 'Vulkan path returns frames for colour-safe Screen blending'
        Assert-True ($gpuGraph.FilterText -match 'blend=all_mode=screen:shortest=0:repeatlast=1') 'Vulkan path retains exact RGB Screen blending'
        Assert-True ($gpuGraph.FilterText -match 'format=gbrp') 'Vulkan Screen blend uses planar RGB'
        Assert-True (-not ($gpuGraph.FilterText -match 'custom_shader_path=')) 'Faulty GPU invert shader is not used'
        Assert-True ($gpuGraph.FilterText -match 'upscaler=lanczos') 'Vulkan path uses a stable high-quality photo resampler'
        Assert-True (-not ($graph.FilterText -match 'cos\(')) 'CPU zoom moves at a constant rate with no easing'
        Assert-True (-not ($gpuGraph.FilterText -match 'cos\(')) 'Vulkan zoom moves at a constant rate with no easing'
        Assert-True ($graph.FilterText -match '\(\(W-\(W/') 'CPU crop offset is anchored to the zoom margin'
        Assert-True ($graph.FilterText -match '\(\(H-\(H/') 'CPU vertical crop offset is anchored to the zoom margin'
        Assert-True ($gpuGraph.FilterText -match '\(\(iw-cw\)/2\)') 'Vulkan crop offset is anchored to the zoom margin'
        Assert-True ($gpuGraph.FilterText -match '\(\(ih-ch\)/2\)') 'Vulkan vertical crop offset is anchored to the zoom margin'
        Assert-True ($graph.FilterText -match '\*\(1[-+]0\.5\)') 'CPU zoom applies the pan offset'
        Assert-True ($gpuGraph.FilterText -match '\*\(1[-+]0\.5\)') 'Vulkan zoom applies the pan offset'
        # The offset multiplier has to stay constant across the clip. When it
        # varied with progress it cancelled against the growing zoom margin,
        # so the pan stalled for three quarters of a second and then reversed.
        Assert-True (-not ($graph.FilterText -match "x='[^']*2\*min")) 'CPU pan offset does not vary with progress'
        Assert-True (-not ($graph.FilterText -match "y='[^']*2\*min")) 'CPU vertical pan offset does not vary with progress'
        Assert-True (-not ($gpuGraph.FilterText -match "crop_x='[^']*2\*min")) 'Vulkan pan offset does not vary with progress'
        Assert-True (-not ($gpuGraph.FilterText -match "crop_y='[^']*2\*min")) 'Vulkan vertical pan offset does not vary with progress'
        Assert-True ($gpuGraph.FilterText -match 'peak_detect=0') 'Vulkan path skips unnecessary HDR analysis'
        Assert-True ($gpuGraph.FilterText -match 'fps=24,format=nv12,hwupload,loop=') 'Vulkan zoom is generated once per delivered frame, from a single upload'
        # The loop filter hands out copies of one uploaded frame, and every copy
        # carries that frame's timestamp. Left alone, a time-driven crop reads
        # the same instant for the whole clip and the motion never starts.
        Assert-True ($gpuGraph.FilterText -match 'setpts=N/\(24\*TB\),libplacebo=') 'Vulkan clip rebuilds timestamps from the frame counter before the crop'
        Assert-True (-not ($gpuGraph.FilterText -match "crop_w='[^']*t\*")) 'Vulkan crop is driven by frame number, not by a timestamp the loop never advances'
        # A still image looped after the upload is sent to the card once. Looped
        # before it, the same canvas crossed the bus 48 times a second.
        Assert-True (-not ($gpuGraph.FilterText -match 'loop=loop=\d+:size=1:start=0,trim=end_frame=\d+,setpts=PTS-STARTPTS,format=nv12,hwupload')) 'Vulkan path does not re-upload the same still frame every frame'
        # Both renderers crop on real numbers, so the canvas exists only to keep
        # the most magnified crop from becoming an upscale: 2112x1188 divided by
        # the 1.1 zoom ceiling is exactly 1920x1080. Overscan beyond that was
        # measured to buy no smoothness at all - zoompan sat at 18.8 percent
        # frame-to-frame variance on a 2x canvas and 12.8 percent on a 4x one -
        # while costing render time in direct proportion to its area.
        Assert-True ($gpuGraph.FilterText -match 'scale=2112:1188') 'Vulkan path prepares enough overscan to avoid upscaling at maximum zoom'
        # Overscan sized by measurement, not by zoompan's old rounding problem:
        # structural similarity to a reference frame flattens after 1.5x.
        Assert-True ($graph.FilterText -match 'scale=2112:1188') 'CPU path prepares enough overscan to hold detail at maximum zoom'
        Assert-True (-not ($graph.FilterText -match 'scale=3840:2160')) 'CPU path no longer carries the oversized zoompan canvas'
        # Sharpening scored worse against that reference in every configuration.
        Assert-True (-not ($graph.FilterText -match 'unsharp=')) 'CPU path does not manufacture edge energy'

        $cpuForVulkan = New-FilterGraph -Timeline $plan -RenderFrames $previewFrames -HardwareOutputFrames
        Assert-True ($cpuForVulkan.FilterText -match '\[composited\]format=nv12,hwupload\[vout\]') 'Processor graph uploads finished frames for the Vulkan encoder'
        Assert-True (-not ($cpuForVulkan.FilterText -match 'libplacebo=')) 'Vulkan encoder no longer pulls in the Vulkan motion graph'
        $cpuCaptionsForVulkan = New-FilterGraph -Timeline $plan -RenderFrames $previewFrames -SubtitlePath 'C:\captions\video.srt' -HardwareOutputFrames
        Assert-True ($cpuCaptionsForVulkan.FilterText -match 'subtitles=[^\r\n]*,format=nv12,hwupload\[vout\]') 'Processor graph uploads after burned captions'
        Assert-True ($graph.FilterText -match '\[composited\]null\[vout\]') 'Processor graph stays in system memory for other encoders'

        $gpuSoftwareOut = New-VulkanFilterGraph `
            -Timeline $plan `
            -RenderFrames $previewFrames `
            -ZoomMaximumPercent 110 `
            -BlurAmount 40 `
            -BackgroundBrightnessPercent 65 `
            -HardwareOutputFrames $false
        Assert-True ($gpuSoftwareOut.FilterText -match '\[composited\]null\[vout\]') 'Vulkan filtering can hand finished frames to a non-Vulkan encoder'
        Assert-True ($gpuGraph.FilterText -match '\[composited\]format=nv12,hwupload\[vout\]') 'Vulkan encoder still receives hardware frames'
        Assert-True (-not ($gpuGraph.FilterText -match 'tmix=')) 'Vulkan zoom carries no temporal blend'
        Assert-True (-not ($gpuGraph.FilterText -match 'zoompan=')) 'Vulkan path avoids CPU zoompan'
        Assert-True (-not $gpuGraph.FilterText.TrimEnd().EndsWith(';')) 'Vulkan graph has no empty trailing chain'

        $sliceFrames = [Math]::Min(240, $plan.TotalFrames - 24)
        $slice = New-TimelineSlice -Timeline $plan -StartFrame 24 -FrameCount $sliceFrames
        Assert-True ($slice.TotalFrames -eq $sliceFrames) 'Timeline slice has exact requested frames'
        Assert-True ((($slice.Items | Measure-Object Frames -Sum).Sum) -eq $sliceFrames) 'Timeline slice item sum'
    }
}

# A voiceover is whatever length it is, and every image lasts a whole number of
# tenths of a second. Where a tenth divides evenly into frames - 3 frames at 30
# FPS - every buildable total is a multiple of 3, and only about a third of
# voiceovers land on one. The other two thirds used to fail outright, telling
# the person to nudge a duration range that could not have helped.
$timingRandom = [System.Random]::new(7)
$timingDurations = 1..40 | ForEach-Object { 120.0 + $timingRandom.NextDouble() * 1080.0 }
foreach ($timingFps in 24, 25, 30, 60) {
    foreach ($timingDuration in $timingDurations) {
        $timingPlan = New-TimelinePlan `
            -ImagePaths $images `
            -AudioDurationSeconds $timingDuration `
            -MinimumDurationSeconds 5.0 `
            -MaximumDurationSeconds 7.0 `
            -Fps $timingFps `
            -Seed 5
        $timingSum = ($timingPlan.Items | Measure-Object Frames -Sum).Sum
        Assert-True ($timingSum -eq $timingPlan.TotalFrames) "Timeline totals agree at $timingFps FPS"
        # Rounding up rather than down, so the picture never runs out before the
        # voiceover does. The mux ends on the shorter stream and trims the rest.
        $timingOvershoot = ($timingPlan.TotalFrames / [double]$timingFps) - $timingDuration
        Assert-True ($timingOvershoot -ge 0) "Video does not end before the voiceover at $timingFps FPS"
        Assert-True ($timingOvershoot -lt 0.2) "Video ends within a fraction of a second of the voiceover at $timingFps FPS"
    }
}

$nvenc = Get-EncodingArguments -Encoder h264_nvenc -Quality Compact
Assert-True ($nvenc -contains 'h264_nvenc') 'NVENC arguments'
Assert-True ($nvenc -contains '2000k') 'Improved Compact bitrate'
Assert-True ($nvenc -contains 'p4') 'NVENC uses the quality-balanced P4 preset'
Assert-True ($nvenc -contains '-spatial_aq') 'NVENC spatial adaptive quantization'

$amf = Get-EncodingArguments -Encoder h264_amf -Quality Balanced
Assert-True ($amf -contains 'h264_amf') 'AMD AMF encoder arguments'
Assert-True ($amf -contains '4000k') 'AMF balanced bitrate'
Assert-True ($amf -contains 'yuv420p') 'AMF output stays 8-bit 4:2:0'

$vulkan = Get-EncodingArguments -Encoder h264_vulkan -Quality Compact
Assert-True ($vulkan -contains 'h264_vulkan') 'Vulkan encoder arguments'
Assert-True ($vulkan -contains '2000k') 'Vulkan compact bitrate'
Assert-True ($vulkan -contains '-async_depth') 'Vulkan encoder uses a deeper asynchronous queue'
Assert-True (-not ($vulkan -contains '-pix_fmt')) 'Vulkan frames stay in GPU memory for encoding'

$youtube = Get-EncodingArguments -Encoder h264_vulkan -Quality YouTube
Assert-True ($youtube -contains '10000k') 'YouTube target bitrate'
Assert-True ($youtube -contains '-g') 'YouTube keyframe interval'

$captionGraph = New-FilterGraph -Timeline $plan -RenderFrames 240 -SubtitlePath 'C:\captions\video.srt'
Assert-True ($captionGraph.FilterText -match 'subtitles=') 'Optional burned captions filter'
Assert-True ($captionGraph.FilterText -match 'perspective=') 'Captioned graph remains animated'

$openClGraph = New-FilterGraph -Timeline $plan -RenderFrames 240 -OpenClScreenKernelPath 'C:\app\Shaders\screen.cl'
Assert-True ($openClGraph.FilterText -match 'program_opencl=.*kernel=screen_rgb') 'GPU Screen compositor is selected'
Assert-True ($openClGraph.FilterText -match 'hwupload') 'GPU Screen compositor uploads RGBA frames'
Assert-True ($openClGraph.FilterText -match 'hwdownload') 'GPU Screen compositor returns encoder-ready frames'

$openClCaptionGraph = New-FilterGraph -Timeline $plan -RenderFrames 240 -SubtitlePath 'C:\captions\video.srt' -OpenClScreenKernelPath 'C:\app\Shaders\screen.cl'
Assert-True ($openClCaptionGraph.FilterText -match 'kernel=screen_caption_rgb') 'GPU Screen and caption kernel is selected'
Assert-True ($openClCaptionGraph.FilterText -match 'subtitles=.*alpha=1') 'Caption layer preserves alpha for GPU compositing'

$captionPresets = @(
    '1. Clean YouTube', '2. Modern News', '3. Minimal Shadow', '4. Translucent Box',
    '5. Yellow Headline', '6. Cyan Accent', '7. Documentary Serif',
    '8. Yellow Emphasis', '9. Upper Safe', '10. Compact Broadcast'
)
$captionStyleGraphs = foreach ($preset in $captionPresets) {
    (New-FilterGraph -Timeline $plan -RenderFrames 240 -SubtitlePath 'C:\captions\video.srt' -CaptionPreset $preset).FilterText
}
Assert-True (($captionStyleGraphs | Sort-Object -Unique).Count -eq 10) 'All ten caption presets produce distinct styles'
Assert-True ($captionStyleGraphs[8] -match 'Alignment=8') 'Upper Safe preset uses top alignment'
Assert-True ($captionStyleGraphs[9] -match 'Alignment=1') 'Compact Broadcast uses left alignment'

$customCaptionStyle = [pscustomobject]@{
    CaptionFont = 'Georgia'; CaptionFontSize = 19; CaptionBold = $false
    CaptionTextColor = '#FFEBCD'; CaptionOutlineColor = '#112233'; CaptionOutlineWidth = 3
    CaptionShadow = 2; CaptionBackgroundColor = '#07111F'; CaptionBackgroundOpacity = 60
    CaptionAlignment = 'Right'; CaptionPositionX = 67; CaptionPositionY = 20
    CaptionMaxWidth = 58; CaptionLineSpacing = 1.15
}
$customCaptionGraph = New-FilterGraph -Timeline $plan -RenderFrames 240 -SubtitlePath 'C:\captions\video.srt' -CaptionStyle $customCaptionStyle
Assert-True ($customCaptionGraph.FilterText -match 'FontName=Georgia') 'Custom caption font reaches the burned export graph'
Assert-True ($customCaptionGraph.FilterText -match 'FontSize=19') 'Custom caption size reaches the burned export graph'
Assert-True ($customCaptionGraph.FilterText -match 'PrimaryColour=&H00CDEBFF') 'Custom caption RGB color is converted to ASS ordering'
Assert-True ($customCaptionGraph.FilterText -match 'BackColour=&H66') 'Custom caption background opacity is converted to ASS alpha'
Assert-True ($customCaptionGraph.FilterText -match 'ScaleY=115') 'Custom caption line spacing reaches the export graph'
Assert-True ($customCaptionGraph.FilterText -match 'Alignment=9') 'Custom upper-right position reaches the export graph'

$wrappedCaption = Format-CaptionText -Text 'Mayor Zohran Mamdani has completely overhauled the mayor''s fund.' -MaxWordsPerLine 6
$wrappedLines = @($wrappedCaption -split '\r?\n')
Assert-True ($wrappedLines.Count -eq 2) 'Caption text is split into the expected number of lines'
Assert-True ((@($wrappedLines[0] -split '\s+')).Count -eq 6) 'Caption first line respects the words-per-line limit'
Assert-True ((@($wrappedLines[1] -split '\s+')).Count -le 6) 'Caption final line respects the words-per-line limit'

$captionTestRoot = Join-Path ([IO.Path]::GetTempPath()) ("SlideshowCaptionTest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $captionTestRoot | Out-Null
try {
    $sourceSrt = Join-Path $captionTestRoot 'source.srt'
    $wrappedSrt = Join-Path $captionTestRoot 'wrapped.srt'
    [IO.File]::WriteAllText($sourceSrt, "1`r`n00:00:00,000 --> 00:00:03,000`r`nOne two three four five six seven eight`r`n", [Text.UTF8Encoding]::new($false))
    [void](Copy-SrtWithWordWrapping -SourcePath $sourceSrt -DestinationPath $wrappedSrt -MaxWordsPerLine 4)
    $wrappedSrtText = Get-Content -LiteralPath $wrappedSrt -Raw
    Assert-True ($wrappedSrtText -match "One two three four\r?\nfive six seven eight") 'Exported SRT uses the selected words-per-line limit'
}
finally {
    if (Test-Path -LiteralPath $captionTestRoot -PathType Container) { Remove-Item -LiteralPath $captionTestRoot -Recurse -Force }
}

$vulkanCaptionGraph = New-VulkanFilterGraph -Timeline $plan -RenderFrames 240 -SubtitlePath 'C:\captions\video.srt'
Assert-True ($vulkanCaptionGraph.FilterText -match 'subtitles=') 'Vulkan burned captions layer'
Assert-True ($vulkanCaptionGraph.FilterText -match 'hwdownload') 'Burned captions use the compatible libass CPU stage'
Assert-True (-not ($vulkanCaptionGraph.FilterText -match 'overlay_vulkan')) 'Vulkan alpha overlay is avoided on older Pascal drivers'

foreach ($fade in @(0.0, 0.5)) {
    $openClGraph = New-OpenClFilterGraph -Timeline $plan -RenderFrames 720 -MotionKernelPath 'C:\run\motion.cl' -WatermarkRect @(696, 792, 528, 288) -WatermarkLoopFrames 221 -CrossfadeSeconds $fade -OverscanScale 1.1
    $text = $openClGraph.FilterText
    $clipCount = $openClGraph.ActiveItemCount
    Assert-True ($openClGraph.RenderFrames -eq 720) 'OpenCL frame count'
    Assert-True (([regex]::Matches($text, 'kernel=clip_\d+')).Count -eq $clipCount) 'OpenCL graph runs one motion kernel per clip'
    Assert-True (([regex]::Matches($openClGraph.KernelSource, '__kernel void clip_\d+')).Count -eq $clipCount) 'OpenCL program defines one kernel per clip'
    Assert-True ($openClGraph.KernelSource -match 'start \+ 1\.0f \+ \(float\)frame_index') 'OpenCL motion counts frames from 1, like perspective'
    Assert-True ($openClGraph.KernelSource -match 'CUBIC_A \(-0\.60f\)') 'OpenCL motion uses the processor graph''s cubic'
    Assert-True ($text -match 'hwupload,loop=' -or $text -match 'hwupload\[base') 'Each photograph is uploaded once, before the loop'
    Assert-True ($text -match ':s=1920x1080') 'Motion kernels render straight to the delivery size'
    Assert-True ($text -match 'kernel=deliver:inputs=3:s=1920x1620') 'Watermark blend and YUV conversion run on the GPU into one packed gray frame'
    Assert-True ($text -match 'crop=528:288:696:792') 'Only the watermark''s rectangle is carried'
    Assert-True ($text -match 'trim=end_frame=221,format=rgba,hwupload,loop=loop=-1:size=221') 'One watermark cycle is uploaded and replayed'
    Assert-True ($openClGraph.KernelSource -match 'inside\.x < 528 && inside\.y < 288') 'Deliver kernel blends only inside the watermark rectangle'
    Assert-True ($openClGraph.KernelSource -match '0\.2126f, 0\.7152f, 0\.0722f') 'Deliver kernel converts with BT.709 weights'
    Assert-True ($text -match 'setpts=N\[layout\]') 'Layout frame is on the integer frame clock'
    Assert-True ($text -match '\[watermarkocl\]' -and $text -match 'settb=1/24,setpts=N\[watermarkocl\]') 'Watermark is put on the integer frame clock before the multi-input kernel'
    Assert-True ($text -match 'settb=1/24,setpts=N\[vseq\]') 'Picture is put on the same integer frame clock before the multi-input kernel'
    Assert-True ($text -match 'mergeplanes=map0s=0:map0p=0:map1s=1:map1p=0:map2s=2:map2p=0:format=yuv420p') 'Packed planes are reassembled as YUV 4:2:0'
    Assert-True ($text -match 'setparams=range=tv:colorspace=bt709') 'Reassembled frames are tagged BT.709 limited range'
    Assert-True (-not ($text -match 'format=rgba,scale=')) 'No RGB to YUV conversion is left for the processor'
    Assert-True (-not ($text -match 'xfade_opencl')) 'xfade_opencl is never used: it skips ahead when chained'
    Assert-True (-not $text.TrimEnd().EndsWith(';')) 'OpenCL filter graph has no empty trailing chain'
    if ($fade -gt 0) {
        $fadeCount = ([regex]::Matches($text, 'kernel=crossfade')).Count
        Assert-True ($fadeCount -eq ($clipCount - 1)) 'One crossfade per join'
        Assert-True ($openClGraph.KernelSource -match '__kernel void crossfade') 'Crossfade kernel is emitted when fading'
        Assert-True ($text -match "concat=n=$($clipCount + $fadeCount):v=1:a=0") 'Clip bodies and fades are joined in order'
    }
    else {
        Assert-True (-not ($openClGraph.KernelSource -match 'crossfade')) 'No crossfade kernel without fades'
        Assert-True ($text -match "concat=n=$($clipCount):v=1:a=0") 'Hard cuts concatenate the clips'
    }
}
$openClCaptionGraph = New-OpenClFilterGraph -Timeline $plan -RenderFrames 240 -MotionKernelPath 'C:\run\motion.cl' -SubtitlePath 'C:\captions\video.srt'
Assert-True ($openClCaptionGraph.FilterText -match 'kernel=deliver:inputs=4') 'OpenCL burned captions are composited on the GPU'
Assert-True ($openClCaptionGraph.KernelSource -match '__read_only image2d_t caption') 'Deliver kernel takes the caption layer'
Assert-True ($openClCaptionGraph.FilterText -match 'crop=1920:1080:0:0,') 'Without a measured footprint the whole watermark frame is carried'
Assert-True ($openClCaptionGraph.FilterText -match 'setpts=N\[captionocl\]') 'Caption layer is on the integer frame clock'

$signatureA = Get-RenderMachineSignature -Encoder 'h264_nvenc' -FfmpegPath 'C:\ffmpeg.exe' -PipelineVersion 'p1'
$signatureB = Get-RenderMachineSignature -Encoder 'h264_amf' -FfmpegPath 'C:\ffmpeg.exe' -PipelineVersion 'p1'
$signatureC = Get-RenderMachineSignature -Encoder 'h264_nvenc' -FfmpegPath 'C:\ffmpeg.exe' -PipelineVersion 'p2'
Assert-True ($signatureA -eq (Get-RenderMachineSignature -Encoder 'h264_nvenc' -FfmpegPath 'C:\ffmpeg.exe' -PipelineVersion 'p1')) 'Machine signature is stable'
Assert-True ($signatureA -ne $signatureB -and $signatureA -ne $signatureC) 'A different encoder or pipeline means measuring again'
$profileRoot = Join-Path ([IO.Path]::GetTempPath()) ("SlideshowProfileTest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $profileRoot | Out-Null
try {
    $profilePath = Join-Path $profileRoot 'render-profile.json'
    Assert-True ($null -eq (Read-RenderProfile -Path $profilePath -Signature $signatureA)) 'No profile before the first measurement'
    [IO.File]::WriteAllText($profilePath, (@{ Signature = $signatureA; Backend = 'opencl'; Device = '0.0'; Lanes = 4 } | ConvertTo-Json))
    Assert-True ((Read-RenderProfile -Path $profilePath -Signature $signatureA).Device -eq '0.0') 'Profile measured on this machine is used'
    Assert-True ($null -eq (Read-RenderProfile -Path $profilePath -Signature $signatureB)) 'Profile measured on other hardware or settings is ignored'
    [IO.File]::WriteAllText($profilePath, '{ not json')
    Assert-True ($null -eq (Read-RenderProfile -Path $profilePath -Signature $signatureA)) 'A damaged profile is ignored'
}
finally { Remove-Item -LiteralPath $profileRoot -Recurse -Force -ErrorAction SilentlyContinue }

$estimated = Get-EstimatedOutputSizeMb -DurationSeconds 1200 -Quality Compact
Assert-True ($estimated -eq 324) 'Twenty-minute compact size estimate'

'All SlideshowEngine tests passed.'
