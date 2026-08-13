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
        self.windowManager = mgr
        mgr.launchMain()
        // Workspace records load synchronously, but local git worktrees are
        // discovered asynchronously. Restore only after that discovery so a
        // valid persisted worktree ref is not mistaken for stale state.
        Task { [weak store, weak mgr] in
            guard let store, let mgr else { return }
            await store.waitForInitialWorkspaceRefresh()
            mgr.restoreChildWindows()
        }
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

    /// Recovery for the cancel case (C2): if the cascade tore down the main
    /// window but `applicationShouldTerminate` was cancelled (user clicked
    /// Cancel on the unsaved-changes prompt), the app is left alive with no
    /// visible window. This rebuilds the main window in that situation so the
    /// user is never stranded. No-op when the main window is already present
    /// (the normal multi-window case where children open/close independently).
    func ensureMainWindowAfterCascadeIfNeeded() {
        windowManager?.recoverMainWindowIfCancelled()
    }
}
