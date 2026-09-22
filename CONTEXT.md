# Project map

## Runtime and distribution

`Yt-dlp Downloader.cmd` is the launcher. It prefers PowerShell 7, falls back to
Windows PowerShell 5.1, and reloads the app on the reserved update exit code 42.

`smart-downloader.ps1` is the self-contained interactive app. Keeping it self-contained
is deliberate: the legacy updater downloads only four fixed files, so adding a required
runtime module would break upgrades for existing users. Functions are grouped into:

| Area | Main entry points and responsibilities |
| --- | --- |
| UI | `Show-MainMenu`, `Read-MenuChoice`, download question/review flow; arrows with numbered fallback |
| Video/audio | `New-DownloadRequest` → `Invoke-YtDlpRequest`; asynchronous optional metadata and cancellable native processes |
| Social posts | `Get-UrlPlatform`, `New-SocialPostRequest`, `Invoke-SocialPostRequest`; gallery-dl config, media tracking, optional manifests |
| Queue | `Show-DownloadQueue`, `Start-DownloadQueue`; session-only requests, retry states, platform holds |
| Library/history | `Get-MediaFiles`, `Resolve-CompletedFiles`, history CSV and paged views |
| Settings/accounts | JSON stores under logs, platform-filtered temporary cookie copies, persisted platform holds |
| Updates | `Invoke-StartupUpdateCheck` → `Update-DownloaderEngine` → `Invoke-InstallerUpdate`; fresh child process runs the checked revision's installer |

`Install Yt-dlp Downloader.cmd` has a CMD wrapper and an embedded PowerShell body. It
resolves `stable` to a commit, stages the app and all helper binaries, checks hashes
and executable startup, and installs with rollback on handled copy failures. It also
creates shortcuts and launches the app for fresh installs. The in-app updater runs
the same body with `-NoLaunch -NoShortcuts -AppRevision <checked-commit>`.

`lib/update-core.ps1` owns the shared network, checksum, cache, executable-check, and
copy/rollback workers. `scripts/Sync-UpdateCore.ps1` embeds it into both deliverables;
CI checks the generated blocks are current. No external module must be downloaded
before an upgraded app can launch.

## Data and ownership

- App files/helpers: installation directory; `installed-version.txt` records its commit.
- `installed-helpers.json`: package identities and local hashes for safe helper reuse.
- `Downloads/`: media, organized by date and social platform where applicable.
- `logs/`: history, settings, account profile paths, platform holds, and setup transcripts.
- `.setup.lock`: exclusive lock shared by installer and in-app helper/update operations.
- `.setup-<guid>/`: unique staging area, removed after normal success/failure.
- Temp cookies: PID-scoped files under Windows TEMP; live owners are not swept.
- `.test-temp/`: ignored test artifacts; never part of distribution.

Tests use AST loading to exercise real functions without entering the menu. Native
process tests use Node.js and fake engines. Installer-flow tests run the actual main
flow in child processes with fixture transport and helper probes. Network tests use a
local streaming HTTP server. Real download/VM tests remain separate from offline CI.

## Change boundaries

Preserve user data during updates. Keep app payloads pinned to a single commit. Both
setup entry points must use the same helper versions and hashes. Keep generated core
blocks synchronized. A fresh process must load new update code before refreshing
helpers, and the app must restart rather than continue with stale loaded functions.
Maintain PowerShell 5.1 compatibility. No admin-only helper installation is required.
