//
//  FileBrowserTabController.swift
//  Treemux

import AppKit
import Combine
import Foundation

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
final class FileBrowserTabController: ObservableObject {
    /// Surfaced load failure for the file tree. UI binds this to a banner
    /// (Task B4) so SSH-key/permission failures stop being silently swallowed.
    enum LoadError: Equatable {
        case generic(String)
        case needsPassword(host: String)
    }

    // Persistent state mirrors / writes back to FileBrowserTabState.
    @Published var rootPath: String
    @Published private(set) var rootKind: FileBrowserRootKind
    @Published var splitRatio: Double
    @Published var expandedDirs: Set<String>
    @Published var showsHiddenFiles: Bool

    // Runtime state.
    @Published private(set) var rootChildren: [FileNode] = []
    @Published private(set) var childrenByPath: [String: [FileNode]] = [:]
    private var rawChildrenByPath: [String: [FileNode]] = [:]
    @Published private(set) var subTabs: [SubTabRuntime] = []
    @Published private(set) var activeSubTabID: UUID?
    @Published private(set) var loadingPaths: Set<String> = []
    @Published private(set) var loadError: LoadError?

    // Git diff/status caches. `diffHunksByPath` keyed by absolute path of the
    // active sub-tab; `fileStatusByPath` keyed by absolute path under `repoRoot`.
    @Published private(set) var diffHunksByPath: [String: [DiffHunk]] = [:]
    @Published private(set) var fileStatusByPath: [String: FileStatus] = [:]

    // Configuration.
    static let textReadLimit: Int = 5 * 1024 * 1024       // 5 MB
    static let largeFileThreshold: Int64 = 5 * 1024 * 1024 // 5 MB
    static let quickLookOnlyThreshold: Int64 = 100 * 1024 * 1024 // 100 MB
    static let treeFetchDepth: Int = 2
    static let treeEntryCap: Int = 500

    let dataSource: any FileBrowserDataSource
    let gitDiffService: GitDiffService?
    let repoRoot: String?
    let treeCache: DirectoryTreeCachePersistence
    @Published private(set) var truncatedDirs: Set<String> = []

    /// Shared word index for editor completion across this tab's sub-tabs.
    /// Lazily populated by `WordCompletionCoordinator` as buffers open.
    let wordIndex = BufferWordIndex()

    /// Called when the persistent state should be written back into
    /// `WorkspaceTabStateRecord.fileBrowserState` (debounced by caller).
    var onPersistableStateChanged: (() -> Void)?

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
        // 1. Instant render from the on-disk cache if present.
        if let identity = dataSource.treeCacheIdentity,
           let snap = treeCache.load(identity: identity, rootPath: rootPath) {
            applySnapshot(snap)
        }
        // 2. Background-refresh via bulk fetch (also the only fetch path on a cache miss).
        await refreshTree()
    }

    /// Bulk-fetch the tree, diff/apply it onto the live state without collapsing
    /// the user's expansion, restore any expanded dirs deeper than the fetch
    /// reached, then persist the snapshot. Refresh errors are swallowed when a
    /// cache is already on screen.
    func refreshTree() async {
        loadError = nil
        do {
            let fetch = try await dataSource.listTree(
                rootPath, maxDepth: Self.treeFetchDepth, entryCap: Self.treeEntryCap)
            applyFetch(fetch)
            for path in expandedDirs where path != rootPath && fetch.childrenByPath[path] == nil {
                if let kids = try? await dataSource.listDirectory(path) {
                    rawChildrenByPath[path] = kids
                    childrenByPath[path] = filtered(kids)
                }
            }
            persistTree()
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

    private func persistTree() {
        guard let identity = dataSource.treeCacheIdentity else { return }
        let snap = DirectoryTreeSnapshot(
            rootPath: rootPath,
            childrenByPath: rawChildrenByPath,
            truncatedDirs: Array(truncatedDirs),
            fetchedAt: Date()
        )
        try? treeCache.save(snap, identity: identity)
    }

    func toggleExpand(_ path: String) async {
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
            rawChildrenByPath[path] = nil
            childrenByPath[path] = nil
        } else {
            loadingPaths.insert(path)
            defer { loadingPaths.remove(path) }
            do {
                let kids = try await dataSource.listDirectory(path)
                rawChildrenByPath[path] = kids
                childrenByPath[path] = filtered(kids)
                expandedDirs.insert(path)
                Task { [weak self] in await self?.prefetchChildren(of: path) }
            } catch {
                // Leave collapsed on error; surface via loadError so the UI banner can show.
                loadError = mapError(error)
            }
        }
        onPersistableStateChanged?()
    }

    /// Background-prefetch a directory's grandchildren so expanding its children
    /// is instant. Internal (not private) so it is unit-testable directly.
    func prefetchChildren(of path: String) async {
        guard let fetch = try? await dataSource.listTree(
            path, maxDepth: Self.treeFetchDepth, entryCap: Self.treeEntryCap) else { return }
        guard expandedDirs.contains(path) else { return }
        for (p, kids) in fetch.childrenByPath where rawChildrenByPath[p] != kids {
            rawChildrenByPath[p] = kids
            childrenByPath[p] = filtered(kids)
        }
        truncatedDirs.formUnion(fetch.truncatedDirs)
    }

    func setShowsHiddenFiles(_ show: Bool) {
        guard showsHiddenFiles != show else { return }
        showsHiddenFiles = show
        // Re-derive filtered listings from the unfiltered cache, so toggling
        // hidden→visible doesn't require a re-fetch.
        var derived: [String: [FileNode]] = [:]
        for (key, value) in rawChildrenByPath {
            derived[key] = filtered(value)
        }
        childrenByPath = derived
        rootChildren = childrenByPath[rootPath] ?? []
        onPersistableStateChanged?()
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

    // MARK: - Git diff / status

    /// Re-pulls `git status --porcelain` for the workspace root. Keys in the
    /// resulting map are absolute paths so the file-tree can look them up by
    /// `node.path` directly. No-op when no `GitDiffService`/`repoRoot` is wired.
    func refreshGitStatus() async {
        guard let svc = gitDiffService, let root = repoRoot else { return }
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
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .confirmingLargeFile(path: path, sizeBytes: meta.sizeBytes))
            return
        }

        await dispatchByType(path: path, meta: meta, subTabID: subTabID)
    }

    /// Called from UI when user confirms the large-file prompt.
    func confirmLargeFileLoad() async {
        guard case .confirmingLargeFile(let path, _) = activeOpenFile,
              let id = activeSubTabID else { return }
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
            let (content, encoding) = decode(data)
            setOpenFile(forSubTab: subTabID, expectingPath: path,
                        .text(path: path, content: content, encoding: encoding, dirty: false))
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
            if let img = NSImage(data: data) {
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

    /// Tries UTF-8 → GBK → Latin-1.
    private func decode(_ data: Data) -> (String, String.Encoding) {
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        let gbk = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)))
        if let s = String(data: data, encoding: gbk) { return (s, gbk) }
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }

    // MARK: - Edit / save

    var isDirty: Bool {
        if case .text(_, _, _, let dirty) = activeOpenFile { return dirty }
        return false
    }

    /// Updates the in-memory buffer for the sub-tab identified by `id`, but
    /// only if that sub-tab still exists, its `path` is unchanged, and its
    /// `openFile` is still `.text` at the same `path`. The path/state guards
    /// are essential because the editor view stays alive across sub-tab
    /// switches (ZStack), so a delayed text-binding setter can fire long
    /// after the user has activated, closed, or repurposed another sub-tab.
    func updateBuffer(content: String, forSubTab id: UUID) {
        guard let idx = subTabs.firstIndex(where: { $0.id == id }) else { return }
        guard case .text(let path, _, let encoding, _) = subTabs[idx].openFile else { return }
        guard subTabs[idx].path == path else { return }
        subTabs[idx].openFile = .text(path: path, content: content, encoding: encoding, dirty: true)
    }

    /// Saves the current buffer back to disk via the data source. Returns as
    /// soon as the write completes and `dirty` is cleared; the git-status and
    /// diff refresh run off the save path so saving never blocks on `git`.
    func saveCurrentFile() async throws {
        guard case .text(let path, let content, let encoding, _) = activeOpenFile else {
            return
        }
        let data = content.data(using: encoding) ?? Data()
        try await dataSource.writeFile(path, data: data)
        setActiveOpenFile(.text(path: path, content: content, encoding: encoding, dirty: false))
        // Fire-and-forget: diff + git status are non-essential to the save
        // completing and each is a `git` subprocess round-trip. This is a plain
        // (MainActor-inherited, not `Task.detached`) Task so the refreshes still
        // mutate `@Published` state on the main actor — same pattern used after
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
