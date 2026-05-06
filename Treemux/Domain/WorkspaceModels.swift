//
//  WorkspaceModels.swift
//  Treemux
//

import Foundation
import AppKit

// MARK: - Persistent Records (Codable)

/// The kind of workspace: local repository or bare terminal.
/// Remote repositories use `.repository` with a non-nil `sshTarget`.
enum WorkspaceKindRecord: String, Codable {
    case repository
    case localTerminal

    // Migration: decode legacy "remote" as "repository"
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        let rawValue = try container.decode(String.self)
        if rawValue == "remote" {
            self = .repository
        } else if let value = WorkspaceKindRecord(rawValue: rawValue) {
            self = value
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unknown kind: \(rawValue)")
        }
    }
}

/// A serializable record representing a single workspace.
struct WorkspaceRecord: Codable {
    let id: UUID
    let kind: WorkspaceKindRecord
    let name: String
    let repositoryPath: String?
    let isPinned: Bool
    let isArchived: Bool
    let sshTarget: SSHTarget?
    let worktreeStates: [WorktreeSessionStateRecord]
    /// Persisted display order of worktrees (paths). Nil means default git order.
    let worktreeOrder: [String]?
    /// User-customized sidebar icon for this workspace.
    let workspaceIcon: SidebarItemIcon?
    /// Per-worktree icon overrides, keyed by worktree path.
    let worktreeIconOverrides: [String: SidebarItemIcon]?
    /// True for the single built-in home-directory terminal entry. Defaults to false for
    /// every user-created workspace and decodes as false when absent in legacy JSON.
    let isBuiltInDefaultTerminal: Bool

    init(
        id: UUID,
        kind: WorkspaceKindRecord,
        name: String,
        repositoryPath: String?,
        isPinned: Bool,
        isArchived: Bool,
        sshTarget: SSHTarget?,
        worktreeStates: [WorktreeSessionStateRecord],
        worktreeOrder: [String]?,
        workspaceIcon: SidebarItemIcon?,
        worktreeIconOverrides: [String: SidebarItemIcon]?,
        isBuiltInDefaultTerminal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.repositoryPath = repositoryPath
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.sshTarget = sshTarget
        self.worktreeStates = worktreeStates
        self.worktreeOrder = worktreeOrder
        self.workspaceIcon = workspaceIcon
        self.worktreeIconOverrides = worktreeIconOverrides
        self.isBuiltInDefaultTerminal = isBuiltInDefaultTerminal
    }

    enum CodingKeys: String, CodingKey {
        case id, kind, name, repositoryPath, isPinned, isArchived, sshTarget,
             worktreeStates, worktreeOrder, workspaceIcon, worktreeIconOverrides,
             isBuiltInDefaultTerminal
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        kind = try c.decode(WorkspaceKindRecord.self, forKey: .kind)
        name = try c.decode(String.self, forKey: .name)
        repositoryPath = try c.decodeIfPresent(String.self, forKey: .repositoryPath)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        isArchived = try c.decodeIfPresent(Bool.self, forKey: .isArchived) ?? false
        sshTarget = try c.decodeIfPresent(SSHTarget.self, forKey: .sshTarget)
        worktreeStates = try c.decodeIfPresent([WorktreeSessionStateRecord].self, forKey: .worktreeStates) ?? []
        worktreeOrder = try c.decodeIfPresent([String].self, forKey: .worktreeOrder)
        workspaceIcon = try c.decodeIfPresent(SidebarItemIcon.self, forKey: .workspaceIcon)
        worktreeIconOverrides = try c.decodeIfPresent([String: SidebarItemIcon].self, forKey: .worktreeIconOverrides)
        isBuiltInDefaultTerminal = try c.decodeIfPresent(Bool.self, forKey: .isBuiltInDefaultTerminal) ?? false
    }
}

/// Persisted state for a single worktree session within a workspace.
struct WorktreeSessionStateRecord: Codable {
    let worktreePath: String
    let branch: String?
    let tabs: [WorkspaceTabStateRecord]
    let selectedTabID: UUID?
}

/// Persisted state for a single tab inside a worktree session.
struct WorkspaceTabStateRecord: Codable, Identifiable {
    let id: UUID
    var title: String
    var isManuallyNamed: Bool
    var kind: WorkspaceTabKind

    // Terminal-tab fields (nil when kind == .fileBrowser)
    let layout: SessionLayoutNode?
    let panes: [PaneSnapshot]
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?

    // File-browser-tab field (nil when kind == .terminal)
    var fileBrowserState: FileBrowserTabState?

    init(
        id: UUID = UUID(),
        title: String,
        isManuallyNamed: Bool = false,
        kind: WorkspaceTabKind = .terminal,
        layout: SessionLayoutNode? = nil,
        panes: [PaneSnapshot] = [],
        focusedPaneID: UUID? = nil,
        zoomedPaneID: UUID? = nil,
        fileBrowserState: FileBrowserTabState? = nil
    ) {
        self.id = id
        self.title = title
        self.isManuallyNamed = isManuallyNamed
        self.kind = kind
        self.layout = layout
        self.panes = panes
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
        self.fileBrowserState = fileBrowserState
    }

    /// Creates a default single-pane terminal tab for the given working directory.
    static func makeDefault(workingDirectory: String, sshTarget: SSHTarget? = nil, title: String = "Tab 1") -> WorkspaceTabStateRecord {
        let paneID = UUID()
        let pane = PaneSnapshot(
            id: paneID,
            backend: .defaultBackend(for: sshTarget),
            workingDirectory: workingDirectory
        )
        return WorkspaceTabStateRecord(
            title: title,
            kind: .terminal,
            layout: .pane(PaneLeaf(paneID: paneID)),
            panes: [pane],
            focusedPaneID: paneID
        )
    }

    /// Creates a default file browser tab rooted at `rootPath`.
    static func makeFileBrowser(rootPath: String, rootKind: FileBrowserRootKind, title: String) -> WorkspaceTabStateRecord {
        WorkspaceTabStateRecord(
            title: title,
            kind: .fileBrowser,
            fileBrowserState: FileBrowserTabState(rootPath: rootPath, rootKind: rootKind)
        )
    }

    enum CodingKeys: String, CodingKey {
        case id, title, isManuallyNamed, kind, layout, panes, focusedPaneID, zoomedPaneID, fileBrowserState
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        isManuallyNamed = try container.decodeIfPresent(Bool.self, forKey: .isManuallyNamed) ?? false
        // Legacy data: missing `kind` → terminal.
        kind = try container.decodeIfPresent(WorkspaceTabKind.self, forKey: .kind) ?? .terminal
        layout = try container.decodeIfPresent(SessionLayoutNode.self, forKey: .layout)
        panes = try container.decodeIfPresent([PaneSnapshot].self, forKey: .panes) ?? []
        focusedPaneID = try container.decodeIfPresent(UUID.self, forKey: .focusedPaneID)
        zoomedPaneID = try container.decodeIfPresent(UUID.self, forKey: .zoomedPaneID)
        fileBrowserState = try container.decodeIfPresent(FileBrowserTabState.self, forKey: .fileBrowserState)
    }
}

/// A snapshot of a single pane for serialization.
struct PaneSnapshot: Codable {
    let id: UUID
    let backend: SessionBackendConfiguration
    let workingDirectory: String?
    /// The tmux session name detected at save time, used to reattach on restore.
    let detectedTmuxSession: String?

    init(id: UUID, backend: SessionBackendConfiguration, workingDirectory: String?, detectedTmuxSession: String? = nil) {
        self.id = id
        self.backend = backend
        self.workingDirectory = workingDirectory
        self.detectedTmuxSession = detectedTmuxSession
    }
}

/// Top-level persisted state containing all workspaces.
struct PersistedWorkspaceState: Codable {
    let version: Int
    let selectedWorkspaceID: UUID?
    let workspaces: [WorkspaceRecord]
    var collapsedSections: [String]?
}

// MARK: - Runtime Models

/// A worktree within a git repository.
struct WorktreeModel: Identifiable {
    let id: UUID
    let path: URL
    let branch: String?
    let headCommit: String?
    let isMainWorktree: Bool
}

/// A snapshot of repository state at a point in time.
struct RepositorySnapshot {
    let currentBranch: String?
    let headCommit: String?
    let worktrees: [WorktreeModel]
    let status: RepositoryStatusSnapshot?
}

/// Summary of repository working-tree status.
struct RepositoryStatusSnapshot {
    let changedFileCount: Int
    let aheadCount: Int
    let behindCount: Int
    let untrackedCount: Int
}

// MARK: - Batch close request

/// In-flight request to close a file-browser outer tab whose controller has
/// 2+ dirty sub-tabs. Carried via `WorkspaceModel.pendingBatchClose` and
/// presented by `WorkspaceTabContainerView` as a SwiftUI sheet.
///
/// The struct holds a strong reference to the controller — that's safe here
/// because the request is short-lived (cleared on Save All / Don't Save /
/// Cancel) and `WorkspaceModel` doesn't retain `pendingBatchClose` after
/// resolution, so no retain cycle forms.
struct BatchCloseRequest: Identifiable {
    let id = UUID()
    let tabID: UUID
    let dirty: [SubTabRuntime]
    let relativePaths: [String]
    let controller: FileBrowserTabController
}

// MARK: - Observable Runtime Model

/// A runtime workspace model observed by UI views via @EnvironmentObject.
/// Created from a `WorkspaceRecord` and serialized back via `toRecord()`.
@MainActor
final class WorkspaceModel: ObservableObject, Identifiable {
    /// Stable UUID for the single built-in `~` (home directory) terminal entry.
    /// Persisted alongside user-created workspaces so its sidebar order survives launches.
    static let builtInDefaultTerminalID = UUID(uuidString: "00000000-0000-0000-0000-00000000007E")!

    let id: UUID
    let kind: WorkspaceKindRecord

    @Published var name: String
    @Published var repositoryRoot: URL?
    @Published var isPinned: Bool
    @Published var isArchived: Bool
    @Published var sshTarget: SSHTarget?
    @Published var currentBranch: String?
    @Published var worktrees: [WorktreeModel] = []
    @Published var repositoryStatus: RepositoryStatusSnapshot?
    /// Custom display order of worktrees (paths). Empty means default git order.
    @Published var worktreeOrder: [String] = []
    /// User-customized sidebar icon for this workspace.
    @Published var workspaceIcon: SidebarItemIcon?
    /// Per-worktree icon overrides, keyed by worktree path.
    @Published var worktreeIconOverrides: [String: SidebarItemIcon] = [:]
    /// True for the single built-in home-directory terminal entry. Read-only at runtime — set during init.
    let isBuiltInDefaultTerminal: Bool

    // MARK: - Tab State

    @Published var tabs: [WorkspaceTabStateRecord] = []
    @Published var activeTabID: UUID?

    /// In-flight request for the batch unsaved-changes sheet (set when
    /// closing an outer file-browser tab with 2+ dirty sub-tabs). The
    /// containing view binds a `.sheet(item:)` to this property; setting it
    /// to nil dismisses the sheet (used as the Cancel path).
    @Published var pendingBatchClose: BatchCloseRequest?

    /// Tab controllers keyed by worktree path → tab ID.
    private var tabControllers: [String: [UUID: WorkspaceSessionController]] = [:]
    /// File browser controllers keyed by worktree path → tab ID.
    private var fileBrowserControllers: [String: [UUID: FileBrowserTabController]] = [:]
    /// Saved tab state for inactive worktrees.
    private var worktreeTabStates: [String: (tabs: [WorkspaceTabStateRecord], activeTabID: UUID?)] = [:]
    /// The worktree path currently being displayed.
    private(set) var activeWorktreePath: String = ""

    /// Shared SFTP service for this workspace; lazily created the first time
    /// a remote file-browser tab needs it. Sharing one service across tabs
    /// means a successful password prompt on the first tab unlocks the rest.
    private var sharedSFTPService_: SFTPService?

    func ensureSharedSFTPService() -> SFTPService {
        if let s = sharedSFTPService_ { return s }
        let s = SFTPService()
        sharedSFTPService_ = s
        return s
    }

    // MARK: - Active Controller

    /// Returns the session controller for the currently active tab, or nil if no tab
    /// is active or the active tab is not a terminal tab. File-browser tabs have no
    /// session controller; callers must tolerate
    /// nil here so we don't lazy-create a phantom terminal controller for an FB tab.
    var sessionController: WorkspaceSessionController? {
        guard let tabID = activeTabID,
              let tab = tabs.first(where: { $0.id == tabID }),
              tab.kind == .terminal else { return nil }
        return controller(forTabID: tabID, worktreePath: activeWorktreePath)
    }

    /// Returns a session controller for the given worktree path, switching if necessary.
    func sessionController(forWorktreePath path: String) -> WorkspaceSessionController? {
        if path != activeWorktreePath {
            switchToWorktree(path)
        }
        return sessionController
    }

    /// Returns true if the given worktree path has any active tab controllers (running sessions).
    func hasRunningSessions(forWorktreePath path: String) -> Bool {
        guard let controllers = tabControllers[path] else { return false }
        return !controllers.isEmpty
    }

    /// Returns true if any worktree path in this workspace has running sessions.
    var hasAnyRunningSessions: Bool {
        tabControllers.values.contains { !$0.isEmpty }
    }

    // MARK: - Initialization

    init(
        id: UUID = UUID(),
        name: String,
        kind: WorkspaceKindRecord,
        repositoryRoot: URL? = nil,
        isPinned: Bool = false,
        isArchived: Bool = false,
        sshTarget: SSHTarget? = nil,
        worktreeOrder: [String] = [],
        workspaceIcon: SidebarItemIcon? = nil,
        worktreeIconOverrides: [String: SidebarItemIcon] = [:],
        isBuiltInDefaultTerminal: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.name = name
        self.repositoryRoot = repositoryRoot
        self.isPinned = isPinned
        self.isArchived = isArchived
        self.sshTarget = sshTarget
        self.worktreeOrder = worktreeOrder
        self.workspaceIcon = workspaceIcon
        self.worktreeIconOverrides = worktreeIconOverrides
        self.isBuiltInDefaultTerminal = isBuiltInDefaultTerminal

        let workingDirectory = repositoryRoot?.path ?? sshTarget?.remotePath ?? NSHomeDirectory()
        self.activeWorktreePath = workingDirectory

        let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: workingDirectory, sshTarget: sshTarget)
        self.tabs = [defaultTab]
        self.activeTabID = defaultTab.id
    }

    /// Creates a runtime model from a persisted record.
    convenience init(from record: WorkspaceRecord) {
        self.init(
            id: record.id,
            name: record.name,
            kind: record.kind,
            repositoryRoot: record.repositoryPath.map { URL(fileURLWithPath: $0) },
            isPinned: record.isPinned,
            isArchived: record.isArchived,
            sshTarget: record.sshTarget,
            worktreeOrder: record.worktreeOrder ?? [],
            workspaceIcon: record.workspaceIcon,
            worktreeIconOverrides: record.worktreeIconOverrides ?? [:],
            isBuiltInDefaultTerminal: record.isBuiltInDefaultTerminal
        )
        restoreTabState(from: record.worktreeStates)
    }

    // MARK: - Tab Operations

    /// Creates a new tab and makes it active.
    func createTab() {
        saveActiveTabState()
        let newIndex = tabs.count + 1
        let newTab = WorkspaceTabStateRecord.makeDefault(
            workingDirectory: activeWorktreePath,
            sshTarget: sshTarget,
            title: "Tab \(newIndex)"
        )
        tabs.append(newTab)
        activeTabID = newTab.id
    }

    /// Creates a new file-browser tab and makes it active.
    func createFileBrowserTab(rootPath: String, rootKind: FileBrowserRootKind, title: String) {
        saveActiveTabState()
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = trimmed.isEmpty ? URL(fileURLWithPath: rootPath).lastPathComponent : trimmed
        let newTab = WorkspaceTabStateRecord.makeFileBrowser(rootPath: rootPath, rootKind: rootKind, title: label)
        tabs.append(newTab)
        activeTabID = newTab.id
    }

    /// Returns or creates a file browser controller for the given tab.
    func fileBrowserController(forTabID tabID: UUID) -> FileBrowserTabController? {
        guard let tab = tabs.first(where: { $0.id == tabID }),
              tab.kind == .fileBrowser,
              let state = tab.fileBrowserState else { return nil }
        let path = activeWorktreePath
        if let existing = fileBrowserControllers[path]?[tabID] { return existing }

        let dataSource: any FileBrowserDataSource = makeDataSource()
        // Inject a GitDiffService matching the workspace's transport (Local
        // for on-disk worktrees, Remote SSH-backed for repository tabs with
        // an `sshTarget`). The injected `repoRoot` is the file-browser tab's
        // root path, which equals the project / worktree root in our model.
        let gitService: GitDiffService = {
            if sshTarget != nil {
                return RemoteGitDiffService(service: ensureSharedSFTPService())
            }
            return LocalGitDiffService()
        }()
        let ctrl = FileBrowserTabController(
            initial: state,
            dataSource: dataSource,
            gitDiffService: gitService,
            repoRoot: state.rootPath
        )
        ctrl.onPersistableStateChanged = { [weak self] in
            self?.persistFileBrowserState(tabID: tabID)
        }
        if fileBrowserControllers[path] == nil { fileBrowserControllers[path] = [:] }
        fileBrowserControllers[path]?[tabID] = ctrl
        return ctrl
    }

    private func makeDataSource() -> any FileBrowserDataSource {
        if let target = sshTarget {
            return RemoteFileBrowserDataSource(sshTarget: target, service: ensureSharedSFTPService())
        }
        return LocalFileBrowserDataSource()
    }

    private func persistFileBrowserState(tabID: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }),
              let ctrl = fileBrowserControllers[activeWorktreePath]?[tabID] else { return }
        var record = tabs[index]
        record.fileBrowserState = ctrl.snapshot()
        tabs[index] = record
    }

    /// Switches to the specified tab.
    func selectTab(_ tabID: UUID) {
        guard tabID != activeTabID,
              tabs.contains(where: { $0.id == tabID }) else { return }
        saveActiveTabState()
        activeTabID = tabID
    }

    /// Cmd+W cascade: if the active outer tab is a file-browser with at least
    /// one open sub-tab, close the active sub-tab and consume the shortcut.
    /// Returns `false` (no-op) when the active tab is not a file-browser, when
    /// the controller has not been instantiated yet, or when there are no
    /// sub-tabs — in which case the caller should fall through to the existing
    /// outer-tab close path.
    func handleCloseShortcut() -> Bool {
        guard let tabID = activeTabID,
              let tab = tabs.first(where: { $0.id == tabID }),
              tab.kind == .fileBrowser,
              let ctrl = fileBrowserControllers[activeWorktreePath]?[tabID] else {
            return false
        }
        return ctrl.handleCloseShortcut()
    }

    /// Closes the tab. If it's a file-browser tab with dirty sub-tabs, the user
    /// is prompted first:
    /// - 1 dirty sub-tab → NSAlert (Save / Don't Save / Cancel) including the
    ///   file's basename in the title.
    /// - 2+ dirty sub-tabs → SwiftUI sheet (`BatchUnsavedChangesSheet`)
    ///   listing relative paths with Save All / Don't Save / Cancel.
    /// Tabs whose dirty list is empty close immediately.
    func requestCloseTab(_ tabID: UUID) {
        guard let tab = tabs.first(where: { $0.id == tabID }) else { return }
        if tab.kind == .fileBrowser,
           let ctrl = fileBrowserControllers[activeWorktreePath]?[tabID] {
            let dirty = ctrl.dirtySubTabs
            switch dirty.count {
            case 0:
                break  // fall through to closeTab
            case 1:
                confirmCloseSingleDirtySubTabAndOuter(tabID: tabID, controller: ctrl, subTab: dirty[0])
                return
            default:
                requestBatchCloseSheet(tabID: tabID, controller: ctrl, dirty: dirty)
                return
            }
        }
        closeTab(tabID)
    }

    private func confirmCloseSingleDirtySubTabAndOuter(tabID: UUID,
                                                      controller: FileBrowserTabController,
                                                      subTab: SubTabRuntime) {
        let alert = NSAlert()
        let name = URL(fileURLWithPath: subTab.path).lastPathComponent
        alert.messageText = String.localizedStringWithFormat(
            String(localized: "%@ has unsaved changes."), name)
        alert.informativeText = String(localized: "Save changes before closing?")
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Don't Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let response = alert.runModal()
        switch response {
        case .alertFirstButtonReturn: // Save
            Task { @MainActor in
                do {
                    controller.activateSubTab(subTab.id)
                    try await controller.saveCurrentFile()
                    self.closeTab(tabID)
                } catch {
                    let err = NSAlert()
                    err.messageText = String(localized: "Save failed")
                    err.informativeText = error.localizedDescription
                    err.runModal()
                }
            }
        case .alertSecondButtonReturn: // Don't Save
            closeTab(tabID)
        default: // Cancel
            break
        }
    }

    private func requestBatchCloseSheet(tabID: UUID,
                                        controller: FileBrowserTabController,
                                        dirty: [SubTabRuntime]) {
        let rels = dirty.map { controller.relativePath($0.path) }
        pendingBatchClose = BatchCloseRequest(
            tabID: tabID,
            dirty: dirty,
            relativePaths: rels,
            controller: controller
        )
    }

    /// Resolves the in-flight `pendingBatchClose`. Called from
    /// `BatchUnsavedChangesSheet`'s callbacks.
    /// - Parameters:
    ///   - saveAll: when `true`, iterates the dirty sub-tabs activating each
    ///     and running `saveCurrentFile()` sequentially. The first failure
    ///     surfaces a Save-failed alert and aborts before the outer tab closes.
    ///   - discard: when `true`, closes the outer tab immediately without
    ///     saving. Mutually exclusive with `saveAll`.
    /// Cancel is handled by setting `pendingBatchClose = nil` directly via the
    /// sheet binding.
    func resolveBatchClose(saveAll: Bool, discard: Bool) {
        guard let req = pendingBatchClose else { return }
        pendingBatchClose = nil
        if discard {
            closeTab(req.tabID)
            return
        }
        guard saveAll else { return }
        let ctrl = req.controller
        Task { @MainActor in
            for sub in req.dirty {
                ctrl.activateSubTab(sub.id)
                do {
                    try await ctrl.saveCurrentFile()
                } catch {
                    let err = NSAlert()
                    err.messageText = String(localized: "Save failed")
                    err.informativeText = error.localizedDescription
                    err.runModal()
                    return  // abort batch close on first failure
                }
            }
            self.closeTab(req.tabID)
        }
    }

    /// Closes a tab and cleans up its controller. If it was active, selects an adjacent tab.
    func closeTab(_ tabID: UUID) {
        saveActiveTabState()
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }

        let path = activeWorktreePath
        if let ctrl = tabControllers[path]?[tabID] {
            ctrl.terminateAll()
            tabControllers[path]?.removeValue(forKey: tabID)
        }
        // File browser controllers don't have terminal sessions to terminate;
        // just drop the reference so the next open re-creates fresh state.
        fileBrowserControllers[path]?.removeValue(forKey: tabID)

        tabs.remove(at: index)

        if tabs.isEmpty {
            activeTabID = nil
        } else if activeTabID == tabID {
            let newIndex = min(index, tabs.count - 1)
            activeTabID = tabs[newIndex].id
        }
    }

    /// Renames a tab and marks it as manually named.
    func renameTab(_ tabID: UUID, title: String) {
        guard let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        tabs[index].title = trimmed
        tabs[index].isManuallyNamed = true
    }

    /// Reorders tabs via drag-and-drop style offsets.
    func moveTab(fromOffsets source: IndexSet, toOffset destination: Int) {
        tabs.move(fromOffsets: source, toOffset: destination)
    }

    /// Cycles to the next tab, wrapping around.
    func selectNextTab() {
        guard tabs.count > 1,
              let currentID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == currentID }) else { return }
        saveActiveTabState()
        let nextIndex = (index + 1) % tabs.count
        activeTabID = tabs[nextIndex].id
    }

    /// Cycles to the previous tab, wrapping around.
    func selectPreviousTab() {
        guard tabs.count > 1,
              let currentID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == currentID }) else { return }
        saveActiveTabState()
        let prevIndex = (index - 1 + tabs.count) % tabs.count
        activeTabID = tabs[prevIndex].id
    }

    /// Selects a tab by 1-based number (e.g. Cmd+1 selects tab 1).
    func selectTabByNumber(_ number: Int) {
        let index = number - 1
        guard index >= 0, index < tabs.count else { return }
        selectTab(tabs[index].id)
    }

    // MARK: - Title Auto-Generation

    /// Returns a suggested title for a tab based on the focused pane's shell session.
    func suggestedTitle(for ctrl: WorkspaceSessionController, existingTab: WorkspaceTabStateRecord?) -> String {
        if existingTab?.isManuallyNamed == true {
            return existingTab?.title ?? "Tab"
        }
        if let focusedPaneID = ctrl.focusedPaneID,
           let session = ctrl.session(for: focusedPaneID) {
            let title = session.title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty { return title }
            let dir = session.effectiveWorkingDirectory
            let basename = URL(fileURLWithPath: dir).lastPathComponent
            if !basename.isEmpty { return basename }
        }
        return existingTab?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Tab"
    }

    // MARK: - State Save/Load

    /// Saves the current active tab's layout and pane state from its controller.
    /// Only applies to terminal tabs — file-browser tabs persist their state via
    /// `persistFileBrowserState` and must not be rewritten here.
    func saveActiveTabState() {
        guard let tabID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == tabID }) else { return }
        let existingTab = tabs[index]
        guard existingTab.kind == .terminal,
              let ctrl = tabControllers[activeWorktreePath]?[tabID] else { return }

        let preferredTitle = suggestedTitle(for: ctrl, existingTab: existingTab)

        tabs[index] = WorkspaceTabStateRecord(
            id: tabID,
            title: preferredTitle,
            isManuallyNamed: existingTab.isManuallyNamed,
            kind: .terminal,
            layout: ctrl.layout,
            panes: ctrl.sessionSnapshots(),
            focusedPaneID: ctrl.focusedPaneID,
            zoomedPaneID: ctrl.zoomedPaneID,
            fileBrowserState: nil
        )
    }

    /// Restores tab state from persisted worktree states.
    private func restoreTabState(from worktreeStates: [WorktreeSessionStateRecord]) {
        for state in worktreeStates {
            if state.worktreePath == activeWorktreePath {
                // Load active worktree state into visible tabs
                if !state.tabs.isEmpty {
                    tabs = state.tabs
                    activeTabID = state.selectedTabID ?? state.tabs.first?.id
                }
            } else {
                // Store inactive worktree state for later retrieval
                if !state.tabs.isEmpty {
                    worktreeTabStates[state.worktreePath] = (
                        tabs: state.tabs,
                        activeTabID: state.selectedTabID
                    )
                }
            }
        }
    }

    // MARK: - Worktree Switching

    /// Saves the current worktree's tab state into the worktreeTabStates dictionary.
    private func saveActiveWorktreeState() {
        saveActiveTabState()
        worktreeTabStates[activeWorktreePath] = (tabs: tabs, activeTabID: activeTabID)
    }

    /// Loads the target worktree's tab state from worktreeTabStates, or creates a default.
    private func loadActiveWorktreeState() {
        if let saved = worktreeTabStates[activeWorktreePath] {
            tabs = saved.tabs
            activeTabID = saved.activeTabID
        } else {
            let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: activeWorktreePath, sshTarget: sshTarget)
            tabs = [defaultTab]
            activeTabID = defaultTab.id
        }
    }

    /// Switches to a different worktree, saving current tab state and restoring the target's.
    func switchToWorktree(_ path: String) {
        guard path != activeWorktreePath else { return }
        saveActiveWorktreeState()
        activeWorktreePath = path
        loadActiveWorktreeState()
    }

    /// Cleans up state for worktrees that no longer exist.
    /// If `activeWorktreePath` pointed to a removed worktree, switches to `fallbackPath`.
    func cleanupRemovedWorktrees(currentPaths: Set<String>, fallbackPath: String) {
        let isActiveRemoved = !currentPaths.contains(activeWorktreePath)

        // Terminate sessions and remove cached state for deleted worktrees
        for path in Array(tabControllers.keys) where !currentPaths.contains(path) {
            if let controllers = tabControllers.removeValue(forKey: path) {
                for (_, ctrl) in controllers {
                    ctrl.terminateAll()
                }
            }
        }
        for path in Array(worktreeTabStates.keys) where !currentPaths.contains(path) {
            worktreeTabStates.removeValue(forKey: path)
        }

        // Switch to fallback if the active worktree was removed
        if isActiveRemoved {
            activeWorktreePath = fallbackPath
            loadActiveWorktreeState()
        }
    }

    // MARK: - Controller Management

    /// Returns or creates a session controller for the given tab and worktree.
    private func controller(forTabID tabID: UUID, worktreePath: String) -> WorkspaceSessionController {
        if let existing = tabControllers[worktreePath]?[tabID] {
            return existing
        }

        // Defensive: this factory should only be reached for terminal tabs.
        // sessionController already gates on tab.kind == .terminal; this assertion
        // catches future regressions where a caller bypasses that guard.
        if let tab = tabs.first(where: { $0.id == tabID }), tab.kind != .terminal {
            assertionFailure("controller(forTabID:) called for non-terminal tab \(tabID)")
        }

        // Look up the saved tab state to restore layout and panes
        let tabState = tabs.first(where: { $0.id == tabID })

        let ctrl = WorkspaceSessionController(
            workingDirectory: worktreePath,
            sshTarget: sshTarget,
            savedLayout: tabState?.layout,
            paneSnapshots: tabState?.panes ?? [],
            focusedPaneID: tabState?.focusedPaneID,
            zoomedPaneID: tabState?.zoomedPaneID
        )

        ctrl.onPaneStateChanged = { [weak self] in
            self?.saveActiveTabState()
        }

        if tabControllers[worktreePath] == nil {
            tabControllers[worktreePath] = [:]
        }
        tabControllers[worktreePath]?[tabID] = ctrl
        return ctrl
    }

    // MARK: - Termination

    /// Terminates all sessions managed by this workspace across all tabs and worktrees.
    func terminateAllSessions() {
        for (_, controllers) in tabControllers {
            for (_, ctrl) in controllers {
                ctrl.terminateAll()
            }
        }
        tabControllers.removeAll()
    }

    // MARK: - Persistence

    /// Serializes the runtime model back to a persistable record, including all tab state.
    func toRecord() -> WorkspaceRecord {
        saveActiveTabState()

        var allWorktreeStates: [WorktreeSessionStateRecord] = []

        // Active worktree state
        allWorktreeStates.append(WorktreeSessionStateRecord(
            worktreePath: activeWorktreePath,
            branch: currentBranch,
            tabs: tabs,
            selectedTabID: activeTabID
        ))

        // Inactive worktree states
        for (path, state) in worktreeTabStates where path != activeWorktreePath {
            allWorktreeStates.append(WorktreeSessionStateRecord(
                worktreePath: path,
                branch: nil,
                tabs: state.tabs,
                selectedTabID: state.activeTabID
            ))
        }

        return WorkspaceRecord(
            id: id,
            kind: kind,
            name: name,
            repositoryPath: repositoryRoot?.path,
            isPinned: isPinned,
            isArchived: isArchived,
            sshTarget: sshTarget,
            worktreeStates: allWorktreeStates,
            worktreeOrder: worktreeOrder.isEmpty ? nil : worktreeOrder,
            workspaceIcon: workspaceIcon,
            worktreeIconOverrides: worktreeIconOverrides.isEmpty ? nil : worktreeIconOverrides,
            isBuiltInDefaultTerminal: isBuiltInDefaultTerminal
        )
    }
}
