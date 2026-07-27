# MAS Release CI Workflow Implementation Plan

Flavor: feature   ·   Date: 2026-07-25   ·   Brief: `tmp/briefs/mas-submission-stower.md`

## Goal

Write a new `.github/workflows/mas-release.yml` that archives the `StowerMacMAS` scheme with Apple Distribution signing, exports a `.pkg` via `ExportOptionsMAS.plist`, and uploads it to App Store Connect — replacing the old Developer ID + Sparkle `release.yml` pipeline that no longer works on this branch. Provide a single `hermes setup-mas-release` invocation (or one-shot `workflow_dispatch`) that produces a CI-verified, uploadable build.

## Non-goals

- Do **not** touch `release.yml` — leave it as historical reference in the repo
- Do **not** modify `ci.yml` — it already builds `StowerMacMAS` in Debug + no-signing mode
- Do **not** add a Sparkle signing, appcast, GitHub Release, or DMG step — MAS doesn't use any of them
- Do **not** change the Xcode project, build settings, or version numbers — those are pre-existing and correct
- Do **not** automate App Store Connect submission-for-review — the workflow uploads to TestFlight/pre-submission; the human publishes manually in App Store Connect

## Assumptions

| # | Assumption (we believe…) | What breaks if false | Status |
|---|--------------------------|----------------------|--------|
| A1 | The Apple Distribution and Mac Installer Distribution P12 certificates, stored as GitHub secrets, are valid and unexpired | `xcodebuild archive` or `-exportArchive` fail with signing errors | to-verify (first dry-run) |
| A2 | The App Store Connect API `.p8` key has permission to upload builds | `altool --upload-package` returns a 403 or permission error | to-verify (first dry-run) |
| A3 | An App Store app record for bundle ID `app.stower.mas` already exists in App Store Connect | `altool --upload-package` errors with "no app record found" | verified (user confirmed app exists) |
| A4 | A Mac App Store provisioning profile for `app.stower.mas` can be generated on developer.apple.com | `xcodebuild -exportArchive` produces an unsigned .pkg or errors | to-verify |
| A5 | The `ExportOptionsMAS.plist` with `signingStyle=manual` + `signingCertificate=Apple Distribution` works correctly with an installed provisioning profile on the CI runner | Export fails or produces Developer-ID-signed output | to-verify (first dry-run) |
| A6 | `CURRENT_PROJECT_VERSION = 1` in the pbxproj needs to be either bumped manually before each release or derived at CI time (e.g. `git rev-list --count HEAD`) | Apple rejects uploads with a reused build number | accepted risk — plan uses manual pre-bump for first release |

## Judgment calls (JCs)

| # | The call | What was decided | Alternative not taken | Why | Door |
|---|----------|------------------|-----------------------|-----|------|
| JC1 | Upload mechanism | `xcrun altool --upload-package` with API key | `xcodebuild -uploadAppStore` (newer) or Apple ID + app password | `altool` is battle-tested in every real MAS pipeline found during research (Franz, geoSp00f, multiple Electron MAS workflows); `-uploadAppStore` is newer with less documented failure-mode resolution | 2-way — switch at any time |
| JC2 | Trigger | `workflow_dispatch` only | Tag-push trigger (`mas-v*`) | MAS releases are deliberate — you bump version, run workflow, verify in TestFlight, publish manually. Tag triggers risk accidental submits. Every real app researched uses manual dispatch. | 2-way — add tags later |
| JC3 | Build number strategy | Manual pre-run bump of `CURRENT_PROJECT_VERSION` in pbxproj before dispatching | Derive from git commit count or timestamp in CI | First release is simplest path; no need to automate build number derivation until it becomes a chore. Bump is a one-line change. | 2-way — automate later |
| JC4 | Old `release.yml` | Keep as reference | Delete | Contains battle-tested keychain management, version parsing, and signing setup patterns that the MAS workflow borrows from | 2-way — delete later |
| JC5 | Provisioning profile | Store as base64 GitHub secret, install on runner at job start | Automatic signing (requires Xcode to have Apple ID + team logged in) | Automatic signing doesn't work headless in CI — no way to pass Apple ID credentials to Xcode's profile manager | 1-way — once stored, easy to rotate |

## Why

1. **No usable release pipeline for the MAS build.** The existing `release.yml` archives scheme `StowerMac` with Developer ID signing — that scheme no longer exists (replaced by `StowerMacMAS`), and Developer ID signatures are rejected by the Mac App Store. It's dead workflow that can only fail.

2. **A release workflow is the last P0 gap before submission.** The brief (`tmp/briefs/mas-submission-stower.md`) identifies "MAS release CI workflow" as the only remaining P0 item. Screenshots and metadata (P1) can be done in App Store Connect directly.

3. **Trust through verification.** A CI workflow proves the build is signable, exportable, and uploadable before you're sitting in front of App Store Connect wondering why the upload fails.

## What

### User-visible behavior

- **One manual dispatch** in the GitHub Actions tab → selects "MAS Release" → optionally enters a version → clicks "Run workflow" → gets a green checkmark and a submitted build in TestFlight 15-20 minutes later.

### Technical requirements

1. **New file**: `.github/workflows/mas-release.yml` — the full CI workflow
2. **New (or updated) file**: `ExportOptionsMAS.plist` — may need `provisioningProfiles` dict added if `signingStyle=manual` fails
3. **New secret**: `MAS_PROVISIONING_PROFILE` — base64 of the App Store provisioning profile (not yet created)

### Success criteria

- [ ] `xcodebuild archive -scheme StowerMacMAS -configuration Release` succeeds on a GitHub Actions macos-26 runner
- [ ] `xcodebuild -exportArchive -exportOptionsPlist ExportOptionsMAS.plist` produces a valid `.pkg`
- [ ] `xcrun altool --upload-package ... --type macos` successfully uploads to App Store Connect
- [ ] The submitted build appears in App Store Connect → TestFlight (ready for testing/review)
- [ ] The workflow completes in under 30 minutes

### Pseudocode

```
mas-release.yml workflow_dispatch:
  1. Checkout repo (actions/checkout@v5)
  2. Select latest stable Xcode
  3. Create temp keychain, import Apple Distribution + Mac Installer certs
  4. Write App Store Connect API key to ~/.appstoreconnect/private_keys/
  5. Install provisioning profile to ~/Library/MobileDevice/Provisioning\ Profiles/
  6. xcodebuild archive -scheme StowerMacMAS -configuration Release ...
  7. xcodebuild -exportArchive -exportOptionsPlist ExportOptionsMAS.plist ...
  8. Verify the .pkg exists and has a non-trivial size
  9. xcrun altool --upload-package ...
  10. Clean up: delete temp keychain
```

## §Surface

- **`~/.appstoreconnect/private_keys/`** — created and written on the runner; torn down with the VM
- **`~/Library/MobileDevice/Provisioning\ Profiles/`** — profile written to this path; torn down with the VM
- **Temp keychain** — created with `security create-keychain`, destroyed on cleanup
- **GitHub secrets in flight** — P12 passwords and the .p8 key pass through env vars; they are masked in logs by GitHub's secret-scrubber, never go to stdout unbidden, and the .p8 is written to a file with `chmod 600`
- **`.pkg` file** — created in `$RUNNER_TEMP`, uploaded via `altool`, then discarded (the runner VM is destroyed)

## §Invariants and Tests

| Invariant | Test/Guard | Threat it closes | Enforced by |
|-----------|-----------|------------------|-------------|
| The .pkg must be signed with Apple Distribution cert | `pkgutil --check-signature <pkg>` after export | An unsigned .pkg will be rejected by App Store Connect | `mas-release.yml` post-export step |
| `.pkg` file size > 1MB | `stat -f '%z' <pkg>` — guard failure if smaller | A degenerate/empty .pkg wastes 15 min of upload time | `mas-release.yml` validation step |
| Build number is unique per upload | N/A (manual bump by human before dispatch) | Apple rejects duplicate build number; the error is clear enough to recover | Human process (check App Store Connect for last submitted build number before bumping) |

## All Needed Context

### Documentation & References

```yaml
- file: tmp/briefs/mas-submission-stower.md
  why: Original gap analysis this plan is based on

- file: .github/workflows/release.yml
  why: Reference for keychain management, version parsing patterns — borrow, don't copy blindly

- file: .github/workflows/ci.yml
  why: Existing CI references — MAS release workflow uses same runner, Xcode selection, project path

- file: Scripts/release/ExportOptionsMAS.plist
  why: The export options plist — may need provisioningProfiles key added

- file: StowerMac/StowerMac.xcodeproj/project.pbxproj
  lines: grep for CURRENT_PROJECT_VERSION, MARKETING_VERSION, PRODUCT_BUNDLE_IDENTIFIER
  why: Build settings for Debug + Release configurations
```

### Reuse inventory

- **Keychain management pattern** from `release.yml` lines 133-165 — import P12 to temp keychain, unlock, set partition list, clean up. The MAS workflow reuses this exact pattern for the Apple Distribution + Mac Installer P12s.
- **ExportOptionsMAS.plist** already exists — no need to recreate it. Only potentially add a `provisioningProfiles` dict.

### Known gotchas

```
// 1. Mac App Store export ALWAYS produces a `.pkg`, not an `.app`.
//    The exportOptionsPlist method=mac-app-store tells xcodebuild to
//    wrap the signed .app in an installer package. The .pkg path
//    is `<app_name>.pkg` (e.g. `Stower.pkg`).
//
// 2. Two certs are required, not one. Apple Distribution signs the .app
//    inside the archive. Mac Installer Distribution signs the .pkg
//    wrapper. Importing only one cert causes exportArchive to fail.
//
// 3. xcodebuild on macos-26 runner: the runner has Xcode 26.5 which
//    matches the local dev environment (verified by ci.yml).
//    CODE_SIGNING_ALLOWED is NOT set (we want real signing).
//
// 4. The --upload-package command requires `-t macos` and the .p8 key
//    file to reside at `~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8`.
//    The key filename MUST match the key ID or altool cannot find it.
//
// 5. GitHub's secret scrubber masks exact matches of secret values in
//    logs. The .p8 key content is base64 in an env var and decoded to
//    disk — the decoded key file is 0.5-1 KB and the full key may not
//    match the secret pattern. `chmod 600` is defense-in-depth.
```

### Considered and rejected

- **`xcodebuild -uploadAppStore`** (Xcode 16+ native). Rejected in favor of `altool` because: (1) `altool` is documented in every real-world MAS pipeline found during research; (2) `-uploadAppStore` has publicly documented issues with macOS .pkg uploads specifically (vs. iOS .ipa) that remain unresolved in Xcode 26 forums; (3) `altool` accepts the same API key format and is not deprecated. Re-evaluate next Xcode version.
- **Fastlane**. Rejected because the entire project's CI tooling is raw `xcodebuild` + bash (see `ci.yml`, `release.yml`). Adding a Ruby dependency and Fastlane setup for a single upload lane adds ~5 minutes per run (bundle install) and a second toolchain to debug. The `release.yml` already demonstrates that raw Bash + `xcodebuild` + `xcrun` is sufficient.
- **Tag-based trigger (`mas-v*`)**. Rejected for JC2 reasons. If auto-tagging is ever desired, the trigger is a 3-line addition.

## Files Being Changed

```
.github/workflows/
├── mas-release.yml           ← NEW      (MAS release CI workflow)
```

No other files modified. `release.yml` stays as reference. No project files touched.

## Architecture Overview

```
Human: bumps CURRENT_PROJECT_VERSION in pbxproj
          │
          ▼
Human: triggers mas-release.yml (workflow_dispatch)
          │
          ▼
  GitHub Actions macos-26 runner
          │
     ┌────┴──────────────────────┐
     │  1. Import certs          │
     │  2. Install provision     │
     │  3. Write API key         │
     │  4. xcodebuild archive    │
     │  5. xcodebuild export    → .pkg
     │  6. Verify signature      │
     │  7. altool --upload ──────┼──→ App Store Connect
     │  8. Clean up              │
     └───────────────────────────┘
          │
          ▼
Human: verifies build in TestFlight
          │
          ▼
Human: submits for review in App Store Connect
```

## Prerequisites (do these before Task 1)

### P1: Create App Store provisioning profile

Go to [developer.apple.com](https://developer.apple.com) → Certificates, Identifiers & Profiles → Profiles → **+** → **Mac App Store** → select App ID `app.stower.mas` → select Apple Distribution certificate → name it `Stower MAS App Store` → download → base64 encode → add as GitHub secret `MAS_PROVISIONING_PROFILE`.

```bash
base64 -i ~/Desktop/Stower_MAS_App_Store.provisionprofile | pbcopy
```

### P2: Bump CURRENT_PROJECT_VERSION (before each release)

Check the last submitted build number in App Store Connect — this will be `1` for the first one. Bump it in the pbxproj by editing both `CURRENT_PROJECT_VERSION` values (Debug and Release share the same `1` value currently):

```
Find in StowerMac/StowerMac.xcodeproj/project.pbxproj:
  CURRENT_PROJECT_VERSION = 1;  (two occurrences)
Change to:
  CURRENT_PROJECT_VERSION = 2;  (or next available)
```

Or set both occurrences to `1` for the MVP submission and let Apple accept build `1` as the first-ever upload.

## Tasks (in implementation order)

- [ ] **Task 1 — Create `mas-release.yml` with cert import and keychain management.** Borrow the keychain setup pattern from `release.yml` lines 133-165, adapted for two certs (Apple Distribution + Mac Installer Distribution). Write the API .p8 key to `~/.appstoreconnect/private_keys/`. Install the provisioning profile.

  *Files:* Create `.github/workflows/mas-release.yml`
  *Verify:* `git diff --check` and `yq eval` on the workflow file to confirm valid YAML

- [ ] **Task 2 — Add archive + export steps.** `xcodebuild archive -scheme StowerMacMAS -configuration Release` followed by `xcodebuild -exportArchive -exportOptionsPlist Scripts/release/ExportOptionsMAS.plist`. Add a post-export validation step: `pkgutil --check-signature` and size gate (>1MB).

  *Files:* Modified `.github/workflows/mas-release.yml`
  *Verify:* Simulate locally by running the same xcodebuild commands (with CODE_SIGNING_ALLOWED=NO if no cert) to confirm archive/export plumbing works

- [ ] **Task 3 — Add altool upload step.** Upload the .pkg with `xcrun altool --upload-package ... --type macos --apiKey ... --apiIssuer ...`. Check output for "No errors uploading". Add cleanup step (delete temp keychain).

  *Files:* Modified `.github/workflows/mas-release.yml`
  *Verify:* Inspection — upload step can only be verified on an actual CI run (no Apple ID in local dev)

- [ ] **Task 4 — Add workflow_dispatch parameters and documentation.** Accept an optional `version` input (pre-filled with the current MARKETING_VERSION). Add a header comment explaining prerequisites (certs, profiles, API key) and release process.

  *Files:* Modified `.github/workflows/mas-release.yml`
  *Verify:* `cat` the workflow file — comments and inputs should be self-documenting

- [ ] **Task 5 — First dry-run on CI.** Trigger the workflow manually with `version: 1.0` and watch the run. Troubleshoot any failures (likely signing/profile issues). Iterate until the .pkg uploads successfully to TestFlight.

  *Verify:* Green checkmark on GitHub Actions, build appears in App Store Connect → TestFlight

## Final Validation Checklist

```bash
# From the repo root.

# 1. YAML syntax check
python3 -c "import yaml; yaml.safe_load(open('.github/workflows/mas-release.yml')); print('YAML OK')"

# 2. File exists
test -f .github/workflows/mas-release.yml && echo "Workflow exists"

# 3. No references to old scheme StowerMac
! grep -n 'StowerMac ' .github/workflows/mas-release.yml

# 4. References StowerMacMAS scheme
grep -q 'StowerMacMAS' .github/workflows/mas-release.yml && echo "Scheme OK"
```

- [ ] All §Invariants have a passing check
- [ ] YAML is valid
- [ ] No references to `StowerMac` (the old scheme) — only `StowerMacMAS`
- [ ] Secrets referenced match what's actually stored in the repo (no typos)
- [ ] First dry-run on CI produces an uploaded .pkg in TestFlight

## Open questions

1. **Does `signingStyle=manual` in `ExportOptionsMAS.plist` need a `provisioningProfiles` dict?** The current plist has `signingStyle=manual` + `signingCertificate=Apple Distribution` but no `provisioningProfiles` key. With the profile installed on the runner (not referenced in the plist), `xcodebuild` may still find it by bundle ID. Test this first; add the key if export fails.

2. **What's the actual `--asc-public-id` value for `altool --upload-package`?** The Franz blog post used it, but some workflows omit it. Resolve: try without it first (many modern workflows do). The `--apple-id` (App Store Connect app ID numeric) may also be optional if using API key auth. Test on first upload.

3. **Does Apple require `--bundle-short-version-string` and `--bundle-version` flags on `altool --upload-package`?** The Franz blog includes them, but API-key-authenticated uploads may derive these from the .pkg itself. If omitting them fails, add them by extracting from the archive's Info.plist with PlistBuddy.
