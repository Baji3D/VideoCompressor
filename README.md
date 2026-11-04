# Video Compressor

Compresses videos to a target file size (8 MB, 10 MB, 25 MB...) straight from the Windows right-click menu. Uses the NVIDIA GPU encoder when available, so most clips take seconds. Falls back to the CPU on other machines.

## Setup

1. **Get ffmpeg.** Download the "full" or "essentials" build from https://www.gyan.dev/ffmpeg/builds/ and put `ffmpeg.exe` and `ffprobe.exe` in the `ffmpeg` folder. (They aren't in the repo because they're too large.)
2. Double-click **Install.bat**. No admin rights needed.

## Use

Right-click any video and choose **Video Compressor**. On Windows 11, choose **Show more options** first.

- **Compress to 8 / 10 / 25 / 50 MB**: compresses right away and saves `name_compressed.mp4` next to the original.
- **Custom target size...**: asks for a size in MB, then compresses.
- **Advanced...**: opens the full window with resolution, quality, audio and output-folder options.

The full window is also in the Start Menu as **Video Compressor**.

## Uninstall

Settings > Apps > Video Compressor > Uninstall.

## Files

| File | What it does |
|---|---|
| `compress.ps1` | The app: the full window, plus quick mode for the right-click menu |
| `launch.vbs` | Starts the app without a console window flashing up |
| `install.ps1` / `Install.bat` | Copies the app to `%LOCALAPPDATA%\Programs\VideoCompressor` and adds the right-click menu |
| `uninstall.ps1` | Removes everything the installer added |
