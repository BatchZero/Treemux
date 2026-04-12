//
//  WorkspaceStore.swift
//  Treemux
//

import SwiftUI

extension Notification.Name {
    static let treemuxTerminalSettingsDidChange = Notification.Name("treemuxTerminalSettingsDidChange")
}

/// Central state management for all workspaces.
/// UI views observe this store via @EnvironmentObject.
@MainActor
final class WorkspaceStore: ObservableObject {
    @Published var workspaces: [WorkspaceModel] = []
    @Published var selectedWorkspaceID: UUID? {
        didSet { handleWorktreeSelectionIfNeeded() }
    }

    @Published var collapsedSections: Set<String> = []

    @Published var showSettings = false
    @Published var showCommandPalette = false
    @Published var sidebarIconCustomizationRequest: SidebarIconCustomizationRequest?

    @Published var settings: AppSettings {
        didSet { try? settingsPersistence.save(settings) }
    }

    /// Applies a new settings snapshot (used by SettingsSheet Save).
    func updateSettings(_ newSettings: AppSettings) {
        let terminalChanged = settings.terminal != newSettings.terminal
        settings = newSettings
        if terminalChanged {
            NotificationCenter.default.post(name: .treemuxTerminalSettingsDidChange, object: newSettings.terminal)
        }
    }

    private let settingsPersistence = AppSettingsPersistence()
    private let workspaceStatePersistence = WorkspaceStatePersistence()
    private let gitService = GitRepositoryService()
    private let metadataWatcher = WorkspaceMetadataWatchService()
    private let tmuxService = TmuxService()

    /// How often to poll SSH-backed workspaces for git state changes.
    /// File system events cannot reach across SSH, so we fall back to a
    /// generous periodic poll plus an immediate refresh on window focus.
    private static let remoteRefreshInterval: TimeInterval = 30

    /// Timer that periodically polls SSH-backed workspaces. Created in `init`
    /// and lives for the entire app lifetime — `WorkspaceStore` is a long-lived
    /// singleton, so no `deinit` cleanup is required. If `WorkspaceStore` ever
    /// becomes non-singleton, add a deinit that invalidates this timer and
    /// removes `remoteWindowObserver`.
    private var remoteRefreshTimer: Timer?

    /// Notification observer that immediately refreshes SSH-backed workspaces
    /// when any Treemux window becomes key. See `remoteRefreshTimer` for
    /// lifetime notes.
    private var remoteWindowObserver: NSObjectProtocol?

    /// Reentry guard for `refreshAllRemoteWorkspaces`. Drops overlapping
    /// triggers (e.g. timer firing while a window-focus refresh is in flight).
    private var isRefreshingRemotes = false

    /// Virtual "Terminal" workspace shown when no real projects exist.
    /// This workspace is never persisted to disk.
    private var defaultTerminalWorkspace: WorkspaceModel?

    /// The currently selected workspace, if any.
    /// Resolves both workspace-level and worktree-level selection.
    /// Falls back to the default terminal workspace when applicable.
    var selectedWorkspace: WorkspaceModel? {
        if let ws = workspaces.first(where: { $0.id == selectedWorkspaceID }) {
            return ws
        }
        // Check if selection is a worktree ID within any workspace
        if let ws = workspaces.first(where: { ws in
            ws.worktrees.contains { $0.id == self.selectedWorkspaceID }
        }) {
            return ws
        }
        if selectedWorkspaceID == defaultTerminalWorkspace?.id {
            return defaultTerminalWorkspace
        }
        return nil
    }

    /// The currently selected worktree, if a worktree (rather than workspace) is selected.
    var selectedWorktree: WorktreeModel? {
        guard let id = selectedWorkspaceID else { return nil }
        for ws in workspaces {
            if let wt = ws.worktrees.first(where: { $0.id == id }) {
                return wt
            }
        }
        return nil
    }

    /// The session controller for the currently active workspace or worktree.
    /// All UI call sites (toolbar, detail view, command palette, menu bar)
    /// should use this single source of truth.
    var activeSessionController: WorkspaceSessionController? {
        guard let workspace = selectedWorkspace else { return nil }
        if let worktree = selectedWorktree {
            return workspace.sessionController(forWorktreePath: worktree.path.path)
        }
        return workspace.sessionController
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
        let real = workspaces.filter { !$0.isArchived && $0.sshTarget == nil }
        if real.isEmpty, let terminal = defaultTerminalWorkspace {
            return [terminal]
        }
        return real
    }

    /// Remote workspaces grouped by server+user combination.
    var remoteWorkspaceGroups: [(key: String, targets: [WorkspaceModel])] {
        let remotes = workspaces.filter { !$0.isArchived && $0.kind == .repository && $0.sshTarget != nil }
        let grouped = Dictionary(grouping: remotes) { ws -> String in
            guard let target = ws.sshTarget else { return "unknown" }
            return Self.remoteGroupKey(for: target)
        }
        return grouped.map { (key: $0.key, targets: $0.value) }
            .sorted { $0.key < $1.key }
    }

    init() {
        self.settings = settingsPersistence.load()
        loadWorkspaceState()
        ensureDefaultTerminal()
        startRemoteWorkspaceRefreshScheduler()
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

    /// When a worktree ID is selected in the sidebar, switch the parent workspace
    /// to that worktree so tabs and pane state update accordingly.
    private func handleWorktreeSelectionIfNeeded() {
        guard let selectedID = selectedWorkspaceID else { return }
        // Find a workspace that contains a worktree with the selected ID
        guard let workspace = workspaces.first(where: { ws in
            ws.worktrees.contains { $0.id == selectedID }
        }),
        let worktree = workspace.worktrees.first(where: { $0.id == selectedID }) else { return }
        // Switch the workspace to that worktree's path
        let path = worktree.path.path
        if workspace.activeWorktreePath != path {
            workspace.switchToWorktree(path)
        }
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
            kind: .repository,
            sshTarget: target
        )
        workspaces.append(workspace)
        selectedWorkspaceID = workspace.id
        saveWorkspaceState()
        Task {
            await refreshWorkspace(workspace)
        }
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

    /// Group key for a remote SSH target, e.g. "my-server|root".
    static func remoteGroupKey(for target: SSHTarget) -> String {
        let user = target.user ?? ""
        return "\(target.displayName)|\(user)"
    }

    /// Display title for a remote workspace group, e.g. "my-server (root@192.168.1.100)".
    static func remoteGroupDisplayTitle(for target: SSHTarget) -> String {
        if let user = target.user, !user.isEmpty {
            return "\(target.displayName) (\(user)@\(target.host))"
        }
        return "\(target.displayName) (\(target.host))"
    }

    /// Moves remote workspaces within a specific server group.
    func moveRemoteWorkspace(groupKey: String, from source: IndexSet, to destination: Int) {
        let remotes = workspaces.filter { !$0.isArchived && $0.sshTarget != nil }
        var group = remotes.filter { ws in
            guard let target = ws.sshTarget else { return false }
            return Self.remoteGroupKey(for: target) == groupKey
        }
        group.move(fromOffsets: source, toOffset: destination)
        let movedIDs = Set(group.map { $0.id })
        // Rebuild workspaces: keep everything not in this group in place, replace group items in order
        var result: [WorkspaceModel] = []
        var groupIterator = group.makeIterator()
        for ws in workspaces {
            if movedIDs.contains(ws.id) {
                if let next = groupIterator.next() {
                    result.append(next)
                }
            } else {
                result.append(ws)
            }
        }
        workspaces = result
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
        // Clear selection if it points to a worktree within this workspace
        if let ws = workspaces.first(where: { $0.id == id }),
           ws.worktrees.contains(where: { $0.id == selectedWorkspaceID }) {
            selectedWorkspaceID = nil
        }
        workspaces.removeAll { $0.id == id }
        if selectedWorkspaceID == id || selectedWorkspaceID == nil {
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
    /// Merges worktrees by path to preserve stable IDs across refreshes.
    /// Supports both local repositories (via local git) and remote repositories (via SSH).
    func refreshWorkspace(_ workspace: WorkspaceModel) async {
        let snapshot: RepositorySnapshot
        do {
            if let root = workspace.repositoryRoot {
                snapshot = try await gitService.inspectRepository(at: root)
            } else if let sshTarget = workspace.sshTarget, let remotePath = sshTarget.remotePath {
                snapshot = try await gitService.inspectRepository(remotePath: remotePath, sshTarget: sshTarget)
            } else {
                return
            }
            workspace.currentBranch = snapshot.currentBranch

            // Merge worktrees: preserve IDs for paths that still exist
            let previousWorktreeIDs = Set(workspace.worktrees.map { $0.id })
            var merged: [WorktreeModel] = []
            for newWT in snapshot.worktrees {
                if let existing = workspace.worktrees.first(where: { $0.path == newWT.path }) {
                    merged.append(WorktreeModel(
                        id: existing.id,
                        path: newWT.path,
                        branch: newWT.branch,
                        headCommit: newWT.headCommit,
                        isMainWorktree: newWT.isMainWorktree
                    ))
                } else {
                    merged.append(newWT)
                }
            }
            workspace.worktrees = merged

            workspace.repositoryStatus = snapshot.status
            // Sort worktrees by persisted display order
            if !workspace.worktreeOrder.isEmpty {
                workspace.worktrees.sort { a, b in
                    let indexA = workspace.worktreeOrder.firstIndex(of: a.path.path) ?? Int.max
                    let indexB = workspace.worktreeOrder.firstIndex(of: b.path.path) ?? Int.max
                    return indexA < indexB
                }
            }

            // If selected worktree was removed, fall back to workspace selection
            if let selID = selectedWorkspaceID,
               previousWorktreeIDs.contains(selID),
               !merged.contains(where: { $0.id == selID }) {
                selectedWorkspaceID = workspace.id
            }

            // Clean up stale tab state / sessions for removed worktrees and
            // reset activeWorktreePath if it pointed to a deleted worktree.
            let currentWorktreePaths = Set(merged.map { $0.path.path })
            let fallbackPath = merged.first(where: { $0.isMainWorktree })?.path.path
                ?? merged.first?.path.path
                ?? workspace.repositoryRoot?.path
                ?? workspace.sshTarget?.remotePath
                ?? ""
            workspace.cleanupRemovedWorktrees(
                currentPaths: currentWorktreePaths,
                fallbackPath: fallbackPath
            )

            // Re-establish watchers so newly added worktrees get their own
            // observers and removed worktrees have their stale handles cleaned up.
            // `watch(workspace:)` is idempotent (stops existing watchers first).
            metadataWatcher.watch(workspace: workspace) { [weak self] workspaceID in
                Task { @MainActor [weak self] in
                    guard let self,
                          let ws = self.workspaces.first(where: { $0.id == workspaceID }) else { return }
                    await self.refreshWorkspace(ws)
                }
            }

            // Notify SwiftUI that child model data changed so the sidebar rebuilds.
            objectWillChange.send()
        } catch {
            // Not a git repository or git command failed — that's acceptable.
        }
    }

    /// Sets up the periodic timer and window-focus observer that drive
    /// `refreshAllRemoteWorkspaces`. Called once from `init()`.
    private func startRemoteWorkspaceRefreshScheduler() {
        // Construct the timer manually and add it to `.common` runloop mode so
        // it keeps firing during event tracking (e.g. window dragging). The
        // standard `Timer.scheduledTimer` puts it in `.default` mode which
        // suspends during user interaction. Tolerance lets macOS coalesce
        // timer firings for power efficiency — 30s polls do not need precision.
        let timer = Timer(
            timeInterval: Self.remoteRefreshInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAllRemoteWorkspaces()
            }
        }
        timer.tolerance = 5
        RunLoop.main.add(timer, forMode: .common)
        remoteRefreshTimer = timer

        remoteWindowObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                await self?.refreshAllRemoteWorkspaces()
            }
        }
    }

    /// Refreshes every SSH-backed workspace serially. No-op for local workspaces.
    /// Reentry-guarded so overlapping triggers (timer + window focus, or
    /// back-to-back) don't stack SSH connections.
    private func refreshAllRemoteWorkspaces() async {
        guard !isRefreshingRemotes else { return }
        let remotes = workspaces.filter { $0.sshTarget != nil && !$0.isArchived }
        guard !remotes.isEmpty else { return }
        isRefreshingRemotes = true
        defer { isRefreshingRemotes = false }
        for workspace in remotes {
            await refreshWorkspace(workspace)
        }
    }

    // MARK: - Persistence

    private func loadWorkspaceState() {
        let state = workspaceStatePersistence.load()
        selectedWorkspaceID = state.selectedWorkspaceID
        collapsedSections = Set(state.collapsedSections ?? [])
        workspaces = state.workspaces.map { WorkspaceModel(from: $0) }
        startWatchingAll()

        // Populate worktrees and branch info from git on launch.
        // Skip SSH-backed workspaces — those are owned by the periodic remote
        // refresh scheduler (timer + window focus), which fires immediately on
        // app launch via `NSWindow.didBecomeKeyNotification`. This avoids a
        // redundant SSH round-trip on every launch.
        Task {
            for workspace in workspaces where workspace.sshTarget == nil {
                await refreshWorkspace(workspace)
            }
            // Restart watchers with full worktree paths now available
            startWatchingAll()
        }
    }

    func saveWorkspaceState() {
        // Resolve to workspace-level ID for persistence (worktree IDs are unstable across launches).
        let resolvedID: UUID? = {
            guard let id = selectedWorkspaceID else { return nil }
            if workspaces.contains(where: { $0.id == id }) { return id }
            if let ws = workspaces.first(where: { ws in ws.worktrees.contains { $0.id == id } }) {
                return ws.id
            }
            return nil
        }()
        // Exclude the default terminal workspace from persistence — it is virtual.
        let persistedSelectedID = resolvedID == defaultTerminalWorkspace?.id ? nil : resolvedID
        let state = PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: persistedSelectedID,
            workspaces: workspaces.map { $0.toRecord() },
            collapsedSections: collapsedSections.isEmpty ? nil : Array(collapsedSections)
        )
        try? workspaceStatePersistence.save(state)
    }

    // MARK: - Sidebar Icons

    /// Returns the resolved sidebar icon for a workspace, considering user overrides and app defaults.
    func sidebarIcon(for workspace: WorkspaceModel) -> SidebarItemIcon {
        if let override = workspace.workspaceIcon {
            return override
        }
        switch workspace.kind {
        case .localTerminal:
            return settings.defaultLocalTerminalIcon
        case .repository:
            let existingIcons = workspaces
                .filter { $0.id != workspace.id && !$0.isArchived && $0.kind == .repository }
                .compactMap { $0.workspaceIcon ?? generatedRepositoryIcon(for: $0) }
            // For remote workspaces, include remotePath in seed so different
            // folders on the same host get distinct icons.
            let iconSeed: String
            if let remotePath = workspace.sshTarget?.remotePath, !remotePath.isEmpty {
                iconSeed = (remotePath as NSString).lastPathComponent
            } else {
                iconSeed = workspace.repositoryRoot?.lastPathComponent ?? workspace.name
            }
            return .randomRepository(
                preferredSeed: iconSeed,
                avoiding: existingIcons
            )
        }
    }

    /// Generates a deterministic icon for a repository workspace (without override).
    private func generatedRepositoryIcon(for workspace: WorkspaceModel) -> SidebarItemIcon {
        let iconSeed: String
        if let remotePath = workspace.sshTarget?.remotePath, !remotePath.isEmpty {
            iconSeed = (remotePath as NSString).lastPathComponent
        } else {
            iconSeed = workspace.repositoryRoot?.lastPathComponent ?? workspace.name
        }
        return .randomRepository(
            preferredSeed: iconSeed,
            avoiding: []
        )
    }

    /// Returns the resolved sidebar icon for a worktree, considering user overrides, app defaults,
    /// and deterministic generation when using the default worktree icon.
    func sidebarIcon(for worktree: WorktreeModel, in workspace: WorkspaceModel) -> SidebarItemIcon {
        if let override = workspace.worktreeIconOverrides[worktree.path.path] {
            return override
        }
        let generatedIcons = SidebarItemIcon.generatedWorktreeIcons(
            seedSourcesByID: Dictionary(
                uniqueKeysWithValues: workspace.worktrees.map { candidate in
                    (candidate.path.path, worktreeIconSeed(for: candidate, in: workspace))
                }
            ),
            overrides: workspace.worktreeIconOverrides
        )
        return generatedIcons[worktree.path.path] ?? .randomRepository(
            preferredSeed: worktreeIconSeed(for: worktree, in: workspace),
            avoiding: []
        )
    }

    /// Generates a stable seed string for deterministic worktree icon generation.
    private func worktreeIconSeed(for worktree: WorktreeModel, in workspace: WorkspaceModel) -> String {
        let repositoryName = workspace.repositoryRoot.map { $0.lastPathComponent } ?? workspace.name
        let displayName = worktree.branch ?? worktree.path.lastPathComponent
        return "\(repositoryName)|\(displayName)|\(worktree.path.path)"
    }

    /// Updates the sidebar icon for the given target (workspace, worktree, or app default).
    func updateSidebarIcon(_ icon: SidebarItemIcon, for target: SidebarIconCustomizationTarget) {
        switch target {
        case .workspace(let workspaceID):
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
            workspace.workspaceIcon = icon
        case .worktree(let workspaceID, let worktreePath):
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
            workspace.worktreeIconOverrides[worktreePath] = icon
        case .appDefaultLocalTerminal:
            settings.defaultLocalTerminalIcon = icon
        }
        saveWorkspaceState()
    }

    /// Resets the sidebar icon for the given target back to its default value.
    func resetSidebarIcon(for target: SidebarIconCustomizationTarget) {
        switch target {
        case .workspace(let workspaceID):
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
            workspace.workspaceIcon = nil
        case .worktree(let workspaceID, let worktreePath):
            guard let workspace = workspaces.first(where: { $0.id == workspaceID }) else { return }
            workspace.worktreeIconOverrides[worktreePath] = nil
        case .appDefaultLocalTerminal:
            settings.defaultLocalTerminalIcon = .localTerminalDefault
        }
        saveWorkspaceState()
    }

    /// Returns a human-readable title for the icon customization request.
    func sidebarIconRequestTitle(_ request: SidebarIconCustomizationRequest) -> String {
        switch request.target {
        case .workspace(let id):
            return workspaces.first(where: { $0.id == id })?.name ?? "Workspace"
        case .worktree(let workspaceID, let worktreePath):
            guard let ws = workspaces.first(where: { $0.id == workspaceID }) else {
                return URL(fileURLWithPath: worktreePath).lastPathComponent
            }
            let wtName = ws.worktrees.first(where: { $0.path.path == worktreePath })?.branch
                ?? URL(fileURLWithPath: worktreePath).lastPathComponent
            return "\(ws.name) / \(wtName)"
        case .appDefaultLocalTerminal:
            return String(localized: "Default Terminal Icon")
        }
    }

    /// Returns the current icon selection for the given customization target.
    func sidebarIconSelection(for target: SidebarIconCustomizationTarget) -> SidebarItemIcon {
        switch target {
        case .workspace(let id):
            guard let ws = workspaces.first(where: { $0.id == id }) else {
                return .randomRepository()
            }
            return ws.workspaceIcon ?? sidebarIcon(for: ws)
        case .worktree(let workspaceID, let worktreePath):
            guard let ws = workspaces.first(where: { $0.id == workspaceID }),
                  let wt = ws.worktrees.first(where: { $0.path.path == worktreePath }) else {
                return .randomRepository()
            }
            if let override = ws.worktreeIconOverrides[worktreePath] {
                return override
            }
            return sidebarIcon(for: wt, in: ws)
        case .appDefaultLocalTerminal:
            return settings.defaultLocalTerminalIcon
        }
    }
}

// MARK: - Sidebar Icon Customization

enum SidebarIconCustomizationTarget {
    case workspace(UUID)
    case worktree(workspaceID: UUID, worktreePath: String)
    case appDefaultLocalTerminal
}

struct SidebarIconCustomizationRequest: Identifiable {
    let id = UUID()
    let target: SidebarIconCustomizationTarget
}
