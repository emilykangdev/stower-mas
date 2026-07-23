//
//  StowerMacMASApp.swift
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
struct StowerMacMASApp: App {
    @NSApplicationDelegateAdaptor(StowerAppDelegate.self) private var appDelegate

    /// The app-owned `UndoManager` (A4): ONE stable instance the board's dismiss/undo
    /// registrations drive, so the undo stack survives a board reload (unlike
    /// `@Environment(\.undoManager)`, which rebinds when the list rebuilds). The board
    /// view-model flips `groupsByEvent` off so each dismiss is exactly one undo step
    /// (I6). Both ⌘Z and the draining-bar Undo button call `undo()` on this instance.
    private let undoManager = UndoManager()

    var body: some Scene {
        WindowGroup {
            StowerRootView(
                flusher: appDelegate.flusher,
                undoManager: undoManager,
                analyticsReporter: StowerNoOpAnalyticsReporter(),
                licenseGate: nil
            )
        }
        .commands {
            // Stower is a single-board app over one local data set: remove
            // File > New Window (⌘N) so a user can't spawn a second board
            // window. macOS already prevents launching a second *process* of an
            // app; this closes the in-app multi-window path.
            CommandGroup(replacing: .newItem) {}
            // ⌘Z / ⌘⇧Z (A4/B1 spike — resolved WITHOUT an AppKit responder bridge in the
            // board; the only AppKit here is forwarding the action the standard Edit-menu
            // item already uses). We replace `.undoRedo` so ⌘Z can reach the board's undo,
            // but FIRST forward `undo:`/`redo:` down the responder chain — exactly what the
            // default Undo item does (`action: undo:, target: nil`). When a draft-composer
            // text field is first responder it handles its own text undo and we stop;
            // ONLY when nothing in the chain handles it does the board dismiss-undo run.
            // So text-field undo is preserved and ⌘Z reverses a dismiss when not editing.
            CommandGroup(replacing: .undoRedo) {
                Button("Undo") { performUndo() }
                    .keyboardShortcut("z", modifiers: .command)
                Button("Redo") { performRedo() }
                    .keyboardShortcut("z", modifiers: [.command, .shift])
            }
        }

        Settings {
            StowerSettingsView()  // No additional panes (no Updates tab)
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
/// loses nothing (JC2). No analytics session end reporting (no analytics backend).
final class StowerAppDelegate: NSObject, NSApplicationDelegate {
    /// Wired to the board view-model's `flushAll()` by `StowerRootView`.
    let flusher = StowerTerminationFlusher()

    func applicationShouldTerminate(
        _ sender: NSApplication
    ) -> NSApplication.TerminateReply {
        // Drain pending draft writes, then let the app quit. No analytics
        // session-end report — there is no analytics backend in the MAS target.
        Task { @MainActor in
            await flusher.flushPendingWork()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}