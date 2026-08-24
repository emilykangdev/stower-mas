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

    var body: some Scene {
        applicationWindowScene
        settingsScene
    }

    private var applicationWindowScene: some Scene {
        WindowGroup {
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
/// loses nothing (JC2). No analytics session end reporting (no analytics backend).
final class ApplicationLifecycleDelegate: NSObject, NSApplicationDelegate {
    /// Wired to the board view-model's `drainPendingWork()` by
    /// `StowerApplicationWindowContentView`.
    let terminationDrain = StowerTerminationDrain()

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
