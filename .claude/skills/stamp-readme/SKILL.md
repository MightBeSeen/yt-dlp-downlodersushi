---
name: stamp-readme
description: Stamp README.md with the current downloader version, last-updated date, and the bundled yt-dlp.exe version. Use after making any change to Seen's yt-dlp Downloader, or when the user says "stamp the readme", "bump the version", or "/stamp-readme".
---

# Stamp README

Refresh the version header line in `README.md` so it always reflects the current state
of the project. Run this as the **last step** after any change to the downloader.

The header line looks like:

```
**Version:** YYYY.MM.DD &nbsp;·&nbsp; **Last updated:** YYYY-MM-DD &nbsp;·&nbsp; **Bundled yt-dlp:** <ytver>
```

## Steps

1. **Get today's date** (the machine's local date), formatted two ways:
   - Version: `YYYY.MM.DD` (e.g. `2026.08.14`).
   - Last updated: `YYYY-MM-DD` (same value, dash-separated).

   ```bash
   date +%Y.%m.%d   # version
   date +%Y-%m-%d   # last-updated
   ```

2. **Read the bundled yt-dlp version** by running the bundled executable:

   ```bash
   ./yt-dlp.exe --version
   ```

   Use the first line of output (e.g. `2026.07.04`) as `<ytver>`.

3. **If two changes land on the same calendar day**, keep the date but append a build
   letter so the version still moves: `2026.08.14`, then `2026.08.14b`, `2026.08.14c`, …
   (Check the existing `**Version:**` value first: if it is already today's date, add or
   bump the trailing letter; otherwise use today's plain date.)

4. **Edit `README.md`** — replace the single `**Version:** …` header line with the freshly
   computed values. Change nothing else in the file unless the user asked you to.

5. **Confirm** the new line back to the user (old → new), e.g.
   `Stamped README: Version 2026.08.14 → 2026.08.15, yt-dlp 2026.07.04 → 2026.09.01`.

## Notes

- This is a **read-and-edit** operation; never rewrite the rest of the README.
- The downloader version is independent of the bundled yt-dlp version — they can differ.
- Keep the exact spacing/format of the header line so it stays a stable, single-line edit.
