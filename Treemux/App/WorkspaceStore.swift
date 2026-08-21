//
//  WorkspaceStore.swift
//  Treemux
//

import Combine
import Observation
import SwiftUI

extension Notification.Name {
    static let treemuxTerminalSettingsDidChange = Notification.Name("treemuxTerminalSettingsDidChange")
}

/// Central state management for all workspaces.
/// UI views observe this store via @Environment(WorkspaceStore.self).
@MainActor
@Observable
final class WorkspaceStore {
    /// NOTE: `sidebarIconCache`/`remoteGroupsCache` correctness depends on every
    /// structural mutation converging on `saveWorkspaceState()` (see its cache-clear
    /// there). `WorkspaceModel` is a class, so mutating one of its properties does
    /// NOT trigger this array's observation — callers must not mutate the
    /// icon-seed/grouping-key input fields (`repositoryRoot`, `sshTarget`, `name`,
    /// `workspaceIcon`, `isArchived`, `kind`) on a path that bypasses
    /// `saveWorkspaceState()`, or the caches will silently go stale.
    var workspaces: [WorkspaceModel] = []

    /// Paths of all file sub-tabs with unsaved edits across every workspace.
    /// Used by the quit guard to decide whether to warn before terminating.
    var unsavedFilePaths: [String] {
        workspaces.flatMap { $0.unsavedFilePaths }
    }

    var selectedWorkspaceID: UUID? {
        didSet {
            handleWorktreeSelectionIfNeeded()
            workspaceSelectionDidChange?()
        }
    }

    var collapsedSections: Set<String> = []
    var remoteGroupOrder: [String]?

    /// Sidebar nodes currently torn off into their own windows. Persisted
    /// across launches so child windows can be rebuilt. Drives the main
    /// sidebar's filter (detached nodes are hidden from the main window).
    var detachedNodes: Set<DetachedNodeRef> = []

    /// WindowManager installs this hook before persistence snapshots. It
    /// compares workspace membership and revalidates detached ownership only
    /// when that structure changed.
    @ObservationIgnored var workspaceStructureDidChange: (@MainActor () -> Void)?

    /// WindowManager uses this hook to keep the main-window selection outside
    /// every currently detached ownership scope.
    @ObservationIgnored var workspaceSelectionDidChange: (@MainActor () -> Void)?

    var showSettings = false
    var showCommandPalette = false
    var sidebarIconCustomizationRequest: SidebarIconCustomizationRequest?

    /// Bumped whenever git worktree metadata for any workspace is refreshed.
    /// Replaces a bare objectWillChange.send() so the invalidation survives
    /// the @Observable migration (which has no objectWillChange).
    private(set) var workspaceMetadataGeneration: Int = 0

    var settings: AppSettings {
        didSet {
            settingsSaver.schedule()
            settingsSubject.send(settings)
        }
    }

    @ObservationIgnored private let settingsSubject = PassthroughSubject<AppSettings, Never>()
    /// Bridge for AppDelegate's debounced menu/updater rebuild. Fires on
    /// every post-init settings assignment; never replays — the subscriber
    /// keeps its debounce but drops `.dropFirst()`.
    var settingsPublisher: AnyPublisher<AppSettings, Never> { settingsSubject.eraseToAnyPublisher() }

    /// Applies a new settings snapshot (used by SettingsSheet Save).
    func updateSettings(_ newSettings: AppSettings) {
        let terminalChanged = settings.terminal != newSettings.terminal
        let toggledOff = settings.showDefaultTerminal && !newSettings.showDefaultTerminal
        settings = newSettings
        if terminalChanged {
            NotificationCenter.default.post(name: .treemuxTerminalSettingsDidChange, object: newSettings.terminal)
        }
        if toggledOff && selectedWorkspaceID == WorkspaceModel.builtInDefaultTerminalID {
            // Switch to the first non-builtin workspace if any exists. If none, leave selection alone —
            // the empty-fallback rule will keep `~` visible in the sidebar so the UI stays consistent.
            if let firstReal = workspaces.first(where: { !$0.isBuiltInDefaultTerminal && !$0.isArchived }) {
                selectedWorkspaceID = firstReal.id
            }
        }
    }

    private let settingsPersistence = AppSettingsPersistence()
    private let workspaceStatePersistence = WorkspaceStatePersistence()
    private let gitService = GitRepositoryService()
    private let metadataWatcher = WorkspaceMetadataWatchService()
    private let tmuxService = TmuxService()

    /// Serial background queue for persistence encoding + IO. Flush paths use
    /// `.sync` so the final write is ordered after any in-flight debounced
    /// write to the same file.
    private static let persistenceQueue = DispatchQueue(label: "treemux.persistence", qos: .utility)

    @ObservationIgnored private lazy var settingsSaver = DebouncedSaver { [weak self] mode in
        guard let self else { return }
        let snapshot = self.settings
        let persistence = self.settingsPersistence
        switch mode {
        case .debounced:
            Self.persistenceQueue.async { try? persistence.save(snapshot) }
        case .flush:
            Self.persistenceQueue.sync { try? persistence.save(snapshot) }
        }
    }

    /// Synchronously writes any pending debounced state to disk. Call on app
    /// termination; safe to call at any time.
    func flushPendingPersistence() {
        settingsSaver.flush()
        stateSaver.flush()
    }

    /// How often to poll SSH-backed workspaces for git state changes.
    /// File system events cannot reach across SSH, so we fall back to a
    /// generous periodic poll plus an immediate refresh on window focus.
    private static let remoteRefreshInterval: TimeInterval = 30

    /// Timer that periodically polls SSH-backed workspaces. Created in `init`
    /// and lives for the entire app lifetime — `WorkspaceStore` is a long-lived
    /// singleton, so no `deinit` cleanup is required. If `WorkspaceStore` ever
    /// becomes non-singleton, add a deinit that invalidates this timer and
    /// removes `remoteWindowObserver`.
    @ObservationIgnored private var remoteRefreshTimer: Timer?

    /// Notification observer that immediately refreshes SSH-backed workspaces
    /// when any Treemux window becomes key. See `remoteRefreshTimer` for
    /// lifetime notes.
    @ObservationIgnored private var remoteWindowObserver: NSObjectProtocol?

    /// Reentry guard for `refreshAllRemoteWorkspaces`. Drops overlapping
    /// triggers (e.g. timer firing while a window-focus refresh is in flight).
    @ObservationIgnored private var isRefreshingRemotes = false

    /// Local repository discovery started while loading persisted state.
    /// Detached worktree refs cannot be validated until this task completes,
    /// because `WorkspaceRecord` persists session state but not the runtime
    /// `worktrees` array.
    @ObservationIgnored private var initialWorkspaceRefreshTask: Task<Void, Never>?

    /// Caches generated repository icons; invalidated whenever the workspace
    /// list mutates (add/remove/rename/icon change all call saveWorkspaceState).
    @ObservationIgnored private var sidebarIconCache: [UUID: SidebarItemIcon] = [:]

    /// Caches the remote workspace grouping; invalidated the same way as
    /// `sidebarIconCache` (see `saveWorkspaceState`).
    @ObservationIgnored private var remoteGroupsCache: [(key: String, targets: [WorkspaceModel])]?

    /// The currently selected workspace, if any.
    /// Resolves both workspace-level and worktree-level selection.
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
    /// Honors `settings.showDefaultTerminal`. When the toggle is off and at least
    /// one non-builtin workspace exists, the built-in `~` is hidden. When the toggle
    /// is off and no other workspace exists, the toggle is overridden so the sidebar
    /// is never empty.
    var sidebarWorkspaces: [WorkspaceModel] {
        let real = workspaces.filter { !$0.isArchived }
        return applyDefaultTerminalFilter(to: real)
    }

    /// Local workspaces (repositories and local terminals, non-archived).
    /// Same filtering rules as `sidebarWorkspaces`.
    var localWorkspaces: [WorkspaceModel] {
        let real = workspaces.filter { !$0.isArchived && $0.sshTarget == nil }
        return applyDefaultTerminalFilter(to: real)
    }

    /// Applies the `showDefaultTerminal` filter with empty-fallback override.
    private func applyDefaultTerminalFilter(to list: [WorkspaceModel]) -> [WorkspaceModel] {
        if settings.showDefaultTerminal { return list }
        let withoutBuiltin = list.filter { !$0.isBuiltInDefaultTerminal }
        return withoutBuiltin.isEmpty ? list : withoutBuiltin
    }

    /// Remote workspaces grouped by server+user combination.
    var remoteWorkspaceGroups: [(key: String, targets: [WorkspaceModel])] {
        // Tracked reads on cache hits (see FileBrowserTabController.visibleRows
        // rationale): a hit must still register the observable inputs, or the
        // calling SwiftUI body ends up with zero tracked dependencies.
        _ = workspaces
        _ = workspaceMetadataGeneration
        if let cached = remoteGroupsCache { return cached }
        let remotes = workspaces.filter { !$0.isArchived && $0.kind == .repository && $0.sshTarget != nil }
        let grouped = Dictionary(grouping: remotes) { ws -> String in
            guard let target = ws.sshTarget else { return "unknown" }
            return Self.remoteGroupKey(for: target)
        }
        let orderedKeys = Self.resolveRemoteGroupOrder(
            savedOrder: remoteGroupOrder,
            discoveredKeys: Array(grouped.keys)
        )
        let result = orderedKeys.compactMap { key in
            grouped[key].map { (key: key, targets: $0) }
        }
        remoteGroupsCache = result
        return result
    }

    init() {
        self.settings = settingsPersistence.load()
        loadWorkspaceState()
        ensureBuiltInDefaultTerminal()
        startRemoteWorkspaceRefreshScheduler()
    }

    /// Suspends until the launch-time local git inspection has populated each
    /// workspace's runtime worktree models.
    func waitForInitialWorkspaceRefresh() async {
        await initialWorkspaceRefreshTask?.value
    }

    /// Launch-time git refresh targets. Kept as a pure helper so the restore
    /// ordering policy can be verified without opening SSH connections.
    static func initialWorkspaceIDsToRefresh(
        workspaces: [WorkspaceModel],
        detachedNodes: Set<DetachedNodeRef>
    ) -> [UUID] {
        let detachedWorktreeWorkspaceIDs = Set(detachedNodes.compactMap { ref -> UUID? in
            guard case .worktree(let workspaceID, _) = ref else { return nil }
            return workspaceID
        })
        return workspaces
            .filter {
                $0.sshTarget == nil || detachedWorktreeWorkspaceIDs.contains($0.id)
            }
            .map(\.id)
    }

    /// Ensures exactly one built-in `~` workspace exists in `workspaces`. Inserts one if absent,
    /// deduplicates if multiple exist (keeping the first), and resets defensive state
    /// (archived flag, repositoryRoot) on the surviving entry. Persists if any mutation occurred.
    private func ensureBuiltInDefaultTerminal() {
        let homeURL = URL(fileURLWithPath: NSHomeDirectory())
        let builtins = workspaces.filter { $0.isBuiltInDefaultTerminal }
        var mutated = false

        if builtins.isEmpty {
            let builtin = WorkspaceModel(
                id: WorkspaceModel.builtInDefaultTerminalID,
                name: "~",
                kind: .localTerminal,
                repositoryRoot: homeURL,
                isBuiltInDefaultTerminal: true
            )
            workspaces.append(builtin)
            mutated = true
        } else if builtins.count > 1 {
            // Prefer the canonical-UUID entry; otherwise keep the first by position.
            let preferredID = builtins.first(where: { $0.id == WorkspaceModel.builtInDefaultTerminalID })?.id
                ?? builtins[0].id
            workspaces.removeAll { $0.isBuiltInDefaultTerminal && $0.id != preferredID }
            mutated = true
        }

        // Defensive state reset on the surviving built-in.
        if let builtin = workspaces.first(where: { $0.isBuiltInDefaultTerminal }) {
            if builtin.isArchived {
                builtin.isArchived = false
                mutated = true
            }
            if builtin.repositoryRoot != homeURL {
                builtin.repositoryRoot = homeURL
                mutated = true
            }
            if builtin.name != "~" {
                builtin.name = "~"
                mutated = true
            }
        }

        if selectedWorkspaceID == nil {
            // Match prior behavior: when launching with no prior selection, open on the
            // built-in terminal so the detail pane is never empty.
            selectedWorkspaceID = WorkspaceModel.builtInDefaultTerminalID
            mutated = true
        }

        if mutated {
            saveWorkspaceState()
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
        // Defensive: built-in `~` is not renameable. Silent early return.
        if id == WorkspaceModel.builtInDefaultTerminalID { return }
        guard let workspace = workspaces.first(where: { $0.id == id }),
              !newName.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        workspace.name = newName
        saveWorkspaceState()
    }

    // MARK: - Reordering Workspaces

    /// Moves local workspaces by translating sidebar indices to the workspaces array.
    func moveLocalWorkspace(from source: IndexSet, to destination: Int) {
        var local = localWorkspaces.filter { !isDetached(.workspace($0.id)) }
        local.move(fromOffsets: source, toOffset: destination)
        let movedIDs = Set(local.map(\.id))
        var localIterator = local.makeIterator()
        workspaces = workspaces.map { workspace in
            guard movedIDs.contains(workspace.id) else { return workspace }
            return localIterator.next() ?? workspace
        }
        saveWorkspaceState()
    }

    /// Group key for a remote SSH target, e.g. "my-server|root".
    static func remoteGroupKey(for target: SSHTarget) -> String {
        let user = target.user ?? ""
        return "\(target.displayName)|\(user)"
    }

    /// Computes the remote-group key for a workspace, or `nil` if the
    /// workspace is not SSH-backed (has no `sshTarget`).
    private func remoteGroupKey(for workspace: WorkspaceModel) -> String? {
        guard let target = workspace.sshTarget else { return nil }
        return Self.remoteGroupKey(for: target)
    }

    /// Returns true if the given node ref is currently recorded as detached
    /// (torn off into its own window). Drives the main sidebar's filter.
    func isDetached(_ ref: DetachedNodeRef) -> Bool {
        detachedNodes.contains(ref)
    }

    /// Workspaces belonging to a remote group key (used by the detached
    /// remote-group window view to list the workspaces it owns).
    func workspacesInRemoteGroup(_ key: String) -> [WorkspaceModel] {
        workspaces.filter { remoteGroupKey(for: $0) == key }
    }

    /// Returns true if the referenced node still exists in the store.
    /// Stale refs (e.g. a workspace/worktree deleted on disk, or a remote
    /// group that no longer has any member) are dropped during window restore.
    func isValid(_ ref: DetachedNodeRef) -> Bool {
        switch ref {
        case .workspace(let id):
            return workspaces.contains { $0.id == id }
        case .worktree(let wsID, let wtID):
            guard let ws = workspaces.first(where: { $0.id == wsID }) else { return false }
            return ws.worktrees.contains { $0.id == wtID }
        case .remoteGroup(let key):
            return workspaces.contains { remoteGroupKey(for: $0) == key }
        }
    }

    /// Display title for a remote workspace group, e.g. "my-server (root@192.168.1.100)".
    static func remoteGroupDisplayTitle(for target: SSHTarget) -> String {
        if let user = target.user, !user.isEmpty {
            return "\(target.displayName) (\(user)@\(target.host))"
        }
        return "\(target.displayName) (\(target.host))"
    }

    static func resolveRemoteGroupOrder(
        savedOrder: [String]?,
        discoveredKeys: [String]
    ) -> [String] {
        let discovered = Set(discoveredKeys)
        var seen = Set<String>()
        let retained = (savedOrder ?? []).filter { key in
            discovered.contains(key) && seen.insert(key).inserted
        }
        let appended = discovered.subtracting(seen).sorted()
        return retained + appended
    }

    /// Moves a remote server header while leaving workspace row order untouched.
    func moveRemoteGroup(_ groupKey: String, to destination: Int) {
        var keys = remoteWorkspaceGroups.map(\.key)
        guard let source = keys.firstIndex(of: groupKey) else { return }
        let clampedDestination = min(max(destination, 0), keys.count)
        keys.move(fromOffsets: IndexSet(integer: source), toOffset: clampedDestination)
        guard keys != remoteWorkspaceGroups.map(\.key) else { return }
        remoteGroupOrder = keys
        saveWorkspaceState()
    }

    /// Moves remote workspaces within a specific server group.
    func moveRemoteWorkspace(groupKey: String, from source: IndexSet, to destination: Int) {
        let remotes = workspaces.filter { !$0.isArchived && $0.sshTarget != nil }
        var group = remotes.filter { ws in
            guard let target = ws.sshTarget else { return false }
            return Self.remoteGroupKey(for: target) == groupKey
                && !isDetached(.workspace(ws.id))
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
        // Defensive: never remove the built-in. Silent early return.
        if id == WorkspaceModel.builtInDefaultTerminalID { return }

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
        // Drop any detached-window refs that pointed at this workspace or one
        // of its worktrees. Without this, stale refs would persist in
        // workspace-state.json until the next launch (isValid is only checked
        // at restore time), and the torn-off child window would point at a
        // node that no longer exists.
        detachedNodes = detachedNodes.filter { ref in
            switch ref {
            case .workspace(let wsID):
                return wsID != id
            case .worktree(let wsID, _):
                return wsID != id
            case .remoteGroup:
                // The remote group may still have other members; leave it.
                return true
            }
        }
        saveWorkspaceState()
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
            // Skip cleanup when no worktrees were detected (non-git directory) —
            // an empty worktree list means git failed, not that all worktrees
            // were removed. Without this guard, every 30-second remote refresh
            // would terminate and recreate all sessions for non-git workspaces.
            let currentWorktreePaths = Set(merged.map { $0.path.path })
            if !currentWorktreePaths.isEmpty {
                let fallbackPath = merged.first(where: { $0.isMainWorktree })?.path.path
                    ?? merged.first?.path.path
                    ?? workspace.repositoryRoot?.path
                    ?? workspace.sshTarget?.remotePath
                    ?? ""
                workspace.cleanupRemovedWorktrees(
                    currentPaths: currentWorktreePaths,
                    fallbackPath: fallbackPath
                )
            }

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
            workspaceMetadataGeneration += 1
            workspaceStructureDidChange?()
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

    /// Refreshes every SSH-backed workspace concurrently. No-op for local
    /// workspaces. Reentry-guarded so overlapping triggers (timer + window
    /// focus, or back-to-back) don't stack SSH connections.
    private func refreshAllRemoteWorkspaces() async {
        guard !isRefreshingRemotes else { return }
        let ids = workspaces
            .filter { $0.sshTarget != nil && !$0.isArchived }
            .map(\.id)
        guard !ids.isEmpty else { return }
        isRefreshingRemotes = true
        defer { isRefreshingRemotes = false }
        await refreshRemoteWorkspacesConcurrently(ids: ids) { [weak self] id in
            guard let self,
                  let workspace = self.workspaces.first(where: { $0.id == id }) else { return }
            await self.refreshWorkspace(workspace)
        }
    }

    /// Runs `refresh` for every workspace id concurrently and returns when all
    /// finish. The closures hop to the main actor, but each SSH round-trip
    /// suspends there, so the network waits overlap — total wall-clock is
    /// roughly the slowest workspace instead of the sum. IDs (not models)
    /// cross the task boundary; each closure re-resolves its workspace so a
    /// mid-flight removal is safely skipped. Internal so tests can drive the
    /// concurrency shape without real SSH.
    func refreshRemoteWorkspacesConcurrently(
        ids: [UUID],
        using refresh: @escaping @MainActor @Sendable (UUID) async -> Void
    ) async {
        await withTaskGroup(of: Void.self) { group in
            for id in ids {
                group.addTask { await refresh(id) }
            }
        }
    }

    // MARK: - Persistence

    private func loadWorkspaceState() {
        let state = workspaceStatePersistence.load()
        selectedWorkspaceID = state.selectedWorkspaceID
        collapsedSections = Set(state.collapsedSections ?? [])
        remoteGroupOrder = state.remoteGroupOrder
        detachedNodes = Set(state.detachedNodes ?? [])
        workspaces = state.workspaces.map { WorkspaceModel(from: $0) }
        startWatchingAll()

        // Populate local worktrees and branch info from git on launch. Remote
        // workspaces normally stay with the periodic refresh scheduler, but a
        // remote workspace owning a persisted detached worktree must refresh
        // here too so restoration can validate that ref.
        initialWorkspaceRefreshTask = Task { [weak self] in
            guard let self else { return }
            let workspaceIDs = Self.initialWorkspaceIDsToRefresh(
                workspaces: workspaces,
                detachedNodes: detachedNodes
            )
            for id in workspaceIDs {
                guard let workspace = workspaces.first(where: { $0.id == id }) else { continue }
                await refreshWorkspace(workspace)
            }
            // Restart watchers with full worktree paths now available
            startWatchingAll()
        }
    }

    /// Cache invalidation MUST stay synchronous here — this is the single
    /// invalidation point for the sidebarIcon/remoteWorkspaceGroups memos
    /// (P1a Task 9). Only snapshot building + encoding + disk IO moved to the
    /// debounced path.
    func saveWorkspaceState() {
        let resolvedRemoteOrder = resolvedRemoteGroupOrderForCurrentWorkspaces()
        let normalizedRemoteOrder = resolvedRemoteOrder.isEmpty ? nil : resolvedRemoteOrder
        if remoteGroupOrder != normalizedRemoteOrder {
            remoteGroupOrder = normalizedRemoteOrder
        }

        // Invalidate derived caches: this is the aggregation point for every
        // structural mutation to `workspaces` (add/remove/rename/icon change/
        // reorder), so clearing here covers all of them without needing a
        // bespoke invalidation call at each call site.
        sidebarIconCache.removeAll()
        remoteGroupsCache = nil

        workspaceStructureDidChange?()

        stateSaver.schedule()
    }

    private func resolvedRemoteGroupOrderForCurrentWorkspaces() -> [String] {
        let discoveredRemoteKeys = workspaces.compactMap { workspace -> String? in
            guard !workspace.isArchived,
                  workspace.kind == .repository,
                  let target = workspace.sshTarget else { return nil }
            return Self.remoteGroupKey(for: target)
        }
        return Self.resolveRemoteGroupOrder(
            savedOrder: remoteGroupOrder,
            discoveredKeys: discoveredRemoteKeys
        )
    }

    private func buildPersistedWorkspaceState() -> PersistedWorkspaceState {
        // Resolve to workspace-level ID for persistence (worktree IDs are unstable across launches).
        let resolvedID: UUID? = {
            guard let id = selectedWorkspaceID else { return nil }
            if workspaces.contains(where: { $0.id == id }) { return id }
            if let ws = workspaces.first(where: { ws in ws.worktrees.contains { $0.id == id } }) {
                return ws.id
            }
            return nil
        }()
        let persistedSelectedID = resolvedID
        let persistedRemoteOrder = resolvedRemoteGroupOrderForCurrentWorkspaces()
        return PersistedWorkspaceState(
            version: 1,
            selectedWorkspaceID: persistedSelectedID,
            workspaces: workspaces.map { $0.toRecord() },
            collapsedSections: collapsedSections.isEmpty ? nil : Array(collapsedSections),
            remoteGroupOrder: persistedRemoteOrder.isEmpty ? nil : persistedRemoteOrder,
            // Omit the key entirely when empty so the persisted file stays
            // close to the legacy shape for users with no detached windows.
            detachedNodes: detachedNodes.isEmpty ? nil : detachedNodes
        )
    }

    /// Builds the persisted snapshot on the main actor (reads live models),
    /// then encodes + writes off-main for `.debounced`, synchronously for
    /// `.flush`.
    @ObservationIgnored private lazy var stateSaver = DebouncedSaver { [weak self] mode in
        guard let self else { return }
        let state = self.buildPersistedWorkspaceState()
        let persistence = self.workspaceStatePersistence
        switch mode {
        case .debounced:
            Self.persistenceQueue.async { try? persistence.save(state) }
        case .flush:
            Self.persistenceQueue.sync { try? persistence.save(state) }
        }
    }

    // MARK: - Sidebar Icons

    /// Returns the resolved sidebar icon for a workspace, considering user overrides and app defaults.
    func sidebarIcon(for workspace: WorkspaceModel) -> SidebarItemIcon {
        // Tracked reads on cache hits (see FileBrowserTabController.visibleRows
        // rationale): a hit must still register the observable inputs, or the
        // calling SwiftUI body ends up with zero tracked dependencies.
        _ = workspaces
        _ = workspaceMetadataGeneration
        if let override = workspace.workspaceIcon {
            return override
        }
        switch workspace.kind {
        case .localTerminal:
            return settings.defaultLocalTerminalIcon
        case .repository:
            if let cached = sidebarIconCache[workspace.id] { return cached }
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
            let icon = SidebarItemIcon.randomRepository(
                preferredSeed: iconSeed,
                avoiding: existingIcons
            )
            sidebarIconCache[workspace.id] = icon
            return icon
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
        // Tracked reads on cache hits (see FileBrowserTabController.visibleRows
        // rationale): a hit must still register the observable inputs, or the
        // calling SwiftUI body ends up with zero tracked dependencies.
        _ = workspaces
        _ = workspaceMetadataGeneration
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
