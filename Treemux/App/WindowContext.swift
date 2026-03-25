//
//  WindowContext.swift
//  Treemux
//

import AppKit
import SwiftUI

/// Manages the main NSWindow and hosts the SwiftUI content view.
@MainActor
final class WindowContext {
    let store: WorkspaceStore
    private var window: NSWindow?

    init(store: WorkspaceStore) {
        self.store = store
    }

    /// Creates and shows the main application window.
    func show() {
        let contentView = MainWindowView()
            .environmentObject(store)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Treemux"
        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
