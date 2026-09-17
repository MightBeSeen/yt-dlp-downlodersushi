***I DO NOT OWN YT-DLP THIS IS JUST A VIBE CODING PROJECT I MADE BECAUSE OF MY LAZINESS***
**Personal used purpose**

**Version:** 2026.09.13b &nbsp;·&nbsp; **Last updated:** 2026-09-13 &nbsp;·&nbsp; **Bundled yt-dlp:** 2026.08.30.232658

Double-click **yt-dlp Downloader.cmd** and follow the terminal prompts.

## Install on a new PC

Download **[Install Seen Downloader.cmd](https://github.com/MightBeSeen/yt-dlp-downlodersushi/raw/refs/heads/main/Install%20Seen%20Downloader.cmd)** and double-click it. One terminal window sets everything up and opens the downloader.

- Supports Windows 10/11 on Intel/AMD 64-bit PCs. Internet access is required.
- Downloads the latest app from this repository's `main` branch, latest stable yt-dlp,
  latest Node.js LTS, and the current FFmpeg essentials release.
- Installs into `%LOCALAPPDATA%\Seen Downloader`, with Desktop and Start menu shortcuts.
- No administrator access, Git, Python, winget, or manual helper installation needed.
- Run the same installer again to update the app and all helpers. Close the downloader
  first. Existing downloads, history, and settings in the install folder are preserved.
- Downloaded helpers are checksum-checked and run-tested before installation. Failed
  downloads leave the existing app intact; a failed file replacement attempts rollback.

Downloads are saved under `%LOCALAPPDATA%\Seen Downloader\Downloads`, sorted by date.
An existing portable copy elsewhere is separate; setup does not migrate its downloads.
The menu's engine-update option still updates only yt-dlp; rerun the installer for a full update.

**Repository access:** the repository must be public for setup without a login. For a
private repository, set `GITHUB_TOKEN` with repository Contents read access before running
setup. The token is used only for this repository's GitHub API requests and is not saved.
The installer must be pushed to `main` before the download link above works.

The portable helper downloads come from [yt-dlp](https://github.com/yt-dlp/yt-dlp#installation),
[Node.js](https://nodejs.org/dist/), and [Gyan's FFmpeg builds](https://www.gyan.dev/ffmpeg/builds/).

## Features

- MP4, MP3, MKV, and AAC output presets.
- Resolution picker for video (Best / 1080p / 720p).
- Playlists and livestream downloads from the start (auto-detected).
- Review the destination and choices before every download; change choices without starting over.
- Background video details never block setup; manual choices appear when details aren't ready.
- Session-only download queue with sequential processing and explicit retry.
- Damaged history rows are skipped with a notice; the original CSV is preserved.
- Per-day download folders and a CSV file-size history.
- In-app engine updates (`yt-dlp -U`) from the menu.
- Optional auto-open: when enabled in **Settings**, Explorer opens with the finished
  download highlighted (setting is saved in `logs\settings.json`).

## Requirements (Windows)

The tool checks these when you start a download and offers setup if something is missing.
The main menu, library, history, and settings remain available without installing helpers:

- A JavaScript runtime — **[Node.js](https://nodejs.org/)** (needed for YouTube and many
  other sites). If it's missing, the tool offers to install it via **winget**.
- **[FFmpeg](https://ffmpeg.org/)** for MP3/AAC audio and high-quality video merges. If it's
  missing, the tool offers to **download a portable copy into this folder** — no install
  needed. Declining setup returns to the menu without starting a download.
- `yt-dlp.exe` is included in the folder.

## Menu

1. Download a video, audio, live, or playlist
2. Download queue
3. View media library sizes
4. View recorded download history
5. Update downloader engine (`yt-dlp -U`)
6. Settings (toggle auto-open after download)
7. Exit

## Download flow

Paste a link, choose format/quality, then live and playlist handling. The final review
shows the destination and resolved choices. Press Enter to start, choose **Change choices**
to edit with the previous selections as defaults, or cancel. No download folder is
created until you confirm. Small terminals use numbered prompts instead of arrow menus.
Review replaces the setup screen and does not wait for video details.

For several links, open **Download queue**, choose **Add link** for each, then **Start queue**.
Items keep their individual choices and reviewed destinations. Failed items stay available
for **Retry failed / interrupted**; ordinary failures do not stop the remaining downloads.
Ctrl+C stops the active download and queue processing, leaving other items pending.
Use **View / remove** to remove items. Closing the app clears the queue.

## Tests

Run both offline suites with `pwsh.exe -NoProfile -File tests/smart-downloader.Tests.ps1`
and `pwsh.exe -NoProfile -File tests/ux.Tests.ps1`. Repeat with `powershell.exe` for
Windows PowerShell 5.1. Tests require Node.js; the existing suite also requires FFmpeg.
The UX suite uses simulated metadata and does not download media.
Also run `tests/menu-render.Tests.ps1` and `tests/queue.Tests.ps1` with both shells.
These cover scrolling/redraws and offline queue execution, including cancellation.
Run `powershell.exe -NoProfile -File tests/installer.Tests.ps1` (or `pwsh.exe`) for
offline installer checks covering checksum rejection, retries, data preservation, and rollback.

---

*The version, last-updated date, and bundled yt-dlp version above are refreshed by the
`/stamp-readme` skill (`.claude/skills/stamp-readme/`) whenever the project changes.*
