# Project audit and update improvements — 2026-09-21

## Confirmed and fixed

| Finding | Evidence and consequence | Fix |
| --- | --- | --- |
| App update revision was outside rollback | Locking installed-version.txt let scripts change while the updater reported that files were unchanged | Stage revision with app files in the same transaction; shared setup lock |
| Update implementations diverged | In-app transfer still suppressed progress; FFmpeg fallback used only gyan.dev without a checksum | One generated update core, used by installer and app helper setup |
| Helpers updated using old loaded code | Old menu replaced app scripts then continued running the old pinned gallery-dl logic; Node/FFmpeg never refreshed | Fetch checked revision's installer and run it in a fresh process for all five helpers |
| No automatic discovery or reload | Users had to know menu 5 and manually reopen the app | Three-second startup check, explicit Update/Later choices, settings toggle, launcher restart code |
| Every update downloaded large unchanged helpers | Installer fetched every archive regardless of installed version | Reuse only matching published package identities and verified local hashes; re-run executable checks |
| Cookie filtering lost some login cookies | Host-only #HttpOnly_x.com fixture was dropped while dotted-domain fixture survived | Parse Netscape fields and strip the HttpOnly prefix only for domain comparison |
| Startup removed another session's cookies | Creating a filtered cookie then calling startup sweep deleted the live file | PID-owned temp names, preserve live owners, remove only the exact profile-validation copy |
| GitHub did not gate app updates on tests | Both clients read main directly; no workflow existed | Windows 5.1/7 CI advances a stable branch only after passing tests |
| Repo mixed source with a downloaded binary | yt-dlp.exe was tracked while other helpers were downloaded | Ignore helper binaries and runtime records; retain the local EXE, remove it from future source snapshots without rewriting history |
| Settings writes could truncate the previous file | Save wrote directly to settings.json | Write a temporary file and replace only after serialization succeeds |

## Design choice

The app remains one runtime script for compatibility with already-installed updaters.
Shared update code has one editable source and checked generated copies. Splitting the
whole app into required modules in this release would break the old four-file updater.
The project map records the existing domain boundaries for future work.

## Verification ledger

- Reproduced the revision-write rollback failure before fixing it.
- Disproved the overly broad HttpOnly hypothesis with a dotted-domain fixture; the
  failure is specifically reproduced with host-only HttpOnly cookies.
- Reproduced active cookie deletion with the real cleanup and filtering functions.
- Full fixture installer tests cover empty install, upgrade, helper reuse, preserved
  downloads/settings, rejected helper, staging/lock cleanup, in-app child installer,
  and the actual CMD restart loop.
- Startup tests cover Update, Later, current version, offline result, and disabled checks.
- Existing network tests exercise real HTTP streams, truncation, 503, and stalled reads.
- Both PowerShell versions run the complete offline suite before publishing.

## Remaining boundaries

Updates require connectivity and the app to be opened; Later does not install anything.
Already-distributed old code cannot acquire startup checking without one initial update.
The queue remains session-only and the UI warns before an update clears it. Copy rollback
handles ordinary errors, not arbitrary power loss during a multi-file install. Interrupted
downloads restart; they do not resume. No claim is made that every supported social site
works anonymously, or that this audit replaced fresh-VM testing.
