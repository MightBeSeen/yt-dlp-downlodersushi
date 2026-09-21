# Entire Social Post Mode — Support Matrix & Qualification

**Engine:** gallery-dl (fetched at install/first-run, SHA-256 fingerprinted)
**Pinned release:** gallery-dl v1.32.13
**Scope:** one post at a time — reel, photo, video, slideshow, or mixed carousel. Profiles,
feeds, albums, stories, comments, and quoted-post expansion are explicitly out of scope
and are rejected before any request is made.

## How it works

1. Main menu → **1. Download** → paste a post link. Social links are recognized automatically,
   including plain X status links and `/photo/1` links; no video/audio mode selection is needed.
2. Choose **Anonymous** or a configured **account profile** (Settings → Manage account profiles).
3. The app validates gallery-dl + FFmpeg, checks for a platform hold, then downloads all
   attachments of that single post into `Downloads/<date>/<platform>/`, without a post-ID subfolder.
4. Choose **Media only** (default), or **Entire social post (include manifest)** before
   confirming. Both download photos and videos at source quality. The latter also writes
   `manifest-<request-id>.json` with finalized items, paths, sizes, types, and engine version.
   Unique manifest names keep different downloads from overwriting each other's records.
   History (CSV) records items in both modes. Existing download folders are not moved.

## Support matrix

"Feasible" means the extractor exists and the URL form is accepted by this app. It is **not**
a guarantee every post downloads — success depends on the post, region, login state, and the
platform's current anti-automation behavior. The **advertised** support is set by live
qualification (below), not by this table.

| Platform  | Accepted single-post forms                                   | Auth typically needed |
|-----------|--------------------------------------------------------------|-----------------------|
| X         | `/<user>/status/<id>` (photo, video, multi-attachment)       | Often no; some gated  |
| TikTok    | `/@<user>/video/<id>`, `/@<user>/photo/<id>`, `vm.tiktok.com/<code>` | Often no       |
| Instagram | `/p/<code>`, `/reel/<code>`, `/tv/<code>` (photo, video, carousel) | Usually yes      |
| Facebook  | `/watch/?v=<id>`, `/<page>/videos/<id>`, `/reel/<id>`, `story_fbid` | Usually yes     |
| YouTube   | Use **Video / audio** mode (yt-dlp) — rejected in entire-post mode | n/a              |

Rejected as collections (never silently expanded): bare profiles, `/media`, `/likes`,
`/stories/`, `/explore`, groups, watch feed, TikTok profiles/playlists.

## Authentication (gated posts)

- v1 supports **user-supplied Netscape `cookies.txt` files only** (no browser extraction).
- A profile stores only a **friendly name, platform, and file path** — never cookie values.
- At download time the app makes a **temporary copy filtered to that platform's cookie
  domains**, restricts it to the current user, hands its path to gallery-dl, and deletes it
  afterward (success, failure, or cancel). Stale copies are swept at startup.
- **Warning:** authenticated downloading can lead to temporary or permanent account
  restrictions. Use a throwaway/secondary account you are willing to lose. Never share your
  cookies.txt.

### Exporting cookies.txt

Use a reputable "Export cookies (Netscape/txt)" browser extension while signed in to the
platform, save the file locally, then add it via **Settings → Manage account profiles → Add**.

## Pacing & platform holds

- Request pacing: Instagram 6–12 s (upstream-documented); other platforms 3–6 s; 5–10 s
  between queued source URLs. Native transient/fragment retries capped at 2; whole-job auto
  retry disabled; blocking responses are not retried.
- On a detected rate-limit/challenge signal (e.g. HTTP 429, `challenge_required`) the app
  stops the download, records anything already finished, and puts the **platform on hold**
  across both engines and all accounts. The hold **persists across restarts**.
- Release a hold from **Settings → Review blocked platforms**. Releasing never starts a
  download. A recorded retry-after time is honored (with a confirm prompt to override).

## Completeness honesty

gallery-dl gives no reliable pre-count of a post's attachments. **Completed** means the run
exited cleanly and every file it produced was finalized — not proof the post had no further
media. The app shows the **downloaded count** and makes no total-completeness claim.
`expectedCount` in the manifest is `null` for this reason.

## Live qualification checklist (run before advertising a platform)

Per platform, download a small set of **explicitly chosen, accessible** posts and record:
engine version, date, auth mode, expected vs. actual attachment count, ordering, and whether
audio/video plays and images open. Use only accounts/content you own or are authorized to use;
never reuse the operator's browser session for automated tests.

| Platform  | Photo post | Video/reel | Multi/carousel or slideshow | Auth (gated) | Result |
|-----------|-----------|-----------|-----------------------------|--------------|--------|
| X         | ☐         | ☐         | ☐                           | ☐            |        |
| TikTok    | ☐         | ☐         | ☐ (photo slideshow)         | ☐            |        |
| Instagram | ☐         | ☐         | ☐                           | ☐            |        |
| Facebook  | ☐         | ☐         | ☐ (supported multi-photo)   | ☐            |        |

**Release gate is per-platform:** a platform that does not pass is labeled *unsupported* in
this document rather than blocking the whole release. Update the support matrix from the
qualification results before telling users a platform works.
