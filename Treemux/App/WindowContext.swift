//
//  WindowContext.swift
//  Treemux

import AppKit
import SwiftUI

/// NSToolbar subclass that blocks NSSplitViewController from injecting
/// its automatic .toggleSidebar item — we provide our own in SwiftUI.
final class SidebarFilteredToolbar: NSToolbar {
    override func insertItem(
        withItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        at index: Int
    ) {
        guard itemIdentifier != .toggleSidebar else { return }
        super.insertItem(withItemIdentifier: itemIdentifier, at: index)
    }
}

/// Wraps SwiftUI's toolbar delegate to filter out .toggleSidebar items
/// that NSSplitViewController injects via the delegate mechanism.
/// Uses forwardingTarget(for:) to transparently pass through any private
/// SwiftUI delegate methods we don't explicitly override.
final class ToolbarDelegateProxy: NSObject, NSToolbarDelegate {
    private let wrapped: NSToolbarDelegate

    init(wrapping delegate: NSToolbarDelegate) {
        self.wrapped = delegate
        super.init()
    }

    // Forward any unknown selectors (including private SwiftUI ones)
    // to the original delegate so we don't break SwiftUI toolbar management.
    override func forwardingTarget(for aSelector: Selector!) -> Any? {
        if wrapped.responds(to: aSelector) { return wrapped }
        return super.forwardingTarget(for: aSelector)
    }

    override func responds(to aSelector: Selector!) -> Bool {
        if super.responds(to: aSelector) { return true }
        return wrapped.responds(to: aSelector)
    }

    // MARK: - NSToolbarDelegate (filter .toggleSidebar)

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let ids = wrapped.toolbarDefaultItemIdentifiers?(toolbar) ?? []
        return ids.filter { $0 != .toggleSidebar }
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        let ids = wrapped.toolbarAllowedItemIdentifiers?(toolbar) ?? []
        return ids.filter { $0 != .toggleSidebar }
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        if itemIdentifier == .toggleSidebar { return nil }
        return wrapped.toolbar?(
            toolbar,
            itemForItemIdentifier: itemIdentifier,
            willBeInsertedIntoToolbar: flag
        )
    }
}

/// Manages the main NSWindow and hosts the SwiftUI content view.
@MainActor
final class WindowContext {
    let store: WorkspaceStore
    private var window: NSWindow?
    private var toolbarDelegateProxy: ToolbarDelegateProxy?

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

        // Use SidebarFilteredToolbar to block insertItem(.toggleSidebar) calls
        let toolbar = SidebarFilteredToolbar(identifier: "MainToolbar")
        toolbar.displayMode = .iconOnly
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.contentView = NSHostingView(rootView: contentView)
        window.center()
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.07, green: 0.08, blue: 0.09, alpha: 1.0)
        window.makeKeyAndOrderFront(nil)
        self.window = window

        // After SwiftUI has configured the toolbar delegate, wrap it to also
        // filter .toggleSidebar from delegate-based item resolution.
        installDelegateProxy(for: toolbar)
    }

    private func installDelegateProxy(for toolbar: NSToolbar) {
        DispatchQueue.main.async { [weak self] in
            guard let self, let delegate = toolbar.delegate else { return }
            let proxy = ToolbarDelegateProxy(wrapping: delegate)
            toolbar.delegate = proxy
            self.toolbarDelegateProxy = proxy

            // Also remove any .toggleSidebar items already present
            for index in (0..<toolbar.items.count).reversed() {
                if toolbar.items[index].itemIdentifier == .toggleSidebar {
                    toolbar.removeItem(at: index)
                }
            }
        }
    }
}
