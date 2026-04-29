//
//  FileBrowserTabController.swift
//  Treemux

import AppKit
import Combine
import Foundation

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
    @Published private(set) var selectedFilePath: String?
    @Published private(set) var openFile: OpenFileState = .empty
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
        self.selectedFilePath = state.selectedFilePath
        self.dataSource = dataSource
    }

    func snapshot() -> FileBrowserTabState {
        FileBrowserTabState(
            rootPath: rootPath,
            rootKind: rootKind,
            selectedFilePath: selectedFilePath,
            splitRatio: splitRatio,
            expandedDirs: Array(expandedDirs),
            showsHiddenFiles: showsHiddenFiles
        )
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

    // MARK: - File selection

    func selectFile(_ path: String) async {
        // Dirty guard handled by the UI sheet before calling selectFile.
        selectedFilePath = path
        openFile = .loadingMeta(path: path)
        onPersistableStateChanged?()

        let meta: FileMetadata
        do {
            meta = try await dataSource.fileMetadata(path)
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
            return
        }

        // Force Quick Look for files larger than the absolute editor cap.
        if meta.sizeBytes > Self.quickLookOnlyThreshold {
            await loadQuickLook(path: path)
            return
        }
        // Prompt for files between large threshold and quickLookOnly threshold.
        if meta.sizeBytes > Self.largeFileThreshold {
            openFile = .confirmingLargeFile(path: path, sizeBytes: meta.sizeBytes)
            return
        }

        await dispatchByType(path: path, meta: meta)
    }

    /// Called from UI when user confirms the large-file prompt.
    func confirmLargeFileLoad() async {
        guard case .confirmingLargeFile(let path, _) = openFile else { return }
        do {
            let meta = try await dataSource.fileMetadata(path)
            await dispatchByType(path: path, meta: meta)
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
        }
    }

    /// Called from UI when user cancels the large-file prompt.
    func cancelLargeFileLoad() {
        openFile = .empty
        selectedFilePath = nil
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
            openFile = .binary(path: path, metadata: meta)
        case .unknown:
            // Try a content sniff to upgrade unknowns into text where possible.
            await loadUnknown(path: path, meta: meta)
        }
    }

    private func loadText(path: String) async {
        openFile = .loadingContent(path: path)
        do {
            let data = try await dataSource.readFile(path, maxBytes: Self.textReadLimit)
            let (content, encoding) = decode(data)
            openFile = .text(path: path, content: content, encoding: encoding, dirty: false)
        } catch FileBrowserError.fileTooLarge(_, let size, _) {
            openFile = .confirmingLargeFile(path: path, sizeBytes: size)
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
        }
    }

    private func loadImage(path: String) async {
        openFile = .loadingContent(path: path)
        do {
            let data = try await dataSource.readFile(path, maxBytes: Int(Self.quickLookOnlyThreshold))
            if let img = NSImage(data: data) {
                openFile = .image(path: path, image: img)
            } else {
                openFile = .error(path: path, message: "Cannot decode image")
            }
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
        }
    }

    private func loadQuickLook(path: String) async {
        openFile = .loadingContent(path: path)
        do {
            let url = try await dataSource.downloadForQuickLook(path) { _ in }
            openFile = .quickLook(path: path, localFileURL: url)
        } catch {
            openFile = .error(path: path, message: error.localizedDescription)
        }
    }

    private func loadUnknown(path: String, meta: FileMetadata) async {
        do {
            let preview = try await dataSource.readFile(path, maxBytes: 8192)
            switch FileTypeClassifier.classifyByContent(preview) {
            case .text:
                await loadText(path: path)
            default:
                openFile = .binary(path: path, metadata: meta)
            }
        } catch {
            openFile = .binary(path: path, metadata: meta)
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
        if case .text(_, _, _, let dirty) = openFile { return dirty }
        return false
    }

    /// Updates the in-memory buffer for the currently open text file.
    func updateBuffer(content: String) {
        guard case .text(let path, _, let encoding, _) = openFile else { return }
        openFile = .text(path: path, content: content, encoding: encoding, dirty: true)
    }

    /// Saves the current buffer back to disk via the data source.
    func saveCurrentFile() async throws {
        guard case .text(let path, let content, let encoding, _) = openFile else {
            return
        }
        let data = content.data(using: encoding) ?? Data()
        try await dataSource.writeFile(path, data: data)
        openFile = .text(path: path, content: content, encoding: encoding, dirty: false)
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
}
