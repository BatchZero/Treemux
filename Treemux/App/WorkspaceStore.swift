//
//  WorkspaceStore.swift
//  Treemux
//

import SwiftUI

/// Central state management for all workspaces.
/// UI views observe this store via @EnvironmentObject.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var workspaces: [WorkspaceModel] = []
    @Published var selectedWorkspaceID: UUID?

    @Published var settings: AppSettings {
        didSet { try? settingsPersistence.save(settings) }
    }

    private let settingsPersistence = AppSettingsPersistence()
    private let workspaceStatePersistence = WorkspaceStatePersistence()
    private let gitService = GitRepositoryService()
    private let metadataWatcher = WorkspaceMetadataWatchService()
    private let tmuxService = TmuxService()

    /// Virtual "Terminal" workspace shown when no real projects exist.
    /// This workspace is never persisted to disk.
    private var defaultTerminalWorkspace: WorkspaceModel?

    /// The currently selected workspace, if any.
    /// Falls back to the default terminal workspace when applicable.
    var selectedWorkspace: WorkspaceModel? {
        if let ws = workspaces.first(where: { $0.id == selectedWorkspaceID }) {
            return ws
        }
        if selectedWorkspaceID == defaultTerminalWorkspace?.id {
            return defaultTerminalWorkspace
        }
        return nil
    }

    /// Workspaces visible in the sidebar (non-archived).
    var sidebarWorkspaces: [WorkspaceModel] {
        let real = workspaces.filter { !$0.isArchived }
        if real.isEmpty, let terminal = defaultTerminalWorkspace {
            return [terminal]
        }
        return real
    }

    /// Local workspaces (repositories and local terminals, non-archived).
    var localWorkspaces: [WorkspaceModel] {
        let real = workspaces.filter { !$0.isArchived && ($0.kind == .repository || $0.kind == .localTerminal) }
        if real.isEmpty, let terminal = defaultTerminalWorkspace {
            return [terminal]
        }
        return real
    }

    /// Remote workspaces grouped by server+user combination.
    var remoteWorkspaceGroups: [(key: String, targets: [WorkspaceModel])] {
        let remotes = workspaces.filter { !$0.isArchived && $0.kind == .remote }
        let grouped = Dictionary(grouping: remotes) { ws -> String in
            guard let target = ws.sshTarget else { return "unknown" }
            let user = target.user ?? ""
            return "\(target.displayName)|\(user)"
        }
        return grouped.map { (key: $0.key, targets: $0.value) }
            .sorted { $0.key < $1.key }
    }

    init() {
        self.settings = settingsPersistence.load()
        loadWorkspaceState()
        ensureDefaultTerminal()
    }

    /// Creates or shows the default "Terminal" workspace when no real workspaces exist.
    /// Hides it automatically when real projects are present.
    private func ensureDefaultTerminal() {
        let hasRealWorkspaces = workspaces.contains { !$0.isArchived }
        if !hasRealWorkspaces {
            if defaultTerminalWorkspace == nil {
                defaultTerminalWorkspace = WorkspaceModel(
                    id: UUID(),
                    name: "~",
                    kind: .localTerminal,
                    repositoryRoot: URL(fileURLWithPath: NSHomeDirectory())
                )
            }
            // Auto-select the default terminal if nothing is selected
            if selectedWorkspaceID == nil {
                selectedWorkspaceID = defaultTerminalWorkspace?.id
            }
        }
    }

    // MARK: - Workspace Selection

    func selectWorkspace(_ id: UUID) {
        selectedWorkspaceID = id
        saveWorkspaceState()
    }

    // MARK: - Adding Workspaces

    /// Adds a workspace from a directory URL.
    func addWorkspaceFromPath(_ path: URL) {
        let name = path.lastPathComponent
        let workspace = WorkspaceModel(
            id: UUID(),
            name: name,
            kind: .repository,
            repositoryRoot: path
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        saveWorkspaceState()
        Task {
            await refreshWorkspace(workspace)
            startWatching(workspace)
        }
    }

    /// Presents an open panel and adds the selected directory as a workspace.
    func addWorkspaceFromOpenPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addWorkspaceFromPath(url)
    }

    /// Adds a remote workspace via SSH target.
    func addRemoteWorkspace(target: SSHTarget, name: String) {
        let workspace = WorkspaceModel(
            id: UUID(),
            name: name,
            kind: .remote,
            sshTarget: target
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        saveWorkspaceState()
    }

    // MARK: - Renaming Workspaces

    func renameWorkspace(_ id: UUID, to newName: String) {
        guard let workspace = workspaces.first(where: { $0.id == id }),
              !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        workspace.name = newName
        saveWorkspaceState()
    }

    // MARK: - Reordering Workspaces

    /// Moves local workspaces by translating sidebar indices to the workspaces array.
    func moveLocalWorkspace(from source: IndexSet, to destination: Int) {
        var local = localWorkspaces
        local.move(fromOffsets: source, toOffset: destination)
        let orderedIDs = local.map { $0.id }
        let nonLocal = workspaces.filter { ws in !orderedIDs.contains(ws.id) }
        workspaces = orderedIDs.compactMap { id in workspaces.first { $0.id == id } } + nonLocal
        saveWorkspaceState()
    }

    /// Reorders worktrees within a workspace and persists the new order.
    func moveWorktree(in workspace: WorkspaceModel, from source: IndexSet, to destination: Int) {
        workspace.worktrees.move(fromOffsets: source, toOffset: destination)
        workspace.worktreeOrder = workspace.worktrees.map { $0.path.path }
        saveWorkspaceState()
    }

    // MARK: - Removing Workspaces

    func removeWorkspace(_ id: UUID) {
        metadataWatcher.stopWatching(workspaceID: id)
        workspaces.removeAll { $0.id == id }
        if selectedWorkspaceID == id {
            selectedWorkspaceID = workspaces.first?.id
        }
        saveWorkspaceState()
        // Re-show the default terminal if all real workspaces have been removed
        ensureDefaultTerminal()
        if selectedWorkspaceID == nil {
            selectedWorkspaceID = defaultTerminalWorkspace?.id
        }
    }

    // MARK: - File System Watching

    /// Starts watching git metadata changes for a workspace and auto-refreshes on change.
    func startWatching(_ workspace: WorkspaceModel) {
        guard workspace.repositoryRoot != nil else { return }
        metadataWatcher.watch(workspace: workspace) { [weak self] workspaceID in
            Task { @MainActor [weak self] in
                guard let self,
                      let ws = self.workspaces.first(where: { $0.id == workspaceID }) else { return }
                await self.refreshWorkspace(ws)
            }
        }
    }

    /// Starts watching all current workspaces.
    private func startWatchingAll() {
        for workspace in workspaces {
            startWatching(workspace)
        }
    }

    // MARK: - Refreshing

    /// Refreshes git state for the given workspace.
    func refreshWorkspace(_ workspace: WorkspaceModel) async {
        guard let root = workspace.repositoryRoot else { return }
        do {
            let snapshot = try await gitService.inspectRepository(at: root)
            workspace.currentBranch = snapshot.currentBranch
            workspace.worktrees = snapshot.worktrees
            workspace.repositoryStatus = snapshot.status
            // Sort worktrees by persisted display order
            if !workspace.worktreeOrder.isEmpty {
                workspace.worktrees.sort { a, b in
                    let indexA = workspace.worktreeOrder.firstIndex(of: a.path.path) ?? Int.max
                    let indexB = workspace.worktreeOrder.firstIndex(of: b.path.path) ?? Int.max
                    return indexA < indexB
                }
            }
        } catch {
            // Not a git repository or git command failed — that's acceptable.
        }
    }

    // MARK: - Persistence

    private func loadWorkspaceState() {
        let state = workspaceStatePersistence.load()
        selectedWorkspaceID = state.selectedWorkspaceID
        workspaces = state.workspaces.map { WorkspaceModel(from: $0) }
        startWatchingAll()
    }

    func saveWorkspaceState() {
        // Exclude the default terminal workspace from persistence — it is virtual.
        let persistedSelectedID = selectedWorkspaceID == defaultTerminalWorkspace?.id ? nil : selectedWorkspaceID
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: persistedSelectedID,
            workspaces: workspaces.map { $0.toRecord() }
        )
        try? workspaceStatePersistence.save(state)
    }
}
