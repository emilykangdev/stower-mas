#!/usr/bin/env bash
# Single-command gate. Run before every commit.
# Scripts/install-hooks.sh wires this to .git/hooks/pre-commit.
# MAS-ONLY WORKTREE: builds via xcodebuild (MAS scheme), not swift build.
# Sentry and TelemetryDeck have been purged from the MAS branch — the shared
# Sources/ no longer import these libraries.
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

# Step 0 — normalize the SDK environment, WHY: git runs hooks with SDKROOT
# pointed at the CommandLineTools SDK (plus CPATH/LIBRARY_PATH at /usr/local).
# The Xcode toolchain cannot build this package against the CLT SDK: `swift test`
# dies with a bare `error: fatalError`, and the mismatched SDK also changes the
# build fingerprint, forcing a full rebuild on every commit. Unsetting SDKROOT is
# what fixes the crash; CPATH/LIBRARY_PATH are injected by the same path and have
# no business steering this gate's build. Without this, the gate passes when run
# by hand and fails only as a pre-commit hook — the worst possible split.
unset SDKROOT CPATH LIBRARY_PATH

# Step 1 — swift-format. FAILS if absent.
if command -v swift-format >/dev/null 2>&1; then
    SWIFT_FORMAT=swift-format
elif SWIFT_FORMAT="$(xcrun --find swift-format 2>/dev/null)" && [ -x "$SWIFT_FORMAT" ]; then
    :
else
    echo "ERROR: swift-format not found. It ships with the Swift 6 toolchain;" >&2
    echo "       ensure your toolchain is on PATH, or: brew install swift-format" >&2
    exit 1
fi
"$SWIFT_FORMAT" lint --strict --recursive Sources Tests

# Step 2 — swiftlint. FAILS if absent.
if ! command -v swiftlint >/dev/null 2>&1; then
    echo "ERROR: swiftlint not installed. Install a precompiled binary from" >&2
    echo "       https://github.com/realm/SwiftLint/releases (portable_swiftlint.zip)" >&2
    echo "       or, with full Xcode: brew install swiftlint" >&2
    exit 1
fi
DEVDIR="$(xcode-select -p)"
if [ "$(basename "$DEVDIR")" = "CommandLineTools" ]; then
    DYLD_FRAMEWORK_PATH="$DEVDIR/usr/lib" swiftlint lint --strict
else
    swiftlint lint --strict
fi

# Step 3 — build (MAS scheme). Sentry and TelemetryDeck have been purged from
# the MAS branch — no conditional compilation at the Xcode project level needed.
xcodebuild -project StowerMac/StowerMac.xcodeproj -scheme StowerMacMAS build CODE_SIGNING_ALLOWED=NO

# Step 4 — test. Sentry/TelemetryDeck-dependent test files have been deleted
# from the MAS branch, so all test suites compile without conditional guards. All other tests (StowerCoreTests,
# StowerMessagesTests, StowerMacUITests minus the guarded suites) run normally.
# Tests that depend on FoundationModels (macOS 26 + Apple Intelligence) are
# excluded when STOWER_SKIP_FM_INTEGRATION=1 is set (CI only — unset locally).
SKIP_ARGS=()
if [ "${STOWER_SKIP_FM_INTEGRATION:-}" = "1" ]; then
    echo "NOTE: STOWER_SKIP_FM_INTEGRATION=1 — excluding the FoundationModels" >&2
    echo "      integration suite (needs macOS 26 + Apple Intelligence). All" >&2
    echo "      other tests still run and still fail hard." >&2
    SKIP_ARGS=(--skip 'StowerFMReplyJudgeIntegrationTests')
fi
swift test ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}

# Step 5 — module boundary checks (shared Sources/ guards, MAS-only).
# These verify the source-level quarantine holds. Sentry/TelemetryDeck imports
# have been removed from the source tree.

# 6a — Engine-internal modules never imported by StowerMacUI (permanent ban).
if grep -RInE --include="*.swift" \
    '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(GRDB|FoundationModels|Photos|PhotoKit)([[:space:]]|$)' \
    Sources/StowerMacUI/ 2>/dev/null; then
    echo "ERROR: StowerMacUI must not import engine-internal modules (GRDB/FoundationModels/Photos/PhotoKit)" >&2
    exit 1
fi

# 6b — StowerMessages imported by EXACTLY four engine-coupled files (closed allowlist).
SM_ALLOWED="$(printf '%s\n' \
    "Sources/StowerMacUI/Startup/StowerMessagesStartupAdapter.swift" \
    "Sources/StowerMacUI/Board/StowerLiveBoardDataSource.swift" \
    "Sources/StowerMacUI/Board/StowerMessagesComposition.swift" \
    "Sources/StowerMacUI/Board/StowerMessagesMapping.swift" \
    | LC_ALL=C sort)"
SM_IMPORTERS="$(grep -RIlE --include="*.swift" \
    '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+StowerMessages([[:space:]]|$)' \
    Sources/StowerMacUI/ 2>/dev/null | LC_ALL=C sort || true)"
if [ "$SM_IMPORTERS" != "$SM_ALLOWED" ]; then
    echo "ERROR: only the four engine-coupled files may import StowerMessages:" >&2
    echo "$SM_ALLOWED" | sed 's/^/       allowed: /' >&2
    echo "       Found:" >&2
    echo "${SM_IMPORTERS:-<none>}" | sed 's/^/       /' >&2
    exit 1
fi

# 6c — StowerCore imported by EXACTLY these StowerMacUI files (closed allowlist).
SC_ALLOWED="$(printf '%s\n' \
    "Sources/StowerMacUI/Board/StowerMessagesComposition.swift" \
    "Sources/StowerMacUI/Board/StowerMessagesStorageLocation.swift" \
    "Sources/StowerMacUI/Feedback/StowerFeedbackConfig.swift" \
    "Sources/StowerMacUI/Startup/StowerLicenseConfig.swift" \
    "Sources/StowerMacUI/Startup/StowerMessagesSourceOverride.swift" \
    | LC_ALL=C sort)"
SC_IMPORTERS="$(grep -RIlE --include="*.swift" \
    '^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\([^)]*\))?([[:space:]]|$))*import[[:space:]]+([a-z]+[[:space:]]+)?StowerCore([[:space:].]|$)' \
    Sources/StowerMacUI/ 2>/dev/null | LC_ALL=C sort || true)"
if [ "$SC_IMPORTERS" != "$SC_ALLOWED" ]; then
    echo "ERROR: only these StowerMacUI files may import StowerCore:" >&2
    echo "$SC_ALLOWED" | sed 's/^/       allowed: /' >&2
    echo "       Found:" >&2
    echo "${SC_IMPORTERS:-<none>}" | sed 's/^/       /' >&2
    exit 1
fi

# 6d — MAS app entry must import ONLY SwiftUI + StowerMacUI.
if grep -RInE --include="*.swift" \
    '^[[:space:]]*(@testable[[:space:]]+)?import[[:space:]]+(GRDB|FoundationModels|Photos|PhotoKit|StowerMessages|StowerCore|Sparkle)([[:space:]]|$)' \
    StowerMac/StowerMacMAS 2>/dev/null; then
    echo "ERROR: the StowerMacMAS app entry must import only SwiftUI + StowerMacUI" >&2
    exit 1
fi

# 6e — No stale pre-rename Stower application/window/lifecycle vocabulary remains
# (2026-08-23 migration to ApplicationDefinition / StowerApplicationWindowContentView
# / StowerTerminationDrain; the retired declaration/filename literals are named only
# inside the split fragments below, never spelled out contiguously in a comment).
# WHY: this vocabulary blurred the application definition, scene description, the
# runtime Application Window, the construction boundary, and cross-cutting
# drain/composition language; letting it back in re-teaches the ambiguity the
# rename removed. Exact stale literals below are split across adjacent quoted
# fragments so this guard's own source is not itself a false hit when the exact
# literal is searched for repo-wide.

# 6e-1 — old pre-rename filenames must be gone.
STALE_OLD_FILES=(
    "StowerMac/StowerMacMAS/StowerMac""MASApp.swift"
    "Sources/StowerMacUI/Views/Stower""RootView.swift"
    "Sources/StowerMacUI/Views/Stower""RootViewLicensing.swift"
    "Sources/StowerMacUI/Views/StowerTermination""Flusher.swift"
)
for STALE_FILE in "${STALE_OLD_FILES[@]}"; do
    if [ -e "$STALE_FILE" ]; then
        echo "ERROR: stale pre-rename file present: $STALE_FILE" >&2
        echo "       It was replaced by StowerApplication.swift /" >&2
        echo "       StowerApplicationWindowContentView(Licensing).swift / StowerTerminationDrain.swift." >&2
        echo "       Delete it and migrate any remaining content into the renamed file." >&2
        exit 1
    fi
done

# 6e-2 — exact stale declaration/reference symbols must be absent repo-wide
# (excluding *.html, the sole permitted historical-record surface per JC1).
STALE_SYMBOL_PARTS=(
    "StowerMac""MASApp"
    "StowerMac""App(\\.swift)?"
    "StowerApp""Delegate"
    "StowerMacMAS""Container"
    "Stower""RootContainer"
    "Stower""RootView"
    "StowerTermination""Flusher"
    "on""Flush"
    "flush""PendingWork"
    "flush""All"
    "Stower""Draft""WriteHandle"
)
STALE_SYMBOLS="$(IFS='|'; echo "${STALE_SYMBOL_PARTS[*]}")"
if git grep -n -E "$STALE_SYMBOLS" -- ':!*.html' 2>/dev/null; then
    echo "ERROR: stale pre-rename declaration/reference symbol found above." >&2
    echo "       Migrate it to the aligned target name; no compatibility alias is allowed." >&2
    exit 1
fi

# 6e-3 — lowercase 'appDelegate' property reference must be gone from the MAS
# app entry (renamed to 'applicationLifecycleDelegate').
STALE_LOWER_APP_DELEGATE="app""Delegate"
if git grep -n "$STALE_LOWER_APP_DELEGATE" -- StowerMac/StowerMacMAS 2>/dev/null; then
    echo "ERROR: stale 'appDelegate' property reference found above in StowerMac/StowerMacMAS." >&2
    echo "       Rename it to 'applicationLifecycleDelegate'." >&2
    exit 1
fi

# 6e-4 — unambiguous stale multi-word phrases must be absent from tracked active
# context. Character classes replace literal spaces so this guard's own source
# text never spells the banned phrase contiguously.
STALE_PHRASES='composition[[:space:]]root'
STALE_PHRASES="$STALE_PHRASES|composition[[:space:]]point"
STALE_PHRASES="$STALE_PHRASES|termination[[:space:]]flush"
STALE_PHRASES="$STALE_PHRASES|flush[[:space:]]on[[:space:]]quit"
STALE_PHRASES="$STALE_PHRASES|save[[:space:]]on[[:space:]]quit"
STALE_PHRASES="$STALE_PHRASES|main[[:space:]]window"
STALE_PHRASES="$STALE_PHRASES|board[[:space:]]window"
STALE_PHRASES="$STALE_PHRASES|top-level[[:space:]]declaration"
if git grep -n -i -E "$STALE_PHRASES" -- \
    .github AGENTS.md ARCHITECTURE.md Docs Sources Tests StowerMac Scripts 2>/dev/null; then
    echo "ERROR: stale application/window/lifecycle phrase found above." >&2
    echo "       Rewrite it using the exact aligned relationship (see AGENTS.md" >&2
    echo "       'Naming map' and Docs/MacAppContract.md) instead of the retired phrase." >&2
    exit 1
fi

echo "All checks passed."