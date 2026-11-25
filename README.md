<p align="center"><img src="icon.png" width="160" alt="Video Compressor icon: a pixel-art hydraulic press"></p>

# Video Compressor

Compresses videos to a target file size (8 MB, 10 MB, 25 MB...) straight from the Windows right-click menu. Uses the NVIDIA GPU encoder when available, so most clips take seconds. Falls back to the CPU on other machines.

## Setup

1. **Get ffmpeg.** Download the "full" or "essentials" build from https://www.gyan.dev/ffmpeg/builds/ and put `ffmpeg.exe` and `ffprobe.exe` in the `ffmpeg` folder. (They aren't in the repo because they're too large.)
2. **For EXR colour (optional):** copy the `oiio` and `ocio` folders from `vfx-transcode` (`D:\workgroup\utils\vfx-transcode`) into this folder. Without them, EXR sequences still work but get a plain sRGB curve, not the ACES look.
3. Double-click **Install.bat**. No admin rights needed.

## Use

Right-click any video and choose **Video Compressor**. On Windows 11, choose **Show more options** first.

- **Compress to 8 / 10 / 25 / 50 MB**: compresses right away and saves `name_compressed.mp4` next to the original.
- **Make GIF (under 10 MB)**: turns the video into an animated GIF (`name.gif`, up to 480p at 15 fps), shrinking it further if needed to stay under 10 MB.
- **Custom target size...**: asks for a size in MB, then compresses.
- **Advanced...**: opens the full window with format (MP4 or GIF), resolution, quality, audio and output-folder options.

The full window is also in the Start Menu as **Video Compressor**.

### Image sequences (EXR, DPX, PNG, TIFF, TGA)

Right-click **any one frame** of a numbered sequence (like `shot_v01.1001.exr`) and use the same menu. The whole sequence becomes `shot_v01.mp4` or `shot_v01.gif` at 25 fps (change `$SequenceFps` at the top of `compress.ps1` for another rate). EXR frames are treated as ACEScg and converted through the ACES 1.2 OCIO config to **Output - sRGB**, the same as `vfx-transcode --colorout out_srgb`, so they look like they do in Nuke/Maya. The MP4 is tagged Rec.709 like vfx-transcode's. If a frame is missing, the video stops there and the result says how many frames were left out. In the full window, dropping all the frames adds the sequence once, shown as `shot_v01.####.exr`.

## Uninstall

Settings > Apps > Video Compressor > Uninstall.

## Files

| File | What it does |
|---|---|
| `compress.ps1` | The app: the full window, plus quick mode for the right-click menu |
| `launch.vbs` | Starts the app without a console window flashing up |
| `install.ps1` / `Install.bat` | Copies the app to `%LOCALAPPDATA%\Programs\VideoCompressor` and adds the right-click menu |
| `uninstall.ps1` | Removes everything the installer added |
