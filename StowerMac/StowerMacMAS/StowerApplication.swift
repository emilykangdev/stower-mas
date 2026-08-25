//
//  StowerApplication.swift
//  StowerMacMAS
//
//  Created by Emily Kang on 7/22/26.
//

import AppKit
import StowerMacUI
import SwiftUI

/// MAS-distributed Stower: no Sparkle, no Sentry, no TelemetryDeck, no diagnostics
/// initialization, no analytics reporting — the app is privacy-first on the App Store.
@main
struct ApplicationDefinition: App {
    @NSApplicationDelegateAdaptor(ApplicationLifecycleDelegate.self)
    private var applicationLifecycleDelegate

    /// The app-owned `UndoManager` (A4): ONE stable instance the board's dismiss/undo
    /// registrations drive, so the undo stack survives a board reload (unlike
    /// `@Environment(\.undoManager)`, which rebinds when the list rebuilds). The board
    /// view-model flips `groupsByEvent` off so each dismiss is exactly one undo step
    /// (I6). Both ⌘Z and the draining-bar Undo button call `undo()` on this instance.
    private let undoManager = UndoManager()

    /// The single Application Window's scene identifier. A single-instance
    /// `Window` scene (never the multi-instance group scene type) is what puts
    /// "Stower" in the Window menu's `.singleWindowList` group and what makes the
    /// app quit when its last window closes — the App Review fix; see
    /// Docs/MacAppContract.md §10. `fileprivate` (not `private`) because
    /// `ApplicationLifecycleDelegate` — a different type in this file — needs it
    /// to recognize the closing window.
    fileprivate static let applicationWindowSceneID = "stower.window.main"

    /// Both the window title and the `.singleWindowList` menu-item label.
    fileprivate static let applicationWindowTitle = "Stower"

    var body: some Scene {
        applicationWindowScene
        settingsScene
    }

    private var applicationWindowScene: some Scene {
        Window(Self.applicationWindowTitle, id: Self.applicationWindowSceneID) {
            ApplicationWindowContentConstructionView(
                terminationDrain: applicationLifecycleDelegate.terminationDrain,
                undoManager: undoManager
            )
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { performUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }
    }

    private var settingsScene: some Scene {
        Settings {
            StowerSettingsView()
        }
    }

    /// Forwards to the focused responder's text undo; falls back to the board undo when
    /// nothing in the responder chain handled it (no text field is editing).
    private func performUndo() {
        if !NSApp.sendAction(Self.undoActionSelector, to: nil, from: nil) {
            undoManager.undo()
        }
    }

    /// The redo mirror of `performUndo`.
    private func performRedo() {
        if !NSApp.sendAction(Self.redoActionSelector, to: nil, from: nil) {
            undoManager.redo()
        }
    }

    /// The standard first-responder Edit-menu undo/redo actions (`undo:` / `redo:`).
    private static let undoActionSelector = Selector(("undo:"))
    private static let redoActionSelector = Selector(("redo:"))
}

/// The app delegate: drains in-flight draft writes on quit so a graceful Cmd-Q
/// loses nothing (JC2), and makes closing the Application Window quit — always —
/// so Stower can never run windowless with no way back (the App Review
/// rejection). No analytics session end reporting (no analytics backend).
final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    /// Wired to the board view-model's `drainPendingWork()` by
    /// `StowerApplicationWindowContentView`.
    let terminationDrain = StowerTerminationDrain()

    /// The quit rules, as a pure type unit-tested in StowerMacUI
    /// (I-QuitPolicyTested). This delegate is thin wiring: it receives AppKit
    /// events and forwards the policy's answer — no rule lives inline here.
    private let quitPolicy = StowerAppLifecycle(
        applicationWindowSceneIdentifier: ApplicationDefinition.applicationWindowSceneID
    )

    /// Observes Application-Window closes so the app quits even when Settings is
    /// still open (JC3) — that close is not a last-window close, so
    /// `applicationShouldTerminateAfterLastWindowClosed` alone cannot cover it.
    /// Subscribes to `NSWindow.willCloseNotification` ONLY — never
    /// `willMiniaturizeNotification`: minimizing must never quit
    /// (I-MinimizeNeverQuits).
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowWillClose(_:)),
            name: NSWindow.willCloseNotification,
            object: nil
        )
    }

    /// Save data and quit when the last window closes — the App Review
    /// single-window remedy ("no menu item to re-open the Application Window"),
    /// declared in source. Deliberately redundant with the `Window` scene's
    /// documented quit-on-close: core behavior must not rest on a scene type's
    /// implicit semantics. Returning `true` makes AppKit invoke
    /// `applicationShouldTerminate(_:)`, so this route drains too.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        quitPolicy.quitsAfterLastWindowClosed
    }

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Drain pending draft writes, then let the app quit. No analytics
        // session-end report — there is no analytics backend in the MAS target.
        Task { @MainActor in
            await terminationDrain.drainPendingWork()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    /// Terminates when the closing window is the Application Window, decided by
    /// `StowerAppLifecycle.shouldQuit(onCloseOf:)` against the window's
    /// identifier. `NSApp.terminate` routes through `applicationShouldTerminate`,
    /// so this path parks for in-flight writes exactly like ⌘Q, and quitting
    /// closes Settings as a consequence rather than dismissing it separately.
    @objc private func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        let identifier = window.identifier?.rawValue
        #if DEBUG
            // A2 (unverified): SwiftUI setting `NSWindow.identifier` from the
            // `Window(id:)` scene id is undocumented — this log is how the first
            // manual run confirms or refutes it. Fallback if it never matches: an
            // NSViewRepresentable that hands its hosting window to this delegate.
            NSLog("Stower windowWillClose identifier=%@", identifier ?? "<nil>")
        #endif
        guard quitPolicy.shouldQuit(onCloseOf: identifier) else { return }
        NSApp.terminate(nil)
    }
}

/// Builds the Application Window content, surfacing a startup failure if an
/// essential store (the precious drafts database) can't be opened on a true
/// disk-level fault. No diagnostics backends, no license gating — MAS
/// privacy-first build.
private struct ApplicationWindowContentConstructionView: View {
    @State private var applicationWindowContentResult:
        Result<StowerApplicationWindowContentView, Error>

    init(terminationDrain: StowerTerminationDrain, undoManager: UndoManager) {
        _applicationWindowContentResult = State(
            initialValue: Result {
                try StowerApplicationWindowContentView(
                    terminationDrain: terminationDrain,
                    undoManager: undoManager,
                    analyticsReporter: StowerNoOpAnalyticsReporter()
                )
            }
        )
    }

    var body: some View {
        switch applicationWindowContentResult {
        case .success(let view):
            view
        case .failure:
            ContentUnavailableView(
                "Stower couldn't open your data",
                systemImage: "externaldrive.badge.exclamationmark",
                description: Text(
                    "There wasn't enough room or permission to open Stower's storage. "
                        + "Free disk space, verify Stower can access its storage "
                        + "location, and reopen Stower."
                )
            )
        }
    }
}
