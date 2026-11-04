# Video Compressor: a small window for shrinking videos to a target size with the bundled ffmpeg.
# Videos can be dropped on "Compress video.bat" or straight onto the window.
# Quick mode (used by the right-click menu): compress.ps1 -Quick 10 "video.mp4"
#   compresses straight to that many MB with a small progress window, no questions asked.

[CmdletBinding(PositionalBinding = $false)]
param(
    [int]$Quick = 0,
    [switch]$Ask,
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
$QualityChoices = @(
    @{ Text = "Fastest (GPU)"; Preset = "veryfast"; Gpu = $true },
    @{ Text = "Fast"; Preset = "veryfast" },
    @{ Text = "Balanced"; Preset = "medium" },
    @{ Text = "Best (slower)"; Preset = "slow" }
)
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

function Compress-Video([string]$InputPath, [hashtable]$Opt) {
    $item = Get-Item -LiteralPath $InputPath
    $folder = if ($Opt.OutFolder) { $Opt.OutFolder } else { $item.DirectoryName }
    $output = Join-Path $folder ($item.BaseName + "_compressed.mp4")
    $targetBytes = $Opt.MB * 1000000 * 0.95

    if ($item.Length -le $targetBytes) { return "already under $($Opt.MB) MB, skipped" }

    $probe = (& $ffprobe -v error -show_entries "format=duration:stream=codec_type" -of json $item.FullName) -join "`n" | ConvertFrom-Json
    $duration = [double]$probe.format.duration
    if (-not ($duration -gt 0)) { throw "could not read the video's length" }
    $hasAudio = $Opt.KeepAudio -and @($probe.streams | Where-Object { $_.codec_type -eq "audio" }).Count -gt 0

    $available = [int]($targetBytes * 8 * 0.94 / $duration / 1000)
    $audioKbps = if (-not $hasAudio) { 0 } elseif ($available -lt 400) { 64 } else { 96 }
    $video = [math]::Min($MaxVideoKbps, $available - $audioKbps)
    if ($video -lt $MinVideoKbps) { throw "too long ($([int]$duration)s) to fit in $($Opt.MB) MB" }

    $scale = if ($Opt.Side) {
        "scale=w='min($($Opt.Side),iw)':h='min($($Opt.Side),ih)':force_original_aspect_ratio=decrease:force_divisible_by=2"
    } else {
        "scale=trunc(iw/2)*2:trunc(ih/2)*2"
    }
    $audioArgs = if ($hasAudio) { @("-map", "0:a:0", "-c:a", "aac", "-b:a", "${audioKbps}k", "-ac", "2") } else { @("-an") }
    $passLog = Join-Path $env:TEMP ("vc-pass-" + [guid]::NewGuid())
    try {
        $useGpu = $Opt.Gpu -and (Test-Nvenc)
        for ($attempt = 1; $attempt -le 5; $attempt++) {
            if ($useGpu) {
                # One pass on the GPU: hardware decode + NVENC with its own internal lookahead pass.
                $gpuArgs = @("-y", "-hwaccel", "auto", "-i", $item.FullName, "-map", "0:v:0", "-vf", $scale, "-pix_fmt", "yuv420p",
                    "-c:v", "h264_nvenc", "-preset", "p5", "-tune", "hq", "-rc", "vbr", "-multipass", "qres", "-spatial-aq", "1",
                    "-b:v", "${video}k", "-maxrate", "$([int]($video * 1.5))k", "-bufsize", "$($video * 2)k")
                Invoke-Ffmpeg ($gpuArgs + $audioArgs + @("-movflags", "+faststart", $output)) $duration 0 100
            } else {
                $common = @("-y", "-i", $item.FullName, "-map", "0:v:0", "-vf", $scale, "-pix_fmt", "yuv420p",
                    "-c:v", "libx264", "-preset", $Opt.Preset, "-b:v", "${video}k", "-passlogfile", $passLog)
                Invoke-Ffmpeg ($common + @("-pass", "1", "-an", "-f", "null", "NUL")) $duration 0 50
                Invoke-Ffmpeg ($common + @("-pass", "2") + $audioArgs + @("-movflags", "+faststart", $output)) $duration 50 100
            }

            $size = (Get-Item -LiteralPath $output).Length
            if ($size -le $targetBytes) { return "{0:N2} MB" -f ($size / 1MB) }
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

$font = New-Object System.Drawing.Font("Segoe UI", 9)

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
    $qf = New-Object System.Windows.Forms.Form
    $qf.Text = "Compressing to $Quick MB"
    $qf.ClientSize = New-Object System.Drawing.Size(420, 96)
    $qf.FormBorderStyle = "FixedToolWindow"
    $qf.StartPosition = "CenterScreen"
    $qf.TopMost = $true
    $qf.Font = $font
    $qLabel = New-Object System.Windows.Forms.Label
    $qLabel.SetBounds(12, 10, 396, 20)
    $qLabel.AutoEllipsis = $true
    $qLabel.Text = [System.IO.Path]::GetFileName($file)
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
    $qLabel.Text = "Waiting for other videos... " + [System.IO.Path]::GetFileName($file)
    while (-not $owned -and -not $script:cancel) {
        try { $owned = $mutex.WaitOne(200) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
        [System.Windows.Forms.Application]::DoEvents()
    }

    $closeIn = 0
    if (-not $script:cancel) {
        $qLabel.Text = [System.IO.Path]::GetFileName($file)
        try {
            $result = Compress-Video $file @{ MB = $Quick; Side = 1920; Preset = "veryfast"; Gpu = $true; KeepAudio = $true }
            $qLabel.Text = "Done: $result - " + [System.IO.Path]::GetFileName($file)
            $progress.Value = 100
            $closeIn = 4
        }
        catch {
            $qLabel.Text = if ($script:cancel) { "Cancelled." } else { "Failed: $($_.Exception.Message)" }
            $closeIn = if ($script:cancel) { 1 } else { 0 }
        }
    }
    if ($owned) { $mutex.ReleaseMutex() }
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
$form.ClientSize = New-Object System.Drawing.Size(500, 470)
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.StartPosition = "CenterScreen"
$form.Font = $font
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

$form.Controls.Add((New-Control Label 12 10 476 20 "Videos (drag more files here):"))
$list = New-Control ListBox 12 32 476 110
$list.SelectionMode = "MultiExtended"
$list.HorizontalScrollbar = $true
$list.AllowDrop = $true
$form.Controls.Add($list)

$addBtn = New-Control Button 12 148 100 28 "Add files..."
$removeBtn = New-Control Button 118 148 100 28 "Remove"
$form.Controls.Add($addBtn)
$form.Controls.Add($removeBtn)

$options = New-Control GroupBox 12 186 476 190 "Options"
$form.Controls.Add($options)
$sizeBox = New-Choice $options "Target size:" 24 $SizeChoices 1
$resBox = New-Choice $options "Max resolution:" 56 $ResolutionChoices 2
$qualityBox = New-Choice $options "Quality:" 88 $QualityChoices 0
$audioCheck = New-Control CheckBox 125 118 200 24 "Keep audio"
$audioCheck.Checked = $true
$options.Controls.Add($audioCheck)

$options.Controls.Add((New-Control Label 12 152 110 20 "Save to:"))
$outBox = New-Control TextBox 125 149 230 24 "Same folder as each video"
$outBox.ReadOnly = $true
$options.Controls.Add($outBox)
$browseBtn = New-Control Button 360 148 50 26 "..."
$resetBtn = New-Control Button 414 148 50 26 "Reset"
$options.Controls.Add($browseBtn)
$options.Controls.Add($resetBtn)
$script:outFolder = ""

$openCheck = New-Control CheckBox 12 382 300 24 "Open the folder when done"
$openCheck.Checked = $true
$form.Controls.Add($openCheck)

$status = New-Control Label 12 408 476 20 "Ready."
$progress = New-Control ProgressBar 12 430 370 28
$goBtn = New-Control Button 388 430 100 28 "Compress"
$form.Controls.Add($status)
$form.Controls.Add($progress)
$form.Controls.Add($goBtn)
$form.AcceptButton = $goBtn

$videoFilter = "Videos|*.mp4;*.mov;*.mkv;*.avi;*.webm;*.wmv;*.m4v;*.flv;*.mpg;*.mpeg;*.ts|All files|*.*"

function Add-Files($Paths) {
    foreach ($p in $Paths) {
        if ((Test-Path -LiteralPath $p -PathType Leaf) -and -not $list.Items.Contains($p)) { [void]$list.Items.Add($p) }
    }
}

function Set-Busy([bool]$Busy) {
    $script:busy = $Busy
    foreach ($c in @($list, $addBtn, $removeBtn, $options, $openCheck)) { $c.Enabled = -not $Busy }
    $goBtn.Text = if ($Busy) { "Cancel" } else { "Compress" }
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
    }
    $script:cancel = $false
    Set-Busy $true
    $files = @($list.Items)
    $results = @()
    $folders = @()
    for ($i = 0; $i -lt $files.Count; $i++) {
        $name = [System.IO.Path]::GetFileName($files[$i])
        $status.Text = "Compressing $($i + 1) of $($files.Count): $name"
        $progress.Value = 0
        try {
            $results += "OK      $name - $(Compress-Video $files[$i] $opt)"
            $folders += if ($opt.OutFolder) { $opt.OutFolder } else { Split-Path $files[$i] }
        }
        catch {
            if ($script:cancel) { $results += "STOPPED $name"; break }
            $results += "FAILED  $name - $($_.Exception.Message)"
        }
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
