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

        // Attach an NSToolbar so SwiftUI .toolbar items render in the title bar.
        let toolbar = NSToolbar(identifier: "MainToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1.0)
        window.makeKeyAndOrderFront(nil)
        self.window = window
    }
}
