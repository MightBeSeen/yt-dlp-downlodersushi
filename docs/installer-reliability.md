# Installer stall investigation — 2026-09-21

The installer displayed “50% node.js / Downloading FFmpeg” on both the host and a VM.
That percentage counted completed setup stages, not bytes downloaded. The FFmpeg
request was synchronous, all PowerShell download progress was disabled, and each
attempt had a 300-second timeout. It retried the same URL three times, restarting
the entire ZIP without an alternate source. Extraction was also silent.

## Evidence and experiment ledger

1. Read the original installer and its tests. Existing tests mocked the HTTP call;
   they covered retry count, checksums, and copy rollback, but never a slow transfer.
2. Inspected the existing host staging folder without changing it. Its `ffmpeg.zip`
   was 8,658,693 bytes, with its last write five minutes after the staging folder's
   creation. This is consistent with an incomplete timed-out transfer; it does not
   prove the exact network conditions during either screenshot.
3. Requested the real gyan.dev ZIP headers outside the network sandbox. The server
   returned HTTP 503 and `Retry-After: 600`. This establishes source unavailability
   during this investigation, not necessarily throughout the earlier install.
4. Ran `powershell.exe -NoProfile -ExecutionPolicy Bypass -File tests/installer-network.Tests.ps1`
   against the original worker. A local server streamed a 1 MiB body over four seconds.
   The byte-count check passed; the activity-output check failed. This reproduces
   the frozen-looking UI even when the network is healthy and making progress.
5. Switched to streamed .NET HTTP reads with visible byte counts, an inactivity
   deadline, an overall deadline, and partial-file cleanup. The same test passed.
   The local server additionally exercises unavailable, truncated, and stalled responses.
6. Verified FFmpeg's current GitHub release metadata includes an essentials ZIP
   with a SHA256 digest. The GitHub source successfully downloaded and verified
   the real 109.5 MiB ZIP. Tests separately force source unavailability and checksum
   mismatch to check the independently verified gyan.dev fallback.
7. Completed a real installation into an empty folder under Windows PowerShell 5.1.
   All five helpers ran: yt-dlp, Node.js, FFmpeg, ffprobe, and gallery-dl. No preinstalled
   helper, Python, winget, or PowerShell 7 is required by the installer.
8. Reinstalled into that folder under PowerShell 7 and checked that sentinel files
   in Downloads and logs survived. The staging folder was removed and the setup
   lock could be reopened exclusively after completion.
9. Launched the installed CMD with PATH restricted to Windows system directories.
   It fell back to Windows PowerShell and reached the main menu successfully.
   Both video/audio and social-post dependency checks passed using bundled helpers.
10. All eight `*.Tests.ps1` suites passed under each of Windows PowerShell 5.1 and
    PowerShell 7 (16 successful suite runs).

## Fix and validation boundaries

This records the initial installer fix. The subsequent [project audit](project-audit.md)
adds a shared update core, tested stable channel, helper reuse, and a pinned gallery-dl
SHA256; the original gallery-dl verification limitation below has therefore been addressed.

`Install Yt-dlp Downloader.cmd` remains a standalone double-click installer using
Windows' built-in PowerShell/.NET. Downloads report activity every two seconds,
abort after 45 seconds without data, and allow up to 30 minutes per attempt. Generic
downloads retry three times; FFmpeg tries each publisher host once. Integrity checks
remain mandatory for yt-dlp, Node.js, and FFmpeg. gallery-dl retains the existing
pinned version and executable smoke check; it has no published checksum in this flow.

Installation still stages all files and checks every helper before replacing the
existing app. Copy failures roll back; existing downloads and settings are preserved.
Version probes now have a deadline. Setup writes `logs/setup-*.log` and releases its
lock and temporary files before opening the interactive app.

The network fixture needs no internet and runs under PowerShell 5.1 and 7. The
installer unit suite also checks retry exhaustion, partial-file cleanup, checksums,
source fallback, helper failure/timeouts, data preservation, and copy rollback.
Live checks use isolated test folders; they are not a fresh-VM or website-download
certification. Both publisher hosts can still be unavailable, in which case setup
fails with a saved log and rerun instructions. Interrupted downloads restart rather
than resume. Local changes must be published before newly downloaded GitHub installers
include the fix.
