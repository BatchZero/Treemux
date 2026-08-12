//
//  WindowContext.swift
//  Treemux

import AppKit
import Combine
import OSLog
import SwiftUI

/// Manages the main NSWindow and hosts the SwiftUI content view.
///
/// A `WindowContext` owns a single `NSWindow` plus its theme/locale observers.
/// `Kind` distinguishes the main workspace window from a torn-off detached
/// window so each can resolve its own root view and frame-autosave key.
@MainActor
final class WindowContext {
    /// The kind of window this context owns. Drives root-view dispatch and the
    /// frame-autosave key so each torn-off window persists to its own slot.
    enum Kind {
        /// The primary workspace window hosting the full sidebar + tabs.
        case main
        /// A torn-off sidebar node shown in its own window. The associated
        /// `DetachedNodeRef` identifies which node was detached; later tasks
        /// swap in the real root view keyed off this ref.
        case detached(DetachedNodeRef)
    }

    let store: WorkspaceStore
    let themeManager: ThemeManager
    let languageManager: LanguageManager
    let kind: Kind
    private var window: NSWindow?
    private var themeCancellable: AnyCancellable?
    private var localeCancellable: AnyCancellable?

    /// Interval token spanning ThemeManager construction (init) through
    /// makeKeyAndOrderFront (show); nil once the interval has been closed.
    private var windowConstructSignpost: OSSignpostIntervalState?

    init(store: WorkspaceStore, kind: Kind = .main) {
        self.store = store
        self.kind = kind
        let sp = PerfSignpost.begin("window-construct")
        self.themeManager = ThemeManager(activeThemeID: store.settings.activeThemeID)
        self.languageManager = LanguageManager(languageCode: store.settings.language)
        self.windowConstructSignpost = sp
    }

    /// Stable per-window autosave key for system-managed frame persistence.
    /// The main window uses a fixed key; each detached window derives a unique
    /// key from its `DetachedNodeRef` so torn-off windows restore independently.
    private var frameAutosaveName: String {
        switch kind {
        case .main:
            return "treemux.main"
        case .detached(let ref):
            return "treemux.detach." + ref.autosaveKeySuffix
        }
    }

    /// Window title shown in the title bar; detached windows refine this with
    /// the node name in a later task.
    private var windowTitle: String {
        switch kind {
        case .main:
            return "Treemux"
        case .detached:
            // Refined in a later task with the detached node's name.
            return "Treemux"
        }
    }

    /// Creates and shows the window, dispatching the root view by `kind`.
    func show() {
        let rootView = makeRootView()
        let host = NSHostingController(
            rootView: rootView
                .environment(store)
                .environment(themeManager)
                .environment(languageManager)
                .environment(\.locale, languageManager.locale)
        )

        let window = NSWindow(contentViewController: host)
        window.title = windowTitle
        window.setContentSize(NSSize(width: 1200, height: 800))

        // Disable macOS window tabbing so the title bar stays focused on the
        // workspace controls we actually use.
        window.tabbingMode = .disallowed

        // Transparent titlebar lets the themed window background show through the
        // toolbar area, so the title bar shares the app's surface tone instead of
        // the opaque system material (which reads as a stark white strip in light
        // themes and breaks the single-surface look against the sidebar).
        window.titlebarAppearsTransparent = true
        window.toolbarStyle = .unifiedCompact

        // System-managed frame persistence: setFrameAutosaveName returns true
        // when it synchronously restored a saved frame. Only center on a fresh
        // launch (no saved frame) so a restored position is respected.
        let restored = window.setFrameAutosaveName(frameAutosaveName)
        if !restored {
            window.center()
        }

        applyThemeAppearance(to: window)
        window.makeKeyAndOrderFront(nil)
        if let sp = windowConstructSignpost {
            PerfSignpost.end("window-construct", sp)
            windowConstructSignpost = nil
        }

        self.window = window

        // Observe theme changes to keep the window appearance in sync.
        themeCancellable = themeManager.activeThemePublisher
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.updateAppearance()
            }

        // Observe language changes to update the root view's locale environment.
        // Re-build via makeRootView() so detached windows update their root too.
        localeCancellable = languageManager.localePublisher
            .receive(on: RunLoop.main)
            .sink { [weak host, weak self] newLocale in
                guard let self, let host else { return }
                host.rootView = self.makeRootView()
                    .environment(self.store)
                    .environment(self.themeManager)
                    .environment(self.languageManager)
                    .environment(\.locale, newLocale)
            }
    }

    /// Closes the window WITHOUT triggering detached-node restore side-effects.
    /// Used during cascade shutdown (a later task) so closing a detached window
    /// during teardown doesn't round-trip through the restore path.
    func closeImmediately() {
        window?.close()
        window = nil
    }

    /// Builds the SwiftUI root view for this window based on `kind`. The
    /// detached case is a placeholder until a later task swaps in the real
    /// `DetachedRootView`.
    private func makeRootView() -> some View {
        switch kind {
        case .main:
            return AnyView(MainWindowView())
        case .detached(let ref):
            // Placeholder until DetachedRootView lands in a later task.
            return AnyView(Text("Detached: \(String(describing: ref))"))
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
