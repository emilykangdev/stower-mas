# Release notes

One authored Markdown file per release, named exactly `<VERSION>.md` where
`<VERSION>` is the marketing version passed to the `MAS Release` workflow (its
`version` input). For version `1.0`, the file is `Docs/release-notes/1.0.md`.

Stower is MAS-only: updates are delivered by the App Store's own updater, so
these notes feed exactly one user-facing surface — the App Store listing's
**"What's New"** field — plus the repo's own version history.

## The release flow (notes + tag)

1. **Author the notes first**: write `Docs/release-notes/<VERSION>.md` before
   releasing. Keep them user-facing — App Store customers read them on the
   product page and in the update list.
2. **Bump** `CURRENT_PROJECT_VERSION` in `project.pbxproj`, then run the
   `MAS Release` workflow (`workflow_dispatch`) with the marketing `version`.
3. **Submit in App Store Connect**: when the build lands in TestFlight and is
   submitted for review, paste this file's content into the version's
   **"What's New"** field.
4. **Tag the released commit** once the upload succeeds:

   ```bash
   git tag mas-v<VERSION> && git push origin mas-v<VERSION>
   ```

   The tag is how "which version am I on?" stays answerable from the repo —
   `git describe --tags` on any checkout, and each tag pairs with its notes
   file by version number.

Files `0.1.1.md`–`0.2.2.md` predate the MAS migration (they shipped through the
retired direct-distribution pipeline under `messages-v*` tags) and remain as the
version-history record.

## Authoring

App Store "What's New" is plain text — Markdown is not rendered there. Keep the
structure simple (short lines, `-` bullets) so the same file reads well both as
Markdown in the repo and as plain text on the store page.
