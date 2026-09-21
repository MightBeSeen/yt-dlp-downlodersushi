# Seen Downloader: Local Multi-Platform Expansion

**Status:** Implementation plan, revised after self-review. No implementation is included in this document.
**Research date:** 2026-09-21

## 1. Goal, research, and decisions

Expand the existing Windows terminal application to download individual videos, photos, and mixed-media posts from **Instagram, TikTok, X, and Facebook**, while retaining existing yt-dlp functionality.

Use:

- **yt-dlp** for the existing video/audio workflow.
- **gallery-dl** for entire social posts.
- **FFmpeg** for required merging and existing conversions.
- Explicit local cookie profiles for content requiring account access.

Keep Windows PowerShell 5.1 and PowerShell 7 support. Preserve the portable launcher, installer, sequential queue, history, and existing output presets.

### Why this combination

gallery-dl adds photo and multi-item capabilities across the four priority platforms. Its supported-site list establishes intended coverage, not guaranteed success for every post or URL form. [Supported sites](https://gdl-org.github.io/docs/supportedsites.html)

Cobalt uses its own extraction implementations, but its website is not an unrestricted API for other applications. Integration requires an authorized instance or self-hosting. Running it locally would add service-management work without removing platform blocking. Exclude it from this release. [Cobalt overview](https://github.com/imputnet/cobalt/blob/main/api/README.md), [API access requirements](https://github.com/imputnet/cobalt/blob/main/docs/api.md)

gallery-dl's Windows package embeds yt-dlp for some video operations. This means it provides complementary extraction paths, but is not universally an independent fallback. Updating the separate `yt-dlp.exe` does not update the embedded module. [Build hook](https://codeberg.org/mikf/gallery-dl/src/tag/v1.32.13/scripts/hook-gallery_dl.py), [Pinned dependencies](https://codeberg.org/mikf/gallery-dl/src/tag/v1.32.13/requirements/windows)

### Account and IP risk

Local downloading can still trigger IP blocks, account challenges, and account restrictions. There is no established safe frequency or trustworthy numerical ban probability.

YouTube members-only downloads require an account entitled to the content. yt-dlp explicitly warns that authenticated use can lead to temporary or permanent bans. [Account guidance](https://github.com/yt-dlp/yt-dlp/wiki/Extractors#exporting-youtube-cookies)

A maintainer reports YouTube restrictions lasting hours to months and warns of permanent bans on Instagram/Facebook. These are maintainer observations, not measured incidence rates. [YouTube observations](https://github.com/yt-dlp/yt-dlp/issues/15724#issuecomment-3814489846), [Instagram/Facebook warning](https://github.com/yt-dlp/yt-dlp/issues/15724#issuecomment-3814500308)

**Account policy:** anonymous by default; use a selected local account only when explicitly requested. Never activate credentials automatically after a failure.

### Scope boundaries

Include individual posts, reels, slideshows, and attached media. Preserve existing video playlists and live-download features.

Exclude profile archiving, feeds, comments, quoted-post expansion, automatic login, hosted services, new live-recording engines, and automatic cross-engine fallback.

## 2. Self-review findings and corrections

**Review verdict:** the engine choice remains appropriate, but the original plan left important integration behavior undefined. The corrections below are incorporated into this revision.

Code references describe the source inspected on the research date; line numbers may move during implementation.

### Major: dependency checks happen too early

The current request builder checks dependencies before collecting choices, and queue startup checks dependencies globally. The dependency function requires yt-dlp, a JavaScript runtime, and FFmpeg together.

Evidence: `New-DownloadRequest` at `smart-downloader.ps1:1093`, `Start-DownloadQueue` at `smart-downloader.ps1:1500`, and `Initialize-DownloadDependencies` at `smart-downloader.ps1:1848`. [Source](../../smart-downloader.ps1)

**Correction:** select mode and authentication first. Validate dependencies per queued request. Entire-post mode requires gallery-dl and FFmpeg, but not the separate yt-dlp executable or Node.js.

### Major: background probing conflicts with account selection

The current request builder immediately starts metadata extraction after receiving the URL. Adding account selection later would allow an unintended preliminary request and potentially duplicate extraction.

**Correction:** decide authentication and check platform holds before any probe. Disable pre-confirmation extraction for the four social platforms and all authenticated requests. Retain existing nonblocking metadata only for other anonymous video/audio requests.

### Major: queue outcomes were named but not defined

The current queue retries only `Failed` and `Interrupted`. Adding blocked or partial outcomes without changing retry selection, counts, and scheduling would strand work or retry it incorrectly.

**Correction:** define one outcome model and use it consistently in execution, queue menus, history, and retry handling.

### Major: completion and missing-item retry were overpromised

Exit status and discovered files cannot establish that an extractor found every attachment. "Retry missing items" also requires stable identities and persisted records.

**Correction:** distinguish successful extraction from verified attachment counts. Resume only using established item identities; otherwise preserve files and report the limitation.

### Major: retry limits were not enforceable as written

A wrapper-level retry count does not control retries inside gallery-dl, embedded yt-dlp, fragment downloads, or extractor-specific logic.

**Correction:** avoid whole-job automatic retries, configure native retry budgets explicitly, and test the actual child-process behavior. Describe pacing as mitigation rather than a strict bound on every upstream HTTP request.

### Scope improvement: remove alternate-engine retry prompts

The first release does not need an additional fallback interface. It complicates authentication, duplicate prevention, quality guarantees, and post completeness.

**Correction:** route by mode. Users may start a separately reviewed request in another mode, but failures do not trigger engine cycling.

## 3. User behavior and implementation contract

### Download flow

Use this sequence:

1. Paste URL and validate HTTP/HTTPS syntax.
2. Choose **Video / audio** or **Entire social post**.
3. Choose **Anonymous** or an explicitly configured account profile.
4. Check platform hold and required dependencies.
5. Collect applicable format, quality, playlist, and live choices.
6. Review destination, mode, authentication, and available details.
7. Confirm download or add the request to the queue.
8. Recheck holds, credentials, and dependencies immediately before execution.

Default to Video / audio. Remember the last mode only for the current session. Authentication defaults to Anonymous for each new request.

Review must remain responsive. Unknown titles/counts are displayed as unknown; they do not prevent confirmation. No media destination is created until execution.

### Mode behavior

| Mode | Engine | Output contract |
|---|---|---|
| Video / audio | yt-dlp | Existing presets, quality choices, playlist/live behavior |
| Entire social post | gallery-dl | All supported attachments from one post, in source order, using available source formats |

Entire-post mode does not offer resolution limits or audio conversion. It must not silently expand to an account, album, feed, replies, or quoted post.

Known collection URLs are rejected. Share links may be resolved after confirmation, but the resulting extraction must still match an approved single-post extractor.

### Platform targets

| Platform | Qualification cases |
|---|---|
| Instagram | Reel, photo, video, mixed carousel |
| TikTok | Video, photo slideshow, short/share link |
| X | Photo post, video post, multiple attachments |
| Facebook | Video/reel, photo, supported multi-photo single-post forms |
| YouTube | Existing public workflows; explicitly selected members-only access |

Facebook URL variants that cannot reliably remain within one post are unavailable in Entire social post mode. Do not substitute a profile or album extraction.

### Internal engine boundary

Keep the initial refactor within the current script to preserve the existing function-based test loading. Do not build a general plugin framework.

Introduce helpers for:

- Engine capability and dependency checks.
- Argument/configuration construction.
- Process execution with an explicit executable path.
- Output-event and error normalization.
- Completed-item recording.

Use request fields for request ID, URL, platform, mode, engine, existing choices, destination, and optional credential-profile ID.

Use result fields for status, error category, exit code, completed items, expected item count when known, enumeration-finished flag, interruption state, and engine versions.

Each completed item records its source identity when available, post order, media type, final path, and extraction/downloader provenance.

### gallery-dl video handling

Use the embedded yt-dlp integration where required. Point it at the packaged FFmpeg directory.

- Instagram: retain its normal DASH-capable video mode.
- Facebook: use documented delegated video handling for merged playback output.
- TikTok: retain direct downloading where supported.

Record embedded yt-dlp provenance so diagnostics do not misrepresent the operation as fully independent. [Configuration reference](https://gdl-org.github.io/docs/configuration.html)

### Authentication

For v1, support user-supplied Netscape-format cookie files, not automatic browser-cookie extraction.

An account profile contains only a friendly name, platform, and cookie-file path. Do not store cookie values in settings, history, or manifests.

At execution:

- Confirm the selected profile matches the recognized platform.
- Validate the file locally.
- Create a temporary working copy containing platform-relevant cookie domains.
- Restrict its permissions to the current user and required system access.
- Preserve cookie domain/path/expiry semantics.
- Pass its path to the engine without printing contents.
- Delete it after success, failure, or cancellation.

Remove stale application-owned temporary credential files at startup. Do not modify the user's original cookie file.

Reject authenticated requests whose platform cannot be established. Never forward account credentials to an arbitrary generic URL.

Provide local cookie-file setup instructions and a short authenticated-use warning. Browser login and cookie export remain user actions. [Cookie-file documentation](https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp)

### Request pacing and blocking

Run one extraction/download job globally, including metadata work.

Default pacing:

- gallery-dl Instagram extraction: preserve 6–12 seconds.
- Other priority platforms: configure 3–6 seconds where native controls support it.
- Between queued source URLs: 5–10 seconds.
- Do not delay every media chunk as though it were a new extraction request.

The Instagram value is documented upstream; other values are product defaults, not safety thresholds. [Delay controls](https://gdl-org.github.io/docs/configuration.html#extractor-sleep-request)

Disable automatic whole-job retries. Configure supported native transient and fragment retries to at most two, and disable configurable retries for blocking responses.

When a detectable rate-limit or account-challenge signal appears:

- Stop the owned child-process tree.
- Record any confirmed completed media.
- Hold that platform across engines and account profiles.
- Continue unrelated queue items.
- Persist the hold across application restarts.

No wrapper can guarantee interception before an engine emits its error. Tests must verify the observable stop behavior; documentation must not promise zero additional in-flight requests.

Release holds only through **Review blocked platforms**. Honor a known retry-after time before allowing release. Releasing a hold does not automatically start downloads.

## 4. Results, persistence, packaging, and delivery

### Queue state model

| State | Meaning and retry behavior |
|---|---|
| Pending | Ready to run when dependencies and platform permit |
| Downloading | Active request |
| Completed | Extraction ended successfully and all reported items are accounted for |
| Partial | Some items completed, but extraction/download failed or completeness remains uncertain |
| Failed | No completed items and a non-blocking failure |
| Interrupted | User cancellation; stop queue processing |
| Blocked | Platform hold prevents execution |

**Retry failed / interrupted** includes Partial, Failed, and Interrupted. It does not clear platform holds.

If an extractor reports no expected count, Completed means all items it enumerated succeeded—not proof that the website contains no additional attachments. Display the downloaded count and omit unsupported completeness claims.

### Output and retry records

Keep existing video/audio destinations.

Entire-post output uses:

`Downloads/<date>/<platform>/<post-id>/`

Use source item IDs and ordinal numbers for filenames. If the post ID is initially unknown, use the request ID until extraction establishes identity; do not derive directories from unrestricted remote titles.

Store a versioned per-request manifest containing:

- Source identity and mode.
- Item identity/order.
- Final relative path and size.
- Completion state and engine versions.
- Expected count when available.

Write manifests atomically. Record an item only after finalization, never from a `.part` file or merge intermediate.

Retry within the original destination. Skip recorded items only when their final file still exists with matching recorded size. Missing or changed files are downloaded again.

When stable item identity is unavailable, do not guess from filenames or signed CDN URLs. Preserve existing output and explain that selective resume is unavailable.

Keep the CSV history columns unchanged; use manifests for new detail. Add image files to library reporting. New gallery output must be identified through completion events and manifests, not an unrestricted shared-folder snapshot.

### Installer and updates

Add a tested gallery-dl Windows x64 release to a version/hash manifest. Fetch binaries from the official release location, verify SHA-256, stage, and smoke-test before replacement. Current executable releases are hosted on Codeberg. [Release assets](https://codeberg.org/mikf/gallery-dl/releases/tag/v1.32.13)

Preserve prior executables and user data on failure. Include license notices and source references.

Test clean Windows 10/11 installations without Python. Do not assume every machine has the required Visual C++ runtime. If startup fails, retain the working installation and report the prerequisite; do not silently elevate.

Show separate versions for standalone yt-dlp, gallery-dl, and its embedded downloader where available. gallery-dl updates use the tested manifest. Preserve the existing explicit standalone yt-dlp update operation.

### Delivery sequence

1. Capture baseline test results; preserve existing uncommitted changes.
2. Implement request-specific dependencies and the engine boundary.
3. Add Entire social post mode and durable item reporting.
4. Add authentication, pacing, platform holds, and queue states.
5. Extend installer, diagnostics, documentation, and tests.
6. Qualify platform/content combinations and publish the supported matrix.
7. Stamp README versions using the repository convention after implementation changes.

No publishing or release upload is implied by this plan.

## 5. Tests and release gates

Run existing downloader, UX, menu, queue, and installer suites under PowerShell 5.1 and PowerShell 7.

Add offline coverage for:

- Dependency checks by mode and by queued item.
- No speculative requests before social/authenticated confirmation.
- Profile/platform matching and anonymous defaults.
- Cookie filtering, permissions, cleanup, and redaction.
- Mixed attachments, ordering, partial output, and selective retry.
- Unknown counts, empty success, and incomplete merging.
- Platform holds across aliases, engines, accounts, and application restarts.
- Generic retry actions never releasing holds.
- Native retry settings and child-process termination.
- Cancellation during pacing, extraction, downloading, and merging.
- Unicode paths, spaces, apostrophes, URL metacharacters, and destination containment.
- Corrupt manifests, legacy history, checksum rejection, and installer rollback.

Use fake executables that exercise the actual process runner. Avoid tests that mock away dependency selection, scheduling, or output parsing—the seams most affected by this change.

For live qualification, use a small set of explicitly selected accessible posts. Record engine versions, date, authentication mode, expected attachments, actual results, and limitations. Validate playable audio/video, readable images, post boundaries, and ordering.

Authenticated tests require explicitly supplied credentials and content. Never discover or reuse the operator's browser sessions for testing.

Release requires:

- Existing workflows passing regression tests.
- Clean-machine installation and rollback passing.
- Qualified post forms producing expected media.
- Partial results and blocking being reported accurately.
- No silent credential activation.
- No automatic engine cycling after failure.
- Untested or failing URL forms clearly excluded or labeled.

Research establishes feasibility, not current download success rates. The qualification results determine the advertised support matrix.
