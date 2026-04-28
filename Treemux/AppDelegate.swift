// Treemux/AppDelegate.swift
import Cocoa
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var treemuxApp: TreemuxApp?
    private var settingsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        TreemuxGhosttyBootstrap.initialize()
        let app = TreemuxApp()
        app.launch()
        self.treemuxApp = app
        buildMainMenu()
        configureUpdater(checkInBackground: true)

        if let store = treemuxApp?.store {
            // Debounce so key-repeat hotkeys (e.g. holding ⌘= to crank the
            // terminal font) don't rebuild the entire main menu and reconfigure
            // the updater on every press. 150ms collapses bursts without making
            // genuine settings edits feel sluggish.
            settingsCancellable = store.$settings
                .dropFirst()
                .debounce(for: .milliseconds(150), scheduler: RunLoop.main)
                .sink { [weak self] _ in
                    self?.buildMainMenu()
                    self?.configureUpdater(checkInBackground: false)
                }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        treemuxApp?.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    // MARK: - Menu Bar

    /// Returns the key equivalent and modifier mask for a shortcut action.
    private func menuShortcut(for action: ShortcutAction) -> (key: String, modifiers: NSEvent.ModifierFlags)? {
        guard let store,
              let shortcut = TreemuxKeyboardShortcuts.effectiveShortcut(for: action, in: store.settings),
              let keyEquiv = shortcut.menuItemKeyEquivalent else {
            return nil
        }
        return (keyEquiv, shortcut.modifierFlags)
    }

    /// Applies a shortcut binding to a menu item.
    private func applyShortcut(_ action: ShortcutAction, to item: NSMenuItem) {
        if let binding = menuShortcut(for: action) {
            item.keyEquivalent = binding.key
            item.keyEquivalentModifierMask = binding.modifiers
        } else {
            item.keyEquivalent = ""
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()

        // App menu
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Treemux", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        applyShortcut(.openSettings, to: settingsItem)
        appMenu.addItem(settingsItem)
        let checkUpdatesItem = NSMenuItem(title: "Check for Updates…", action: #selector(checkForUpdates), keyEquivalent: "")
        checkUpdatesItem.target = self
        appMenu.addItem(checkUpdatesItem)
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
        let openItem = NSMenuItem(title: "Open Project…", action: #selector(openProject), keyEquivalent: "")
        openItem.target = self
        applyShortcut(.openProject, to: openItem)
        fileMenu.addItem(openItem)
        fileMenu.addItem(.separator())
        let closeItem = NSMenuItem(title: "Close Pane", action: #selector(closePane), keyEquivalent: "")
        closeItem.target = self
        applyShortcut(.closePane, to: closeItem)
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
        let sidebarItem = NSMenuItem(title: "Toggle Sidebar", action: #selector(toggleSidebar), keyEquivalent: "")
        sidebarItem.target = self
        applyShortcut(.toggleSidebar, to: sidebarItem)
        viewMenu.addItem(sidebarItem)
        viewMenu.addItem(.separator())
        let commandPaletteItem = NSMenuItem(title: "Command Palette", action: #selector(toggleCommandPalette), keyEquivalent: "")
        commandPaletteItem.target = self
        applyShortcut(.commandPalette, to: commandPaletteItem)
        viewMenu.addItem(commandPaletteItem)
        viewMenu.addItem(.separator())
        let fontIncreaseItem = NSMenuItem(title: String(localized: "Increase Terminal Font Size"), action: #selector(terminalFontSizeIncrease), keyEquivalent: "")
        fontIncreaseItem.target = self
        applyShortcut(.terminalFontSizeIncrease, to: fontIncreaseItem)
        viewMenu.addItem(fontIncreaseItem)
        let fontDecreaseItem = NSMenuItem(title: String(localized: "Decrease Terminal Font Size"), action: #selector(terminalFontSizeDecrease), keyEquivalent: "")
        fontDecreaseItem.target = self
        applyShortcut(.terminalFontSizeDecrease, to: fontDecreaseItem)
        viewMenu.addItem(fontDecreaseItem)
        let fontResetItem = NSMenuItem(title: String(localized: "Reset Terminal Font Size"), action: #selector(terminalFontSizeReset), keyEquivalent: "")
        fontResetItem.target = self
        applyShortcut(.terminalFontSizeReset, to: fontResetItem)
        viewMenu.addItem(fontResetItem)
        let viewMenuItem = NSMenuItem()
        viewMenuItem.submenu = viewMenu
        mainMenu.addItem(viewMenuItem)

        // Pane menu
        let paneMenu = NSMenu(title: "Pane")
        let splitHItem = NSMenuItem(title: "Split Horizontal", action: #selector(splitHorizontal), keyEquivalent: "")
        splitHItem.target = self
        applyShortcut(.splitHorizontal, to: splitHItem)
        paneMenu.addItem(splitHItem)
        let splitVItem = NSMenuItem(title: "Split Vertical", action: #selector(splitVertical), keyEquivalent: "")
        splitVItem.target = self
        applyShortcut(.splitVertical, to: splitVItem)
        paneMenu.addItem(splitVItem)
        paneMenu.addItem(.separator())
        let nextPaneItem = NSMenuItem(title: "Next Pane", action: #selector(focusNextPane), keyEquivalent: "")
        nextPaneItem.target = self
        applyShortcut(.focusNextPane, to: nextPaneItem)
        paneMenu.addItem(nextPaneItem)
        let prevPaneItem = NSMenuItem(title: "Previous Pane", action: #selector(focusPreviousPane), keyEquivalent: "")
        prevPaneItem.target = self
        applyShortcut(.focusPreviousPane, to: prevPaneItem)
        paneMenu.addItem(prevPaneItem)
        paneMenu.addItem(.separator())
        let zoomItem = NSMenuItem(title: "Zoom Pane", action: #selector(zoomPane), keyEquivalent: "")
        zoomItem.target = self
        applyShortcut(.zoomPane, to: zoomItem)
        paneMenu.addItem(zoomItem)
        let paneMenuItem = NSMenuItem()
        paneMenuItem.submenu = paneMenu
        mainMenu.addItem(paneMenuItem)

        // Tab menu
        let tabMenu = NSMenu(title: "Tab")
        let newTabItem = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")
        newTabItem.target = self
        applyShortcut(.newTab, to: newTabItem)
        tabMenu.addItem(newTabItem)
        let closeTabItem = NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "")
        closeTabItem.target = self
        applyShortcut(.closeTab, to: closeTabItem)
        tabMenu.addItem(closeTabItem)
        tabMenu.addItem(.separator())
        let nextTabItem = NSMenuItem(title: "Next Tab", action: #selector(nextTab), keyEquivalent: "")
        nextTabItem.target = self
        applyShortcut(.nextTab, to: nextTabItem)
        tabMenu.addItem(nextTabItem)
        let prevTabItem = NSMenuItem(title: "Previous Tab", action: #selector(previousTab), keyEquivalent: "")
        prevTabItem.target = self
        applyShortcut(.previousTab, to: prevTabItem)
        tabMenu.addItem(prevTabItem)
        let tabMenuItem = NSMenuItem()
        tabMenuItem.submenu = tabMenu
        mainMenu.addItem(tabMenuItem)

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
        store?.activeSessionController
    }

    @objc private func openSettings() {
        store?.showSettings = true
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
        store?.showCommandPalette.toggle()
    }

    @objc private func splitHorizontal() {
        guard let sc = sessionController, let focused = sc.focusedPaneID else { return }
        sc.splitPane(focused, axis: .vertical)
    }

    @objc private func splitVertical() {
        guard let sc = sessionController, let focused = sc.focusedPaneID else { return }
        sc.splitPane(focused, axis: .horizontal)
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

    @objc private func newTab() {
        store?.selectedWorkspace?.createTab()
    }

    @objc private func closeTab() {
        guard let ws = store?.selectedWorkspace, let tabID = ws.activeTabID else { return }
        ws.closeTab(tabID)
    }

    @objc private func nextTab() {
        store?.selectedWorkspace?.selectNextTab()
    }

    @objc private func previousTab() {
        store?.selectedWorkspace?.selectPreviousTab()
    }

    @objc private func terminalFontSizeIncrease() {
        adjustTerminalFontSizeOffset(by: +1)
    }

    @objc private func terminalFontSizeDecrease() {
        adjustTerminalFontSizeOffset(by: -1)
    }

    @objc private func terminalFontSizeReset() {
        applyTerminalFontSizeOffset(0)
    }

    private func adjustTerminalFontSizeOffset(by delta: Int) {
        guard let store else { return }
        let next = store.settings.terminal.fontSizeOffset + delta
        applyTerminalFontSizeOffset(next)
    }

    private func applyTerminalFontSizeOffset(_ value: Int) {
        guard let store else { return }
        var draft = store.settings
        draft.terminal.fontSizeOffset = TerminalSettings.clamp(value)
        guard draft.terminal != store.settings.terminal else { return }
        store.updateSettings(draft)
    }

    // MARK: - Updates

    private func configureUpdater(checkInBackground: Bool) {
        guard let settings = store?.settings.updates else { return }
        AppUpdaterController.shared.configure(
            automaticallyChecks: settings.automaticallyChecksForUpdates,
            automaticallyDownloads: settings.automaticallyDownloadsUpdates,
            checkInBackground: checkInBackground
        )
    }

    @objc private func checkForUpdates() {
        AppUpdaterController.shared.checkForUpdates()
    }
}
