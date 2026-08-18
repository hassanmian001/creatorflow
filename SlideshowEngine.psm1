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
        [int]$Fps = 24,
        [Nullable[int]]$Seed,
        [ValidateSet('Cinematic In', 'Cinematic Out', 'Balanced', 'Slow Drift', 'Dynamic')]
        [string]$MotionPreset = 'Balanced'
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

    $preset = Get-MotionPreset -PresetName $MotionPreset
    $items = [System.Collections.Generic.List[object]]::new()
    for ($index = 0; $index -lt $occurrenceCount; $index++) {
        $imageIndex = $imageIndices[$index]
        $duration = $durations[$index]
        $items.Add([pscustomobject]@{
            ImagePath = $ImagePaths[$imageIndex]
            ImageName = [IO.Path]::GetFileName($ImagePaths[$imageIndex])
            Frames = [int]$duration.Frames
            DurationTenths = [int]$duration.Tenths
            ZoomDirection = Get-WeightedRandomChoice -Weights $preset.ZoomWeights -Random $random
            PanDirection = Get-WeightedRandomChoice -Weights $preset.PanWeights -Random $random
            MotionPreset = $MotionPreset
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
        MotionPreset = $MotionPreset
        Items = $items.ToArray()
    }
}

function Get-AllMotionPresets {
    $presetNames = @('Cinematic In', 'Cinematic Out', 'Balanced', 'Slow Drift', 'Dynamic')
    $presets = @()
    foreach ($name in $presetNames) {
        $preset = Get-MotionPreset -PresetName $name
        $presets += [pscustomobject]@{
            Name = $preset.Name
            Description = $preset.Description
        }
    }
    return $presets
}

function Get-RandomMotionPreset {
    param([System.Random]$Random)
    $presetNames = @('Cinematic In', 'Cinematic Out', 'Balanced', 'Slow Drift', 'Dynamic')
    return $presetNames[$Random.Next(0, $presetNames.Count)]
}

function Get-MotionPreset {
    [CmdletBinding()]
    param(
        [ValidateSet('Cinematic In', 'Cinematic Out', 'Balanced', 'Slow Drift', 'Dynamic')]
        [string]$PresetName = 'Balanced'
    )

    $presets = @{
        'Cinematic In' = @{
            Name = 'Cinematic In'
            Description = 'Intense zoom-in with varied pans - engaging and revealing'
            ZoomWeights = @{ 'In' = 0.8; 'Out' = 0.2 }
            PanWeights = @{ 'Left' = 0.25; 'Right' = 0.25; 'Up' = 0.25; 'Down' = 0.25 }
        }
        'Cinematic Out' = @{
            Name = 'Cinematic Out'
            Description = 'Zoom-out effect with varied pans - revealing wide shots'
            ZoomWeights = @{ 'In' = 0.2; 'Out' = 0.8 }
            PanWeights = @{ 'Left' = 0.25; 'Right' = 0.25; 'Up' = 0.25; 'Down' = 0.25 }
        }
        'Balanced' = @{
            Name = 'Balanced'
            Description = 'Mixed zoom with random pans - naturally varied'
            ZoomWeights = @{ 'In' = 0.5; 'Out' = 0.5 }
            PanWeights = @{ 'Left' = 0.25; 'Right' = 0.25; 'Up' = 0.25; 'Down' = 0.25 }
        }
        'Slow Drift' = @{
            Name = 'Slow Drift'
            Description = 'Gentle motion - calm, documentary-style'
            ZoomWeights = @{ 'In' = 0.4; 'Out' = 0.6 }
            PanWeights = @{ 'Left' = 0.35; 'Right' = 0.35; 'Up' = 0.15; 'Down' = 0.15 }
        }
        'Dynamic' = @{
            Name = 'Dynamic'
            Description = 'Fast, aggressive zoom-in with directional pans - energetic'
            ZoomWeights = @{ 'In' = 0.85; 'Out' = 0.15 }
            PanWeights = @{ 'Left' = 0.3; 'Right' = 0.3; 'Up' = 0.2; 'Down' = 0.2 }
        }
    }

    return $presets[$PresetName]
}

function Get-WeightedRandomChoice {
    param(
        [hashtable]$Weights,
        [System.Random]$Random
    )

    $choices = @()
    $values = @()
    foreach ($key in $Weights.Keys) {
        $choices += $key
        $values += $Weights[$key]
    }

    $totalWeight = ($values | Measure-Object -Sum).Sum
    $randomValue = $Random.NextDouble() * $totalWeight
    $currentSum = 0

    for ($i = 0; $i -lt $choices.Count; $i++) {
        $currentSum += $values[$i]
        if ($randomValue -le $currentSum) {
            return $choices[$i]
        }
    }

    return $choices[-1]
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
        [int]$Width = 1920,
        [int]$Height = 1080,

        # Shutter motion blur: generate the camera move at twice the delivery
        # frame rate and blend three of those frames into each delivered one.
        # Measured at roughly 2.3x the cost of the whole rest of the graph, so
        # it is the one quality feature worth offering as a choice.
        [bool]$MotionBlur = $true
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

    $fps = [int]$Timeline.Fps
    # Generate camera motion at twice the delivery frame rate. The final
    # per-clip temporal blend supplies the natural exposure blur that a real
    # camera would have and then returns the stream to the requested FPS.
    # With motion blur off there is nothing to blend, so generating those
    # extra frames would only be to throw them away again.
    $motionFactor = if ($MotionBlur) { 2 } else { 1 }
    $motionFps = $fps * $motionFactor
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
    # zoompan evaluates crop coordinates as whole input pixels.  At only 1.25x
    # overscan a slow zoom repeatedly holds and then jumps a pixel, which looks
    # like camera shake.  A 2x working canvas makes those steps sub-pixel at the
    # final resolution and produces visibly steadier motion.
    $workingScale = [Math]::Max(2.0, $zoomMaximum)
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

    for ($itemIndex = 0; $itemIndex -lt $activeItems.Count; $itemIndex++) {
        $item = $activeItems[$itemIndex]
        $frames = [int]$item.Frames
        $motionFrames = $frames * $motionFactor
        $sourceFrames = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceFrames' -DefaultValue $frames)
        $sourceStartFrame = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceStartFrame' -DefaultValue 0)
        $motionSourceStartFrame = $sourceStartFrame * $motionFactor
        $denominator = [Math]::Max(1, ($sourceFrames * $motionFactor) - 1)
        # Constant velocity for the full clip. A cosine ease-in-out was tried
        # here, but easing all the way to zero velocity at both ends made
        # every clip visibly decelerate before the cut, and the near-zero
        # per-frame motion in that window tends to hit zoompan's whole-pixel
        # crop rounding (see workingScale below), which reads as camera shake.
        $linearProgress = "min(1\,(on+$motionSourceStartFrame)/$denominator)"
        $zoomProgress = $linearProgress
        if ($item.ZoomDirection -eq 'Out') {
            $zoomExpression = "$zoomMaximumText-$zoomDeltaText*$zoomProgress"
        }
        else {
            $zoomExpression = "1+$zoomDeltaText*$zoomProgress"
        }

        # Drift slowly across one axis while zooming. The offset moves at a
        # constant rate for the same reason the zoom does, so it never
        # decelerates into zoompan's whole-pixel crop rounding.
        $panDirection = [string](Get-OptionalPropertyValue -Object $item -Name 'PanDirection' -DefaultValue 'None')
        $pan = Get-PanOffsetExpressions -PanDirection $panDirection -HorizontalMargin '((iw-iw/zoom)/2)' -VerticalMargin '((ih-ih/zoom)/2)'
        $xExpression = $pan.X
        $yExpression = $pan.Y

        $motionBlurStage = if ($MotionBlur) { ",tmix=frames=3:weights='1 2 1',fps=$fps" } else { '' }
        $filters.Add("[occsrc$itemIndex]zoompan=z='$zoomExpression':x='$xExpression':y='$yExpression':d=$motionFrames`:s=$Width`x$Height`:fps=$motionFps,setsar=1$motionBlurStage,trim=end_frame=$frames,setpts=PTS-STARTPTS[clip$itemIndex]")
    }

    $clipLabels = (0..($activeItems.Count - 1) | ForEach-Object { "[clip$_]" }) -join ''
    $filters.Add("$clipLabels`concat=n=$($activeItems.Count)`:v=1`:a=0,trim=end_frame=$RenderFrames,setpts=PTS-STARTPTS[vseq]")
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
        [int]$Width = 1920,
        [int]$Height = 1080,

        # Vulkan's own H.264 encoder needs the finished frames left on the GPU.
        # Every other encoder - NVENC, AMF, Quick Sync, libx264 - wants ordinary
        # frames in system memory, and passing $false ends the graph there so
        # this filter path can be used with any of them.
        [bool]$HardwareOutputFrames = $true,

        # Matches New-FilterGraph so the two backends stay visually identical.
        [bool]$MotionBlur = $true
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

    $fps = [int]$Timeline.Fps
    $motionFactor = if ($MotionBlur) { 2 } else { 1 }
    $motionFps = $fps * $motionFactor
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
    # This deliberately stays well below the CPU renderer's 2x canvas. That
    # one is oversized to keep zoompan's whole-pixel crop from stepping, and
    # libplacebo crops on real numbers so it has no such problem. Matching the
    # 2x canvas was measured at roughly 25 percent slower than this, and it
    # exhausted the memory of an integrated GPU outright.
    $workingScale = [Math]::Max(1.25, $zoomMaximum)
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

    for ($itemIndex = 0; $itemIndex -lt $activeItems.Count; $itemIndex++) {
        $item = $activeItems[$itemIndex]
        $frames = [int]$item.Frames
        $clipFrames = if ($itemIndex -eq ($activeItems.Count - 1)) { $frames + $pipelineTailFrames } else { $frames }
        $motionClipFrames = $clipFrames * $motionFactor
        $sourceFrames = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceFrames' -DefaultValue $frames)
        $sourceStartFrame = [int](Get-OptionalPropertyValue -Object $item -Name 'SourceStartFrame' -DefaultValue 0)
        $motionSourceStartFrame = $sourceStartFrame * $motionFactor
        $denominator = [Math]::Max(1, ($sourceFrames * $motionFactor) - 1)
        # Match the CPU renderer's constant-velocity zoom so GPU previews and
        # final renders look the same.
        $linearProgress = "min(1\,($motionSourceStartFrame+t*$motionFps)/$denominator)"
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
        $motionBlurStage = if ($MotionBlur) { ",tmix=frames=3:weights='1 2 1',fps=$fps" } else { '' }
        if ($useOpenClComposite) {
            # libplacebo still performs the animated crop on the selected
            # Vulkan GPU, but returns RGBA frames so the exact Screen equation
            # and optional caption alpha overlay can run on NVIDIA OpenCL.
            $filters.Add("[occsrc$itemIndex]fps=$motionFps,loop=loop=$($motionClipFrames - 1)`:size=1`:start=0,trim=end_frame=$motionClipFrames,setpts=PTS-STARTPTS,libplacebo=$gpuFastOptions`:format=rgba`:w=$Width`:h=$Height`:crop_w='iw/($zoomExpression)'`:crop_h='ih/($zoomExpression)'`:crop_x='$cropXExpression'`:crop_y='$cropYExpression',hwdownload,format=rgba$motionBlurStage,trim=end_frame=$clipFrames,setpts=PTS-STARTPTS[clip$itemIndex]")
        }
        else {
            $filters.Add("[occsrc$itemIndex]fps=$motionFps,format=nv12,hwupload,loop=loop=$($motionClipFrames - 1)`:size=1`:start=0,trim=end_frame=$motionClipFrames,setpts=PTS-STARTPTS,libplacebo=$gpuFastOptions`:w=$Width`:h=$Height`:crop_w='iw/($zoomExpression)'`:crop_h='ih/($zoomExpression)'`:crop_x='$cropXExpression'`:crop_y='$cropYExpression',hwdownload,format=nv12$motionBlurStage,trim=end_frame=$clipFrames,setpts=PTS-STARTPTS[clip$itemIndex]")
        }
    }

    $clipLabels = (0..($activeItems.Count - 1) | ForEach-Object { "[clip$_]" }) -join ''
    $filters.Add("$clipLabels`concat=n=$($activeItems.Count)`:v=1`:a=0,trim=end_frame=$processingFrames,setpts=PTS-STARTPTS[vseq]")

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
        [string]$Quality
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
        # A two-second key-frame interval (48 frames at 24 FPS). This used to be
        # 12, taken from YouTube's "GOP of half the frame rate" note, which puts
        # a key frame on screen twice a second. On a slideshow that is close to
        # the worst possible choice: key frames ate about 40 percent of the
        # bitrate that should have gone to picture detail, and playback had to
        # decode a full 1920x1080 intra frame twice a second, which stutters on
        # laptops that manage the same file comfortably at two seconds.
        foreach ($value in @('-bf', '2', '-g', '48')) {
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
