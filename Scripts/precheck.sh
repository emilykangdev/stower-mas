#!/usr/bin/env bash
# Single-command gate. Run before every commit.
# Scripts/install-hooks.sh wires this to .git/hooks/pre-commit.
# Covers the same paths as .swiftlint.yml `included:` — Sources Tests.
# MAS-ONLY WORKTREE: stripped of Sparkle, Sentry, TelemetryDeck guards —
# those live in the direct-sales repo at ~/Documents/Projects/stower.
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

# Step 3 — build.
swift build

# Step 4 — test.
SKIP_ARGS=()
if [ "${STOWER_SKIP_FM_INTEGRATION:-}" = "1" ]; then
    echo "NOTE: STOWER_SKIP_FM_INTEGRATION=1 — excluding FoundationModels" >&2
    echo "      integration suite (needs macOS 26 + Apple Intelligence)." >&2
    SKIP_ARGS=(--skip 'StowerFMReplyJudgeIntegrationTests')
fi
DEVDIR="$(xcode-select -p)"
if [ "$(basename "$DEVDIR")" = "CommandLineTools" ]; then
    FW="$DEVDIR/Library/Developer/Frameworks"
    INTEROP="$DEVDIR/Library/Developer/usr/lib"
    swift test \
        -Xswiftc -F -Xswiftc "$FW" \
        -Xlinker -F -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$FW" \
        -Xlinker -rpath -Xlinker "$INTEROP" \
        ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}
else
    swift test ${SKIP_ARGS[@]+"${SKIP_ARGS[@]}"}
fi

# Step 5 — module boundary checks (shared Sources/ guards, MAS-only).
# These guards verify the source-level quarantine holds. The MAS target
# excludes certain files from its compile sources, but the import text
# still exists in the source tree — the guards catch reintroductions.

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
    '^[[:space:]]*(@[A-Za-z_][A-Za-z0-9_]*(\\([^)]*\\))?([[:space:]]|$))*import[[:space:]]+([a-z]+[[:space:]]+)?StowerCore([[:space:].]|$)' \
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
    StowerMacMAS 2>/dev/null; then
    echo "ERROR: the StowerMacMAS app entry must import only SwiftUI + StowerMacUI" >&2
    exit 1
fi

echo "All checks passed."