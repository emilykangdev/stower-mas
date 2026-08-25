import Foundation

@testable import StowerMacUI

/// The ordered milestones `StowerGatedTriageStore` records, so a drain test can
/// assert the drain returned only AFTER the gated dismiss write completed.
internal enum StowerGatedTriageStoreEvent: Equatable, Sendable {
    /// A gated `dismiss` was entered — the triage write is in flight, suspended.
    case dismissStarted

    /// The test opened the gate (`releaseDismissals`).
    case dismissalsReleased

    /// A gated `dismiss` resumed past the gate and landed its row.
    case dismissCompleted

    /// The drain under test returned (recorded via `noteDrainReturned`).
    case drainReturned
}

/// A triage store whose `dismiss` suspends on a continuation until the test
/// releases it — a deterministically SLOW triage write, with every milestone
/// serialized through this actor so ordering assertions are race-free (no sleeps,
/// no polling).
///
/// Purpose-built for I-DrainAwaitsTriage: a drain that stopped awaiting
/// `triageTask` records `.drainReturned` before `.dismissCompleted`, so the
/// expected event order fails loudly.
internal actor StowerGatedTriageStore: StowerTriageStoring {
    private var dismissed: [String: StowerDismissedAnchor] = [:]
    private var mutedKeys: Set<String> = []
    private var dismissGates: [CheckedContinuation<Void, Never>] = []
    private var dismissStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedDismissals = 0

    /// The milestones observed so far, in actor-serialized order.
    private(set) internal var events: [StowerGatedTriageStoreEvent] = []

    /// Creates an empty gated store with the dismiss gate closed.
    internal init() {}

    internal func dismissedMessages() -> [String: StowerDismissedAnchor] {
        dismissed
    }

    internal func muted() -> Set<String> {
        mutedKeys
    }

    internal func dismiss(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) async {
        noteDismissStarted()
        await withCheckedContinuation { dismissGates.append($0) }
        dismissed[handleKey] = StowerDismissedAnchor(
            messageGUID: messageGUID,
            anchorTimestamp: anchorTimestamp
        )
        events.append(.dismissCompleted)
    }

    internal func undismiss(handleKey: String) {
        dismissed[handleKey] = nil
    }

    internal func retireDismissal(
        handleKey: String,
        messageGUID: String,
        anchorTimestamp: Date,
        at: Date
    ) {
        guard let anchor = dismissed[handleKey],
            anchor.messageGUID == messageGUID,
            anchor.anchorTimestamp == anchorTimestamp
        else {
            return
        }
        dismissed[handleKey] = nil
    }

    internal func mute(handleKey: String, at: Date) {
        mutedKeys.insert(handleKey)
    }

    internal func unmute(handleKey: String, at: Date) {
        mutedKeys.remove(handleKey)
    }

    /// Suspends until a gated dismiss has entered `dismiss`.
    ///
    /// Resumes immediately if one already has. Continuation-based — never a poll.
    internal func waitForDismissStarted() async {
        guard startedDismissals == 0 else { return }
        await withCheckedContinuation { dismissStartWaiters.append($0) }
    }

    /// Opens the gate: every suspended dismiss resumes and lands its row.
    internal func releaseDismissals() {
        events.append(.dismissalsReleased)
        let gates = dismissGates
        dismissGates = []
        for gate in gates {
            gate.resume()
        }
    }

    /// Records that the drain under test returned — the ordering probe's last mark.
    internal func noteDrainReturned() {
        events.append(.drainReturned)
    }

    private func noteDismissStarted() {
        startedDismissals += 1
        events.append(.dismissStarted)
        let waiters = dismissStartWaiters
        dismissStartWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
