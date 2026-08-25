import Foundation

@testable import StowerMacUI

/// The ordered milestones `StowerGatedDraftStore` records, so a drain test can
/// assert the drain returned only AFTER the gated write completed.
internal enum StowerGatedDraftStoreEvent: Equatable, Sendable {
    /// A gated `upsert` was entered — the write is now in flight, suspended.
    case writeStarted

    /// The test opened the gate (`releaseWrites`).
    case writesReleased

    /// A gated `upsert` resumed past the gate and landed its entry.
    case writeCompleted

    /// The drain under test returned (recorded via `noteDrainReturned`).
    case drainReturned
}

/// A draft store whose `upsert` suspends on a continuation until the test releases
/// it — a deterministically SLOW write, with every milestone serialized through
/// this actor so ordering assertions are race-free (no sleeps, no polling).
///
/// Purpose-built for the drain invariants (I-DrainOutlivesWindow,
/// I-DrainAwaitsWrites): a drain that no-ops records `.drainReturned` before
/// `.writeCompleted`, so the expected event order fails loudly.
internal actor StowerGatedDraftStore: StowerDraftStoring {
    private var entries: [String: StowerDraftEntry] = [:]
    private var writeGates: [CheckedContinuation<Void, Never>] = []
    private var writeStartWaiters: [CheckedContinuation<Void, Never>] = []
    private var startedWrites = 0

    /// The milestones observed so far, in actor-serialized order.
    private(set) internal var events: [StowerGatedDraftStoreEvent] = []

    /// Creates an empty gated store with the write gate closed.
    internal init() {}

    internal func all() -> [String: StowerDraftEntry] {
        entries
    }

    internal func upsert(key: String, body: String) async {
        noteWriteStarted()
        await withCheckedContinuation { writeGates.append($0) }
        entries[key] = StowerDraftEntry(body: body, updatedAt: Date())
        events.append(.writeCompleted)
    }

    internal func delete(key: String) {
        entries[key] = nil
    }

    internal func markSent(key: String) {
        guard let entry = entries[key] else { return }
        entries[key] = StowerDraftEntry(
            body: entry.body,
            updatedAt: entry.updatedAt,
            resolvedAt: Date()
        )
    }

    internal func unmarkSent(key: String) {
        guard let entry = entries[key] else { return }
        entries[key] = StowerDraftEntry(
            body: entry.body,
            updatedAt: entry.updatedAt,
            resolvedAt: nil
        )
    }

    /// Suspends until a gated write has entered `upsert`.
    ///
    /// Resumes immediately if one already has. Continuation-based — never a poll.
    internal func waitForWriteStarted() async {
        guard startedWrites == 0 else { return }
        await withCheckedContinuation { writeStartWaiters.append($0) }
    }

    /// Opens the gate: every suspended write resumes and lands its entry.
    internal func releaseWrites() {
        events.append(.writesReleased)
        let gates = writeGates
        writeGates = []
        for gate in gates {
            gate.resume()
        }
    }

    /// Records that the drain under test returned — the ordering probe's last mark.
    internal func noteDrainReturned() {
        events.append(.drainReturned)
    }

    private func noteWriteStarted() {
        startedWrites += 1
        events.append(.writeStarted)
        let waiters = writeStartWaiters
        writeStartWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}
