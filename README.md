# Slideshow Video Tool

A portable Windows 11 tool for turning a folder of images and an M4A voiceover into a 1920x1080, 24 FPS YouTube video.

## What it does

- Randomly shuffles the selected images, then reshuffles each repeated cycle.
- Prevents adjacent duplicate images.
- Assigns exact randomized timings within the selected 0.1-second duration range.
- Ends the video with the voiceover.
- Normalises the finished audio to -14 LUFS, the level YouTube plays back at. YouTube
  only turns loud uploads down and never raises a quiet one, so an unnormalised video
  sounds quieter than everything beside it. The final render measures the whole
  voiceover first and then applies one constant gain, which avoids the audible
  breathing a single adaptive pass produces on speech.
- Keeps each complete foreground image visible over a darkened, blurred full-frame copy.
- Randomly applies zoom-in or zoom-out motion, combined with a slow pan drift in a
  random direction. Both move at a constant rate for the whole image, so the
  motion never decelerates into a visible stutter before the next cut.
- Offers **Cinematic motion blur** under Motion, on by default. It generates the
  camera move at 48 FPS and blends three of those frames into each delivered
  one, which is the shutter blur a real camera produces. Measured on a 20-second
  render, it costs 2.3x the time of everything else in the graph combined, so
  turning it off is by far the largest speed control the tool has.
- Applies the supplied full-frame MOV/MP4 watermark with Screen blending for the entire video.
- Creates automatic SRT captions locally from the voiceover; captions can also be burned into the video.
- Groups settings into five sections — Media and Audio, Motion, Captions, Blanking Fill
  and Export — and shows one at a time. The left rail switches between them, so no
  setting is buried below a scroll or folded inside a collapsed panel.
- Includes a live caption editor for correcting text and timestamps, search-and-replace, adding/removing/splitting/merging rows, and previewing a selected caption.
- Updates caption text and styling over the embedded player instantly, without regenerating the video preview. Captions can be dragged to reposition and resized with the cyan corner handle or mouse wheel.
- Provides complete global caption controls for font, size, bold, text/outline/background colors, outline, shadow, box opacity, alignment, X/Y position, maximum width, words per line, and line height.
- Generates a required 60-second 1080p preview with an embedded player.
- Uses the exact previewed timeline, so the final video matches what was approved.
  The rendered preview file itself is only dropped straight into the final video
  when a render segment happens to be exactly as long as the preview; otherwise
  that stretch is re-rendered, because cutting an encoded clip to a shorter
  segment cannot be done accurately without re-encoding it anyway.
- Renders the final video in resumable 30-second segments, three at a time.
- Batch-renders multiple saved project files sequentially.
- Keeps persistent render history with completed, failed, paused, and resumable final and batch jobs.
- Uses the Quadro P620 through compatible NVIDIA NVENC for H.264 encoding.
- Uses a custom OpenCL compositor for colour-correct RGB Screen blending so the watermark does not crush shadows or posterize photos.
- Composites burned captions on the GPU, or skips that work when **SRT only** is selected.
- Supports **Burned only** output when captions should be embedded without creating a separate SRT file.
- Includes ten reference-matched caption presets covering bold outlined YouTube,
  newsroom, minimal, boxed, colored, documentary, upper-safe, and compact styles.
- Automatically falls back to NVIDIA Vulkan, Intel Quick Sync, and finally CPU encoding.
- Saves and reopens projects, including the generated timeline.

## One-time setup

No separate FFmpeg installation is required. The tool includes a compatible
FFmpeg 7.1.1 portable runtime for the Quadro P620. Keep the `Tools` and
`Shaders` folders beside the scripts.

## Start the tool

Double-click **Start Tool.bat**.

The folder is portable. Keep these files and folders together:

- `Start Tool.bat`
- `SlideshowVideoTool.ps1`
- `SlideshowEngine.psm1`
- `SlideshowAnalysis.psm1`
- `CaptionWorker.ps1`
- `SlideshowRenderWorker.ps1`
- `SlideshowBatchWorker.ps1`
- `Shaders`
- `Tools\FFmpeg-7.1.1`

## Workflow

1. Select a folder containing JPG, JPEG, PNG, or WEBP images. Only files directly inside that folder are used.
2. Select the M4A voiceover.
3. Select the full-frame MOV or MP4 animated watermark.
4. Choose the final MP4 filename using **Save As**.
5. Adjust image timing, zoom, captions, blur, brightness, and quality if needed. Use the
   left rail to move between the five settings sections.
6. Click **Generate 60s Preview**.
7. Review the preview in the built-in player.
8. Click **Render / Resume Final**.

The first caption run downloads an offline multilingual speech model (about 465 MB). Interrupted downloads resume, and the model and generated captions are cached for later runs.

After captions are generated, use **Edit Captions** to correct the SRT before rendering. The editor remains open beside the main player, so text and timestamp edits can be checked while seeking or playing. Caption changes never require regenerating the 60-second preview; a burned-caption final export applies the current style and SRT during rendering.

For batch work, click **Batch Projects**. Add any number of videos, selecting an images folder, M4A voiceover, and MP4 output for each one. Choose the shared watermark, then click **Render All**; the tool builds the projects and renders them one at a time so the laptop is not overloaded. Motion and caption settings from the main window are applied to every queued video. The same window also retains **Render Saved Projects** for existing `.svp.json` projects.

Use **Render History** from the left navigation to inspect jobs, open outputs, remove history entries, or resume a paused final/batch render. Jobs that were active when the application closed are marked Paused on the next launch.

If a setting that affects the video changes, the final-render button is disabled until a new preview is generated.

## Quality modes

| Mode | Approximate video bitrate | Intended use |
|---|---:|---|
| Compact | 2,000 kbps | Small files with improved 1080p detail |
| Balanced | 4,000 kbps | Cleaner photographs at a moderate size |
| High | 7,000 kbps | High-quality local master |
| YouTube | 10,000 kbps | Recommended upload master with YouTube-friendly GOP settings |

All modes use H.264 video in an MP4 container. YouTube mode uses 384 kbps AAC stereo audio; the other modes use 160 kbps.

YouTube mode places a key frame every two seconds. It previously used YouTube's
"GOP of half the frame rate" note, which puts one on screen twice a second; on
slideshow content that spent roughly 60 percent of the bitrate on key frames
instead of picture detail, produced a much larger file for no visible gain, and
forced playback to decode a full 1920x1080 intra frame twice a second, which
stutters on modest laptops.

The renderer prepares each source photograph directly at the zoom working
resolution with Lanczos scaling instead of enlarging an already-created 1080p
frame. NVENC uses its P4 quality preset with spatial adaptive quantization.
Images that are too small for their fitted 1080p area are reported before the
preview: scaling can reduce additional damage, but it cannot recreate detail
that is absent from the original image.

## Installing, and keeping every computer up to date

CreatorFlow installs per user, updates itself from GitHub Releases, and appears in
Add/Remove Programs. No administrator rights are needed at any point.

### One-time setup, on the computer where the code is edited

1. Create a public GitHub repository named `creatorflow`.
2. Open `SlideshowUpdate.psm1` and set your account name:

   ```powershell
   $script:UpdateOwner = 'your-github-username'
   ```

   Until that is filled in, update checking stays completely silent — no checks,
   no errors, no prompts — so the tool is perfectly usable without it.
3. Create a token at <https://github.com/settings/tokens> with **Contents: read and
   write** on that repository, then, in the PowerShell window you publish from:

   ```powershell
   $env:GITHUB_TOKEN = 'ghp_yourtokenhere'
   ```

### Publishing the runtime, once

Before any computer can be set up over the internet, publish FFmpeg once:

```powershell
.\Publish-Release.ps1 -Version 1.0.0 -IncludeRuntime
```

That packs `Tools` to about 116 MB and uploads it under its own permanent tag,
`runtime-7.1.1`. It has its own tag rather than riding along with the newest
release because pointing installers at "latest" would break every fresh install
the moment an application-only release was published. Repeat it only when FFmpeg
itself is replaced.

### Installing on a computer

**On a computer with nothing on it**, copy `Setup.bat` across — it is about three
kilobytes — or download it from the repository, and double-click it. It fetches the
application and the runtime from GitHub and installs both. Nothing else needs to be
carried between machines.

**When the whole folder is already there**, double-click `Install.bat` instead. It
uses the local `Tools` folder and never downloads anything.

Either way the application lands in `%LOCALAPPDATA%\Programs\CreatorFlow` with Start
Menu and desktop shortcuts and an Add/Remove Programs entry. The runtime is handled
cheapest-first: an already-installed copy is kept, otherwise one sitting beside the
installer is copied, otherwise the published one is downloaded. Reinstalling is
therefore quick and never disturbs an existing FFmpeg.

### Publishing an update

Edit the code, then from the source folder:

```powershell
.\Publish-Release.ps1 -Version 1.1.0 -Notes "Fixed the audio level."
```

This stamps `VERSION`, packages the application, records its SHA-256, creates the
GitHub release, and uploads both the archive and the manifest that installed copies
read. Without a token, `-ArtifactsOnly` builds the same files in `dist\` for uploading
by hand.

### What each installation does

On start it checks for a newer release on a background thread, so a slow or absent
network never delays the window. If one exists it offers to install it, and choosing
yes downloads the archive, checks it against the published SHA-256, and hands it to a
separate updater process. **Check for Updates** in the left rail asks on demand.

The updater exists as its own process because an application cannot replace files it
currently has open. It waits for the tool to close, moves the previous version aside,
copies the new one in, and starts the tool again. If anything fails at any point the
previous version is put back, so a bad download can never leave a half-updated
installation. Failures are recorded in `%LOCALAPPDATA%\SlideshowVideoTool\update.log`.

Updates carry only the application, around 80 KB, because the 283 MB FFmpeg runtime
does not change between releases and is deliberately excluded. Settings, render
history, and the downloaded speech model live outside the installation folder and
survive both updates and uninstalls.

## Running it on another computer

Copy the whole folder and double-click **Start Tool.bat**. Nothing is installed, no
paths are hard-coded to one machine, and FFmpeg travels inside the `Tools` folder, so
the same copy runs on any Windows 10 or 11 PC with Windows PowerShell 5.1 — which is
every one of them by default.

The tool measures the machine it finds itself on rather than assuming:

| It checks | What it does with the answer |
|---|---|
| Video encoder | Probes NVIDIA NVENC, then AMD AMF, then NVIDIA Vulkan, then Intel Quick Sync, and finally falls back to CPU encoding. The chosen one is named in the top-right of the window. |
| Motion-effects processor | Times the unchanged full-quality CPU graph against every compatible Vulkan GPU on the first render. It uses a GPU only when it wins by at least 8%; the per-machine result is cached. |
| Processor cores and installed memory | Picks how many 30-second segments render at once — 1 lane on a small laptop, up to 4 on a workstation. |
| OpenCL device | Only used for the GPU watermark and caption compositor, and only on NVIDIA. Every other machine does that step on the CPU, with identical output. |

So it runs anywhere; what changes is how long a render takes. A machine with no
supported GPU encoder still produces the same video through `libx264`, just slower.
Roughly 8 GB of memory is the practical floor, and it will render with a single lane.

### When a render feels too slow

The stage costs were measured, not estimated, on a 10-second segment pinned to two
cores so the numbers reflect a modest laptop:

| Stage | Cost |
|---|---:|
| Camera motion at 48 FPS plus the `tmix` shutter blend | **57%** |
| Animated crop and photo preparation | 28% |
| Watermark RGB Screen blend | 15% |
| Background blur, encoding | ~0% each — both finish far ahead of the filters |

Motion blur is therefore the only setting that changes render time substantially.
Switching it off measured **2.3x faster** end to end, at 1920x1080 and the same
bitrate, and is what to reach for when a render has to finish sooner.

Two things that sound like they should help do not, and were measured rather than
assumed:

- **More parallel lanes on a small machine.** On a simulated dual-core laptop, two
  lanes finished 6% *slower* than one, because the lanes contend for the same two
  cores. The lane formula's conservative answer for an 8 GB laptop is correct.
- **Blurring the background more cheaply.** Blurring at a quarter resolution and
  scaling back up is three times faster at that stage, but the stage runs once per
  photograph rather than once per frame, so it saves about one second across an
  entire render.

Two things do not travel with the folder by default:

- The caption speech engine and its models, about 535 MB, live in
  `%LOCALAPPDATA%\SlideshowVideoTool\caption-engine`. A new computer downloads them once,
  so its first caption run needs an internet connection. To avoid that, copy that
  `caption-engine` folder into `Tools\caption-engine` beside the scripts before copying
  the tool — the tool prefers that location when it exists, and then captions work
  offline on any machine. Everything else already works offline immediately.
- Settings, caption caches, and paused renders live in `%LOCALAPPDATA%\SlideshowVideoTool`,
  which is per-machine. Do not copy a half-finished render to another PC and resume it
  there — start it again instead.

Saved `.svp.json` projects store full paths to the images, voiceover, and watermark. If
those sit somewhere else on the other computer, the tool asks you to point at each
missing file rather than failing.

## GPU acceleration

Current FFmpeg 8.x builds require a newer NVENC API than the final supported
Quadro P620 driver provides. The included FFmpeg 7.1.1 build uses a compatible
NVENC API, so H.264 encoding works on the P620 without downgrading the NVIDIA
driver.

The first render on a new machine performs a short calibration using the actual
project media. It compares the existing CPU motion graph with every usable Vulkan
device, after warming the file cache, and requires the GPU to win by at least eight
percent. The choice is stored in `%LOCALAPPDATA%\SlideshowVideoTool\filter-backend.json`
and is automatically invalidated by a renderer update, CPU/GPU change, or graphics
driver update. A failed or slower GPU probe keeps the proven CPU renderer.

Both paths retain 1920x1080 delivery, 24 FPS output, 48 FPS motion sampling,
three-frame temporal motion blur, Lanczos photo resampling, RGB Screen blending,
caption styling, and the selected encoder quality/bitrate. The Vulkan path changes
where the animated fractional crop runs, not those quality decisions. Its real-number
crop needs only enough source overscan to avoid upscaling; the CPU `zoompan` path
keeps its larger 2x canvas to avoid whole-pixel stepping.

Three independent 30-second segments render simultaneously on a machine with
enough CPU and memory. An 8 GB laptop remains at one lane to avoid paging. Selecting
**SRT only** is the fastest caption mode because no caption pixels are rendered into
the video. GPU utilization still need not read 100 percent: decode, static photo
preparation, RGB Screen blending, captions, and encoding use different CPU/GPU
engines. The top-right status names both the encoder and whether motion effects use
the CPU or the calibrated Vulkan GPU.

The bundled FFmpeg build retains its original `LICENSE` and `README.txt`; FFmpeg
is free software distributed under its applicable LGPL/GPL terms.

## Files created outside the tool folder

The tool stores remembered settings, temporary previews, and the most recent error log under:

```text
%LOCALAPPDATA%\SlideshowVideoTool
```

Completed 30-second segments from a cancelled or failed final render are retained under the data folder and reused when the same job is started again. An existing final output is not replaced until the new render has completed successfully.

## Troubleshooting

If the tool reports that FFmpeg is missing, confirm that
`Tools\FFmpeg-7.1.1\ffmpeg-7.1.1-full_build\bin\ffmpeg.exe` is still present.

If rendering fails, the latest detailed FFmpeg error is saved as:

```text
%LOCALAPPDATA%\SlideshowVideoTool\last-error.log
```

The test suite can be run from PowerShell with:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-SlideshowEngine.ps1
```
