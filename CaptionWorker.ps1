[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$JobPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$job = [IO.File]::ReadAllText($JobPath, [Text.Encoding]::UTF8) | ConvertFrom-Json
$progressPath = [string]$job.ProgressPath
$errorPath = [string]$job.ErrorPath
if (Test-Path -LiteralPath $errorPath -PathType Leaf) { Remove-Item -LiteralPath $errorPath -Force }

function Write-CaptionProgress {
    param([string]$Phase, [double]$Percent, [string]$Message)
    $text = "phase=$Phase`r`npercent=$([Math]::Max(0, [Math]::Min(100, $Percent)).ToString('0.0', [Globalization.CultureInfo]::InvariantCulture))`r`nmessage=$Message`r`n"
    [IO.File]::WriteAllText($progressPath, $text, [Text.UTF8Encoding]::new($false))
}

function Quote-CaptionArgument {
    param([AllowEmptyString()][string]$Value)
    if ($Value.Length -gt 0 -and $Value -notmatch '[\s"]') { return $Value }
    $builder = [Text.StringBuilder]::new()
    [void]$builder.Append('"')
    $slashes = 0
    foreach ($character in $Value.ToCharArray()) {
        if ($character -eq '\') { $slashes++; continue }
        if ($character -eq '"') {
            [void]$builder.Append(('\' * (($slashes * 2) + 1)))
            [void]$builder.Append('"')
            $slashes = 0
            continue
        }
        if ($slashes -gt 0) { [void]$builder.Append(('\' * $slashes)); $slashes = 0 }
        [void]$builder.Append($character)
    }
    if ($slashes -gt 0) { [void]$builder.Append(('\' * ($slashes * 2))) }
    [void]$builder.Append('"')
    return $builder.ToString()
}

function Receive-FileWithProgress {
    param([string]$Uri, [string]$Destination, [string]$Label, [double]$StartPercent, [double]$EndPercent)
    Add-Type -AssemblyName System.Net.Http
    $temporary = "$Destination.download"
    $client = [Net.Http.HttpClient]::new()
    $request = $null
    $response = $null
    $input = $null
    $output = $null
    try {
        [long]$existingLength = 0
        if (Test-Path -LiteralPath $temporary -PathType Leaf) {
            $existingLength = (Get-Item -LiteralPath $temporary).Length
        }
        $request = [Net.Http.HttpRequestMessage]::new([Net.Http.HttpMethod]::Get, $Uri)
        if ($existingLength -gt 0) {
            $request.Headers.Range = [Net.Http.Headers.RangeHeaderValue]::new($existingLength, $null)
        }
        $response = $client.SendAsync($request, [Net.Http.HttpCompletionOption]::ResponseHeadersRead).Result
        [void]$response.EnsureSuccessStatusCode()
        $isPartial = ([int]$response.StatusCode -eq 206)
        if ($existingLength -gt 0 -and -not $isPartial) {
            $existingLength = 0
        }
        $responseLength = $response.Content.Headers.ContentLength
        $total = if ($responseLength) { $existingLength + $responseLength } else { $null }
        $input = $response.Content.ReadAsStreamAsync().Result
        $mode = if ($isPartial -and $existingLength -gt 0) { [IO.FileMode]::Append } else { [IO.FileMode]::Create }
        $output = [IO.File]::Open($temporary, $mode, [IO.FileAccess]::Write, [IO.FileShare]::Read)
        $buffer = New-Object byte[] (1024 * 1024)
        [long]$received = $existingLength
        [long]$lastFlush = $received
        while (($read = $input.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $output.Write($buffer, 0, $read)
            $received += $read
            if (($received - $lastFlush) -ge 8MB) {
                $output.Flush()
                $lastFlush = $received
            }
            $fraction = if ($total -and $total -gt 0) { $received / [double]$total } else { 0.0 }
            $percent = $StartPercent + (($EndPercent - $StartPercent) * $fraction)
            $receivedMb = [Math]::Round($received / 1MB, 0)
            $totalMb = if ($total) { [Math]::Round($total / 1MB, 0) } else { '?' }
            Write-CaptionProgress 'download' $percent "${Label}: $receivedMb of $totalMb MB"
        }
        $output.Flush()
        $output.Dispose(); $output = $null
        Move-Item -LiteralPath $temporary -Destination $Destination -Force
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $input) { $input.Dispose() }
        if ($null -ne $response) { $response.Dispose() }
        if ($null -ne $request) { $request.Dispose() }
        $client.Dispose()
    }
}

function Ensure-CaptionEngine {
    $engineRoot = [string]$job.EngineRoot
    $versionRoot = Join-Path $engineRoot 'v1.9.2'
    $existingCandidates = @(
        (Join-Path $engineRoot 'Release\whisper-cli.exe'),
        (Join-Path $versionRoot 'Release\whisper-cli.exe'),
        (Join-Path $versionRoot 'whisper-cli.exe')
    )
    foreach ($candidate in $existingCandidates) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    New-Item -ItemType Directory -Path $engineRoot -Force | Out-Null
    $archivePath = Join-Path $engineRoot 'whisper-blas-bin-x64-v1.9.2.zip'
    Receive-FileWithProgress `
        -Uri 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.2/whisper-blas-bin-x64.zip' `
        -Destination $archivePath -Label 'Downloading caption engine' -StartPercent 0 -EndPercent 8

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $versionRoot -PathType Container) {
        [IO.Directory]::Delete($versionRoot, $true)
    }
    [IO.Compression.ZipFile]::ExtractToDirectory($archivePath, $versionRoot)
    foreach ($candidate in @((Join-Path $versionRoot 'Release\whisper-cli.exe'), (Join-Path $versionRoot 'whisper-cli.exe'))) {
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    throw 'The caption-engine package did not contain whisper-cli.exe.'
}

function Ensure-CaptionModels {
    $modelsRoot = Join-Path ([string]$job.EngineRoot) 'models'
    New-Item -ItemType Directory -Path $modelsRoot -Force | Out-Null
    $modelPath = Join-Path $modelsRoot 'ggml-small.bin'
    $vadPath = Join-Path $modelsRoot 'ggml-silero-v6.2.0.bin'
    if (-not (Test-Path -LiteralPath $modelPath -PathType Leaf)) {
        Receive-FileWithProgress `
            -Uri 'https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-small.bin' `
            -Destination $modelPath -Label 'Downloading speech model (one time)' -StartPercent 8 -EndPercent 40
    }
    if (-not (Test-Path -LiteralPath $vadPath -PathType Leaf)) {
        Receive-FileWithProgress `
            -Uri 'https://huggingface.co/ggml-org/whisper-vad/resolve/main/ggml-silero-v6.2.0.bin' `
            -Destination $vadPath -Label 'Downloading voice detector' -StartPercent 40 -EndPercent 41
    }
    return [pscustomobject]@{ ModelPath = $modelPath; VadPath = $vadPath }
}

try {
    Write-CaptionProgress 'setup' 0 'Preparing offline caption engine...'
    $whisperPath = Ensure-CaptionEngine
    $models = Ensure-CaptionModels

    $workDirectory = Split-Path -Parent $JobPath
    $wavPath = Join-Path $workDirectory 'voiceover-16khz.wav'
    $prefixPath = Join-Path $workDirectory 'automatic-captions'
    Write-CaptionProgress 'audio' 42 'Preparing voiceover for transcription...'
    & ([string]$job.FfmpegPath) -y -hide_banner -loglevel error -i ([string]$job.AudioPath) -ar 16000 -ac 1 -c:a pcm_s16le $wavPath
    if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $wavPath -PathType Leaf)) {
        throw 'FFmpeg could not prepare the voiceover for transcription.'
    }

    Write-CaptionProgress 'transcribe' 45 'Transcribing voiceover locally. This may take several minutes...'
    $arguments = @(
        '--model', [string]$models.ModelPath,
        '--file', $wavPath,
        '--language', 'auto',
        '--threads', [string][Math]::Max(4, [Environment]::ProcessorCount - 2),
        '--processors', '1',
        '--output-srt',
        '--output-file', $prefixPath,
        '--split-on-word',
        '--max-len', '80',
        '--vad',
        '--vad-model', [string]$models.VadPath,
        '--print-progress'
    )
    $logPath = Join-Path $workDirectory 'whisper.log'
    $errorLogPath = Join-Path $workDirectory 'whisper-error.log'
    $argumentLine = (($arguments | ForEach-Object { Quote-CaptionArgument ([string]$_) }) -join ' ')
    $process = Start-Process -FilePath $whisperPath -ArgumentList $argumentLine -PassThru -WindowStyle Hidden -RedirectStandardOutput $logPath -RedirectStandardError $errorLogPath
    $null = $process.Handle
    while (-not $process.HasExited) {
        $whisperPercent = 0.0
        if (Test-Path -LiteralPath $errorLogPath -PathType Leaf) {
            $progressText = Get-Content -LiteralPath $errorLogPath -Raw -ErrorAction SilentlyContinue
            if ($null -ne $progressText) {
                $matches = [regex]::Matches($progressText, '(?i)progress\s*=\s*(\d+)%')
                if ($matches.Count -gt 0) { $whisperPercent = [double]$matches[$matches.Count - 1].Groups[1].Value }
            }
        }
        Write-CaptionProgress 'transcribe' (45.0 + ($whisperPercent * 0.54)) "Transcribing voiceover locally: $([Math]::Floor($whisperPercent))%"
        Start-Sleep -Milliseconds 500
        $process.Refresh()
    }
    $process.WaitForExit(); $process.Refresh()
    if ($process.ExitCode -ne 0) {
        throw "The offline transcription engine exited with code $($process.ExitCode)."
    }

    $generatedSrt = "$prefixPath.srt"
    if (-not (Test-Path -LiteralPath $generatedSrt -PathType Leaf)) {
        throw 'The transcription engine did not create an SRT file.'
    }
    $destinationDirectory = Split-Path -Parent ([string]$job.OutputSrt)
    New-Item -ItemType Directory -Path $destinationDirectory -Force | Out-Null
    $captionText = [IO.File]::ReadAllText($generatedSrt)
    [IO.File]::WriteAllText([string]$job.OutputSrt, $captionText, [Text.UTF8Encoding]::new($false))
    if (Test-Path -LiteralPath $wavPath -PathType Leaf) { Remove-Item -LiteralPath $wavPath -Force }
    Write-CaptionProgress 'complete' 100 'Automatic captions are ready.'
    exit 0
}
catch {
    $details = $_.Exception.ToString()
    [IO.File]::WriteAllText($errorPath, $details, [Text.UTF8Encoding]::new($false))
    Write-CaptionProgress 'failed' 100 $_.Exception.Message
    exit 1
}
