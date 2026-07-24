#!/usr/bin/env bash
# Single-command gate. Run before every commit.
# Scripts/install-hooks.sh wires this to .git/hooks/pre-commit.
# MAS-ONLY WORKTREE: builds via xcodebuild (MAS scheme), not swift build.
# The shared Sources/ files import Sentry/TelemetryDeck — those are resolved
# by the Xcode project (MAS target excludes them from compile sources).
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"

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

# Step 3 — build (MAS scheme). swift build won't work here because shared
# Sources/ files import Sentry/TelemetryDeck — those are excluded from the
# MAS target at the Xcode project level, not the SPM level.
xcodebuild -project StowerMac/StowerMac.xcodeproj -scheme StowerMacMAS build CODE_SIGNING_ALLOWED=NO

# Step 4 — test (MAS scheme). The MAS scheme has no Xcode-native test targets
# (all test targets are SPM-level, defined in Package.swift). xcodebuild test
# can't run them without a testable reference; they are gated separately via
# swift test in the non-MAS worktree or by CI.
# xcodebuild -project StowerMac/StowerMac.xcodeproj -scheme StowerMacMAS test
echo "  (tests: SPM-level only — run via swift test in the main worktree)"

# Step 5 — module boundary checks (shared Sources/ guards, MAS-only).
# These verify the source-level quarantine holds. The MAS target excludes
# files from its compile sources, but the import text still exists in the
# source tree — these guards catch reintroductions at the source level.

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

echo "All checks passed."