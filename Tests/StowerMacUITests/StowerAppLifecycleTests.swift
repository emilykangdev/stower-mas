import Testing

@testable import StowerMacUI

/// The MAS quit policy's two rules (I-QuitPolicyTested): last-window-close always
/// quits, and a window close quits iff the closing window is the Application
/// Window — so a silent `true → false` flip or identifier-match change fails
/// here, on every commit, not on the manual checklist.
@Suite("StowerAppLifecycle")
internal struct StowerAppLifecycleTests {
    /// The scene id under test — the same value `ApplicationDefinition` declares
    /// for its `Window(_:id:)` scene.
    private static let applicationWindowSceneID = "stower.window.main"

    /// An identifier no scene in the app declares.
    private static let unrelatedWindowID = "some.other.window"

    private let lifecycle = StowerAppLifecycle(
        applicationWindowSceneIdentifier: Self.applicationWindowSceneID
    )

    @Test("closing the last window always quits (I-QuitPolicyTested)")
    internal func lastWindowCloseQuits() {
        #expect(lifecycle.quitsAfterLastWindowClosed)
    }

    @Test("closing the Application Window quits (I-QuitPolicyTested)")
    internal func applicationWindowCloseQuits() {
        #expect(lifecycle.shouldQuit(onCloseOf: Self.applicationWindowSceneID))
    }

    @Test("closing a differently-identified window never quits (I-QuitPolicyTested)")
    internal func otherWindowCloseNeverQuits() {
        #expect(!lifecycle.shouldQuit(onCloseOf: Self.unrelatedWindowID))
    }

    @Test("closing an unidentified window never quits (I-QuitPolicyTested)")
    internal func unidentifiedWindowCloseNeverQuits() {
        #expect(!lifecycle.shouldQuit(onCloseOf: nil))
    }
}
