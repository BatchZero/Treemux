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
}
