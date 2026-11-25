# Installs Video Compressor for the current user (no admin needed):
#   - copies the app to %LOCALAPPDATA%\Programs\VideoCompressor
#   - adds a "Video Compressor" submenu when right-clicking video files
#   - adds a Start Menu shortcut and an entry in Settings > Apps for uninstalling

$ErrorActionPreference = "Stop"
$src = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA "Programs\VideoCompressor"

New-Item -ItemType Directory -Force (Join-Path $dest "ffmpeg") | Out-Null
foreach ($f in "compress.ps1", "launch.vbs", "uninstall.ps1", "icon.ico") { Copy-Item (Join-Path $src $f) $dest -Force }
Copy-Item (Join-Path $src "ffmpeg\*") (Join-Path $dest "ffmpeg") -Force
# oiiotool + ACES OCIO config for correct EXR colour (optional; without them EXR gets a plain sRGB curve).
foreach ($d in "oiio", "ocio") {
    if (Test-Path (Join-Path $src $d)) {
        New-Item -ItemType Directory -Force (Join-Path $dest $d) | Out-Null   # copy contents, so reinstalling doesn't nest oiio\oiio
        Copy-Item (Join-Path $src "$d\*") (Join-Path $dest $d) -Recurse -Force
    }
}

$launch = "wscript.exe `"$dest\launch.vbs`""
$icon = Join-Path $dest "icon.ico"
$sizes = 8, 10, 25, 50
$extensions = ".mp4", ".mov", ".mkv", ".avi", ".webm", ".wmv", ".m4v", ".flv", ".mpg", ".mpeg", ".mts", ".m2ts", ".3gp",
    ".exr", ".dpx", ".png", ".tif", ".tiff", ".tga"   # image sequence frames (same menu)

function Set-Key([string]$Path, [hashtable]$Values) {
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($Path)
    foreach ($name in $Values.Keys) { $key.SetValue($name, $Values[$name]) }
    $key.Close()
}

foreach ($ext in $extensions) {
    $menu = "Software\Classes\SystemFileAssociations\$ext\shell\VideoCompressor"
    Set-Key $menu @{ MUIVerb = "Video Compressor"; SubCommands = ""; Icon = $icon }
    $i = 0
    foreach ($mb in $sizes) {
        $i++
        Set-Key "$menu\shell\$i-$mb" @{ MUIVerb = "Compress to $mb MB" }
        Set-Key "$menu\shell\$i-$mb\command" @{ "" = "$launch -Quick $mb `"%1`"" }
    }
    Set-Key "$menu\shell\8-gif" @{ MUIVerb = "Make GIF (under 10 MB)"; CommandFlags = 0x20 }   # separator above
    Set-Key "$menu\shell\8-gif\command" @{ "" = "$launch -Gif -Quick 10 `"%1`"" }
    $hkcu = [Microsoft.Win32.Registry]::CurrentUser
    $hkcu.DeleteSubKeyTree("$menu\shell\9-more", $false)   # replaced by 9-custom in this version
    Set-Key "$menu\shell\9-custom" @{ MUIVerb = "Custom target size..."; CommandFlags = 0x20 }
    Set-Key "$menu\shell\9-custom\command" @{ "" = "$launch -Ask `"%1`"" }
    Set-Key "$menu\shell\a-advanced" @{ MUIVerb = "Advanced..." }   # "a-" sorts after "9-"
    Set-Key "$menu\shell\a-advanced\command" @{ "" = "$launch `"%1`"" }
}

# Start Menu shortcut to the full window.
$shell = New-Object -ComObject WScript.Shell
$lnk = $shell.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Programs")) "Video Compressor.lnk"))
$lnk.TargetPath = "wscript.exe"
$lnk.Arguments = "`"$dest\launch.vbs`""
$lnk.IconLocation = $icon
$lnk.Save()

Set-Key "Software\Microsoft\Windows\CurrentVersion\Uninstall\VideoCompressor" @{
    DisplayName = "Video Compressor"
    Publisher = $env:USERNAME
    InstallLocation = $dest
    DisplayIcon = $icon
    UninstallString = "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$dest\uninstall.ps1`""
    NoModify = 1
    NoRepair = 1
}

Write-Host "Installed to $dest"
Write-Host "Right-click any video > Video Compressor > Compress to 10 MB  (on Windows 11: Show more options first)"
