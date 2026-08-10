//
//  FileBrowserTabController.swift
//  Treemux

import AppKit
import Foundation
import Observation

/// Selects which form of a file path is written to the pasteboard
/// by ``FileBrowserTabController/copyPath(_:mode:)``.
enum CopyPathMode { case absolute, relative }

/// Runtime mirror of `FileSubTabRecord` augmented with the in-memory
/// `OpenFileState` for the file the sub-tab is showing. Only `isPinned == true`
/// records are persisted (snapshot drops the preview tab).
struct SubTabRuntime: Identifiable, Equatable {
    let id: UUID
    var path: String
    var isPinned: Bool
    var openFile: OpenFileState
    /// Per-file rendering mode, mirrored from `FileSubTabRecord.viewMode`.
    /// `nil` means "use the default for this file kind".
    var viewMode: FileViewMode?
}

@MainActor
@Observable
final class FileBrowserTabController {
    /// Surfaced load failure for the file tree. UI binds this to a banner
    /// (Task B4) so SSH-key/permission failures stop being silently swallowed.
    enum LoadError: Equatable {
        case generic(String)
        case needsPassword(host: String)
    }

    // Persistent state mirrors / writes back to FileBrowserTabState.
    var rootPath: String
    private(set) var rootKind: FileBrowserRootKind
    var splitRatio: Double
    var expandedDirs: Set<String> {
        didSet { visibleRowsCache = nil }
    }
    var showsHiddenFiles: Bool {
        didSet { visibleRowsCache = nil }
    }

    // Runtime state.
    private(set) var rootChildren: [FileNode] = [] {
        didSet { visibleRowsCache = nil }
    }
    private(set) var childrenByPath: [String: [FileNode]] = [:] {
        didSet { visibleRowsCache = nil }
    }
    @ObservationIgnored private var rawChildrenByPath: [String: [FileNode]] = [:] {
        didSet { rawTreeGeneration += 1 }
    }

    /// Monotonic generation for rawChildrenByPath. The async hidden-file filter
    /// compares it before applying, so a tree mutation that lands mid-filter
    /// (expand/refresh completing) restarts the filter instead of clobbering
    /// newer entries with a stale derived dictionary.
    @ObservationIgnored private var rawTreeGeneration = 0

    /// Test seam: awaiting this task guarantees the last toggle has been applied.
    @ObservationIgnored private(set) var pendingHiddenFilterTask: Task<Void, Never>?
    private(set) var subTabs: [SubTabRuntime] = [] {
        didSet { visibleRowsCache = nil }
    }
    private(set) var activeSubTabID: UUID? {
        didSet { visibleRowsCache = nil }
    }
    private(set) var loadingPaths: Set<String> = []
    private(set) var loadError: LoadError?
    private(set) var symlinkErrorsByPath: [String: String] = [:] {
        didSet { visibleRowsCache = nil }
    }
    @ObservationIgnored private var canonicalIdentityByPath: [String: String] = [:]
    @ObservationIgnored private var expansionTokens: [String: UUID] = [:]
    @ObservationIgnored private var treeLoadGeneration = 0

    // Git diff/status caches. `diffHunksByPath` keyed by absolute path of the
    // active sub-tab; `fileStatusByPath` keyed by absolute path under `repoRoot`.
    private(set) var diffHunksByPath: [String: [DiffHunk]] = [:]
    private(set) var fileStatusByPath: [String: FileStatus] = [:] {
        didSet { visibleRowsCache = nil }
    }

    // Configuration.
    static let textReadLimit: Int = 5 * 1024 * 1024       // 5 MB
    static let largeFileThreshold: Int64 = 5 * 1024 * 1024 // 5 MB
    static let quickLookOnlyThreshold: Int64 = 100 * 1024 * 1024 // 100 MB
    static let treeFetchDepth: Int = 2
    static let treeEntryCap: Int = 500
    static let searchMaxResults = 500
    static let searchMaxDepth = 12

    let dataSource: any FileBrowserDataSource
    let gitDiffService: GitDiffService?
    let repoRoot: String?
    let treeCache: DirectoryTreeCachePersistence
    private(set) var truncatedDirs: Set<String> = [] {
        didSet { visibleRowsCache = nil }
    }

    /// Live search field text. Typing filters the loaded tree; changing it
    /// cancels any in-flight recursive search and returns to live-filter mode.
    var searchQuery: String = "" {
        didSet {
            guard searchQuery != oldValue else { return }
            showingRecursiveResults = false
            searchResults = []
            searchError = nil
            searchTask?.cancel()
            searchTask = nil
            // A cancelled task's own cleanup (`if !Task.isCancelled { isSearching = false }`
            // in performRecursiveSearch) never runs once cancelled, so this is the only
            // place left to clear the flag — otherwise editing the query mid-search
            // leaves `isSearching` stuck `true` forever.
            isSearching = false
            visibleRowsCache = nil
        }
    }
    private(set) var isSearching = false { didSet { visibleRowsCache = nil } }
    private(set) var showingRecursiveResults = false { didSet { visibleRowsCache = nil } }
    private(set) var searchResults: [FileNode] = [] { didSet { visibleRowsCache = nil } }
    private(set) var searchError: String?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// True when this tab browses a remote host (system-SSH or Citadel). Drives
    /// the local-vs-remote escalation-hint copy. `rootKind` (.project/.worktree)
    /// is orthogonal — both are local — so it MUST NOT be used for this.
    var isRemote: Bool { dataSource is RemoteFileBrowserDataSource }

    /// Inline "new folder / new file" editor state. Non-nil while the user is
    /// typing a name. Drives an `.editor` row in `visibleRows()`.
    struct NewEntryDraft: Equatable {
        let parentPath: String
        let intent: NewEntryIntent
        var errorMessage: String?
    }
    private(set) var newEntryDraft: NewEntryDraft? {
        didSet { visibleRowsCache = nil }
    }

    /// Memoized result of the last `visibleRows()` flatten. Invalidated (set
    /// to `nil`) via `didSet` on every observed property the flatten
    /// reads: `rootChildren`, `childrenByPath`, `expandedDirs`,
    /// `truncatedDirs`, `fileStatusByPath`, `activeSubTabID`, `subTabs`
    /// (which `selectedFilePath` derives from), and `showsHiddenFiles`
    /// (belt-and-suspenders — it only actually takes effect by re-deriving
    /// `childrenByPath`/`rootChildren`, but is included directly in case that
    /// ever changes). Without this, `FileTreePanelView.body` re-flattened the
    /// whole tree — O(n) work plus an O(n) Equatable diff against the
    /// previous `[FileTreeRowModel]` — on every re-render, even ones the
    /// tree's own state had nothing to do with.
    @ObservationIgnored private var visibleRowsCache: [FileTreeRowModel]?

    #if DEBUG
    /// Test seam: counts actual flattens (cache misses), so tests can assert
    /// the cache is hit/invalidated at the right times without depending on
    /// timing. Not gated on anything but DEBUG — cheap increment.
    @ObservationIgnored private(set) var visibleRowsComputeCount = 0
    #endif

    /// Last known vertical scroll offset of the file tree. Cached in-memory so
    /// the tree restores its position when the tab is re-mounted (e.g. after
    /// switching to a terminal tab and back). @ObservationIgnored — must not
    /// trigger a re-render, and it is intentionally never persisted to disk.
    @ObservationIgnored var treeScrollOffset: CGFloat = 0

    /// Bumped whenever a full tree reload settles (bulk fetch + any async
    /// deeper expanded directories applied). The tree view observes this to
    /// re-assert a restored scroll offset once remote children have arrived —
    /// otherwise the offset is applied against a shorter, still-loading tree
    /// and lands in the wrong place. Local trees render instantly from cache,
    /// so they settle on the first bump.
    private(set) var treeContentGeneration: Int = 0

    /// Shared word index for editor completion across this tab's sub-tabs.
    /// Lazily populated by `WordCompletionCoordinator` as buffers open.
    let wordIndex = BufferWordIndex()

    /// Called when the persistent state should be written back into
    /// `WorkspaceTabStateRecord.fileBrowserState` (debounced by caller).
    @ObservationIgnored var onPersistableStateChanged: (() -> Void)?

    init(
        initial state: FileBrowserTabState,
        dataSource: any FileBrowserDataSource,
        gitDiffService: GitDiffService? = nil,
        repoRoot: String? = nil,
        treeCache: DirectoryTreeCachePersistence = DirectoryTreeCachePersistence()
    ) {
        self.rootPath = state.rootPath
        self.rootKind = state.rootKind
        self.splitRatio = state.splitRatio
        self.expandedDirs = Set(state.expandedDirs)
        self.showsHiddenFiles = state.showsHiddenFiles
        self.dataSource = dataSource
        self.gitDiffService = gitDiffService
        self.repoRoot = repoRoot
        self.treeCache = treeCache
        self.subTabs = state.subTabs.map {
            SubTabRuntime(id: $0.id, path: $0.path, isPinned: $0.isPinned, openFile: .empty,
                          viewMode: $0.viewMode)
        }
        self.activeSubTabID = state.activeSubTabID ?? self.subTabs.first?.id
    }

    func snapshot() -> FileBrowserTabState {
        let pinned = subTabs.filter { $0.isPinned }.map {
            FileSubTabRecord(id: $0.id, path: $0.path, isPinned: true, viewMode: $0.viewMode)
        }
        let activeID: UUID? = {
            if let active = activeSubTab, active.isPinned { return active.id }
            return pinned.last?.id
        }()
        return FileBrowserTabState(
            rootPath: rootPath,
            rootKind: rootKind,
            splitRatio: splitRatio,
            expandedDirs: Array(expandedDirs),
            showsHiddenFiles: showsHiddenFiles,
            subTabs: pinned,
            activeSubTabID: activeID
        )
    }

    // MARK: - Sub-tab access

    /// The currently focused sub-tab (if any).
    var activeSubTab: SubTabRuntime? {
        subTabs.first(where: { $0.id == activeSubTabID })
    }

    /// Backward-compat read for SwiftUI consumers (e.g. `FileViewerPanelView`)
    /// that still address the controller as if it owned a single open file.
    /// SwiftUI re-renders on `subTabs` / `activeSubTabID` changes, so the
    /// computed-property approach is sufficient.
    var openFile: OpenFileState { activeSubTab?.openFile ?? .empty }

    /// Backward-compat read for the file-tree row's "selected" highlight.
    var selectedFilePath: String? { activeSubTab?.path }

    /// All sub-tabs whose buffer is currently dirty. Stage F1 will use this to
    /// drive the "X files have unsaved changes" sheet on outer-tab close.
    var dirtySubTabs: [SubTabRuntime] {
        subTabs.filter {
            if case .text(_, _, _, let dirty) = $0.openFile { return dirty }
            return false
        }
    }

    private func setActiveOpenFile(_ state: OpenFileState) {
        guard let id = activeSubTabID,
              let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
        subTabs[idx].openFile = state
    }

    /// Writes `state` into the sub-tab identified by `id`, but only if that
    /// sub-tab still exists AND its `path` still equals `expectingPath`.
    /// Used by async load chains so a stale completion can't overwrite the
    /// wrong sub-tab when the user has switched tabs or repurposed the
    /// preview tab mid-load.
    private func setOpenFile(
        forSubTab id: UUID,
        expectingPath path: String,
        _ state: OpenFileState
    ) {
        guard let idx = subTabs.firstIndex(where: { $0.id == id }),
              subTabs[idx].path == path else { return }
        subTabs[idx].openFile = state
    }

    private var activeOpenFile: OpenFileState {
        activeSubTab?.openFile ?? .empty
    }

    private func loadActiveTab() async {
        guard let active = activeSubTab else { return }
        await selectFile(active.path, subTabID: active.id)
    }

    // MARK: - Tree loading

    func loadRoot() async {
        loadError = nil
        // 1. Instant render from the on-disk cache if present. The file read +
        //    JSON decode runs off the main actor (mirroring persistTree's write
        //    side) — a large remote snapshot used to block the first frame for
        //    the whole synchronous decode.
        if let identity = dataSource.treeCacheIdentity {
            let cache = treeCache
            let root = rootPath
            let snap = await Task.detached(priority: .userInitiated) {
                cache.load(identity: identity, rootPath: root)
            }.value
            // Apply only while the tree is still unpopulated: the detached read
            // introduces a suspension point, so a concurrent refreshTree()
            // (manual refresh / retry) may have landed fresher data during the
            // await — never clobber it with the older on-disk snapshot. On the
            // cold-start path rootChildren is always empty here, so the
            // cache-first instant render is unaffected.
            if let snap, rootChildren.isEmpty {
                applySnapshot(snap)
            }
        }
        // 2. Background-refresh via bulk fetch (also the only fetch path on a cache miss).
        await refreshTree()
    }

    /// Bulk-fetch the tree, diff/apply it onto the live state without collapsing
    /// the user's expansion, restore any expanded dirs deeper than the fetch
    /// reached, then persist the snapshot. Refresh errors are swallowed when a
    /// cache is already on screen.
    func refreshTree() async {
        treeLoadGeneration &+= 1
        let generation = treeLoadGeneration
        expansionTokens.removeAll()
        loadingPaths.removeAll()
        symlinkErrorsByPath.removeAll()
        canonicalIdentityByPath.removeAll()
        loadError = nil
        do {
            let fetch = try await dataSource.listTree(
                rootPath, maxDepth: Self.treeFetchDepth, entryCap: Self.treeEntryCap)
            guard treeLoadGeneration == generation else { return }
            applyFetch(fetch)
            for path in expandedDirs where path != rootPath && fetch.childrenByPath[path] == nil {
                guard await validateExpansion(path) else { continue }
                if let kids = try? await dataSource.listDirectory(path) {
                    guard treeLoadGeneration == generation else { return }
                    rawChildrenByPath[path] = kids
                    childrenByPath[path] = filtered(kids)
                }
            }
            await persistTree()
            // The full tree (bulk fetch + async deeper expanded dirs) is now
            // applied; signal the view so it can re-assert a restored offset.
            PerfSignpost.event("tree-generation-bump")
            treeContentGeneration &+= 1
            await refreshGitStatus()
        } catch {
            let mapped = mapError(error)
            if case .needsPassword = mapped {
                loadError = mapped
            } else if rootChildren.isEmpty {
                loadError = mapped
            }
        }
    }

    private func applySnapshot(_ snap: DirectoryTreeSnapshot) {
        for (path, kids) in snap.childrenByPath {
            rawChildrenByPath[path] = kids
            childrenByPath[path] = filtered(kids)
        }
        truncatedDirs = Set(snap.truncatedDirs)
        rootChildren = childrenByPath[rootPath] ?? []
    }

    /// Applies a fresh bulk fetch, only re-binding directories whose contents
    /// actually changed (cheap `Equatable` compare) so SwiftUI churn stays low.
    /// `expandedDirs` is left untouched, so the tree keeps its open state.
    private func applyFetch(_ fetch: DirectoryTreeFetch) {
        for (path, kids) in fetch.childrenByPath where rawChildrenByPath[path] != kids {
            rawChildrenByPath[path] = kids
            childrenByPath[path] = filtered(kids)
        }
        for dir in fetch.childrenByPath.keys { truncatedDirs.remove(dir) }
        truncatedDirs.formUnion(fetch.truncatedDirs)
        rootChildren = childrenByPath[rootPath] ?? []
    }

    private func persistTree() async {
        guard let identity = dataSource.treeCacheIdentity else { return }
        // Snapshot the (value-type) tree on the main actor, then JSON-encode and
        // write it to disk off the main thread. For a large remote tree the
        // encode + atomic write took long enough to visibly freeze the UI while
        // the fetch settled. Awaiting a detached task moves the work off the
        // main actor (the UI keeps ticking during the await) while still
        // finishing the write before the caller continues.
        let snap = DirectoryTreeSnapshot(
            rootPath: rootPath,
            childrenByPath: rawChildrenByPath,
            truncatedDirs: Array(truncatedDirs),
            fetchedAt: Date()
        )
        let cache = treeCache
        await Task.detached(priority: .utility) {
            try? cache.save(snap, identity: identity)
        }.value
    }

    func toggleExpand(_ path: String) async {
        if loadingPaths.contains(path) {
            expansionTokens[path] = nil
            loadingPaths.remove(path)
            return
        }
        if expandedDirs.contains(path) {
            expansionTokens[path] = nil
            expandedDirs.remove(path)
            rawChildrenByPath[path] = nil
            childrenByPath[path] = nil
        } else {
            let token = UUID()
            let generation = treeLoadGeneration
            expansionTokens[path] = token
            loadingPaths.insert(path)
            var retainedAsExpansionIdentity = false
            defer {
                if expansionTokens[path] == token {
                    loadingPaths.remove(path)
                    if !retainedAsExpansionIdentity {
                        expansionTokens[path] = nil
                    }
                }
            }
            do {
                guard await validateExpansion(path),
                      expansionTokens[path] == token,
                      treeLoadGeneration == generation else { return }
                let kids = try await dataSource.listDirectory(path)
                guard expansionTokens[path] == token,
                      treeLoadGeneration == generation else { return }
                rawChildrenByPath[path] = kids
                childrenByPath[path] = filtered(kids)
                expandedDirs.insert(path)
                symlinkErrorsByPath[path] = nil
                retainedAsExpansionIdentity = true
                Task { [weak self] in
                    await self?.prefetchChildren(
                        of: path, generation: generation, expansionToken: token)
                }
            } catch {
                guard expansionTokens[path] == token,
                      treeLoadGeneration == generation else { return }
                // Leave collapsed on error; surface via loadError so the UI banner can show.
                loadError = mapError(error)
            }
        }
        onPersistableStateChanged?()
    }

    /// Background-prefetch a directory's grandchildren so expanding its children
    /// is instant. Internal (not private) so it is unit-testable directly.
    func prefetchChildren(of path: String) async {
        await prefetchChildren(
            of: path, generation: treeLoadGeneration, expansionToken: nil)
    }

    private func prefetchChildren(
        of path: String,
        generation: Int,
        expansionToken: UUID?
    ) async {
        guard let fetch = try? await dataSource.listTree(
            path, maxDepth: Self.treeFetchDepth, entryCap: Self.treeEntryCap) else { return }
        guard treeLoadGeneration == generation, expandedDirs.contains(path) else { return }
        if let expansionToken {
            guard expansionTokens[path] == expansionToken else { return }
        }
        for (p, kids) in fetch.childrenByPath where rawChildrenByPath[p] != kids {
            rawChildrenByPath[p] = kids
            childrenByPath[p] = filtered(kids)
        }
        truncatedDirs.formUnion(fetch.truncatedDirs)
    }

    private func validateExpansion(_ path: String) async -> Bool {
        guard let node = node(at: path), node.isSymlink else { return true }
        guard case .directory(let targetIdentity) = node.symlinkTargetResolution else {
            symlinkErrorsByPath[path] = symlinkErrorMessage(for: node.symlinkTargetResolution)
            return false
        }

        do {
            for ancestor in ancestorPaths(of: path) {
                let identity = try await canonicalIdentity(for: ancestor)
                if identity == targetIdentity {
                    symlinkErrorsByPath[path] = String(localized: "This symbolic link points to an ancestor, so expansion was stopped.")
                    return false
                }
            }
            return true
        } catch {
            symlinkErrorsByPath[path] = error.localizedDescription
            return false
        }
    }

    private func canonicalIdentity(for path: String) async throws -> String {
        if let cached = canonicalIdentityByPath[path] { return cached }
        if let embedded = node(at: path)?.canonicalDirectoryIdentity {
            canonicalIdentityByPath[path] = embedded
            return embedded
        }
        let identity = try await dataSource.canonicalDirectoryIdentity(path)
        canonicalIdentityByPath[path] = identity
        return identity
    }

    private func ancestorPaths(of path: String) -> [String] {
        var paths: [String] = []
        var current = (path as NSString).deletingLastPathComponent
        while current == rootPath || current.hasPrefix(rootPath + "/") {
            paths.append(current)
            if current == rootPath { break }
            current = (current as NSString).deletingLastPathComponent
        }
        return paths.reversed()
    }

    private func node(at path: String) -> FileNode? {
        let parent = (path as NSString).deletingLastPathComponent
        let siblings = parent == rootPath ? rootChildren : childrenByPath[parent]
        return siblings?.first { $0.path == path }
    }

    private func symlinkErrorMessage(for resolution: SymlinkTargetResolution) -> String {
        switch resolution {
        case .directory:
            return String(localized: "The symbolic link could not be expanded.")
        case .file:
            return ""
        case .broken:
            return String(localized: "The symbolic link target no longer exists.")
        case .inaccessible:
            return String(localized: "The symbolic link target cannot be read.")
        case .unresolved(let reason):
            return reason ?? String(localized: "The server could not resolve this symbolic link target.")
        }
    }

    func activateNode(_ node: FileNode) async {
        if node.isExpandableDirectory {
            await toggleExpand(node.path)
            return
        }
        if node.isSymlink {
            switch node.symlinkTargetResolution {
            case .file:
                break
            default:
                symlinkErrorsByPath[node.path] = symlinkErrorMessage(for: node.symlinkTargetResolution)
                return
            }
        }
        await openInTree(node.path)
    }

    func setShowsHiddenFiles(_ show: Bool) {
        guard showsHiddenFiles != show else { return }
        showsHiddenFiles = show
        rederiveFilteredChildren()
        onPersistableStateChanged?()
    }

    /// Re-derives the filtered listings from the unfiltered cache off the main
    /// actor, then applies the result atomically. The whole-tree O(n) filter
    /// used to run synchronously here and stalled the main thread on large trees.
    ///
    /// Race argument: this closure is a `Task {}` created on the @MainActor,
    /// so it inherits the actor — every line before and after the `await` runs
    /// serialized with the rest of the controller's main-actor work (toggles,
    /// tree mutations). A newer toggle cancels the in-flight task before
    /// starting its own, and the old task's continuation checks
    /// `Task.isCancelled` right after the await, so a superseded computation
    /// never applies. If a tree mutation (expand/refresh completing) lands
    /// during the filter's background window, `rawTreeGeneration` no longer
    /// matches the snapshot this task captured, so instead of clobbering the
    /// newer raw data with a stale derived dictionary it just restarts the
    /// filter from the fresh state — each restart captures a strictly newer
    /// snapshot, so this converges in a bounded number of iterations.
    private func rederiveFilteredChildren() {
        let show = showsHiddenFiles
        let raw = rawChildrenByPath
        let generation = rawTreeGeneration
        pendingHiddenFilterTask?.cancel()
        pendingHiddenFilterTask = Task { [weak self] in
            let derived = await Task.detached(priority: .userInitiated) { () -> [String: [FileNode]] in
                var result: [String: [FileNode]] = [:]
                result.reserveCapacity(raw.count)
                for (path, nodes) in raw {
                    result[path] = show ? nodes : nodes.filter { !$0.isHidden }
                }
                return result
            }.value
            guard let self, !Task.isCancelled else { return }
            guard self.rawTreeGeneration == generation, self.showsHiddenFiles == show else {
                self.rederiveFilteredChildren()   // inputs moved mid-filter; recompute fresh
                return
            }
            self.childrenByPath = derived
            self.rootChildren = derived[self.rootPath] ?? []
            self.pendingHiddenFilterTask = nil
        }
    }

    func refresh(_ path: String) async {
        do {
            let kids = try await dataSource.listDirectory(path)
            rawChildrenByPath[path] = kids
            childrenByPath[path] = filtered(kids)
            if path == rootPath { rootChildren = childrenByPath[path] ?? [] }
        } catch {
            // Surface via loadError so the UI banner can show (do not reset on entry —
            // user-driven retries go through loadRoot, which clears).
            loadError = mapError(error)
        }
    }

    private func filtered(_ nodes: [FileNode]) -> [FileNode] {
        showsHiddenFiles ? nodes : nodes.filter { !$0.isHidden }
    }

    // MARK: - New entry

    /// The directory a new entry should be created in, given a right-clicked
    /// node: the node itself when it is a directory, else its parent.
    func targetDirectory(for node: FileNode) -> String {
        node.isExpandableDirectory ? node.path : (node.path as NSString).deletingLastPathComponent
    }

    func beginNewEntry(intent: NewEntryIntent, in directory: String) async {
        // Expand the full ancestor chain so the editor row's parent is actually
        // reachable during visibleRows() flatten — not just the immediate dir.
        if directory != rootPath {
            let rel = relativePath(directory)
            var current = rootPath
            for component in rel.split(separator: "/") {
                current += "/" + component
                if !expandedDirs.contains(current) {
                    await toggleExpand(current)
                    // If a level failed to expand (data-source error), don't leave a
                    // draft that can never render — bail; loadError already surfaces.
                    guard expandedDirs.contains(current) else { return }
                }
            }
        }
        newEntryDraft = NewEntryDraft(parentPath: directory, intent: intent, errorMessage: nil)
    }

    func cancelNewEntry() {
        newEntryDraft = nil
    }

    /// Returns a localized error message for an invalid name, or nil if valid.
    func validateNewEntryName(_ name: String, in directory: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return String(localized: "Name cannot be empty") }
        if trimmed.contains("/") { return String(localized: "Name cannot contain a slash") }
        let siblings = (directory == rootPath) ? rootChildren : (childrenByPath[directory] ?? [])
        if siblings.contains(where: { $0.name == trimmed }) {
            return String.localizedStringWithFormat(
                String(localized: "An item named \"%@\" already exists"), trimmed)
        }
        return nil
    }

    func commitNewEntry(name: String) async {
        guard let draft = newEntryDraft else { return }
        let dir = draft.parentPath
        if let err = validateNewEntryName(name, in: dir) {
            newEntryDraft?.errorMessage = err
            return
        }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let newPath = (dir == "/" ? "" : dir) + "/" + trimmed
        do {
            switch draft.intent {
            case .folder: try await dataSource.createDirectory(newPath)
            case .file:   try await dataSource.createFile(newPath)
            }
        } catch {
            newEntryDraft?.errorMessage = String.localizedStringWithFormat(
                String(localized: "Could not create \"%@\""), trimmed)
            return
        }
        newEntryDraft = nil
        // Refresh the parent so the new entry appears. A new folder is expanded
        // (it is empty); a new file is NOT auto-opened — it simply appears.
        await refresh(dir)
        if draft.intent == .folder, !expandedDirs.contains(newPath) {
            expandedDirs.insert(newPath)
            childrenByPath[newPath] = []
            rawChildrenByPath[newPath] = []
        }
        onPersistableStateChanged?()
    }

    /// Flattens the expanded tree into visible rows, depth-first. This is the
    /// single source the tree view renders from; rows are pure values so
    /// SwiftUI can skip unchanged rows via Equatable.
    ///
    /// Memoized: the flatten is only recomputed once per actual state change,
    /// keyed off `visibleRowsCache`. See its doc comment for the full list of
    /// observed properties whose `didSet` invalidates the cache — every
    /// property this function reads must be on that list.
    func visibleRows() -> [FileTreeRowModel] {
        // Touch every input on EVERY call — including cache hits. Under
        // @Observable, SwiftUI only tracks properties actually read during
        // body evaluation; a cache hit that read nothing observable would
        // leave the calling view with zero tracked dependencies, and the
        // tree would never re-render again.
        _ = rootChildren
        _ = childrenByPath
        _ = expandedDirs
        _ = truncatedDirs
        _ = fileStatusByPath
        _ = activeSubTabID
        _ = subTabs
        _ = showsHiddenFiles
        _ = newEntryDraft
        _ = searchQuery
        _ = showingRecursiveResults
        _ = searchResults
        _ = symlinkErrorsByPath
        if let cached = visibleRowsCache { return cached }
        #if DEBUG
        visibleRowsComputeCount += 1
        #endif
        var rows: [FileTreeRowModel] = []
        let trimmedQuery = searchQuery.trimmingCharacters(in: .whitespaces)

        // Mode 3: flat recursive results.
        if showingRecursiveResults {
            // Filter at emit time (mirrors modes 1/2, which read from the already
            // hidden-filtered rootChildren/childrenByPath) so hidden entries like
            // `.git/config` don't leak into results when "Show Hidden Files" is off.
            // searchResults itself stays raw so a live showsHiddenFiles toggle just
            // re-filters here instead of needing a re-search.
            for node in filtered(searchResults) {
                rows.append(FileTreeRowModel(
                    id: "result:" + node.path,
                    kind: .node(node),
                    depth: 0,
                    isSelected: selectedFilePath == node.path,
                    isExpanded: false,
                    status: fileStatusByPath[node.path],
                    symlinkError: symlinkErrorsByPath[node.path]))
            }
            visibleRowsCache = rows
            return rows
        }

        // Mode 2: live filter of the loaded tree.
        if !trimmedQuery.isEmpty {
            let (visible, expanded) = FileTreeSearch.filter(
                rootChildren: rootChildren, childrenByPath: childrenByPath, query: trimmedQuery)
            func emitFiltered(_ nodes: [FileNode], depth: Int) {
                for node in nodes where visible.contains(node.path) {
                    let isExp = node.isExpandableDirectory && expanded.contains(node.path)
                    rows.append(FileTreeRowModel(
                        id: node.path,
                        kind: .node(node),
                        depth: depth,
                        isSelected: selectedFilePath == node.path,
                        isExpanded: isExp,
                        status: fileStatusByPath[node.path],
                        symlinkError: symlinkErrorsByPath[node.path]))
                    if isExp, let kids = childrenByPath[node.path] {
                        emitFiltered(kids, depth: depth + 1)
                    }
                }
            }
            emitFiltered(rootChildren, depth: 0)
            visibleRowsCache = rows
            return rows
        }

        // Mode 1: normal tree (existing code path below — the `emit(...)` closure).
        func emit(_ nodes: [FileNode], depth: Int, parent: String) {
            if let draft = newEntryDraft, draft.parentPath == parent {
                rows.append(FileTreeRowModel(
                    id: "newEntry:" + parent,
                    kind: .editor(parentPath: parent, intent: draft.intent),
                    depth: depth, isSelected: false, isExpanded: false, status: nil))
            }
            for node in nodes {
                let expanded = node.isExpandableDirectory && expandedDirs.contains(node.path)
                rows.append(FileTreeRowModel(
                    id: node.path,
                    kind: .node(node),
                    depth: depth,
                    isSelected: selectedFilePath == node.path,
                    isExpanded: expanded,
                    status: fileStatusByPath[node.path],
                    symlinkError: symlinkErrorsByPath[node.path]
                ))
                if expanded, let kids = childrenByPath[node.path] {
                    emit(kids, depth: depth + 1, parent: node.path)
                    if truncatedDirs.contains(node.path) {
                        rows.append(FileTreeRowModel(
                            id: "loadMore:" + node.path,
                            kind: .loadMore(parentPath: node.path),
                            depth: depth + 1,
                            isSelected: false, isExpanded: false, status: nil
                        ))
                    }
                }
            }
        }
        emit(rootChildren, depth: 0, parent: rootPath)
        if truncatedDirs.contains(rootPath) {
            rows.append(FileTreeRowModel(
                id: "loadMore:" + rootPath, kind: .loadMore(parentPath: rootPath),
                depth: 0, isSelected: false, isExpanded: false, status: nil
            ))
        }
        visibleRowsCache = rows
        return rows
    }

    // MARK: - Search

    /// Escalate to a bounded, cancellable recursive search (Enter).
    func performRecursiveSearch() async {
        let query = searchQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        searchTask?.cancel()
        isSearching = true
        searchError = nil
        searchResults = []
        showingRecursiveResults = true
        let ds = dataSource
        let root = rootPath
        let cap = Self.searchMaxResults
        let includeHidden = showsHiddenFiles
        let task = Task { [weak self] in
            do {
                let results = try await ds.searchNames(root: root, query: query, maxResults: cap, includeHidden: includeHidden)
                guard !Task.isCancelled else { return }
                self?.searchResults = results
            } catch {
                guard !Task.isCancelled else { return }
                self?.searchError = (error as? LocalizedError)?.errorDescription
                    ?? error.localizedDescription
            }
            if !Task.isCancelled { self?.isSearching = false }
        }
        searchTask = task
        await task.value
    }

    func clearSearch() {
        searchQuery = ""   // didSet resets the rest
    }

    /// Reveal a recursive-result path back in the tree: clear the search and
    /// expand every ancestor directory so the path becomes visible.
    func revealInTree(_ path: String) async {
        clearSearch()
        let rel = relativePath(path)
        guard rel != path else { return }   // not under root; nothing to expand
        var current = rootPath
        for component in rel.split(separator: "/").dropLast() {
            current += "/" + component
            if !expandedDirs.contains(current) {
                await toggleExpand(current)
                // If a level failed to expand (data-source error), stop walking —
                // otherwise this keeps calling toggleExpand on never-expanded dirs
                // and repeatedly overwrites loadError. Mirrors beginNewEntry's guard.
                guard expandedDirs.contains(current) else { return }
            }
        }
    }

    // MARK: - Git diff / status

    /// Re-pulls `git status --porcelain` for the workspace root. Keys in the
    /// resulting map are absolute paths so the file-tree can look them up by
    /// `node.path` directly. No-op when no `GitDiffService`/`repoRoot` is wired.
    func refreshGitStatus() async {
        guard let svc = gitDiffService, let root = repoRoot else { return }
        let sp = PerfSignpost.begin("git-status-refresh")
        defer { PerfSignpost.end("git-status-refresh", sp) }
        let result = (try? await svc.fileStatus(in: root)) ?? [:]
        let prefix = root.hasSuffix("/") ? root : root + "/"
        var byPath: [String: FileStatus] = [:]
        for (rel, st) in result {
            // Renames are already keyed under the new (post-rename) path by
            // the porcelain parser, so a simple prefix join is sufficient.
            byPath[prefix + rel] = st
        }
        fileStatusByPath = byPath
    }

    /// Re-pulls hunks for the active sub-tab's file. No-op when no service /
    /// repo root is wired or there is no active sub-tab.
    func refreshDiffForActive() async {
        guard let svc = gitDiffService, let root = repoRoot,
              let path = activeSubTab?.path else { return }
        if let h = try? await svc.diffHunks(forFile: path, repoRoot: root) {
            diffHunksByPath[path] = h
        }
    }

    // MARK: - Sub-tab API

    /// Single-click on a tree file. Routing:
    /// 1. If `path` is already open in a pinned sub-tab → focus it.
    /// 2. Else if a preview sub-tab exists → repurpose it (replace path, reload).
    /// 3. Else → append a new preview sub-tab.
    func openInTree(_ path: String) async {
        if let pinned = subTabs.first(where: { $0.isPinned && $0.path == path }) {
            activeSubTabID = pinned.id
            onPersistableStateChanged?()
            return
        }
        if let previewIdx = subTabs.firstIndex(where: { !$0.isPinned }) {
            // Repurposing swaps in a different file under the same sub-tab id,
            // so any live (unsaved) buffer for the old file must not leak into
            // the new one.
            liveBufferByTab[subTabs[previewIdx].id] = nil
            subTabs[previewIdx].path = path
            subTabs[previewIdx].openFile = .empty
            activeSubTabID = subTabs[previewIdx].id
            await loadActiveTab()
            onPersistableStateChanged?()
            return
        }
        let new = SubTabRuntime(id: UUID(), path: path, isPinned: false, openFile: .empty)
        subTabs.append(new)
        activeSubTabID = new.id
        await loadActiveTab()
        onPersistableStateChanged?()
    }

    /// Tree double-click (or context-menu Pin): open and pin in one step. If
    /// the file is already open (preview or pinned), just flip `isPinned`.
    func pinFile(_ path: String) async {
        if let idx = subTabs.firstIndex(where: { $0.path == path }) {
            subTabs[idx].isPinned = true
            activeSubTabID = subTabs[idx].id
            if case .empty = subTabs[idx].openFile { await loadActiveTab() }
            onPersistableStateChanged?()
            return
        }
        let new = SubTabRuntime(id: UUID(), path: path, isPinned: true, openFile: .empty)
        subTabs.append(new)
        activeSubTabID = new.id
        await loadActiveTab()
        onPersistableStateChanged?()
    }

    /// Promote the active preview sub-tab to a pinned one. No-op if already pinned
    /// or there is no active sub-tab.
    func pinActiveSubTab() {
        guard let id = activeSubTabID,
              let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
        if !subTabs[idx].isPinned {
            subTabs[idx].isPinned = true
            onPersistableStateChanged?()
        }
    }

    /// Activate (focus) a specific sub-tab by id. No-op if the id is unknown.
    func activateSubTab(_ id: UUID) {
        guard subTabs.contains(where: { $0.id == id }) else { return }
        activeSubTabID = id
        onPersistableStateChanged?()
        // Schedule a diff refresh for the new active file. Fire-and-forget so
        // synchronous UI handlers calling `activateSubTab` don't have to await.
        Task { await self.refreshDiffForActive() }
    }

    /// Unconditionally close the sub-tab with the given id. Bypasses any dirty
    /// confirmation. Used by tests and the close-shortcut path. Stage F1 will
    /// add a dirty-check wrapper called `closeSubTab` that delegates here.
    func closeSubTabImmediate(_ id: UUID) {
        guard let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
        let wasActive = (activeSubTabID == id)
        liveBufferByTab[id] = nil
        pendingLargeFileMeta[id] = nil
        subTabs.remove(at: idx)
        if wasActive {
            if idx < subTabs.count {
                activeSubTabID = subTabs[idx].id
            } else if !subTabs.isEmpty {
                activeSubTabID = subTabs[subTabs.count - 1].id
            } else {
                activeSubTabID = nil
            }
        }
        onPersistableStateChanged?()
    }

    /// Close a sub-tab by id. If the sub-tab has unsaved text edits, this shows
    /// a Save / Don't Save / Cancel modal first; otherwise it delegates straight
    /// to `closeSubTabImmediate(_:)`. Tests bypass the modal by calling
    /// `closeSubTabImmediate(_:)` directly.
    func closeSubTab(_ id: UUID) {
        guard let tab = subTabs.first(where: { $0.id == id }) else { return }
        if case .text(let path, _, _, true) = tab.openFile {
            confirmCloseDirtySubTab(id: id, path: path)
        } else {
            closeSubTabImmediate(id)
        }
    }

    private func confirmCloseDirtySubTab(id: UUID, path: String) {
        let alert = NSAlert()
        let name = URL(fileURLWithPath: path).lastPathComponent
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
                    activateSubTab(id)
                    try await saveCurrentFile()
                    closeSubTabImmediate(id)
                } catch {
                    let err = NSAlert()
                    err.messageText = String(localized: "Save failed")
                    err.informativeText = error.localizedDescription
                    err.runModal()
                }
            }
        case .alertSecondButtonReturn: // Don't Save
            closeSubTabImmediate(id)
        default:
            break
        }
    }

    /// Drag-reorder sub-tabs. Mirrors `Array.move(fromOffsets:toOffset:)`.
    func reorderSubTabs(from source: IndexSet, to destination: Int) {
        subTabs.move(fromOffsets: source, toOffset: destination)
        onPersistableStateChanged?()
    }

    /// Cmd+W cascade: close the active sub-tab if there is one.
    /// - Returns: `true` if the shortcut was claimed (a sub-tab was closed);
    ///   `false` if no sub-tab existed and the outer tab close should proceed.
    func handleCloseShortcut() -> Bool {
        guard let id = activeSubTabID else { return false }
        closeSubTab(id)
        return true
    }

    // MARK: - File loading (operates on the active sub-tab)

    func selectFile(_ path: String) async {
        guard let id = activeSubTabID else { return }
        await selectFile(path, subTabID: id)
    }

    /// Internal entry point that pins the load to a specific sub-tab id, so
    /// every async write goes back to that exact slot regardless of the
    /// current `activeSubTabID` when the await resumes.
    private func selectFile(_ path: String, subTabID: UUID) async {
        // Dirty guard handled by the UI sheet before calling selectFile.
        setOpenFile(forSubTab: subTabID, expectingPath: path, .loadingMeta(path: path))
        onPersistableStateChanged?()

        let meta: FileMetadata
        do {
            meta = try await dataSource.fileMetadata(path)
        } catch {
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .error(path: path, message: error.localizedDescription))
            return
        }

        // Force Quick Look for files larger than the absolute editor cap.
        if meta.sizeBytes > Self.quickLookOnlyThreshold {
            await loadQuickLook(path: path, subTabID: subTabID)
            return
        }
        // Prompt for files between large threshold and quickLookOnly threshold.
        if meta.sizeBytes > Self.largeFileThreshold {
            pendingLargeFileMeta[subTabID] = meta
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .confirmingLargeFile(path: path, sizeBytes: meta.sizeBytes))
            return
        }

        await dispatchByType(path: path, meta: meta, subTabID: subTabID)
    }

    /// Called from UI when user confirms the large-file prompt. Reuses the
    /// metadata captured by `selectFile` when it still matches this sub-tab's
    /// path; falls back to a fresh stat otherwise (e.g. state restored from
    /// persistence, or the size-gate was hit via a `readFile` failure).
    func confirmLargeFileLoad() async {
        guard case .confirmingLargeFile(let path, _) = activeOpenFile,
              let id = activeSubTabID else { return }
        if let meta = pendingLargeFileMeta.removeValue(forKey: id), meta.path == path {
            await dispatchByType(path: path, meta: meta, subTabID: id)
            return
        }
        do {
            let meta = try await dataSource.fileMetadata(path)
            await dispatchByType(path: path, meta: meta, subTabID: id)
        } catch {
            setOpenFile(forSubTab: id, expectingPath: path,
                        .error(path: path, message: error.localizedDescription))
        }
    }

    /// Called from UI when user cancels the large-file prompt.
    func cancelLargeFileLoad() {
        if let id = activeSubTabID {
            pendingLargeFileMeta[id] = nil
        }
        setActiveOpenFile(.empty)
    }

    private func dispatchByType(path: String, meta: FileMetadata, subTabID: UUID) async {
        let kind = FileTypeClassifier.classifyByName(path)
        switch kind {
        case .text:
            await loadText(path: path, subTabID: subTabID)
        case .image:
            await loadImage(path: path, subTabID: subTabID)
        case .quickLook:
            await loadQuickLook(path: path, subTabID: subTabID)
        case .binary:
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .binary(path: path, metadata: meta))
        case .unknown:
            // Try a content sniff to upgrade unknowns into text where possible.
            await loadUnknown(path: path, meta: meta, subTabID: subTabID)
        }
    }

    private func loadText(path: String, subTabID: UUID) async {
        setOpenFile(forSubTab: subTabID, expectingPath: path,
                    .loadingContent(path: path))
        do {
            let data = try await dataSource.readFile(path, maxBytes: Self.textReadLimit)
            let decoded = await Task.detached(priority: .userInitiated) {
                TextEncodingDetector.decode(data)
            }.value
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .text(path: path, content: decoded.text, encoding: decoded.encoding, dirty: false))
        } catch FileBrowserError.fileTooLarge(_, let size, _) {
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .confirmingLargeFile(path: path, sizeBytes: size))
        } catch {
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .error(path: path, message: error.localizedDescription))
        }
    }

    private func loadImage(path: String, subTabID: UUID) async {
        setOpenFile(forSubTab: subTabID, expectingPath: path,
                    .loadingContent(path: path))
        do {
            let data = try await dataSource.readFile(path, maxBytes: Int(Self.quickLookOnlyThreshold))
            let decoded = await Task.detached(priority: .userInitiated) {
                DownsampledImageDecoder.decode(data)
            }.value
            if let decoded {
                let img = NSImage(cgImage: decoded.cgImage, size: decoded.pixelSize)
                setOpenFile(forSubTab: subTabID, expectingPath: path,
                            .image(path: path, image: img))
            } else {
                setOpenFile(forSubTab: subTabID, expectingPath: path,
                            .error(path: path, message: "Cannot decode image"))
            }
        } catch {
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .error(path: path, message: error.localizedDescription))
        }
    }

    private func loadQuickLook(path: String, subTabID: UUID) async {
        setOpenFile(forSubTab: subTabID, expectingPath: path,
                    .loadingContent(path: path))
        do {
            let url = try await dataSource.downloadForQuickLook(path) { _ in }
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .quickLook(path: path, localFileURL: url))
        } catch {
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .error(path: path, message: error.localizedDescription))
        }
    }

    private func loadUnknown(path: String, meta: FileMetadata, subTabID: UUID) async {
        do {
            let preview = try await dataSource.readPrefix(path, maxBytes: FileTypeClassifier.sniffByteCount)
            switch FileTypeClassifier.classifyByContent(preview) {
            case .text:
                await loadText(path: path, subTabID: subTabID)
            default:
                setOpenFile(forSubTab: subTabID, expectingPath: path,
                            .binary(path: path, metadata: meta))
            }
        } catch {
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .binary(path: path, metadata: meta))
        }
    }

    // MARK: - Edit / save

    var isDirty: Bool {
        if case .text(_, _, _, let dirty) = activeOpenFile { return dirty }
        return false
    }

    /// Live (per-keystroke) editor buffers, keyed by sub-tab id. Intentionally
    /// @ObservationIgnored: keystrokes must not fan out to every observer of this
    /// controller (tree rows, tab bars). The published `openFile` keeps the
    /// content it had when the tab was opened / last saved; `dirty` is the only
    /// flag that publishes, exactly once per dirty transition.
    @ObservationIgnored private(set) var liveBufferByTab: [UUID: String] = [:]

    /// Metadata captured when a load enters `.confirmingLargeFile`, keyed by
    /// sub-tab. Lets `confirmLargeFileLoad()` reuse the stat from `selectFile`
    /// instead of paying a second remote round-trip. Path-checked on read so a
    /// repurposed sub-tab can never dispatch stale metadata.
    @ObservationIgnored private var pendingLargeFileMeta: [UUID: FileMetadata] = [:]

    /// Reads the in-progress (uncommitted-to-`openFile`) buffer for a sub-tab,
    /// if the user has typed anything since it was opened/saved. Views that
    /// reconstruct their initial editor text from controller state must prefer
    /// this over `openFile.content` — see `updateBuffer` for why the two can
    /// diverge.
    func liveBuffer(for id: UUID) -> String? { liveBufferByTab[id] }

    /// Updates the in-memory buffer for the sub-tab identified by `id`, but
    /// only if that sub-tab still exists, its `path` is unchanged, and its
    /// `openFile` is still `.text` at the same `path`. The path/state guards
    /// are essential because the editor view stays alive across sub-tab
    /// switches (ZStack), so a delayed text-binding setter can fire long
    /// after the user has activated, closed, or repurposed another sub-tab.
    ///
    /// Only the *first* keystroke since the buffer was last clean publishes
    /// (via the `dirty` flip below) — every keystroke after that only updates
    /// `liveBufferByTab`, which is `@ObservationIgnored`. This keeps per-key input
    /// from fanning out to every other observer of this controller (file tree
    /// rows, tab bars, etc.).
    func updateBuffer(content: String, forSubTab id: UUID) {
        guard let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
        guard case .text(let path, let opened, let encoding, let dirty) = subTabs[idx].openFile else { return }
        guard subTabs[idx].path == path else { return }
        liveBufferByTab[id] = content
        if !dirty {
            // First divergence from the on-disk content: publish once so the
            // dirty dot and close-guard update. Also auto-pin (VSCode
            // semantics: editing a preview tab converts it to a regular tab)
            // so `openInTree`'s preview-reuse branch can no longer repurpose
            // this sub-tab out from under an in-progress edit — see the
            // "single click while dirty discards the preview tab" bug this
            // guards against. Folded into the same `subTabs` write as the
            // `openFile` update above so this doesn't add a second publish.
            subTabs[idx].openFile = .text(path: path, content: opened, encoding: encoding, dirty: true)
            subTabs[idx].isPinned = true
        }
    }

    /// Saves the current buffer back to disk via the data source. Returns as
    /// soon as the write completes and `dirty` is cleared; the git-status and
    /// diff refresh run off the save path so saving never blocks on `git`.
    func saveCurrentFile() async throws {
        guard let id = activeSubTabID,
              case .text(let path, let opened, let encoding, _) = activeOpenFile else {
            return
        }
        let content = liveBufferByTab[id] ?? opened
        let data = content.data(using: encoding) ?? Data()
        try await dataSource.writeFile(path, data: data)
        // The write above suspends this task; the user can keep typing while
        // it's in flight, which advances `liveBufferByTab[id]` past `content`.
        // Only treat the buffer as "saved" (clear it + drop dirty) if it still
        // matches what we actually wrote to disk. If it diverged, keep the
        // newer buffer and the dirty flag so those keystrokes are never
        // silently discarded; `openFile.content` still advances to the
        // just-saved value so a subsequent switch-away/back round trip has
        // the right disk-backed baseline to diff against.
        // Write completion must land on the sub-tab we started saving (`id`),
        // not whatever tab happens to be active now — `writeFile` suspends,
        // and the user can switch tabs while it's in flight. Using the
        // `expectingPath`-guarded setter (instead of re-reading
        // `activeSubTabID` via `setActiveOpenFile`) keeps a slow save from
        // clobbering a different tab's state after the user has moved on.
        let bufferAfterWrite = liveBufferByTab[id]
        if bufferAfterWrite == nil || bufferAfterWrite == content {
            liveBufferByTab[id] = nil
            setOpenFile(forSubTab: id, expectingPath: path,
                .text(path: path, content: content, encoding: encoding, dirty: false))
        } else {
            setOpenFile(forSubTab: id, expectingPath: path,
                .text(path: path, content: content, encoding: encoding, dirty: true))
        }
        // Fire-and-forget: diff + git status are non-essential to the save
        // completing and each is a `git` subprocess round-trip. This is a plain
        // (MainActor-inherited, not `Task.detached`) Task so the refreshes still
        // mutate observed state on the main actor — same pattern used after
        // tree mutations.
        Task { [weak self] in
            await self?.refreshDiffForActive()
            await self?.refreshGitStatus()
        }
    }

    // MARK: - Error mapping & password retry

    /// Maps an arbitrary error into a user-presentable `LoadError`. SSH key-auth
    /// failures become `.needsPassword` so the UI can prompt for a password
    /// instead of silently returning an empty tree.
    private func mapError(_ error: Error) -> LoadError {
        if let svcErr = error as? SFTPServiceError {
            switch svcErr {
            case .authenticationFailed, .noAuthMethodAvailable:
                let host = (dataSource as? RemoteFileBrowserDataSource)?.sshTarget.host ?? ""
                return .needsPassword(host: host)
            default:
                break
            }
        }
        if let localized = error as? LocalizedError, let msg = localized.errorDescription {
            return .generic(msg)
        }
        return .generic(error.localizedDescription)
    }

    /// Re-attempts the SFTP connection with an interactive password and reloads
    /// the root listing. Only meaningful when the data source is remote; for
    /// local sources this is a no-op.
    func retryWithPassword(_ password: String) async {
        guard let remote = dataSource as? RemoteFileBrowserDataSource else { return }
        do {
            try await remote.connectWithPassword(password)
            await loadRoot()
        } catch {
            loadError = mapError(error)
        }
    }

    // MARK: - Load more (truncated directories)

    /// Re-fetches a truncated directory's **full** (uncapped) listing via the
    /// normal per-directory call and clears its truncation marker. Backs the
    /// file-tree "Load more" row.
    func loadMore(_ path: String) async {
        do {
            let kids = try await dataSource.listDirectory(path)
            rawChildrenByPath[path] = kids
            childrenByPath[path] = filtered(kids)
            truncatedDirs.remove(path)
            if path == rootPath { rootChildren = childrenByPath[path] ?? [] }
        } catch {
            loadError = mapError(error)
        }
    }

    #if DEBUG
    /// Test seam: lets unit tests drive the truncated-directory UI path without
    /// constructing a 500+ entry directory.
    func markTruncatedForTesting(_ path: String) { truncatedDirs.insert(path) }
    #endif

    // MARK: - View mode

    /// Update the persisted view mode for a sub-tab (used by the document viewer's mode picker).
    func setViewMode(_ mode: FileViewMode, forSubTab id: UUID) {
        guard let index = subTabs.firstIndex(where: { $0.id == id }) else { return }
        subTabs[index].viewMode = mode
        onPersistableStateChanged?()
    }

    // MARK: - Copy path

    /// Writes either the absolute or root-relative form of `path` to the system
    /// pasteboard. Backs the file-tree right-click "Copy Absolute / Relative
    /// Path" menu items.
    func copyPath(_ path: String, mode: CopyPathMode) {
        let value = (mode == .absolute) ? path : relativePath(path)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }

    /// Strips the tab's `rootPath` prefix from `path`. If `path` does not live
    /// under the root (or equals the root with no trailing component), the
    /// absolute path is returned unchanged. Internal (not private) so unit
    /// tests can verify the prefix logic without touching the pasteboard.
    func relativePath(_ path: String) -> String {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path
    }
}
