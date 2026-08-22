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
        Assert-True ($graph.FilterText -match 'zoompan=') 'Zoom animation filter'
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
        Assert-True ($graph.FilterText -match '\(\(iw-iw/zoom\)/2\)') 'CPU crop offset is anchored to the zoom margin'
        Assert-True ($graph.FilterText -match '\(\(ih-ih/zoom\)/2\)') 'CPU vertical crop offset is anchored to the zoom margin'
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
        # A still image looped after the upload is sent to the card once. Looped
        # before it, the same canvas crossed the bus 48 times a second.
        Assert-True (-not ($gpuGraph.FilterText -match 'loop=loop=\d+:size=1:start=0,trim=end_frame=\d+,setpts=PTS-STARTPTS,format=nv12,hwupload')) 'Vulkan path does not re-upload the same still frame every frame'
        # The crop is computed on real numbers here, so this canvas exists only
        # to keep the most magnified crop from being an upscale. 2400x1350
        # divided by the 1.1 zoom ceiling still exceeds 1920x1080.
        Assert-True ($gpuGraph.FilterText -match 'scale=2400:1350') 'Vulkan path prepares enough overscan to avoid upscaling at maximum zoom'
        Assert-True (-not ($gpuGraph.FilterText -match 'scale=3840:2160')) 'Vulkan path does not carry the CPU renderer''s oversized canvas'

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
Assert-True ($captionGraph.FilterText -match 'zoompan=') 'Captioned graph remains animated'

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

$estimated = Get-EstimatedOutputSizeMb -DurationSeconds 1200 -Quality Compact
Assert-True ($estimated -eq 324) 'Twenty-minute compact size estimate'

'All SlideshowEngine tests passed.'
