import Foundation
import Testing

@testable import StowerMacUI

/// Tests the `StowerDiagnostics` umbrella facade: disabled consent → analytics
/// backend does not start; enabled consent → analytics backend starts.
@Suite(.serialized) @MainActor internal struct StowerDiagnosticsGateTests {

    @Test internal func disabledConsent_neitherBackendStarts() async {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        let consent = StowerDiagnosticsConsent(storage: storage)
        consent.setEnabled(false)

        var analyticsClientCalled = false

        // Drive StowerDiagnostics.initialize with a disabled consent — analytics
        // backend should not fire.
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in analyticsClientCalled = true }
        )

        #expect(
            analyticsClientCalled == false,
            "analytics backend must not start when consent is off"
        )
        #expect(StowerDiagnostics.isEnabled() == false)
    }

    @Test internal func enabledConsent_analyticsBackendIsNoOp() async {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        // Fresh storage = default-on. In MAS-only build there is no
        // TelemetryDeck SDK — makeClient is never called.
        var analyticsClientCalled = false

        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in analyticsClientCalled = true }
        )

        #expect(
            analyticsClientCalled == false,
            "makeClient is never called in MAS build (no TelemetryDeck)"
        )
        #expect(
            StowerDiagnostics.isEnabled() == true,
            "diagnostics should be enabled even without TelemetryDeck"
        )
    }

    @Test internal func setEnabled_false_disablesDiagnostics() async {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in }
        )
        #expect(StowerDiagnostics.isEnabled() == true)

        StowerDiagnostics.setEnabled(false)

        #expect(StowerDiagnostics.isEnabled() == false)
    }

    @Test internal func reconcileLicenseConsent_propagates() async {
        StowerAnalytics.resetForTesting()
        defer { StowerAnalytics.resetForTesting() }

        let storage = StowerInMemoryLeaseStorage()
        StowerDiagnostics.initialize(
            consent: StowerDiagnosticsConsent(storage: storage),
            identity: StowerDiagnosticsIdentity(storage: storage),
            makeAnalyticsClient: { _, _, _ in }
        )
        #expect(StowerDiagnostics.isEnabled() == true)

        StowerDiagnostics.reconcileLicenseConsent(licenseOptOut: true)

        // "Off wins" — license opt-out must propagate to isEnabled.
        #expect(StowerDiagnostics.isEnabled() == false)
    }
}
