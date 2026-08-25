import Foundation
import StowerMessages
import Testing

@testable import StowerMacUI

/// The board view-model's quit-drain behaviors: `drainPendingWork()` genuinely
/// awaits the in-flight draft write (I-DrainAwaitsWrites) and the in-flight
/// triage action (I-DrainAwaitsTriage).
///
/// Many tests already call `drainPendingWork()` purely as a convenience await —
/// every one of them would still pass if it became a no-op. These two are the
/// guardrail: driven by the gated stores (`StowerGatedDraftStore` /
/// `StowerGatedTriageStore`), whose writes suspend on a continuation until the
/// test releases them, so each assertion is a race-free event order recorded on
/// the store actor — no sleeps, no polling.
@MainActor
@Suite internal struct StowerBoardViewModelDrainTests {
    /// A row whose draft/dismiss keys derive from `handle`.
    private func makeRow(chatID: String, handle: String) -> StowerBoardRow {
        StowerBoardRow(
            chatID: chatID,
            counterpart: "Person \(chatID)",
            counterpartHandle: handle,
            draftKey: StowerDraftKey.derive(forHandle: handle),
            lastMessageGUID: "guid-\(chatID)",
            lastMessageTimestamp: Date(timeIntervalSince1970: 1_000_000),
            monogram: "P",
            summary: StowerLastMessageSummary.make(kind: .text, text: "hi"),
            ageInDays: 2,
            deepLink: nil
        )
    }

    @Test(
        "drainPendingWork returns only after an in-flight draft write lands (I-DrainAwaitsWrites)"
    )
    internal func drainAwaitsInFlightWrite() async {
        let store = StowerGatedDraftStore()
        let model = StowerBoardViewModel(
            dataSource: StowerSpyBoardDataSource(),
            draftStore: store,
            onFailure: { _ in },
            sleep: { _ in }
        )

        // The write suspends inside the gated store — deliberately slow, still in
        // flight when the drain is awaited.
        model.draftBinding(for: "raw:alice").wrappedValue = "still writing"
        let drainTask = Task {
            await model.drainPendingWork()
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
        #expect(await store.all()["raw:alice"]?.body == "still writing")
    }

    @Test(
        "drainPendingWork returns only after an in-flight dismiss lands (I-DrainAwaitsTriage)"
    )
    internal func drainAwaitsInFlightDismiss() async {
        let triage = StowerGatedTriageStore()
        let model = StowerBoardViewModel(
            dataSource: StowerSpyBoardDataSource(),
            triage: triage,
            onFailure: { _ in },
            sleep: { _ in }
        )
        let row = makeRow(chatID: "a", handle: "+14155550100")

        // The dismiss suspends inside the gated store — a dismiss issued moments
        // before a quit.
        model.dismiss([row])
        let drainTask = Task {
            await model.drainPendingWork()
            await triage.noteDrainReturned()
        }
        await triage.waitForDismissStarted()
        await triage.releaseDismissals()
        await drainTask.value

        #expect(
            await triage.events == [
                .dismissStarted, .dismissalsReleased, .dismissCompleted, .drainReturned
            ]
        )
        #expect(await triage.dismissedMessages().keys.sorted() == [row.draftKey])
    }
}
