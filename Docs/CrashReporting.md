# Crash Reporting

## Removed for MAS

Sentry crash reporting is **not included** in the MAS-distributed build. The
entire `Sources/StowerMacUI/CrashReporting/` directory has been removed for the
MAS-only branch. The MAS target has no crash-reporting dependency, no Sentry
SDK, no DSN, no scrubber, and no crash-handler configuration.

What was removed:

- `StowerCrashReporting.swift` — the only `SentrySDK.start` site
- `StowerSentryScrubber.swift` — the `beforeSend` PII scrubber
- `StowerCrashReportingTests.swift` — test suite
- `StowerSentryScrubberTests.swift` — test suite

The umbrella facade `StowerDiagnostics.initialize()` (in
`Sources/StowerMacUI/Diagnostics/`) skips crash reporting entirely on the MAS
target; analytics (consent-gated, no-op TelemetryDeck) is the only backend.

For the full crash reporting design (EU DSN, KSCrash guard, PII scrubber, etc.)
see the non-MAS source tree.
