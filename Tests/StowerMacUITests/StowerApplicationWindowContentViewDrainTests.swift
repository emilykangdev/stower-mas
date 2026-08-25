import Foundation
import Testing

@testable import StowerMacUI

/// The Application Window content view's termination-drain wiring
/// (I-DrainOutlivesWindow).
///
/// This is the seam `ApplicationLifecycleDelegate` relies on at quit: closing the
/// Application Window tears down the view tree — and the `@State`-held
/// `StowerBoardViewModel` — BEFORE `applicationShouldTerminate` runs, so the
/// `registerDrain` closure must hold the board model strongly. A weak capture
/// hollows the drain into a silent no-op and the process can exit mid-write.
@MainActor
@Suite("StowerApplicationWindowContentView drain")
internal struct StowerApplicationWindowDrainTests {
    @Test(
        "the drain awaits an in-flight write after the view tree is gone (I-DrainOutlivesWindow)"
    )
    internal func drainOutlivesViewTree() async {
        let drain = StowerTerminationDrain()
        let store = StowerGatedDraftStore()
        var view: StowerApplicationWindowContentView? = StowerApplicationWindowContentView(
            startup: StowerFakeStartupProvider(),
            board: StowerSpyBoardDataSource(),
            draftStore: store,
            terminationDrain: drain
        )

        // Put a write in flight through the content view's board model; it suspends
        // inside the gated store — deliberately slow, exactly like a keystroke's
        // write-through racing a ⌘W.
        view?.boardModel.draftBinding(for: "raw:alice").wrappedValue = "must survive close"

        // Closing the window destroys the view value and its `@State`-held models;
        // only the drain's own capture can keep the board model alive past here.
        view = nil

        let drainTask = Task {
            await drain.drainPendingWork()
            await store.noteDrainReturned()
        }
        await store.waitForWriteStarted()
        await store.releaseWrites()
        await drainTask.value

        #expect(
            await store.events == [
                .writeStarted, .writesReleased, .writeCompleted, .drainReturned
            ]
        )
        #expect(await store.all()["raw:alice"]?.body == "must survive close")
    }
}
