# Video Compressor: a small window for shrinking videos to a target size with the bundled ffmpeg.
# Videos can be dropped on "Compress video.bat" or straight onto the window.
# Quick mode (used by the right-click menu): compress.ps1 -Quick 10 "video.mp4"
#   compresses straight to that many MB with a small progress window, no questions asked.
#   Add -Gif to make an animated GIF under that size instead.

[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Quick = 0,
    [switch]$Ask,
    [switch]$Gif,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Files = @()
)

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$ffDir = Join-Path $PSScriptRoot "ffmpeg"
$ffmpeg = Join-Path $ffDir "ffmpeg.exe"
$ffprobe = Join-Path $ffDir "ffprobe.exe"
if (-not ((Test-Path $ffmpeg) -and (Test-Path $ffprobe))) {
    [System.Windows.Forms.MessageBox]::Show("ffmpeg.exe or ffprobe.exe is missing from:`n$ffDir", "Video Compressor", "OK", "Error") | Out-Null
    exit 1
}

$SizeChoices = @(
    @{ Text = "8 MB"; MB = 8 },
    @{ Text = "10 MB (Discord)"; MB = 10 },
    @{ Text = "25 MB"; MB = 25 },
    @{ Text = "50 MB"; MB = 50 },
    @{ Text = "100 MB"; MB = 100 }
)
$ResolutionChoices = @(
    @{ Text = "Keep original"; Side = 0 },
    @{ Text = "1080p"; Side = 1920 },
    @{ Text = "720p"; Side = 1280 },
    @{ Text = "480p"; Side = 854 },
    @{ Text = "360p"; Side = 640 }
)
$FormatChoices = @(
    @{ Text = "MP4 video"; Gif = $false },
    @{ Text = "Animated GIF"; Gif = $true }
)
$QualityChoices = @(
    @{ Text = "Fastest (GPU)"; Preset = "veryfast"; Gpu = $true },
    @{ Text = "Fast"; Preset = "veryfast" },
    @{ Text = "Balanced"; Preset = "medium" },
    @{ Text = "Best (slower)"; Preset = "slow" }
)
$SequenceFps = 25   # frame rate used when turning an image sequence (EXR, PNG...) into a video or GIF

# EXR colour handling, matching vfx-transcode: oiiotool + the ACES 1.2 OCIO config turn the linear
# ACEScg renders into the "Output - sRGB" view (the ACES look you see in Nuke/Maya).
# Without the oiio/ocio folders it falls back to a plain linear-to-sRGB curve.
$oiiotool = Join-Path $PSScriptRoot "oiio\oiiotool.exe"
$ocioConfig = Join-Path $PSScriptRoot "ocio\aces_1.2cg\config.ocio"
$ExrColorIn = "ACES - ACEScg"
$ExrColorOut = "Output - sRGB"
$script:seqTemp = $null
$MinVideoKbps = 32
$MaxVideoKbps = 12000

$script:busy = $false
$script:cancel = $false
$script:current = $null

# True when the NVIDIA hardware encoder works on this machine (checked once, takes a moment).
function Test-Nvenc {
    if ($null -eq $script:nvenc) {
        & $ffmpeg -hide_banner -loglevel quiet -f lavfi -i "color=s=256x256:d=0.1" -c:v h264_nvenc -f null - 2>$null
        $script:nvenc = ($LASTEXITCODE -eq 0)
    }
    return $script:nvenc
}

function Quote-Arg([string]$a) {
    if ($a -eq "") { return '""' }
    if ($a -match '[\s"]') { return '"' + ($a -replace '"', '\"') + '"' }
    return $a
}

# Runs ffmpeg with progress reporting; the window stays responsive while it works.
function Invoke-Ffmpeg([string[]]$ArgList, [double]$Duration, [int]$From, [int]$To) {
    $psi = New-Object System.Diagnostics.ProcessStartInfo $ffmpeg
    $psi.Arguments = (@("-hide_banner", "-loglevel", "error", "-nostats", "-progress", "pipe:1") + $ArgList | ForEach-Object { Quote-Arg $_ }) -join " "
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    $script:current = $p
    $errors = $p.StandardError.ReadToEndAsync()
    while ($null -ne ($line = $p.StandardOutput.ReadLine())) {
        $us = 0L
        if ($line.StartsWith("out_time_us=") -and [long]::TryParse($line.Substring(12), [ref]$us)) {
            $fraction = [math]::Min(1, [math]::Max(0, $us / ($Duration * 1e6)))
            $progress.Value = [int]($From + ($To - $From) * $fraction)
        }
        [System.Windows.Forms.Application]::DoEvents()
    }
    $p.WaitForExit()
    $script:current = $null
    if ($script:cancel) { throw "Cancelled" }
    if ($p.ExitCode) { throw ("ffmpeg failed: " + $errors.Result.Trim()) }
}

$ImageExtensions = ".exr", ".dpx", ".png", ".tif", ".tiff", ".tga", ".jpg", ".jpeg", ".bmp"

# Finds the numbered image sequence a frame belongs to, e.g. shot_0042.exr -> shot_0001..shot_0120.exr.
# Also accepts the list's display form, shot_####.exr. Returns $null for anything that isn't an image.
function Get-Sequence([string]$Path) {
    $ext = [System.IO.Path]::GetExtension($Path).ToLower()
    if ($ImageExtensions -notcontains $ext) { return $null }
    $dir = Split-Path $Path
    $name = Split-Path $Path -Leaf
    if ($name -notmatch '^(.*?)(\d+|#+)(\.[^.]+)$') { throw "isn't a numbered image sequence (like shot_0001.exr)" }
    $prefix, $digits, $e = $Matches[1], $Matches[2].Length, $Matches[3]
    $rx = '^' + [regex]::Escape($prefix) + '(\d{' + $digits + '})' + [regex]::Escape($e) + '$'
    $frames = @(Get-ChildItem -LiteralPath $dir -File | ForEach-Object { if ($_.Name -match $rx) { [int]$Matches[1] } } | Sort-Object)
    if (-not $frames.Count) { throw "no frames found" }
    $start = $frames[0]
    $count = 1   # ffmpeg stops at the first missing frame, so only count the unbroken run
    while ($count -lt $frames.Count -and $frames[$count] -eq $start + $count) { $count++ }
    $base = $prefix -replace '[\s._-]+$', ''
    return @{
        Pattern = Join-Path ($dir -replace '%', '%%') (($prefix -replace '%', '%%') + "%0${digits}d" + $e)
        Display = Join-Path $dir ($prefix + ('#' * $digits) + $e)
        First = Join-Path $dir ($prefix + $start.ToString("D$digits") + $e)
        Start = $start; Count = $count; Missing = $frames.Count - $count; Prefix = $prefix; Digits = $digits; Ext = $e
        Dir = $dir; Base = $(if ($base) { $base } else { "sequence" }); Exr = ($e -ieq ".exr")
    }
}

# Converts every EXR frame to an 8-bit PNG in $OutDir (f_000000.png, ...) through OCIO, several frames at once.
function Convert-ExrFrames($Seq, [string]$OutDir) {
    $max = [math]::Min(16, [Environment]::ProcessorCount)
    $running = New-Object System.Collections.ArrayList
    $next = 0
    $finished = 0
    try {
        while ($finished -lt $Seq.Count) {
            while ($running.Count -lt $max -and $next -lt $Seq.Count) {
                $frame = Join-Path $Seq.Dir ($Seq.Prefix + ($Seq.Start + $next).ToString("D$($Seq.Digits)") + $Seq.Ext)
                $oiioArgs = @("--wildcardoff", "--evaloff", "--threads", "1", "-i", $frame, "--ch", "R,G,B",
                    "--colorconfig", $ocioConfig, "--colorconvert", $ExrColorIn, $ExrColorOut,
                    "-d", "uint8", "-o", (Join-Path $OutDir ("f_{0:D6}.png" -f $next)))
                $psi = New-Object System.Diagnostics.ProcessStartInfo $oiiotool
                $psi.Arguments = ($oiioArgs | ForEach-Object { Quote-Arg $_ }) -join " "
                $psi.UseShellExecute = $false
                $psi.CreateNoWindow = $true
                $psi.RedirectStandardError = $true
                $psi.RedirectStandardOutput = $true
                [void]$running.Add(@{ P = [System.Diagnostics.Process]::Start($psi); Name = Split-Path $frame -Leaf })
                $next++
            }
            foreach ($job in @($running)) {
                if (-not $job.P.HasExited) { continue }
                if ($job.P.ExitCode) {
                    $msg = ($job.P.StandardError.ReadToEnd() + $job.P.StandardOutput.ReadToEnd()).Trim()
                    throw "colour conversion failed on $($job.Name): $msg"
                }
                $running.Remove($job)
                $finished++
            }
            $progress.Value = [int](100 * $finished / $Seq.Count)
            [System.Windows.Forms.Application]::DoEvents()
            if ($script:cancel) { throw "Cancelled" }
            Start-Sleep -Milliseconds 20
        }
    }
    finally {
        foreach ($job in $running) { try { $job.P.Kill() } catch {} }
    }
}

# Deletes the converted frames of the last EXR sequence, if any.
function Remove-SeqTemp {
    if ($script:seqTemp) { Remove-Item -LiteralPath $script:seqTemp -Recurse -Force -ErrorAction SilentlyContinue }
    $script:seqTemp = $null
}

# Describes what to feed ffmpeg for a video file or an image sequence.
function Get-Source([string]$Path, [double]$SeqFps) {
    $seq = Get-Sequence $Path
    if ($seq) {
        $probe = (& $ffprobe -v error -select_streams v:0 -show_entries "stream=width,height" -of json $seq.First) -join "`n" | ConvertFrom-Json
        $note = ", $($seq.Count) frames"
        if ($seq.Exr -and (Test-Path $oiiotool) -and (Test-Path $ocioConfig)) {
            Remove-SeqTemp
            $script:seqTemp = Join-Path $env:TEMP ("vc-frames-" + [guid]::NewGuid())
            New-Item -ItemType Directory $script:seqTemp | Out-Null
            Convert-ExrFrames $seq $script:seqTemp
            $in = @("-framerate", "$SeqFps", "-start_number", "0", "-i", (Join-Path $script:seqTemp "f_%06d.png"))
        } else {
            $in = @("-framerate", "$SeqFps", "-start_number", "$($seq.Start)")
            if ($seq.Exr) {
                $in += @("-apply_trc", "iec61966_2_1")   # fallback: plain linear -> sRGB curve, no ACES look
                $note += ", simple sRGB (oiio/ocio folders not found)"
            }
            $in += @("-i", $seq.Pattern)
        }
        if ($seq.Missing) { $note += " (stopped at a missing frame, $($seq.Missing) left out)" }
        return @{
            Input = $in; Duration = $seq.Count / $SeqFps; Fps = $SeqFps; Sequence = $true
            Width = [int]$probe.streams[0].width; Height = [int]$probe.streams[0].height; HasAudio = $false
            Dir = $seq.Dir; Base = $seq.Base; Name = $seq.Base; Bytes = 0; Note = $note
        }
    }
    $item = Get-Item -LiteralPath $Path
    $probe = (& $ffprobe -v error -show_entries "format=duration:stream=codec_type,width,height" -of json $item.FullName) -join "`n" | ConvertFrom-Json
    $duration = [double]$probe.format.duration
    if (-not ($duration -gt 0)) { throw "could not read the video's length" }
    $v = @($probe.streams | Where-Object { $_.codec_type -eq "video" })[0]
    return @{
        Input = @("-i", $item.FullName); Duration = $duration; Fps = 0; Sequence = $false
        Width = [int]$v.width; Height = [int]$v.height
        HasAudio = @($probe.streams | Where-Object { $_.codec_type -eq "audio" }).Count -gt 0
        Dir = $item.DirectoryName; Base = $item.BaseName; Name = $item.BaseName + "_compressed"; Bytes = $item.Length
    }
}

function Compress-Video([string]$InputPath, [hashtable]$Opt) {
    $targetBytes = $Opt.MB * 1000000 * 0.95
    $src = Get-Source $InputPath $Opt.SeqFps
    $folder = if ($Opt.OutFolder) { $Opt.OutFolder } else { $src.Dir }
    $output = Join-Path $folder ($src.Name + ".mp4")

    if ($src.Bytes -and $src.Bytes -le $targetBytes) { return "already under $($Opt.MB) MB, skipped" }
    $duration = $src.Duration
    $hasAudio = $Opt.KeepAudio -and $src.HasAudio

    $available = [int]($targetBytes * 8 * 0.94 / $duration / 1000)
    $audioKbps = if (-not $hasAudio) { 0 } elseif ($available -lt 400) { 64 } else { 96 }
    $video = [math]::Min($MaxVideoKbps, $available - $audioKbps)
    if ($video -lt $MinVideoKbps) { throw "too long ($([int]$duration)s) to fit in $($Opt.MB) MB" }

    $scale = if ($Opt.Side) {
        "scale=w='min($($Opt.Side),iw)':h='min($($Opt.Side),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
    } else {
        "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    }
    $tagArgs = @()
    if ($src.Sequence) {
        # Image frames are RGB: convert to YUV with the Rec.709 matrix (ffmpeg would pick 601) and tag it, like vfx-transcode.
        $scale += ":out_color_matrix=bt709:out_range=tv,format=yuv420p"
        $tagArgs = @("-color_primaries", "bt709", "-color_trc", "bt709", "-colorspace", "bt709", "-color_range", "tv")
    }
    $audioArgs = if ($hasAudio) { @("-map", "0:a:0", "-c:a", "aac", "-b:a", "${audioKbps}k", "-ac", "2") } else { @("-an") }
    $passLog = Join-Path $env:TEMP ("vc-pass-" + [guid]::NewGuid())
    try {
        $useGpu = $Opt.Gpu -and (Test-Nvenc)
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            if ($useGpu) {
                # One pass on the GPU: hardware decode + NVENC with its own internal lookahead pass.
                $hw = if ($src.Sequence) { @() } else { @("-hwaccel", "auto") }
                $gpuArgs = @("-y") + $hw + $src.Input + @("-map", "0:v:0", "-vf", $scale, "-pix_fmt", "yuv420p",
                    "-c:v", "h264_nvenc", "-preset", "p5", "-tune", "hq", "-rc", "vbr", "-multipass", "qres", "-spatial-aq", "1",
                    "-b:v", "${video}k", "-maxrate", "$([int]($video * 1.5))k", "-bufsize", "$($video * 2)k") + $tagArgs
                Invoke-Ffmpeg ($gpuArgs + $audioArgs + @("-movflags", "+faststart", $output)) $duration 0 100
            } else {
                $common = @("-y") + $src.Input + @("-map", "0:v:0", "-vf", $scale, "-pix_fmt", "yuv420p",
                    "-c:v", "libx264", "-preset", $Opt.Preset, "-b:v", "${video}k", "-passlogfile", $passLog) + $tagArgs
                Invoke-Ffmpeg ($common + @("-pass", "1", "-an", "-f", "null", "NUL")) $duration 0 50
                Invoke-Ffmpeg ($common + @("-pass", "2") + $audioArgs + @("-movflags", "+faststart", $output)) $duration 50 100
            }

            $size = (Get-Item -LiteralPath $output).Length
            if ($size -le $targetBytes) { return ("{0:N2} MB" -f ($size / 1MB)) + $src.Note }
            $video = [int]($video * $targetBytes / $size * 0.9)
            if ($video -lt $MinVideoKbps) { break }
        }
        Remove-Item -LiteralPath $output -ErrorAction SilentlyContinue
        throw "could not get it under $($Opt.MB) MB"
    }
    catch {
        if ($script:cancel) { Remove-Item -LiteralPath $output -ErrorAction SilentlyContinue }
        throw
    }
    finally {
        Remove-Item "$passLog*" -ErrorAction SilentlyContinue
    }
}

# Makes an animated GIF under the target size. GIF size grows with width^2 x fps, so when a try
# comes out too big, the next one shrinks the width (and drops to 10 fps) by about the right amount.
function New-Gif([string]$InputPath, [hashtable]$Opt) {
    $targetBytes = $Opt.MB * 1000000 * 0.95
    $src = Get-Source $InputPath $Opt.SeqFps
    $folder = if ($Opt.OutFolder) { $Opt.OutFolder } else { $src.Dir }
    $output = Join-Path $folder ($src.Base + ".gif")
    $duration = $src.Duration
    $longSide = [math]::Max($src.Width, $src.Height)
    $side = if ($Opt.Side -and $Opt.Side -lt $longSide) { $Opt.Side } else { $longSide }
    $fps = if ($src.Fps -and $src.Fps -lt 15) { $src.Fps } else { 15 }

    try {
        for ($attempt = 1; $attempt -le 6; $attempt++) {
            $vf = "fps=$fps,scale=w=${side}:h=${side}:force_original_aspect_ratio=decrease:flags=lanczos," +
                "split[a][b];[a]palettegen=stats_mode=diff[p];[b][p]paletteuse=dither=bayer:bayer_scale=5:diff_mode=rectangle"
            Invoke-Ffmpeg (@("-y") + $src.Input + @("-map", "0:v:0", "-vf", $vf, "-loop", "0", $output)) $duration 0 100

            $size = (Get-Item -LiteralPath $output).Length
            if ($size -le $targetBytes) { return ("{0:N2} MB, {1}px, {2} fps" -f ($size / 1MB), $side, $fps) + $src.Note }
            $ratio = $targetBytes / $size
            if ($fps -gt 10 -and $ratio -lt 0.6) { $fps = 10; $ratio *= 1.5 }
            $side = [int]($side * [math]::Sqrt($ratio) * 0.95)
            if ($side -lt 120) { break }
        }
        Remove-Item -LiteralPath $output -ErrorAction SilentlyContinue
        throw "too long ($([int]$duration)s) for a GIF under $($Opt.MB) MB - trim it first"
    }
    catch {
        if ($script:cancel) { Remove-Item -LiteralPath $output -ErrorAction SilentlyContinue }
        throw
    }
}

$font = New-Object System.Drawing.Font("Segoe UI", 9)
$iconPath = Join-Path $PSScriptRoot "icon.ico"
$appIcon = if (Test-Path $iconPath) { New-Object System.Drawing.Icon $iconPath } else { $null }

# ---------- Quick mode (right-click menu) ----------

# -Ask: ask for the target size first ("Custom target size..." in the menu).
if ($Ask) {
    Add-Type -AssemblyName Microsoft.VisualBasic
    $answer = [Microsoft.VisualBasic.Interaction]::InputBox("Target size in MB:", "Video Compressor", "15").Trim() -replace '\s*mb$', ''
    if (-not $answer) { exit }
    if (-not [int]::TryParse($answer, [ref]$Quick) -or $Quick -lt 1) {
        [System.Windows.Forms.MessageBox]::Show("`"$answer`" isn't a whole number of MB.", "Video Compressor", "OK", "Warning") | Out-Null
        exit
    }
}

if ($Quick -gt 0) {
    $file = $Files | Select-Object -First 1
    $displayName = [System.IO.Path]::GetFileName($file)
    $seq = try { Get-Sequence $file } catch { $null }
    if ($seq) {
        # Right-clicking several frames of a sequence starts one copy per frame; only the first does the work.
        $md5 = [System.Security.Cryptography.MD5]::Create()
        $key = -join ($md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$($seq.Display.ToLower())|$Gif|$Quick")) | ForEach-Object { $_.ToString("x2") })
        $seqMutex = New-Object System.Threading.Mutex($false, "Local\VideoCompressorSeq-$key")
        try { if (-not $seqMutex.WaitOne(0)) { exit } } catch [System.Threading.AbandonedMutexException] {}
        $marker = Join-Path $env:TEMP "vc-seq-$key.done"
        if ((Test-Path $marker) -and ((Get-Date) - (Get-Item $marker).LastWriteTime).TotalSeconds -lt 15) { exit }
        $displayName = Split-Path $seq.Display -Leaf
    }
    $qf = New-Object System.Windows.Forms.Form
    $qf.Text = if ($Gif) { "Making a GIF under $Quick MB" } else { "Compressing to $Quick MB" }
    $qf.ClientSize = New-Object System.Drawing.Size(420, 96)
    $qf.FormBorderStyle = "FixedToolWindow"
    $qf.StartPosition = "CenterScreen"
    $qf.TopMost = $true
    $qf.Font = $font
    if ($appIcon) { $qf.Icon = $appIcon }
    $qLabel = New-Object System.Windows.Forms.Label
    $qLabel.SetBounds(12, 10, 396, 20)
    $qLabel.AutoEllipsis = $true
    $qLabel.Text = $displayName
    $progress = New-Object System.Windows.Forms.ProgressBar
    $progress.SetBounds(12, 36, 396, 22)
    $qBtn = New-Object System.Windows.Forms.Button
    $qBtn.SetBounds(318, 64, 90, 26)
    $qBtn.Text = "Cancel"
    $qf.Controls.AddRange(@($qLabel, $progress, $qBtn))
    $script:done = $false
    $qBtn.Add_Click({
        if ($script:done) { $qf.Close(); return }
        $script:cancel = $true
        try { $script:current.Kill() } catch {}
    })
    $qf.Add_FormClosing({ if (-not $script:done) { $script:cancel = $true; try { $script:current.Kill() } catch {} } })
    $qf.Show()
    [System.Windows.Forms.Application]::DoEvents()

    # Several files right-clicked at once each start their own window; take turns so the GPU isn't swamped.
    $mutex = New-Object System.Threading.Mutex($false, "Local\VideoCompressorQuick")
    $owned = $false
    $qLabel.Text = "Waiting for other videos... " + $displayName
    while (-not $owned -and -not $script:cancel) {
        try { $owned = $mutex.WaitOne(200) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        [System.Windows.Forms.Application]::DoEvents()
    }

    $closeIn = 0
    if (-not $script:cancel) {
        $qLabel.Text = $displayName
        try {
            $result = if ($Gif) { New-Gif $file @{ MB = $Quick; Side = 480; SeqFps = $SequenceFps } }
                else { Compress-Video $file @{ MB = $Quick; Side = 1920; Preset = "veryfast"; Gpu = $true; KeepAudio = $true; SeqFps = $SequenceFps } }
            $qLabel.Text = "Done: $result - " + $displayName
            $progress.Value = 100
            $closeIn = 4
        }
        catch {
            $qLabel.Text = if ($script:cancel) { "Cancelled." } else { "Failed: $($_.Exception.Message)" }
            $closeIn = if ($script:cancel) { 1 } else { 0 }
        }
        finally { Remove-SeqTemp }
    }
    if ($owned) { $mutex.ReleaseMutex() }
    if ($seq) { Set-Content -LiteralPath $marker "" }   # tells late-starting copies for other frames to skip
    $script:done = $true
    if ($qf.IsDisposed) { exit }
    $qBtn.Text = "Close"
    if ($closeIn) {
        $timer = New-Object System.Windows.Forms.Timer
        $timer.Interval = $closeIn * 1000
        $timer.Add_Tick({ $qf.Close() })
        $timer.Start()
    }
    $qf.Hide()
    [void]$qf.ShowDialog()
    exit
}

# ---------- Window ----------

$form = New-Object System.Windows.Forms.Form
$form.Text = "Video Compressor"
$form.ClientSize = New-Object System.Drawing.Size(500, 502)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.Font = $font
if ($appIcon) { $form.Icon = $appIcon }
$form.AllowDrop = $true

function New-Control($Type, $X, $Y, $W, $H, $Text = "") {
    $c = New-Object "System.Windows.Forms.$Type"
    $c.Location = New-Object System.Drawing.Point($X, $Y)
    $c.Size = New-Object System.Drawing.Size($W, $H)
    if ($Text) { $c.Text = $Text }
    return $c
}

function New-Choice($Parent, $Label, $Y, $Choices, $Default) {
    $Parent.Controls.Add((New-Control Label 12 ($Y + 3) 110 20 $Label))
    $box = New-Control ComboBox 125 $Y 200 24
    $box.DropDownStyle = "DropDownList"
    foreach ($c in $Choices) { [void]$box.Items.Add($c.Text) }
    $box.SelectedIndex = $Default
    $Parent.Controls.Add($box)
    return $box
}

$form.Controls.Add((New-Control Label 12 10 476 20 "Videos or image sequences (drag more files here):"))
$list = New-Control ListBox 12 32 476 110
$list.SelectionMode = "MultiExtended"
$list.HorizontalScrollbar = $true
$list.AllowDrop = $true
$form.Controls.Add($list)

$addBtn = New-Control Button 12 148 100 28 "Add files..."
$removeBtn = New-Control Button 118 148 100 28 "Remove"
$form.Controls.Add($addBtn)
$form.Controls.Add($removeBtn)

$options = New-Control GroupBox 12 186 476 222 "Options"
$form.Controls.Add($options)
$formatBox = New-Choice $options "Format:" 24 $FormatChoices 0
$sizeBox = New-Choice $options "Target size:" 56 $SizeChoices 1
$resBox = New-Choice $options "Max resolution:" 88 $ResolutionChoices 2
$qualityBox = New-Choice $options "Quality:" 120 $QualityChoices 0
$audioCheck = New-Control CheckBox 125 150 200 24 "Keep audio"
$audioCheck.Checked = $true
$options.Controls.Add($audioCheck)

$options.Controls.Add((New-Control Label 12 184 110 20 "Save to:"))
$outBox = New-Control TextBox 125 181 230 24 "Same folder as each video"
$outBox.ReadOnly = $true
$options.Controls.Add($outBox)
$browseBtn = New-Control Button 360 180 50 26 "..."
$resetBtn = New-Control Button 414 180 50 26 "Reset"
$options.Controls.Add($browseBtn)
$options.Controls.Add($resetBtn)
$script:outFolder = ""

$openCheck = New-Control CheckBox 12 414 300 24 "Open the folder when done"
$openCheck.Checked = $true
$form.Controls.Add($openCheck)

$status = New-Control Label 12 440 476 20 "Ready."
$progress = New-Control ProgressBar 12 462 370 28
$goBtn = New-Control Button 388 462 100 28 "Compress"
$form.Controls.Add($status)
$form.Controls.Add($progress)
$form.Controls.Add($goBtn)
$form.AcceptButton = $goBtn

$videoFilter = "Videos and image sequences|*.mp4;*.mov;*.mkv;*.avi;*.webm;*.wmv;*.m4v;*.flv;*.mpg;*.mpeg;*.ts;" +
    (($ImageExtensions | ForEach-Object { "*$_" }) -join ";") + "|All files|*.*"

# Frames of an image sequence collapse into one entry shown as shot_####.exr.
function Add-Files($Paths) {
    foreach ($p in $Paths) {
        if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { continue }
        $entry = $p
        $name = Split-Path $p -Leaf
        if ($ImageExtensions -contains [System.IO.Path]::GetExtension($p).ToLower()) {
            # Cheap check first so dropping hundreds of frames doesn't rescan the folder for each one.
            if ($name -match '^(.*?)(\d+)(\.[^.]+)$' -and $list.Items.Contains((Join-Path (Split-Path $p) ($Matches[1] + ('#' * $Matches[2].Length) + $Matches[3])))) { continue }
            try { $entry = (Get-Sequence $p).Display }
            catch { $status.Text = "Skipped ${name}: $($_.Exception.Message)"; continue }
        }
        if (-not $list.Items.Contains($entry)) { [void]$list.Items.Add($entry) }
    }
}

function Set-Busy([bool]$Busy) {
    $script:busy = $Busy
    foreach ($c in @($list, $addBtn, $removeBtn, $options, $openCheck)) { $c.Enabled = -not $Busy }
    $goBtn.Text = if ($Busy) { "Cancel" } elseif ($FormatChoices[$formatBox.SelectedIndex].Gif) { "Make GIF" } else { "Compress" }
}

# Quality and audio don't apply to GIFs.
function Update-FormatControls {
    $gif = $FormatChoices[$formatBox.SelectedIndex].Gif
    $qualityBox.Enabled = -not $gif
    $audioCheck.Enabled = -not $gif
}

function Start-Compression {
    if ($list.Items.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Add some videos first.", "Video Compressor") | Out-Null
        return
    }
    $opt = @{
        MB = $SizeChoices[$sizeBox.SelectedIndex].MB
        Side = $ResolutionChoices[$resBox.SelectedIndex].Side
        Preset = $QualityChoices[$qualityBox.SelectedIndex].Preset
        Gpu = [bool]$QualityChoices[$qualityBox.SelectedIndex].Gpu
        KeepAudio = $audioCheck.Checked
        OutFolder = $script:outFolder
        SeqFps = $SequenceFps
    }
    $makeGif = $FormatChoices[$formatBox.SelectedIndex].Gif
    $script:cancel = $false
    Set-Busy $true
    $files = @($list.Items)
    $results = @()
    $folders = @()
    for ($i = 0; $i -lt $files.Count; $i++) {
        $name = [System.IO.Path]::GetFileName($files[$i])
        $status.Text = $(if ($makeGif) { "Making GIF" } else { "Compressing" }) + " $($i + 1) of $($files.Count): $name"
        $progress.Value = 0
        try {
            $result = if ($makeGif) { New-Gif $files[$i] $opt } else { Compress-Video $files[$i] $opt }
            $results += "OK      $name - $result"
            $folders += if ($opt.OutFolder) { $opt.OutFolder } else { Split-Path $files[$i] }
        }
        catch {
            if ($script:cancel) { $results += "STOPPED $name"; break }
            $results += "FAILED  $name - $($_.Exception.Message)"
        }
        finally { Remove-SeqTemp }
    }
    Set-Busy $false
    $progress.Value = 0
    $status.Text = if ($script:cancel) { "Cancelled." } else { "Finished." }
    if ($form.IsDisposed -or $form.Disposing) { return }
    if ($openCheck.Checked -and -not $script:cancel) {
        $folders | Select-Object -Unique | ForEach-Object { Start-Process explorer.exe $_ }
    }
    [System.Windows.Forms.MessageBox]::Show(($results -join "`n"), "Video Compressor") | Out-Null
}

$onDragEnter = {
    if ($_.Data.GetDataPresent([System.Windows.Forms.DataFormats]::FileDrop) -and -not $script:busy) { $_.Effect = "Copy" }
}
$onDragDrop = { Add-Files $_.Data.GetData([System.Windows.Forms.DataFormats]::FileDrop) }
foreach ($c in @($form, $list)) { $c.Add_DragEnter($onDragEnter); $c.Add_DragDrop($onDragDrop) }

$addBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Multiselect = $true
    $dlg.Filter = $videoFilter
    if ($dlg.ShowDialog() -eq "OK") { Add-Files $dlg.FileNames }
})
$removeBtn.Add_Click({
    foreach ($item in @($list.SelectedItems)) { $list.Items.Remove($item) }
})
$browseBtn.Add_Click({
    $dlg = New-Object System.Windows.Forms.FolderBrowserDialog
    if ($dlg.ShowDialog() -eq "OK") { $script:outFolder = $dlg.SelectedPath; $outBox.Text = $dlg.SelectedPath }
})
$formatBox.Add_SelectedIndexChanged({
    $gif = $FormatChoices[$formatBox.SelectedIndex].Gif
    if ($gif -and $resBox.SelectedIndex -lt 3) { $resBox.SelectedIndex = 3 }   # GIFs above 480p get huge fast
    $goBtn.Text = if ($gif) { "Make GIF" } else { "Compress" }
    Update-FormatControls
})
$resetBtn.Add_Click({ $script:outFolder = ""; $outBox.Text = "Same folder as each video" })
$goBtn.Add_Click({
    if ($script:busy) {
        $script:cancel = $true
        try { $script:current.Kill() } catch {}
    } else {
        Start-Compression
    }
})
$form.Add_FormClosing({
    if ($script:busy) {
        $script:cancel = $true
        try { $script:current.Kill() } catch {}
    }
})

Add-Files $Files
[void]$form.ShowDialog()
