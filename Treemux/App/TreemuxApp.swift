//
//  TreemuxApp.swift
//  Treemux
//

import AppKit
import SwiftUI

/// Application orchestrator that owns the store and manages windows.
@MainActor
final class TreemuxApp {
    private(set) var windowManager: WindowManager?

    /// The central workspace store, accessible after launch.
    var store: WorkspaceStore? { windowManager?.store }

    /// Initializes the store, creates the main window, restores any torn-off
    /// child windows from the previous session, and shows them.
    func launch() {
        let store = WorkspaceStore()
        let mgr = WindowManager(store: store)
        mgr.launchMain()
        mgr.restoreChildWindows() // rebuild detached child windows
        self.windowManager = mgr
    }

    /// Persists workspace state before the application terminates.
    func shutdown() {
        windowManager?.store.saveWorkspaceState()      // capture latest live tab state + clear caches
        windowManager?.store.flushPendingPersistence() // synchronous final write of both files
    }

    /// Called when the main window is about to close. Triggers cascade shutdown
    /// of all child windows and terminates the app.
    func handleMainWindowWillClose() {
        windowManager?.handleMainWindowWillClose()
    }
}
