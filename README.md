# Seen's yt-dlp Downloader

A Windows menu app for downloading video, audio, playlists, livestreams, and supported social posts.

**Version:** 2026.09.22 &nbsp;·&nbsp; **Last updated:** 2026-09-22 &nbsp;·&nbsp; **yt-dlp:** downloaded and verified during setup

## Install

1. **[Download Install Seen Downloader.cmd](https://github.com/MightBeSeen/yt-dlp-downlodersushi/raw/refs/heads/stable/Install%20Seen%20Downloader.cmd)** and save it to your PC.
2. Double-click it. Setup downloads the app and its helpers, creates shortcuts, and opens the app.
3. Paste a link and follow the menu. Files are saved in the app's `Downloads` folder.

Requires an internet connection and Windows 10/11 on an Intel/AMD 64-bit PC.
No administrator access, Python, Node.js, winget, or PowerShell 7 installation is needed.
The app installs in `%LOCALAPPDATA%\Seen Downloader`.

Setup shows downloaded MB, verifies the helper files, and tries an alternate FFmpeg
source when necessary. If it cannot finish, rerun the installer. Details are saved
in `%LOCALAPPDATA%\Seen Downloader\logs\setup-*.log`.

## Updates

The app checks for updates when opened and offers **Update now and restart** or
**Later**. The check waits at most three seconds; being offline does not prevent use.
Turn it off in **Settings → Check for app updates at startup** if preferred.

**Menu 5: Update / repair app and download helpers** checks the app, yt-dlp, Node.js,
FFmpeg/ffprobe, and gallery-dl together. You can also rerun the standalone installer.
Unchanged verified helpers are reused. Downloads, history, account profiles, and
settings are preserved. Updating restarts the app; a nonempty session queue requires
confirmation because it is not saved across restarts.

**Already using an older version?** Select its existing **Update** option once, then
close and reopen the app. That installs the new startup-check feature. Alternatively,
run the latest installer above. An old app cannot gain automatic checking until updated.

## What it does

- MP4/MKV video, MP3/AAC audio, quality limits, playlists, and live-from-start options.
- Sequential download queue with cancellation and retry.
- Media library sizes and download history.
- Photos and videos from supported single social-post URLs through gallery-dl.
- Optional account profiles using user-provided Netscape cookie files.

Social-site availability depends on the site, account access, and upstream engines.
See [social-post support](docs/social-post-support.md) for the supported URL forms and limits.

## Development and publishing

Push changes to `main`. [GitHub Actions](https://github.com/MightBeSeen/yt-dlp-downlodersushi/actions)
runs the offline test suite on Windows PowerShell 5.1 and PowerShell 7. **Only a passing
commit advances `stable`, the branch used by the installer and startup updater.**
No manual version URL or release upload is needed for each update.

The distributed app and installer remain self-contained, including for upgrades from
old versions. Shared installer/update workers live in `lib/update-core.ps1` and are
embedded in both files by a small build script:

```powershell
.\scripts\Sync-UpdateCore.ps1
.\scripts\Test-Project.ps1 -Engine powershell
.\scripts\Test-Project.ps1 -Engine pwsh
```

Development tests need Node.js on PATH. They do not download media or require real
social accounts. Helper EXEs, personal data, and test output are excluded from Git;
the installer obtains the binaries from their publishers. Do not edit generated core
blocks directly. See [project structure](CONTEXT.md) and [publishing guide](docs/publishing.md).

## Credits

This is a personal project built around [yt-dlp](https://github.com/yt-dlp/yt-dlp),
[gallery-dl](https://github.com/mikf/gallery-dl), [FFmpeg](https://ffmpeg.org/), and
[Node.js](https://nodejs.org/). I do not own these projects. Their respective licenses apply.
