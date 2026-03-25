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

    /// The currently selected workspace, if any.
    var selectedWorkspace: WorkspaceModel? {
        workspaces.first { $0.id == selectedWorkspaceID }
    }

    /// Workspaces visible in the sidebar (non-archived).
    var sidebarWorkspaces: [WorkspaceModel] {
        workspaces.filter { !$0.isArchived }
    }

    /// Local workspaces (repositories and local terminals, non-archived).
    var localWorkspaces: [WorkspaceModel] {
        workspaces.filter { !$0.isArchived && ($0.kind == .repository || $0.kind == .localTerminal) }
    }

    init() {
        self.settings = settingsPersistence.load()
        loadWorkspaceState()
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
        Task { await refreshWorkspace(workspace) }
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

    // MARK: - Removing Workspaces

    func removeWorkspace(_ id: UUID) {
        workspaces.removeAll { $0.id == id }
        if selectedWorkspaceID == id {
            selectedWorkspaceID = workspaces.first?.id
        }
        saveWorkspaceState()
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
        } catch {
            // Not a git repository or git command failed — that's acceptable.
        }
    }

    // MARK: - Persistence

    private func loadWorkspaceState() {
        let state = workspaceStatePersistence.load()
        selectedWorkspaceID = state.selectedWorkspaceID
        workspaces = state.workspaces.map { WorkspaceModel(from: $0) }
    }

    func saveWorkspaceState() {
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: selectedWorkspaceID,
            workspaces: workspaces.map { $0.toRecord() }
        )
        try? workspaceStatePersistence.save(state)
    }
}
