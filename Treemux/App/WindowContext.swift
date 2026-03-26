//
//  WindowContext.swift
//  Treemux

import AppKit
import Combine
import SwiftUI

/// Manages the main NSWindow and hosts the SwiftUI content view.
@MainActor
final class WindowContext {
    let store: WorkspaceStore
    let themeManager: ThemeManager
    private var window: NSWindow?
    private var themeCancellable: AnyCancellable?

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
        applyThemeAppearance(to: window)
        window.makeKeyAndOrderFront(nil)

        self.window = window

        // Observe theme changes to keep the window appearance in sync.
        themeCancellable = themeManager.$activeTheme
            .dropFirst()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAppearance()
            }
    }

    /// Applies the active theme's appearance to the given window.
    private func applyThemeAppearance(to window: NSWindow) {
        window.appearance = themeManager.windowAppearance
        window.backgroundColor = themeManager.nsWindowBackgroundColor
    }

    /// Re-applies appearance to the current window (call when theme changes).
    func updateAppearance() {
        guard let window else { return }
        applyThemeAppearance(to: window)
    }
}
