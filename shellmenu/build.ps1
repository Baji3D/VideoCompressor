# Builds the Windows 11 right-click menu: VideoCompressorMenu.dll, VideoCompressor.exe and the
# package logos in Assets\. The results are committed, so installing needs none of this;
# rebuild only after changing the .cpp files or icon.png.
# Needs Visual Studio Build Tools (C++).

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
$obj = Join-Path $env:TEMP "VideoCompressorMenu-build"
New-Item -ItemType Directory -Force $obj | Out-Null

# MSVC environment
$vs = & "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe" -latest -products * `
    -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $vs) { throw "Visual Studio C++ build tools not found." }
$vcvars = Join-Path $vs "VC\Auxiliary\Build\vcvars64.bat"

$flags = "/nologo /O2 /MT /W3 /EHsc /DUNICODE /D_UNICODE /Fo`"$obj\\`""
$cmd = "`"$vcvars`" >nul 2>nul && cd /d `"$here`" && " +
    "cl $flags /LD VideoCompressorMenu.cpp /Fe:VideoCompressorMenu.dll /link /DEF:VideoCompressorMenu.def /IMPLIB:`"$obj\menu.lib`" shlwapi.lib shell32.lib ole32.lib user32.lib && " +
    "cl $flags VideoCompressor.exe.cpp /Fe:VideoCompressor.exe /link /SUBSYSTEM:WINDOWS shlwapi.lib shell32.lib user32.lib"
cmd /c $cmd
if ($LASTEXITCODE) { throw "Compile failed." }

# Package logos (the manifest requires them).
$assets = Join-Path $here "Assets"
New-Item -ItemType Directory -Force $assets | Out-Null
Add-Type -AssemblyName System.Drawing
$src = [System.Drawing.Image]::FromFile((Join-Path $here "..\icon.png"))
foreach ($a in @{ n = "StoreLogo"; s = 50 }, @{ n = "Square44x44Logo"; s = 44 }, @{ n = "Square150x150Logo"; s = 150 }) {
    $bmp = New-Object System.Drawing.Bitmap $a.s, $a.s
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.InterpolationMode = "NearestNeighbor"   # pixel art
    $g.PixelOffsetMode = "Half"
    $g.DrawImage($src, 0, 0, $a.s, $a.s)
    $g.Dispose()
    $bmp.Save((Join-Path $assets "$($a.n).png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}
$src.Dispose()
Write-Host "Built VideoCompressorMenu.dll, VideoCompressor.exe and Assets\"
