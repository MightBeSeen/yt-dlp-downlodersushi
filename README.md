# Seen's yt-dlp Downloader

**Version:** 2026.08.30b &nbsp;·&nbsp; **Last updated:** 2026-08-30 &nbsp;·&nbsp; **Bundled yt-dlp:** 2026.08.18.122307

Double-click **Seen's yt-dlp Downloader.cmd** and follow the terminal prompts.

## Features

- MP4, MP3, MKV, and AAC output presets.
- Resolution picker for video (Best / 1080p / 720p).
- Playlists and livestream downloads from the start (auto-detected).
- Per-day download folders and a CSV file-size history.
- In-app engine updates (`yt-dlp -U`) from the menu.
- Optional auto-open: when enabled in **Settings**, Explorer opens with the finished
  download highlighted (setting is saved in `logs\settings.json`).

## Requirements (Windows)

The tool can set these up for you on first run — if something is missing it offers to
install it automatically:

- A JavaScript runtime — **[Node.js](https://nodejs.org/)** (needed for YouTube and many
  other sites). If it's missing, the tool offers to install it via **winget**.
- **[FFmpeg](https://ffmpeg.org/)** for MP3/AAC audio and high-quality video merges. If it's
  missing, the tool offers to **download a portable copy into this folder** — no install
  needed. (Decline and video-only downloads still work.)
- `yt-dlp.exe` is included in the folder.

## Menu

1. Download a video, audio, live, or playlist
2. View media library sizes
3. View recorded download history
4. Update downloader engine (`yt-dlp -U`)
5. Settings (toggle auto-open after download)
6. Exit

---

*The version, last-updated date, and bundled yt-dlp version above are refreshed by the
`/stamp-readme` skill (`.claude/skills/stamp-readme/`) whenever the project changes.*
