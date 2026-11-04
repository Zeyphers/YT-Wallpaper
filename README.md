# YT Wallpaper

A tiny macOS menu bar app that streams YouTube videos as your desktop wallpaper.

- Copy a YouTube link (video or playlist), click **Paste YouTube link** in the menu bar
- Thumbnails and titles for each video; click one to play it
- Crop to fill / Fit / Stretch, resolution 480p–4K (2K/4K when the video has it), shuffle
- Muted, one hardware-decoded H.264 stream shared across all displays, 30s buffer cap
- Pauses while the screen is asleep or locked; resumes where it left off when YouTube's stream link expires

## Install

Needs macOS 13+, Xcode command line tools and [yt-dlp](https://github.com/yt-dlp/yt-dlp):

```bash
brew install yt-dlp deno
./build.sh
```

`build.sh` compiles `main.swift` and copies **YT Wallpaper.app** to `/Applications`.
