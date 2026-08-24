// WILL BE REMOVED, IGNORE — inactive Lemon Squeezy licensing/trial subsystem. The MAS
// build wires no license gate, so nothing in this file is reachable at runtime. Removal
// is a planned separate concern (Docs/BuildLog.md, 2026-08-24 entry).

import StowerCore
import Testing

@testable import StowerMacUI

/// `compiledDefault(for:)` resolves `staging`/`production` per `StowerEnvironment`.
@Suite internal struct StowerLicenseConfigTests {
    // MARK: I6 — compiledDefault(for:) resolves staging/production per environment

    @Test("compiledDefault(for: .debug) resolves to staging (I6)")
    internal func compiledDefaultForDebugIsStaging() {
        #expect(StowerLicenseConfig.compiledDefault(for: .debug) == StowerLicenseConfig.staging)
    }

    @Test("compiledDefault(for: .release) resolves to production (I6)")
    internal func compiledDefaultForReleaseIsProduction() {
        #expect(
            StowerLicenseConfig.compiledDefault(for: .release) == StowerLicenseConfig.production
        )
    }
}
