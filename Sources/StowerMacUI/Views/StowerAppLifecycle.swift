/// The MAS app's quit policy: the pure rules behind the app delegate's AppKit
/// wiring.
///
/// Decided as R1 on 2026-08-24. Stower is a single-window app, and App Review rejected the state where closing
/// the Application Window leaves the app running with no menu item to bring it
/// back. The chosen remedy is the rejection's second branch: save data and quit
/// when the Application Window closes — always. The two rules live here, in the
/// testable library, so a silent flip of either (the `true`, or the identifier
/// match) fails a unit test on every commit (I-QuitPolicyTested) instead of
/// surviving until the manual checklist. The AppKit wiring — the notification
/// subscription and `NSApp.terminate` — stays in the delegate, mirroring how
/// `StowerTerminationDrain` keeps quit-time logic testable while the app entry
/// stays thin.
public struct StowerAppLifecycle: Sendable {
    /// The `Window(_:id:)` scene identifier of the Application Window this policy
    /// recognizes.
    private let applicationWindowSceneIdentifier: String

    /// Creates the policy recognizing the Application Window by its scene identifier.
    ///
    /// - Parameter applicationWindowSceneIdentifier: The Application Window's
    ///   `Window(_:id:)` scene identifier, as declared by the app target.
    public init(applicationWindowSceneIdentifier: String) {
        self.applicationWindowSceneIdentifier = applicationWindowSceneIdentifier
    }

    /// Whether closing the app's last window quits the app: always `true` — the
    /// single-window App Review remedy.
    ///
    /// `ApplicationLifecycleDelegate.applicationShouldTerminateAfterLastWindowClosed`
    /// forwards this answer verbatim.
    public var quitsAfterLastWindowClosed: Bool { true }

    /// Whether the app should quit when the window with `identifier` closes: `true`
    /// iff it is the Application Window.
    ///
    /// This is the case `quitsAfterLastWindowClosed` cannot cover — closing the
    /// Application Window while Settings is still open is not a last-window close
    /// (JC3: quit anyway; Settings holds no unsaved state). A `nil` (unidentified)
    /// window never quits.
    public func shouldQuit(onCloseOf identifier: String?) -> Bool {
        identifier == applicationWindowSceneIdentifier
    }
}
