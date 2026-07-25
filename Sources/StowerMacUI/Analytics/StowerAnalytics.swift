import Foundation

/// The analytics backend: no-op for MAS (no TelemetryDeck).
///
/// The orchestration layer (consent gate, backend init ordering) now lives in
/// `StowerDiagnostics` (JC1). On the MAS target there is no TelemetryDeck SDK,
/// so `StowerAnalytics` always uses `StowerNoOpAnalyticsReporter` — every event
/// is silently dropped. The consent/identity types live in
/// `Sources/StowerMacUI/Diagnostics/`.
///
/// `@MainActor`-isolated: call from the main actor (the app's startup and UI
/// already do). Synchronous — an async caller off the main actor must hop to it
/// first; there is no `await` *within* main-actor code (Eng F4/F5). The reporter
/// itself is `Sendable`.
@MainActor
public final class StowerAnalytics {
    /// The singleton built by `startBackend` and used by `report`.
    private static var shared: StowerAnalytics?

    private let reporter: any StowerAnalyticsReporting
    private let consent: StowerDiagnosticsConsent

    private init(reporter: any StowerAnalyticsReporting, consent: StowerDiagnosticsConsent) {
        self.reporter = reporter
        self.consent = consent
    }

    // MARK: — Backend init (called only from StowerDiagnostics facade)

    /// Starts the analytics backend when consent is enabled (JC3).
    ///
    /// Called exclusively by `StowerDiagnostics.initialize()` — not by the app
    /// target directly. On the MAS target the reporter is always a no-op.
    ///
    /// When consent is disabled this is a complete no-op.
    ///
    /// - Parameters:
    ///   - consent: The consent accessor (real UserDefaults-backed in production;
    ///     inject a fake for tests).
    ///   - identity: The install-identity accessor (real UserDefaults-backed in
    ///     production; inject a fake for tests). Ignored on MAS — no TelemetryDeck.
    ///   - makeClient: Injectable SDK-init closure. Ignored on MAS — always a
    ///     no-op. Retained for source compatibility with the non-MAS target.
    @MainActor
    internal static func startBackend(
        consent: StowerDiagnosticsConsent,
        identity: StowerDiagnosticsIdentity,
        makeClient: (String, String, String) -> Void = { _, _, _ in }
    ) {
        guard consent.isEnabled else {
            // Kill switch: build a no-op reporter.
            let noOp = StowerAnalytics(
                reporter: StowerNoOpAnalyticsReporter(),
                consent: consent
            )
            Self.shared = noOp
            return
        }

        // On MAS there is no TelemetryDeck SDK; the reporter is always a no-op.
        let reporter: any StowerAnalyticsReporting = StowerNoOpAnalyticsReporter()
        let live = StowerAnalytics(
            reporter: reporter,
            consent: consent
        )
        Self.shared = live
    }

    // MARK: — Event reporting

    /// Emits one analytics event through the configured reporter.
    ///
    /// A no-op when `startBackend` has not yet been called or analytics is off.
    internal static func report(_ event: StowerAnalyticsEvent) {
        shared?.reporter.report(event)
    }

    /// Reports that the app finished launching (per-launch).
    ///
    /// A no-op when off. Public lifecycle entry point for the app target. The
    /// full event taxonomy (`StowerAnalyticsEvent`) stays internal — only the two
    /// app-emitted lifecycle events are exposed, so no internal associated-value
    /// types leak.
    public static func reportAppLaunched() {
        report(.appLaunched)
    }

    /// Reports that the user quit the app (per-launch).
    ///
    /// A no-op when off.
    public static func reportSessionEnded() {
        report(.sessionEnded)
    }

    // MARK: — Test support

    /// Resets all static state so each test starts from a clean slate.
    ///
    /// Clears `shared` and the kill latch. Call at the start of every test that
    /// calls `startBackend(consent:identity:makeClient:)`. Not for production use.
    @MainActor
    internal static func resetForTesting() {
        shared = nil
        StowerDiagnosticsKillLatch.reset()
    }

    // MARK: — Consent passthrough (delegated to StowerDiagnostics in production)

    /// Whether diagnostics collection is currently enabled.
    ///
    /// Reads from the live `shared` reporter's consent; returns `false` when
    /// the backend has not been started. Used by `StowerPrivacySettingsView`
    /// to initialize its toggle state.
    internal static func isEnabled() -> Bool {
        shared?.consent.isEnabled ?? false
    }

    /// Enables or disables the analytics backend and updates the local UserDefaults cache.
    ///
    /// In production this is called via `StowerDiagnostics.setEnabled(_:)` which
    /// handles both backends. The caller (Settings toggle / disclosure card) is
    /// responsible for pushing the change to the license record.
    internal static func setEnabled(_ enabled: Bool) {
        guard let current = shared else { return }
        current.consent.setEnabled(enabled)
        if enabled {
            // Clear the in-memory kill latch, then bring up a live reporter.
            StowerDiagnosticsKillLatch.reset()
            Self.shared = StowerAnalytics(
                reporter: StowerNoOpAnalyticsReporter(),
                consent: current.consent
            )
        } else {
            // Fail closed in memory across every reporter, even if the UserDefaults
            // write failed. Durable off is backstopped by the license record's
            // `diagnostics_opt_out`, reconciled on the next check-in (JC8).
            StowerDiagnosticsKillLatch.latchOff()
            Self.shared = StowerAnalytics(
                reporter: StowerNoOpAnalyticsReporter(),
                consent: current.consent
            )
        }
    }

    /// Reconciles the local UserDefaults cache against the license record's opt-out
    /// flag on each license check-in.
    ///
    /// "Off wins" — this never auto-re-enables. Called via
    /// `StowerDiagnostics.reconcileLicenseConsent(licenseOptOut:)` in production.
    ///
    /// - Parameter licenseOptOut: `true` when the license record carries
    ///   `diagnostics_opt_out = true`.
    internal static func reconcileLicenseConsent(licenseOptOut: Bool) {
        guard let current = shared else { return }
        current.consent.reconcile(licenseOptOut: licenseOptOut)
        if licenseOptOut {
            StowerDiagnosticsKillLatch.latchOff()
            Self.shared = StowerAnalytics(
                reporter: StowerNoOpAnalyticsReporter(),
                consent: current.consent
            )
        }
    }
}
