//
//  FileBrowserTabController.swift
//  Treemux

import AppKit
import Combine
import Foundation

@MainActor
final class FileBrowserTabController: ObservableObject {
    // Persistent state mirrors / writes back to FileBrowserTabState.
    @Published var rootPath: String
    @Published private(set) var rootKind: FileBrowserRootKind
    @Published var splitRatio: Double
    @Published var expandedDirs: Set<String>
    @Published var showsHiddenFiles: Bool

    // Runtime state.
    @Published private(set) var rootChildren: [FileNode] = []
    @Published private(set) var childrenByPath: [String: [FileNode]] = [:]
    @Published private(set) var selectedFilePath: String?
    @Published private(set) var openFile: OpenFileState = .empty
    @Published private(set) var loadingPaths: Set<String> = []

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
        do {
            let children = try await dataSource.listDirectory(rootPath)
            self.rootChildren = filtered(children)
            self.childrenByPath[rootPath] = self.rootChildren
            // Restore previously-expanded dirs (best effort; missing dirs are silently skipped).
            for path in expandedDirs where path != rootPath {
                if let kids = try? await dataSource.listDirectory(path) {
                    self.childrenByPath[path] = filtered(kids)
                }
            }
        } catch {
            self.rootChildren = []
        }
    }

    func toggleExpand(_ path: String) async {
        if expandedDirs.contains(path) {
            expandedDirs.remove(path)
            childrenByPath[path] = nil
        } else {
            loadingPaths.insert(path)
            defer { loadingPaths.remove(path) }
            do {
                let kids = try await dataSource.listDirectory(path)
                childrenByPath[path] = filtered(kids)
                expandedDirs.insert(path)
            } catch {
                // Leave collapsed on error; caller may surface a toast.
            }
        }
        onPersistableStateChanged?()
    }

    func setShowsHiddenFiles(_ show: Bool) {
        guard showsHiddenFiles != show else { return }
        showsHiddenFiles = show
        // Re-filter cached listings without re-fetching.
        for (key, value) in childrenByPath {
            childrenByPath[key] = filtered(value)
        }
        rootChildren = childrenByPath[rootPath] ?? []
        onPersistableStateChanged?()
    }

    func refresh(_ path: String) async {
        do {
            let kids = try await dataSource.listDirectory(path)
            childrenByPath[path] = filtered(kids)
            if path == rootPath { rootChildren = childrenByPath[path] ?? [] }
        } catch {
            // Silent on error; caller can surface UI.
        }
    }

    private func filtered(_ nodes: [FileNode]) -> [FileNode] {
        showsHiddenFiles ? nodes : nodes.filter { !$0.isHidden }
    }
}
