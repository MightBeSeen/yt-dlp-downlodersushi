# Changelog

## 2026-09-21 — In-app self-update + winget-free Node.js

- **The app can now update itself.** Menu option 5 ("Update this app + downloader engines")
  first checks the app's own GitHub repo (`MightBeSeen/yt-dlp-downlodersushi`, branch `main`)
  and, when a newer commit exists, downloads the app files, syntax-checks the new script,
  backs up the current ones, and swaps them in atomically (with rollback on any failure),
  then records the commit in `installed-version.txt`. Any network/validation failure leaves
  every file untouched and the engine updates below still run. Reuses the network installer's
  proven staging/backup pattern; only app source files are touched (engine binaries keep
  their own update paths). New: `Update-AppFromGitHub`, `Install-AppFiles`,
  `Get-InstalledRevision`; `Invoke-ReliableDownload` gained an optional `-Headers` param.
- **Node.js install no longer requires winget.** `Install-NodeRuntime` still prefers winget,
  but now falls back to a portable download (`Install-NodePortable`): the official Node LTS
  zip is fetched from nodejs.org, SHA-256 verified against the published `SHASUMS256.txt`, and
  `node.exe` is dropped beside the app (no admin/UAC). Works on locked-down PCs without winget.

## 2026-09-21 — Automatic social routing and simpler folders

- Fixed the mode prompt for X photo links: mode selection previously ignored the URL.
  Social platform links now go directly to the photo/video engine, independent of last mode.
- Media-only is the default; “Entire social post (include manifest)” enables an optional record.
- Social output is now `Downloads/<date>/<platform>/`, without post-ID subfolders, with unique per-request manifest names.
- Offline regression coverage checks X/legacy Twitter routing, folder paths, optional manifests,
  preserved records, and the updated queue prompt sequence. Live X extraction is not covered.

## 2026-09-21 — Multi-platform expansion (yt-dlp + gallery-dl)

Adds an **Entire social post** download mode powered by gallery-dl (Instagram, TikTok, X,
Facebook) alongside the existing yt-dlp video/audio workflow, plus the engine boundary,
authentication, pacing, and platform-hold machinery to support it. Delivered in four phases;
every phase kept the full test suite green under **Windows PowerShell 5.1 and PowerShell 7**.

Test coverage grew from **117 → 200** assertions (2 new suites: `engine-boundary.Tests.ps1`,
`social-engine.Tests.ps1`). All existing yt-dlp behavior is preserved.

### Phase 1 — Engine boundary + flow reorder (no new platforms)

- **`Invoke-MediaProcess`** now takes an `$ExecutablePath` (defaults to yt-dlp, resolved at
  call time) and optional `$WorkingDirectory`, so any engine can run through the same
  process runner with its existing `.cmd`-wrapping, UTF-8, and Ctrl+C handling intact.
- **Per-mode dependency checks:** split `Initialize-DownloadDependencies` into
  `Test-YtDlpReady` / `Test-JsRuntimeReady` / `Test-FfmpegReady`, composed by
  `Resolve-RequestDependencies -Mode`. Video/audio validates yt-dlp + JS runtime + FFmpeg;
  entire-post validates gallery-dl + FFmpeg only. The check moved from the top of
  `New-DownloadRequest` to *after* mode selection.
- **Flow reorder:** URL → mode → account → dependency/hold checks → choices → review. Added
  `Read-DownloadMode` (session-sticky default) and `Read-AccountProfile` (Anonymous default).
- **Probe gating:** the background metadata probe now fires only for anonymous video/audio;
  social and authenticated requests issue no pre-confirmation request.
- **Queue state model:** `Get-QueueStates` (Pending, Downloading, Completed, Partial, Failed,
  Interrupted, Blocked) and `Get-QueueRetryStates` (Partial/Failed/Interrupted — never
  Blocked), centralizing the retry set used by the queue.

### Phase 2 — gallery-dl engine + Entire social post mode

- **Fetch-on-install gallery-dl:** `Install-GalleryDl` downloads the pinned release
  (`Get-GalleryDlRelease` → v1.32.13), verifies SHA-256 when a hash is pinned (Codeberg
  publishes none, so it fingerprints and trusts-on-first-use otherwise), smoke-tests
  `--version`, and only then replaces the existing binary.
- **URL intelligence:** `Get-UrlPlatform`, `Get-PostIdFromUrl` (deterministic, no network),
  and `Test-IsCollectionUrl` — collection/profile/feed/album/stories links are rejected so
  entire-post mode never silently expands beyond one post.
- **Per-run config:** `New-GalleryDlConfigFile` writes a temporary JSON config (pacing, retry
  budgets, optional cookie path, `ffmpeg_location`) and `--config-ignore` prevents any user
  global config from leaking in. Output goes to a flat `-D` destination.
- **Output layout & manifest:** `Downloads/<date>/<platform>/<post-id>/` (falls back to a
  request id when no id is derivable). A versioned `manifest.json` records each **finalized**
  item (order, relative path, size, media type, engine version) written atomically
  (temp-file + move). `expectedCount` is `null` — gallery-dl gives no reliable pre-count.
- **Execution:** `Invoke-SocialPostRequest` runs gallery-dl through the shared runner,
  resolves completed files by folder-diff (images now count), maps outcome via
  `Get-SocialPostStatus` (Completed / Partial / Failed / Blocked / Interrupted), and records
  history using the unchanged CSV columns. `Invoke-DownloadRequest` became a dispatcher;
  the yt-dlp body is now `Invoke-YtDlpRequest`.
- **Library reporting** now includes image extensions.

### Phase 3 — Authentication, pacing, platform holds

- **Cookie-file profiles** (`account-profiles.json`): store only name/platform/path — never
  cookie values. At download time `Resolve-RequestCookiePath` builds a **temporary copy
  filtered to the platform's cookie domains**, restricts it to the current user (`icacls`),
  hands the path to gallery-dl, and deletes it afterward. `Clear-StaleCookieFiles` sweeps
  leftovers at startup. Platform mismatches and unestablishable platforms are refused.
- **Pacing:** Instagram 6–12 s (upstream-documented), other platforms 3–6 s, and 5–10 s
  between queued source URLs (`Get-QueueItemDelaySeconds`). Native retries capped at 2;
  whole-job auto-retry disabled.
- **Platform holds** (`platform-holds.json`, persisted across restarts): a detected
  rate-limit/challenge signal (`Test-BlockingSignal`) stops the download and holds the
  platform across both engines and all accounts. `Test-PlatformHeld` honors a retry-after
  and auto-expires. Holds are checked before building a request and again before execution;
  held queue items are marked `Blocked` while others continue.

### Phase 4 — Installer, menus, diagnostics, docs

- **Installer (`Install Seen Downloader.cmd`)** now stages gallery-dl as a first-class helper:
  a new `[5/6]` step downloads the pinned `gallery-dl.exe`, run-tests it with the other
  helpers (`[6/6]`), writes a `GalleryDl-LICENSE.txt` notice, and includes it in the atomic
  install/rollback set so a bad copy rolls back with the rest. gallery-dl publishes no
  checksum, so it is run-tested rather than hash-verified (the other helpers stay
  checksum-verified). Progress text renumbered `[1/6]`…`[6/6]`; pinned version is kept in
  sync with `Get-GalleryDlRelease`.
- **Settings menu** gained *Manage account profiles* (add/remove) and *Review blocked
  platforms* (release honoring retry-after; releasing never starts a download).
- **Engine update** now updates both yt-dlp (`-U`) and gallery-dl (to the tested pinned
  release), showing installed vs. pinned versions. Main-menu labels updated.
- **Docs:** `docs/social-post-support.md` (support matrix, auth guide, limits, and a
  per-platform live-qualification checklist with a per-platform release gate).
- README stamped and feature list updated.

### Notes / follow-ups

- **Live qualification is still required** before advertising any platform as supported —
  the offline suite proves the machinery; real success depends on each post, region, login
  state, and the platform's current anti-automation behavior.
- gallery-dl's SHA-256 is not pinned (no official checksum); set `Get-GalleryDlRelease.Sha256`
  once a trusted hash is recorded to enforce strict verification.
