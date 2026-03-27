//
//  WorkspaceModels.swift
//  Treemux
//

import Foundation

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
    let layout: SessionLayoutNode?
    let panes: [PaneSnapshot]
    let focusedPaneID: UUID?
    let zoomedPaneID: UUID?

    init(
        id: UUID = UUID(),
        title: String,
        isManuallyNamed: Bool = false,
        layout: SessionLayoutNode? = nil,
        panes: [PaneSnapshot] = [],
        focusedPaneID: UUID? = nil,
        zoomedPaneID: UUID? = nil
    ) {
        self.id = id
        self.title = title
        self.isManuallyNamed = isManuallyNamed
        self.layout = layout
        self.panes = panes
        self.focusedPaneID = focusedPaneID
        self.zoomedPaneID = zoomedPaneID
    }

    /// Creates a default single-pane tab for the given working directory.
    static func makeDefault(workingDirectory: String, title: String = "Tab 1") -> WorkspaceTabStateRecord {
        let paneID = UUID()
        let pane = PaneSnapshot(
            id: paneID,
            backend: .localShell(LocalShellConfig.defaultShell()),
            workingDirectory: workingDirectory
        )
        return WorkspaceTabStateRecord(
            title: title,
            layout: .pane(PaneLeaf(paneID: paneID)),
            panes: [pane],
            focusedPaneID: paneID
        )
    }

    // Support decoding old data without isManuallyNamed field
    enum CodingKeys: String, CodingKey {
        case id, title, isManuallyNamed, layout, panes, focusedPaneID, zoomedPaneID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        isManuallyNamed = try container.decodeIfPresent(Bool.self, forKey: .isManuallyNamed) ?? false
        layout = try container.decodeIfPresent(SessionLayoutNode.self, forKey: .layout)
        panes = try container.decodeIfPresent([PaneSnapshot].self, forKey: .panes) ?? []
        focusedPaneID = try container.decodeIfPresent(UUID.self, forKey: .focusedPaneID)
        zoomedPaneID = try container.decodeIfPresent(UUID.self, forKey: .zoomedPaneID)
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

// MARK: - Observable Runtime Model

/// A runtime workspace model observed by UI views via @EnvironmentObject.
/// Created from a `WorkspaceRecord` and serialized back via `toRecord()`.
@MainActor
final class WorkspaceModel: ObservableObject, Identifiable {
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

    // MARK: - Tab State

    @Published var tabs: [WorkspaceTabStateRecord] = []
    @Published var activeTabID: UUID?

    /// Tab controllers keyed by worktree path → tab ID.
    private var tabControllers: [String: [UUID: WorkspaceSessionController]] = [:]
    /// Saved tab state for inactive worktrees.
    private var worktreeTabStates: [String: (tabs: [WorkspaceTabStateRecord], activeTabID: UUID?)] = [:]
    /// The worktree path currently being displayed.
    private(set) var activeWorktreePath: String = ""

    // MARK: - Active Controller

    /// Returns the session controller for the currently active tab, or nil if no tab is active.
    var sessionController: WorkspaceSessionController? {
        guard let tabID = activeTabID else { return nil }
        return controller(forTabID: tabID, worktreePath: activeWorktreePath)
    }

    /// Returns a session controller for the given worktree path, switching if necessary.
    func sessionController(forWorktreePath path: String) -> WorkspaceSessionController? {
        if path != activeWorktreePath {
            switchToWorktree(path)
        }
        return sessionController
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
        worktreeIconOverrides: [String: SidebarItemIcon] = [:]
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

        let workingDirectory = repositoryRoot?.path ?? NSHomeDirectory()
        self.activeWorktreePath = workingDirectory

        let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: workingDirectory)
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
            worktreeIconOverrides: record.worktreeIconOverrides ?? [:]
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
            title: "Tab \(newIndex)"
        )
        tabs.append(newTab)
        activeTabID = newTab.id
    }

    /// Switches to the specified tab.
    func selectTab(_ tabID: UUID) {
        guard tabID != activeTabID,
              tabs.contains(where: { $0.id == tabID }) else { return }
        saveActiveTabState()
        activeTabID = tabID
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
    func saveActiveTabState() {
        guard let tabID = activeTabID,
              let index = tabs.firstIndex(where: { $0.id == tabID }),
              let ctrl = tabControllers[activeWorktreePath]?[tabID] else { return }

        let existingTab = tabs[index]
        let preferredTitle = suggestedTitle(for: ctrl, existingTab: existingTab)

        tabs[index] = WorkspaceTabStateRecord(
            id: tabID,
            title: preferredTitle,
            isManuallyNamed: existingTab.isManuallyNamed,
            layout: ctrl.layout,
            panes: ctrl.sessionSnapshots(),
            focusedPaneID: ctrl.focusedPaneID,
            zoomedPaneID: ctrl.zoomedPaneID
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
            let defaultTab = WorkspaceTabStateRecord.makeDefault(workingDirectory: activeWorktreePath)
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

    // MARK: - Controller Management

    /// Returns or creates a session controller for the given tab and worktree.
    private func controller(forTabID tabID: UUID, worktreePath: String) -> WorkspaceSessionController {
        if let existing = tabControllers[worktreePath]?[tabID] {
            return existing
        }

        // Look up the saved tab state to restore layout and panes
        let tabState = tabs.first(where: { $0.id == tabID })

        let ctrl = WorkspaceSessionController(
            workingDirectory: worktreePath,
            savedLayout: tabState?.layout,
            paneSnapshots: tabState?.panes ?? [],
            focusedPaneID: tabState?.focusedPaneID,
            zoomedPaneID: tabState?.zoomedPaneID
        )

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
            worktreeIconOverrides: worktreeIconOverrides.isEmpty ? nil : worktreeIconOverrides
        )
    }
}
