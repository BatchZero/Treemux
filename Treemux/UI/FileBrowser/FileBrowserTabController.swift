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

    // Configuration.
    static let textReadLimit: Int = 5 * 1024 * 1024       // 5 MB
    static let largeFileThreshold: Int64 = 5 * 1024 * 1024 // 5 MB
    static let quickLookOnlyThreshold: Int64 = 100 * 1024 * 1024 // 100 MB

    let dataSource: any FileBrowserDataSource

    /// Called when the persistent state should be written back into
    /// `WorkspaceTabStateRecord.fileBrowserState` (debounced by caller).
    var onPersistableStateChanged: (() -> Void)?

    init(initial state: FileBrowserTabState, dataSource: any FileBrowserDataSource) {
        self.rootPath = state.rootPath
        self.rootKind = state.rootKind
        self.splitRatio = state.splitRatio
        self.expandedDirs = Set(state.expandedDirs)
        self.showsHiddenFiles = state.showsHiddenFiles
        self.dataSource = dataSource
        self.subTabs = state.subTabs.map {
            SubTabRuntime(id: $0.id, path: $0.path, isPinned: $0.isPinned, openFile: .empty)
        }
        self.activeSubTabID = state.activeSubTabID ?? self.subTabs.first?.id
    }

    func snapshot() -> FileBrowserTabState {
        let pinned = subTabs.filter { $0.isPinned }.map {
            FileSubTabRecord(id: $0.id, path: $0.path, isPinned: true)
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

    private var activeOpenFile: OpenFileState {
        activeSubTab?.openFile ?? .empty
    }

    private func loadActiveTab() async {
        guard let active = activeSubTab else { return }
        await selectFile(active.path)
    }

    // MARK: - Tree loading

    func loadRoot() async {
        loadError = nil
        do {
            let children = try await dataSource.listDirectory(rootPath)
            rawChildrenByPath[rootPath] = children
            childrenByPath[rootPath] = filtered(children)
            rootChildren = childrenByPath[rootPath] ?? []
            // Restore previously-expanded dirs (best effort; missing dirs are silently skipped).
            for path in expandedDirs where path != rootPath {
                if let kids = try? await dataSource.listDirectory(path) {
                    rawChildrenByPath[path] = kids
                    childrenByPath[path] = filtered(kids)
                }
            }
        } catch {
            rootChildren = []
            loadError = mapError(error)
        }
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
            } catch {
                // Leave collapsed on error; surface via loadError so the UI banner can show.
                loadError = mapError(error)
            }
        }
        onPersistableStateChanged?()
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
        // Dirty guard handled by the UI sheet before calling selectFile.
        setActiveOpenFile(.loadingMeta(path: path))
        onPersistableStateChanged?()

        let meta: FileMetadata
        do {
            meta = try await dataSource.fileMetadata(path)
        } catch {
            setActiveOpenFile(.error(path: path, message: error.localizedDescription))
            return
        }

        // Force Quick Look for files larger than the absolute editor cap.
        if meta.sizeBytes > Self.quickLookOnlyThreshold {
            await loadQuickLook(path: path)
            return
        }
        // Prompt for files between large threshold and quickLookOnly threshold.
        if meta.sizeBytes > Self.largeFileThreshold {
            setActiveOpenFile(.confirmingLargeFile(path: path, sizeBytes: meta.sizeBytes))
            return
        }

        await dispatchByType(path: path, meta: meta)
    }

    /// Called from UI when user confirms the large-file prompt.
    func confirmLargeFileLoad() async {
        guard case .confirmingLargeFile(let path, _) = activeOpenFile else { return }
        do {
            let meta = try await dataSource.fileMetadata(path)
            await dispatchByType(path: path, meta: meta)
        } catch {
            setActiveOpenFile(.error(path: path, message: error.localizedDescription))
        }
    }

    /// Called from UI when user cancels the large-file prompt.
    func cancelLargeFileLoad() {
        setActiveOpenFile(.empty)
    }

    private func dispatchByType(path: String, meta: FileMetadata) async {
        let kind = FileTypeClassifier.classifyByName(path)
        switch kind {
        case .text:
            await loadText(path: path)
        case .image:
            await loadImage(path: path)
        case .quickLook:
            await loadQuickLook(path: path)
        case .binary:
            setActiveOpenFile(.binary(path: path, metadata: meta))
        case .unknown:
            // Try a content sniff to upgrade unknowns into text where possible.
            await loadUnknown(path: path, meta: meta)
        }
    }

    private func loadText(path: String) async {
        setActiveOpenFile(.loadingContent(path: path))
        do {
            let data = try await dataSource.readFile(path, maxBytes: Self.textReadLimit)
            let (content, encoding) = decode(data)
            setActiveOpenFile(.text(path: path, content: content, encoding: encoding, dirty: false))
        } catch FileBrowserError.fileTooLarge(_, let size, _) {
            setActiveOpenFile(.confirmingLargeFile(path: path, sizeBytes: size))
        } catch {
            setActiveOpenFile(.error(path: path, message: error.localizedDescription))
        }
    }

    private func loadImage(path: String) async {
        setActiveOpenFile(.loadingContent(path: path))
        do {
            let data = try await dataSource.readFile(path, maxBytes: Int(Self.quickLookOnlyThreshold))
            if let img = NSImage(data: data) {
                setActiveOpenFile(.image(path: path, image: img))
            } else {
                setActiveOpenFile(.error(path: path, message: "Cannot decode image"))
            }
        } catch {
            setActiveOpenFile(.error(path: path, message: error.localizedDescription))
        }
    }

    private func loadQuickLook(path: String) async {
        setActiveOpenFile(.loadingContent(path: path))
        do {
            let url = try await dataSource.downloadForQuickLook(path) { _ in }
            setActiveOpenFile(.quickLook(path: path, localFileURL: url))
        } catch {
            setActiveOpenFile(.error(path: path, message: error.localizedDescription))
        }
    }

    private func loadUnknown(path: String, meta: FileMetadata) async {
        do {
            let preview = try await dataSource.readFile(path, maxBytes: 8192)
            switch FileTypeClassifier.classifyByContent(preview) {
            case .text:
                await loadText(path: path)
            default:
                setActiveOpenFile(.binary(path: path, metadata: meta))
            }
        } catch {
            setActiveOpenFile(.binary(path: path, metadata: meta))
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

    /// Updates the in-memory buffer for the currently open text file.
    func updateBuffer(content: String) {
        guard case .text(let path, _, let encoding, _) = activeOpenFile else { return }
        setActiveOpenFile(.text(path: path, content: content, encoding: encoding, dirty: true))
    }

    /// Saves the current buffer back to disk via the data source.
    func saveCurrentFile() async throws {
        guard case .text(let path, let content, let encoding, _) = activeOpenFile else {
            return
        }
        let data = content.data(using: encoding) ?? Data()
        try await dataSource.writeFile(path, data: data)
        setActiveOpenFile(.text(path: path, content: content, encoding: encoding, dirty: false))
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
