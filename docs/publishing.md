# Publishing updates

1. Make changes on a branch or `main`, and update the version/date in README.
2. If shared workers changed, run `scripts/Sync-UpdateCore.ps1`.
3. Run `scripts/Test-Project.ps1` with `-Engine powershell` and `-Engine pwsh`.
4. Commit and push to `main` (or merge a PR).
5. Wait for **Windows tests and update channel** to pass on GitHub Actions.

The publish job fast-forwards `stable` to the tested commit. Clients resolve this
branch to an immutable commit before downloading files. Failed tests leave `stable`
unchanged. The publish job also checks that the commit is still the newest `main`
commit; a superseded run does not replace a newer update. Don't force-push `stable`.

The workflow uses the repository's `GITHUB_TOKEN` with `contents: write` only in its
publish job. No personal token is needed. If branch protections are added to `stable`,
allow this publishing mechanism or change the workflow to match those protections.
The workflow triggers on `main`, PRs, and manual dispatch; its own `stable` push does
not start another publishing loop.

Users get a bounded check when opening the app. They choose Update or Later. Menu 5
also checks and repairs all helpers. Successful updates request a launcher restart.
Existing old copies need one manual update/reopen to acquire this behavior. A source
checkout skips startup checks so running development code does not offer to replace it.

## One-click installer compatibility

The app and installer embed their shared core. This intentionally supports the old
updater's fixed four-file download list. New installations also include the installer
itself, but the in-app updater fetches the checked commit's current installer before
running it. Future installer fixes therefore reach users who keep an older standalone
installer, provided its bootstrap can still fetch the app and helpers. For an obsolete
bootstrap that cannot finish, download the current installer from the README link.

To roll back a bad release, revert it on `main` and push the revert. Once tests pass,
the revert becomes the next update. Do not rewrite published history.

## Verification boundaries

Offline CI covers UI decisions, native process cancellation, updater rollback and
locking, complete installer/in-app flow, helper caching, hash rejection, network
stalls, and restart behavior. It does not prove that every social site is accessible
or that an antivirus product will accept a new helper binary. Perform real clean-PC
and representative media-download checks for releases changing those integrations.

References: [GitHub workflow permissions](https://docs.github.com/en/actions/reference/workflows-and-actions/workflow-syntax),
[GITHUB_TOKEN-triggered events](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).
