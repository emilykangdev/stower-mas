// WILL BE REMOVED, IGNORE — inactive Lemon Squeezy licensing/trial subsystem. The MAS
// build wires no license gate, so nothing in this file is reachable at runtime. Removal
// is a planned separate concern (Docs/BuildLog.md, 2026-08-24 entry).

import Foundation

@testable import StowerMacUI

/// An in-memory `StowerTrialBadgeDismissing` so tests never touch `UserDefaults`.
internal final class StowerInMemoryBadgeDismissal: StowerTrialBadgeDismissing, @unchecked Sendable {
    private let lock = NSLock()
    private var dismissed = false

    internal init() {}

    internal var isDismissed: Bool {
        lock.withLock { dismissed }
    }

    internal func dismiss() {
        lock.withLock { dismissed = true }
    }
}
