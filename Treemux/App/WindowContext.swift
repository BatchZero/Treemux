//
//  WindowContext.swift
//  Treemux

import AppKit
import SwiftUI

/// Manages the main NSWindow and hosts the SwiftUI content view.
@MainActor
final class WindowContext {
    let store: WorkspaceStore
    let themeManager: ThemeManager
    private var window: NSWindow?

    init(store: WorkspaceStore) {
        self.store = store
        self.themeManager = ThemeManager(activeThemeID: store.settings.activeThemeID)
        themeManager.ensureBuiltInThemesExist()
    }

    /// Creates and shows the main application window.
    func show() {
        let host = NSHostingController(
            rootView: MainWindowView()
                .environmentObject(store)
                .environmentObject(themeManager)
        )

        let window = NSWindow(contentViewController: host)
        window.title = "Treemux"
        window.setContentSize(NSSize(width: 1200, height: 800))

        // Disable macOS window tabbing so the title bar stays focused on the
        // workspace controls we actually use.
        window.tabbingMode = .disallowed

        window.titlebarAppearsTransparent = false
        window.toolbarStyle = .unifiedCompact
        window.center()
        applyAppearance(to: window)
        window.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1.0)
        window.makeKeyAndOrderFront(nil)

        self.window = window
    }

    /// Applies the appearance setting to the window.
    private func applyAppearance(to window: NSWindow) {
        switch store.settings.appearance {
        case "dark":
            window.appearance = NSAppearance(named: .darkAqua)
        case "light":
            window.appearance = NSAppearance(named: .aqua)
        default:
            window.appearance = nil  // Follow system
        }
    }

    /// Re-applies appearance to the current window (call when settings change).
    func updateAppearance() {
        guard let window else { return }
        applyAppearance(to: window)
    }
}
