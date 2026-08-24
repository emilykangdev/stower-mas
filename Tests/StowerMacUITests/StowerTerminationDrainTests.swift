import Foundation
import Testing

@testable import StowerMacUI

/// The public lifecycle-wire contract `StowerTerminationDrain` exposes (I-TerminationDrainContract).
///
/// An empty drain is a no-op, registration is deferred (never invoked at
/// registration time), a later registration replaces an earlier one rather
/// than stacking, and `drainPendingWork()` both invokes and fully awaits the
/// currently-registered operation before returning.
@MainActor
@Suite("StowerTerminationDrain")
internal struct StowerTerminationDrainTests {
    @Test(
        "drainPendingWork is a no-op when nothing has been registered (I-TerminationDrainContract)"
    )
    internal func emptyDrainIsNoOp() async {
        let drain = StowerTerminationDrain()
        await drain.drainPendingWork()
        // No registered operation and no crash/hang — the no-op contract itself
        // is the assertion; reaching this line is the pass condition.
    }

    @Test("registerDrain does not invoke the operation (I-TerminationDrainContract)")
    internal func registrationIsDeferred() {
        let drain = StowerTerminationDrain()
        let invoked = StowerTerminationDrainTests.InvocationFlag()
        drain.registerDrain { invoked.mark() }
        #expect(!invoked.wasMarked)
    }

    @Test("drainPendingWork invokes the registered operation (I-TerminationDrainContract)")
    internal func drainInvokesRegisteredOperation() async {
        let drain = StowerTerminationDrain()
        let invoked = StowerTerminationDrainTests.InvocationFlag()
        drain.registerDrain { invoked.mark() }
        await drain.drainPendingWork()
        #expect(invoked.wasMarked)
    }

    @Test("a later registerDrain call replaces the earlier operation (I-TerminationDrainContract)")
    internal func registrationReplacesPrevious() async {
        let drain = StowerTerminationDrain()
        let first = StowerTerminationDrainTests.InvocationFlag()
        let second = StowerTerminationDrainTests.InvocationFlag()
        drain.registerDrain { first.mark() }
        drain.registerDrain { second.mark() }
        await drain.drainPendingWork()
        #expect(!first.wasMarked)
        #expect(second.wasMarked)
    }

    @Test("drainPendingWork awaits the operation before returning (I-TerminationDrainContract)")
    internal func drainAwaitsOperationCompletion() async {
        let drain = StowerTerminationDrain()
        let events = StowerTerminationDrainTests.EventLog()
        drain.registerDrain {
            await events.append("operation-started")
            try? await Task.sleep(for: .milliseconds(20))
            await events.append("operation-finished")
        }
        await drain.drainPendingWork()
        await events.append("drain-returned")
        #expect(
            await events.values == ["operation-started", "operation-finished", "drain-returned"]
        )
    }

    /// A minimal `@MainActor` flag so a registered closure's invocation can be
    /// observed without any escaping-mutable-state warnings.
    @MainActor
    private final class InvocationFlag {
        private(set) var wasMarked = false
        func mark() { wasMarked = true }
    }

    /// Records the order operations actually ran in, so
    /// `drainAwaitsOperationCompletion` can prove `drainPendingWork()` doesn't
    /// return until the registered operation's own internal suspension resolves.
    private actor EventLog {
        private(set) var values: [String] = []
        func append(_ value: String) {
            values.append(value)
        }
    }
}
