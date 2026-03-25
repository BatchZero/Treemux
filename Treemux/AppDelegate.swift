// Treemux/AppDelegate.swift
import Cocoa

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var treemuxApp: TreemuxApp?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TreemuxGhosttyBootstrap.initialize()
        let app = TreemuxApp()
        app.launch()
        self.treemuxApp = app
        buildMainMenu()
    }

    func applicationWillTerminate(_ notification: Notification) {
        treemuxApp?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu Bar

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Treemux", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Treemux", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthersItem = NSMenuItem(title: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthersItem.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(hideOthersItem)
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Treemux", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let appMenuItem = NSMenuItem()
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File menu
        let fileMenu = NSMenu(title: "File")
        let openItem = NSMenuItem(title: "Open Project…", action: #selector(openProject), keyEquivalent: "o")
        openItem.target = self
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        let closeItem = NSMenuItem(title: "Close Pane", action: #selector(closePane), keyEquivalent: "w")
        closeItem.target = self
        fileMenu.addItem(closeItem)
        let fileMenuItem = NSMenuItem()
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit menu (standard)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let editMenuItem = NSMenuItem()
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // View menu
        let viewMenu = NSMenu(title: "View")
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "b")
        sidebarItem.target = self
        viewMenu.addItem(sidebarItem)
        viewMenu.addItem(.separator())
        let commandPaletteItem = NSMenuItem(title: "Command Palette", action: #selector(toggleCommandPalette), keyEquivalent: "P")
        commandPaletteItem.keyEquivalentModifierMask = [.command, .shift]
        commandPaletteItem.target = self
        viewMenu.addItem(commandPaletteItem)
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Pane menu
        let paneMenu = NSMenu(title: "Pane")
        let splitHItem = NSMenuItem(title: "Split Horizontal", action: #selector(splitHorizontal), keyEquivalent: "d")
        splitHItem.target = self
        paneMenu.addItem(splitHItem)
        let splitVItem = NSMenuItem(title: "Split Vertical", action: #selector(splitVertical), keyEquivalent: "D")
        splitVItem.keyEquivalentModifierMask = [.command, .shift]
        splitVItem.target = self
        paneMenu.addItem(splitVItem)
        paneMenu.addItem(.separator())
        let nextPaneItem = NSMenuItem(title: "Next Pane", action: #selector(focusNextPane), keyEquivalent: "]")
        nextPaneItem.target = self
        paneMenu.addItem(nextPaneItem)
        let prevPaneItem = NSMenuItem(title: "Previous Pane", action: #selector(focusPreviousPane), keyEquivalent: "[")
        prevPaneItem.target = self
        paneMenu.addItem(prevPaneItem)
        paneMenu.addItem(.separator())
        let zoomItem = NSMenuItem(title: "Zoom Pane", action: #selector(zoomPane), keyEquivalent: "\r")
        zoomItem.keyEquivalentModifierMask = [.command, .shift]
        zoomItem.target = self
        paneMenu.addItem(zoomItem)
        let paneMenuItem = NSMenuItem()
        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        // Window menu
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        let windowMenuItem = NSMenuItem()
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }

    // MARK: - Menu Actions

    private var store: WorkspaceStore? {
        treemuxApp?.store
    }

    private var sessionController: WorkspaceSessionController? {
        store?.selectedWorkspace?.sessionController
    }

    @objc private func openSettings() {
        // Settings are handled via the SettingsSheet in SwiftUI
    }

    @objc private func openProject() {
        store?.addWorkspaceFromOpenPanel()
    }

    @objc private func closePane() {
        guard let sc = sessionController, let focused = sc.focusedPaneID else { return }
        sc.closePane(focused)
    }

    @objc private func toggleSidebar() {
        NSApp.keyWindow?.firstResponder?.tryToPerform(
            #selector(NSSplitViewController.toggleSidebar(_:)),
            with: nil
        )
    }

    @objc private func toggleCommandPalette() {
        // Command palette is handled in SwiftUI overlay
    }

    @objc private func splitHorizontal() {
        guard let sc = sessionController, let focused = sc.focusedPaneID else { return }
        sc.splitPane(focused, axis: .horizontal)
    }

    @objc private func splitVertical() {
        guard let sc = sessionController, let focused = sc.focusedPaneID else { return }
        sc.splitPane(focused, axis: .vertical)
    }

    @objc private func focusNextPane() {
        sessionController?.focusNext()
    }

    @objc private func focusPreviousPane() {
        sessionController?.focusPrevious()
    }

    @objc private func zoomPane() {
        sessionController?.toggleZoom()
    }
}
