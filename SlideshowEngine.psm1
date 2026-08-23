Set-StrictMode -Version Latest

$script:InvariantCulture = [System.Globalization.CultureInfo]::InvariantCulture

function Get-SupportedImageFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Folder
    )

    if (-not (Test-Path -LiteralPath $Folder -PathType Container)) {
        throw "The image folder does not exist: $Folder"
    }

    $extensions = @('.jpg', '.jpeg', '.png', '.webp')
    return @(
        Get-ChildItem -LiteralPath $Folder -File -ErrorAction Stop |
            Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() } |
            Sort-Object FullName |
            ForEach-Object { $_.FullName }
    )
}

function Get-MediaDurationSeconds {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$FfprobePath,

        [Parameter(Mandatory = $true)]
        [string]$MediaPath
    )

    if (-not (Test-Path -LiteralPath $MediaPath -PathType Leaf)) {
        throw "The media file does not exist: $MediaPath"
    }

    $probeArgs = @(
        '-v', 'error',
        '-show_entries', 'format=duration',
        '-of', 'default=noprint_wrappers=1:nokey=1',
        $MediaPath
    )

    $output = & $FfprobePath @probeArgs 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $output) {
        throw "FFprobe could not read the duration of: $MediaPath"
    }

    $duration = 0.0
    if (-not [double]::TryParse(
            (($output | Select-Object -First 1).ToString().Trim()),
            [System.Globalization.NumberStyles]::Float,
            $script:InvariantCulture,
            [ref]$duration)) {
        throw "FFprobe returned an invalid duration for: $MediaPath"
    }

    if ($duration -le 0) {
        throw "The voiceover duration must be greater than zero."
    }

    return $duration
}

function New-ShuffledIndexCycle {
    param(
        [int]$Count,
        [System.Random]$Random,
        [int]$PreviousIndex = -1
    )

    $indices = [System.Collections.Generic.List[int]]::new()
    for ($index = 0; $index -lt $Count; $index++) {
        $indices.Add($index)
    }

    for ($index = $indices.Count - 1; $index -gt 0; $index--) {
        $swapIndex = $Random.Next(0, $index + 1)
        $temporary = $indices[$index]
        $indices[$index] = $indices[$swapIndex]
        $indices[$swapIndex] = $temporary
    }

    if ($Count -gt 1 -and $PreviousIndex -ge 0 -and $indices[0] -eq $PreviousIndex) {
        $swapIndex = $Random.Next(1, $Count)
        $temporary = $indices[0]
        $indices[0] = $indices[$swapIndex]
        $indices[$swapIndex] = $temporary
    }

    return $indices.ToArray()
}

function Get-AllowedDurationOptions {
    param(
        [int]$MinimumTenths,
        [int]$MaximumTenths,
        [int]$Fps
    )

    $options = [System.Collections.Generic.List[object]]::new()
    $seenFrames = @{}
    for ($tenths = $MinimumTenths; $tenths -le $MaximumTenths; $tenths++) {
        $seconds = $tenths / 10.0
        $frames = [Math]::Round(
            $seconds * $Fps,
            [System.MidpointRounding]::AwayFromZero
        )

        if (-not $seenFrames.ContainsKey($frames)) {
            $seenFrames[$frames] = $true
            $options.Add([pscustomobject]@{
                Tenths = $tenths
                Frames = [int]$frames
            })
        }
    }

    return @($options | Sort-Object Frames)
}

function New-ExactDurationSequence {
    param(
        [int]$Count,
        [int]$TargetFrames,
        [object[]]$AllowedOptions,
        [System.Random]$Random
    )

    $minimumFrames = [int]$AllowedOptions[0].Frames
    $maximumFrames = [int]$AllowedOptions[-1].Frames

    for ($attempt = 0; $attempt -lt 500; $attempt++) {
        $chosen = [System.Collections.Generic.List[object]]::new()
        $remaining = $TargetFrames
        $failed = $false

        for ($position = 0; $position -lt [Math]::Max(0, $Count - 2); $position++) {
            $remainingSlots = $Count - $position - 1
            $candidates = @(
                $AllowedOptions | Where-Object {
                    $after = $remaining - [int]$_.Frames
                    $after -ge ($remainingSlots * $minimumFrames) -and
                    $after -le ($remainingSlots * $maximumFrames)
                }
            )

            if ($candidates.Count -eq 0) {
                $failed = $true
                break
            }

            $selection = $candidates[$Random.Next(0, $candidates.Count)]
            $chosen.Add($selection)
            $remaining -= [int]$selection.Frames
        }

        if ($failed) {
            continue
        }

        $tail = [System.Collections.Generic.List[object]]::new()
        if ($Count -eq 1) {
            $match = @($AllowedOptions | Where-Object { [int]$_.Frames -eq $remaining })
            if ($match.Count -eq 1) {
                $tail.Add($match[0])
            }
        }
        else {
            $pairs = [System.Collections.Generic.List[object]]::new()
            foreach ($first in $AllowedOptions) {
                foreach ($second in $AllowedOptions) {
                    if (([int]$first.Frames + [int]$second.Frames) -eq $remaining) {
                        $pairs.Add([pscustomobject]@{ First = $first; Second = $second })
                    }
                }
            }

            if ($pairs.Count -gt 0) {
                $pair = $pairs[$Random.Next(0, $pairs.Count)]
                $tail.Add($pair.First)
                $tail.Add($pair.Second)
            }
        }

        if (($chosen.Count + $tail.Count) -eq $Count) {
            foreach ($item in $tail) {
                $chosen.Add($item)
            }
            return $chosen.ToArray()
        }
    }

    throw "Could not create exact 0.1-second image timings for this voiceover. Try changing the minimum or maximum duration by 0.1 seconds."
}

function New-TimelinePlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$ImagePaths,

        [Parameter(Mandatory = $true)]
        [double]$AudioDurationSeconds,

        [double]$MinimumDurationSeconds = 5.0,
        [double]$MaximumDurationSeconds = 7.0,
        [int]$Fps = 30,
        [Nullable[int]]$Seed
    )

    if ($ImagePaths.Count -lt 2) {
        throw "At least two readable images are required to avoid consecutive duplicates."
    }
    if ($Fps -le 0) {
        throw "FPS must be greater than zero."
    }
    if ($MinimumDurationSeconds -le 0 -or $MaximumDurationSeconds -le 0) {
        throw "Image durations must be greater than zero."
    }
    if ($MinimumDurationSeconds -gt $MaximumDurationSeconds) {
        throw "Minimum image duration cannot exceed maximum image duration."
    }

    $minimumTenths = [int][Math]::Round($MinimumDurationSeconds * 10)
    $maximumTenths = [int][Math]::Round($MaximumDurationSeconds * 10)
    $targetFrames = [int][Math]::Ceiling($AudioDurationSeconds * $Fps)
    $allowed = @(Get-AllowedDurationOptions -MinimumTenths $minimumTenths -MaximumTenths $maximumTenths -Fps $Fps)
    if ($allowed.Count -eq 0) {
        throw "No valid image durations were generated."
    }

    $minimumFrames = [int]$allowed[0].Frames
    $maximumFrames = [int]$allowed[-1].Frames
    $minimumCount = [int][Math]::Ceiling($targetFrames / [double]$maximumFrames)
    $maximumCount = [int][Math]::Floor($targetFrames / [double]$minimumFrames)
    if ($minimumCount -gt $maximumCount -or $maximumCount -lt 1) {
        throw "The voiceover is too short for the selected image-duration range."
    }

    $averageFrames = ($minimumFrames + $maximumFrames) / 2.0
    $occurrenceCount = [int][Math]::Round($targetFrames / $averageFrames)
    $occurrenceCount = [Math]::Max($minimumCount, [Math]::Min($maximumCount, $occurrenceCount))

    $actualSeed = if ($null -ne $Seed) { [int]$Seed } else { Get-Random -Minimum 1 -Maximum ([int]::MaxValue) }
    $random = [System.Random]::new($actualSeed)
    $durations = @(New-ExactDurationSequence -Count $occurrenceCount -TargetFrames $targetFrames -AllowedOptions $allowed -Random $random)

    $imageIndices = [System.Collections.Generic.List[int]]::new()
    $previousIndex = -1
    while ($imageIndices.Count -lt $occurrenceCount) {
        $cycle = @(New-ShuffledIndexCycle -Count $ImagePaths.Count -Random $random -PreviousIndex $previousIndex)
        foreach ($index in $cycle) {
            if ($imageIndices.Count -ge $occurrenceCount) {
                break
            }
            $imageIndices.Add($index)
            $previousIndex = $index
        }
    }

    $items = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $occurrenceCount; $index++) {
        $imageIndex = $imageIndices[$index]
        $duration = $durations[$index]
        $items.Add([pscustomobject]@{
            ImagePath = $ImagePaths[$imageIndex]
            ImageName = [IO.Path]::GetFileName($ImagePaths[$imageIndex])
            Frames = [int]$duration.Frames
            DurationTenths = [int]$duration.Tenths
            ZoomDirection = if ($random.Next(0, 2) -eq 0) { 'In' } else { 'Out' }
            # A slow drift across one axis gives the zoom a more filmic feel.
            # The offset is always scaled by the crop margin the zoom creates,
            # so the window can never leave the image.
            PanDirection = @('Left', 'Right', 'Up', 'Down')[$random.Next(0, 4)]
        })
    }

    return [pscustomobject]@{
        Version = 1
        Seed = $actualSeed
        Fps = $Fps
        AudioDurationSeconds = $AudioDurationSeconds
        TotalFrames = $targetFrames
        MinimumDurationSeconds = $minimumTenths / 10.0
        MaximumDurationSeconds = $maximumTenths / 10.0
        Items = $items.ToArray()
    }
}

function Format-InvariantNumber {
    param(
        [double]$Value,
        [string]$Format = '0.######'
    )
    return $Value.ToString($Format, $script:InvariantCulture)
}

function Get-OptionalPropertyValue {
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Object,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        $DefaultValue
    )
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) {
        return $DefaultValue
    }
    return $property.Value
}

function Get-PanOffsetExpressions {
    param(
        [string]$PanDirection,
        [string]$HorizontalMargin,
        [string]$VerticalMargin,
        [double]$DriftFraction = 0.5
    )

    # The crop sits at a fixed fraction off centre, and the zoom carries it
    # there. Because the margin only ever grows or shrinks with the zoom, and
    # this multiplier is constant, the crop travels in one direction for the
    # whole clip.
    #
    # An earlier version scaled the offset by a factor that ran from 1.5 down to
    # 0.5 across the clip. Multiplied by a margin growing from nothing, the
    # result peaked around two thirds through and then travelled backwards, and
    # near that turning point the crop landed on the same whole pixel for three
    # quarters of a second before jumping. On screen that is a pan that slows to
    # a halt, twitches, and reverses.
    #
    # DriftFraction stays at or below 1 so the window cannot leave the image:
    # the offset is valid anywhere between 0 and twice the centred margin.
    $driftText = Format-InvariantNumber ([Math]::Max(0.0, [Math]::Min(1.0, $DriftFraction)))
    switch ($PanDirection) {
        'Left'  { return [pscustomobject]@{ X = "$HorizontalMargin*(1-$driftText)"; Y = $VerticalMargin } }
        'Right' { return [pscustomobject]@{ X = "$HorizontalMargin*(1+$driftText)"; Y = $VerticalMargin } }
        'Up'    { return [pscustomobject]@{ X = $HorizontalMargin; Y = "$VerticalMargin*(1-$driftText)" } }
        'Down'  { return [pscustomobject]@{ X = $HorizontalMargin; Y = "$VerticalMargin*(1+$driftText)" } }
        default { return [pscustomobject]@{ X = $HorizontalMargin; Y = $VerticalMargin } }
    }
}

function Get-ClipSequenceFilters {
    param(
        [int]$ClipCount,
        [int[]]$ClipFrames,
        [int]$FadeFrames,
        [int]$Fps,
        [int]$TotalFrames,
        [string]$OutputLabel
    )

    if ($FadeFrames -le 0 -or $ClipCount -lt 2) {
        $labels = (0..($ClipCount - 1) | ForEach-Object { "[clip$_]" }) -join ''
        return @("$labels`concat=n=$ClipCount`:v=1`:a=0,trim=end_frame=$TotalFrames,setpts=PTS-STARTPTS[$OutputLabel]")
    }

    # Each clip was generated FadeFrames longer than its share of the timeline,
    # so the dissolves consume that surplus instead of shortening the video.
    # Without it the segment would come up (ClipCount-1)*FadeFrames short and
    # the voiceover would drift out of sync with the pictures.
    #
    # xfade holds the accumulated stream until "offset", blends for "duration",
    # then continues with the incoming clip, so the running length after each
    # join is (offset + incoming length). Both are expressed in seconds.
    $lines = [System.Collections.Generic.List[string]]::new()
    $fadeSeconds = Format-InvariantNumber ($FadeFrames / [double]$Fps)
    $accumulated = $ClipFrames[0]
    $current = '[clip0]'
    for ($index = 1; $index -lt $ClipCount; $index++) {
        $offsetFrames = $accumulated - $FadeFrames
        if ($offsetFrames -lt 0) { $offsetFrames = 0 }
        $offsetSeconds = Format-InvariantNumber ($offsetFrames / [double]$Fps)
        $target = if ($index -eq ($ClipCount - 1)) { "[xfadeout]" } else { "[xfade$index]" }
        $lines.Add("$current[clip$index]xfade=transition=fade:duration=$fadeSeconds`:offset=$offsetSeconds$target")
        $current = $target
        $accumulated = $offsetFrames + $ClipFrames[$index]
    }

    $lines.Add("[xfadeout]trim=end_frame=$TotalFrames,setpts=PTS-STARTPTS[$OutputLabel]")
    return $lines.ToArray()
}

function ConvertTo-FilterPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ''
    }
    return $Path.Replace('\', '/').Replace(':', '\:').Replace("'", "\'").Replace('[', '\[').Replace(']', '\]')
}

function New-TimelineSlice {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Timeline,
        [Parameter(Mandatory = $true)]
        [int]$StartFrame,
        [Parameter(Mandatory = $true)]
        [int]$FrameCount
    )

    if ($StartFrame -lt 0 -or $FrameCount -le 0 -or ($StartFrame + $FrameCount) -gt [int]$Timeline.TotalFrames) {
        throw 'Timeline slice is outside the available frame range.'
    }

    $sliceEnd = $StartFrame + $FrameCount
    $cursor = 0
    $items = [System.Collections.Generic.List[object]]::new()
    foreach ($item in $Timeline.Items) {
        $itemFrames = [int]$item.Frames
        $itemStart = $cursor
        $itemEnd = $cursor + $itemFrames
        $cursor = $itemEnd
        if ($itemEnd -le $StartFrame) { continue }
        if ($itemStart -ge $sliceEnd) { break }

        $overlapStart = [Math]::Max($StartFrame, $itemStart)
        $overlapEnd = [Math]::Min($sliceEnd, $itemEnd)
        $overlapFrames = $overlapEnd - $overlapStart
        if ($overlapFrames -le 0) { continue }

        $items.Add([pscustomobject]@{
            ImagePath = [string]$item.ImagePath
            ImageName = [string]$item.ImageName
            Frames = [int]$overlapFrames
            DurationTenths = [int][Math]::Round(($overlapFrames / [double]$Timeline.Fps) * 10.0)
            ZoomDirection = [string]$item.ZoomDirection
            SourceFrames = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceFrames' -DefaultValue $itemFrames)
            SourceStartFrame = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceStartFrame' -DefaultValue 0) + ($overlapStart - $itemStart)
            PanDirection = [string](Get-OptionalPropertyValue -Object $item -Name 'PanDirection' -DefaultValue 'None')
        })
    }

    $sum = ($items | Measure-Object Frames -Sum).Sum
    if ([int]$sum -ne $FrameCount) {
        throw "Timeline slice produced $sum frames instead of $FrameCount."
    }

    return [pscustomobject]@{
        Version = 2
        Seed = [int]$Timeline.Seed
        Fps = [int]$Timeline.Fps
        AudioDurationSeconds = $FrameCount / [double]$Timeline.Fps
        TotalFrames = $FrameCount
        MinimumDurationSeconds = [double]$Timeline.MinimumDurationSeconds
        MaximumDurationSeconds = [double]$Timeline.MaximumDurationSeconds
        SliceStartFrame = $StartFrame
        Items = $items.ToArray()
    }
}

function Convert-HexToAssColour {
    param([string]$Hex, [int]$OpacityPercent = 100)
    $value = ([string]$Hex).Trim().TrimStart('#')
    if ($value -notmatch '^[0-9A-Fa-f]{6}$') { $value = 'FFFFFF' }
    $red = $value.Substring(0, 2)
    $green = $value.Substring(2, 2)
    $blue = $value.Substring(4, 2)
    $alpha = [int][Math]::Round(255.0 * (1.0 - ([Math]::Max(0, [Math]::Min(100, $OpacityPercent)) / 100.0)))
    return ('&H{0:X2}{1}{2}{3}' -f $alpha, $blue, $green, $red)
}

function Format-CaptionText {
    [CmdletBinding()]
    param(
        [AllowEmptyString()][string]$Text,
        [int]$MaxWordsPerLine = 8
    )

    $words = @([regex]::Split(([string]$Text).Trim(), '\s+') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($words.Count -eq 0) { return '' }
    $limit = [Math]::Max(3, [Math]::Min(20, $MaxWordsPerLine))
    $lines = [Collections.Generic.List[string]]::new()
    for ($offset = 0; $offset -lt $words.Count; $offset += $limit) {
        $last = [Math]::Min($words.Count - 1, $offset + $limit - 1)
        $lines.Add(($words[$offset..$last] -join ' '))
    }
    return ($lines -join [Environment]::NewLine)
}

function Copy-SrtWithWordWrapping {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath,
        [int]$MaxWordsPerLine = 8
    )

    if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
        throw "Caption file does not exist: $SourcePath"
    }
    $source = Get-Content -LiteralPath $SourcePath -Raw
    $pattern = '(?ms)^\s*\d+\s*\r?\n(?<start>\d{2}:\d{2}:\d{2},\d{3})\s*-->\s*(?<end>\d{2}:\d{2}:\d{2},\d{3})[^\r\n]*\r?\n(?<text>.*?)(?=\r?\n\s*\r?\n|\z)'
    $matches = [regex]::Matches($source, $pattern)
    if ($matches.Count -eq 0) { throw 'The caption file contains no readable SRT entries.' }
    $output = [Text.StringBuilder]::new()
    $index = 1
    foreach ($match in $matches) {
        [void]$output.AppendLine([string]$index)
        [void]$output.AppendLine("$($match.Groups['start'].Value) --> $($match.Groups['end'].Value)")
        [void]$output.AppendLine((Format-CaptionText -Text $match.Groups['text'].Value -MaxWordsPerLine $MaxWordsPerLine))
        [void]$output.AppendLine()
        $index++
    }
    $destinationDirectory = Split-Path -Parent $DestinationPath
    if ($destinationDirectory -and -not (Test-Path -LiteralPath $destinationDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    }
    [IO.File]::WriteAllText($DestinationPath, $output.ToString(), [Text.UTF8Encoding]::new($false))
    return $DestinationPath
}

function Get-CaptionForceStyle {
    param(
        [string]$Preset = '1. Clean YouTube',
        [psobject]$CaptionStyle = $null
    )

    if ($null -ne $CaptionStyle -and $CaptionStyle.PSObject.Properties['CaptionFont']) {
        $fontName = ([string]$CaptionStyle.CaptionFont).Replace(',', '')
        $fontSize = [Math]::Max(10.0, [Math]::Min(36.0, [double]$CaptionStyle.CaptionFontSize))
        $bold = if ([bool]$CaptionStyle.CaptionBold) { 1 } else { 0 }
        $primary = Convert-HexToAssColour -Hex ([string]$CaptionStyle.CaptionTextColor)
        $outlineColour = Convert-HexToAssColour -Hex ([string]$CaptionStyle.CaptionOutlineColor)
        $backgroundOpacity = [int][Math]::Round([double]$CaptionStyle.CaptionBackgroundOpacity)
        $backColour = Convert-HexToAssColour -Hex ([string]$CaptionStyle.CaptionBackgroundColor) -OpacityPercent $backgroundOpacity
        $borderStyle = if ($backgroundOpacity -gt 0) { 3 } else { 1 }
        $outline = [Math]::Max(0.0, [Math]::Min(8.0, [double]$CaptionStyle.CaptionOutlineWidth))
        $shadow = [Math]::Max(0.0, [Math]::Min(8.0, [double]$CaptionStyle.CaptionShadow))
        $positionX = [Math]::Max(5.0, [Math]::Min(95.0, [double]$CaptionStyle.CaptionPositionX))
        $positionY = [Math]::Max(5.0, [Math]::Min(95.0, [double]$CaptionStyle.CaptionPositionY))
        $maxWidth = [Math]::Max(25.0, [Math]::Min(95.0, [double]$CaptionStyle.CaptionMaxWidth))
        $leftPercent = [Math]::Max(0.0, $positionX - ($maxWidth / 2.0))
        $rightPercent = [Math]::Max(0.0, 100.0 - ($positionX + ($maxWidth / 2.0)))
        $marginL = [int][Math]::Round(384.0 * $leftPercent / 100.0)
        $marginR = [int][Math]::Round(384.0 * $rightPercent / 100.0)
        $horizontal = switch ([string]$CaptionStyle.CaptionAlignment) { 'Left' { 1 }; 'Right' { 3 }; default { 2 } }
        if ($positionY -lt 34.0) {
            $alignment = 6 + $horizontal
            $marginV = [int][Math]::Round(288.0 * $positionY / 100.0)
        }
        elseif ($positionY -gt 66.0) {
            $alignment = $horizontal
            $marginV = [int][Math]::Round(288.0 * (100.0 - $positionY) / 100.0)
        }
        else {
            $alignment = 3 + $horizontal
            $marginV = 0
        }
        $scaleY = [int][Math]::Round(100.0 * [Math]::Max(0.8, [Math]::Min(1.5, [double]$CaptionStyle.CaptionLineSpacing)))
        return "FontName=$fontName\,FontSize=$fontSize\,Bold=$bold\,PrimaryColour=$primary\,OutlineColour=$outlineColour\,BackColour=$backColour\,BorderStyle=$borderStyle\,Outline=$outline\,Shadow=$shadow\,ScaleY=$scaleY\,Alignment=$alignment\,MarginL=$marginL\,MarginR=$marginR\,MarginV=$marginV"
    }

    # ASS colors use AABBGGRR ordering. Commas are escaped because this string
    # is embedded in an FFmpeg filter option.
    switch -Wildcard ($Preset) {
        '2.*'  { return 'FontName=Arial Narrow\,FontSize=16\,Bold=1\,PrimaryColour=&H00FFFFFF\,OutlineColour=&H00000000\,BackColour=&H780B1628\,BorderStyle=3\,Outline=3\,Shadow=0\,Alignment=1\,MarginL=72\,MarginR=72\,MarginV=92' }
        '3.*'  { return 'FontName=Segoe UI\,FontSize=16\,Bold=0\,PrimaryColour=&H00FFFFFF\,OutlineColour=&H00000000\,BackColour=&H80000000\,BorderStyle=1\,Outline=0\,Shadow=2\,Alignment=2\,MarginL=70\,MarginR=70\,MarginV=105' }
        '4.*'  { return 'FontName=Segoe UI Semibold\,FontSize=16\,Bold=1\,PrimaryColour=&H00FFFFFF\,OutlineColour=&H00000000\,BackColour=&H78000000\,BorderStyle=3\,Outline=4\,Shadow=0\,Alignment=2\,MarginL=70\,MarginR=70\,MarginV=92' }
        '5.*'  { return 'FontName=Segoe UI Semibold\,FontSize=17\,Bold=1\,PrimaryColour=&H0000D4FF\,OutlineColour=&H00000000\,BorderStyle=1\,Outline=3\,Shadow=0\,Alignment=2\,MarginL=65\,MarginR=65\,MarginV=92' }
        '6.*'  { return 'FontName=Segoe UI Semibold\,FontSize=16\,Bold=1\,PrimaryColour=&H00EED322\,OutlineColour=&H00000000\,BackColour=&H90000000\,BorderStyle=3\,Outline=3\,Shadow=0\,Alignment=2\,MarginL=70\,MarginR=70\,MarginV=92' }
        '7.*'  { return 'FontName=Georgia\,FontSize=17\,Bold=1\,PrimaryColour=&H00DCF4FF\,OutlineColour=&H00000000\,BackColour=&H88000000\,BorderStyle=3\,Outline=3\,Shadow=1\,Alignment=2\,MarginL=60\,MarginR=60\,MarginV=88' }
        '8.*'  { return 'FontName=Segoe UI Semibold\,FontSize=17\,Bold=1\,PrimaryColour=&H0000D4FF\,OutlineColour=&H00000000\,BorderStyle=1\,Outline=3\,Shadow=1\,Alignment=2\,MarginL=65\,MarginR=65\,MarginV=92' }
        '9.*'  { return 'FontName=Segoe UI Semibold\,FontSize=16\,Bold=1\,PrimaryColour=&H00FFFFFF\,OutlineColour=&H00000000\,BackColour=&H88000000\,BorderStyle=3\,Outline=3\,Shadow=0\,Alignment=8\,MarginL=70\,MarginR=70\,MarginV=62' }
        '10.*' { return 'FontName=Arial\,FontSize=14\,Bold=0\,PrimaryColour=&H00FFFFFF\,OutlineColour=&H00000000\,BackColour=&H82000000\,BorderStyle=3\,Outline=3\,Shadow=0\,Alignment=1\,MarginL=72\,MarginR=72\,MarginV=60' }
        default { return 'FontName=Segoe UI Semibold\,FontSize=16\,Bold=1\,PrimaryColour=&H00FFFFFF\,OutlineColour=&H00000000\,BorderStyle=1\,Outline=2\,Shadow=0\,Alignment=2\,MarginL=70\,MarginR=70\,MarginV=92' }
    }
}

function New-FilterGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Timeline,

        [Parameter(Mandatory = $true)]
        [int]$RenderFrames,

        [double]$ZoomMaximumPercent = 110.0,
        [double]$BlurAmount = 40.0,
        [double]$BackgroundBrightnessPercent = 65.0,
        [string]$SubtitlePath = '',
        [string]$CaptionPreset = '1. Clean YouTube',
        [psobject]$CaptionStyle = $null,
        [string]$OpenClScreenKernelPath = '',
        [double]$CrossfadeSeconds = 0.0,
        # How much larger than the delivery frame the motion works on. See the
        # table where it is used: more detail, less speed, and at 1.1 the crop
        # at maximum zoom is exactly a delivery frame so nothing is enlarged.
        [double]$OverscanScale = 1.1,
        [int]$Width = 1920,
        [int]$Height = 1080
    )

    if ($RenderFrames -le 0 -or $RenderFrames -gt [int]$Timeline.TotalFrames) {
        throw "Render frame count is outside the timeline."
    }

    $activeItems = [System.Collections.Generic.List[object]]::new()
    $accumulatedFrames = 0
    foreach ($item in $Timeline.Items) {
        if ($accumulatedFrames -ge $RenderFrames) {
            break
        }
        $activeItems.Add($item)
        $accumulatedFrames += [int]$item.Frames
    }

    $uniquePaths = [System.Collections.Generic.List[string]]::new()
    $pathToIndex = @{}
    foreach ($item in $activeItems) {
        $key = $item.ImagePath.ToLowerInvariant()
        if (-not $pathToIndex.ContainsKey($key)) {
            $pathToIndex[$key] = $uniquePaths.Count
            $uniquePaths.Add($item.ImagePath)
        }
    }

    $occurrencesByImage = @{}
    for ($itemIndex = 0; $itemIndex -lt $activeItems.Count; $itemIndex++) {
        $key = $activeItems[$itemIndex].ImagePath.ToLowerInvariant()
        $imageIndex = [int]$pathToIndex[$key]
        if (-not $occurrencesByImage.ContainsKey($imageIndex)) {
            $occurrencesByImage[$imageIndex] = [System.Collections.Generic.List[int]]::new()
        }
        $occurrencesByImage[$imageIndex].Add($itemIndex)
    }

    # Camera motion is generated once per delivered frame. An earlier version
    # optionally generated it at twice the delivery rate and blended three of
    # those frames into each delivered one, for a shutter-blur look. Measured
    # on real projects that one option cost 47 percent of the entire render -
    # more than every other stage put together, and eight times what encoding
    # cost - so it was removed rather than left as a trap.
    $fps = [int]$Timeline.Fps
    $blurSigma = [Math]::Max(0.1, [Math]::Min(50.0, $BlurAmount / 2.0))
    $brightnessAdjustment = ([Math]::Max(20.0, [Math]::Min(100.0, $BackgroundBrightnessPercent)) - 100.0) / 200.0
    $zoomMaximum = [Math]::Max(100.0, [Math]::Min(150.0, $ZoomMaximumPercent)) / 100.0
    $zoomDelta = $zoomMaximum - 1.0

    $blurText = Format-InvariantNumber $blurSigma
    $brightnessText = Format-InvariantNumber $brightnessAdjustment
    $zoomMaximumText = Format-InvariantNumber $zoomMaximum
    $zoomDeltaText = Format-InvariantNumber $zoomDelta
    $useOpenClComposite = -not [string]::IsNullOrWhiteSpace($OpenClScreenKernelPath)
    $captionForceStyle = Get-CaptionForceStyle -Preset $CaptionPreset -CaptionStyle $CaptionStyle
    # The canvas is the delivery size, and the motion filter warps the crop
    # straight onto it. There is no overscan because there is nothing left for
    # it to buy.
    #
    # It used to be 2x, on the reasoning that a larger canvas would push
    # zoompan's whole-pixel crop steps below one delivered pixel. Measured, it
    # does not: frame-to-frame motion variance was 18.8 percent at 2x, 13.5 at
    # 3x and 12.8 at 4x, so zoompan has a floor around 13 percent no canvas
    # reaches past, while 4x cost four times the render time. Cropping on real
    # numbers instead puts that measurement at 0.9 percent.
    #
    # Once the crop is exact, overscan only adds a second full-frame resample -
    # warp at canvas size, then scale down to delivery size. Dropping it and
    # warping directly to delivery size measured the same acutance (6.51
    # against 6.48 for the old renderer) and ran 45 percent faster.
    # Overscan is not about jitter. It used to be 2x on the reasoning that a
    # larger canvas would push zoompan's whole-pixel crop steps below one
    # delivered pixel; measured, it does not. Frame-to-frame motion variance
    # was 18.8 percent at 2x, 13.5 at 3x and 12.8 at 4x - zoompan has a floor
    # around 13 percent that no canvas reaches past. Cropping on real numbers
    # is what fixes that, and it puts the same measurement at 0.6 percent.
    #
    # What overscan buys is detail, and it costs a little smoothness back, so
    # this number is a balance rather than a maximum. Building one frame's
    # exact framing on a 4x canvas gives a reference to score against:
    #
    #   canvas   detail   motion variance   speed      40 x 10min
    #   1.00x     0.789        0.6%           2.34x        2.8 h
    #   1.10x     0.799        1.0%           2.04x        3.3 h
    #   1.25x     0.817        1.7%           1.65x        4.0 h
    #   1.50x     0.832        2.6%           1.12x        6.0 h
    #   2.00x     0.833          -              -            -
    #   zoompan   0.828       16.1%           3.07x        2.2 h
    #
    # Detail flattens after 1.5x. Motion variance rises with the canvas because
    # perspective interpolates on a fixed 1/256-of-a-source-pixel grid, so a
    # larger canvas makes that step coarser by the time it reaches delivery
    # size. Render time rises with the canvas area, steeply.
    #
    # This sits at the zoom ceiling, which is the one principled point on that
    # curve: the crop at maximum zoom is exactly a delivery frame, so the
    # picture is never enlarged, and every frame before it is a downsample.
    # Going higher buys detail that only shows up under close comparison and
    # costs hours a day at this tool's real workload - thirty to fifty videos.
    # Going lower starts enlarging the frame at the top of the zoom.
    # At or below 1 the canvas is the delivery frame and the top of the zoom
    # enlarges it - that is the deliberate trade the fastest setting makes.
    # Above 1 the canvas also never falls below the zoom ceiling, so the most
    # magnified crop is still a whole delivery frame or better.
    $workingScale = if ($OverscanScale -le 1.0) { 1.0 } else { [Math]::Max($OverscanScale, $zoomMaximum) }
    $workingWidth = [int]([Math]::Ceiling(($Width * $workingScale) / 2.0) * 2)
    $workingHeight = [int]([Math]::Ceiling(($Height * $workingScale) / 2.0) * 2)
    $filters = [System.Collections.Generic.List[string]]::new()

    for ($imageIndex = 0; $imageIndex -lt $uniquePaths.Count; $imageIndex++) {
        $inputIndex = $imageIndex + 2
        $filters.Add("[$inputIndex`:v]split=2[bgsrc$imageIndex][fgsrc$imageIndex]")
        # Prepare the static photo directly at the overscan resolution. The old
        # path first made a 1080p frame and enlarged it again for zoompan,
        # softening low-resolution photographs unnecessarily.
        $filters.Add("[bgsrc$imageIndex]scale=$workingWidth`:$workingHeight`:force_original_aspect_ratio=increase:flags=lanczos+accurate_rnd,crop=$workingWidth`:$workingHeight,gblur=sigma=$blurText,eq=brightness=$brightnessText[bg$imageIndex]")
        $filters.Add("[fgsrc$imageIndex]scale=$workingWidth`:$workingHeight`:force_original_aspect_ratio=decrease:flags=lanczos+accurate_rnd[fg$imageIndex]")
        $filters.Add("[bg$imageIndex][fg$imageIndex]overlay=(W-w)/2`:(H-h)/2:shortest=1,setsar=1[base$imageIndex]")

        $occurrences = $occurrencesByImage[$imageIndex]
        if ($occurrences.Count -eq 1) {
            $filters.Add("[base$imageIndex]null[occsrc$($occurrences[0])]")
        }
        else {
            $labels = ($occurrences | ForEach-Object { "[occsrc$_]" }) -join ''
            $filters.Add("[base$imageIndex]split=$($occurrences.Count)$labels")
        }
    }

    # A dissolve needs both images on screen at once, so each clip is generated
    # this much longer than its share of the timeline and the overlap is spent
    # on the blend. Capped at a third of the shortest clip so a long fade over
    # short images cannot swallow a picture whole.
    $fadeFrames = 0
    if ($CrossfadeSeconds -gt 0 -and $activeItems.Count -ge 2) {
        $shortestClip = ($activeItems | Measure-Object Frames -Minimum).Minimum
        $fadeFrames = [int][Math]::Round($CrossfadeSeconds * $fps)
        $fadeFrames = [Math]::Max(1, [Math]::Min($fadeFrames, [int][Math]::Floor($shortestClip / 3.0)))
    }
    $clipFrameCounts = [System.Collections.Generic.List[int]]::new()

    for ($itemIndex = 0; $itemIndex -lt $activeItems.Count; $itemIndex++) {
        $item = $activeItems[$itemIndex]
        $timelineFrames = [int]$item.Frames
        # The surplus is for the dissolve to consume; the motion still has to
        # complete over the image's own span, so SourceFrames stays unextended.
        $frames = $timelineFrames + $fadeFrames
        $sourceFrames = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceFrames' -DefaultValue $timelineFrames)
        $sourceStartFrame = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceStartFrame' -DefaultValue 0)
        $denominator = [Math]::Max(1, $sourceFrames - 1)
        # Constant velocity for the full clip. A cosine ease-in-out was tried
        # here, but easing all the way to zero velocity at both ends made
        # every clip visibly decelerate before the cut.
        $linearProgress = "min(1\,(on+$sourceStartFrame)/$denominator)"
        $zoomProgress = $linearProgress
        if ($item.ZoomDirection -eq 'Out') {
            $zoomExpression = "$zoomMaximumText-$zoomDeltaText*$zoomProgress"
        }
        else {
            $zoomExpression = "1+$zoomDeltaText*$zoomProgress"
        }

        # The crop window, in canvas pixels, as real numbers. perspective maps
        # this quadrilateral onto the full output rectangle and samples it with
        # a bicubic kernel, so a crop edge that lands a third of the way into a
        # pixel is rendered a third of the way into it. zoompan could only ever
        # place that edge on a whole pixel, and the resulting hold-then-jump is
        # what read as camera shake.
        $cropWidthExpression = "(W/($zoomExpression))"
        $cropHeightExpression = "(H/($zoomExpression))"

        # Drift slowly across one axis while zooming, at a constant rate for
        # the same reason the zoom is constant.
        $panDirection = [string](Get-OptionalPropertyValue -Object $item -Name 'PanDirection' -DefaultValue 'None')
        $pan = Get-PanOffsetExpressions -PanDirection $panDirection -HorizontalMargin "((W-$cropWidthExpression)/2)" -VerticalMargin "((H-$cropHeightExpression)/2)"
        $cropLeft = "($($pan.X))"
        $cropTop = "($($pan.Y))"
        $cropRight = "$cropLeft+$cropWidthExpression"
        $cropBottom = "$cropTop+$cropHeightExpression"

        # No sharpening pass. One was tried, because the cubic warp reads softer
        # than zoompan's scaler on an edge-energy probe and a light unsharp put
        # that number back where it was. Scored against the reference frame
        # instead, it made every configuration worse by about 0.045: it was
        # manufacturing edge energy the photograph never had, which is exactly
        # what an edge-energy probe cannot tell from real detail. Overscan buys
        # the detail back honestly; sharpening only looked like it did.
        #
        # A still image arrives as a single frame at the container's nominal
        # rate, so the clip's frames are generated here rather than by the
        # motion filter. setpts rebuilds the timestamps from the frame counter:
        # the loop filter hands out copies that all carry the source frame's
        # timestamp, and leaving those in place stalls anything downstream that
        # reads time, including xfade.
        $perspectiveExpressions = "x0='$cropLeft':y0='$cropTop':x1='$cropRight':y1='$cropTop':x2='$cropLeft':y2='$cropBottom':x3='$cropRight':y3='$cropBottom'"
        $clipFrameCounts.Add($frames)
        $filters.Add("[occsrc$itemIndex]fps=$fps,loop=loop=$($frames - 1)`:size=1`:start=0,trim=end_frame=$frames,setpts=N/($fps*TB),perspective=$perspectiveExpressions`:interpolation=cubic:sense=source:eval=frame,scale=$Width`:$Height`:flags=lanczos+accurate_rnd,setsar=1,trim=end_frame=$frames,setpts=PTS-STARTPTS,fps=$fps[clip$itemIndex]")
    }

    foreach ($line in (Get-ClipSequenceFilters -ClipCount $activeItems.Count -ClipFrames $clipFrameCounts.ToArray() -FadeFrames $fadeFrames -Fps $fps -TotalFrames $RenderFrames -OutputLabel 'vseq')) {
        $filters.Add($line)
    }
    if ($useOpenClComposite) {
        $kernelFilterPath = ConvertTo-FilterPath $OpenClScreenKernelPath
        $filters.Add('[vseq]format=rgba,hwupload[vseqocl]')
        $filters.Add("[1:v]fps=$fps,scale=$Width`:$Height`:flags=bicubic,setsar=1,trim=end_frame=$RenderFrames,setpts=PTS-STARTPTS,format=rgba,hwupload[watermarkocl]")
        if ([string]::IsNullOrWhiteSpace($SubtitlePath)) {
            $filters.Add("[vseqocl][watermarkocl]program_opencl=source='$kernelFilterPath':kernel=screen_rgb:inputs=2:shortest=0:repeatlast=1,hwdownload,format=rgba,format=yuv420p,trim=end_frame=$RenderFrames,setpts=N/($fps*TB)[vout]")
        }
        else {
            $subtitleFilterPath = ConvertTo-FilterPath $SubtitlePath
            $filters.Add("color=c=black@0.0:s=$Width`x$Height`:r=$fps,format=rgba,subtitles=filename='$subtitleFilterPath':alpha=1:force_style='$captionForceStyle',trim=end_frame=$RenderFrames,setpts=PTS-STARTPTS,hwupload[captionocl]")
            $filters.Add("[vseqocl][watermarkocl][captionocl]program_opencl=source='$kernelFilterPath':kernel=screen_caption_rgb:inputs=3:shortest=0:repeatlast=1,hwdownload,format=rgba,format=yuv420p,trim=end_frame=$RenderFrames,setpts=N/($fps*TB)[vout]")
        }
    }
    else {
        $filters.Add("[1:v]fps=$fps,scale=$Width`:$Height`:flags=bicubic,setsar=1,trim=end_frame=$RenderFrames,setpts=PTS-STARTPTS[watermark]")
        # Screen is an RGB compositing operation. Applying it directly to YUV
        # planes shifts colors because neutral chroma is encoded around 128.
        $filters.Add("[vseq]format=gbrp[vseqrgb]")
        $filters.Add("[watermark]format=gbrp[watermarkrgb]")
        $filters.Add("[vseqrgb][watermarkrgb]blend=all_mode=screen:shortest=0:repeatlast=1,trim=end_frame=$RenderFrames,setpts=PTS-STARTPTS,format=yuv420p[composited]")
        if ([string]::IsNullOrWhiteSpace($SubtitlePath)) {
            $filters.Add('[composited]null[vout]')
        }
        else {
            $subtitleFilterPath = ConvertTo-FilterPath $SubtitlePath
            $filters.Add("[composited]subtitles=filename='$subtitleFilterPath':force_style='$captionForceStyle'[vout]")
        }
    }

    return [pscustomobject]@{
        ImageInputs = $uniquePaths.ToArray()
        FilterText = ($filters -join ";`r`n") + "`r`n"
        ActiveItemCount = $activeItems.Count
        RenderFrames = $RenderFrames
        DurationSeconds = $RenderFrames / [double]$fps
    }
}

function New-VulkanFilterGraph {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [psobject]$Timeline,

        [Parameter(Mandatory = $true)]
        [int]$RenderFrames,

        [double]$ZoomMaximumPercent = 110.0,
        [double]$BlurAmount = 40.0,
        [double]$BackgroundBrightnessPercent = 65.0,
        [string]$SubtitlePath = '',
        [string]$CaptionPreset = '1. Clean YouTube',
        [psobject]$CaptionStyle = $null,
        [string]$OpenClScreenKernelPath = '',
        [double]$CrossfadeSeconds = 0.0,
        [double]$OverscanScale = 1.1,
        [int]$Width = 1920,
        [int]$Height = 1080,

        # Vulkan's own H.264 encoder needs the finished frames left on the GPU.
        # Every other encoder - NVENC, AMF, Quick Sync, libx264 - wants ordinary
        # frames in system memory, and passing $false ends the graph there so
        # this filter path can be used with any of them.
        [bool]$HardwareOutputFrames = $true
    )

    if ($RenderFrames -le 0 -or $RenderFrames -gt [int]$Timeline.TotalFrames) {
        throw "Render frame count is outside the timeline."
    }

    $activeItems = [System.Collections.Generic.List[object]]::new()
    $accumulatedFrames = 0
    foreach ($item in $Timeline.Items) {
        if ($accumulatedFrames -ge $RenderFrames) {
            break
        }
        $activeItems.Add($item)
        $accumulatedFrames += [int]$item.Frames
    }

    $uniquePaths = [System.Collections.Generic.List[string]]::new()
    $pathToIndex = @{}
    foreach ($item in $activeItems) {
        $key = $item.ImagePath.ToLowerInvariant()
        if (-not $pathToIndex.ContainsKey($key)) {
            $pathToIndex[$key] = $uniquePaths.Count
            $uniquePaths.Add($item.ImagePath)
        }
    }

    $occurrencesByImage = @{}
    for ($itemIndex = 0; $itemIndex -lt $activeItems.Count; $itemIndex++) {
        $key = $activeItems[$itemIndex].ImagePath.ToLowerInvariant()
        $imageIndex = [int]$pathToIndex[$key]
        if (-not $occurrencesByImage.ContainsKey($imageIndex)) {
            $occurrencesByImage[$imageIndex] = [System.Collections.Generic.List[int]]::new()
        }
        $occurrencesByImage[$imageIndex].Add($itemIndex)
    }

    # One generated frame per delivered frame, matching New-FilterGraph. See
    # the note there about the shutter-blur option that used to double this.
    $fps = [int]$Timeline.Fps
    $blurSigma = [Math]::Max(0.1, [Math]::Min(50.0, $BlurAmount / 2.0))
    $brightnessAdjustment = ([Math]::Max(20.0, [Math]::Min(100.0, $BackgroundBrightnessPercent)) - 100.0) / 200.0
    $zoomMaximum = [Math]::Max(100.0, [Math]::Min(150.0, $ZoomMaximumPercent)) / 100.0
    $zoomDelta = $zoomMaximum - 1.0

    $blurText = Format-InvariantNumber $blurSigma
    $brightnessText = Format-InvariantNumber $brightnessAdjustment
    $zoomMaximumText = Format-InvariantNumber $zoomMaximum
    $zoomDeltaText = Format-InvariantNumber $zoomDelta
    $useOpenClComposite = -not [string]::IsNullOrWhiteSpace($OpenClScreenKernelPath)
    $captionForceStyle = Get-CaptionForceStyle -Preset $CaptionPreset -CaptionStyle $CaptionStyle
    $filters = [System.Collections.Generic.List[string]]::new()
    # Vulkan framesync filters may retain a small tail while draining. Feed a
    # few cloned frames through the pipeline, then trim back to the exact job
    # length so every segment contains the requested number of frames.
    $pipelineTailFrames = 4
    $processingFrames = $RenderFrames + $pipelineTailFrames
    # Lanczos sampling keeps fine edges stable during a slow fractional crop;
    # bilinear sampling can shimmer as those edges cross the pixel grid.
    $gpuFastOptions = "upscaler=lanczos:downscaler=lanczos:skip_aa=1:disable_linear=1:peak_detect=0:apply_filmgrain=0"

    # Prepare each unique image with enough overscan that the most magnified
    # crop still contains a full delivery frame. An earlier version prepared
    # these at the delivery resolution itself, so a zoom had already discarded
    # the detail it was about to magnify, and the background blur was applied
    # to a frame a quarter of the area, making the same sigma look visibly
    # weaker here than in the final render.
    #
    # Both renderers now crop on real numbers, so both use the same canvas:
    # just large enough that the most magnified frame is still a downsample.
    # At or below 1 the canvas is the delivery frame and the top of the zoom
    # enlarges it - that is the deliberate trade the fastest setting makes.
    # Above 1 the canvas also never falls below the zoom ceiling, so the most
    # magnified crop is still a whole delivery frame or better.
    $workingScale = if ($OverscanScale -le 1.0) { 1.0 } else { [Math]::Max($OverscanScale, $zoomMaximum) }
    $workingWidth = [int]([Math]::Ceiling(($Width * $workingScale) / 2.0) * 2)
    $workingHeight = [int]([Math]::Ceiling(($Height * $workingScale) / 2.0) * 2)

    for ($imageIndex = 0; $imageIndex -lt $uniquePaths.Count; $imageIndex++) {
        $inputIndex = $imageIndex + 2
        $filters.Add("[$inputIndex`:v]split=2[bgsrc$imageIndex][fgsrc$imageIndex]")
        $filters.Add("[bgsrc$imageIndex]scale=$workingWidth`:$workingHeight`:force_original_aspect_ratio=increase:flags=lanczos+accurate_rnd,crop=$workingWidth`:$workingHeight,gblur=sigma=$blurText,eq=brightness=$brightnessText[bg$imageIndex]")
        $filters.Add("[fgsrc$imageIndex]scale=$workingWidth`:$workingHeight`:force_original_aspect_ratio=decrease:flags=lanczos+accurate_rnd[fg$imageIndex]")
        $filters.Add("[bg$imageIndex][fg$imageIndex]overlay=(W-w)/2`:(H-h)/2:shortest=1,setsar=1[base$imageIndex]")

        $occurrences = $occurrencesByImage[$imageIndex]
        if ($occurrences.Count -eq 1) {
            $filters.Add("[base$imageIndex]null[occsrc$($occurrences[0])]")
        }
        else {
            $labels = ($occurrences | ForEach-Object { "[occsrc$_]" }) -join ''
            $filters.Add("[base$imageIndex]split=$($occurrences.Count)$labels")
        }
    }

    # See the CPU renderer: each clip is generated this much longer than its
    # share of the timeline so the dissolves have something to consume and the
    # segment still contains exactly the frames the timeline promised.
    $fadeFrames = 0
    if ($CrossfadeSeconds -gt 0 -and $activeItems.Count -ge 2) {
        $shortestClip = ($activeItems | Measure-Object Frames -Minimum).Minimum
        $fadeFrames = [int][Math]::Round($CrossfadeSeconds * $fps)
        $fadeFrames = [Math]::Max(1, [Math]::Min($fadeFrames, [int][Math]::Floor($shortestClip / 3.0)))
    }
    $clipFrameCounts = [System.Collections.Generic.List[int]]::new()

    for ($itemIndex = 0; $itemIndex -lt $activeItems.Count; $itemIndex++) {
        $item = $activeItems[$itemIndex]
        $timelineFrames = [int]$item.Frames
        $frames = $timelineFrames + $fadeFrames
        $clipFrames = if ($itemIndex -eq ($activeItems.Count - 1)) { $frames + $pipelineTailFrames } else { $frames }
        $sourceFrames = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceFrames' -DefaultValue $timelineFrames)
        $sourceStartFrame = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceStartFrame' -DefaultValue 0)
        $denominator = [Math]::Max(1, $sourceFrames - 1)
        # Match the CPU renderer's constant-velocity zoom so GPU previews and
        # final renders look the same.
        #
        # Driven by the frame counter, not by time. The loop filter below hands
        # out references to one uploaded frame, and every reference carries that
        # frame's timestamp, so a time-driven expression evaluates identically
        # for the whole clip and the motion never starts. That is what "the
        # Vulkan graph does not repeat itself" was: not a broken filter, a
        # clock that never advanced.
        $linearProgress = "min(1\,($sourceStartFrame+n)/$denominator)"
        $zoomProgress = $linearProgress
        if ($item.ZoomDirection -eq 'Out') {
            $zoomExpression = "$zoomMaximumText-$zoomDeltaText*$zoomProgress"
        }
        else {
            $zoomExpression = "1+$zoomDeltaText*$zoomProgress"
        }

        # Match the CPU renderer's drift so GPU previews and final renders move
        # the same way.
        $panDirection = [string](Get-OptionalPropertyValue -Object $item -Name 'PanDirection' -DefaultValue 'None')
        $pan = Get-PanOffsetExpressions -PanDirection $panDirection -HorizontalMargin '((iw-cw)/2)' -VerticalMargin '((ih-ch)/2)'
        $cropXExpression = $pan.X
        $cropYExpression = $pan.Y
        # Normalize the still image's default 25 FPS before looping. Doing fps
        # after loop silently removed roughly one frame in every 25.
        #
        # The upload happens before the loop, not after it. Looping first meant
        # sending the same static canvas across to the graphics card 48 times a
        # second - around 600 MB/s at this canvas size - when one copy is all
        # the card ever needs. The loop filter hands out references to the
        # frame already sitting in video memory.
        $clipFrameCounts.Add($clipFrames)
        if ($useOpenClComposite) {
            # libplacebo still performs the animated crop on the selected
            # Vulkan GPU, but returns RGBA frames so the exact Screen equation
            # and optional caption alpha overlay can run on NVIDIA OpenCL.
            $filters.Add("[occsrc$itemIndex]fps=$fps,loop=loop=$($clipFrames - 1)`:size=1`:start=0,trim=end_frame=$clipFrames,setpts=N/($fps*TB),libplacebo=$gpuFastOptions`:format=rgba`:w=$Width`:h=$Height`:crop_w='iw/($zoomExpression)'`:crop_h='ih/($zoomExpression)'`:crop_x='$cropXExpression'`:crop_y='$cropYExpression',hwdownload,format=rgba,trim=end_frame=$clipFrames,setpts=PTS-STARTPTS,fps=$fps[clip$itemIndex]")
        }
        else {
            $filters.Add("[occsrc$itemIndex]fps=$fps,format=nv12,hwupload,loop=loop=$($clipFrames - 1)`:size=1`:start=0,trim=end_frame=$clipFrames,setpts=N/($fps*TB),libplacebo=$gpuFastOptions`:w=$Width`:h=$Height`:crop_w='iw/($zoomExpression)'`:crop_h='ih/($zoomExpression)'`:crop_x='$cropXExpression'`:crop_y='$cropYExpression',hwdownload,format=nv12,trim=end_frame=$clipFrames,setpts=PTS-STARTPTS,fps=$fps[clip$itemIndex]")
        }
    }

    foreach ($line in (Get-ClipSequenceFilters -ClipCount $activeItems.Count -ClipFrames $clipFrameCounts.ToArray() -FadeFrames $fadeFrames -Fps $fps -TotalFrames $processingFrames -OutputLabel 'vseq')) {
        $filters.Add($line)
    }

    if ($useOpenClComposite) {
        # FFmpeg's Vulkan blend filter only implements Normal and Multiply.
        # A tiny OpenCL kernel performs Screen directly on gamma-encoded RGBA:
        # 1 - (1 - base) * (1 - watermark). This preserves the CPU reference
        # colours while moving the per-pixel blend onto the Quadro GPU.
        $kernelFilterPath = ConvertTo-FilterPath $OpenClScreenKernelPath
        $filters.Add('[vseq]format=rgba,hwupload[vseqocl]')
        $filters.Add("[1:v]fps=$fps,scale=$Width`:$Height`:flags=bicubic,setsar=1,trim=end_frame=$processingFrames,setpts=PTS-STARTPTS,format=rgba,hwupload[watermarkocl]")

        if ([string]::IsNullOrWhiteSpace($SubtitlePath)) {
            $filters.Add("[vseqocl][watermarkocl]program_opencl=source='$kernelFilterPath':kernel=screen_rgb:inputs=2:shortest=0:repeatlast=1,hwdownload,format=rgba,format=yuv420p,trim=end_frame=$RenderFrames,setpts=N/($fps*TB)[vout]")
        }
        else {
            $subtitleFilterPath = ConvertTo-FilterPath $SubtitlePath
            $filters.Add("color=c=black@0.0:s=$Width`x$Height`:r=$fps,format=rgba,subtitles=filename='$subtitleFilterPath':alpha=1:force_style='$captionForceStyle',trim=end_frame=$processingFrames,setpts=PTS-STARTPTS,hwupload[captionocl]")
            $filters.Add("[vseqocl][watermarkocl][captionocl]program_opencl=source='$kernelFilterPath':kernel=screen_caption_rgb:inputs=3:shortest=0:repeatlast=1,hwdownload,format=rgba,format=yuv420p,trim=end_frame=$RenderFrames,setpts=N/($fps*TB)[vout]")
        }
    }
    else {
        # Preserve the photo's colour and tonal range by performing Screen mode
        # in planar RGB. This is the safe fallback when OpenCL is unavailable.
        $filters.Add('[vseq]format=gbrp[vseqrgb]')
        $filters.Add("[1:v]fps=$fps,scale=$Width`:$Height`:flags=bicubic,setsar=1,trim=end_frame=$processingFrames,setpts=PTS-STARTPTS,format=gbrp[watermarkrgb]")
        $filters.Add("[vseqrgb][watermarkrgb]blend=all_mode=screen:shortest=0:repeatlast=1,trim=end_frame=$RenderFrames,setpts=PTS-STARTPTS,format=yuv420p[composited]")

        # Only Vulkan's own encoder wants the result handed back as a hardware
        # frame. Uploading for anything else would immediately be undone by the
        # encoder pulling it straight back into system memory.
        $tail = if ($HardwareOutputFrames) { ',format=nv12,hwupload' } else { '' }
        if ([string]::IsNullOrWhiteSpace($SubtitlePath)) {
            if ($HardwareOutputFrames) { $filters.Add('[composited]format=nv12,hwupload[vout]') }
            else { $filters.Add('[composited]null[vout]') }
        }
        else {
            $subtitleFilterPath = ConvertTo-FilterPath $SubtitlePath
            $filters.Add("[composited]subtitles=filename='$subtitleFilterPath':force_style='$captionForceStyle'$tail[vout]")
        }
    }

    return [pscustomobject]@{
        ImageInputs = $uniquePaths.ToArray()
        FilterText = ($filters -join ";`r`n") + "`r`n"
        ActiveItemCount = $activeItems.Count
        RenderFrames = $RenderFrames
        DurationSeconds = $RenderFrames / [double]$fps
    }
}

function Get-EncodingArguments {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('h264_vulkan', 'h264_nvenc', 'h264_amf', 'h264_qsv', 'libx264')]
        [string]$Encoder,

        [Parameter(Mandatory = $true)]
        [ValidateSet('Compact', 'Balanced', 'High', 'YouTube')]
        [string]$Quality,

        [int]$Fps = 30
    )

    $qualitySettings = @{
        Compact = @{ Bitrate = '2000k'; MaxRate = '3200k'; Buffer = '4000k'; Cq = '27' }
        Balanced = @{ Bitrate = '4000k'; MaxRate = '6000k'; Buffer = '8000k'; Cq = '24' }
        High = @{ Bitrate = '7000k'; MaxRate = '10000k'; Buffer = '14000k'; Cq = '20' }
        YouTube = @{ Bitrate = '10000k'; MaxRate = '14000k'; Buffer = '20000k'; Cq = '18' }
    }
    $selected = $qualitySettings[$Quality]

    $arguments = [System.Collections.Generic.List[string]]::new()
    switch ($Encoder) {
        'h264_vulkan' {
            foreach ($value in @('-c:v', 'h264_vulkan', '-rc_mode', 'vbr', '-quality', '3', '-async_depth', '8', '-usage', 'transcode')) {
                $arguments.Add($value)
            }
        }
        'h264_nvenc' {
            # P4 plus spatial AQ is a better quality/speed balance for detailed
            # photographs than the old P3 low-bitrate combination.
            foreach ($value in @('-c:v', 'h264_nvenc', '-preset', 'p4', '-tune', 'hq', '-rc', 'vbr', '-cq', $selected.Cq, '-spatial_aq', '1', '-aq-strength', '8')) {
                $arguments.Add($value)
            }
        }
        'h264_amf' {
            foreach ($value in @('-c:v', 'h264_amf', '-usage', 'transcoding', '-quality', 'balanced', '-rc', 'vbr_peak')) {
                $arguments.Add($value)
            }
        }
        'h264_qsv' {
            foreach ($value in @('-c:v', 'h264_qsv', '-preset', 'medium')) {
                $arguments.Add($value)
            }
        }
        'libx264' {
            foreach ($value in @('-c:v', 'libx264', '-preset', 'medium')) {
                $arguments.Add($value)
            }
        }
    }

    foreach ($value in @(
            '-b:v', $selected.Bitrate,
            '-maxrate:v', $selected.MaxRate,
            '-bufsize:v', $selected.Buffer)) {
        $arguments.Add($value)
    }

    if ($Encoder -ne 'h264_vulkan') {
        $arguments.Add('-pix_fmt')
        $arguments.Add('yuv420p')
    }

    foreach ($value in @('-profile:v', 'high', '-level:v', '4.1')) {
        $arguments.Add($value)
    }

    foreach ($value in @('-color_range', 'tv', '-colorspace', 'bt709', '-color_primaries', 'bt709', '-color_trc', 'bt709')) {
        $arguments.Add($value)
    }
    if ($Quality -eq 'YouTube') {
        # A two-second key-frame interval, derived from the delivery rate. This
        # used to be a fixed 12 frames, taken from YouTube's "GOP of half the
        # frame rate" note, which puts a key frame on screen twice a second. On
        # a slideshow that is close to the worst possible choice: key frames ate
        # about 40 percent of the bitrate that should have gone to picture
        # detail, and playback had to decode a full 1920x1080 intra frame twice
        # a second, which stutters on laptops that manage the same file
        # comfortably at two seconds.
        $keyFrameInterval = [Math]::Max(1, $Fps * 2)
        foreach ($value in @('-bf', '2', '-g', [string]$keyFrameInterval)) {
            $arguments.Add($value)
        }
    }

    return $arguments.ToArray()
}

function Get-EstimatedOutputSizeMb {
    [CmdletBinding()]
    param(
        [double]$DurationSeconds,
        [ValidateSet('Compact', 'Balanced', 'High', 'YouTube')]
        [string]$Quality
    )

    $videoKbps = switch ($Quality) {
        'Compact' { 2000 }
        'Balanced' { 4000 }
        'High' { 7000 }
        'YouTube' { 10000 }
    }
    $audioKbps = if ($Quality -eq 'YouTube') { 384 } else { 160 }
    $totalKbps = $videoKbps + $audioKbps
    return [Math]::Round(($totalKbps * $DurationSeconds) / 8000.0, 0)
}

Export-ModuleMember -Function @(
    'Get-SupportedImageFiles',
    'Get-MediaDurationSeconds',
    'New-TimelinePlan',
    'New-TimelineSlice',
    'New-FilterGraph',
    'New-VulkanFilterGraph',
    'Format-CaptionText',
    'Copy-SrtWithWordWrapping',
    'Get-EncodingArguments',
    'Get-EstimatedOutputSizeMb'
)
