//
//  WindowContext.swift
//  Treemux

import AppKit
import Combine
import Observation
import OSLog
import SwiftUI

/// Routes workspace-sensitive commands to the content displayed by one window.
/// Main-window commands follow the store selection, while detached windows keep
/// an independent workspace/worktree selection.
@MainActor
@Observable
final class WindowCommandContext {
    private let store: WorkspaceStore
    private let followsStoreSelection: Bool
    private var workspaceID: UUID?
    private var worktreePath: String?

    /// Changes whenever a command mutates an inactive worktree's tab state.
    /// Detached views read this value so SwiftUI refreshes after the temporary
    /// worktree switch has restored the main window's selection.
    private(set) var revision = 0

    var showCommandPalette = false

    var workspace: WorkspaceModel? {
        if followsStoreSelection {
            return store.selectedWorkspace
        }
        guard let workspaceID else { return nil }
        return store.workspaces.first { $0.id == workspaceID }
    }

    /// The active file-browser controller in this window, if its selected tab
    /// is a file tab. Used as the target of the save notification so Cmd+S
    /// never fans out to editors hosted by other windows.
    var activeFileBrowserController: FileBrowserTabController? {
        guard let result = withSelectedWorktree({ workspace -> FileBrowserTabController? in
            guard let tabID = workspace.activeTabID,
                  workspace.tabs.first(where: { $0.id == tabID })?.kind == .fileBrowser else {
                return nil
            }
            return workspace.fileBrowserController(forTabID: tabID)
        }) else { return nil }
        return result
    }

    init(store: WorkspaceStore, kind: WindowContext.Kind) {
        self.store = store
        switch kind {
        case .main:
            followsStoreSelection = true
            workspaceID = nil
            worktreePath = nil
        case .detached(let ref):
            followsStoreSelection = false
            switch ref {
            case .workspace(let id):
                workspaceID = id
                worktreePath = nil
            case .worktree(let workspaceID, let worktreeID):
                self.workspaceID = workspaceID
                worktreePath = store.workspaces
                    .first(where: { $0.id == workspaceID })?
                    .worktrees.first(where: { $0.id == worktreeID })?
                    .path.path
            case .remoteGroup(let key):
                workspaceID = store.workspacesInRemoteGroup(key).first?.id
                worktreePath = nil
            }
        }
    }

    /// Updates a detached window's local navigation selection without changing
    /// the main window's global store selection.
    func updateSelection(workspace: WorkspaceModel?, worktreePath: String?) {
        guard !followsStoreSelection else { return }
        workspaceID = workspace?.id
        self.worktreePath = worktreePath
    }

    @discardableResult
    func perform(_ action: ShortcutAction) -> Bool {
        switch action {
        case .commandPalette:
            showCommandPalette.toggle()
            return true
        case .newTab:
            return performInSelectedWorktree { $0.createTab() }
        case .newFileBrowserTab:
            return performInSelectedWorktree { workspace in
                let root: String
                let kind: FileBrowserRootKind
                if !workspace.activeWorktreePath.isEmpty {
                    root = workspace.activeWorktreePath
                    kind = .worktree
                } else if let repositoryRoot = workspace.repositoryRoot?.path {
                    root = repositoryRoot
                    kind = .project
                } else {
                    return
                }
                let title = URL(fileURLWithPath: root).lastPathComponent
                workspace.createFileBrowserTab(rootPath: root, rootKind: kind, title: title)
            }
        case .closeTab:
            return performInSelectedWorktree { workspace in
                guard let tabID = workspace.activeTabID else { return }
                if workspace.handleCloseShortcut() { return }
                workspace.closeTab(tabID)
            }
        case .nextTab:
            return performInSelectedWorktree { $0.selectNextTab() }
        case .previousTab:
            return performInSelectedWorktree { $0.selectPreviousTab() }
        case .splitHorizontal:
            return performWithSessionController { controller in
                guard let focused = controller.focusedPaneID else { return }
                controller.splitPane(focused, axis: .vertical)
            }
        case .splitVertical:
            return performWithSessionController { controller in
                guard let focused = controller.focusedPaneID else { return }
                controller.splitPane(focused, axis: .horizontal)
            }
        case .closePane:
            return performWithSessionController { controller in
                guard let focused = controller.focusedPaneID else { return }
                controller.closePane(focused)
            }
        case .focusNextPane:
            return performWithSessionController { $0.focusNext() }
        case .focusPreviousPane:
            return performWithSessionController { $0.focusPrevious() }
        case .zoomPane:
            return performWithSessionController { $0.toggleZoom() }
        case .openSettings, .toggleSidebar, .openProject,
             .terminalFontSizeIncrease, .terminalFontSizeDecrease,
             .terminalFontSizeReset:
            return false
        }
    }

    private func performWithSessionController(
        _ action: (WorkspaceSessionController) -> Void
    ) -> Bool {
        performInSelectedWorktree { workspace in
            guard let controller = workspace.sessionController else { return }
            action(controller)
        }
    }

    private func performInSelectedWorktree(
        _ action: (WorkspaceModel) -> Void
    ) -> Bool {
        guard withSelectedWorktree(action) != nil else { return false }
        revision += 1
        return true
    }

    private func withSelectedWorktree<Result>(
        _ action: (WorkspaceModel) -> Result
    ) -> Result? {
        guard let workspace else { return nil }
        let originalPath = workspace.activeWorktreePath
        let targetPath = resolvedWorktreePath
        if let targetPath, targetPath != originalPath {
            workspace.switchToWorktree(targetPath)
        }
        defer {
            if workspace.activeWorktreePath != originalPath {
                workspace.switchToWorktree(originalPath)
            }
        }
        return action(workspace)
    }

    private var resolvedWorktreePath: String? {
        if followsStoreSelection {
            return store.selectedWorktree?.path.path
        }
        return worktreePath
    }
}

private struct WindowCommandContextEnvironmentKey: EnvironmentKey {
    static let defaultValue: WindowCommandContext? = nil
}

extension EnvironmentValues {
    var windowCommandContext: WindowCommandContext? {
        get { self[WindowCommandContextEnvironmentKey.self] }
        set { self[WindowCommandContextEnvironmentKey.self] = newValue }
    }
}

private struct WindowCommandHost: View {
    let content: AnyView
    @Bindable var commandContext: WindowCommandContext

    var body: some View {
        content
            .environment(\.windowCommandContext, commandContext)
            .overlay {
                if commandContext.showCommandPalette {
                    CommandPaletteView(
                        commandContext: commandContext,
                        isPresented: $commandContext.showCommandPalette
                    )
                }
            }
    }
}

/// Manages the main NSWindow and hosts the SwiftUI content view.
///
/// A `WindowContext` owns a single `NSWindow` plus its theme/locale observers.
/// `Kind` distinguishes the main workspace window from a torn-off detached
/// window so each can resolve its own root view and frame-autosave key.
@MainActor
final class WindowContext: NSObject, NSWindowDelegate {
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
    let commandContext: WindowCommandContext
    private var window: NSWindow?
    private var themeCancellable: AnyCancellable?
    private var localeCancellable: AnyCancellable?

    /// Weak back-reference to the owning `WindowManager`, set by the manager
    /// right after creating the context. Injected into the SwiftUI environment
    /// so views (e.g. the sidebar) can call `windowManager.detach(_:)`. Weak to
    /// break the retain cycle WindowManager → WindowContext → WindowManager.
    weak var windowManager: WindowManager?

    /// Interval token spanning ThemeManager construction (init) through
    /// makeKeyAndOrderFront (show); nil once the interval has been closed.
    private var windowConstructSignpost: OSSignpostIntervalState?

    init(store: WorkspaceStore, kind: Kind = .main) {
        self.store = store
        self.kind = kind
        self.commandContext = WindowCommandContext(store: store, kind: kind)
        let sp = PerfSignpost.begin("window-construct")
        self.themeManager = ThemeManager(activeThemeID: store.settings.activeThemeID)
        self.languageManager = LanguageManager(languageCode: store.settings.language)
        self.windowConstructSignpost = sp
        super.init()
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

    /// Window title shown in the title bar. Detached windows show the node's
    /// name (workspace name, or the remote-group display title) so the title
    /// bar identifies what was torn off.
    private var windowTitle: String {
        switch kind {
        case .main:
            return "Treemux"
        case .detached(let ref):
            return detachedTitle(for: ref)
        }
    }

    /// Derives the window title for a detached window from its ref.
    /// Falls back to "Treemux" if the referenced node is missing.
    private func detachedTitle(for ref: DetachedNodeRef) -> String {
        switch ref {
        case .workspace(let id):
            return store.workspaces.first(where: { $0.id == id })?.name ?? "Treemux"
        case .worktree(let wsID, let wtID):
            guard let ws = store.workspaces.first(where: { $0.id == wsID }),
                  let wt = ws.worktrees.first(where: { $0.id == wtID }) else {
                return store.workspaces.first(where: { $0.id == wsID })?.name ?? "Treemux"
            }
            // "<workspace> — <branch/path>" so a torn-off worktree is identifiable.
            let branch = wt.branch ?? wt.path.lastPathComponent
            return "\(ws.name) — \(branch)"
        case .remoteGroup(let key):
            // remoteGroupDisplayTitle takes an SSHTarget; derive it from the
            // group's first workspace. Fall back to the raw group key.
            if let ws = store.workspacesInRemoteGroup(key).first,
               let target = ws.sshTarget {
                return WorkspaceStore.remoteGroupDisplayTitle(for: target)
            }
            return key
        }
    }

    /// Creates and shows the window, dispatching the root view by `kind`.
    func show() {
        let host = NSHostingController(
            rootView: makeRootViewWithEnvironment(locale: languageManager.locale)
        )

        let window = NSWindow(contentViewController: host)
        window.delegate = self
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
        // Re-build via makeRootViewWithEnvironment() so detached windows update
        // their root too, and so the WindowManager environment stays injected.
        localeCancellable = languageManager.localePublisher
            .receive(on: RunLoop.main)
            .sink { [weak host, weak self] newLocale in
                guard let self, let host else { return }
                host.rootView = self.makeRootViewWithEnvironment(locale: newLocale)
            }
    }

    /// Closes the window WITHOUT triggering detached-node restore side-effects.
    /// Used during cascade shutdown (a later task) so closing a detached window
    /// during teardown doesn't round-trip through the restore path.
    func closeImmediately() {
        window?.close()
        window = nil
    }

    /// Returns `true` if this context currently owns `candidate` (identity
    /// comparison). Used by `WindowManager` to locate the `WindowContext` whose
    /// window just posted `willCloseNotification` so it can route the close
    /// through `closeChild(_:)` and run the detached-ref restore side-effect.
    func ownsWindow(_ candidate: NSWindow) -> Bool {
        guard let window else { return false }
        return window === candidate
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard case .main = kind else { return true }
        return windowManager?.shouldCloseMainWindow() ?? true
    }

    /// Test-only accessor for the underlying `NSWindow`. Production code goes
    /// through `ownsWindow(_:)`; tests need the window itself to drive
    /// `handleChildWindowClose(_:)` against a real identity.
    internal func testWindow() -> NSWindow? { window }

    /// Builds the SwiftUI root view for this window based on `kind`.
    private func makeRootView() -> AnyView {
        let content: AnyView = switch kind {
        case .main:
            AnyView(MainWindowView())
        case .detached(let ref):
            AnyView(DetachedRootView(ref: ref))
        }
        return AnyView(WindowCommandHost(content: content, commandContext: commandContext))
    }

    /// Builds the root view and applies the full environment chain (store,
    /// theme, language, locale, and the owning `WindowManager` when present).
    /// Factored out so both the initial host and the locale-change rebuild
    /// inject the same environment set, keeping the WindowManager reachable
    /// from any view (e.g. the sidebar's `onDetachNode` wiring). Erased to
    /// `AnyView` so the conditional `WindowManager` injection yields a single
    /// opaque return type.
    private func makeRootViewWithEnvironment(locale: Locale) -> AnyView {
        var view = AnyView(
            makeRootView()
                .environment(store)
                .environment(themeManager)
                .environment(languageManager)
                .environment(\.locale, locale)
        )
        if let windowManager {
            view = AnyView(view.environment(windowManager))
        }
        return view
    }

    /// Applies the active theme's appearance to the given window.
    private func applyThemeAppearance(to window: NSWindow) {
        window.appearance = themeManager.windowAppearance
        window.backgroundColor = themeManager.nsWindowBackgroundColor
    }

    /// Restores the themed titlebar layer after AppKit rebuilds it for full screen.
    func refreshFullScreenTitlebar() {
        guard let window else { return }
        applyThemeAppearance(to: window)
        var titlebarView = window.standardWindowButton(.closeButton)?.superview
        for _ in 0..<2 {
            guard let view = titlebarView else { break }
            view.wantsLayer = true
            view.layer?.backgroundColor = themeManager.nsWindowBackgroundColor.cgColor
            titlebarView = view.superview
        }
    }

    func windowWillEnterFullScreen(_ notification: Notification) {
        refreshFullScreenTitlebar()
    }

    func windowDidEnterFullScreen(_ notification: Notification) {
        refreshFullScreenTitlebar()
        DispatchQueue.main.async { [weak self] in
            self?.refreshFullScreenTitlebar()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            self?.refreshFullScreenTitlebar()
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        refreshFullScreenTitlebar()
    }

    /// Re-applies appearance to the current window (call when theme changes).
    func updateAppearance() {
        refreshFullScreenTitlebar()
    }
}
