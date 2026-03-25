//
//  TreemuxApp.swift
//  Treemux
//

import AppKit
import SwiftUI

/// Application orchestrator that owns the store and manages windows.
@MainActor
final class TreemuxApp {
    private var windowContext: WindowContext?

    /// Initializes the store, creates the main window, and shows it.
    func launch() {
        let store = WorkspaceStore()
        let window = WindowContext(store: store)
        window.show()
        self.windowContext = window
    }

    /// Persists workspace state before the application terminates.
    func shutdown() {
        windowContext?.store.saveWorkspaceState()
    }
}
