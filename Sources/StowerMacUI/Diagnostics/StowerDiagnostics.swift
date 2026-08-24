import Foundation

/// The diagnostics umbrella facade: the single launch entry point for all
/// diagnostics backends (MAS: analytics only, no crash reporting).
///
/// On the MAS target, Sentry crash reporting is absent (SDK not available).
/// `initialize()` is the ONLY call the app target makes to start the analytics
/// backend. It reads consent once, and when enabled starts analytics. When
/// disabled, the backend does not start.
///
/// This facade also exposes consent passthrough — `isEnabled()`, `setEnabled`,
/// and `reconcileLicenseConsent` — so the app target and UI never need to name
/// the internal `StowerDiagnosticsConsent` type or the analytics backend
/// directly.
///
/// `StowerAnalytics.report(_:)` is the entry point for analytics events (it
/// stays on `StowerAnalytics`; this facade does not duplicate it).
@MainActor
public enum StowerDiagnostics {

    // MARK: — Initialization

    /// Initializes the analytics backend behind the shared consent gate.
    ///
    /// The production entry point for `ApplicationDefinition.init()`. When consent is
    /// off this is a complete no-op — no analytics backend starts.
    ///
    /// The injectable form used by tests is `internal`; this public wrapper
    /// supplies real UserDefaults-backed instances so the app target never names
    /// those internal types.
    @MainActor
    public static func initialize() {
        initialize(
            consent: StowerDiagnosticsConsent(),
            identity: StowerDiagnosticsIdentity()
        )
    }

    /// Initializes the analytics backend.
    ///
    /// - Parameters:
    ///   - consent: Shared consent accessor (real UserDefaults-backed in production;
    ///     inject a fake for tests).
    ///   - identity: Shared install-identity accessor (real UserDefaults-backed in
    ///     production; inject a fake for tests).
    ///   - makeAnalyticsClient: Injectable analytics init closure for tests (no-op
    ///     on MAS — no TelemetryDeck).
    @MainActor
    internal static func initialize(
        consent: StowerDiagnosticsConsent,
        identity: StowerDiagnosticsIdentity,
        makeAnalyticsClient: (String, String, String) -> Void = { _, _, _ in }
    ) {
        guard consent.isEnabled else {
            // One gate: analytics stays off. Build a no-op analytics shared
            // instance so report(_:) calls are safe no-ops this session.
            StowerAnalytics.startBackend(
                consent: consent,
                identity: identity,
                makeClient: { _, _, _ in }
            )
            return
        }

        // MAS: no Sentry crash reporting — analytics only.
        StowerAnalytics.startBackend(
            consent: consent,
            identity: identity,
            makeClient: makeAnalyticsClient
        )
    }

    // MARK: — Consent passthrough

    /// Whether diagnostics collection is currently enabled.
    ///
    /// Reads from the live analytics shared instance. Matches
    /// `StowerDiagnosticsConsent.isEnabled` (the UserDefaults cache + kill latch).
    public static func isEnabled() -> Bool {
        StowerAnalytics.isEnabled()
    }

    /// Enables or disables all diagnostics backends and updates the UserDefaults cache.
    ///
    /// On MAS there is no crash reporting to stop — this only toggles analytics.
    ///
    /// The caller (Settings toggle / disclosure card) is responsible for pushing
    /// the change to the license record (`diagnostics_opt_out`) via the licensing
    /// workstream.
    public static func setEnabled(_ enabled: Bool) {
        StowerAnalytics.setEnabled(enabled)
    }

    /// Reconciles the local UserDefaults cache against the license record's opt-out
    /// flag on each license check-in.
    ///
    /// "Off wins" — this never auto-re-enables. When `licenseOptOut` is `true`,
    /// delegates to `StowerAnalytics.reconcileLicenseConsent(licenseOptOut:)`.
    ///
    /// - Parameter licenseOptOut: `true` when the license record carries
    ///   `diagnostics_opt_out = true`.
    public static func reconcileLicenseConsent(licenseOptOut: Bool) {
        StowerAnalytics.reconcileLicenseConsent(licenseOptOut: licenseOptOut)
    }
}
