import Foundation

/// Lets the app delegate drain the board's in-flight draft writes on quit.
///
/// `StowerApplication.swift` (outside the SPM tree) holds one of these, hands it
/// to `StowerApplicationWindowContentView`, and awaits `drainPendingWork()` from
/// `applicationShouldTerminate` so a graceful quit loses no draft (JC2). The
/// tested guarantee is `StowerBoardViewModel.drainPendingWork()`; this is the
/// thin lifecycle wire to it.
@MainActor
public final class StowerTerminationDrain {
    private var drainOperation: (@MainActor () async -> Void)?

    /// Creates a drain with no work wired yet.
    public init() {}

    /// Wires the work to run on termination (the board view-model's `drainPendingWork`).
    internal func registerDrain(_ drainOperation: @escaping @MainActor () async -> Void) {
        self.drainOperation = drainOperation
    }

    /// Awaits the wired termination work; a no-op if nothing was wired.
    public func drainPendingWork() async {
        await drainOperation?()
    }
}
