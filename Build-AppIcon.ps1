<#
.SYNOPSIS
    Builds the application icon from the CreatorFlow logo artwork.

.DESCRIPTION
    Takes the full logo (mark plus wordmark on paper) and produces the two
    assets the application needs:

      Assets\CreatorFlow.png  the mark alone, transparent, 256 px
      Assets\CreatorFlow.ico  the same at every size Windows asks for

    Only the mark is used. A wordmark is unreadable at 16 px, which is the size
    that actually decides whether someone can find the window in their taskbar.

    The paper behind the logo is removed by flooding inwards from the edges
    rather than by making every pale pixel transparent, because the play
    triangle in the middle of the mark is white too and a plain threshold
    punches a hole straight through it.

    Re-run this only when the artwork changes; the built assets are committed.

.PARAMETER SourcePath
    The logo artwork. Defaults to the copy kept beside this script.
#>
[CmdletBinding()]
param(
    [string]$SourcePath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = Split-Path -Parent $MyInvocation.MyCommand.Path
$assets = Join-Path $root 'Assets'
if ([string]::IsNullOrWhiteSpace($SourcePath)) { $SourcePath = Join-Path $assets 'creatorflow-logo.png' }
if (-not (Test-Path -LiteralPath $SourcePath -PathType Leaf)) {
    throw "The logo artwork was not found at $SourcePath."
}
New-Item -ItemType Directory -Path $assets -Force | Out-Null

$source = [Drawing.Bitmap]::FromFile($SourcePath)
try {
    # --- Locate the mark ---------------------------------------------------
    # It sits alone in the left third of the artwork, so measuring the ink in
    # that band finds it without hard-coded coordinates.
    $band = [int]($source.Width * 0.36)
    $minX = $source.Width; $minY = $source.Height; $maxX = 0; $maxY = 0
    for ($y = 0; $y -lt $source.Height; $y++) {
        for ($x = 0; $x -lt $band; $x++) {
            $pixel = $source.GetPixel($x, $y)
            if (($pixel.R + $pixel.G + $pixel.B) -lt 690) {
                if ($x -lt $minX) { $minX = $x }
                if ($x -gt $maxX) { $maxX = $x }
                if ($y -lt $minY) { $minY = $y }
                if ($y -gt $maxY) { $maxY = $y }
            }
        }
    }
    if ($maxX -le $minX -or $maxY -le $minY) { throw 'No mark was found in the left third of the artwork.' }

    # --- Crop to a square with a little air --------------------------------
    $markWidth = $maxX - $minX + 1
    $markHeight = $maxY - $minY + 1
    $side = [int]([Math]::Max($markWidth, $markHeight) * 1.14)
    $centreX = $minX + [int]($markWidth / 2)
    $centreY = $minY + [int]($markHeight / 2)

    $square = [Drawing.Bitmap]::new($side, $side, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($square)
    $graphics.Clear([Drawing.Color]::White)
    $graphics.DrawImage($source, [int](($side - $markWidth) / 2) - 0, [int](($side - $markHeight) / 2),
        [Drawing.Rectangle]::new($minX, $minY, $markWidth, $markHeight), [Drawing.GraphicsUnit]::Pixel)
    $graphics.Dispose()

    # --- Resample to 256 ---------------------------------------------------
    $master = [Drawing.Bitmap]::new(256, 256, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [Drawing.Graphics]::FromImage($master)
    $graphics.Clear([Drawing.Color]::White)
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.DrawImage($square, [Drawing.Rectangle]::new(0, 0, 256, 256))
    $graphics.Dispose()
    $square.Dispose()

    # --- Remove the paper --------------------------------------------------
    # Flooded from the border so enclosed white - the play triangle - survives.
    $width = $master.Width; $height = $master.Height
    $data = $master.LockBits([Drawing.Rectangle]::new(0, 0, $width, $height),
        [Drawing.Imaging.ImageLockMode]::ReadWrite, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bytes = [byte[]]::new($data.Stride * $height)
    [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $bytes.Length)

    $isPaper = {
        param($index)
        # BGRA order. Paper is pale and close to neutral.
        $b = $bytes[$index]; $g = $bytes[$index + 1]; $r = $bytes[$index + 2]
        $max = [Math]::Max($r, [Math]::Max($g, $b))
        $min = [Math]::Min($r, [Math]::Min($g, $b))
        return ($min -gt 218 -and ($max - $min) -lt 16)
    }

    $visited = [bool[]]::new($width * $height)
    $queue = [Collections.Generic.Queue[int]]::new()
    # The parentheses matter: a comma binds tighter than a minus in PowerShell,
    # so @(0, $height - 1) would subtract one from the whole array.
    for ($x = 0; $x -lt $width; $x++) {
        foreach ($y in @(0, ($height - 1))) { $queue.Enqueue($y * $width + $x) }
    }
    for ($y = 0; $y -lt $height; $y++) {
        foreach ($x in @(0, ($width - 1))) { $queue.Enqueue($y * $width + $x) }
    }

    $cleared = 0
    while ($queue.Count -gt 0) {
        $cell = $queue.Dequeue()
        if ($visited[$cell]) { continue }
        $visited[$cell] = $true
        $index = $cell * 4
        if (-not (& $isPaper $index)) { continue }
        $bytes[$index + 3] = 0
        $cleared++
        $cx = $cell % $width; $cy = [int]($cell / $width)
        if ($cx -gt 0) { $queue.Enqueue($cell - 1) }
        if ($cx -lt $width - 1) { $queue.Enqueue($cell + 1) }
        if ($cy -gt 0) { $queue.Enqueue($cell - $width) }
        if ($cy -lt $height - 1) { $queue.Enqueue($cell + $width) }
    }

    [Runtime.InteropServices.Marshal]::Copy($bytes, 0, $data.Scan0, $bytes.Length)
    $master.UnlockBits($data)
    Write-Host "Cleared $cleared background pixels." -ForegroundColor DarkGray

    $pngPath = Join-Path $assets 'CreatorFlow.png'
    $master.Save($pngPath, [Drawing.Imaging.ImageFormat]::Png)
    Write-Host "Wrote $pngPath" -ForegroundColor DarkGray

    # --- Assemble the .ico -------------------------------------------------
    # Every entry is a PNG. Windows has read PNG-compressed icon entries since
    # Vista, and it keeps this readable next to a hand-built BMP with its
    # separate transparency mask.
    $sizes = @(16, 24, 32, 48, 64, 128, 256)
    $frames = [Collections.Generic.List[byte[]]]::new()
    foreach ($size in $sizes) {
        $scaled = [Drawing.Bitmap]::new($size, $size, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $graphics = [Drawing.Graphics]::FromImage($scaled)
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::HighQuality
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.DrawImage($master, [Drawing.Rectangle]::new(0, 0, $size, $size))
        $graphics.Dispose()
        $stream = [IO.MemoryStream]::new()
        $scaled.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
        $frames.Add($stream.ToArray())
        $stream.Dispose(); $scaled.Dispose()
    }

    $icoPath = Join-Path $assets 'CreatorFlow.ico'
    $output = [IO.File]::Create($icoPath)
    try {
        $writer = [IO.BinaryWriter]::new($output)
        $writer.Write([uint16]0)               # reserved
        $writer.Write([uint16]1)               # type: icon
        $writer.Write([uint16]$sizes.Count)
        $offset = 6 + (16 * $sizes.Count)
        for ($index = 0; $index -lt $sizes.Count; $index++) {
            $size = $sizes[$index]
            # 0 means 256 in the directory entry, which is why it is a byte.
            $writer.Write([byte]($(if ($size -ge 256) { 0 } else { $size })))
            $writer.Write([byte]($(if ($size -ge 256) { 0 } else { $size })))
            $writer.Write([byte]0)             # palette size
            $writer.Write([byte]0)             # reserved
            $writer.Write([uint16]1)           # colour planes
            $writer.Write([uint16]32)          # bits per pixel
            $writer.Write([uint32]$frames[$index].Length)
            $writer.Write([uint32]$offset)
            $offset += $frames[$index].Length
        }
        foreach ($frame in $frames) { $writer.Write($frame) }
        $writer.Flush()
    }
    finally { $output.Dispose() }

    Write-Host "Wrote $icoPath ($('{0:N0}' -f (Get-Item $icoPath).Length) bytes, $($sizes.Count) sizes)" -ForegroundColor Green
    $master.Dispose()
}
finally { $source.Dispose() }
